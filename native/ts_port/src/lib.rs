//! JavaScript, TypeScript, Python, C, C++ and Go as definitions and references.
//!
//! Each grammar's own tags query says what is a definition and what is a call;
//! what a definition is nested in is worked out from the tree, so a method is
//! qualified by its class. Imports are read from the tree as well, because the
//! tags queries do not carry them: a specifier, and the names brought in from
//! it, are what the resolver needs to find what an import refers to.
//!
//! The reply is plain JSON, one object per request, holding the attrs of the
//! graph: a node's key and lines, and a reference's kind, target and line. The
//! signature and the text hash are filled in by Elixir, which is where the
//! plan says they are computed.


use serde_json::{Value, json};
use tree_sitter::{Language, Node, Parser, Query, QueryCursor, StreamingIterator};
mod scopes;

/// The languages this program parses, and the queries that read them.
fn grammar(lang: &str) -> Option<(Language, Vec<&'static str>)> {
    match lang {
        "javascript" => Some((
            Language::new(tree_sitter_javascript::LANGUAGE),
            vec![tree_sitter_javascript::TAGS_QUERY],
        )),
        // TypeScript and TSX read both the JavaScript tags and their own, so
        // that a TypeScript interface or type alias is a definition too.
        "typescript" => Some((
            Language::new(tree_sitter_typescript::LANGUAGE_TYPESCRIPT),
            vec![
                tree_sitter_typescript::TAGS_QUERY,
                tree_sitter_javascript::TAGS_QUERY,
            ],
        )),
        "tsx" => Some((
            Language::new(tree_sitter_typescript::LANGUAGE_TSX),
            vec![
                tree_sitter_typescript::TAGS_QUERY,
                tree_sitter_javascript::TAGS_QUERY,
            ],
        )),
        "python" => Some((
            Language::new(tree_sitter_python::LANGUAGE),
            vec![tree_sitter_python::TAGS_QUERY],
        )),
        "c" => Some((Language::new(tree_sitter_c::LANGUAGE), vec![C_QUERY])),
        "cpp" => Some((Language::new(tree_sitter_cpp::LANGUAGE), vec![C_QUERY, CPP_QUERY])),
        "go" => Some((Language::new(tree_sitter_go::LANGUAGE), vec![tree_sitter_go::TAGS_QUERY])),
        _ => None,
    }
}

// Capture the definition including its body, never a header prototype.
const C_QUERY: &str = r#"
(function_definition declarator: (function_declarator declarator: (identifier) @name)) @definition.function
(function_definition declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))) @definition.function
(struct_specifier name: (type_identifier) @name body: (_)) @definition.class
(union_specifier name: (type_identifier) @name body: (_)) @definition.class
(enum_specifier name: (type_identifier) @name body: (_)) @definition.class
(type_definition declarator: (type_identifier) @name) @definition.type
(call_expression function: (identifier) @name) @reference.call
(call_expression function: (field_expression field: (field_identifier) @name)) @reference.call
"#;

const CPP_QUERY: &str = r#"
(function_definition declarator: (reference_declarator (function_declarator declarator: (identifier) @name))) @definition.function
(function_definition declarator: (function_declarator declarator: (field_identifier) @name)) @definition.method
(function_definition declarator: (function_declarator declarator: (qualified_identifier name: (identifier) @name))) @definition.method
(class_specifier name: (type_identifier) @name body: (_)) @definition.class
(namespace_definition name: (namespace_identifier) @name) @definition.module
(call_expression function: (qualified_identifier name: (identifier) @name)) @reference.call
(call_expression function: (template_function name: (identifier) @name)) @reference.call
"#;

const CONSTRUCTOR_QUERY: &str = r#"((method_definition name: (property_identifier) @name) @definition.method (#eq? @name "constructor"))"#;

struct Grammar {
    language: Language,
    queries: Vec<Query>,
}

