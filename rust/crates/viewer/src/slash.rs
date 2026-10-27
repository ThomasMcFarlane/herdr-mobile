//! Slash commands: the list shown while the person types `/`, what a typed line means, and the
//! pickers that change the model, the thinking level, the mode or any other setting.
//!
//! Pure: no I/O. A few commands belong to this program (`/model`, `/plan`, `/settings`, `/info`,
//! `/new`, ...); the rest are the agent's own (`available_commands_update`) and go to it as the
//! text typed. A local command is never sent to the agent: omp's ACP mode has no `/clear` or
//! `/new`, so it would reach the model as chat.

use crate::transcript::Transcript;

/// Rows of the command list drawn at once.
pub const MAX_ROWS: usize = 6;

/// A command this program carries out itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Local {
    Model,
    Thinking,
    Mode,
    /// Into plan mode, and back out of it.
    Plan,
    /// Every setting the agent lets the person change.
    Settings,
    /// The files attached to the next message: take one off.
    Files,
    /// Which herdr-tui this is and which session it shows.
    Info,
    /// Install a newer (or named) herdr-tui.
    Update,
    /// A new session in this pane (`/new`, also `/clear`).
    Fresh,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    Local(Local),
    /// One of the agent's own commands.
    Agent,
    /// One of the agent's skills (`skill:name`): a command that loads instructions.
    Skill,
}

/// One row of the command list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// Without the slash.
    pub name: String,
    pub description: String,
    /// What the argument looks like, for an agent command that takes one.
    pub hint: Option<String>,
    pub kind: Kind,
    /// Why it cannot be used now; the row stays, dim, with this in place of the description.
    pub reason: Option<String>,
    pub aliases: &'static [&'static str],
}

/// The select option a local command changes.
#[must_use]
pub fn option_of(tr: &Transcript, local: Local) -> Option<&acp::ConfigOption> {
    match local {
        Local::Model => tr.option("model"),
        Local::Thinking => tr.option("thought_level").or_else(|| tr.option("thinking")),
        Local::Mode | Local::Plan => tr.option("mode"),
        Local::Settings | Local::Info | Local::Fresh | Local::Files | Local::Update => None,
    }
}

fn noun(local: Local) -> &'static str {
    match local {
        Local::Model => "model",
        Local::Thinking => "thinking level",
        _ => "mode",
    }
}

/// The choice that is plan mode: named `plan` by value or name, else the only one whose name
/// has `plan` in it.
fn plan_choice(opt: &acp::ConfigOption) -> Option<&(String, String)> {
    let is = |c: &&(String, String), exact: bool| {
        let (v, n) = (c.0.to_lowercase(), c.1.to_lowercase());
        if exact {
            v == "plan" || n == "plan"
        } else {
            v.contains("plan") || n.contains("plan")
        }
    };
    opt.choices.iter().find(|c| is(c, true)).or_else(|| {
        let mut some = opt.choices.iter().filter(|c| is(c, false));
        let first = some.next()?;
        some.next().is_none().then_some(first)
    })
}

/// The settings that can be changed here: every select the agent reported, with a choice to
/// make and a way to make it. `(option id, "Name · current")`.
#[must_use]
pub fn settings_rows(tr: &Transcript) -> Vec<(String, String)> {
    tr.options()
        .iter()
        .filter(|o| !o.legacy && o.choices.len() >= 2)
        .map(|o| {
            (
                o.id.clone(),
                format!("{} · {}", o.name, o.current_name().unwrap_or("-")),
            )
        })
        .collect()
}

