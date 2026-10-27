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
    /// The picture's number in this message (`[Image #2]`), 0 for a file that is no picture. It
    /// stays with the picture when another is taken off, so what the person wrote about
    /// `[Image #2]` stays true.
    pub number: u32,
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

    /// What it is called above the input: its name, or just the file's own name when it lies
    /// outside the session's folder (the full path is in what the agent is told).
    #[must_use]
    pub fn short(&self) -> &str {
        if self.name.starts_with('/') {
            self.name.rsplit('/').next().unwrap_or(&self.name)
        } else {
            &self.name
        }
    }

    /// How it is listed above the input: its short name, and `picture` when it goes as one.
    #[must_use]
    pub fn label(&self, agent_takes_pictures: bool) -> String {
        let name = if self.number > 0 {
            format!("#{} {}", self.number, self.short())
        } else {
            self.short().to_string()
        };
        if self.is_picture(agent_takes_pictures) {
            format!("{name} · picture")
        } else {
            name
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
        number: 0,
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

/// The prompt's content blocks: the text (when it says more than placeholders), then each file.
/// A numbered picture is introduced by a text block with its placeholder (`[Image #2]`), so the
/// words the person wrote about it point at it; then the picture itself when its bytes were read
/// and the agent takes pictures, else a link.
#[must_use]
pub fn blocks(text: &str, files: &[Attachment], agent_takes_pictures: bool) -> Value {
    let mut out = Vec::new();
    if !without_placeholders(text).trim().is_empty() {
        out.push(json!({"type": "text", "text": text}));
    }
    for f in files {
        if f.number > 0 {
            out.push(json!({"type": "text", "text": placeholder(f.number)}));
        }
        out.push(match (&f.data, f.picture) {
            (Some(data), Some(mime)) if f.is_picture(agent_takes_pictures) => {
                json!({"type": "image", "data": data, "mimeType": mime})
            }
            _ => json!({"type": "resource_link", "uri": f.uri, "name": f.name}),
        });
    }
    Value::Array(out)
}

/// How the message is shown in the conversation: the text, then each file on its own line
/// (`[Image #1] name` for a numbered picture, `@name` for a file).
#[must_use]
pub fn echo(text: &str, files: &[Attachment]) -> String {
    let mut out = if without_placeholders(text).trim().is_empty() {
        String::new()
    } else {
        text.to_string()
    };
    for f in files {
        if !out.is_empty() {
            out.push('\n');
        }
        if f.number > 0 {
            out.push_str(&placeholder(f.number));
            out.push(' ');
            out.push_str(f.short());
        } else {
            out.push('@');
            out.push_str(&f.name);
        }
    }
    out
}

/// The text that stands for picture number `n` in a message.
#[must_use]
pub fn placeholder(n: u32) -> String {
    format!("[Image #{n}]")
}

/// Where the placeholders sit in `text`: `(start, end, number)`, in order.
#[must_use]
pub fn tokens(text: &str) -> Vec<(usize, usize, u32)> {
    const OPEN: &str = "[Image #";
    text.match_indices(OPEN)
        .filter_map(|(start, _)| {
            let rest = &text[start + OPEN.len()..];
            let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
            (digits > 0 && digits <= 9 && rest[digits..].starts_with(']')).then(|| {
                (
                    start,
                    start + OPEN.len() + digits + 1,
                    rest[..digits].parse().unwrap_or(0),
                )
            })
        })
        .collect()
}

/// `text` with every placeholder removed.
#[must_use]
pub fn without_placeholders(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    for (start, end, _) in tokens(text) {
        out.push_str(&text[at..start]);
        at = end;
    }
    out.push_str(&text[at..]);
    out
}

/// Whether `text` says nothing but placeholders: such a box still counts as empty for pasting a
/// path and for Backspace taking a file off.
#[must_use]
pub fn only_placeholders(text: &str) -> bool {
    without_placeholders(text).trim().is_empty()
}

/// The span to delete for the placeholder that ends at `cursor` (or just before one space
/// that ends there), and its number: what Backspace takes off as one piece.
#[must_use]
pub fn token_before(text: &str, cursor: usize) -> Option<(usize, usize, u32)> {
    tokens(text).into_iter().find_map(|(s, e, n)| {
        if e == cursor {
            Some((s, e, n))
        } else if e < cursor && &text[e..cursor] == " " {
            Some((s, cursor, n))
        } else {
            None
        }
    })
}

/// The spans to delete to take picture `n` out of `text`: each of its placeholders, with the
/// one space after it when there is one. Last first, so deleting them in order stays valid.
#[must_use]
pub fn spans_of(text: &str, n: u32) -> Vec<(usize, usize)> {
    let mut spans: Vec<(usize, usize)> = tokens(text)
        .into_iter()
        .filter(|t| t.2 == n)
        .map(|(s, e, _)| (s, if text[e..].starts_with(' ') { e + 1 } else { e }))
        .collect();
    spans.reverse();
    spans
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

    #[test]
    fn a_file_outside_the_folder_is_listed_by_its_own_name_and_told_to_the_agent_in_full() {
        let mut p = attachment("/home/me/.herdr-mobile/inbox/tui-x/clipboard-1-1.png", "/w");
        p.size = 10;
        assert_eq!(p.label(true), "clipboard-1-1.png · picture");
        assert_eq!(p.label(false), "clipboard-1-1.png");
        assert_eq!(
            p.name,
            "/home/me/.herdr-mobile/inbox/tui-x/clipboard-1-1.png"
        );
        assert_eq!(attachment("/w/src/a.rs", "/w").label(true), "src/a.rs");
    }

    #[test]
    fn pictures_are_pointed_at_by_number_in_the_text_and_introduced_to_the_agent_the_same_way() {
        let mut a = attachment("/w/a.png", "/w");
        let mut b = attachment("/w/b.png", "/w");
        let f = attachment("/w/notes.md", "/w");
        a.number = 1;
        b.number = 2;
        let files = [a, b, f];
        assert_eq!(
            blocks("compare [Image #1] with [Image #2]", &files, false),
            json!([
                {"type": "text", "text": "compare [Image #1] with [Image #2]"},
                {"type": "text", "text": "[Image #1]"},
                {"type": "resource_link", "uri": "file:///w/a.png", "name": "a.png"},
                {"type": "text", "text": "[Image #2]"},
                {"type": "resource_link", "uri": "file:///w/b.png", "name": "b.png"},
                {"type": "resource_link", "uri": "file:///w/notes.md", "name": "notes.md"}
            ])
        );
        // Only placeholders typed: the words say nothing, so there is no text block at all.
        assert_eq!(
            blocks("[Image #1] ", &files[..1], false)[0]["text"],
            "[Image #1]"
        );
        assert_eq!(
            blocks("[Image #1] ", &files[..1], false)
                .as_array()
                .map(Vec::len),
            Some(2)
        );
        assert_eq!(
            echo("compare [Image #1] with [Image #2]", &files),
            "compare [Image #1] with [Image #2]\n[Image #1] a.png\n[Image #2] b.png\n@notes.md"
        );
        assert_eq!(echo("[Image #1] ", &files[..1]), "[Image #1] a.png");
        assert_eq!(files[1].label(false), "#2 b.png");
    }

    #[test]
    fn placeholders_are_found_taken_off_in_one_piece_and_never_confused_with_other_brackets() {
        let t = "a [Image #1] b [Image #12] [Image #x] [Image 3] [Image #1]";
        assert_eq!(
            tokens(t).iter().map(|x| x.2).collect::<Vec<_>>(),
            [1, 12, 1]
        );
        assert_eq!(without_placeholders(t), "a  b  [Image #x] [Image 3] ");
        assert!(only_placeholders("[Image #1] [Image #2]  ") && only_placeholders(""));
        assert!(!only_placeholders("[Image #1] hi"));
        // Backspace right after the token, or after the one space that follows it.
        let s = "look [Image #1] ";
        assert_eq!(token_before(s, 15), Some((5, 15, 1)));
        assert_eq!(token_before(s, 16), Some((5, 16, 1)));
        assert_eq!(token_before(s, 14), None);
        assert_eq!(token_before("hi [Image #1]x", 14), None);
        // Taking picture 1 out of the text: each placeholder with its space, last first.
        let mut text = "[Image #1] and [Image #2] then [Image #1]".to_string();
        for (a, b) in spans_of(&text.clone(), 1) {
            text.replace_range(a..b, "");
        }
        assert_eq!(text, "and [Image #2] then ");
    }
}