// Query compilation is independent of the file. The Port serves many files;
// compile each language once, sharing only immutable queries between parses.
fn compiled_grammar(lang: &str) -> Result<&'static Grammar, String> {
    use std::sync::OnceLock;
    static JS: OnceLock<Result<Grammar, String>> = OnceLock::new();
    static TS: OnceLock<Result<Grammar, String>> = OnceLock::new();
    static TSX: OnceLock<Result<Grammar, String>> = OnceLock::new();
    static PY: OnceLock<Result<Grammar, String>> = OnceLock::new();
    static C: OnceLock<Result<Grammar, String>> = OnceLock::new();
    static CPP: OnceLock<Result<Grammar, String>> = OnceLock::new();
    static GO: OnceLock<Result<Grammar, String>> = OnceLock::new();
    let slot = match lang {
        "javascript" => &JS, "typescript" => &TS, "tsx" => &TSX, "python" => &PY,
        "c" => &C, "cpp" => &CPP, "go" => &GO,
        _ => return Err(format!("unknown language: {lang}")),
    };
    slot.get_or_init(|| {
        let (language, mut sources) = grammar(lang).unwrap();
        if matches!(lang, "javascript" | "typescript" | "tsx") { sources.push(CONSTRUCTOR_QUERY); }
        let queries = sources.into_iter().map(|source| Query::new(&language, source)
            .map_err(|error| error.to_string())).collect::<Result<Vec<_>, _>>()?;
        Ok(Grammar { language, queries })
    }).as_ref().map_err(Clone::clone)
}

/// The kinds the plan names. A tags query captures more than this (constants,
/// for one); what it captures that is not here is not a definition the core
/// holds.
fn definition_kind(capture: &str) -> Option<&'static str> {
    match capture.strip_prefix("definition.") {
        Some("class") => Some("class"),
        Some("function") => Some("function"),
        Some("method") => Some("method"),
        Some("module") => Some("module"),
        Some("type") => Some("type"),
        _ => None,
    }
}

struct Definition {
    kind: String,
    name: String,
    qualified: String,
    key: String,
    start_line: usize,
    end_line: usize,
    start_byte: usize,
    end_byte: usize,
}