/// Why `local` cannot be used now, in the person's words, or `None` when it can.
#[must_use]
pub fn unavailable(tr: &Transcript, local: Local, can_fresh: bool) -> Option<String> {
    match local {
        Local::Fresh => (!can_fresh).then(|| "needs the session's agent and folder".to_string()),
        Local::Info | Local::Files => None,
        Local::Update => crate::update::asset()
            .is_none()
            .then(|| "no release build for this computer".to_string()),
        Local::Settings => settings_rows(tr)
            .is_empty()
            .then(|| "no settings to change here".to_string()),
        Local::Plan => match tr.option("mode") {
            None => Some("no modes to choose here".to_string()),
            Some(o) if o.legacy => Some("can't be changed from here".to_string()),
            Some(o) => plan_choice(o)
                .is_none()
                .then(|| "this agent has no plan mode".to_string()),
        },
        Local::Model | Local::Thinking | Local::Mode => match option_of(tr, local) {
            None => Some(format!("no {} to choose here", noun(local))),
            Some(o) if o.legacy => Some("can't be changed from here".to_string()),
            Some(o) if o.choices.len() < 2 => {
                Some(format!("no other {} to choose here", noun(local)))
            }
            Some(_) => None,
        },
    }
}

/// The commands of this program, in the order they are listed.
#[must_use]
pub fn locals(tr: &Transcript, can_fresh: bool) -> Vec<Entry> {
    let row = |local, name: &str, description: &str, aliases| Entry {
        name: name.to_string(),
        description: description.to_string(),
        hint: None,
        kind: Kind::Local(local),
        reason: unavailable(tr, local, can_fresh),
        aliases,
    };
    vec![
        row(Local::Model, "model", "Switch model", &[]),
        row(Local::Thinking, "thinking", "Thinking level", &[]),
        row(Local::Mode, "mode", "Mode (Shift-Tab: next)", &[]),
        row(Local::Plan, "plan", "Plan mode (again: back)", &[]),
        row(
            Local::Settings,
            "settings",
            "Every setting of this session",
            &[],
        ),
        row(
            Local::Files,
            "files",
            "Attached files: take one off",
            &["attachments", "detach"],
        ),
        row(
            Local::Info,
            "info",
            "About herdr-tui and this session",
            &["version", "about"],
        ),
        Entry {
            hint: Some("[check|VERSION]".to_string()),
            ..row(Local::Update, "update", "Install the latest herdr-tui", &[])
        },
        row(
            Local::Fresh,
            "new",
            "Fresh session (also /clear)",
            &["clear"],
        ),
    ]
}

fn local_named(name: &str) -> Option<Local> {
    match name {
        "model" => Some(Local::Model),
        "thinking" => Some(Local::Thinking),
        "mode" => Some(Local::Mode),
        "plan" => Some(Local::Plan),
        "settings" => Some(Local::Settings),
        "files" | "attachments" | "detach" => Some(Local::Files),
        "info" | "version" | "about" => Some(Local::Info),
        "update" => Some(Local::Update),
        "new" | "clear" => Some(Local::Fresh),
        _ => None,
    }
}

/// What the agent calls a skill: `skill:name`.
const SKILL: &str = "skill:";

/// The rows to list for `text`: none unless it is a `/` and one word. Prefix matches come before
/// the ones that only contain what was typed; within each, this program's commands, then the
/// agent's, then its skills (a skill also answers to its name without `skill:`). An agent
/// command with the name of a local one is dropped (the local one wins: omp's own `/model` only
/// prints the current model).
#[must_use]
pub fn entries(text: &str, agent: &[acp::Command], tr: &Transcript, can_fresh: bool) -> Vec<Entry> {
    let Some(query) = text.strip_prefix('/') else {
        return Vec::new();
    };
    if query.contains(char::is_whitespace) {
        return Vec::new();
    }
    let query = query.to_lowercase();
    let mut all = locals(tr, can_fresh);
    all.extend(
        agent
            .iter()
            .filter(|c| local_named(&c.name.to_lowercase()).is_none())
            .map(|c| Entry {
                name: c.name.clone(),
                description: c.description.clone(),
                hint: c.hint.clone(),
                kind: if c.name.starts_with(SKILL) {
                    Kind::Skill
                } else {
                    Kind::Agent
                },
                reason: None,
                aliases: &[],
            }),
    );
    let names = |e: &Entry| -> Vec<String> {
        let name = e.name.to_lowercase();
        let short = name.strip_prefix(SKILL).map(str::to_string);
        std::iter::once(name)
            .chain(short)
            .chain(e.aliases.iter().map(|a| (*a).to_string()))
            .collect()
    };
    let rank = |e: &Entry| match e.kind {
        Kind::Local(_) => 0,
        Kind::Agent => 1,
        Kind::Skill => 2,
    };
    let (mut prefix, mut inside) = (Vec::new(), Vec::new());
    for e in all {
        let n = names(&e);
        if n.iter().any(|n| n.starts_with(&query)) {
            prefix.push(e);
        } else if n.iter().any(|n| n.contains(&query)) {
            inside.push(e);
        }
    }
    prefix.sort_by_key(rank);
    inside.sort_by_key(rank);
    prefix.extend(inside);
    prefix
}

