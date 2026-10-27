//! `herdr-tui ls` and `kill` against an empty, private HOME: no agent is ever started here.

use std::process::{Command, Output};

fn run(home: &std::path::Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_herdr-tui"))
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("HERDR_MOBILE_NO_PANE", "1")
        .output()
        .expect("run herdr-tui")
}

#[test]
fn ls_on_a_machine_with_no_sessions_says_how_to_start() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["ls"]);
    assert!(out.status.success(), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("Start one with `herdr-tui`"));
}

#[test]
fn killing_a_session_that_does_not_exist_fails_and_says_which() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["kill", "zzz999"]);
    assert!(!out.status.success(), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("zzz999"),
        "{out:?}"
    );
}

#[test]
fn kill_without_an_id_is_a_usage_error_not_a_bulk_kill() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["kill"]);
    assert_eq!(out.status.code(), Some(64), "{out:?}");
}
