#!/usr/bin/env python3
"""Checks one section of CHANGELOG.md, and its media, before a commit.

    python3 check_changelog.py <x.y.z | unreleased> [--remote] [--no-media=REASON]

--no-media skips the media rule for a release whose changes only the phone
can show while no phone is at hand (a test cannot draw video, a WebView or
Android's own UI). The reason is required and printed, so a release without
media says why instead of passing silently.

Works on the git repo of the current directory (not the one this script lives
in), so running it by absolute path inside a clone checks that clone. Prints
one finding per line as `<rule>: <detail>` and exits 1, or prints `OK`.

Rules (release = a version argument; unreleased skips the release-only ones):
  heading  release: `## [x.y.z] - YYYY-MM-DD`, one `### ` headline before the first bullet
  order    release: each headline block opens with a paragraph; media close the
           block; `**Fixed**` comes once, last, followed only by bullets
  jargon   no commit hashes, source file names, lib/ paths, "refactor", PR numbers
           or CamelCase widget names (outside backticks)
  tip      every `> [!TIP]` card's first line starts `> Try it:`; at most 3
  label    every backticked label in a tip is a quoted string in app/lib/**/*.dart
  version  release: app/pubspec.yaml is at the version being released
  media    release: the section starts with the walkthrough line
           [![label](<version>-whats-new.jpg)](<version>-whats-new.mp4); each
           headline block has one still (and at most one phone clip); all are
           v<version> assets on the GitHub release, with text that reads alone;
           files present under local/release-media/<version>/ (or, with
           --remote, on the release)
"""
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

MAX_TIPS = 3
STILL_MAX_BYTES = 1_500_000
CLIP_MAX_BYTES = 30_000_000
# The poster is the one picture the update sheet fetches unasked.
POSTER_MAX_BYTES = 81_920
# Product names that are CamelCase by their makers, not widget names.
CAMEL_OK = {'GitHub', 'YouTube', 'JavaScript', 'TypeScript', 'MacBook', 'PowerShell', 'WhatsApp', 'LaTeX', 'OpenSSH', 'WireGuard'}

HEADING = re.compile(r'^## \[\d+\.\d+\.\d+\] - \d{4}-\d{2}-\d{2}$')
BULLET = re.compile(r'^(\s*)([-*]|\d+\.) ')
IMAGE = re.compile(r'^!\[([^\]]*)\]\(([^)\s]+)\)\s*$')
LINK_LINE = re.compile(r'^\[([^\]]+)\]\(([^)\s]+)\)\s*$')
CODE = re.compile(r'`[^`]*`')
URL_PART = re.compile(r'\]\([^)]*\)|https?://\S+')
JARGON = [
    (re.compile(r'\.(dart|kt|py|sh)\b'), 'a source file name'),
    (re.compile(r'\blib/'), 'a lib/ path'),
    (re.compile(r'\brefactor', re.I), '"refactor"'),
    (re.compile(r'\bPR #?\d+'), 'a PR number'),
]
JARGON_PROSE = [  # checked with backticks and URLs removed
    (re.compile(r'\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b'), 'a commit hash'),
]
CAMEL = re.compile(r'\b[A-Z][a-z]+[A-Z][A-Za-z]+\b')


def repo_root() -> Path:
    out = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit('check_changelog: run it inside a git checkout of herdr-mobile')
    return Path(out.stdout.strip())


def section(lines: list[str], version: str) -> tuple[int, list[str]] | None:
    """The section's lines (heading first) and the heading's 1-based line number."""
    head = '## [Unreleased]' if version == 'unreleased' else f'## [{version}]'
    for i, line in enumerate(lines):
        if line == head or line.startswith(head + ' '):
            end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith('## [')), len(lines))
            return i + 1, lines[i:end]
    return None


def tips(body: list[tuple[int, str]]) -> list[tuple[int, list[str]]]:
    """Each `> [!TIP]` card: its line number and the text lines after the marker."""
    found = []
    for k, (n, line) in enumerate(body):
        if line.strip() == '> [!TIP]':
            text = []
            for _, nxt in body[k + 1:]:
                if not nxt.startswith('>'):
                    break
                text.append(nxt[1:].strip())
            found.append((n, text))
    return found


def check_heading(sec: list[str], first: int) -> list[str]:
    out = []
    if not HEADING.match(sec[0]):
        out.append(f'heading: line {first}: "{sec[0]}" is not "## [x.y.z] - YYYY-MM-DD"')
    heads = []
    for line in sec[1:]:
        if BULLET.match(line):
            break
        if line.startswith('### '):
            heads.append(line)
    if len(heads) != 1:
        out.append(f'heading: {len(heads)} "### " headlines before the first bullet; write exactly one')
    return out