/// What a typed line means.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Run {
    /// Chat: send it as typed.
    Message,
    /// One of the agent's commands: send it as typed.
    Agent,
    /// A command of this program, with the rest of the line.
    Local(Local, String),
    /// Looks like a command the agent does not list: held once, since a typo would cost a turn.
    Unknown(String),
}

/// Whether `word` reads as a command (`/model`, `/skill:review`) and not as a path
/// (`/home/me/x`).
fn command_like(word: &str) -> Option<&str> {
    let name = word.strip_prefix('/')?;
    (!name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | ':' | '-' | '.')))
    .then_some(name)
}

/// What the line `text` is. An agent that never listed its commands is never guarded.
#[must_use]
pub fn classify(text: &str, agent: &[acp::Command]) -> Run {
    let text = text.trim();
    let word = text.split_whitespace().next().unwrap_or("");
    let Some(name) = command_like(word) else {
        return Run::Message;
    };
    let lower = name.to_lowercase();
    if let Some(local) = local_named(&lower) {
        return Run::Local(local, text[word.len()..].trim().to_string());
    }
    if agent.iter().any(|c| c.name.eq_ignore_ascii_case(name)) {
        Run::Agent
    } else if agent.is_empty() {
        Run::Message
    } else {
        Run::Unknown(name.to_string())
    }
}

/// The choices of one option, with the one the cursor is on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Picker {
    /// The option the rows are the choices of; empty for the list of settings.
    pub option_id: String,
    pub title: String,
    /// `(value, name)`; on the list of settings, `(option id, "Name · current")`.
    pub rows: Vec<(String, String)>,
    pub current: Option<String>,
    pub sel: usize,
    /// What the rows are.
    pub kind: PickerKind,
}

/// What a picker's rows are.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PickerKind {
    /// The choices of one option (`/model`).
    Choices,
    /// The settings themselves: choosing one opens its choices (`/settings`).
    Settings,
    /// The files attached to the next message: choosing one takes it off (`/files`).
    Files,
}

impl Picker {
    pub fn up(&mut self) {
        self.sel = self.sel.saturating_sub(1);
    }

    pub fn down(&mut self) {
        self.sel = (self.sel + 1).min(self.rows.len().saturating_sub(1));
    }

    #[must_use]
    pub fn chosen(&self) -> Option<&(String, String)> {
        self.rows.get(self.sel)
    }
}

/// The list of settings, to choose which to change; `None` when there are none.
#[must_use]
pub fn settings(tr: &Transcript) -> Option<Picker> {
    let rows = settings_rows(tr);
    (!rows.is_empty()).then(|| Picker {
        option_id: String::new(),
        title: "Settings".to_string(),
        rows,
        current: None,
        sel: 0,
        kind: PickerKind::Settings,
    })
}

/// The picker of attached files, by their labels, on the last one (the one Backspace takes off).
/// A row's value is its place in the list.
#[must_use]
pub fn attached(labels: &[String]) -> Picker {
    Picker {
        option_id: String::new(),
        title: "Attached files".to_string(),
        rows: labels
            .iter()
            .enumerate()
            .map(|(i, l)| (i.to_string(), l.clone()))
            .collect(),
        current: None,
        sel: labels.len().saturating_sub(1),
        kind: PickerKind::Files,
    }
}

