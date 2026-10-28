//! The programs an update runs: `curl` (else `wget`) to download, `sha256sum` (else `shasum`) to
//! check, and the downloaded file itself with `--version`. Every failure is a sentence for the
//! person; none of these steps changes the installed program.

use std::io;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use super::progress::Event;

pub(super) const CANCELLED: &str = "stopped; nothing was changed";

fn have(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

/// How `curl` is asked to fetch a file. It gives up on a connection that cannot be made in 20 s
/// or one that stays under 1 KB/s for 30 s, not on a total time: a slow radio that keeps
/// delivering finishes, a dead one does not hang. `--retry` repeats a transient failure.
fn curl(url: &str, to: &Path) -> Command {
    let mut command = Command::new("curl");
    command
        .args([
            "-fsL",
            "--retry",
            "2",
            "--connect-timeout",
            "20",
            "--speed-limit",
            "1000",
            "--speed-time",
            "30",
            "-o",
        ])
        .arg(to)
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

/// Downloads `url` to `to` with curl, else wget.
pub(super) fn fetch(url: &str, to: &Path) -> Result<(), String> {
    if have("curl") {
        finish("curl", url, curl(url, to).status())
    } else if have("wget") {
        let status = Command::new("wget")
            .args(["-q", "-T", "120", "-O"])
            .arg(to)
            .arg(url)
            .stdin(Stdio::null())
            .status();
        finish("wget", url, status)
    } else {
        Err("needs curl or wget to download the release".to_string())
    }
}

fn finish(tool: &str, url: &str, status: io::Result<ExitStatus>) -> Result<(), String> {
    match status {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => Err(download_error(url, tool, s.code())),
        Err(e) => Err(format!("could not start {tool} ({e})")),
    }
}

/// Says what went wrong with a download from the tool's exit code, so a dead network is not
/// blamed on the version asked for.
fn download_error(url: &str, tool: &str, code: Option<i32>) -> String {
    let why = match (tool, code) {
        ("curl", Some(22 | 37)) => "the server has no such file (a release has a desk client from 0.1.30 on; check the version)".to_string(),
        ("curl", Some(6 | 7)) => "cannot reach the server; check the network".to_string(),
        ("curl", Some(28)) => "it stopped sending data; check the network".to_string(),
        (_, Some(c)) => format!("{tool} exited with {c}"),
        (_, None) => format!("{tool} was stopped by a signal"),
    };
    format!("could not download {url}: {why}")
}

fn stop(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// The length the last real response in a `curl -D` header dump gives its body. A redirect before
/// it says nothing about the file, and a response still being written is left alone.
fn final_length(dump: &str) -> Option<u64> {
    let mut blocks: Vec<&str> = dump.split("\r\n\r\n").collect();
    // What follows the last blank line is a response still arriving, or nothing.
    blocks.pop();
    let last = blocks.iter().rev().find(|b| {
        !b.split_whitespace()
            .nth(1)
            .is_some_and(|status| status.starts_with('3'))
    })?;
    last.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case("content-length")
            .then(|| v.trim().parse::<u64>().ok())
            .flatten()
    })
}

/// Downloads `url` to `to`, telling `report` how far it has got: curl runs on its own and the file
/// it is writing is measured, so the screen never waits on the network. The whole size comes from
/// the headers of that same request (`-D`), so there is no second round trip to wait for. Without
/// curl (wget) there is no measure, and it says so.
pub(super) fn download(
    url: &str,
    to: &Path,
    label: &str,
    cancel: &AtomicBool,
    report: &mut dyn FnMut(Event),
) -> Result<(), String> {
    if !have("curl") {
        report(Event::Step(&format!(
            "downloading {label} (no progress without curl)"
        )));
        return fetch(url, to);
    }
    let headers = to.with_file_name("headers");
    let started = Instant::now();
    let mut command = curl(url, to);
    command.arg("-D").arg(&headers);
    let mut child = command
        .spawn()
        .map_err(|e| format!("could not start curl ({e})"))?;
    let measure = |done: u64| {
        #[allow(clippy::cast_precision_loss)]
        let per_sec = done as f64 / started.elapsed().as_secs_f64().max(0.001);
        (done, per_sec)
    };
    let mut total = None;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if cancel.load(Ordering::Relaxed) => {
                stop(&mut child);
                report(Event::Finished);
                return Err(CANCELLED.to_string());
            }
            Ok(None) => {
                total = total.or_else(|| {
                    std::fs::read_to_string(&headers)
                        .ok()
                        .as_deref()
                        .and_then(final_length)
                });
                let (done, per_sec) = measure(std::fs::metadata(to).map_or(0, |m| m.len()));
                report(Event::Bytes {
                    label,
                    done,
                    total,
                    per_sec,
                });
                std::thread::sleep(Duration::from_millis(60));
            }
            Err(e) => {
                stop(&mut child);
                report(Event::Finished);
                return Err(format!("could not wait for curl ({e})"));
            }
        }
    };
    if !status.success() {
        report(Event::Finished);
        return Err(download_error(url, "curl", status.code()));
    }
    let size = std::fs::metadata(to).map_or(0, |m| m.len());
    let (done, per_sec) = measure(size);
    report(Event::Bytes {
        label,
        done,
        total: Some(size),
        per_sec,
    });
    report(Event::Finished);
    Ok(())
}

