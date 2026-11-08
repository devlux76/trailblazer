//! Small helpers over tree-sitter nodes and string literals.

use tree_sitter::Node;

pub(crate) fn string_argument(node: Node, field: &str, source: &str) -> Option<String> {
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

pub(crate) fn children_by_field<'a>(node: Node<'a>, field: &str) -> Vec<Node<'a>> {
    let mut cursor = node.walk();
    let children: Vec<Node> = node
        .children_by_field_name(field, &mut cursor)
        .collect();
    children
}

pub(crate) fn walk<'a, F: FnMut(Node<'a>)>(node: Node<'a>, visit: &mut F) {
    visit(node);
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        walk(child, visit);
    }
}

pub(crate) fn text<'a>(node: Node<'_>, source: &'a str) -> &'a str {
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