/// What `/model <args>` comes to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pick {
    Open(Picker),
    Apply {
        value: String,
        name: String,
    },
    /// Nothing to do; the sentence says why.
    Nothing(String),
}

/// Opens the picker for `opt`, or applies the one choice `args` names: exact on a value or name,
/// else the only one that contains it. Several that contain it open the picker on those alone.
#[must_use]
pub fn pick(opt: &acp::ConfigOption, args: &str) -> Pick {
    let open = |rows: Vec<(String, String)>| {
        let sel = rows
            .iter()
            .position(|(v, _)| Some(v) == opt.current.as_ref())
            .unwrap_or(0);
        Pick::Open(Picker {
            option_id: opt.id.clone(),
            title: opt.name.clone(),
            rows,
            current: opt.current.clone(),
            sel,
            kind: PickerKind::Choices,
        })
    };
    let args = args.trim();
    if args.is_empty() {
        return open(opt.choices.clone());
    }
    let want = args.to_lowercase();
    let apply = |(value, name): &(String, String)| Pick::Apply {
        value: value.clone(),
        name: name.clone(),
    };
    if let Some(exact) = opt
        .choices
        .iter()
        .find(|(v, n)| v.to_lowercase() == want || n.to_lowercase() == want)
    {
        return apply(exact);
    }
    let some: Vec<(String, String)> = opt
        .choices
        .iter()
        .filter(|(v, n)| v.to_lowercase().contains(&want) || n.to_lowercase().contains(&want))
        .cloned()
        .collect();
    match some.as_slice() {
        [] => Pick::Nothing(format!("no {} matches \"{args}\"", opt.name.to_lowercase())),
        [one] => apply(one),
        _ => open(some),
    }
}

/// Where `/plan` goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlanMove {
    pub value: String,
    pub name: String,
    /// Into plan mode (so the mode left is worth remembering), not out of it.
    pub entering: bool,
}

/// `/plan`: into plan mode, or, when already there, back to the mode `before` (if it is still a
/// choice), else to the one called `default`, else to the first other.
///
/// # Errors
/// A sentence saying why there is nowhere to go.
pub fn plan_move(opt: &acp::ConfigOption, before: Option<&str>) -> Result<PlanMove, String> {
    let plan = plan_choice(opt).ok_or_else(|| "this agent has no plan mode".to_string())?;
    let go = |c: &(String, String), entering| PlanMove {
        value: c.0.clone(),
        name: c.1.clone(),
        entering,
    };
    if opt.current.as_deref() != Some(plan.0.as_str()) {
        return Ok(go(plan, true));
    }
    let others = || opt.choices.iter().filter(|c| c.0 != plan.0);
    before
        .and_then(|b| others().find(|c| c.0 == b))
        .or_else(|| {
            others().find(|c| {
                c.0.eq_ignore_ascii_case("default") || c.1.eq_ignore_ascii_case("default")
            })
        })
        .or_else(|| others().next())
        .map(|c| go(c, false))
        .ok_or_else(|| "already in plan mode, and it is the only one".to_string())
}

