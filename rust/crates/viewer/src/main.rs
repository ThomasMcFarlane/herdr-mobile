//! herdr-tui: a terminal client for one keeper session. Replaces the python
//! `view` command: the same socket, a full-screen UI.
//!
//! No async runtime. Two threads feed one channel (socket, keyboard); the UI
//! redraws only when something arrives, so it costs nothing at rest.
//!
//! This file is the only impure layer: it carries out the [`herdr_tui::session::Effect`]s
//! the pure session asks for.

use acp::Message;
use crossterm::{
    event::{
        self, DisableBracketedPaste, DisableFocusChange, EnableBracketedPaste, EnableFocusChange,
        Event as Term, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent,
        MouseEventKind,
    },
    execute,
    terminal::{
        self, BeginSynchronizedUpdate, EndSynchronizedUpdate, EnterAlternateScreen,
        LeaveAlternateScreen, SetTitle,
    },
};
use herdr_tui::composer::Composer;
use herdr_tui::question::{self, Act};
use herdr_tui::select::Selection;
use herdr_tui::session::{Effect, Event, Phase, Record, Refused, Session, Start};
use herdr_tui::transcript::Transcript;
use herdr_tui::ui;
use herdr_tui::{
    cli, delight, fold, herdr, highlight, host, input, lines, md, select, sessions, termbg, theme,
    update,
};
use keeper::records::StateDir;
use std::io::{BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Lines one press of Up or Down (or one tick of the wheel) scrolls.
const SCROLL_STEP: usize = 3;
/// Said when a key or a paste lands on a question's choices, where it would do nothing.
const QUESTION_HINT: &str = "Answer on the panel: ↑↓ or a number, then Enter; Esc declines";

enum Ev {
    Key(KeyEvent),
    /// A press, drag or release of the left button, or a turn of the wheel, when the mouse is ours
    /// (`input::mouse_wanted`).
    Mouse(MouseEvent),
    Resize,
    /// Text pasted (the terminal marks it, so it is one insertion and not a run of keys).
    Paste(String),
    /// SIGTERM, SIGHUP or SIGINT: leave cleanly.
    Signal(i32),
    /// Something outside wrote on the screen, or the window was away: draw everything again.
    Repaint,
    Session(Event),
}

struct App {
    dir: StateDir,
    id: String,
    out: UnixStream,
    session: Session,
    transcript: Transcript,
    composer: Composer,
    view: ui::View,
    hint: Option<String>,
    agent: String,
    cwd: String,
    theme: theme::Theme,
    turn_started: Option<Instant>,
    /// A standing grant waits for the same key a second time.
    confirm: Option<(acp::Id, usize)>,
    turn_live: bool,
    turns_done: usize,
    was_attention: bool,
    last_title: String,
    /// The request the chosen option belongs to; a new one starts at the first option.
    sel_for: Option<acp::Id>,
    /// The permission option a click last chose, and for which request: a second click on it
    /// answers.
    clicked: Option<(acp::Id, usize)>,
    /// The file this program was started from, watched for being replaced by a newer one.
    watch: update::Watch,
    /// The version of a newer herdr-tui installed since this one started; `Ctrl-R` loads it.
    newer: Option<String>,
    /// When the file was last looked at (at most every few seconds, and only on something that
    /// already woke the screen: no timer).
    watched: Instant,
    /// Leave to start the newer one in this session.
    reload: bool,
    /// While a question waits the composer is its box: the person's own draft, set aside until
    /// the question goes.
    stash: Option<String>,
    /// The question and field whose text the composer holds.
    boxed: Option<(acp::Id, usize)>,
    repaint: bool,
    /// The selection was finished: copy what it covers from the frame about to be drawn.
    copy: bool,
    /// Whether things move: the spinner, the shimmer, the pulse and unfolds.
    motion: bool,
    /// The signal that asked the program to end, if one did.
    signal: Option<i32>,
    /// Tells herdr what this session is doing, when run inside a herdr pane.
    reporter: Option<herdr::Reporter>,
    t0: Instant,
    tx: mpsc::Sender<Ev>,
    quit: bool,
}

/// While this program owns the screen, a background job of the same terminal that tries to write
/// (an image viewer's warnings, a build left running with `&`) is stopped by the kernel instead of
/// writing over the interface. The shell lists it as Stopped, and `fg` resumes it. Undone with the
/// rest of the terminal's modes when raw mode ends.
fn stop_background_writers() {
    use rustix::termios::{tcgetattr, tcsetattr, LocalModes, OptionalActions};
    let tty = std::io::stdin();
    if let Ok(mut modes) = tcgetattr(&tty) {
        modes.local_modes |= LocalModes::TOSTOP;
        let _ = tcsetattr(&tty, OptionalActions::Now, &modes);
    }
}

/// `herdr-tui ls`: the sessions on this machine as a table.
fn list_sessions(home: &std::path::Path, all: bool) {
    let dir = StateDir::create(home)
        .unwrap_or_else(|e| die(keeper::exit::FAILED, &format!("no state directory ({e})")));
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX));
    let infos = dir.scan(now, &keeper::records::System);
    let width = terminal::size().map_or(100, |(w, _)| usize::from(w));
    let table = sessions::render(
        &sessions::rows(&infos, now, &home.to_string_lossy()),
        all,
        width,
    );
    let _ = std::io::stdout().write_all(table.as_bytes());
}

