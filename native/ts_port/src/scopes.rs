//! Lexical bindings used only to settle calls through renamed imports.
//! Locals and uncertain/repeated bindings stop lookup; they never force an
//! imported target. Scopes are recorded in source order for binary lookup.
use std::collections::HashMap;
use tree_sitter::Node;
use super::{Import, text};

struct Scope {
    start: usize,
    end: usize,
    parent: Option<usize>,
    function: bool,
    uncertain: bool,
    names: HashMap<String, Option<(String, usize)>>,
}

pub(super) struct Bindings {
    scopes: Vec<Scope>,
}

impl Bindings {
    pub(super) fn new(root: Node, source: &str, lang: &str, imports: &[Import]) -> Self {
        let mut result = Self { scopes: vec![Scope {
            start: 0, end: root.end_byte() + 1, parent: None,
            function: true, uncertain: false, names: HashMap::new(),
        }] };
        result.visit(root, 0, source, lang == "python");
        for import in imports {
            let scope = result.scope_at(import.start_byte);
            for binding in &import.names {
                if let Some(local) = &binding.local {
                    let target = (local != &binding.exported &&
                        !(lang == "python" && conditional_import(root, import.start_byte)))
                        .then(|| (format!("{}#{}", import.spec, binding.exported),
                            if lang == "python" { import.start_byte } else { 0 }));
                    result.bind(scope, local.clone(), target);
                }
            }
        }
        result
    }

    fn bind(&mut self, scope: usize, name: String, target: Option<(String, usize)>) {
        self.scopes[scope].names.entry(name)
            .and_modify(|binding| *binding = None)
            .or_insert(target);
    }

    fn pattern(&mut self, node: Node, scope: usize, source: &str) {
        match node.kind() {
            "identifier" | "shorthand_property_identifier_pattern" =>
                self.bind(scope, text(node, source).to_string(), None),
            "pair_pattern" => {
                if let Some(value) = node.child_by_field_name("value") {
                    self.pattern(value, scope, source);
                }
            }
            "assignment_pattern" | "default_parameter" | "typed_default_parameter"
                | "typed_parameter" | "required_parameter" | "optional_parameter" => {
                if let Some(left) = node.child_by_field_name("left")
                    .or_else(|| node.child_by_field_name("name"))
                    .or_else(|| node.child_by_field_name("pattern"))
                    .or_else(|| node.named_child(0)) {
                    self.pattern(left, scope, source);
                }
            }
            // Assignment to an object's field does not bind the object.
            "attribute" | "subscript" | "member_expression" | "subscript_expression" => {}
            _ => {
                let mut cursor = node.walk();
                for child in node.named_children(&mut cursor) {
                    self.pattern(child, scope, source);
                }
            }
        }
    }

    fn visit(&mut self, node: Node, parent: usize, source: &str, python: bool) {
        let kind = node.kind();
        let function = if python {
            matches!(kind, "function_definition" | "lambda")
        } else {
            matches!(kind, "function_declaration" | "function_expression" | "generator_function"
                | "generator_function_declaration" | "arrow_function" | "method_definition")
        };
        let class = matches!(kind, "class_definition" | "class_declaration" | "class");
        let declaration = matches!(kind, "function_definition" | "function_declaration"
            | "generator_function_declaration" | "class_definition" | "class_declaration");
        if declaration {
            if let Some(name) = node.child_by_field_name("name") {
                self.pattern(name, parent, source);
            }
        }
        let block = !python && matches!(kind, "statement_block" | "catch_clause"
            | "for_statement" | "for_in_statement" | "switch_body");
        let comprehension = python && matches!(kind, "list_comprehension" | "set_comprehension"
            | "dictionary_comprehension" | "generator_expression");
        let scope = if function || class || block || comprehension {
            let id = self.scopes.len();
            self.scopes.push(Scope { start: node.start_byte(), end: node.end_byte(),
                parent: Some(parent), function, uncertain: false, names: HashMap::new() });
            id
        } else { parent };
        if function || class {
            // Named function/class expressions bind only their own body.
            if !declaration {
                if let Some(name) = node.child_by_field_name("name") {
                    self.pattern(name, scope, source);
                }
            }
            if let Some(parameters) = node.child_by_field_name("parameters")
                .or_else(|| node.child_by_field_name("parameter")) {
                self.pattern(parameters, scope, source);
            }
        }
        if kind == "catch_clause" {
            if let Some(parameter) = node.child_by_field_name("parameter") {
                self.pattern(parameter, scope, source);
            }
        }
        if !python && kind == "variable_declarator" {
            let mut binding_scope = scope;
            if node.parent().is_some_and(|p| p.kind() == "variable_declaration") {
                while !self.scopes[binding_scope].function {
                    binding_scope = self.scopes[binding_scope].parent.unwrap_or(0);
                }
            }
            if let Some(name) = node.child_by_field_name("name") {
                self.pattern(name, binding_scope, source);
            }
        }
        if !python && kind == "for_in_statement" {
            let mut binding_scope = scope;
            if node.child_by_field_name("kind").is_some_and(|k| text(k, source) == "var") {
                while !self.scopes[binding_scope].function {
                    binding_scope = self.scopes[binding_scope].parent.unwrap_or(0);
                }
            }
            if let Some(left) = node.child_by_field_name("left") {
                self.pattern(left, binding_scope, source);
            }
        }
        if python && matches!(kind, "assignment" | "augmented_assignment" | "for_statement" | "for_in_clause") {
            if let Some(left) = node.child_by_field_name("left") {
                self.pattern(left, scope, source);
            }
        }
        if python && kind == "named_expression" {
            if let Some(name) = node.child_by_field_name("name") {
                self.pattern(name, scope, source);
            }
        }
        if python && matches!(kind, "as_pattern" | "except_clause") {
            if let Some(alias) = node.child_by_field_name("alias") {
                self.pattern(alias, scope, source);
            }
        }
        if python && kind == "wildcard_import" {
            self.scopes[scope].uncertain = true;
        }
        let mut cursor = node.walk();
        for child in node.named_children(&mut cursor) {
            self.visit(child, scope, source, python);
        }
    }

    fn scope_at(&self, at: usize) -> usize {
        let mut id = self.scopes.partition_point(|scope| scope.start <= at).saturating_sub(1);
        while self.scopes[id].end <= at {
            id = self.scopes[id].parent.unwrap_or(0);
        }
        id
    }

    pub(super) fn target(&self, name: &str, at: usize) -> Option<String> {
        let mut scope = self.scope_at(at);
        loop {
            if self.scopes[scope].uncertain { return None; }
            if let Some(binding) = self.scopes[scope].names.get(name) {
                return binding.as_ref().filter(|(_, available)| at >= *available)
                    .map(|(target, _)| target.clone());
            }
            scope = self.scopes[scope].parent?;
        }
    }
}

// A conditional Python import may never run. Without executing the program
// its binding is not settled, so do not force that target onto later calls.
fn conditional_import(root: Node, at: usize) -> bool {
    let mut node = root.descendant_for_byte_range(at, at + 1);
    while let Some(current) = node {
        match current.kind() {
            "if_statement" | "for_statement" | "while_statement" | "try_statement"
                | "with_statement" | "match_statement" => return true,
            "function_definition" | "class_definition" | "module" => return false,
            _ => node = current.parent(),
        }
    }
    true
}
