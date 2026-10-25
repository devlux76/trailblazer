use serde_json::Value;

fn parse(lang: &str, source: &str) -> Value {
    ts_port::parse(lang, "web/app.js", source).expect("parses")
}

fn nodes(parsed: &Value) -> Vec<Value> {
    parsed["nodes"].as_array().expect("nodes").clone()
}

fn qualified(parsed: &Value) -> Vec<String> {
    nodes(parsed)
        .iter()
        .map(|node| node["qualified"].as_str().unwrap().to_string())
        .collect()
}

fn expect_qualified(expected: &[&str], parsed: &Value) {
    assert_eq!(
        expected,
        qualified(parsed).iter().map(String::as_str).collect::<Vec<_>>()
    );
}

fn refs(parsed: &Value) -> Vec<(String, String)> {
    parsed["refs"]
        .as_array()
        .expect("refs")
        .iter()
        .map(|entry| {
            (
                entry["kind"].as_str().unwrap().to_string(),
                entry["target"].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

#[test]
fn javascript_definitions() {
    let parsed = parse(
        "javascript",
        "class Store {\n  put(hike) { return hike; }\n}\nfunction saveHikes(hikes) {}\n",
    );

    expect_qualified(&["Store", "Store.put", "saveHikes"], &parsed);
    assert_eq!("class", nodes(&parsed)[0]["kind"].as_str().unwrap());
    assert_eq!("method", nodes(&parsed)[1]["kind"].as_str().unwrap());
    assert_eq!("function", nodes(&parsed)[2]["kind"].as_str().unwrap());
    assert_eq!("javascript:function:web/app.js#saveHikes", nodes(&parsed)[2]["key"].as_str().unwrap());
    assert_eq!(4, nodes(&parsed)[2]["start_line"].as_u64().unwrap());
}

#[test]
fn javascript_calls_carry_the_bare_name() {
    let parsed = parse("javascript", "function go() {\n  saveHikes([]);\n}\n");

    assert!(refs(&parsed).contains(&("calls".to_string(), "saveHikes".to_string())));
}

#[test]
fn typescript_imports() {
    let parsed = parse(
        "typescript",
        "import { saveHikes } from \"./save\";\n\nexport function renderList(hikes: string[]): string {\n  saveHikes(hikes);\n  return hikes.join(\", \");\n}\n",
    );

    let found = refs(&parsed);

    assert!(found.contains(&("imports".to_string(), "./save".to_string())), "{found:?}");
    assert!(
        found.contains(&("references".to_string(), "./save#saveHikes".to_string())),
        "{found:?}"
    );
    expect_qualified(&["renderList"], &parsed);
}

#[test]
fn typescript_shorthand_imports() {
    let parsed = parse(
        "typescript",
        "import Store from \"./store\";\nimport * as Vectors from \"./vectors\";\nconst x = require(\"./legacy\");\nconst y = import(\"./lazy\");\n",
    );

    let found = refs(&parsed);

    for specifier in ["./store", "./vectors", "./legacy", "./lazy"] {
        assert!(
            found.contains(&("imports".to_string(), specifier.to_string())),
            "{specifier} missing from {found:?}"
        );
    }

    // A default import refers to the module's default export, whatever it is
    // called here; a namespace import names the module and nothing in it.
    assert!(found.contains(&("references".to_string(), "./store#default".to_string())), "{found:?}");
    assert!(!found.contains(&("references".to_string(), "./store#Store".to_string())), "{found:?}");
    assert!(
        !found.iter().any(|(kind, target)| kind == "references" && target.starts_with("./vectors#")),
        "{found:?}"
    );
}

#[test]
fn python_imports() {
    let parsed = parse(
        "python",
        "from app.store import put\n\ndef f():\n    put()\n",
    );

    expect_qualified(&["f"], &parsed);

    let found = refs(&parsed);

    assert!(found.contains(&("imports".to_string(), "app.store".to_string())), "{found:?}");
    assert!(
        found.contains(&("references".to_string(), "app.store#put".to_string())),
        "{found:?}"
    );
}

#[test]
fn python_plain_import() {
    let parsed = parse("python", "import app.store\n\napp.store.put()\n");

    assert!(refs(&parsed).contains(&("imports".to_string(), "app.store".to_string())));
}

#[test]
fn a_file_that_does_not_parse_keeps_what_came_before() {
    let parsed = parse(
        "javascript",
        "function saveHikes() {}\n\nclass Broken {\n  put( {\n",
    );

    assert!(qualified(&parsed).contains(&"saveHikes".to_string()), "{:?}", qualified(&parsed));
}

#[test]
fn a_reference_inside_a_method_comes_from_it() {
    let parsed = parse(
        "typescript",
        "class Store {\n  put(hike) {\n    return saveHikes(hike);\n  }\n}\n",
    );

    let method = nodes(&parsed)
        .into_iter()
        .find(|node| node["qualified"].as_str() == Some("Store.put"))
        .expect("the method");

    let from = parsed["refs"]
        .as_array()
        .expect("refs")
        .iter()
        .find(|entry| entry["kind"] == "calls" && entry["target"] == "saveHikes")
        .expect("the call");

    assert_eq!(method["key"], from["from_key"]);
}

#[test]
fn an_unknown_language_is_an_error() {
    assert!(ts_port::parse("ruby", "web/app.rb", "").is_err());
}

#[test]
fn redefinition_keeps_only_the_last_node_and_its_body_references() {
    for (lang, source, line) in [
        ("python", "def f():\n    old()\ndef f():\n    new()\n", 3),
        ("javascript", "function f(){ old(); }\nfunction f(){ newer(); }\n", 2),
    ] {
        let parsed = parse(lang, source);
        assert_eq!(qualified(&parsed), ["f"]);
        assert_eq!(nodes(&parsed)[0]["start_line"], line);
        let calls: Vec<_> = refs(&parsed).into_iter().filter(|(kind,_)| kind=="calls").collect();
        assert_eq!(calls, [("calls".into(), if lang=="python" {"new"} else {"newer"}.into())]);
    }
}

#[test]
fn overwritten_parent_drops_its_nested_nodes_imports_and_containment_refs() {
    let parsed = parse("python", "def f():\n    from old import thing as stale\n    def gone():\n        old()\n    gone()\ndef f():\n    new()\n");
    assert_eq!(qualified(&parsed), ["f"]);
    assert_eq!(refs(&parsed), [("calls".into(), "new".into())]);
}

#[test]
fn renamed_imports_do_not_override_javascript_parameters_or_local_declarations() {
    for declaration in [
        "function f(load) { load(); }",
        "function f(load = fallback) { load(); }",
        "function f({load}) { load(); }",
        "function f({x: load}) { load(); }",
        "function f([load]) { load(); }",
        "function f(...load) { load(); }",
        "function f() { const load = callback; load(); }",
        "function f() { let load = callback; load(); }",
        "function f() { var load = callback; load(); }",
        "function f() { function load() {} load(); }",
        "function f() { class load {} load(); }",
    ] {
        let source = format!("import {{read as load}} from \"./io\";\n{declaration}");
        let parsed = parse("javascript", &source);
        assert!(refs(&parsed).contains(&("calls".into(), "load".into())), "{source}: {parsed}");
        assert!(!refs(&parsed).contains(&("calls".into(), "./io#read".into())), "{source}: {parsed}");
    }
}

#[test]
fn a_python_function_local_import_does_not_bind_a_sibling_function() {
    let parsed = parse("python", "def a():\n    from app.store import put as save\n    save()\ndef b():\n    save()\n");
    let calls: Vec<_> = parsed["refs"].as_array().unwrap().iter()
        .filter(|r| r["kind"] == "calls")
        .map(|r| (r["from_key"].as_str().unwrap(), r["target"].as_str().unwrap()))
        .collect();
    assert_eq!(calls, [
        ("python:function:web/app.js#a", "app.store#put"),
        ("python:function:web/app.js#b", "save"),
    ]);
}

#[test]
fn python_parameters_assignments_and_nested_imports_shadow_renamed_imports() {
    for body in [
        "def f(save):\n    save()",
        "def f(save=fallback):\n    save()",
        "def f(*save):\n    save()",
        "def f(**save):\n    save()",
        "def f():\n    save = callback\n    save()",
        "def f():\n    a, save = callbacks\n    save()",
        "def f():\n    import other as save\n    save()",
        "def f():\n    from other import save\n    save()",
    ] {
        let source = format!("from app.store import put as save\n{body}\n");
        let parsed = parse("python", &source);
        assert!(refs(&parsed).contains(&("calls".into(), "save".into())), "{source}: {parsed}");
        assert!(!refs(&parsed).contains(&("calls".into(), "app.store#put".into())), "{source}: {parsed}");
    }
}

#[test]
fn scoped_import_bindings_reach_nested_scopes_without_leaking_from_blocks() {
    let js = parse("javascript", "import {read as load} from './io';\nfunction f(){ {const load = cb; load();} load(); }\n");
    let targets: Vec<_> = js["refs"].as_array().unwrap().iter()
        .filter(|r| r["kind"] == "calls").map(|r| r["target"].as_str().unwrap()).collect();
    assert_eq!(targets, ["load", "./io#read"]);
    let py = parse("python", "def a():\n    from app.store import put as save\n    def b():\n        save()\n");
    assert!(refs(&py).contains(&("calls".into(), "app.store#put".into())));
}

#[test]
fn loop_bindings_and_python_as_targets_shadow_imports() {
    for body in [
        "function f(){ for (const load of callbacks) { load(); } }",
        "function f(){ for (let load in callbacks) { load(); } }",
    ] {
        let parsed = parse("javascript", &format!("import {{read as load}} from './io';\n{body}"));
        assert!(refs(&parsed).contains(&("calls".into(), "load".into())), "{body}: {parsed}");
    }
    for body in [
        "def f():\n    with context as save:\n        save()",
        "def f():\n    try:\n        pass\n    except Error as save:\n        save()",
    ] {
        let parsed = parse("python", &format!("from app.store import put as save\n{body}\n"));
        assert!(refs(&parsed).contains(&("calls".into(), "save".into())), "{body}: {parsed}");
    }
}

#[test]
fn typed_arrow_parameters_shadow_but_destructuring_keys_do_not() {
    for body in [
        "function f(load: () => void){load();}",
        "const f = (load: () => void) => load();",
        "const f = load => load();",
    ] {
        let parsed = parse("typescript", &format!("import {{read as load}} from './io';\n{body}"));
        assert!(refs(&parsed).contains(&("calls".into(), "load".into())), "{body}: {parsed}");
    }
    let parsed = parse("javascript", "import {read as load} from './io';\nfunction f({load: other}){load();}");
    assert!(refs(&parsed).contains(&("calls".into(), "./io#read".into())));
}

#[test]
fn python_imports_that_are_not_settled_leave_the_call_bare() {
    for source in [
        "def f():\n    save()\n    from app.store import put as save\n",
        "def f():\n    if condition:\n        from app.store import put as save\n    save()\n",
        "from app.store import put as save\nfrom other import *\nsave()\n",
    ] {
        let parsed = parse("python", source);
        assert!(refs(&parsed).contains(&("calls".into(), "save".into())), "{source}: {parsed}");
        assert!(!refs(&parsed).contains(&("calls".into(), "app.store#put".into())), "{source}: {parsed}");
    }
}

fn find<'a>(parsed: &'a Value, kind: &str, target: &str) -> &'a Value {
    parsed["refs"]
        .as_array()
        .expect("refs")
        .iter()
        .find(|entry| entry["kind"] == kind && entry["target"] == target)
        .unwrap_or_else(|| panic!("no {kind} {target} in {}", parsed["refs"]))
}

#[test]
fn a_reference_after_a_definition_is_not_from_it() {
    let parsed = parse("javascript", "function done() {}\noutside();\n");

    assert_eq!(Value::Null, find(&parsed, "calls", "outside")["from_key"]);
}

#[test]
fn a_reference_after_a_nested_definition_is_from_the_outer_one() {
    let parsed = parse(
        "javascript",
        "function outer() {\n  function inner() {}\n  after();\n}\n",
    );

    assert_eq!(
        "javascript:function:web/app.js#outer",
        find(&parsed, "calls", "after")["from_key"]
    );
}

#[test]
fn typescript_definitions_come_in_source_order() {
    let parsed = parse(
        "typescript",
        "class A { a() { x(); } }\ninterface I { m(): void }\nclass B { b() { y(); } }\n",
    );

    let names = qualified(&parsed);
    let a = names.iter().position(|name| name == "A").expect("A");
    let m = names.iter().position(|name| name == "I.m").or_else(|| names.iter().position(|name| name == "m")).expect("m");
    assert!(a < m, "{names:?}");

    let mut unique = names.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), names.len(), "duplicate definitions: {names:?}");

    assert_eq!("typescript:method:web/app.js#A.a", find(&parsed, "calls", "x")["from_key"]);
    assert_eq!("typescript:method:web/app.js#B.b", find(&parsed, "calls", "y")["from_key"]);
}

