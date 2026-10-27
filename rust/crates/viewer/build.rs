//! Bakes the keeper (python, one source shared with the phone app) into the binary, with the
//! agent table filled in, so a machine needs no checkout of this repository to run sessions.
//! Same extraction as `tool/install-keeper.sh`.

use std::{env, fs, path::PathBuf};

fn main() {
    release_version();
    bake_keeper();
}

/// The binary reports the release's version (the app's `version:` in pubspec.yaml), because a
/// release is one number for the app and for herdr-tui; the crate's own 0.1.0 means nothing to
/// the person running `herdr-tui --version`.
fn release_version() {
    let pubspec =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"))
            .join("../../../app/pubspec.yaml");
    println!("cargo:rerun-if-changed={}", pubspec.display());
    let text =
        fs::read_to_string(&pubspec).unwrap_or_else(|e| panic!("{}: {e}", pubspec.display()));
    let version = text
        .lines()
        .find_map(|l| l.strip_prefix("version: "))
        .and_then(|v| v.split('+').next())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .expect("pubspec.yaml has a `version: x.y.z+n` line");
    println!("cargo:rustc-env=HERDR_TUI_VERSION={version}");
}

fn bake_keeper() {
    let dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"));
    let dart = dir.join("../../../app/lib/data/services/keeper_script.dart");
    let routes = dir.join("../keeper/routes.json");
    println!("cargo:rerun-if-changed={}", dart.display());
    println!("cargo:rerun-if-changed={}", routes.display());

    let text = fs::read_to_string(&dart).unwrap_or_else(|e| panic!("{}: {e}", dart.display()));
    let start = "const keeperPython = r'''\n";
    let body = text
        .split_once(start)
        .and_then(|(_, rest)| rest.rsplit_once("\n''';"))
        .map(|(body, _)| body)
        .expect("keeper_script.dart holds `const keeperPython = r'''...''';`");
    let table: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&routes).expect("read routes.json"))
            .expect("routes.json is JSON");
    assert!(
        body.contains("@@ROUTES@@"),
        "the keeper has a place for the agent table"
    );
    let script = body.replace("@@ROUTES@@", &table.to_string()) + "\n";
    let out = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR")).join("keeper.py");
    fs::write(out, script).expect("write keeper.py");
}
