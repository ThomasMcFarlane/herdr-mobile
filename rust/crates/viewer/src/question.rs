//! An agent's question (`elicitation/create` in form mode), answered in the terminal. Pure: the
//! form, what the person's keys and clicks do to it, the lines it draws and the answer it sends.
//!
//! The person walks the fields one at a time, in the schema's order. What they answered stays on
//! the panel, one line each, above the field they are on, so every answer is in sight when the
//! last Enter sends them all. A choice (an enum, a boolean as Yes and No, several ticks) is
//! picked on the panel; text and numbers are typed in the composer, which is the field's box
//! while it is on screen. Nothing is chosen for the person and nothing is sent on a timeout.
//!
//! The answer is built as the phone builds it (`question_form.dart`, `acp_models.dart`), so an
//! agent cannot tell which client answered.

use crate::md::{self, clean};
use crate::theme::Theme;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use serde_json::{json, Map, Value};

/// One choice of an enum.
#[derive(Clone, Debug, PartialEq)]
pub struct Choice {
    /// What is sent.
    pub value: String,
    /// What is shown.
    pub title: String,
}

/// What a field holds. ACP restricts a form to a flat object of these.
#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Text {
        min_len: Option<usize>,
        max_len: Option<usize>,
    },
    /// `number`, or `integer` when `integer`.
    Number {
        integer: bool,
        min: Option<f64>,
        max: Option<f64>,
    },
    /// One choice: a string `enum`, or a titled `oneOf`.
    One(Vec<Choice>),
    /// Several choices: an `array` of an enum (`items.enum`, or titled `items.anyOf`).
    Many {
        options: Vec<Choice>,
        min: Option<usize>,
        max: Option<usize>,
    },
    Bool,
    /// A type this terminal cannot show; it is left out of the answer.
    Unknown(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Field {
    /// The key in the answer.
    pub name: String,
    pub title: Option<String>,
    pub description: Option<String>,
    pub required: bool,
    /// The agent marked it secret (Codex's `_meta.codex.isSecret`, a bare `_meta.isSecret`, or a
    /// password format). It is shown as any other, with a warning: hiding it would pretend a form
    /// is a safe place for a secret.
    pub secret: bool,
    pub kind: Kind,
}

impl Field {
    /// The title, or the name when there is none.
    #[must_use]
    pub fn label(&self) -> &str {
        self.title
            .as_deref()
            .filter(|t| !t.is_empty())
            .unwrap_or(&self.name)
    }

    /// The choices drawn as rows: an enum's, Yes and No, or the ticks'.
    fn rows(&self) -> Vec<String> {
        match &self.kind {
            Kind::One(o) | Kind::Many { options: o, .. } => {
                o.iter().map(|c| c.title.clone()).collect()
            }
            Kind::Bool => vec!["Yes".into(), "No".into()],
            _ => Vec::new(),
        }
    }

    /// Answered in the composer rather than on the panel.
    #[must_use]
    pub fn typed(&self) -> bool {
        matches!(self.kind, Kind::Text { .. } | Kind::Number { .. })
    }
}

/// `Slot::cursor` of an optional choice nothing has been picked in yet.
const NONE: usize = usize::MAX;

/// What the person has put into one field so far.
#[derive(Clone, Debug, PartialEq)]
struct Slot {
    /// The row marked `›`. For an enum and Yes/No, the choice; `NONE` when nothing is marked.
    cursor: usize,
    ticked: Vec<bool>,
    text: String,
}

/// What the person does to the form.
#[derive(Clone, Debug, PartialEq)]
pub enum Act {
    Up,
    Down,
    /// A digit: marks that row (and ticks it, on a field of ticks).
    Pick(usize),
    /// Space: ticks or unticks the marked row.
    Toggle,
    /// A click on a row: marks it; on the row already marked, confirms it. On ticks, ticks it.
    Click(usize),
    /// Enter: confirms the field, with the composer's text for a typed one.
    Enter(String),
    /// Shift-Tab: back to the field before, keeping the composer's text for a typed one.
    Back(String),
}

/// An agent's question in form mode, and the person's answers so far.
#[derive(Clone, Debug, PartialEq)]
pub struct Form {
    pub message: String,
    /// The schema's own description.
    pub description: Option<String>,
    pub fields: Vec<Field>,
    /// Codex goes on without an answer after this long (`_meta.codex.autoResolutionMs`).
    pub auto_ms: Option<u64>,
    slots: Vec<Slot>,
    /// The field on screen; `fields.len()` only for a form with no fields.
    at: usize,
    /// When the field on screen appeared: it is not confirmed by a key meant for the one before.
    since_ms: u64,
}

fn str_of(v: Option<&Value>) -> Option<String> {
    v.and_then(Value::as_str).map(str::to_string)
}

fn usize_of(v: Option<&Value>) -> Option<usize> {
    v.and_then(Value::as_u64)
        .and_then(|n| usize::try_from(n).ok())
}

/// A titled `oneOf`/`anyOf` list, or else a plain `enum`.
fn choices(titled: Option<&Value>, plain: Option<&Value>) -> Vec<Choice> {
    let titled: Vec<Choice> = titled
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|o| {
            let value = o.get("const")?.as_str()?.to_string();
            let title = str_of(o.get("title")).unwrap_or_else(|| value.clone());
            Some(Choice { value, title })
        })
        .collect();
    if !titled.is_empty() {
        return titled;
    }
    plain
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|s| Choice {
            value: s.to_string(),
            title: s.to_string(),
        })
        .collect()
}