/// `herdr-tui kill ID...`: ends each session for good, and says what it did to each.
fn kill_sessions(home: &std::path::Path, ids: &[String]) -> ! {
    let Some(script) = host::find_script(home) else {
        // No keeper was ever installed here, so none of these can be running.
        for id in ids {
            eprintln!("herdr-tui: {id}: no such session (no keeper is installed on this machine)");
        }
        std::process::exit(keeper::exit::MISSING);
    };
    let mut failed = false;
    for id in ids {
        match host::kill(&script, id) {
            Ok(()) => {
                let _ = writeln!(std::io::stdout(), "ended {id}");
            }
            Err(e) => {
                failed = true;
                eprintln!("herdr-tui: {id}: {}", md::one_line(&e.message, 200));
            }
        }
    }
    std::process::exit(i32::from(failed));
}

fn die(code: i32, message: &str) -> ! {
    eprintln!("herdr-tui: {}", md::one_line(message, 400));
    std::process::exit(code);
}

/// Opens the state directory and connects to keeper `id`.
fn connect(home: &std::path::Path, id: &str) -> (StateDir, UnixStream) {
    StateDir::create(home)
        .and_then(|mut d| {
            d.enter()?;
            let s = d.connect(id)?;
            Ok((d, s))
        })
        .unwrap_or_else(|e| die(keeper::exit::GONE, &format!("no such session: {id} ({e})")))
}

