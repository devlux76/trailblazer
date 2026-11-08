//! Definitions and references: the qualified keys, what a definition is
//! nested in, which definitions survive a re-definition, and what each
//! reference is attached to.

use serde_json::Value;

pub(crate) struct Definition {
    pub(crate) kind: String,
    pub(crate) name: String,
    pub(crate) qualified: String,
    pub(crate) key: String,
    pub(crate) start_line: usize,
    pub(crate) end_line: usize,
    pub(crate) start_byte: usize,
    pub(crate) end_byte: usize,
}

pub(crate) struct Raw {
    pub(crate) kind: String,
    pub(crate) name: String,
    pub(crate) bare: bool,
    pub(crate) start_byte: usize,
    pub(crate) end_byte: usize,
    pub(crate) start_line: usize,
    pub(crate) end_line: usize,
}

/// The last definition of a key wins. Children of an overwritten definition
/// go with it, even when their own keys did not occur in the replacement.
pub(crate) fn surviving_definitions(definitions: &[Definition], parents: &[Option<usize>])
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

pub(crate) struct Ref {
    pub(crate) kind: String,
    pub(crate) target: String,
    pub(crate) arity: Value,
    pub(crate) line: usize,
    pub(crate) start_byte: usize,
    pub(crate) from_key: Option<String>,
}

/// A method is qualified by its class, a nested class by the class it is in.
/// Each definition's parent, the innermost one holding it, comes back with it.
pub(crate) fn qualify(raw: Vec<Raw>, lang: &str, path: &str) -> (Vec<Definition>, Vec<Option<usize>>) {
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
pub(crate) fn attach(definitions: &[Definition], refs: &mut [Ref]) {
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
