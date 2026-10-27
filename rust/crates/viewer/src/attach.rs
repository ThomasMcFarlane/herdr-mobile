//! Files attached to a message. A path (or several) pasted into an empty box is a file to send
//! with the message, as the phone's `@file`: a `resource_link` whose `name` is the path relative to
//! the session's folder (the absolute path when it lies outside), whose `uri` is the absolute
//! `file://` address, and with no `title` (the one form that reads well in all four adapters,
//! `docs/AGENT_SESSIONS.md`, "Pictures and files").
//!
//! Pure: whether a path is a file that exists is the caller's to check.

use acp::is_unsafe_control;
use serde_json::{json, Value};

/// Files one message carries at most.
pub const MAX_FILES: usize = 10;

/// The biggest picture sent as a picture; a bigger one goes as a link to the file (the agent
/// reads it itself), so a message never carries megabytes of encoded pixels.
pub const MAX_PICTURE_BYTES: u64 = 5 * 1024 * 1024;

/// The most picture bytes one message carries as pictures (encoded, about a third more): the
/// keeper refuses a line over 32 MiB, and the whole message is written at once. Pictures past it
/// go as links.
pub const MAX_PICTURES_TOTAL: u64 = 20 * 1024 * 1024;

/// A file to send with the next message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attachment {
    /// What the person reads and the agent is told: relative to the session's folder when inside it.
    pub name: String,
    /// Absolute `file://` address, percent-encoded.
    pub uri: String,
    /// Absolute path, to read the file when it goes as a picture.
    pub path: String,
    /// The picture type, when the file is one (by its name).
    pub picture: Option<&'static str>,
    /// Bytes in the file, when the caller has looked.
    pub size: u64,
    /// The picture's bytes, base64, read when the message is sent.
    pub data: Option<String>,
    /// Goes as a link even though it is a picture: the message already carries
    /// [`MAX_PICTURES_TOTAL`] bytes of pictures.
    pub link: bool,
}

impl Attachment {
    /// Whether this goes as a picture (an `image` block) and not as a link: it is one, it is
    /// small enough, and the agent takes pictures.
    #[must_use]
    pub fn is_picture(&self, agent_takes_pictures: bool) -> bool {
        agent_takes_pictures
            && !self.link
            && self.picture.is_some()
            && self.size <= MAX_PICTURE_BYTES
    }

    /// How it is listed above the input: its name, and `picture` when it goes as one.
    #[must_use]
    pub fn label(&self, agent_takes_pictures: bool) -> String {
        if self.is_picture(agent_takes_pictures) {
            format!("{} · picture", self.name)
        } else {
            self.name.clone()
        }
    }
}

fn picture_type(path: &str) -> Option<&'static str> {
    let ext = path.rsplit_once('.')?.1.to_ascii_lowercase();
    match ext.as_str() {
        "png" => Some("image/png"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    }
}

