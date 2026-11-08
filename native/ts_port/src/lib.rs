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
use tree_sitter::{Node, Parser, QueryCursor, StreamingIterator};

mod definitions;
mod grammar;
mod helpers;
mod imports;
mod scopes;

use definitions::{Raw, Ref, attach, qualify, surviving_definitions};
use grammar::{compiled_grammar, definition_kind};
use helpers::text;
use imports::imports;

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
