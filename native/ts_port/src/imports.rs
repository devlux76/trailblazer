//! Imports, read from the tree: a module specifier and the names it brings in.

use tree_sitter::Node;

use crate::helpers::{children_by_field, string_argument, text, walk};

pub(crate) struct Import {
    pub(crate) spec: String,
    pub(crate) names: Vec<Binding>,
    pub(crate) line: usize,
    pub(crate) start_byte: usize,
}

/// A name an import brings in: the name the module exports it by, and the name
/// it is called by here, if it is called anything here (a re-export is not).
pub(crate) struct Binding {
    pub(crate) exported: String,
    pub(crate) local: Option<String>,
}

impl Binding {
    fn same(name: String) -> Self {
        Binding {
            local: Some(name.clone()),
            exported: name,
        }
    }
}

/// Imports are read from the tree, because the tags queries do not carry them.
pub(crate) fn imports(root: Node, source: &str, lang: &str) -> Vec<Import> {
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