fn parse_field(name: &str, p: &Value, required: bool) -> (Field, Slot) {
    let ty = p.get("type").and_then(Value::as_str).unwrap_or("");
    let meta = p.get("_meta");
    let secret = meta
        .and_then(|m| m.get("codex"))
        .and_then(|c| c.get("isSecret"))
        == Some(&Value::Bool(true))
        || meta.and_then(|m| m.get("isSecret")) == Some(&Value::Bool(true))
        || p.get("format").and_then(Value::as_str) == Some("password");
    let mut slot = Slot {
        cursor: 0,
        ticked: Vec::new(),
        text: String::new(),
    };
    let kind = match ty {
        "string"
            if p.get("oneOf").is_some_and(Value::is_array)
                || p.get("enum").is_some_and(Value::is_array) =>
        {
            let options = choices(p.get("oneOf"), p.get("enum"));
            let default = str_of(p.get("default"));
            slot.cursor = options
                .iter()
                .position(|c| Some(&c.value) == default.as_ref())
                // As on the phone, an optional choice with no default starts with none chosen.
                .unwrap_or(if required { 0 } else { NONE });
            Kind::One(options)
        }
        "string" => {
            slot.text = str_of(p.get("default")).unwrap_or_default();
            Kind::Text {
                min_len: usize_of(p.get("minLength")),
                max_len: usize_of(p.get("maxLength")),
            }
        }
        "number" | "integer" => {
            if let Some(d) = p.get("default").and_then(Value::as_f64) {
                slot.text = number_text(d);
            }
            Kind::Number {
                integer: ty == "integer",
                min: p.get("minimum").and_then(Value::as_f64),
                max: p.get("maximum").and_then(Value::as_f64),
            }
        }
        "boolean" => {
            // The phone's switch starts off when the agent gives no default.
            slot.cursor = usize::from(p.get("default") != Some(&Value::Bool(true)));
            Kind::Bool
        }
        "array" => {
            let items = p.get("items");
            let options = choices(
                items.and_then(|i| i.get("anyOf")),
                items.and_then(|i| i.get("enum")),
            );
            let defaults: Vec<&str> = p
                .get("default")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect();
            slot.ticked = options
                .iter()
                .map(|c| defaults.contains(&c.value.as_str()))
                .collect();
            Kind::Many {
                options,
                min: usize_of(p.get("minItems")),
                max: usize_of(p.get("maxItems")),
            }
        }
        other => Kind::Unknown(other.to_string()),
    };
    (
        Field {
            name: name.to_string(),
            title: str_of(p.get("title")),
            description: str_of(p.get("description")).filter(|d| !d.is_empty()),
            required,
            secret,
            kind,
        },
        slot,
    )
}

/// A number as the person would type it: `3`, not `3.0`.
fn number_text(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 {
        format!("{}", n as i64)
    } else {
        format!("{n}")
    }
}

/// A bound as it reads in a sentence.
fn bound(n: f64) -> String {
    number_text(n)
}

/// The number typed, as the phone sends it: whole when it is written whole (or the field wants a
/// whole number and it is one), else as written. `Err` with the reason when it is not a number.
fn parse_number(text: &str, integer: bool) -> Result<Value, String> {
    if let Ok(n) = text.parse::<i64>() {
        return Ok(json!(n));
    }
    match text.parse::<f64>() {
        Ok(n) if n.is_finite() => {
            if integer && n.fract() == 0.0 && n.abs() < 9e15 {
                Ok(json!(n as i64))
            } else {
                Ok(json!(n))
            }
        }
        _ => Err("Must be a number".into()),
    }
}