/// Shift-Tab: the choice after the current one, round to the first. `None` when there is
/// nothing to change to.
#[must_use]
pub fn next_choice(opt: &acp::ConfigOption) -> Option<(String, String)> {
    if opt.legacy || opt.choices.len() < 2 {
        return None;
    }
    let at = opt
        .choices
        .iter()
        .position(|(v, _)| Some(v) == opt.current.as_ref());
    opt.choices
        .get(at.map_or(0, |i| (i + 1) % opt.choices.len()))
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use acp::SessionUpdate;
    use serde_json::json;

    fn cmd(name: &str, hint: Option<&str>) -> acp::Command {
        acp::Command {
            name: name.into(),
            description: format!("does {name}"),
            hint: hint.map(Into::into),
        }
    }

    fn tr_with(options: serde_json::Value) -> Transcript {
        let mut tr = Transcript::default();
        tr.apply(
            SessionUpdate::from_value(
                &json!({"sessionUpdate": "config_option_update", "configOptions": options}),
            )
            .expect("update"),
        );
        tr
    }

    fn models() -> serde_json::Value {
        json!([{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "b",
            "options": [{"value": "a", "name": "Opus 4.1"}, {"value": "b", "name": "Sonnet 5.5"}, {"value": "c", "name": "Sonnet 4"}]}])
    }

    fn modes(current: &str) -> serde_json::Value {
        json!([{"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": current,
            "options": [{"value": "default", "name": "Default"}, {"value": "acceptEdits", "name": "Accept edits"}, {"value": "plan", "name": "Plan"}]}])
    }

    fn names(e: &[Entry]) -> Vec<&str> {
        e.iter().map(|e| e.name.as_str()).collect()
    }

    #[test]
    fn the_list_puts_prefix_matches_first_then_local_before_agent_and_hides_a_shadowed_name() {
        let tr = Transcript::default();
        let agent = [
            cmd("compact", None),
            cmd("model", None),
            cmd("remodel-x", None),
            cmd("new", None),
        ];
        let got = entries("/mo", &agent, &tr, true);
        assert_eq!(names(&got), ["model", "mode", "remodel-x"]);
        assert!(got.iter().filter(|e| e.name == "model").count() == 1);
        assert_eq!(got[0].kind, Kind::Local(Local::Model));
        assert_eq!(
            names(&entries("/", &agent, &tr, true)),
            [
                "model",
                "thinking",
                "mode",
                "plan",
                "settings",
                "files",
                "info",
                "update",
                "new",
                "compact",
                "remodel-x"
            ]
        );
        assert_eq!(
            names(&entries("/cl", &[], &tr, true)),
            ["new"],
            "/clear is found, and listed as /new"
        );
        assert_eq!(
            names(&entries("/vers", &[], &tr, true)),
            ["info"],
            "/version is found, and listed as /info"
        );
    }

    #[test]
    fn skills_follow_the_commands_and_answer_to_their_name_without_the_prefix() {
        let tr = Transcript::default();
        let agent = [
            cmd("skill:review", None),
            cmd("compact", None),
            cmd("skill:compose", Some("[what]")),
        ];
        let all = entries("/", &agent, &tr, true);
        assert_eq!(
            names(&all)[9..],
            ["compact", "skill:review", "skill:compose"],
            "locals, then commands, then skills, each in the order given"
        );
        assert_eq!(all[10].kind, Kind::Skill);
        assert_eq!(
            names(&entries("/rev", &agent, &tr, true)),
            ["skill:review"],
            "a prefix of the short name matches"
        );
        assert_eq!(
            names(&entries("/co", &agent, &tr, true)),
            ["compact", "skill:compose"]
        );
    }

    #[test]
    fn the_list_closes_once_the_line_has_a_space_or_is_not_a_command() {
        let tr = Transcript::default();
        assert!(entries("/model x", &[], &tr, true).is_empty());
        assert!(entries("hello", &[], &tr, true).is_empty());
        assert!(entries("", &[], &tr, true).is_empty());
        assert!(entries("/\nx", &[], &tr, true).is_empty());
    }

    #[test]
    fn a_command_that_cannot_run_stays_listed_with_its_reason() {
        let tr = Transcript::default();
        let got = entries("/model", &[], &tr, false);
        assert_eq!(got[0].reason.as_deref(), Some("no model to choose here"));
        let new = entries("/new", &[], &tr, false);
        assert_eq!(
            new[0].reason.as_deref(),
            Some("needs the session's agent and folder")
        );
        assert_eq!(
            entries("/plan", &[], &tr, true)[0].reason.as_deref(),
            Some("no modes to choose here")
        );
        assert_eq!(
            entries("/settings", &[], &tr, true)[0].reason.as_deref(),
            Some("no settings to change here")
        );
        assert_eq!(entries("/info", &[], &tr, false)[0].reason, None);
        let one = tr_with(
            json!([{"id": "model", "name": "Model", "type": "select", "currentValue": "a", "options": [{"value": "a"}]}]),
        );
        assert_eq!(
            entries("/model", &[], &one, true)[0].reason.as_deref(),
            Some("no other model to choose here")
        );
        let both = tr_with(models());
        assert_eq!(entries("/model", &[], &both, true)[0].reason, None);
        let old = {
            let mut t = Transcript::default();
            t.apply(SessionUpdate::Config(vec![acp::legacy_models(
                &json!({"models": {"currentModelId": "m", "availableModels": [{"modelId": "m"}, {"modelId": "n"}]}}),
            )
            .expect("legacy")]));
            t
        };
        assert_eq!(
            entries("/model", &[], &old, true)[0].reason.as_deref(),
            Some("can't be changed from here")
        );
        let no_plan = tr_with(
            json!([{"id": "mode", "category": "mode", "type": "select", "currentValue": "a", "options": [{"value": "a"}, {"value": "b"}]}]),
        );
        assert_eq!(
            entries("/plan", &[], &no_plan, true)[0].reason.as_deref(),
            Some("this agent has no plan mode")
        );
    }

    #[test]
    fn a_typed_line_is_a_local_command_an_agent_command_a_held_typo_or_chat() {
        let agent = [cmd("compact", Some("[focus]")), cmd("skill:review", None)];
        assert_eq!(
            classify("/clear", &agent),
            Run::Local(Local::Fresh, String::new())
        );
        assert_eq!(
            classify("/new", &[]),
            Run::Local(Local::Fresh, String::new())
        );
        assert_eq!(
            classify("/MODEL  opus ", &agent),
            Run::Local(Local::Model, "opus".into())
        );
        assert_eq!(
            classify("/version", &agent),
            Run::Local(Local::Info, String::new())
        );
        assert_eq!(
            classify("/plan", &agent),
            Run::Local(Local::Plan, String::new())
        );
        assert_eq!(
            classify("/settings", &agent),
            Run::Local(Local::Settings, String::new())
        );
        assert_eq!(classify("/compact now", &agent), Run::Agent);
        assert_eq!(classify("/skill:review", &agent), Run::Agent);
        assert_eq!(classify("/clera", &agent), Run::Unknown("clera".into()));
        assert_eq!(classify("/clera", &[]), Run::Message, "no list, no guard");
        assert_eq!(
            classify("/home/me/x look at this", &agent),
            Run::Message,
            "a path is chat"
        );
        assert_eq!(classify("hello /model", &agent), Run::Message);
        assert_eq!(classify("/", &agent), Run::Message);
    }

    #[test]
    fn model_with_words_applies_the_one_match_narrows_several_and_says_when_none() {
        let tr = tr_with(models());
        let opt = tr.option("model").expect("model");
        assert_eq!(
            pick(opt, "opus"),
            Pick::Apply {
                value: "a".into(),
                name: "Opus 4.1".into()
            }
        );
        assert_eq!(
            pick(opt, "SONNET 4"),
            Pick::Apply {
                value: "c".into(),
                name: "Sonnet 4".into()
            },
            "an exact name wins over a longer one that contains it"
        );
        let Pick::Open(p) = pick(opt, "sonnet") else {
            panic!("two match: a picker")
        };
        assert_eq!(p.rows.len(), 2);
        assert_eq!(
            pick(opt, "zzz"),
            Pick::Nothing("no model matches \"zzz\"".into())
        );
    }

    #[test]
    fn the_picker_opens_on_the_current_choice_and_stops_at_the_ends() {
        let tr = tr_with(models());
        let Pick::Open(mut p) = pick(tr.option("model").expect("model"), "") else {
            panic!("open")
        };
        assert_eq!(p.chosen().map(|c| c.0.as_str()), Some("b"));
        p.down();
        p.down();
        assert_eq!(p.sel, 2, "stops at the last");
        p.up();
        p.up();
        p.up();
        assert_eq!(p.sel, 0, "stops at the first");
        assert_eq!(p.option_id, "model");
    }

    #[test]
    fn plan_goes_in_and_comes_back_to_where_it_was_else_to_default() {
        let tr = tr_with(modes("acceptEdits"));
        let opt = tr.option("mode").expect("mode");
        let into = plan_move(opt, None).expect("plan");
        assert_eq!((into.value.as_str(), into.entering), ("plan", true));
        let tr = tr_with(modes("plan"));
        let opt = tr.option("mode").expect("mode");
        let back = plan_move(opt, Some("acceptEdits")).expect("back");
        assert_eq!((back.value.as_str(), back.entering), ("acceptEdits", false));
        assert_eq!(
            plan_move(opt, None).expect("default").value,
            "default",
            "nothing remembered: the mode called default"
        );
        assert_eq!(
            plan_move(opt, Some("plan")).expect("not itself").value,
            "default"
        );
        let only = tr_with(
            json!([{"id": "mode", "type": "select", "currentValue": "plan", "options": [{"value": "plan"}]}]),
        );
        assert!(plan_move(only.option("mode").expect("mode"), None).is_err());
        let none = tr_with(modes("default"));
        let mut opt = none.option("mode").expect("mode").clone();
        opt.choices.retain(|c| c.0 != "plan");
        assert_eq!(
            plan_move(&opt, None),
            Err("this agent has no plan mode".into())
        );
    }

    #[test]
    fn shift_tab_cycles_the_mode_and_wraps() {
        let tr = tr_with(modes("acceptEdits"));
        assert_eq!(
            next_choice(tr.option("mode").expect("mode")).map(|c| c.0),
            Some("plan".into())
        );
        let tr = tr_with(modes("plan"));
        assert_eq!(
            next_choice(tr.option("mode").expect("mode")).map(|c| c.0),
            Some("default".into()),
            "round to the first"
        );
        let one = tr_with(
            json!([{"id": "mode", "type": "select", "currentValue": "a", "options": [{"value": "a"}]}]),
        );
        assert_eq!(next_choice(one.option("mode").expect("mode")), None);
    }

    #[test]
    fn settings_lists_what_can_be_changed_with_its_current_value() {
        let mut all = models().as_array().expect("array").clone();
        all.extend(modes("plan").as_array().expect("array").clone());
        all.push(json!({"id": "fast", "name": "Fast", "type": "select", "currentValue": "off", "options": [{"value": "off"}]}));
        let tr = tr_with(json!(all));
        let p = settings(&tr).expect("settings");
        assert!(p.kind == PickerKind::Settings && p.title == "Settings");
        assert_eq!(
            p.rows,
            [
                ("model".to_string(), "Model · Sonnet 5.5".to_string()),
                ("mode".to_string(), "Mode · Plan".to_string()),
            ],
            "a setting with one choice is not offered"
        );
        assert!(settings(&Transcript::default()).is_none());
    }

    #[test]
    fn the_attached_files_picker_opens_on_the_last_and_names_each_by_its_place() {
        let labels = vec!["a.rs".to_string(), "shot.png · picture".to_string()];
        let p = attached(&labels);
        assert_eq!(p.kind, PickerKind::Files);
        assert_eq!(p.sel, 1, "the one Backspace would take off");
        assert_eq!(
            p.chosen(),
            Some(&("1".to_string(), "shot.png · picture".to_string()))
        );
        let tr = Transcript::default();
        assert_eq!(
            classify("/detach", &[]),
            Run::Local(Local::Files, String::new())
        );
        assert_eq!(
            names(&entries("/att", &[], &tr, true)),
            ["files"],
            "found by an alias, listed as /files"
        );
    }

    #[test]
    fn update_is_a_command_that_takes_check_or_a_version_and_is_found_by_its_name() {
        assert_eq!(
            classify("/update check", &[]),
            Run::Local(Local::Update, "check".into())
        );
        assert_eq!(
            classify("/update 0.1.35", &[cmd("compact", None)]),
            Run::Local(Local::Update, "0.1.35".into())
        );
        let tr = Transcript::default();
        let got = entries("/upd", &[], &tr, true);
        assert_eq!(names(&got), ["update"]);
        assert_eq!(got[0].hint.as_deref(), Some("[check|VERSION]"));
    }
}
