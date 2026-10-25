// C, C++ and Go: vendored code (llama.cpp, ollama) is read like the rest.
use serde_json::Value;

fn parse(lang: &str, path: &str, source: &str) -> Value {
    ts_port::parse(lang, path, source).expect("parses")
}

fn nodes(parsed: &Value) -> Vec<(String, String, u64, u64)> {
    parsed["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| {
            (
                n["kind"].as_str().unwrap().to_string(),
                n["qualified"].as_str().unwrap().to_string(),
                n["start_line"].as_u64().unwrap(),
                n["end_line"].as_u64().unwrap(),
            )
        })
        .collect()
}

fn refs(parsed: &Value) -> Vec<(String, String, Option<String>)> {
    parsed["refs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["kind"].as_str().unwrap().to_string(),
                r["target"].as_str().unwrap().to_string(),
                r["from_key"].as_str().map(str::to_string),
            )
        })
        .collect()
}

#[test]
fn c_functions_span_their_bodies_and_calls_come_from_them() {
    let source = "#include \"ggml.h\"\n#include <stdio.h>\n\nstatic int helper(int x) {\n  return x + 1;\n}\n\nint *make(void) {\n  helper(2);\n  return 0;\n}\n\nint proto(int y);\n\ntypedef struct point { int x; } point_t;\n";
    let parsed = parse("c", "src/a.c", source);
    let found = nodes(&parsed);

    assert!(found.contains(&("function".into(), "helper".into(), 4, 6)), "{found:?}");
    // a pointer-returning function is found too, body and all
    assert!(found.contains(&("function".into(), "make".into(), 8, 11)), "{found:?}");
    // a prototype is not a definition (the header and the source would both claim it)
    assert!(!found.iter().any(|n| n.1 == "proto"), "{found:?}");
    assert!(found.iter().any(|n| n.0 == "class" && n.1 == "point"), "{found:?}");
    assert!(found.iter().any(|n| n.0 == "type" && n.1 == "point_t"), "{found:?}");

    let found = refs(&parsed);
    assert!(found.contains(&("calls".into(), "helper".into(), Some("c:function:src/a.c#make".into()))), "{found:?}");
    assert!(found.iter().any(|r| r.0 == "imports" && r.1 == "ggml.h"), "{found:?}");
    assert!(found.iter().any(|r| r.0 == "imports" && r.1 == "stdio.h"), "{found:?}");
}

#[test]
fn cpp_classes_methods_namespaces_and_calls() {
    let source = "#include \"llama.h\"\nnamespace llm {\nclass Model {\n public:\n  int eval(int n) { return step(n); }\n};\nint Model::step(int n) {\n  return helper(n) + this->eval(n);\n}\n}\n";
    let parsed = parse("cpp", "src/model.cpp", source);
    let found = nodes(&parsed);

    assert!(found.iter().any(|n| n.0 == "module" && n.1 == "llm"), "{found:?}");
    assert!(found.iter().any(|n| n.0 == "class" && n.1 == "llm.Model"), "{found:?}");
    assert!(found.iter().any(|n| n.0 == "method" && n.1 == "llm.Model.eval"), "{found:?}");
    assert!(found.iter().any(|n| n.0 == "method" && n.1.ends_with("step") && n.2 == 7 && n.3 == 9), "{found:?}");

    let calls: Vec<String> = refs(&parsed).into_iter().filter(|r| r.0 == "calls").map(|r| r.1).collect();
    assert!(calls.contains(&"step".to_string()), "{calls:?}");
    assert!(calls.contains(&"helper".to_string()), "{calls:?}");
    assert!(calls.contains(&"eval".to_string()), "{calls:?}");
}

#[test]
fn cuda_kernels_are_functions() {
    let source = "__global__ void scale(float *x, int n) {\n  int i = blockIdx.x;\n  clamp(x, i);\n}\n";
    let parsed = parse("cpp", "ggml/scale.cu", source);
    assert!(nodes(&parsed).iter().any(|n| n.0 == "function" && n.1 == "scale"), "{:?}", nodes(&parsed));
    assert!(refs(&parsed).iter().any(|r| r.0 == "calls" && r.1 == "clamp"));
}

#[test]
fn go_functions_methods_types_imports_and_calls() {
    let source = "package server\n\nimport (\n\t\"fmt\"\n\t\"github.com/ollama/ollama/api\"\n)\n\ntype Server struct{}\n\nfunc (s *Server) Serve() {\n\tfmt.Println(api.Version())\n\thelper()\n}\n\nfunc helper() {}\n";
    let parsed = parse("go", "server/server.go", source);
    let found = nodes(&parsed);

    assert!(found.iter().any(|n| n.0 == "type" && n.1 == "Server"), "{found:?}");
    assert!(found.iter().any(|n| n.0 == "method" && n.1 == "Serve"), "{found:?}");
    assert!(found.iter().any(|n| n.0 == "function" && n.1 == "helper"), "{found:?}");

    let found = refs(&parsed);
    assert!(found.iter().any(|r| r.0 == "imports" && r.1 == "fmt"), "{found:?}");
    assert!(found.iter().any(|r| r.0 == "imports" && r.1 == "github.com/ollama/ollama/api"), "{found:?}");
    assert!(found.iter().any(|r| r.0 == "calls" && r.1 == "helper"), "{found:?}");
}

#[test]
fn cpp_reference_returns_and_forward_declarations() {
    let parsed = parse("cpp", "x.cpp", "struct Forward;\nclass Model;\nint &value() {\n  return fetch();\n}\n");
    let found = nodes(&parsed);
    assert!(found.contains(&("function".into(), "value".into(), 3, 5)), "{found:?}");
    assert!(!found.iter().any(|n| n.1 == "Forward" || n.1 == "Model"), "{found:?}");
    assert!(refs(&parsed).contains(&("calls".into(), "fetch".into(), Some("cpp:function:x.cpp#value".into()))));
}

#[test]
fn unfinished_go_import_does_not_crash_or_invent_a_path() {
    let parsed = parse("go", "server.go", "package server\nimport \"");
    assert!(!refs(&parsed).iter().any(|r| r.0 == "imports"));
}