#[test]
fn an_aliased_javascript_import_refers_to_the_exported_name() {
    let parsed = parse(
        "javascript",
        "import { put as save, other as put } from \"./store\";\nsave();\nput();\n",
    );

    let found = refs(&parsed);
    assert!(found.contains(&("references".to_string(), "./store#put".to_string())), "{found:?}");
    assert!(found.contains(&("references".to_string(), "./store#other".to_string())), "{found:?}");
    assert!(!found.contains(&("references".to_string(), "./store#save".to_string())), "{found:?}");

    // a call through the local name is a call of what it is bound to
    let calls: Vec<&String> = found.iter().filter(|(kind, _)| kind == "calls").map(|(_, target)| target).collect();
    assert_eq!(vec!["./store#put", "./store#other"], calls);
}

#[test]
fn a_call_through_a_default_import_is_a_call_of_the_default_export() {
    let parsed = parse("javascript", "import Store from \"./store\";\nStore();\n");

    find(&parsed, "calls", "./store#default");
}

#[test]
fn an_aliased_python_import_refers_to_the_exported_name() {
    let parsed = parse("python", "from app.store import put as save\n\nsave()\n");

    let found = refs(&parsed);
    assert!(found.contains(&("references".to_string(), "app.store#put".to_string())), "{found:?}");
    assert!(!found.contains(&("references".to_string(), "app.store#save".to_string())), "{found:?}");
    find(&parsed, "calls", "app.store#put");
}