def check_order(body: list[tuple[int, str]]) -> list[str]:
    out = []
    fixed_at = None
    block = None  # current headline
    expect_paragraph = False
    media_seen = False
    in_tip = False
    for n, line in body:
        s = line.strip()
        if not s:
            in_tip = False
            continue
        if line.startswith('### '):
            if fixed_at is not None:
                out.append(f'order: line {n}: headline after **Fixed** (line {fixed_at}); **Fixed** goes last')
            block, expect_paragraph, media_seen = line[4:], True, False
            continue
        if s == '**Fixed**':
            if fixed_at is not None:
                out.append(f'order: line {n}: a second **Fixed**; keep one, at the end')
            fixed_at = n
            block = None
            continue
        if fixed_at is not None:
            if not (BULLET.match(line) or line.startswith('  ')):
                out.append(f'order: line {n}: only bullets follow **Fixed**')
            continue
        if block is None:
            continue
        is_media = bool(IMAGE.match(s) or LINK_LINE.match(s))
        if expect_paragraph:
            expect_paragraph = False
            if BULLET.match(line) or s.startswith('>') or is_media:
                out.append(f'order: line {n}: "### {block}" must open with a one-paragraph outcome, not a list, card or media')
        if s.startswith('>'):
            in_tip = True
        if is_media:
            media_seen = True
        elif media_seen and (BULLET.match(line) or (s.startswith('>') and not in_tip) or s == '> [!TIP]'):
            out.append(f'order: line {n}: media close the "### {block}" block; move bullets and cards above them')
    return out


def check_jargon(body: list[tuple[int, str]]) -> list[str]:
    out = []
    for n, line in body:
        no_url = URL_PART.sub(' ', line)
        for rx, what in JARGON:
            m = rx.search(no_url)
            if m:
                out.append(f'jargon: line {n}: "{m.group(0)}" is {what}; say what the person sees')
        prose = CODE.sub(' ', no_url)
        for rx, what in JARGON_PROSE:
            m = rx.search(prose)
            if m:
                out.append(f'jargon: line {n}: "{m.group(0)}" is {what}')
        for m in CAMEL.finditer(prose):
            if m.group(0) not in CAMEL_OK:
                out.append(f'jargon: line {n}: "{m.group(0)}" looks like a widget name; use the label the person sees')
    return out


def check_tips(body: list[tuple[int, str]], root: Path) -> list[str]:
    out = []
    cards = tips(body)
    if len(cards) > MAX_TIPS:
        out.append(f'tip: {len(cards)} tips; at most {MAX_TIPS} per release, for what the person has to find')
    sources = None
    for n, text in cards:
        if not text or not text[0].startswith('Try it:'):
            out.append(f'tip: line {n}: the card must start "> Try it:"')
        for label in CODE.findall(' '.join(text)):
            label = label.strip('`')
            if not re.search(r'[A-Za-z]', label) or label.startswith('.') or 'localhost' in label:
                continue
            if sources is None:
                # A label such as 'Share or save\u2026' is written with an escape; the person
                # sees the character, so compare with it decoded.
                sources = re.sub(
                    r'\\u([0-9a-fA-F]{4})',
                    lambda m: chr(int(m.group(1), 16)),
                    '\n'.join(p.read_text(errors='ignore') for p in (root / 'app' / 'lib').rglob('*.dart')),
                )
            if f"'{label}'" not in sources and f'"{label}"' not in sources:
                out.append(f'label: {label} (line {n}) is not a string in app/lib; use the exact label on screen')
    return out


def check_version(root: Path, version: str) -> list[str]:
    pubspec = (root / 'app' / 'pubspec.yaml').read_text()
    m = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', pubspec, re.M)
    if not m:
        return ['version: app/pubspec.yaml has no "version: x.y.z+N" line']
    if m.group(1) != version:
        return [f'version: app/pubspec.yaml is at {m.group(1)}+{m.group(2)}; bump it to {version} first']
    return []


WALKTHROUGH = re.compile(r'^\[!\[([^\]]+)\]\(([^)\s]+)\)\]\(([^)\s]+)\)\s*$')