impl Form {
    /// The form an `elicitation/create` asks to be filled in, or `None` for a request this
    /// terminal cannot answer (a mode other than `form`). `mode` defaults to `form`, and a form
    /// with no schema has no fields, as on the phone.
    #[must_use]
    pub fn parse(p: &Value, now_ms: u64) -> Option<Form> {
        if p.get("mode").and_then(Value::as_str).unwrap_or("form") != "form" {
            return None;
        }
        let schema = p.get("requestedSchema");
        let required: Vec<&str> = schema
            .and_then(|s| s.get("required"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        let (fields, slots) = schema
            .and_then(|s| s.get("properties"))
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
            .filter(|(_, p)| p.is_object())
            .map(|(name, p)| parse_field(name, p, required.contains(&name.as_str())))
            .unzip();
        let auto_ms = p
            .get("_meta")
            .and_then(|m| m.get("codex"))
            .and_then(|c| c.get("autoResolutionMs"))
            .and_then(Value::as_f64)
            .filter(|n| n.is_finite() && *n >= 0.0)
            .map(|n| n as u64);
        Some(Form {
            message: str_of(p.get("message")).unwrap_or_default(),
            description: schema
                .and_then(|s| s.get("description"))
                .and_then(Value::as_str)
                .filter(|d| !d.is_empty())
                .map(str::to_string),
            fields,
            auto_ms,
            slots,
            at: 0,
            since_ms: now_ms,
        })
    }

    /// The index of the field on screen.
    #[must_use]
    pub fn at(&self) -> usize {
        self.at
    }

    /// The field on screen; `None` for a form with no fields.
    #[must_use]
    pub fn field(&self) -> Option<&Field> {
        self.fields.get(self.at)
    }

    /// The field on screen is answered in the composer.
    #[must_use]
    pub fn typed(&self) -> bool {
        self.field().is_some_and(Field::typed)
    }

    /// What the composer starts with on the field on screen: what was typed there before, else
    /// the agent's default.
    #[must_use]
    pub fn text(&self) -> &str {
        self.slots.get(self.at).map_or("", |s| s.text.as_str())
    }

    /// When the field on screen appeared.
    #[must_use]
    pub fn since_ms(&self) -> u64 {
        self.since_ms
    }

    /// Whether `act` would confirm the field on screen (and, on the last, send the answer).
    #[must_use]
    pub fn confirms(&self, act: &Act) -> bool {
        match act {
            Act::Enter(_) => true,
            Act::Click(i) => {
                matches!(
                    self.field().map(|f| &f.kind),
                    Some(Kind::One(_) | Kind::Bool)
                ) && self.slots.get(self.at).is_some_and(|s| s.cursor == *i)
            }
            _ => false,
        }
    }

    /// Carries out `act`. `Ok(Some(result))` when the last field was confirmed: the `result` of
    /// the `elicitation/create`. `Err` says what is wrong with the field; nothing is lost.
    ///
    /// # Errors
    /// The field's value does not pass its schema.
    pub fn act(&mut self, act: Act, now_ms: u64) -> Result<Option<Value>, String> {
        let rows = self.field().map(Field::rows).unwrap_or_default();
        let many = matches!(self.field().map(|f| &f.kind), Some(Kind::Many { .. }));
        let typed = self.typed();
        let click = matches!(act, Act::Click(_));
        let Some(slot) = self.slots.get_mut(self.at) else {
            // No fields: Enter sends the empty answer the phone would.
            return Ok(matches!(act, Act::Enter(_)).then(|| self.result()));
        };
        let last = rows.len().saturating_sub(1);
        match act {
            Act::Up => {
                slot.cursor = if slot.cursor == NONE {
                    0
                } else {
                    slot.cursor.saturating_sub(1)
                }
            }
            Act::Down => slot.cursor = slot.cursor.wrapping_add(1).min(last),
            Act::Pick(i) | Act::Click(i) if i < rows.len() => {
                let again = slot.cursor == i;
                slot.cursor = i;
                if many {
                    if let Some(t) = slot.ticked.get_mut(i) {
                        *t = !*t;
                    }
                } else if again && click {
                    return self.confirm(String::new(), now_ms);
                }
            }
            Act::Pick(_) | Act::Click(_) => return Err("No such option".into()),
            Act::Toggle => {
                if let Some(t) = slot.ticked.get_mut(slot.cursor) {
                    *t = !*t;
                }
            }
            Act::Enter(text) => return self.confirm(text, now_ms),
            Act::Back(text) => {
                if typed {
                    slot.text = text;
                }
                if self.at > 0 {
                    self.at -= 1;
                    self.since_ms = now_ms;
                }
            }
        }
        Ok(None)
    }

    fn confirm(&mut self, text: String, now_ms: u64) -> Result<Option<Value>, String> {
        let typed = self.typed();
        let at = self.at;
        if typed {
            // Kept whatever happens: a wrong answer is corrected, not typed again.
            self.slots[at].text = text;
        }
        self.check(at)?;
        self.at += 1;
        self.since_ms = now_ms;
        if self.at >= self.fields.len() {
            self.at = self.fields.len().saturating_sub(1);
            return Ok(Some(self.result()));
        }
        Ok(None)
    }

    /// What is wrong with field `i`, in the words the person reads.
    fn check(&self, i: usize) -> Result<(), String> {
        let f = &self.fields[i];
        let s = &self.slots[i];
        let need = |empty: bool| {
            if empty && f.required {
                Err("Required".to_string())
            } else {
                Ok(())
            }
        };
        match &f.kind {
            Kind::Text { min_len, max_len } => {
                if s.text.is_empty() {
                    return need(true);
                }
                let n = s.text.chars().count();
                if min_len.is_some_and(|m| n < m) {
                    return Err(format!("At least {} characters", min_len.unwrap_or(0)));
                }
                if let Some(m) = max_len.filter(|m| n > *m) {
                    return Err(format!("At most {m} characters"));
                }
                Ok(())
            }
            Kind::Number { integer, min, max } => {
                let t = s.text.trim();
                if t.is_empty() {
                    return need(true);
                }
                let v = parse_number(t, *integer)?;
                let n = v.as_f64().unwrap_or(0.0);
                if *integer && !v.is_i64() {
                    return Err("Must be a whole number".into());
                }
                if let Some(m) = min.filter(|m| n < *m) {
                    return Err(format!("At least {}", bound(m)));
                }
                if let Some(m) = max.filter(|m| n > *m) {
                    return Err(format!("At most {}", bound(m)));
                }
                Ok(())
            }
            Kind::One(o) => need(o.is_empty()),
            Kind::Many { min, max, .. } => {
                let n = s.ticked.iter().filter(|t| **t).count();
                if n == 0 {
                    return need(true);
                }
                if let Some(m) = min.filter(|m| n < *m) {
                    return Err(format!("Choose at least {m}"));
                }
                if let Some(m) = max.filter(|m| n > *m) {
                    return Err(format!("Choose at most {m}"));
                }
                Ok(())
            }
            Kind::Bool => Ok(()),
            Kind::Unknown(ty) if f.required => Err(format!(
                "This terminal cannot answer a field of type “{ty}”; Esc declines"
            )),
            Kind::Unknown(_) => Ok(()),
        }
    }

    /// The value field `i` contributes to the answer, if any; as the phone builds it.
    fn value(&self, i: usize) -> Option<Value> {
        let s = &self.slots[i];
        match &self.fields[i].kind {
            Kind::Text { .. } => (!s.text.is_empty()).then(|| json!(s.text)),
            Kind::Number { integer, .. } => {
                let t = s.text.trim();
                (!t.is_empty()).then(|| parse_number(t, *integer).unwrap_or_else(|_| json!(t)))
            }
            Kind::Bool => Some(json!(s.cursor == 0)),
            Kind::One(o) => o.get(s.cursor).map(|c| json!(c.value)),
            Kind::Many { options, .. } => {
                let chosen: Vec<&str> = options
                    .iter()
                    .zip(&s.ticked)
                    .filter(|(_, t)| **t)
                    .map(|(c, _)| c.value.as_str())
                    .collect();
                (!chosen.is_empty()).then(|| json!(chosen))
            }
            Kind::Unknown(_) => None,
        }
    }

    /// The `content` of an accepted answer: field name to value, in the schema's order.
    #[must_use]
    pub fn content(&self) -> Map<String, Value> {
        (0..self.fields.len())
            .filter_map(|i| self.value(i).map(|v| (self.fields[i].name.clone(), v)))
            .collect()
    }

    fn result(&self) -> Value {
        json!({"action": "accept", "content": self.content()})
    }

    /// Field `i`'s answer in words, as the panel and the transcript show it.
    fn said(&self, i: usize) -> String {
        let s = &self.slots[i];
        match &self.fields[i].kind {
            Kind::Text { .. } | Kind::Number { .. } if s.text.trim().is_empty() => "—".into(),
            Kind::Text { .. } | Kind::Number { .. } => md::one_line(&s.text, 200),
            Kind::Bool => (if s.cursor == 0 { "Yes" } else { "No" }).into(),
            Kind::One(o) => o
                .get(s.cursor)
                .map_or_else(|| "—".into(), |c| md::one_line(&c.title, 200)),
            Kind::Many { options, .. } => {
                let t: Vec<&str> = options
                    .iter()
                    .zip(&s.ticked)
                    .filter(|(_, t)| **t)
                    .map(|(c, _)| c.title.as_str())
                    .collect();
                if t.is_empty() {
                    "—".into()
                } else {
                    md::one_line(&t.join(", "), 200)
                }
            }
            Kind::Unknown(_) => "—".into(),
        }
    }

    /// Every answer in one line, for the transcript once it is sent.
    #[must_use]
    pub fn summary(&self) -> String {
        let all: Vec<String> = (0..self.fields.len()).map(|i| self.said(i)).collect();
        md::one_line(&all.join(" · "), 300)
    }

    /// The panel's lines, untinted, with the option of the field on screen each row draws (what
    /// a click on that row does). `total`: the requests waiting, this one included. The agent's
    /// message is cut at `max_message` rows. `max_rows`:
    /// the rows the panel has room for; over it, answered fields fold into a count and the
    /// descriptions are cut, never the field on screen or the keys line.
    #[must_use]
    pub fn lines(
        &self,
        total: usize,
        width: usize,
        max_message: usize,
        max_rows: usize,
        theme: Theme,
    ) -> (Vec<Line<'static>>, Vec<Option<usize>>) {
        let wrap = width.saturating_sub(2);
        let more = if total > 1 {
            format!("  ({total} waiting)")
        } else {
            String::new()
        };
        let mut rows = vec![
            Line::default(),
            Line::from(vec![
                Span::raw("  "),
                Span::styled("▲ Needs you", theme.warn()),
                Span::styled(format!(" · Question{more}"), theme.bold()),
            ]),
            Line::default(),
        ];
        let text = |s: &str, style: Style, lead: &str| {
            let lead = lead.to_string();
            let mut out = Vec::new();
            for line in clean(s).replace('\t', "    ").lines() {
                if line.trim().is_empty() {
                    out.push(Line::default());
                    continue;
                }
                out.extend(md::wrap_spans(
                    vec![Span::styled(line.to_string(), style)],
                    vec![Span::raw(lead.clone())],
                    vec![Span::raw(lead.clone())],
                    wrap,
                ));
            }
            out
        };
        let message = if self.message.trim().is_empty() {
            "The agent has a question"
        } else {
            self.message.trim()
        };
        let mut said = text(message, theme.bold(), "  ");
        if said.len() > max_message {
            said.truncate(max_message);
            said.push(Line::from(Span::styled("  …", theme.dim())));
        }
        let mut form_desc = self
            .description
            .as_deref()
            .map(|d| text(d, theme.dim(), "  "))
            .unwrap_or_default();
        // The answers so far, one line each, so all of them are in sight before the last Enter.
        let answered: Vec<Vec<Line<'static>>> = (0..self.at.min(self.fields.len()))
            .map(|i| {
                let label = md::one_line(self.fields[i].label(), 60);
                md::wrap_spans(
                    vec![
                        Span::styled(format!("{label}  "), theme.dim()),
                        Span::raw(self.said(i)),
                    ],
                    vec![Span::raw("  "), Span::styled("✓ ", theme.ok())],
                    vec![Span::raw("    ")],
                    wrap,
                )
            })
            .collect();
        // The field on screen in three parts: its title, its description (which may be cut), and
        // the rest (secret warning, choices, hint), whose rows `rest_options` maps to options.
        let mut field_head: Vec<Line<'static>> = Vec::new();
        let mut field_desc: Vec<Line<'static>> = Vec::new();
        let mut rest: Vec<Line<'static>> = Vec::new();
        let mut rest_options: Vec<Option<usize>> = Vec::new();
        if let Some(f) = self.field() {
            let slot = &self.slots[self.at];
            let mut head = vec![Span::styled(md::one_line(f.label(), 200), theme.bold())];
            if !f.required && !matches!(f.kind, Kind::Bool) {
                head.push(Span::styled(" (optional)", theme.dim()));
            }
            if self.fields.len() > 1 {
                head.push(Span::styled(
                    format!("  {} of {}", self.at + 1, self.fields.len()),
                    theme.dim(),
                ));
            }
            field_head = md::wrap_spans(head, vec![Span::raw("  ")], vec![Span::raw("  ")], wrap);
            if let Some(d) = &f.description {
                field_desc = text(d, theme.dim(), "  ");
            }
            if f.secret {
                rest.extend(text(
                    "Marked secret by the agent: what you type goes to it as plain text, not hidden.",
                    theme.bad(),
                    "  ",
                ));
            }
            let many = matches!(f.kind, Kind::Many { .. });
            for (i, title) in f.rows().iter().enumerate() {
                let marked = i == slot.cursor;
                let (mark, style) = if marked {
                    ("› ", theme.accent().add_modifier(Modifier::BOLD))
                } else {
                    ("  ", Style::default())
                };
                let tick = if !many {
                    ""
                } else if slot.ticked.get(i).copied().unwrap_or(false) {
                    "☑ "
                } else {
                    "☐ "
                };
                let lines = md::wrap_spans(
                    vec![Span::styled(
                        format!("{tick}{}. {}", i + 1, clean(title)),
                        style,
                    )],
                    vec![Span::raw("  "), Span::styled(mark, style)],
                    vec![Span::raw(" ".repeat(7 + tick.chars().count()))],
                    width.saturating_sub(2),
                );
                rest_options.resize(rest.len(), None);
                rest_options.extend(std::iter::repeat_n(Some(i), lines.len()));
                rest.extend(lines);
            }
            let hint = match &f.kind {
                Kind::Text { min_len, max_len } => Some(match (min_len, max_len) {
                    (Some(a), Some(b)) => {
                        format!("Type it in the box below: {a} to {b} characters")
                    }
                    (Some(a), None) => format!("Type it in the box below: at least {a} characters"),
                    (None, Some(b)) => format!("Type it in the box below: at most {b} characters"),
                    (None, None) => "Type it in the box below".to_string(),
                }),
                Kind::Number { integer, min, max } => {
                    let what = if *integer {
                        "a whole number"
                    } else {
                        "a number"
                    };
                    Some(match (min, max) {
                        (Some(a), Some(b)) => {
                            format!(
                                "Type {what} in the box below, {} to {}",
                                bound(*a),
                                bound(*b)
                            )
                        }
                        (Some(a), None) => {
                            format!("Type {what} in the box below, at least {}", bound(*a))
                        }
                        (None, Some(b)) => {
                            format!("Type {what} in the box below, at most {}", bound(*b))
                        }
                        (None, None) => format!("Type {what} in the box below"),
                    })
                }
                Kind::Unknown(ty) => Some(format!(
                    "This terminal cannot show a field of type “{}”.",
                    md::one_line(ty, 40)
                )),
                Kind::One(o) if o.is_empty() => Some("No choices were offered.".into()),
                _ => None,
            };
            if let Some(h) = hint {
                rest.extend(text(&h, theme.dim(), "  "));
            }
        } else {
            rest.extend(text("Nothing to fill in.", theme.dim(), "  "));
        }
        rest_options.resize(rest.len(), None);
        let mut tail: Vec<Line<'static>> = Vec::new();
        if let Some(ms) = self.auto_ms {
            tail.push(Line::default());
            tail.extend(text(
                &format!(
                    "The agent goes on without an answer {} after it asked.",
                    crate::elapsed::duration(ms.div_ceil(1000))
                ),
                theme.dim(),
                "  ",
            ));
        }
        tail.push(Line::default());
        tail.extend(text(&self.keys(), theme.dim(), "  "));
        tail.push(Line::default());

        // Over the room the panel has: fold the answered rows first (the last one or two stay,
        // with a count of the rest), then cut descriptions. The field on screen (its choices)
        // and the keys line are never cut.
        let kept = |keep: usize| -> usize {
            let n = answered.len();
            if keep >= n {
                answered.iter().map(Vec::len).sum()
            } else {
                1 + answered[n - keep..].iter().map(Vec::len).sum::<usize>()
            }
        };
        let fixed =
            |said: &[Line<'static>], form_desc: &[Line<'static>], field_desc: &[Line<'static>]| {
                rows.len()
                    + said.len()
                    + form_desc.len()
                    + 1
                    + field_head.len()
                    + field_desc.len()
                    + rest.len()
                    + tail.len()
            };
        let n = answered.len();
        let room = max_rows.saturating_sub(fixed(&said, &form_desc, &field_desc));
        let keep = if kept(n) <= room {
            n
        } else {
            (0..=n.min(2)).rev().find(|&k| kept(k) <= room).unwrap_or(0)
        };
        let mut over =
            (fixed(&said, &form_desc, &field_desc) + kept(keep)).saturating_sub(max_rows);
        for block in [&mut form_desc, &mut said, &mut field_desc] {
            if over == 0 {
                break;
            }
            over -= cut(block, over, theme);
        }

        rows.extend(said);
        rows.extend(form_desc);
        rows.push(Line::default());
        if keep < n {
            rows.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("✓ ", theme.ok()),
                Span::styled(format!("{} answered", n - keep), theme.dim()),
            ]));
        }
        for group in &answered[n - keep..] {
            rows.extend(group.iter().cloned());
        }
        rows.extend(field_head);
        rows.extend(field_desc);
        let mut options: Vec<Option<usize>> = Vec::new();
        options.resize(rows.len(), None);
        options.extend(rest_options);
        rows.extend(rest);
        rows.extend(tail);
        options.resize(rows.len(), None);
        (rows, options)
    }

    /// The keys the field on screen takes.
    fn keys(&self) -> String {
        let enter = if self.at + 1 >= self.fields.len() {
            "Enter sends"
        } else {
            "Enter next"
        };
        let mut k = match self.field().map(|f| &f.kind) {
            Some(Kind::One(_) | Kind::Bool) => format!("↑↓ choose · {enter}"),
            Some(Kind::Many { .. }) => format!("↑↓ move · Space ticks · {enter}"),
            _ => enter.to_string(),
        };
        if self.at > 0 {
            k.push_str(" · Shift-Tab back");
        }
        k.push_str(" · Esc declines");
        k
    }
}