/// The SHA-256 of a file, as lower-case hex, by `sha256sum` or `shasum`.
pub(super) fn sha256(file: &Path) -> Result<String, String> {
    let out = if have("sha256sum") {
        Command::new("sha256sum").arg(file).output()
    } else if have("shasum") {
        Command::new("shasum")
            .args(["-a", "256"])
            .arg(file)
            .output()
    } else {
        return Err("needs sha256sum or shasum to check the download".to_string());
    }
    .map_err(|e| format!("could not check {}: {e}", file.display()))?;
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .next()
        .filter(|s| s.len() == 64)
        .map(str::to_ascii_lowercase)
        .ok_or_else(|| format!("could not check {}", file.display()))
}

/// How long a program gets to answer `--version`.
const VERSION_WAIT: Duration = Duration::from_secs(3);

/// What `program --version` prints, both streams (`herdr-tui` says it on stderr), or why not. A
/// program that has not answered in [`VERSION_WAIT`] is stopped: it is a file that was just put
/// there, and a screen is waiting.
pub(super) fn version_said(program: &Path) -> io::Result<String> {
    let mut child = Command::new(program)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let deadline = Instant::now() + VERSION_WAIT;
    while child.try_wait()?.is_none() {
        if Instant::now() >= deadline {
            stop(&mut child);
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "no answer to --version",
            ));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let out = child.wait_with_output()?;
    Ok(format!(
        "{}{}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_size_comes_from_the_last_real_response_never_from_a_redirect() {
        let redirect = "HTTP/2 302 \r\nlocation: https://cdn/x\r\ncontent-length: 0\r\n\r\n";
        let file = "HTTP/2 200 \r\ncontent-type: application/octet-stream\r\nContent-Length: 2527000\r\n\r\n";
        assert_eq!(final_length(&format!("{redirect}{file}")), Some(2_527_000));
        assert_eq!(
            final_length(redirect),
            None,
            "the real response has not come"
        );
        let chunked = "HTTP/2 200 \r\ncontent-type: text/plain\r\n\r\n";
        assert_eq!(
            final_length(&format!("{redirect}{chunked}")),
            None,
            "unknown, and not the redirect's 0"
        );
        assert_eq!(
            final_length(&format!("{redirect}HTTP/2 200 \r\ncontent-len")),
            None,
            "half a response is not read"
        );
    }

    #[test]
    fn a_failed_download_says_why_and_does_not_blame_the_version_for_the_network() {
        let url = "https://x/y";
        assert!(download_error(url, "curl", Some(22)).contains("no such file"));
        assert!(download_error(url, "curl", Some(6)).contains("network"));
        assert!(!download_error(url, "curl", Some(28)).contains("0.1.30"));
        assert!(download_error(url, "wget", Some(4)).contains("wget exited with 4"));
    }
}