/// Standard base64, padded.
#[must_use]
pub fn base64(bytes: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(A[((n >> (18 - 6 * i)) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// The attachment for the absolute path `abs`, in a session whose folder is `cwd`.
#[must_use]
pub fn attachment(abs: &str, cwd: &str) -> Attachment {
    let shown = cwd
        .trim_end_matches('/')
        .is_empty()
        .then_some(abs)
        .or_else(|| abs.strip_prefix(&format!("{}/", cwd.trim_end_matches('/'))))
        .unwrap_or(abs);
    Attachment {
        // A file name can hold anything; the terminal must only ever see text.
        name: shown.chars().filter(|c| !is_unsafe_control(*c)).collect(),
        uri: format!("file://{}", percent_encode(abs)),
        path: abs.to_string(),
        picture: picture_type(abs),
        size: 0,
        data: None,
        link: false,
    }
}

/// The bytes of the file at `path`, never more than [`MAX_PICTURE_BYTES`] of them, and only when it
/// is a regular file (a pipe or a device could block the screen for good). `None` for anything
/// else, or when it has grown past the limit.
///
/// # Errors
/// The reason it could not be read.
pub fn read_picture(path: &str) -> Result<Option<Vec<u8>>, String> {
    use std::io::Read;
    // Looked at before it is opened: opening a pipe with no writer waits for one.
    if !std::fs::metadata(path)
        .map_err(|e| e.to_string())?
        .is_file()
    {
        return Ok(None);
    }
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.len() > MAX_PICTURE_BYTES {
        return Ok(None);
    }
    let mut bytes = Vec::with_capacity(usize::try_from(meta.len()).unwrap_or(0));
    file.take(MAX_PICTURE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    Ok((bytes.len() as u64 <= MAX_PICTURE_BYTES).then_some(bytes))
}

fn percent_encode(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = s.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The words of one line, as a shell reads them: split at spaces, with `'…'`, `"…"` and `\x`
/// keeping what is inside as one word (how terminals write a dropped file). `None` for a quote
/// that never closes.
fn words(line: &str) -> Option<Vec<String>> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('"'), '\\') | (None, '\\') => {
                cur.push(chars.next()?);
                in_word = true;
            }
            (Some(_), c) => cur.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                in_word = true;
            }
            (None, c) if c.is_whitespace() => {
                if in_word {
                    out.push(std::mem::take(&mut cur));
                    in_word = false;
                }
            }
            (None, c) => {
                cur.push(c);
                in_word = true;
            }
        }
    }
    if quote.is_some() {
        return None;
    }
    if in_word {
        out.push(cur);
    }
    Some(out)
}

/// The absolute paths `paste` is made of, when it is nothing else: every word of every line a
/// path (`/abs`, `~/x`, or `file:///abs`, quoted or with `\ ` as a terminal writes it). `None`
/// for anything that is text, however much of it looks like a path. `home` stands for `~`.
#[must_use]
pub fn paths_in(paste: &str, home: &str) -> Option<Vec<String>> {
    let mut paths = Vec::new();
    for line in paste.lines() {
        for word in words(line)? {
            let path = match word.strip_prefix("file://") {
                Some(rest) => percent_decode(rest.strip_prefix("localhost").unwrap_or(rest))?,
                None => match word.strip_prefix("~/") {
                    Some(rest) if !home.is_empty() => {
                        format!("{}/{rest}", home.trim_end_matches('/'))
                    }
                    _ => word,
                },
            };
            if !path.starts_with('/') || path.contains('\0') {
                return None;
            }
            paths.push(path);
        }
    }
    (!paths.is_empty()).then_some(paths)
}

/// The prompt's content blocks: the text (when there is any), then each file: a picture whose
/// bytes were read, when the agent takes pictures, else a link.
#[must_use]
pub fn blocks(text: &str, files: &[Attachment], agent_takes_pictures: bool) -> Value {
    let mut out = Vec::new();
    if !text.trim().is_empty() {
        out.push(json!({"type": "text", "text": text}));
    }
    out.extend(files.iter().map(|f| match (&f.data, f.picture) {
        (Some(data), Some(mime)) if f.is_picture(agent_takes_pictures) => {
            json!({"type": "image", "data": data, "mimeType": mime})
        }
        _ => json!({"type": "resource_link", "uri": f.uri, "name": f.name}),
    }));
    Value::Array(out)
}

/// How the message is shown in the conversation: the text, then each file on its own line.
#[must_use]
pub fn echo(text: &str, files: &[Attachment]) -> String {
    let mut out = text.to_string();
    for f in files {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push('@');
        out.push_str(&f.name);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dropped_file_is_a_path_however_the_terminal_wrote_it() {
        let h = "/home/me";
        assert_eq!(paths_in("/etc/hosts", h), Some(vec!["/etc/hosts".into()]));
        assert_eq!(
            paths_in("'/tmp/my notes.md'", h),
            Some(vec!["/tmp/my notes.md".into()])
        );
        assert_eq!(
            paths_in("/tmp/my\\ notes.md /tmp/b.rs", h),
            Some(vec!["/tmp/my notes.md".into(), "/tmp/b.rs".into()])
        );
        assert_eq!(
            paths_in("file:///tmp/a%20b.txt\r\n~/x.rs\n", h),
            Some(vec!["/tmp/a b.txt".into(), "/home/me/x.rs".into()])
        );
    }

    #[test]
    fn text_is_never_taken_for_files() {
        let h = "/home/me";
        for s in [
            "",
            "  ",
            "fix the bug",
            "/etc/hosts is wrong",
            "relative/path.rs",
            "'/unclosed",
            "/a %zz",
            "file://%zz",
            "~x",
        ] {
            assert_eq!(paths_in(s, h), None, "{s:?}");
        }
        assert_eq!(paths_in("~/x", ""), None, "no home, no ~");
    }

    #[test]
    fn a_file_is_named_from_the_sessions_folder_and_addressed_in_full() {
        let a = attachment("/w/proj/src/a b.rs", "/w/proj");
        assert_eq!(a.name, "src/a b.rs");
        assert_eq!(a.uri, "file:///w/proj/src/a%20b.rs");
        assert_eq!(attachment("/etc/hosts", "/w/proj").name, "/etc/hosts");
        assert_eq!(
            attachment("/w/projx/a", "/w/proj").name,
            "/w/projx/a",
            "a folder that merely starts with the same letters"
        );
        assert_eq!(attachment("/a", "/").name, "/a");
        assert_eq!(attachment("/a/b", "").name, "/a/b");
        assert_eq!(attachment("/w/\u{1b}[2J.rs", "/w").name, "[2J.rs");
        assert_eq!(attachment("/w/é.rs", "/w").uri, "file:///w/%C3%A9.rs");
    }

    #[test]
    fn the_prompt_is_the_text_then_the_links_and_a_message_may_be_only_files() {
        let f = attachment("/w/a.rs", "/w");
        assert_eq!(
            blocks("look", std::slice::from_ref(&f), true),
            json!([{"type": "text", "text": "look"}, {"type": "resource_link", "uri": "file:///w/a.rs", "name": "a.rs"}])
        );
        assert_eq!(
            blocks("  ", std::slice::from_ref(&f), true),
            json!([{"type": "resource_link", "uri": "file:///w/a.rs", "name": "a.rs"}])
        );
        assert_eq!(
            blocks("hi", &[], true),
            json!([{"type": "text", "text": "hi"}])
        );
        assert_eq!(echo("look", std::slice::from_ref(&f)), "look\n@a.rs");
        assert_eq!(echo("", &[f]), "@a.rs");
    }

    #[test]
    fn a_picture_goes_as_a_picture_only_when_the_agent_takes_them_and_it_is_small() {
        let mut p = attachment("/w/shot.PNG", "/w");
        assert_eq!(p.picture, Some("image/png"), "by its name, any case");
        assert_eq!(attachment("/w/a.txt", "/w").picture, None);
        p.size = 1000;
        p.data = Some(base64(b"hi"));
        assert_eq!(p.label(true), "shot.PNG · picture");
        assert_eq!(p.label(false), "shot.PNG");
        assert_eq!(
            blocks("", std::slice::from_ref(&p), true),
            json!([{"type": "image", "data": "aGk=", "mimeType": "image/png"}])
        );
        assert_eq!(
            blocks("", std::slice::from_ref(&p), false),
            json!([{"type": "resource_link", "uri": "file:///w/shot.PNG", "name": "shot.PNG"}]),
            "an agent that takes no pictures gets the link"
        );
        p.size = MAX_PICTURE_BYTES + 1;
        assert!(!p.is_picture(true), "too big: a link");
        assert_eq!(p.label(true), "shot.PNG");
    }

    #[test]
    fn base64_is_the_standard_padded_encoding() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64(&[0xff, 0xfe, 0xfd, 0xfc]), "//79/A==");
    }

    #[test]
    fn only_a_regular_file_within_the_limit_is_read_as_a_picture() {
        let dir = tempfile::tempdir().expect("tempdir");
        let small = dir.path().join("a.png");
        std::fs::write(&small, b"png").expect("write");
        let p = small.to_string_lossy();
        assert_eq!(read_picture(&p), Ok(Some(b"png".to_vec())));
        let big = dir.path().join("big.png");
        std::fs::write(
            &big,
            vec![0u8; usize::try_from(MAX_PICTURE_BYTES).expect("fits") + 1],
        )
        .expect("write");
        assert_eq!(
            read_picture(&big.to_string_lossy()),
            Ok(None),
            "over the limit: a link"
        );
        assert_eq!(
            read_picture(&dir.path().to_string_lossy()),
            Ok(None),
            "a folder is no picture"
        );
        assert_eq!(read_picture("/dev/zero"), Ok(None), "a device never ends");
        assert!(read_picture(&dir.path().join("gone.png").to_string_lossy()).is_err());
    }
}