/// Parse `source` and answer with the definitions and references it holds.
pub fn parse(lang: &str, path: &str, source: &str) -> Result<Value, String> {
    let grammar = compiled_grammar(lang)?;
    let mut parser = Parser::new();
    parser
        .set_language(&grammar.language)
        .map_err(|error| format!("{error}"))?;
    // A tree with errors in it is still a tree: what parsed before the error is
    // read, and a file being edited keeps its place in the graph.
    let tree = parser.parse(source, None).ok_or("no tree")?;

    let mut definitions: Vec<Raw> = Vec::new();
    let mut calls: Vec<Raw> = Vec::new();

    for query in &grammar.queries {
        let names = query.capture_names().to_vec();
        let mut cursor = QueryCursor::new();
        let mut matches = cursor.matches(query, tree.root_node(), source.as_bytes());

        while let Some(found) = matches.next() {
            // A match carries the definition or the call and, inside it, the
            // name it is called by. The name may come after, so it is read
            // first.
            let name_node = found
                .captures()
                .iter()
                .find(|capture| names[capture.index as usize] == "name")
                .map(|capture| capture.node);
            let name = name_node
                .map(|node| text(node, source).to_string())
                .unwrap_or_default();
            // `save()` and not `store.save()`: only a bare call can be a call
            // of something an import bound to that name
            let bare = name_node
                .and_then(|node| node.parent())
                .is_some_and(|parent| matches!(parent.kind(), "call_expression" | "call" | "new_expression"));

            for capture in found.captures() {
                let capture_name = names[capture.index as usize];
                let node = capture.node;

                let kind = definition_kind(capture_name).or({
                    match capture_name {
                        "reference.call" => Some("calls"),
                        "reference.class" if node.kind() == "new_expression" => Some("calls"),
                        "reference.class" | "reference.type" => Some("references"),
                        _ => None,
                    }
                });

                let Some(kind) = kind else { continue };

                let raw = Raw {
                    kind: kind.to_string(),
                    name: name.clone(),
                    bare,
                    start_byte: node.start_byte(),
                    end_byte: node.end_byte(),
                    start_line: node.start_position().row + 1,
                    end_line: node.end_position().row + 1,
                };

                if capture_name.starts_with("reference.") {
                    calls.push(raw);
                } else {
                    definitions.push(raw);
                }
            }
        }
    }

    // Several queries run over one tree (TypeScript reads the JavaScript tags
    // as well as its own), so the definitions are put in document order here,
    // an enclosing one before what it encloses, and a definition both queries
    // found is kept once. qualify and attach both rely on that order.
    definitions.sort_by_key(|one| (one.start_byte, std::cmp::Reverse(one.end_byte)));
    definitions.dedup_by(|later, earlier| {
        later.start_byte == earlier.start_byte
            && later.end_byte == earlier.end_byte
            && later.kind == earlier.kind
    });

    let (definitions, parents) = qualify(definitions, lang, path);
    let (live, overwritten) = surviving_definitions(&definitions, &parents);
    let root = tree.root_node();
    let found_imports = imports(root, source, lang);

    // What a bare call is bound to when an import gave the name another one:
    // `import { put as save }` makes `save()` a call of `./store#put`, and a
    // default import a call of the module's default export.
    let bindings = scopes::Bindings::new(root, source, lang, &found_imports);

    let nodes: Vec<Value> = definitions
        .iter()
        .enumerate()
        .filter(|(index, _)| live[*index])
        .map(|(_, definition)| {
            json!({
                "key": definition.key,
                "lang": lang,
                "kind": definition.kind,
                "name": definition.name,
                "qualified": definition.qualified,
                "path": path,
                "start_line": definition.start_line,
                "end_line": definition.end_line,
            })
        })
        .collect();

    let mut refs: Vec<Ref> = calls
        .iter()
        .map(|call| Ref {
            kind: call.kind.clone(),
            target: if call.bare {
                bindings.target(&call.name, call.start_byte).filter(|target| !target.ends_with("#*"))
                    .unwrap_or_else(|| call.name.clone())
            } else {
                namespace_call(root, source, call.start_byte, &bindings)
                    .unwrap_or_else(|| call.name.clone())
            },
            arity: Value::Null,
            line: call.start_line,
            start_byte: call.start_byte,
            from_key: None,
        })
        .collect();

    for import in &found_imports {
        refs.push(Ref {
            kind: "imports".to_string(),
            target: import.spec.clone(),
            arity: Value::Null,
            line: import.line,
            start_byte: import.start_byte,
            from_key: None,
        });

        for binding in &import.names {
            if binding.exported == "*" { continue; }
            refs.push(Ref {
                kind: "references".to_string(),
                target: format!("{}#{}", import.spec, binding.exported),
                arity: Value::Null,
                line: import.line,
                start_byte: import.start_byte,
                from_key: None,
            });
        }
    }

    // A reference in an overwritten body must not attach to the later node
    // sharing its key, nor turn into a file-level reference after filtering.
    refs.retain(|entry| {
        let next = overwritten.partition_point(|(start, _)| *start <= entry.start_byte);
        next == 0 || entry.start_byte >= overwritten[next - 1].1
    });
    attach(&definitions, &mut refs);

    // A class holds its methods and a function the functions inside it, as an
    // Elixir module holds what it declares: the parent is known here, so the
    // reference is not attached by position.
    for (child, parent) in parents.iter().enumerate() {
        if !live[child] { continue; }
        if let Some(parent) = parent {
            refs.push(Ref {
                kind: "contains".to_string(),
                target: definitions[child].qualified.clone(),
                arity: Value::Null,
                line: definitions[child].start_line,
                start_byte: definitions[child].start_byte,
                from_key: Some(definitions[*parent].key.clone()),
            });
        }
    }

    let refs: Vec<Value> = refs
        .iter()
        .map(|entry| {
            json!({
                "from_key": entry.from_key,
                "kind": entry.kind,
                "target": entry.target,
                "ambiguous": false,
                "arity": entry.arity,
                "line": entry.line,
            })
        })
        .collect();

    Ok(json!({ "nodes": nodes, "refs": refs }))
}

struct Raw {
    kind: String,
    name: String,
    bare: bool,
    start_byte: usize,
    end_byte: usize,
    start_line: usize,
    end_line: usize,
}