fn main() {
    let cmd = cli::parse(std::env::args().skip(1)).unwrap_or_else(|e| {
        eprintln!("herdr-tui: {e}\n\n{}", cli::USAGE);
        std::process::exit(keeper::exit::USAGE);
    });
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let (id, start) = match cmd {
        cli::Cmd::Help => {
            eprintln!("{}", cli::USAGE);
            return;
        }
        cli::Cmd::Version => {
            eprintln!("herdr-tui {}", cli::VERSION);
            return;
        }
        cli::Cmd::Ls { all } => {
            list_sessions(&home, all);
            return;
        }
        cli::Cmd::Kill { ids } => kill_sessions(&home, &ids),
        cli::Cmd::Update { check, version } => {
            let exe = std::env::current_exe()
                .unwrap_or_else(|e| die(keeper::exit::FAILED, &format!("no path to itself ({e})")));
            let base = update::base_url(|k| std::env::var(k).ok(), version.as_deref());
            use std::io::IsTerminal;
            let mut console = update::Console::new(
                std::io::stderr().is_terminal(),
                std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty()),
            );
            let result = update::run(
                &exe,
                cli::VERSION,
                &base,
                version.is_some(),
                check,
                &mut |e| console.event(&e),
            );
            match result {
                Ok(said) => {
                    let _ = writeln!(std::io::stdout(), "herdr-tui: {said}");
                }
                Err(why) => die(keeper::exit::FAILED, &why),
            }
            return;
        }
        cli::Cmd::Attach { id } => (id, Start::Attach),
        cli::Cmd::New { agent, cwd } => {
            if keeper::routes::by_id(&agent).is_none() {
                let known: Vec<String> = keeper::routes::all().into_iter().map(|r| r.id).collect();
                die(
                    keeper::exit::USAGE,
                    &format!("unknown agent {agent:?} (known: {})", known.join(", ")),
                );
            }
            let cwd = cwd
                .map(PathBuf::from)
                .map_or_else(std::env::current_dir, Ok)
                .unwrap_or_else(|e| die(keeper::exit::GONE, &format!("no current folder ({e})")));
            let cwd = cwd.canonicalize().unwrap_or(cwd);
            let script = host::find_script(&home).unwrap_or_else(|| {
                die(
                    keeper::exit::MISSING,
                    "no keeper is installed on this machine. Run tool/install-keeper.sh from the herdr-mobile repo (or open the herdr mobile app on this machine once), or set HERDR_KEEPER_SCRIPT.",
                )
            });
            let id = host::start(&script, &agent, &cwd).unwrap_or_else(|e| die(e.code, &e.message));
            (
                id,
                Start::Create {
                    cwd: cwd.to_string_lossy().into_owned(),
                },
            )
        }
    };
    let (dir, stream) = connect(&home, &id);
    let (tx, rx) = mpsc::channel();
    spawn_reader(
        stream.try_clone().expect("a socket can be cloned"),
        tx.clone(),
    );
    let info = dir.read(&id);
    let (session, first) = Session::begin(start, std::env::var("HERDR_PANE_ID").ok());
    let mut app = App {
        dir,
        id: id.clone(),
        out: stream,
        session,
        transcript: Transcript::default(),
        composer: Composer::default(),
        view: ui::View::default(),
        hint: None,
        agent: info.as_ref().map_or_else(String::new, |i| {
            keeper::routes::by_id(&i.agent).map_or(i.agent.clone(), |r| r.label)
        }),
        cwd: info.as_ref().map_or_else(String::new, |i| i.cwd.clone()),
        theme: theme::Theme::detect(None),
        turn_started: None,
        confirm: None,
        turn_live: false,
        turns_done: 0,
        was_attention: false,
        last_title: String::new(),
        sel_for: None,
        clicked: None,
        watch: update::Watch::new(&std::env::current_exe().unwrap_or_default(), cli::VERSION),
        newer: None,
        watched: Instant::now(),
        reload: false,
        stash: None,
        boxed: None,
        repaint: false,
        copy: false,
        motion: delight::motion_enabled(),
        signal: None,
        reporter: None,
        t0: Instant::now(),
        tx: tx.clone(),
        quit: false,
    };
    app.run(first);
    app.reporter = herdr::Target::from_env(|k| std::env::var(k).ok()).map(|target| {
        let exe = std::env::current_exe().map_or_else(
            |_| "herdr-tui".to_string(),
            |p| p.to_string_lossy().into_owned(),
        );
        herdr::Reporter::new(
            target,
            format!("{} · phone", app.agent),
            vec![exe, "attach".to_string(), id.clone()],
        )
    });

    let mut term = ratatui::init();
    let _ = execute!(std::io::stdout(), EnterAlternateScreen, SetTitle("herdr"));
    // Ask the terminal to send the wheel as Up and Down while we own the screen (what the wheel
    // does when the mouse is not ours, below).
    let _ = std::io::stdout().write_all(b"\x1b[?1007h");
    let _ = execute!(std::io::stdout(), EnableFocusChange, EnableBracketedPaste);
    let _ = terminal::enable_raw_mode();
    stop_background_writers();
    install_restore_hook();
    // The tint behind messages is derived from the real background, so ask for it, once, now:
    // the keyboard thread is not reading yet.
    app.theme = theme::Theme::detect(termbg::query());
    // Clicks and the wheel come to us (after the colour query, so no click lands in its reply):
    // a click opens what it is on, and a drag selects and copies (`select.rs`).
    if input::mouse_wanted(|k| std::env::var(k).ok()) {
        let _ = std::io::stdout().write_all(input::MOUSE_ON);
        let _ = std::io::stdout().flush();
    }
    spawn_input(tx.clone());
    highlight::warm();
    spawn_signals(tx);

    while !app.quit {
        let working = app.transcript.running() || app.session.prompting();
        if working {
            if app.turn_started.is_none() {
                app.turn_live = app.session.ready();
            }
            app.turn_started = app.turn_started.or_else(|| Some(Instant::now()));
        } else if let Some(started) = app.turn_started.take() {
            // The turn the person watched ended: say what it did. A turn that
            // ended while the history was replaying is not news.
            if app.turn_live && app.session.ready() {
                app.transcript.done(started.elapsed().as_secs());
                app.turns_done += 1;
            }
        }
        app.attend();
        app.report();
        let working_secs = app.turn_started.map(|t| t.elapsed().as_secs());
        let ctx = ui::Frame_ {
            transcript: &app.transcript,
            session: &app.session,
            composer: &app.composer,
            header: ui::Header {
                agent: &app.agent,
                cwd: &app.cwd,
            },
            theme: app.theme,
            hint: app.hint.as_deref(),
            working_secs,
            turn: app.turns_done,
            anim_ms: app.now_ms(),
            motion: app.motion,
            newer: app.newer.as_deref(),
        };
        if std::mem::take(&mut app.repaint) {
            let _ = term.clear();
        }
        // One frame reaches the terminal whole: where it is supported, it shows nothing half-drawn.
        let _ = execute!(std::io::stdout(), BeginSynchronizedUpdate);
        let drawn = term.draw(|f| ui::draw(f, &ctx, &mut app.view));
        let _ = execute!(std::io::stdout(), EndSynchronizedUpdate);
        // A selection was just finished: copy it from this frame, then draw again at once so the
        // footer says so (nothing else would wake the loop to show it).
        if app.copy && drawn.as_ref().is_ok_and(|d| app.copy_selection(d.buffer)) {
            continue;
        }
        app.copy = false;
        // The loop sleeps until something happens, and wakes by itself only while something moves:
        // the elapsed counter every second, the shimmer and spinner every few frames, an unfold at
        // 60 Hz for the 160 ms it lasts. At rest nothing wakes it.
        let wake = delight::next_wake(
            app.motion,
            working,
            !app.session.waiting().is_empty(),
            !app.view.reveal.is_empty(),
        );
        let first = match wake {
            Some(d) => match rx.recv_timeout(d) {
                Ok(ev) => ev,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
            None => match rx.recv() {
                Ok(ev) => ev,
                Err(_) => break,
            },
        };
        // A streaming agent sends bursts: handle all that is waiting, draw once.
        app.handle(first);
        while let Ok(more) = rx.try_recv() {
            app.handle(more);
        }
    }
    restore_modes();
    let _ = execute!(std::io::stdout(), LeaveAlternateScreen);
    ratatui::restore();
    // The pane is no agent any more.
    if let Some(reporter) = app.reporter.take() {
        reporter.release();
    }
    // Load the newer herdr-tui into this session: the keeper holds everything, so the new one
    // attaches and replays. Same terminal, same pane; this process becomes it.
    if app.reload {
        use std::os::unix::process::CommandExt;
        let err = std::process::Command::new(app.watch.path())
            .arg("attach")
            .arg(&app.id)
            .exec();
        die(
            keeper::exit::FAILED,
            &format!(
                "could not start the newer herdr-tui ({err}); the session is still running: herdr-tui attach {}",
                app.id
            ),
        );
    }
    // Asked to end by a signal: the terminal is put back, then the exit status says so.
    if let Some(sig) = app.signal {
        std::process::exit(128 + sig);
    }
    if let Phase::Ended(reason) = app.session.phase() {
        eprintln!("herdr-tui: {}", md::one_line(reason, 400));
        std::process::exit(keeper::exit::EXITED);
    }
    eprintln!(
        "Session {id} is still running (it shows on your phone). Reopen it: herdr-tui attach {id}",
        id = app.id
    );
}

