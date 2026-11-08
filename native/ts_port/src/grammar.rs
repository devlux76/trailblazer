//! The tree-sitter grammars and the queries that read them, per language.

use tree_sitter::{Language, Query};

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

pub(crate) struct Grammar {
    pub(crate) language: Language,
    pub(crate) queries: Vec<Query>,
}

// Query compilation is independent of the file. The Port serves many files;
// compile each language once, sharing only immutable queries between parses.
pub(crate) fn compiled_grammar(lang: &str) -> Result<&'static Grammar, String> {
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
pub(crate) fn definition_kind(capture: &str) -> Option<&'static str> {
    match capture.strip_prefix("definition.") {
        Some("class") => Some("class"),
        Some("function") => Some("function"),
        Some("method") => Some("method"),
        Some("module") => Some("module"),
        Some("type") => Some("type"),
        _ => None,
    }
}