def check_media(body: list[tuple[int, str]], root: Path, version: str, remote: bool) -> list[str]:
    out = []
    lead: list[tuple[int, str]] = []  # before the first headline
    blocks: list[tuple[str, list[tuple[int, str]]]] = []
    for n, line in body:
        if line.startswith('### '):
            blocks.append((line[4:], []))
        elif line.strip() == '**Fixed**':
            break
        elif blocks:
            blocks[-1][1].append((n, line.strip()))
        else:
            lead.append((n, line.strip()))
    asset = re.compile(rf'^https://github\.com/[^/]+/[^/]+/releases/download/v{re.escape(version)}/'
                       rf'({re.escape(version)}-[a-z0-9]+(?:-[a-z0-9]+)*)\.(png|jpg|mp4)$')
    local = root / 'local' / 'release-media' / version
    limits = {'png': STILL_MAX_BYTES, 'jpg': POSTER_MAX_BYTES, 'mp4': CLIP_MAX_BYTES}

    def asset_ok(n: int, url: str, kind: str, name_must: str | None = None) -> None:
        a = asset.match(url)
        if not a or a.group(2) != kind or (name_must and f'{a.group(1)}.{kind}' != name_must):
            want = name_must or f'{version}-<slug>.{kind}'
            out.append(f'media: line {n}: {url} is not the v{version} release asset {want}')
            return
        name = f'{a.group(1)}.{kind}'
        if remote:
            try:
                req = urllib.request.Request(url, method='HEAD')
                with urllib.request.urlopen(req, timeout=20) as r:
                    size = int(r.headers.get('Content-Length') or 0)
                if size > limits[kind]:
                    out.append(f'media: {name} is {size} bytes on the release; keep it under {limits[kind]}')
            except (urllib.error.URLError, TimeoutError) as e:
                out.append(f'media: {url} is not reachable ({e}); upload it with gh release upload')
        else:
            f = local / name
            if not f.exists():
                out.append(f'media: local/release-media/{version}/{name} is missing; make it before release')
            elif f.stat().st_size > limits[kind]:
                out.append(f'media: {name} is {f.stat().st_size} bytes; keep it under {limits[kind]}')

    # The walkthrough leads: its poster line comes before the first headline,
    # so GitHub and the in-app sheet both open on it.
    walks = [(n, m) for n, s in lead if (m := WALKTHROUGH.match(s))]
    stray = [n for _, lines in blocks for n, s in lines if WALKTHROUGH.match(s) or s.endswith(f'-whats-new.mp4)')]
    for n in stray:
        out.append(f'media: line {n}: the walkthrough goes above the first "### " headline, as the line [![…](poster)](clip)')
    if blocks and len(walks) != 1:
        out.append(f'media: start the section with the walkthrough line [![…]({version}-whats-new.jpg)]({version}-whats-new.mp4) (found {len(walks)})')
    for n, m in walks:
        if len(m.group(1).split()) < 4:
            out.append(f'media: line {n}: "{m.group(1)}" is too short; say what it is and costs: "Watch what\'s new · 6 changes · 0:19 · 7.5 MB"')
        asset_ok(n, m.group(2), 'jpg', f'{version}-whats-new.jpg')
        asset_ok(n, m.group(3), 'mp4', f'{version}-whats-new.mp4')

    for head, lines in blocks:
        stills = [(n, m) for n, s in lines if (m := IMAGE.match(s))]
        clips = [(n, m) for n, s in lines if (m := LINK_LINE.match(s)) and m.group(2).endswith('.mp4')]
        if len(stills) != 1:
            out.append(f'media: "### {head}" has {len(stills)} stills; give it exactly one')
        if len(clips) > 1:
            out.append(f'media: "### {head}" links {len(clips)} phone clips; one at most, the walkthrough covers the rest')
        for (n, m), kind in [(x, 'png') for x in stills] + [(x, 'mp4') for x in clips]:
            if len(m.group(1).split()) < 4:
                out.append(f'media: line {n}: "{m.group(1)}" is too short; the in-app sheet shows only this text, so it must read alone')
            asset_ok(n, m.group(2), kind)
    return out


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    remote = '--remote' in sys.argv[1:]
    no_media = next((a.split('=', 1)[1].strip() for a in sys.argv[1:] if a.startswith('--no-media=')), None)
    if len(args) != 1 or not re.fullmatch(r'\d+\.\d+\.\d+|unreleased', args[0]) or no_media == '':
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    version = args[0]
    root = repo_root()
    lines = (root / 'CHANGELOG.md').read_text().splitlines()
    found = section(lines, version)
    if found is None:
        print(f'heading: CHANGELOG.md has no "## [{version if version != "unreleased" else "Unreleased"}]" section')
        return 1
    first, sec = found
    body = [(first + i, line) for i, line in enumerate(sec) if i > 0]
    findings = []
    if version != 'unreleased':
        findings += check_heading(sec, first)
        findings += check_order(body)
    findings += check_jargon(body)
    findings += check_tips(body, root)
    if version != 'unreleased':
        findings += check_version(root, version)
        if no_media is None:
            findings += check_media(body, root, version, remote)
        else:
            print(f'note: media not checked: {no_media}')
    for f in findings:
        print(f)
    if not findings:
        print('OK')
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main())