/// Puts back every terminal mode this program changed. Run on a normal exit and, through the panic
/// hook, on a crash, so the terminal is never left with its wheel remapped, the mouse taken or
/// focus events on.
fn restore_modes() {
    let mut out = std::io::stdout();
    let _ = out.write_all(input::MOUSE_OFF);
    let _ = out.write_all(b"\x1b[?1007l");
    // A panic between the begin and end of a frame must not leave the terminal holding output.
    let _ = execute!(
        out,
        EndSynchronizedUpdate,
        DisableBracketedPaste,
        DisableFocusChange,
        SetTitle("")
    );
}

/// ratatui's panic hook restores raw mode and the alternate screen; this adds the rest.
fn install_restore_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore_modes();
        previous(info);
    }));
}

/// Reads the keyboard on its own thread. Terminal replies that are not typing are dropped here.
fn spawn_input(tx: mpsc::Sender<Ev>) {
    std::thread::spawn(move || {
        let mut replies = input::OscFilter::default();
        loop {
            let ev = match event::read() {
                Ok(Term::Key(k)) if k.kind != KeyEventKind::Release => {
                    if replies.drops(&k) {
                        continue;
                    }
                    Ev::Key(k)
                }
                Ok(Term::Paste(text)) => Ev::Paste(text),
                Ok(Term::Resize(..)) => Ev::Resize,
                Ok(Term::FocusGained) => Ev::Repaint,
                // Only what acts: the buttons (a drag selects), and the wheel. A move with no
                // button held is never asked for.
                Ok(Term::Mouse(m))
                    if matches!(
                        m.kind,
                        MouseEventKind::Down(MouseButton::Left)
                            | MouseEventKind::Drag(MouseButton::Left)
                            | MouseEventKind::Up(MouseButton::Left)
                            | MouseEventKind::ScrollUp
                            | MouseEventKind::ScrollDown
                    ) =>
                {
                    Ev::Mouse(m)
                }
                Ok(_) => continue,
                Err(_) => return,
            };
            if tx.send(ev).is_err() {
                return;
            }
        }
    });
}

/// SIGTERM, SIGHUP (the terminal closed) and SIGINT end the program the way a normal exit does, so
/// the terminal is put back.
fn spawn_signals(tx: mpsc::Sender<Ev>) {
    use signal_hook::{
        consts::{SIGHUP, SIGINT, SIGTERM},
        iterator::Signals,
    };
    let Ok(mut signals) = Signals::new([SIGHUP, SIGINT, SIGTERM]) else {
        return;
    };
    std::thread::spawn(move || {
        if let Some(sig) = signals.forever().next() {
            let _ = tx.send(Ev::Signal(sig));
        }
    });
}

/// The longest line taken from the keeper: what the keeper itself allows from an agent.
const MAX_LINE: usize = 64 * 1024 * 1024;

fn spawn_reader(stream: UnixStream, tx: mpsc::Sender<Ev>) {
    std::thread::spawn(move || {
        for line in lines::Lines::new(BufReader::new(stream), MAX_LINE) {
            let Ok(line) = line else { break };
            // A line that is not JSON-RPC (an agent's stray output) is not ours to show.
            if let Ok(m) = Message::parse(&line) {
                if tx.send(Ev::Session(Event::Message(m))).is_err() {
                    return;
                }
            }
        }
        let _ = tx.send(Ev::Session(Event::Closed));
    });
}

impl App {
    /// Tells herdr what the session is doing: its agent list shows working, blocked or idle.
    fn report(&mut self) {
        let Some(reporter) = self.reporter.as_mut() else {
            return;
        };
        if !self.session.ready() {
            return;
        }
        let state = if !self.session.waiting().is_empty() {
            herdr::State::Blocked
        } else if self.transcript.running() || self.session.prompting() {
            herdr::State::Working
        } else {
            herdr::State::Idle
        };
        reporter.set(state, self.session.session_id());
    }

    /// Calls for the person from a pane they may not be looking at: a bell when a
    /// request arrives, and the window title says what the session needs.
    fn attend(&mut self) {
        let head = self.session.waiting().first().map(|w| w.id.clone());
        if head != self.sel_for {
            self.view.sel = 0;
            self.sel_for = head;
        }
        let waiting = !self.session.waiting().is_empty();
        if waiting && !self.was_attention {
            let mut out = std::io::stdout();
            let _ = out.write_all(b"\x07");
            let _ = out.flush();
        }
        self.was_attention = waiting;
        let title = if waiting {
            format!("▲ {} needs you", self.agent)
        } else if self.transcript.running() || self.session.prompting() {
            format!("● {} working", self.agent)
        } else {
            self.transcript
                .title()
                .map_or_else(|| self.agent.clone(), str::to_string)
        };
        // An agent chooses its session's title; the terminal must only ever see one safe line.
        let title = md::one_line(&title, 100);
        if title != self.last_title {
            let _ = execute!(std::io::stdout(), SetTitle(&title));
            self.last_title = title;
        }
    }

