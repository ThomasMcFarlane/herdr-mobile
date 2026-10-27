//! A picture on the clipboard (a screenshot): a terminal cannot paste one, only text, so the
//! picture is read with the tool the system has for it (`wl-paste`, `xclip`, `pngpaste`), saved
//! in the host inbox the phone's attachments use (`<home>/.herdr-mobile/inbox/`, folders 0700,
//! files 0600) and attached like any file.
//!
//! The reading runs on a thread of the caller's choosing: a clipboard tool that hangs (a dead
//! compositor) must not hold the screen. Every tool is given [`TIMEOUT`].

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// How long one tool may take.
pub const TIMEOUT: Duration = Duration::from_secs(4);

/// The most bytes read from the clipboard: a retina screenshot is a few MB, nothing is 32.
pub const MAX_BYTES: usize = 32 * 1024 * 1024;

/// A program that can say what the clipboard holds and write it out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tool {
    pub program: String,
    /// Arguments that list the types on the clipboard, one per line; none when the tool only
    /// writes PNG.
    pub list: Vec<String>,
    /// Arguments that write the picture of type `{mime}` to standard output.
    pub get: Vec<String>,
}

fn tool(program: &str, list: &[&str], get: &[&str]) -> Tool {
    Tool {
        program: program.to_string(),
        list: list.iter().map(|s| (*s).to_string()).collect(),
        get: get.iter().map(|s| (*s).to_string()).collect(),
    }
}

/// The tools to try, in order: Wayland, X11, macOS.
#[must_use]
pub fn tools() -> Vec<Tool> {
    vec![
        tool("wl-paste", &["--list-types"], &["--type", "{mime}"]),
        tool(
            "xclip",
            &["-selection", "clipboard", "-t", "TARGETS", "-o"],
            &["-selection", "clipboard", "-t", "{mime}", "-o"],
        ),
        tool("pngpaste", &[], &["-"]),
    ]
}

/// The picture types read, best first: the MIME type and the file extension.
const TYPES: [(&str, &str); 4] = [
    ("image/png", "png"),
    ("image/jpeg", "jpg"),
    ("image/webp", "webp"),
    ("image/gif", "gif"),
];

/// The first picture type a listing of the clipboard's types offers.
#[must_use]
pub fn pick_type(listing: &str) -> Option<(&'static str, &'static str)> {
    TYPES
        .iter()
        .find(|(mime, _)| listing.lines().any(|l| l.trim() == *mime))
        .copied()
}

/// Whether `bytes` start the way a file of extension `ext` does: what a tool wrote is checked
/// before it is saved and sent as a picture.
#[must_use]
pub fn looks_like(ext: &str, bytes: &[u8]) -> bool {
    match ext {
        "png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "jpg" => bytes.starts_with(&[0xff, 0xd8, 0xff]),
        "gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        "webp" => bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP",
        _ => false,
    }
}

/// Why nothing was read, in the person's words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Nothing {
    /// None of the tools is installed.
    NoTool,
    /// A tool answered, and the clipboard holds no picture.
    NoPicture,
    /// The picture is bigger than [`MAX_BYTES`].
    TooBig,
    /// The picture could not be saved.
    Save(String),
}

impl Nothing {
    #[must_use]
    pub fn say(&self) -> String {
        match self {
            Nothing::NoTool => {
                "To paste a picture, install wl-clipboard, xclip or pngpaste (or paste its path)"
                    .to_string()
            }
            Nothing::NoPicture => {
                "No picture on the clipboard (copy one first, or paste a path)".to_string()
            }
            Nothing::TooBig => "The picture on the clipboard is over 32 MB".to_string(),
            Nothing::Save(why) => format!("Could not save the picture: {why}"),
        }
    }
}

enum Run {
    Missing,
    Failed,
    TooBig,
    Out(Vec<u8>),
}

/// Runs `program`, reads at most `limit` bytes of its standard output, and gives up on it after
/// [`TIMEOUT`] (the child is ours, so it is the one killed).
fn run(program: &str, args: &[String], limit: usize) -> Run {
    let mut child = match Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Run::Missing,
        Err(_) => return Run::Failed,
    };
    let Some(out) = child.stdout.take() else {
        let _ = child.kill();
        return Run::Failed;
    };
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = out.take(limit as u64 + 1).read_to_end(&mut bytes);
        bytes
    });
    let started = Instant::now();
    let ok = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Ok(None) if started.elapsed() < TIMEOUT => {
                std::thread::sleep(Duration::from_millis(10));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let bytes = reader.join().unwrap_or_default();
    if bytes.len() > limit {
        // Over the limit: the reader stopped, and the child, blocked on its pipe, was killed above
        // or finished; either way what was read is not the picture.
        let _ = child.kill();
        return Run::TooBig;
    }
    if ok {
        Run::Out(bytes)
    } else {
        Run::Failed
    }
}

/// A new file name in `dir`: `clipboard-<seconds>-<n>.<ext>`, unique within this program's run.
fn file_name(ext: &str, n: usize) -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    format!("clipboard-{secs}-{n}.{ext}")
}

static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);

/// Writes `bytes` as a new owner-only file in `dir` (made owner-only if it is new).
fn save(dir: &Path, ext: &str, bytes: &[u8]) -> Result<PathBuf, String> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| e.to_string())?;
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let path = dir.join(file_name(ext, n));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .map_err(|e| e.to_string())?;
    file.write_all(bytes).map_err(|e| e.to_string())?;
    Ok(path)
}

