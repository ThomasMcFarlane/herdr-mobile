//! Bakes the keeper (python, one source shared with the phone app) into the binary, with the
//! agent table filled in, so a machine needs no checkout of this repository to run sessions.
//! Same extraction as `tool/install-keeper.sh`.

use std::{env, fs, path::PathBuf};

fn main() {
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