    fn now_ms(&self) -> u64 {
        u64::try_from(self.t0.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    /// The wheel scrolls. A press starts a selection and the release ends it: dragged, it copies
    /// what was covered; not dragged, it is a click. A click on an option of the asking panel
    /// chooses it, and a click on the option already chosen answers with it (the same guards as
    /// Enter; on a question's ticks a click ticks); a click on a tool call, a run of them or the
    /// thinking opens or closes it. The click waits for the release so that a drag that starts on
    /// a tool call selects its text instead of opening it.
    fn mouse(&mut self, m: MouseEvent) {
        let at = (m.column, m.row);
        match m.kind {
            MouseEventKind::ScrollUp => {
                self.view.select = None;
                self.view.scroll = self.view.scroll.saturating_add(SCROLL_STEP);
            }
            MouseEventKind::ScrollDown => {
                self.view.select = None;
                self.view.scroll = self.view.scroll.saturating_sub(SCROLL_STEP);
            }
            MouseEventKind::Down(MouseButton::Left) => {
                self.hint = None;
                // A press that moves off the option a standing grant waits on takes the
                // "press again" back, as the click used to: a drag must not leave it armed.
                self.confirm = None;
                self.view.select = Some(Selection::begin(at));
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                if let Some(s) = self.view.select.as_mut().filter(|s| !s.done) {
                    s.drag(at);
                }
            }
            MouseEventKind::Up(MouseButton::Left) => {
                // A release with no press seen (the press went to something else) is not a click.
                let Some(mut s) = self.view.select.take().filter(|s| !s.done) else {
                    return;
                };
                s.drag(at);
                if s.range().is_some() {
                    s.done = true;
                    self.view.select = Some(s);
                    self.copy = true;
                } else {
                    self.click(m.row);
                }
            }
            _ => {}
        }
    }

    /// The release of a press that did not move, on screen row `row`.
    fn click(&mut self, row: u16) {
        self.view.help = false;
        if !self.session.waiting().is_empty() {
            if let Some(i) = self.view.option_at(row) {
                if self.asking_question() {
                    self.ask(Act::Click(i));
                    return;
                }
                // A first click only chooses, even on the option already marked (the
                // default is not a choice): the second click on it answers. A tap that
                // lands on a row the panel just moved under the thumb cannot approve.
                let armed = self.view.sel == i
                    && matches!((&self.clicked, &self.sel_for),
                        (Some((id, n)), Some(cur)) if id == cur && *n == i);
                if armed {
                    self.answer(i);
                } else {
                    self.confirm = None;
                    self.view.sel = i;
                    self.clicked = self.sel_for.clone().map(|id| (id, i));
                }
                return;
            }
        }
        self.confirm = None;
        if self.view.click_newest(row) {
            return;
        }
        let now = self.motion.then(|| self.now_ms());
        self.view.click_fold(row, now);
    }

    /// Puts what the finished selection covers on the clipboard, from the frame just drawn, and
    /// says so. False when there was nothing to copy.
    fn copy_selection(&mut self, drawn: &ratatui::buffer::Buffer) -> bool {
        self.copy = false;
        let Some(range) = self.view.select.and_then(|s| s.range()) else {
            return false;
        };
        let text = select::text(drawn, range);
        if text.is_empty() {
            return false;
        }
        let mut out = std::io::stdout();
        let _ = out.write_all(&select::osc52(&text));
        let _ = out.flush();
        let n = text.chars().count();
        self.hint = Some(format!(
            "Copied {n} character{}",
            if n == 1 { "" } else { "s" }
        ));
        true
    }

    fn handle(&mut self, ev: Ev) {
        // What was selected is screen cells as they were drawn: anything but the pointer itself
        // (or output moving under a finished selection) leaves it pointing at other text.
        match &ev {
            Ev::Mouse(_) | Ev::Repaint => {}
            Ev::Session(_) => {
                // Not while the copy of a just-finished drag is still to be made: the
                // release and this event may arrive in one batch.
                if !self.copy && self.view.select.is_some_and(|s| s.done) {
                    self.view.select = None;
                }
            }
            _ => self.view.select = None,
        }
        match ev {
            Ev::Key(k) => {
                self.hint = None;
                if !matches!(k.code, KeyCode::Char('1'..='9') | KeyCode::Enter) {
                    self.confirm = None;
                }
                self.key(k);
            }
            Ev::Mouse(m) => self.mouse(m),
            Ev::Resize => {}
            Ev::Repaint => self.repaint = true,
            Ev::Paste(text) => self.paste(&text),
            Ev::Signal(sig) => {
                self.signal = Some(sig);
                self.quit = true;
            }
            Ev::Session(e) => {
                let fx = self.session.handle(e, self.now_ms(), &mut self.transcript);
                self.run(fx);
            }
        }
        self.sync_box();
        self.look_for_newer();
    }

    /// Looks at the installed file when something already woke the screen, and at most every few
    /// seconds.
    fn look_for_newer(&mut self) {
        if self.watched.elapsed() < Duration::from_secs(3) {
            return;
        }
        self.watched = Instant::now();
        if let Some(v) = self.watch.poll() {
            self.newer = Some(v);
        }
    }

    /// `Ctrl-R`: load the newer herdr-tui into this session, when nothing would be lost.
    fn load_newer(&mut self) {
        if !self.composer.text.is_empty() {
            self.hint = Some("Send or clear your message first, then Ctrl-R".to_string());
        } else if !self.session.waiting().is_empty() {
            self.hint = Some("Answer the request first, then Ctrl-R".to_string());
        } else {
            self.reload = true;
            self.quit = true;
        }
    }

    fn asking_question(&self) -> bool {
        self.session
            .waiting()
            .first()
            .is_some_and(|w| w.question().is_some())
    }

    /// While a question waits, the composer belongs to it: the person's own draft is set aside
    /// (it comes back when the question goes), and on a typed field the box holds that field's
    /// text, so Enter can never send a prompt by accident.
    fn sync_box(&mut self) {
        let head = self
            .session
            .waiting()
            .first()
            .and_then(|w| w.question().map(|q| (w.id.clone(), q.at())));
        let Some(at) = head else {
            self.boxed = None;
            if let Some(draft) = self.stash.take() {
                self.composer.clear();
                self.composer.restore(draft);
            }
            return;
        };
        if self.stash.is_none() {
            self.stash = Some(std::mem::take(&mut self.composer.text));
            self.composer.clear();
            self.boxed = None;
        }
        if self.boxed.as_ref() == Some(&at) {
            return;
        }
        self.composer.clear();
        if let Some(q) = self.session.waiting().first().and_then(|w| w.question()) {
            if q.typed() {
                self.composer.restore(q.text().to_string());
            }
        }
        self.boxed = Some(at);
    }

    /// Carries out effects. Reading the record answers at once, so it may produce more.
    fn run(&mut self, effects: Vec<Effect>) {
        let mut queue = std::collections::VecDeque::from(effects);
        while let Some(fx) = queue.pop_front() {
            match fx {
                Effect::Send(m) => {
                    let mut line = m.to_line();
                    line.push('\n');
                    if self.out.write_all(line.as_bytes()).is_err() {
                        let more =
                            self.session
                                .handle(Event::Closed, self.now_ms(), &mut self.transcript);
                        queue.extend(more);
                    }
                }
                Effect::ReadRecord => {
                    let rec = self.dir.read(&self.id).map(|i| Record {
                        session_id: i.session_id,
                        cwd: if i.cwd.is_empty() { "/".into() } else { i.cwd },
                        exited: (i.state == keeper::records::State::Exited)
                            .then(|| i.exit_reason.unwrap_or_else(|| "the agent exited".into())),
                    });
                    let more = self.session.handle(
                        Event::Record(rec),
                        self.now_ms(),
                        &mut self.transcript,
                    );
                    queue.extend(more);
                }
                Effect::RetryIn(d) => {
                    let tx = self.tx.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(d.max(Duration::from_millis(1)));
                        let _ = tx.send(Ev::Session(Event::Retry));
                    });
                }
                Effect::RestoreInput(t) => self.composer.restore(t),
            }
        }
    }

