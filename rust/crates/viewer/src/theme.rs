//! Colour. Where the terminal's background is known (asked once with OSC 11, else `COLORFGBG`, else
//! forced with `HERDR_TUI_THEME`), every colour is chosen to be read on it: the secondary grey is
//! computed to hold a contrast ratio of at least 4.5, the semantic colours come from a palette
//! tuned for light or dark and checked against it in the tests, and the tint behind messages is the
//! background nudged toward the foreground. Where the background is unknown it falls back to the
//! terminal's own 16 colours, which are the user's theme but can be faint. `NO_COLOR` leaves only
//! bold, italic and underline.

use ratatui::style::{Color, Modifier, Style};

pub type Rgb = (u8, u8, u8);

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Theme {
    color: bool,
    /// The terminal's background, when known.
    bg: Option<Rgb>,
}

/// How far toward the foreground the tint moves: a little more on dark, where it is harder to see.
const TINT_DARK: f32 = 0.075;
const TINT_LIGHT: f32 = 0.05;
/// The contrast ratio the secondary text must hold against the background (WCAG AA for text).
const MIN_CONTRAST: f32 = 4.6;

fn channel(c: u8) -> f32 {
    let v = f32::from(c) / 255.0;
    if v <= 0.03928 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

/// WCAG relative luminance.
#[must_use]
pub fn luminance((r, g, b): Rgb) -> f32 {
    0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

/// WCAG contrast ratio, 1 to 21.
#[must_use]
pub fn contrast(a: Rgb, b: Rgb) -> f32 {
    let (la, lb) = (luminance(a), luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

fn is_dark(bg: Rgb) -> bool {
    luminance(bg) < 0.18
}

/// The terminal background `bg` nudged toward the foreground it implies.
#[must_use]
pub fn tint(bg: Rgb) -> Rgb {
    let (target, amount) = if is_dark(bg) {
        (255.0, TINT_DARK)
    } else {
        (0.0, TINT_LIGHT)
    };
    let mix = |c: u8| {
        (f32::from(c) + (target - f32::from(c)) * amount)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    (mix(bg.0), mix(bg.1), mix(bg.2))
}

/// `from` moved toward `to` by `t` (0 is `from`, 1 is `to`), per channel.
fn mix(from: Rgb, to: Rgb, t: f32) -> Rgb {
    let m = |a: u8, b: u8| {
        (f32::from(a) + (f32::from(b) - f32::from(a)) * t)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    (m(from.0, to.0), m(from.1, to.1), m(from.2, to.2))
}

/// How far from the background toward the foreground a decorative rule sits: visible, never
/// competing with the text it separates (codex's `TABLE_SEPARATOR_FG_ALPHA`).
const FAINT: f32 = 0.2;
/// How much of the semantic colour the row behind an added or removed line takes: enough to
/// tell them apart at a glance, little enough that the text on it reads as plain text.
const DIFF_TINT_DARK: f32 = 0.2;
const DIFF_TINT_LIGHT: f32 = 0.12;
/// How far toward the blue of the palette the background moves for selected text. The text
/// keeps its own colour, so the band only has to be seen: it is a clear step from the tint
/// behind a message, and every colour in the palette still reads on it (checked in the tests).
/// A reversed cell, the old selection, was white on near-black on a light terminal.
const SELECTION_DARK: f32 = 0.22;
const SELECTION_LIGHT: f32 = 0.16;

/// The lightest (on light) or darkest (on dark) grey that still holds [`MIN_CONTRAST`] against
/// the tint over `bg`, where it also has to be read (the input, the band behind a message), so
/// it holds it against `bg` itself too: as quiet as secondary text can be while staying readable.
#[must_use]
pub fn quiet_grey(bg: Rgb) -> Rgb {
    let toward: f32 = if is_dark(bg) { 255.0 } else { 0.0 };
    let at = |t: f32| {
        let m = |c: u8| {
            (f32::from(c) + (toward - f32::from(c)) * t)
                .round()
                .clamp(0.0, 255.0) as u8
        };
        (m(bg.0), m(bg.1), m(bg.2))
    };
    let on = tint(bg);
    (0..=100)
        .map(|i| at(i as f32 / 100.0))
        .find(|c| contrast(*c, on) >= MIN_CONTRAST)
        .unwrap_or_else(|| at(1.0))
}

/// Light or dark from `COLORFGBG` (`fg;bg`, set by some terminals), when nothing better is known.
#[must_use]
pub fn bg_from_colorfgbg(v: &str) -> Option<Rgb> {
    let bg: u8 = v.rsplit(';').next()?.parse().ok()?;
    Some(if bg == 7 || bg == 15 {
        (255, 255, 255)
    } else if bg <= 8 {
        (24, 24, 24)
    } else {
        return None;
    })
}

/// The semantic colours for a light or a dark background.
struct Palette {
    ok: Rgb,
    bad: Rgb,
    warn: Rgb,
    accent: Rgb,
    cmd: Rgb,
    flag: Rgb,
    string: Rgb,
    var: Rgb,
}

const LIGHT: Palette = Palette {
    ok: (26, 127, 55),
    bad: (207, 34, 46),
    warn: (140, 94, 0),
    accent: (14, 116, 144),
    cmd: (5, 80, 174),
    flag: (176, 79, 0),
    string: (17, 99, 41),
    var: (130, 80, 223),
};

const DARK: Palette = Palette {
    ok: (63, 185, 80),
    bad: (255, 123, 114),
    warn: (227, 179, 65),
    accent: (86, 212, 221),
    cmd: (121, 192, 255),
    flag: (255, 166, 87),
    string: (126, 231, 135),
    var: (210, 168, 255),
};

impl Theme {
    /// `bg`: the terminal's background when it answered. `HERDR_TUI_THEME=light|dark` overrides.
    #[must_use]
    pub fn detect(bg: Option<Rgb>) -> Theme {
        let color = std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty())
            && std::env::var("TERM").map_or(true, |t| t != "dumb");
        let forced = match std::env::var("HERDR_TUI_THEME").as_deref() {
            Ok("light") => Some((255, 255, 255)),
            // No exact background is known: a typical dark one, so the tint lands where a real one would.
            Ok("dark") => Some((24, 24, 24)),
            _ => None,
        };
        let known = forced.or(bg).or_else(|| {
            std::env::var("COLORFGBG")
                .ok()
                .and_then(|v| bg_from_colorfgbg(&v))
        });
        Theme {
            color,
            bg: if color { known } else { None },
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn plain() -> Theme {
        Theme {
            color: false,
            bg: None,
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn banded(bg: Rgb) -> Theme {
        Theme {
            color: true,
            bg: Some(bg),
        }
    }

    fn palette(self) -> Option<&'static Palette> {
        self.bg.map(|bg| if is_dark(bg) { &DARK } else { &LIGHT })
    }

    fn rgb(c: Rgb) -> Color {
        Color::Rgb(c.0, c.1, c.2)
    }

    /// A semantic colour: the tuned one where the background is known, else the terminal's own.
    fn pick(self, tuned: impl Fn(&Palette) -> Rgb, ansi: Color) -> Style {
        if !self.color {
            return Style::default();
        }
        Style::default().fg(self.palette().map_or(ansi, |p| Self::rgb(tuned(p))))
    }

    /// The tint behind a block, or none.
    #[must_use]
    pub fn band(self) -> Option<Style> {
        self.bg
            .map(tint)
            .map(|(r, g, b)| Style::default().bg(Color::Rgb(r, g, b)))
    }

    /// Secondary text: hints, process, anything the person reads second.
    #[must_use]
    pub fn dim(self) -> Style {
        match (self.color, self.bg) {
            (false, _) => Style::default().add_modifier(Modifier::DIM),
            (true, Some(bg)) => Style::default().fg(Self::rgb(quiet_grey(bg))),
            (true, None) => Style::default().fg(Color::DarkGray),
        }
    }
    /// Whether colour is shown at all (`NO_COLOR` and a dumb terminal leave only bold and the like).
    #[must_use]
    pub fn colored(self) -> bool {
        self.color
    }
    /// Decoration that only separates (table rules): a fifth of the way from the background to
    /// the foreground, so it is seen without being read.
    #[must_use]
    pub fn faint(self) -> Style {
        match (self.color, self.bg) {
            (false, _) => Style::default().add_modifier(Modifier::DIM),
            (true, Some(bg)) => {
                let fg = if is_dark(bg) {
                    (255, 255, 255)
                } else {
                    (0, 0, 0)
                };
                Style::default().fg(Self::rgb(mix(bg, fg, FAINT)))
            }
            (true, None) => Style::default().fg(Color::DarkGray),
        }
    }
    /// The row behind an added (`true`) or removed line of a diff, where the background is known.
    #[must_use]
    pub fn diff_row(self, added: bool) -> Option<Style> {
        let (bg, p) = (self.bg?, self.palette()?);
        let t = if is_dark(bg) {
            DIFF_TINT_DARK
        } else {
            DIFF_TINT_LIGHT
        };
        let c = mix(bg, if added { p.ok } else { p.bad }, t);
        Some(Style::default().bg(Self::rgb(c)))
    }
    /// The background of selected text, where the terminal's background is known: its own colour
    /// moved toward the palette's blue, so it is seen on light and dark alike and the text on it
    /// keeps its colour. `None` leaves the caller to swap foreground and background.
    #[must_use]
    pub fn selection(self) -> Option<Color> {
        let (bg, p) = (self.bg?, self.palette()?);
        let t = if is_dark(bg) {
            SELECTION_DARK
        } else {
            SELECTION_LIGHT
        };
        Some(Self::rgb(mix(bg, p.cmd, t)))
    }
    /// Where typing goes, and what the person said.
    #[must_use]
    pub fn accent(self) -> Style {
        self.pick(|p| p.accent, Color::Cyan)
    }
    #[must_use]
    pub fn ok(self) -> Style {
        self.pick(|p| p.ok, Color::Green)
    }
    #[must_use]
    pub fn bad(self) -> Style {
        self.pick(|p| p.bad, Color::Red)
    }
    /// Something that needs the person.
    #[must_use]
    pub fn warn(self) -> Style {
        self.pick(|p| p.warn, Color::Yellow)
            .add_modifier(Modifier::BOLD)
    }
    #[must_use]
    pub fn bold(self) -> Style {
        Style::default().add_modifier(Modifier::BOLD)
    }
    #[must_use]
    pub fn code(self) -> Style {
        self.pick(|p| p.accent, Color::Cyan)
    }
    /// A command name in a shell line.
    #[must_use]
    pub fn cmd(self) -> Style {
        self.pick(|p| p.cmd, Color::Blue)
    }
    /// A flag or redirect.
    #[must_use]
    pub fn flag(self) -> Style {
        self.pick(|p| p.flag, Color::Red)
    }
    #[must_use]
    pub fn string(self) -> Style {
        self.pick(|p| p.string, Color::Green)
    }
    #[must_use]
    pub fn var(self) -> Style {
        self.pick(|p| p.var, Color::Magenta)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BACKGROUNDS: [Rgb; 6] = [
        (255, 255, 255),
        (251, 248, 241),
        (242, 242, 242),
        (24, 24, 24),
        (26, 27, 38),
        (0, 0, 0),
    ];

    #[test]
    fn the_tint_is_a_little_lighter_on_dark_and_a_little_darker_on_light() {
        let dark = tint((26, 27, 38));
        assert!(dark.0 > 26 && dark.0 < 60, "{dark:?}");
        assert_eq!(
            tint((255, 255, 255)),
            (242, 242, 242),
            "the grey Codex uses on white"
        );
    }

    #[test]
    fn the_quiet_grey_always_holds_the_contrast_and_is_no_louder_than_it_must_be() {
        for bg in BACKGROUNDS {
            let g = quiet_grey(bg);
            assert!(
                contrast(g, bg) >= MIN_CONTRAST,
                "{bg:?} -> {g:?} is {:.2}",
                contrast(g, bg)
            );
            assert!(
                contrast(g, bg) < 6.5,
                "{bg:?} -> {g:?} is louder than needed: {:.2}",
                contrast(g, bg)
            );
        }
    }

    #[test]
    fn every_semantic_colour_reads_on_the_backgrounds_it_is_for_and_on_the_tint() {
        for (palette, backgrounds, name) in [
            (&LIGHT, &BACKGROUNDS[..3], "light"),
            (&DARK, &BACKGROUNDS[3..], "dark"),
        ] {
            for bg in backgrounds {
                for (c, what) in [
                    (palette.ok, "ok"),
                    (palette.bad, "bad"),
                    (palette.warn, "warn"),
                    (palette.accent, "accent"),
                    (palette.cmd, "cmd"),
                    (palette.flag, "flag"),
                    (palette.string, "string"),
                    (palette.var, "var"),
                ] {
                    assert!(
                        contrast(c, *bg) >= 4.5,
                        "{name} {what} {c:?} on {bg:?}: {:.2}",
                        contrast(c, *bg)
                    );
                    assert!(
                        contrast(c, tint(*bg)) >= 4.0,
                        "{name} {what} on the tint of {bg:?}: {:.2}",
                        contrast(c, tint(*bg))
                    );
                }
            }
        }
    }

    #[test]
    fn secondary_text_stays_readable_on_the_tint_too() {
        for bg in BACKGROUNDS {
            assert!(
                contrast(quiet_grey(bg), tint(bg)) >= 4.0,
                "{bg:?}: {:.2}",
                contrast(quiet_grey(bg), tint(bg))
            );
        }
    }

    #[test]
    fn selected_text_is_a_clear_step_from_the_tint_and_every_colour_still_reads_on_it() {
        let sel = |bg: Rgb| match Theme::banded(bg).selection() {
            Some(Color::Rgb(r, g, b)) => (r, g, b),
            other => panic!("{bg:?}: {other:?}"),
        };
        for (palette, backgrounds, name, text) in [
            (&LIGHT, &BACKGROUNDS[..3], "light", (0, 0, 0)),
            (&DARK, &BACKGROUNDS[3..], "dark", (255, 255, 255)),
        ] {
            for bg in backgrounds {
                let s = sel(*bg);
                assert!(
                    contrast(s, *bg) >= 1.15 && contrast(s, tint(*bg)) >= 1.1,
                    "{name} {bg:?}: selection {s:?} is not seen against the page and the tint"
                );
                assert!(
                    contrast(text, s) >= 7.0,
                    "{name} {bg:?}: plain text on {s:?}: {:.2}",
                    contrast(text, s)
                );
                for c in [
                    palette.ok,
                    palette.bad,
                    palette.warn,
                    palette.accent,
                    palette.cmd,
                    palette.flag,
                    palette.string,
                    palette.var,
                    quiet_grey(*bg),
                ] {
                    assert!(
                        contrast(c, s) >= 3.0,
                        "{name} {bg:?}: {c:?} on selection {s:?}: {:.2}",
                        contrast(c, s)
                    );
                }
            }
        }
        assert_eq!(Theme::plain().selection(), None, "no colour, no band");
    }

    #[test]
    fn colorfgbg_tells_light_from_dark_and_nothing_else() {
        assert_eq!(bg_from_colorfgbg("0;15"), Some((255, 255, 255)));
        assert_eq!(bg_from_colorfgbg("15;0"), Some((24, 24, 24)));
        assert_eq!(bg_from_colorfgbg("15;default;0"), Some((24, 24, 24)));
        assert_eq!(bg_from_colorfgbg("12;100"), None);
        assert_eq!(bg_from_colorfgbg("x"), None);
    }

    #[test]
    fn without_colour_there_is_no_tint_and_no_hue_and_unknown_backgrounds_use_the_terminals_own() {
        let t = Theme::plain();
        assert!(t.band().is_none());
        assert_eq!(t.cmd(), Style::default());
        let unknown = Theme {
            color: true,
            bg: None,
        };
        assert_eq!(unknown.ok().fg, Some(Color::Green));
        assert_eq!(
            Theme::banded((255, 255, 255)).ok().fg,
            Some(Color::Rgb(26, 127, 55))
        );
    }
}