/// Reads the picture on the clipboard with the first of `tools` that has one and saves it in
/// `dir`.
///
/// # Errors
/// Why there is no picture to attach.
pub fn read(tools: &[Tool], dir: &Path) -> Result<PathBuf, Nothing> {
    let mut found_tool = false;
    for t in tools {
        let kind = if t.list.is_empty() {
            Some(TYPES[0])
        } else {
            match run(&t.program, &t.list, 64 * 1024) {
                Run::Missing => continue,
                Run::Out(listing) => {
                    found_tool = true;
                    pick_type(&String::from_utf8_lossy(&listing))
                }
                Run::Failed | Run::TooBig => {
                    found_tool = true;
                    None
                }
            }
        };
        let Some((mime, ext)) = kind else { continue };
        let args: Vec<String> = t.get.iter().map(|a| a.replace("{mime}", mime)).collect();
        match run(&t.program, &args, MAX_BYTES) {
            Run::Missing => {}
            Run::TooBig => return Err(Nothing::TooBig),
            Run::Failed => found_tool = true,
            Run::Out(bytes) => {
                found_tool = true;
                if looks_like(ext, &bytes) {
                    return save(dir, ext, &bytes).map_err(Nothing::Save);
                }
            }
        }
    }
    Err(if found_tool {
        Nothing::NoPicture
    } else {
        Nothing::NoTool
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\nrest";

    /// A tool that is a shell script: lists `types`, writes `body` for a get.
    fn fake(dir: &Path, name: &str, types: &str, body: &[u8]) -> Tool {
        use std::os::unix::fs::PermissionsExt;
        let data = dir.join(format!("{name}.bin"));
        std::fs::write(&data, body).expect("write");
        let script = dir.join(name);
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nif [ \"$1\" = list ]; then printf '{types}'; else cat '{}'; fi\n",
                data.display()
            ),
        )
        .expect("write");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        Tool {
            program: script.to_string_lossy().into_owned(),
            list: vec!["list".into()],
            get: vec!["get".into(), "{mime}".into()],
        }
    }

    #[test]
    fn the_best_picture_type_on_the_clipboard_is_chosen() {
        assert_eq!(
            pick_type("text/plain\nimage/jpeg\nimage/png\n"),
            Some(("image/png", "png"))
        );
        assert_eq!(
            pick_type("image/gif\nTARGETS\n"),
            Some(("image/gif", "gif"))
        );
        assert_eq!(pick_type("text/plain\ntext/html\n"), None);
        assert_eq!(
            pick_type("x-image/png\n"),
            None,
            "a whole line, not a part of one"
        );
    }

    #[test]
    fn what_a_tool_wrote_is_saved_only_when_it_starts_like_the_picture_it_says_it_is() {
        assert!(looks_like("png", PNG) && !looks_like("png", b"<html>"));
        assert!(looks_like("jpg", &[0xff, 0xd8, 0xff, 0xe0]));
        assert!(looks_like("gif", b"GIF89a...") && looks_like("webp", b"RIFF\0\0\0\0WEBPVP8 "));
        assert!(!looks_like("exe", PNG));
    }

    #[test]
    fn a_picture_on_the_clipboard_is_saved_in_the_inbox_for_the_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("tempdir");
        let inbox = dir.path().join("inbox/tui-x");
        let t = fake(dir.path(), "paste", "text/plain\\nimage/png\\n", PNG);
        let path = read(&[t], &inbox).expect("saved");
        assert_eq!(std::fs::read(&path).expect("read"), PNG);
        assert!(path.starts_with(&inbox) && path.extension().is_some_and(|e| e == "png"));
        let mode = |p: &Path| std::fs::metadata(p).expect("meta").permissions().mode() & 0o777;
        assert_eq!((mode(&inbox), mode(&path)), (0o700, 0o600));
        let two = read(&[fake(dir.path(), "paste2", "image/png\\n", PNG)], &inbox).expect("again");
        assert_ne!(path, two, "a second screenshot is a second file");
    }

    #[test]
    fn nothing_to_paste_says_which_of_three_things_is_wrong() {
        let dir = tempfile::tempdir().expect("tempdir");
        let inbox = dir.path().join("inbox");
        let missing = Tool {
            program: "/definitely/not/a/tool".into(),
            list: vec!["x".into()],
            get: vec![],
        };
        assert_eq!(
            read(std::slice::from_ref(&missing), &inbox),
            Err(Nothing::NoTool)
        );
        let text_only = fake(dir.path(), "t", "text/plain\\n", b"hi");
        assert_eq!(
            read(&[missing.clone(), text_only], &inbox),
            Err(Nothing::NoPicture)
        );
        let liar = fake(dir.path(), "l", "image/png\\n", b"<html>not a png");
        assert_eq!(
            read(&[liar], &inbox),
            Err(Nothing::NoPicture),
            "bytes that are not a picture"
        );
        assert!(
            !inbox.exists(),
            "nothing is made when there is nothing to save"
        );
        let good = fake(dir.path(), "g", "image/png\\n", PNG);
        assert!(
            read(&[missing, good], &inbox).is_ok(),
            "the next tool is tried"
        );
    }
}