/// Whether Esc declines the question: not while an answer is being typed (Ctrl-U clears the box
/// first), as a permission's Esc only acts on an empty box, so a slip loses nothing.
#[must_use]
pub fn esc_declines(typed: bool, boxed: &str) -> bool {
    !typed || boxed.is_empty()
}

/// Cut `block` by up to `by` rows, ending it with an ellipsis; at least a row and the ellipsis
/// stay. Returns the rows saved.
fn cut(block: &mut Vec<Line<'static>>, by: usize, theme: Theme) -> usize {
    let len = block.len();
    if len <= 2 {
        return 0;
    }
    let to = len.saturating_sub(by).max(2);
    block.truncate(to - 1);
    block.push(Line::from(Span::styled("  …", theme.dim())));
    len - to
}

/// The `result` that declines a question.
#[must_use]
pub fn declined() -> Value {
    json!({"action": "decline"})
}

/// The `result` that withdraws a question (the turn was stopped).
#[must_use]
pub fn cancelled() -> Value {
    json!({"action": "cancel"})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn form(p: Value) -> Form {
        Form::parse(&p, 0).expect("a form")
    }

    fn enter(f: &mut Form, text: &str) -> Result<Option<Value>, String> {
        f.act(Act::Enter(text.into()), 0)
    }

    /// omp's `select`: a string enum in `value`.
    fn omp_select() -> Value {
        json!({"sessionId": "s", "mode": "form", "message": "Approve plan \"x\" and start implementation?",
               "requestedSchema": {"type": "object", "properties": {"value": {"type": "string", "enum": ["Approve and execute", "Refine plan"]}}}})
    }

    /// Claude's AskUserQuestion: a titled `oneOf` per question and an optional "Other" text.
    fn claude_ask() -> Value {
        json!({"mode": "form", "sessionId": "s", "toolCallId": "toolu_1", "message": "Please answer the following questions.",
               "requestedSchema": {"type": "object", "properties": {
                   "question_0": {"type": "string", "title": "Approach", "description": "Which approach?",
                                  "oneOf": [{"const": "Safe", "title": "Safe — slower"}, {"const": "Fast", "title": "Fast — riskier", "_meta": {"_claude/askUserQuestionOption": {"description": "riskier"}}}]},
                   "question_0_custom": {"type": "string", "title": "Other", "description": "Type your own answer instead of choosing an option above (optional)."},
                   "question_1": {"type": "array", "title": "Targets", "description": "Where?", "items": {"anyOf": [{"const": "web", "title": "web"}, {"const": "api", "title": "api"}, {"const": "cli", "title": "cli"}]}},
                   "question_1_custom": {"type": "string", "title": "Other", "description": "Type your own answer instead of choosing an option above (optional)."}}}})
    }

    /// Codex's request_user_input: required fields, a secret, and a time limit.
    fn codex_input() -> Value {
        json!({"mode": "form", "sessionId": "s", "message": "Codex needs a few details",
               "_meta": {"codex": {"autoResolutionMs": 60000}},
               "requestedSchema": {"type": "object", "required": ["port", "token"], "properties": {
                   "port": {"type": "integer", "title": "Port", "minimum": 1, "maximum": 65535, "default": 8080},
                   "token": {"type": "string", "title": "Token", "_meta": {"codex": {"isSecret": true}}},
                   "ratio": {"type": "number", "title": "Ratio"},
                   "verbose": {"type": "boolean", "title": "Verbose", "default": true}}}})
    }

    #[test]
    fn each_field_type_is_read_in_the_schemas_order() {
        let f = form(claude_ask());
        let names: Vec<&str> = f.fields.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "question_0",
                "question_0_custom",
                "question_1",
                "question_1_custom"
            ]
        );
        assert!(
            matches!(&f.fields[0].kind, Kind::One(o) if o[1].value == "Fast" && o[1].title == "Fast — riskier")
        );
        assert!(matches!(&f.fields[1].kind, Kind::Text { .. }));
        assert!(matches!(&f.fields[2].kind, Kind::Many { options, .. } if options.len() == 3));
        assert!(!f.fields[0].required);

        let c = form(codex_input());
        assert_eq!(c.auto_ms, Some(60_000));
        assert!(matches!(
            c.fields[0].kind,
            Kind::Number {
                integer: true,
                min: Some(_),
                max: Some(_)
            }
        ));
        assert!(matches!(
            c.fields[2].kind,
            Kind::Number { integer: false, .. }
        ));
        assert!(matches!(c.fields[3].kind, Kind::Bool));
        assert!(c.fields[1].secret && !c.fields[0].secret);
        assert!(c.fields[0].required && c.fields[1].required && !c.fields[2].required);
        assert_eq!(c.text(), "8080", "the agent's default is in the box");

        let o = form(omp_select());
        assert!(
            matches!(&o.fields[0].kind, Kind::One(o) if o.len() == 2 && o[0].title == "Approve and execute")
        );
        let unknown = form(json!({"requestedSchema": {"properties": {"when": {"type": "date"}}}}));
        assert!(matches!(&unknown.fields[0].kind, Kind::Unknown(t) if t == "date"));
    }

    #[test]
    fn only_form_requests_are_forms() {
        assert!(Form::parse(
            &json!({"mode": "url", "url": "https://x", "message": "Open"}),
            0
        )
        .is_none());
        let bare = form(json!({"message": "Ok?"}));
        assert!(bare.fields.is_empty());
        let mut bare = bare;
        assert_eq!(
            enter(&mut bare, ""),
            Ok(Some(json!({"action": "accept", "content": {}})))
        );
    }

    #[test]
    fn omp_select_confirm_and_input_answer_value_as_the_phone_does() {
        let mut f = form(omp_select());
        f.act(Act::Pick(1), 0).expect("moved");
        assert_eq!(
            enter(&mut f, ""),
            Ok(Some(
                json!({"action": "accept", "content": {"value": "Refine plan"}})
            ))
        );
        let mut confirm = form(
            json!({"mode": "form", "message": "Proceed?", "requestedSchema": {"type": "object", "properties": {"value": {"type": "boolean"}}}}),
        );
        // With no default the phone's switch is off: the mark starts on No.
        assert_eq!(
            enter(&mut confirm, ""),
            Ok(Some(
                json!({"action": "accept", "content": {"value": false}})
            ))
        );
        let mut input = form(
            json!({"mode": "form", "message": "Name?", "requestedSchema": {"type": "object", "properties": {"value": {"type": "string"}}}}),
        );
        assert!(input.typed());
        assert_eq!(
            enter(&mut input, "Ada"),
            Ok(Some(
                json!({"action": "accept", "content": {"value": "Ada"}})
            ))
        );
    }

    #[test]
    fn walking_claudes_form_sends_what_was_chosen_and_typed() {
        let mut f = form(claude_ask());
        f.act(Act::Pick(1), 0).expect("picked");
        assert_eq!(enter(&mut f, ""), Ok(None));
        assert_eq!(f.at(), 1);
        assert!(f.typed(), "Other is typed in the box");
        assert_eq!(enter(&mut f, ""), Ok(None), "Other is optional");
        // Ticks: Space on the mark, a digit, and the same digit again unticks.
        f.act(Act::Toggle, 0).expect("ticked");
        f.act(Act::Pick(2), 0).expect("ticked");
        f.act(Act::Pick(1), 0).expect("ticked");
        f.act(Act::Pick(1), 0).expect("unticked");
        assert_eq!(enter(&mut f, ""), Ok(None));
        assert_eq!(
            enter(&mut f, "both, really"),
            Ok(Some(json!({"action": "accept", "content": {
                "question_0": "Fast", "question_1": ["web", "cli"], "question_1_custom": "both, really"}}))),
            "an empty text is left out, ticks keep the options' order"
        );
        assert!(f.summary().contains("Fast — riskier"));
    }

    #[test]
    fn a_wrong_number_or_a_missing_answer_keeps_the_typed_text_and_says_why() {
        let mut f = form(codex_input());
        assert!(enter(&mut f, "80a").is_err());
        assert_eq!((f.at(), f.text()), (0, "80a"), "nothing typed is lost");
        assert!(enter(&mut f, "70000").is_err(), "above the maximum");
        assert!(enter(&mut f, "8.5").is_err(), "a whole number is asked for");
        assert_eq!(enter(&mut f, " 8081 "), Ok(None));
        assert!(enter(&mut f, "").is_err(), "the token is required");
        assert_eq!(f.at(), 1);
        // Back keeps what was typed, and the field before shows its answer again.
        f.act(Act::Back("sec".into()), 0).expect("back");
        assert_eq!((f.at(), f.text()), (0, " 8081 "));
        assert_eq!(enter(&mut f, "8081"), Ok(None));
        assert_eq!(f.text(), "sec");
        assert_eq!(enter(&mut f, "s3cret"), Ok(None));
        assert_eq!(enter(&mut f, "2.5"), Ok(None));
        assert_eq!(
            enter(&mut f, ""),
            Ok(Some(
                json!({"action": "accept", "content": {"port": 8081, "token": "s3cret", "ratio": 2.5, "verbose": true}})
            ))
        );
    }

    #[test]
    fn ticks_respect_their_bounds_and_a_required_field_cannot_be_skipped() {
        let mut f = form(
            json!({"requestedSchema": {"required": ["pick"], "properties": {
            "pick": {"type": "array", "minItems": 2, "items": {"enum": ["a", "b", "c"]}, "default": ["b"]}}}}),
        );
        assert!(enter(&mut f, "").is_err(), "one ticked, two needed");
        f.act(Act::Click(0), 0).expect("ticked");
        assert_eq!(
            enter(&mut f, ""),
            Ok(Some(
                json!({"action": "accept", "content": {"pick": ["a", "b"]}})
            ))
        );
        let mut unknown = form(
            json!({"requestedSchema": {"required": ["when"], "properties": {"when": {"type": "date"}}}}),
        );
        assert!(enter(&mut unknown, "").is_err());
    }

    #[test]
    fn an_optional_choice_nobody_made_is_left_out_as_on_the_phone() {
        let optional = json!({"requestedSchema": {"properties": {"pick": {"type": "string", "enum": ["a", "b"]}}}});
        let mut f = form(optional.clone());
        assert_eq!(f.said(0), "—");
        assert_eq!(
            enter(&mut f, ""),
            Ok(Some(json!({"action": "accept", "content": {}})))
        );
        let mut f = form(optional.clone());
        f.act(Act::Down, 0).expect("moved");
        assert_eq!(f.said(0), "a");
        assert_eq!(
            enter(&mut f, ""),
            Ok(Some(json!({"action": "accept", "content": {"pick": "a"}})))
        );
        let mut f = form(optional);
        f.act(Act::Pick(1), 0).expect("picked");
        assert_eq!(
            enter(&mut f, ""),
            Ok(Some(json!({"action": "accept", "content": {"pick": "b"}})))
        );
        let mut f = form(
            json!({"requestedSchema": {"required": ["pick"], "properties": {"pick": {"type": "string", "enum": ["a", "b"]}}}}),
        );
        assert_eq!(
            enter(&mut f, ""),
            Ok(Some(json!({"action": "accept", "content": {"pick": "a"}})))
        );
    }

    #[test]
    fn a_click_marks_a_choice_and_a_second_click_confirms_it() {
        let mut f = form(omp_select());
        assert!(!f.confirms(&Act::Click(1)));
        assert_eq!(f.act(Act::Click(1), 0), Ok(None));
        assert!(f.confirms(&Act::Click(1)));
        assert_eq!(
            f.act(Act::Click(1), 0),
            Ok(Some(
                json!({"action": "accept", "content": {"value": "Refine plan"}})
            ))
        );
        assert!(form(omp_select()).act(Act::Pick(5), 0).is_err());
    }

    #[test]
    fn the_panel_maps_each_choice_row_to_its_option_and_shows_earlier_answers() {
        let mut f = form(claude_ask());
        let (rows, options) = f.lines(1, 60, 10, 100, Theme::plain());
        let text: Vec<String> = rows
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect();
        let row_of = |needle: &str| text.iter().position(|r| r.contains(needle)).expect(needle);
        assert_eq!(options[row_of("1. Safe")], Some(0));
        assert_eq!(options[row_of("2. Fast")], Some(1));
        assert_eq!(options[row_of("Needs you")], None);
        assert_eq!(rows.len(), options.len());

        f.act(Act::Pick(1), 0).expect("picked");
        enter(&mut f, "").expect("next");
        let (rows, options) = f.lines(1, 60, 10, 100, Theme::plain());
        let text: String = rows
            .iter()
            .flat_map(|l| l.spans.iter().map(|s| s.content.to_string()))
            .collect();
        assert!(
            text.contains("Fast — riskier"),
            "the answer so far stays in sight: {text}"
        );
        assert!(
            options.iter().all(Option::is_none),
            "a typed field has no rows to click"
        );
    }

    #[test]
    fn a_form_over_its_room_folds_answers_and_cuts_descriptions_but_never_the_field() {
        let mut props = serde_json::Map::new();
        for i in 0..6 {
            props.insert(
                format!("f{i}"),
                json!({"type": "string", "title": format!("Step {i}"), "enum": ["a", "b"]}),
            );
        }
        props.insert(
            "last".into(),
            json!({"type": "string", "enum": ["red", "green"],
                   "description": "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"}),
        );
        let mut f = form(
            json!({"message": "Hello", "requestedSchema": {"type": "object", "properties": props}}),
        );
        for _ in 0..6 {
            f.act(Act::Pick(0), 0).expect("picked");
            enter(&mut f, "").expect("next");
        }
        let (all, _) = f.lines(1, 40, 10, 100, Theme::plain());
        let (rows, options) = f.lines(1, 40, 10, 18, Theme::plain());
        assert!(rows.len() < all.len() && rows.len() <= 18, "{}", rows.len());
        let text: Vec<String> = rows
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect();
        let joined = text.join("\n");
        for needle in ["1. red", "2. green", "Esc declines", "Step 5"] {
            assert!(joined.contains(needle), "{needle}:\n{joined}");
        }
        assert!(
            !joined.contains("Step 0"),
            "early answers are folded:\n{joined}"
        );
        assert_eq!(rows.len(), options.len());
        let row_of = |needle: &str| text.iter().position(|r| r.contains(needle)).expect(needle);
        assert_eq!(options[row_of("2. green")], Some(1));
        assert_eq!(options[row_of("Step 5")], None);

        // Tighter still: nothing is left to fold but the count, so the description is cut.
        let (rows, _) = f.lines(1, 40, 10, 15, Theme::plain());
        let tight: String = rows
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(rows.len() <= 15, "{tight}");
        for needle in ["1. red", "2. green", "Esc declines", "answered", "…"] {
            assert!(tight.contains(needle), "{needle}:\n{tight}");
        }
    }

    #[test]
    fn esc_keeps_an_answer_being_typed_and_declines_otherwise() {
        assert!(!esc_declines(true, "80"), "a typed answer survives a slip");
        assert!(esc_declines(true, ""));
        assert!(esc_declines(false, ""), "a choice declines");
    }
}
