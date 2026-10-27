//! The Rust replay log against the python one, on the same seeded random
//! sessions. `tool/gen-replay-fixtures.py` runs the python reference
//! (`ReplayLog` in `keeper_script.dart`) and records every step; this replays the
//! operations and compares counters after each step, then every entry (message
//! and size) in replay order, and the replays from a few `since` points.
//!
//! Skipped, with a message, when python3 is not installed.

use keeper::replay_log::ReplayLog;
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;
use std::process::Command;

fn generate() -> Option<Vec<Value>> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let out = std::env::temp_dir().join(format!("herdr-replay-{}.json", std::process::id()));
    let status = Command::new("python3")
        .arg(root.join("tool/gen-replay-fixtures.py"))
        .arg(&out)
        .status()
        .ok()?;
    assert!(status.success(), "the python reference failed");
    let raw = std::fs::read(&out).expect("the generator wrote its output");
    let _ = std::fs::remove_file(&out);
    Some(serde_json::from_slice(&raw).expect("the generator wrote JSON"))
}

fn stat(log: &ReplayLog) -> Value {
    serde_json::json!({
        "bytes": log.bytes(), "count": log.count(), "dropped": log.dropped(),
        "trimmed": log.trimmed(), "turns": log.turn_count(), "next_seq": log.next_seq(),
    })
}

#[test]
fn the_rust_log_makes_the_same_decisions_as_the_python_one() {
    let Some(scenarios) = generate() else {
        eprintln!("python3 not found: differential test skipped");
        return;
    };
    assert!(scenarios.len() >= 50);
    for sc in &scenarios {
        let seed = &sc["seed"];
        let p = &sc["params"];
        let n = |k: &str| usize::try_from(p[k].as_u64().expect("a number")).expect("fits");
        let mut log = ReplayLog::new(
            n("max_bytes"),
            n("max_entries"),
            p["full_turns"].as_u64().expect("number"),
            p["soft_bytes"]
                .as_u64()
                .map(|s| usize::try_from(s).expect("fits")),
        );
        let mut ids: Vec<Option<u64>> = Vec::new();
        for (i, (op, want)) in sc["ops"]
            .as_array()
            .expect("ops")
            .iter()
            .zip(sc["steps"].as_array().expect("steps"))
            .enumerate()
        {
            let mut expect = want.clone();
            if let Some(target) = op.get("remove") {
                let id = ids[usize::try_from(target.as_u64().expect("index")).expect("fits")]
                    .expect("an add");
                let ok = log.remove(id);
                assert_eq!(
                    Some(ok),
                    expect["removed"].as_bool(),
                    "seed {seed} op {i}: remove"
                );
                expect.as_object_mut().expect("object").remove("removed");
                ids.push(None);
            } else {
                let waiting: HashSet<String> = op["waiting"]
                    .as_array()
                    .expect("waiting")
                    .iter()
                    .filter_map(|w| w.as_str().map(str::to_string))
                    .collect();
                let size = usize::try_from(op["size"].as_u64().expect("size")).expect("fits");
                ids.push(Some(log.add(op["add"].clone(), size, || waiting)));
            }
            assert_eq!(stat(&log), expect, "seed {seed} op {i}: counters");
        }
        let got: Vec<Value> = log
            .replay(None)
            .map(|(e, seq)| serde_json::json!([e.msg, e.size, seq]))
            .collect();
        let want = sc["final"].as_array().expect("final");
        assert_eq!(got.len(), want.len(), "seed {seed}: entries held");
        for (k, (g, w)) in got.iter().zip(want).enumerate() {
            assert_eq!(g, w, "seed {seed}: entry {k}");
        }
        for (since, want) in sc["since"].as_object().expect("since") {
            let from: u64 = since.parse().expect("a number");
            let got: Vec<Value> = log
                .replay(Some(from))
                .map(|(e, seq)| serde_json::json!([e.msg, seq]))
                .collect();
            assert_eq!(
                &Value::Array(got),
                want,
                "seed {seed}: replay since {since}"
            );
        }
    }
}
