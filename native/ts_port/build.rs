//! The grammars are C, compiled with whatever the cc crate is given. On this
//! machine that is Intel's icx, on purpose: it makes faster binaries. icx calls
//! its own memcpy and memset (`_intel_fast_memcpy`, `_intel_fast_memset`),
//! which live in Intel's libirc, so a build with it links libirc, statically,
//! and the Port needs nothing from oneAPI to run. Any other compiler needs
//! nothing here.

use std::env;
use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CC");

    let Some(compiler) = env::var_os("CC").map(PathBuf::from) else {
        return;
    };

    if !is_intel(&compiler) {
        return;
    }

    // icx sits in <oneapi>/compiler/<version>/bin and its libraries in ../lib;
    // a bare `icx` is looked up on PATH first
    let resolved = if compiler.components().count() > 1 {
        Some(compiler)
    } else {
        on_path(&compiler)
    };

    let archive = resolved
        .and_then(|path| path.canonicalize().ok())
        .and_then(|path| path.parent()?.parent().map(|dir| dir.join("lib/libirc.a")))
        .filter(|archive| archive.is_file());

    // A link argument, not a link library: rustc puts a package's libraries
    // before its dependencies' archives, and the tree-sitter archives are the
    // ones that need libirc, so it has to come after them, at the end.
    match archive {
        Some(archive) => println!("cargo:rustc-link-arg={}", archive.display()),
        None => println!("cargo:warning=CC is Intel's ({}) but libirc.a was not found next to it", compiler_name()),
    }
}

fn compiler_name() -> String {
    env::var("CC").unwrap_or_default()
}

fn is_intel(compiler: &Path) -> bool {
    compiler
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| ["icx", "icpx", "icc"].iter().any(|prefix| name.starts_with(prefix)))
}

fn on_path(name: &Path) -> Option<PathBuf> {
    env::split_paths(&env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}