/// The last definition of a key wins. Children of an overwritten definition
/// go with it, even when their own keys did not occur in the replacement.
fn surviving_definitions(definitions: &[Definition], parents: &[Option<usize>])
    -> (Vec<bool>, Vec<(usize, usize)>) {
    let last: std::collections::HashMap<&str, usize> = definitions.iter().enumerate()
        .map(|(index, definition)| (definition.key.as_str(), index)).collect();
    let mut live = Vec::with_capacity(definitions.len());
    let mut overwritten: Vec<(usize, usize)> = Vec::new();
    for (index, definition) in definitions.iter().enumerate() {
        let winner = last[definition.key.as_str()] == index;
        live.push(winner && parents[index].is_none_or(|parent| live[parent]));
        if !winner {
            if let Some(previous) = overwritten.last_mut()
                .filter(|previous| definition.start_byte <= previous.1) {
                previous.1 = previous.1.max(definition.end_byte);
            } else {
                overwritten.push((definition.start_byte, definition.end_byte));
            }
        }
    }
    (live, overwritten)
}

// Member calls keep a namespace binding instead of degrading to a bare leaf.
fn namespace_call(root: Node, source: &str, at: usize, bindings: &scopes::Bindings) -> Option<String> {
    let mut node = root.descendant_for_byte_range(at, at + 1)?;
    loop {
        if matches!(node.kind(), "member_expression" | "attribute") {
            let object = node.child_by_field_name("object")?;
            let member = node.child_by_field_name("property")
                .or_else(|| node.child_by_field_name("attribute"))?;
            let target = bindings.target(text(object, source), at)?;
            let spec = target.strip_suffix("#*")?;
            return Some(format!("{}#{}", spec, text(member, source)));
        }
        if matches!(node.kind(), "call_expression" | "call") {
            node = node.child_by_field_name("function")?;
            if !matches!(node.kind(), "member_expression" | "attribute") { return None; }
            continue;
        }
        node = node.parent()?;
    }
}

struct Ref {
    kind: String,
    target: String,
    arity: Value,
    line: usize,
    start_byte: usize,
    from_key: Option<String>,
}

struct Import {
    spec: String,
    names: Vec<Binding>,
    line: usize,
    start_byte: usize,
}

/// A name an import brings in: the name the module exports it by, and the name
/// it is called by here, if it is called anything here (a re-export is not).
struct Binding {
    exported: String,
    local: Option<String>,
}

impl Binding {
    fn same(name: String) -> Self {
        Binding {
            local: Some(name.clone()),
            exported: name,
        }
    }
}

/// A method is qualified by its class, a nested class by the class it is in.
/// Each definition's parent, the innermost one holding it, comes back with it.
fn qualify(raw: Vec<Raw>, lang: &str, path: &str) -> (Vec<Definition>, Vec<Option<usize>>) {
    // The definitions come out of the tree in document order and nest, so the
    // ones open right now are a stack, and an enclosing definition is always
    // qualified before what it encloses.
    let mut open: Vec<(usize, usize, String, usize)> = Vec::new();
    let mut definitions = Vec::new();
    let mut parents = Vec::new();

    for one in raw {
        while let Some(top) = open.last() {
            if one.start_byte >= top.0 && one.end_byte <= top.1 {
                break;
            }
            open.pop();
        }

        let qualified = match open.last() {
            Some((_, _, prefix, _)) => format!("{prefix}.{}", one.name),
            None => one.name.clone(),
        };
        let key = format!("{lang}:{}:{path}#{qualified}", one.kind);

        parents.push(open.last().map(|top| top.3));
        // A typedef names its aliased struct; it is not that struct's scope.
        if !(matches!(lang, "c" | "cpp") && one.kind == "type") {
            open.push((one.start_byte, one.end_byte, qualified.clone(), definitions.len()));
        }

        definitions.push(Definition {
            kind: one.kind,
            name: one.name,
            qualified,
            key,
            start_line: one.start_line,
            end_line: one.end_line,
            start_byte: one.start_byte,
            end_byte: one.end_byte,
        });
    }

    (definitions, parents)
}