#[test]
fn a_python_module_alias_names_the_module_only() {
    let parsed = parse("python", "import app.store as store\n");

    let found = refs(&parsed);
    assert!(found.contains(&("imports".to_string(), "app.store".to_string())), "{found:?}");
    assert!(!found.iter().any(|(kind, _)| kind == "references"), "{found:?}");
}

#[test]
fn a_reexport_refers_to_the_exported_name() {
    let parsed = parse("javascript", "export { put as save } from \"./store\";\n");

    let found = refs(&parsed);
    assert!(found.contains(&("references".to_string(), "./store#put".to_string())), "{found:?}");
    assert!(!found.contains(&("references".to_string(), "./store#save".to_string())), "{found:?}");
}

#[test]
fn a_class_contains_its_methods_and_a_function_its_nested_functions() {
    let parsed = parse(
        "javascript",
        "class Store {\n  put() {}\n  get() {}\n}\nfunction outer() {\n  function inner() {}\n}\n",
    );

    assert_eq!("javascript:class:web/app.js#Store", find(&parsed, "contains", "Store.put")["from_key"]);
    assert_eq!("javascript:class:web/app.js#Store", find(&parsed, "contains", "Store.get")["from_key"]);
    assert_eq!("javascript:function:web/app.js#outer", find(&parsed, "contains", "outer.inner")["from_key"]);

    let contains = refs(&parsed).into_iter().filter(|(kind, _)| kind == "contains").count();
    assert_eq!(3, contains);
}

#[test]
fn namespace_members_keep_their_module_and_respect_shadowing() {
    let js = parse("typescript", "import * as IO from './io';\nfunction f(){ IO.read(); }\nfunction g(IO){ IO.read(); }\n");
    find(&js,"calls","./io#read");
    let py = parse("python", "from . import util\nimport pkg.io as IO\ndef f():\n util.read()\n IO.write()\n");
    find(&py,"calls",".util#read");
    find(&py,"calls","pkg.io#write");
}

#[test]
fn constructors_and_type_annotations_are_references_with_constructor_ownership() {
    let parsed = parse("typescript", "import {FireState} from './fireRules';\nclass Camp {\n state: FireState;\n constructor(){\n  this.state = new FireState();\n  setup();\n }\n}\n");
    assert!(qualified(&parsed).contains(&"Camp.constructor".to_string()));
    assert_eq!(find(&parsed,"calls","FireState")["from_key"],"typescript:method:web/app.js#Camp.constructor");
    assert_eq!(find(&parsed,"calls","setup")["from_key"],"typescript:method:web/app.js#Camp.constructor");
    find(&parsed,"references","FireState");
}
