//! The command line.

/// The release this binary belongs to (the app's version), set by build.rs.
pub const VERSION: &str = env!("HERDR_TUI_VERSION");

pub const USAGE: &str = "\
herdr-tui: work with a coding agent in the terminal, as a herdr session

usage:
  herdr-tui [--agent ID] [--cwd DIR]   start a new session (agent: omp, claude, codex, pi; default omp)
  herdr-tui attach ID                  open a session that is already running
  herdr-tui ls [--all]                 list the sessions on this machine, what needs you first
  herdr-tui kill ID...                 end sessions for good (the agent and its keeper)
  herdr-tui update [--check] [VERSION] install the latest release, or VERSION (0.1.30; older too)
  herdr-tui --help | --version

A session keeps running when you leave it (Ctrl-D), and shows on your phone. Reopen it with
`herdr-tui attach ID`; the id is printed when you leave.";

#[derive(Debug, PartialEq, Eq)]
pub enum Cmd {
    New {
        agent: String,
        cwd: Option<String>,
    },
    Attach {
        id: String,
    },
    /// Print the sessions on this machine; `all` includes the ones that have exited.
    Ls {
        all: bool,
    },
    Kill {
        ids: Vec<String>,
    },
    /// Replace this program with the latest release, or with `version` (an older one too), or
    /// only say whether that would change anything.
    Update {
        check: bool,
        version: Option<String>,
    },
    Help,
    Version,
}

/// Parses the arguments after the program name.
///
/// # Errors
/// A sentence saying what is wrong.
pub fn parse<I: IntoIterator<Item = String>>(args: I) -> Result<Cmd, String> {
    let mut args = args.into_iter();
    let mut agent = None;
    let mut cwd = None;
    while let Some(a) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        match a.as_str() {
            "-h" | "--help" => return Ok(Cmd::Help),
            "-V" | "--version" => return Ok(Cmd::Version),
            "-a" | "--agent" => agent = Some(value("--agent")?),
            "-C" | "--cwd" => cwd = Some(value("--cwd")?),
            "ls" => {
                let rest: Vec<String> = args.by_ref().collect();
                return match rest.as_slice() {
                    [] => Ok(Cmd::Ls { all: false }),
                    [flag] if flag == "--all" => Ok(Cmd::Ls { all: true }),
                    _ => Err("ls takes only --all".to_string()),
                };
            }
            "kill" => {
                let ids: Vec<String> = args.by_ref().collect();
                if ids.is_empty() {
                    return Err("kill needs a session id (see `herdr-tui ls`)".to_string());
                }
                if let Some(bad) = ids.iter().find(|i| !keeper::records::is_valid_id(i)) {
                    return Err(format!("{bad:?} is not a session id"));
                }
                return Ok(Cmd::Kill { ids });
            }
            "update" => {
                let mut check = false;
                let mut version = None;
                for a in args.by_ref() {
                    if a == "--check" && !check {
                        check = true;
                    } else if version.is_none() && crate::update::version_of(&a).is_some() {
                        version = Some(a);
                    } else {
                        return Err(format!(
                            "update takes --check and a version like 0.1.30, not {a:?}"
                        ));
                    }
                }
                return Ok(Cmd::Update { check, version });
            }
            "attach" => {
                let id = value("attach")?;
                if !keeper::records::is_valid_id(&id) {
                    return Err(format!("{id:?} is not a session id"));
                }
                return if args.next().is_some() || agent.is_some() || cwd.is_some() {
                    Err("attach takes only an id".to_string())
                } else {
                    Ok(Cmd::Attach { id })
                };
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    Ok(Cmd::New {
        agent: agent.unwrap_or_else(|| "omp".to_string()),
        cwd,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Result<Cmd, String> {
        parse(args.iter().map(|s| (*s).to_string()))
    }

    #[test]
    fn update_takes_a_check_flag_and_a_version_in_either_form_and_nothing_else() {
        assert_eq!(
            p(&["update"]),
            Ok(Cmd::Update {
                check: false,
                version: None
            })
        );
        assert_eq!(
            p(&["update", "--check", "v0.1.30"]),
            Ok(Cmd::Update {
                check: true,
                version: Some("v0.1.30".into())
            })
        );
        assert_eq!(
            p(&["update", "0.1.30"]),
            Ok(Cmd::Update {
                check: false,
                version: Some("0.1.30".into())
            })
        );
        assert!(p(&["update", "latest"]).is_err());
        assert!(p(&["update", "0.1.30", "0.1.31"]).is_err());
    }

    #[test]
    fn no_arguments_starts_omp_here() {
        assert_eq!(
            p(&[]),
            Ok(Cmd::New {
                agent: "omp".into(),
                cwd: None
            })
        );
    }

    #[test]
    fn an_agent_and_a_folder_can_be_chosen_in_either_form() {
        assert_eq!(
            p(&["--agent", "claude", "-C", "/w"]),
            Ok(Cmd::New {
                agent: "claude".into(),
                cwd: Some("/w".into())
            })
        );
        assert_eq!(
            p(&["-a", "pi"]),
            Ok(Cmd::New {
                agent: "pi".into(),
                cwd: None
            })
        );
    }

    #[test]
    fn attach_takes_one_valid_id_and_nothing_else() {
        assert_eq!(
            p(&["attach", "abc123"]),
            Ok(Cmd::Attach {
                id: "abc123".into()
            })
        );
        assert!(p(&["attach"]).is_err());
        assert!(p(&["attach", "../etc"]).is_err());
        assert!(p(&["--agent", "omp", "attach", "abc123"]).is_err());
        assert!(p(&["attach", "abc123", "extra"]).is_err());
    }

    #[test]
    fn it_reports_the_release_version_the_app_has() {
        let pubspec = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../app/pubspec.yaml"
        ))
        .expect("pubspec");
        let line = pubspec
            .lines()
            .find(|l| l.starts_with("version: "))
            .expect("version line");
        assert!(
            line.starts_with(&format!("version: {VERSION}+")),
            "{line} vs {VERSION}"
        );
    }

    #[test]
    fn ls_takes_at_most_all_and_kill_takes_ids_and_only_ids() {
        assert_eq!(p(&["ls"]), Ok(Cmd::Ls { all: false }));
        assert_eq!(p(&["ls", "--all"]), Ok(Cmd::Ls { all: true }));
        assert!(p(&["ls", "--nope"]).is_err() && p(&["ls", "--all", "x"]).is_err());
        assert_eq!(
            p(&["kill", "abc123", "def456"]),
            Ok(Cmd::Kill {
                ids: vec!["abc123".into(), "def456".into()]
            })
        );
        assert!(
            p(&["kill"]).is_err(),
            "no id, no kill: never a bulk action by default"
        );
        assert!(p(&["kill", "../etc"]).is_err() && p(&["kill", "abc123", "BAD"]).is_err());
    }

    #[test]
    fn help_version_and_mistakes() {
        assert_eq!(p(&["--help"]), Ok(Cmd::Help));
        assert_eq!(p(&["-V"]), Ok(Cmd::Version));
        assert!(p(&["--agent"]).is_err());
        assert!(p(&["--nope"]).is_err());
    }
}