/// Say which definition each reference came from: the innermost one holding
/// it, if any. The definitions come in document order and the references are
/// swept in order of where they are, so this is one pass.
fn attach(definitions: &[Definition], refs: &mut [Ref]) {
    let mut order: Vec<usize> = (0..refs.len()).collect();
    order.sort_by_key(|index| refs[*index].start_byte);

    let mut open: Vec<&Definition> = Vec::new();
    let mut next = 0;

    // The open definitions are a chain, each inside the one below it: one that
    // has ended is closed before the next is opened, and after the openings
    // the ones ending before the reference are closed too, so the top is the
    // innermost definition holding it.
    for index in order {
        let at = refs[index].start_byte;

        while next < definitions.len() && definitions[next].start_byte <= at {
            let opening = &definitions[next];
            while open.last().is_some_and(|top| top.end_byte <= opening.start_byte) {
                open.pop();
            }
            open.push(opening);
            next += 1;
        }

        while open.last().is_some_and(|top| top.end_byte <= at) {
            open.pop();
        }

        refs[index].from_key = open.last().map(|one| one.key.clone());
    }
}

/// Imports are read from the tree, because the tags queries do not carry them.
fn imports(root: Node, source: &str, lang: &str) -> Vec<Import> {
    let mut found = Vec::new();
    walk(root, &mut |node| found.extend(imports_of(node, source, lang)));
    found
}

fn imports_of(node: Node, source: &str, lang: &str) -> Vec<Import> {
    match lang {
        "javascript" | "typescript" | "tsx" => js_imports(node, source),
        "python" => python_imports(node, source),
        "c" | "cpp" if node.kind() == "preproc_include" => path_import(node, source),
        "go" if node.kind() == "import_spec" => path_import(node, source),
        _ => Vec::new(),
    }
}

fn path_import(node: Node, source: &str) -> Vec<Import> {
    let Some(path) = node.child_by_field_name("path") else { return Vec::new() };
    // Macro includes have no literal path; leave them unresolved.
    if !matches!(path.kind(), "string_literal" | "system_lib_string" |
        "interpreted_string_literal" | "raw_string_literal") { return Vec::new(); }
    let literal = text(path, source);
    let closing = match literal.as_bytes().first() {
        Some(b'"') => '"', Some(b'<') => '>', Some(b'`') => '`', _ => return Vec::new(),
    };
    if literal.len() < 2 || !literal.ends_with(closing) { return Vec::new(); }
    vec![Import {
        spec: literal[1..literal.len() - 1].to_string(),
        names: Vec::new(),
        line: node.start_position().row + 1,
        start_byte: node.start_byte(),
    }]
}

/// `import … from "<spec>"`, `require("<spec>")` and a dynamic
/// `import("<spec>")`; a re-export carries the same shape as an import.
fn js_imports(node: Node, source: &str) -> Vec<Import> {
    let line = node.start_position().row + 1;
    let start_byte = node.start_byte();

    match node.kind() {
        "import_statement" | "export_statement" => match string_argument(node, "source", source) {
            Some(spec) => vec![Import {
                spec,
                names: imported_names(node, source),
                line,
                start_byte,
            }],
            None => Vec::new(),
        },
        "call_expression" => {
            let function = node.child_by_field_name("function");
            let required =
                function.is_some_and(|f| f.kind() == "identifier" && text(f, source) == "require");
            let dynamic = function.is_some_and(|f| f.kind() == "import");

            if !required && !dynamic {
                return Vec::new();
            }

            match string_argument(node, "arguments", source) {
                Some(spec) => vec![Import {
                    spec,
                    names: Vec::new(),
                    line,
                    start_byte,
                }],
                None => Vec::new(),
            }
        }
        _ => Vec::new(),
    }
}