    /// A paste goes into the box whole: no line of it is sent, and nothing in it acts as a key.
    fn paste(&mut self, text: &str) {
        // A question's choices are picked on the panel: a paste there would go nowhere.
        let choosing = self
            .session
            .waiting()
            .first()
            .and_then(|w| w.question())
            .is_some_and(|q| !q.typed());
        if choosing {
            self.hint = Some(QUESTION_HINT.to_string());
            return;
        }
        let (clean, cut) = input::clean_paste(text);
        self.view.focus = None;
        self.view.invalidate_lines();
        self.composer.insert_str(&clean);
        self.hint = cut.then(|| format!("The paste was cut at {} KB", input::MAX_PASTE / 1024));
    }

    /// Browse mode starts on the newest thing that can be opened.
    fn enter_browse(&mut self) {
        let keys = fold::focusable(self.transcript.items(), &self.view.expanded);
        match keys.last() {
            Some(last) => {
                self.view.focus = Some(*last);
                self.view.focus_dirty = true;
                self.view.invalidate_lines();
            }
            None => self.hint = Some("Nothing to fold yet".to_string()),
        }
    }

    /// Browse mode: move among what can be opened, open it, close it. `true` when the key
    /// was used here; scrolling and Ctrl chords go on to the usual handling.
    fn browse_key(&mut self, k: KeyEvent) -> bool {
        use fold::Nav;
        if k.modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return false;
        }
        let nav = match k.code {
            KeyCode::Esc | KeyCode::Char('i') => {
                self.view.focus = None;
                self.view.invalidate_lines();
                return true;
            }
            KeyCode::Up | KeyCode::Char('k') => Nav::Prev,
            KeyCode::Down | KeyCode::Char('j') => Nav::Next,
            KeyCode::Right | KeyCode::Char('l' | ' ') | KeyCode::Enter => Nav::Open,
            KeyCode::Left | KeyCode::Char('h') => Nav::Close,
            KeyCode::Char('a') => Nav::OpenAll,
            KeyCode::Char('z') => Nav::CloseAll,
            KeyCode::PageUp | KeyCode::PageDown | KeyCode::Home | KeyCode::End => return false,
            // Any other letter was meant for the message: leave browsing and type it.
            KeyCode::Char(c) => {
                self.view.focus = None;
                self.view.invalidate_lines();
                self.composer.insert(c);
                return true;
            }
            _ => return true,
        };
        let keys = fold::focusable(self.transcript.items(), &self.view.expanded);
        let Some(&last) = keys.last() else {
            self.view.focus = None;
            self.view.invalidate_lines();
            return true;
        };
        // What was focused may have been dropped to stay in budget.
        let focus = self.view.focus.filter(|f| keys.contains(f)).unwrap_or(last);
        let (to, opened) = fold::navigate(nav, focus, &keys, &mut self.view.expanded);
        // What was just opened grows into place.
        let now = self.now_ms();
        if self.motion {
            for key in opened {
                self.view.reveal.insert(key, now);
            }
        }
        self.view.invalidate_lines();
        self.view.focus = Some(to);
        self.view.focus_dirty = true;
        true
    }

    fn key(&mut self, k: KeyEvent) {
        // The key list closes on `?`, Esc or Enter; any other key closes it and does its own job.
        if self.view.help {
            self.view.help = false;
            if matches!(k.code, KeyCode::Char('?') | KeyCode::Esc | KeyCode::Enter) {
                return;
            }
        } else if k.code == KeyCode::Char('?')
            && self.composer.text.is_empty()
            && self.session.waiting().is_empty()
        {
            self.view.help = true;
            return;
        }
        if self.view.focus.is_some() && self.browse_key(k) {
            return;
        }
        if self.question_key(k) {
            return;
        }
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        let alt = k.modifiers.contains(KeyModifiers::ALT);
        match k.code {
            // With nothing typed and nothing asking, Esc browses what the agent did; with a request
            // waiting it withdraws the request.
            KeyCode::Esc if self.composer.text.is_empty() && self.session.waiting().is_empty() => {
                self.enter_browse()
            }
            KeyCode::Esc if self.composer.text.is_empty() => self.dismiss(),
            KeyCode::Char('d') if ctrl => self.quit = true,
            KeyCode::Char('c') if ctrl => {
                if self.transcript.running() || self.session.prompting() {
                    let fx = self.session.cancel(&mut self.transcript);
                    self.run(fx);
                } else if self.composer.text.is_empty() {
                    self.quit = true;
                } else {
                    self.composer.clear();
                }
            }
            KeyCode::Char('t') if ctrl => {
                self.view.thoughts = !self.view.thoughts;
                self.view.invalidate_lines();
            }
            // Sent messages, as in a shell: Up and Down are for scrolling.
            KeyCode::Char('p') if ctrl => {
                self.composer.older();
            }
            KeyCode::Char('n') if ctrl => {
                self.composer.newer();
            }
            // Another program (an image viewer's warnings, a stray `echo`) can write on this
            // terminal behind our back; this puts the screen right.
            KeyCode::Char('l') if ctrl => self.repaint = true,
            KeyCode::Char('r') if ctrl && self.newer.is_some() => self.load_newer(),
            KeyCode::Char('w') if ctrl => self.composer.kill_word(),
            KeyCode::Char('u') if ctrl => self.composer.clear(),
            KeyCode::Char('j') if ctrl => self.composer.insert('\n'),
            KeyCode::Enter if alt || k.modifiers.contains(KeyModifiers::SHIFT) => {
                self.composer.insert('\n')
            }
            // On the permission panel, Enter confirms the chosen option, if nothing is typed.
            KeyCode::Enter
                if self.composer.text.is_empty() && !self.session.waiting().is_empty() =>
            {
                self.answer(self.view.sel);
            }
            KeyCode::Enter => self.send(),
            KeyCode::Tab | KeyCode::BackTab if self.session.permission_waiting() => {
                let n = self.session.waiting()[0]
                    .permission()
                    .map_or(1, |r| r.options.len().max(1));
                self.view.sel = if k.code == KeyCode::Tab {
                    (self.view.sel + 1) % n
                } else {
                    (self.view.sel + n - 1) % n
                };
            }
            // With a request waiting and nothing typed, Up and Down walk its options (and stop at
            // the ends); the conversation still scrolls with PgUp, PgDn and the wheel.
            KeyCode::Up | KeyCode::Down
                if self.composer.text.is_empty() && self.session.permission_waiting() =>
            {
                let last = self.session.waiting()[0]
                    .permission()
                    .map_or(0, |r| r.options.len().saturating_sub(1));
                self.view.sel = if k.code == KeyCode::Up {
                    self.view.sel.saturating_sub(1)
                } else {
                    (self.view.sel + 1).min(last)
                };
            }
            // A digit answers only with an empty box: one being typed into a
            // message never answers a permission.
            KeyCode::Char(c @ '1'..='9')
                if !ctrl
                    && !alt
                    && self.composer.text.is_empty()
                    && self.session.permission_waiting() =>
            {
                self.answer(c as usize - '1' as usize);
            }
            KeyCode::Char(c) if !ctrl && !alt => self.composer.insert(c),
            KeyCode::Backspace => self.composer.backspace(),
            KeyCode::Delete => self.composer.delete(),
            KeyCode::Left => self.composer.left(),
            KeyCode::Right => self.composer.right(),
            // With nothing typed, Home goes to the start of the conversation.
            KeyCode::Home if self.composer.text.is_empty() => self.view.scroll = usize::MAX,
            KeyCode::Home => self.composer.home(),
            KeyCode::End if self.view.scroll > 0 => self.view.scroll = 0,
            KeyCode::End => self.composer.end(),
            // The wheel arrives as Up and Down in most terminals, so they scroll the
            // conversation; they move within a message only when it has several lines.
            KeyCode::Up => {
                if !(self.composer.text.contains('\n') && self.composer.up()) {
                    self.view.scroll = self.view.scroll.saturating_add(SCROLL_STEP);
                }
            }
            KeyCode::Down => {
                if !(self.composer.text.contains('\n') && self.composer.down()) {
                    self.view.scroll = self.view.scroll.saturating_sub(SCROLL_STEP);
                }
            }
            KeyCode::PageUp => self.view.scroll = self.view.scroll.saturating_add(self.view.page),
            KeyCode::PageDown => self.view.scroll = self.view.scroll.saturating_sub(self.view.page),
            _ => {}
        }
    }

    /// Keys for the question on screen. `true` when the key was the question's: on a typed field
    /// everything but Enter, Shift-Tab and Esc edits the box as usual.
    fn question_key(&mut self, k: KeyEvent) -> bool {
        let Some(typed) = self
            .session
            .waiting()
            .first()
            .and_then(|w| w.question())
            .map(|q| q.typed())
        else {
            return false;
        };
        // Ctrl-C still stops the turn, Ctrl-U clears, Ctrl-J breaks a typed answer's line.
        if k.modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return false;
        }
        let act = match k.code {
            KeyCode::Esc => {
                if question::esc_declines(typed, &self.composer.text) {
                    self.dismiss();
                }
                return true;
            }
            KeyCode::Enter if typed && k.modifiers.contains(KeyModifiers::SHIFT) => return false,
            // The box is empty on a choice: only a typed field's text goes with it.
            KeyCode::Enter => Act::Enter(self.composer.text.clone()),
            KeyCode::BackTab => Act::Back(self.composer.text.clone()),
            _ if typed => return false,
            KeyCode::Up => Act::Up,
            KeyCode::Down => Act::Down,
            KeyCode::Char(' ') => Act::Toggle,
            KeyCode::Char(c @ '1'..='9') => Act::Pick(c as usize - '1' as usize),
            KeyCode::Char(_) | KeyCode::Tab | KeyCode::Backspace | KeyCode::Delete => {
                self.hint = Some(QUESTION_HINT.to_string());
                return true;
            }
            _ => return false,
        };
        self.ask(act);
        true
    }

    fn ask(&mut self, act: Act) {
        // As for a permission: the question the person is looking at, as last drawn.
        let Some(shown) = self.sel_for.clone() else {
            return;
        };
        let result = self
            .session
            .question_for(&shown, act, self.now_ms(), &mut self.transcript);
        self.finish_answer(result);
    }

    fn answer(&mut self, index: usize) {
        // The request the person is looking at, as last drawn. A key meant for it must never be
        // applied to whatever took its place while the keys were queued.
        let Some(shown) = self.sel_for.clone() else {
            return;
        };
        // An answer that outlives this call ("always allow") is meant twice, for the same request.
        let standing = self
            .session
            .waiting()
            .first()
            .filter(|w| w.id == shown)
            .and_then(|w| w.permission())
            .and_then(|r| r.options.get(index))
            .is_some_and(|o| o.is_standing());
        if standing && self.confirm.as_ref() != Some(&(shown.clone(), index)) {
            self.confirm = Some((shown, index));
            self.hint = Some(format!(
                "This stays allowed. Press {} again to confirm",
                index + 1
            ));
            return;
        }
        self.confirm = None;
        let result = self
            .session
            .answer_for(&shown, index, self.now_ms(), &mut self.transcript);
        self.finish_answer(result);
    }

    /// Esc on a request: withdraw a permission (the way out of one that offers nothing to
    /// choose), decline a question.
    fn dismiss(&mut self) {
        let Some(shown) = self.sel_for.clone() else {
            return;
        };
        self.confirm = None;
        let result = self
            .session
            .dismiss_for(&shown, self.now_ms(), &mut self.transcript);
        self.finish_answer(result);
    }

    fn finish_answer(&mut self, result: Result<Vec<Effect>, Refused>) {
        match result {
            // The agent goes on from the answer: follow it. A mark or a move on a question sends
            // nothing and leaves the conversation where the person had scrolled it.
            Ok(fx) => {
                if !fx.is_empty() {
                    self.view.scroll = 0;
                }
                self.run(fx);
            }
            // A key right after the card appeared was meant for something else.
            Err(Refused::TooSoon | Refused::NothingWaiting) => {}
            Err(Refused::Changed) => {
                self.hint =
                    Some("That request was answered elsewhere; look at the next one".to_string())
            }
            Err(Refused::Ended) => self.hint = Some("The session is over".to_string()),
            // The field keeps what was typed; the footer says what is wrong.
            Err(Refused::Invalid(why)) => self.hint = Some(why),
            Err(_) => self.hint = Some("No such option".to_string()),
        }
    }

    fn send(&mut self) {
        let text = self.composer.text.trim().to_string();
        if text.is_empty() {
            return;
        }
        match self.session.send(&text, &mut self.transcript) {
            Ok(fx) => {
                self.composer.take();
                self.view.scroll = 0;
                self.run(fx);
            }
            // The text stays in the box.
            Err(Refused::NotReady) => self.hint = Some("The session is not open yet".to_string()),
            Err(Refused::Busy) => self.hint = Some("The agent is working; not sent".to_string()),
            Err(_) => {}
        }
    }
}