/// `import a.b` and `from a.b import c`, which may name several modules.
fn python_imports(node: Node, source: &str) -> Vec<Import> {
    let line = node.start_position().row + 1;

    match node.kind() {
        "import_statement" => {
            let mut found = Vec::new();
            let mut cursor = node.walk();

            for child in node.children(&mut cursor) {
                match child.kind() {
                    "dotted_name" => found.push(Import {
                        spec: text(child, source).to_string(),
                        names: vec![Binding { exported: "*".into(), local: Some(text(child, source).to_string()) }],
                        line,
                        start_byte: child.start_byte(),
                    }),
                    // `import app.store as store` names the module, and
                    // nothing in it
                    "aliased_import" => {
                        if let Some(name) = child.child_by_field_name("name") {
                            found.push(Import {
                                spec: text(name, source).to_string(),
                                names: vec![Binding { exported: "*".into(), local: Some(alias_of(child, source)) }],
                                line,
                                start_byte: child.start_byte(),
                            });
                        }
                    }
                    _ => {}
                }
            }

            found
        }
        "import_from_statement" => {
            let spec = node
                .child_by_field_name("module_name")
                .map(|module| text(module, source).to_string())
                .unwrap_or_default();

            // `from app.store import put as save` brings in put, called save
            let names: Vec<Binding> = children_by_field(node, "name")
                .into_iter()
                .map(|one| match one.kind() {
                    "aliased_import" => Binding {
                        exported: one
                            .child_by_field_name("name")
                            .map(|name| last_segment(text(name, source)))
                            .unwrap_or_default(),
                        local: Some(alias_of(one, source)),
                    },
                    _ => Binding::same(last_segment(text(one, source))),
                })
                .filter(|binding| !binding.exported.is_empty())
                .collect();

            if spec.chars().all(|c| c == '.') {
                return names.into_iter().map(|binding| Import {
                    spec: format!("{}{}", spec, binding.exported),
                    names: vec![Binding { exported: "*".into(), local: binding.local }],
                    line, start_byte: node.start_byte(),
                }).collect();
            }
            vec![Import {
                spec,
                names,
                line,
                start_byte: node.start_byte(),
            }]
        }
        _ => Vec::new(),
    }
}

fn alias_of(node: Node, source: &str) -> String {
    node.child_by_field_name("alias")
        .map(|alias| text(alias, source).to_string())
        .unwrap_or_default()
}

/// The names an import clause brings in, by the name each is exported as:
/// `import { a, b as c } from "x"` brings in a, and b called c; `import S from
/// "x"` brings in the default export, called S. A namespace import names the
/// module and nothing in it. `export { a as b } from "x"` refers to a and
/// binds nothing here.
fn imported_names(node: Node, source: &str) -> Vec<Binding> {
    let mut names: Vec<Binding> = Vec::new();

    walk(node, &mut |child| match child.kind() {
        "import_specifier" | "export_specifier" => {
            if let Some(name) = child.child_by_field_name("name") {
                let exported = text(name, source).to_string();
                let local = if child.kind() == "export_specifier" {
                    None
                } else {
                    Some(
                        child
                            .child_by_field_name("alias")
                            .map(|alias| text(alias, source).to_string())
                            .unwrap_or_else(|| exported.clone()),
                    )
                };
                names.push(Binding { exported, local });
            }
        }
        "namespace_import" => {
            if let Some(name) = child.named_child(0) {
                names.push(Binding { exported: "*".into(), local: Some(text(name, source).to_string()) });
            }
        }
        // the default import, which the grammar gives in the clause itself
        "identifier" => {
            if child.parent().is_some_and(|parent| parent.kind() == "import_clause") {
                names.push(Binding {
                    exported: "default".to_string(),
                    local: Some(text(child, source).to_string()),
                });
            }
        }
        _ => {}
    });

    names
}

/// The name a module path is called by where it is used: `app.store` is `store`.
fn last_segment(path: &str) -> String {
    path.rsplit('.').next().unwrap_or("").trim().to_string()
}

fn string_argument(node: Node, field: &str, source: &str) -> Option<String> {
    let field_node = node.child_by_field_name(field)?;
    let first = if field_node.kind() == "arguments" {
        field_node.named_child(0)
    } else {
        Some(field_node)
    }?;

    if first.kind() != "string" {
        return None;
    }

    Some(unquote(&text(first, source)))
}

fn children_by_field<'a>(node: Node<'a>, field: &str) -> Vec<Node<'a>> {
    let mut cursor = node.walk();
    let children: Vec<Node> = node
        .children_by_field_name(field, &mut cursor)
        .collect();
    children
}

fn walk<'a, F: FnMut(Node<'a>)>(node: Node<'a>, visit: &mut F) {
    visit(node);
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        walk(child, visit);
    }
}

fn text<'a>(node: Node<'_>, source: &'a str) -> &'a str {
    node.utf8_text(source.as_bytes()).unwrap_or("")
}

/// `"a/b"` reads as `a/b`.
fn unquote(literal: &str) -> String {
    let inner = literal
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
        .or_else(|| {
            literal
                .strip_prefix('\'')
                .and_then(|rest| rest.strip_suffix('\''))
        })
        .unwrap_or(literal);

    inner.replace("\\\"", "\"").replace("\\\\", "\\")
}
