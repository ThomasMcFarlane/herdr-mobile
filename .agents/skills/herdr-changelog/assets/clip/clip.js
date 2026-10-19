// herdr mobile release clip: the timeline for index.html (its header says
// what the clip is; make_clip.sh fills the variables this reads).

// make_clip.sh appends `hold` + FADE seconds of held last frame.
const FADE = 0.4;
const W = 1080;
const H = 1920;
const ZOOM = 1.2; // punch-in, within 1.15-1.3; crops less of the screen than 1.3
const MERGE_GAP = 2.0; // closer gestures share one punch-in and pan
const EDGE = 140; // a drag keeps this much canvas around its ends
const BOTTOM_BAND = H - 200 - 300; // touches below this move the caption up
const EASE = "power4.out"; // Motion.easeOut
const CAMERA_EASE = "sine.inOut";
const IN = 0.25; // Motion.sheetIn
const OUT = 0.19; // Motion.sheetOut

const vars = window.__hyperframes.getVariables();
const HOLD = Number(vars.hold);
const steps = JSON.parse(vars.touches).steps || [];
const chapters = steps.filter((s) => s.kind === "chapter");
const touchSteps = steps.filter((s) => s.kind !== "chapter");
const total = Number(document.getElementById("recording").dataset.duration);
const footageEnd = total - HOLD - FADE;
// The chapter a moment belongs to: the last one started by then (-1: none).
const chapterAt = (t) => {
  let c = -1;
  chapters.forEach((ch, i) => {
    if (ch.t <= t) c = i;
  });
  return c;
};

const tl = gsap.timeline({ paused: true });

// ---- Caption pieces ---------------------------------------------------------
function fillText(el, text) {
  text.split("`").forEach((part, i) => {
    if (!part) return;
    if (i % 2 === 1) {
      const label = document.createElement("span");
      label.className = "ui";
      label.textContent = part;
      el.appendChild(label);
    } else {
      el.appendChild(document.createTextNode(part));
    }
  });
}
function span(cls, text) {
  const el = document.createElement("span");
  el.className = cls;
  el.textContent = text;
  return el;
}
function pill(lane, cls) {
  const el = document.createElement("div");
  el.className = "caption" + (cls ? " " + cls : "");
  // Captions crossfade in one place: the overlap is brief and meant.
  el.setAttribute("data-layout-allow-overlap", "");
  document.getElementById(lane).appendChild(el);
  return el;
}
function stepPill(lane, text) {
  const el = pill(lane);
  fillText(el, text);
  return el;
}
function tryPill(text, lane) {
  const el = pill(lane);
  const label = document.createElement("span");
  label.className = "try";
  // Lucide lightbulb, as on the in-app Tip card.
  label.innerHTML =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
    '<path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/>' +
    '<path d="M9 18h6"/><path d="M10 22h4"/></svg>Try it:';
  el.appendChild(label);
  el.appendChild(document.createTextNode(" "));
  fillText(el, text.replace(/^\s*Try it:\s*/i, ""));
  return el;
}
// A chapter card: progress through the change list (done, now, to come),
// "2/5" and the change's name, and a slot for the current step's label.
function chapterPill(lane, ch, count) {
  const el = pill(lane, "chapter");
  const bar = document.createElement("div");
  bar.className = "bar";
  for (let i = 1; i <= count; i++) {
    bar.appendChild(span("seg" + (i < ch.index ? " done" : i === ch.index ? " now" : ""), ""));
  }
  el.appendChild(bar);
  const head = document.createElement("div");
  head.appendChild(span("count", ch.index + "/" + count));
  const name = span("name", "");
  fillText(name, ch.label);
  head.appendChild(name);
  el.appendChild(head);
  const lines = document.createElement("div");
  lines.className = "lines";
  el.appendChild(lines);
  return { el, lines };
}
function endPill(count, lane) {
  const el = pill(lane, "end");
  el.appendChild(span("name", "herdr mobile " + vars.version));
  el.appendChild(document.createElement("div")).appendChild(
    span("sub", count + (count === 1 ? " change" : " changes")),
  );
  return el;
}

// ---- Gestures: when each touch is down -------------------------------------
// A release ends the drag before it (the ring lifts there); a drag with no
// release lifts just after it stops moving.
const gestures = [];
touchSteps.forEach((s, i) => {
  if (s.kind === "tap") {
    gestures.push({ kind: "tap", start: s.t, end: s.t + 0.2, points: [s] });
  } else if (s.kind === "drag") {
    const next = touchSteps[i + 1];
    const lift = next && next.kind === "release" ? next.t : Math.min(s.until + 0.1, footageEnd);
    gestures.push({ kind: "drag", start: s.t, moveEnd: s.until, end: lift, points: [s, s.to] });
  }
});
gestures.forEach((g) => (g.chapter = chapterAt(g.start)));

// ---- Camera -----------------------------------------------------------------
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
// Centre a point at scale s without showing past the canvas edge. The clamp
// never moves a point closer to an edge than it is at 1x.
function aim(px, py, s) {
  return {
    scale: s,
    x: clamp(W / 2 - s * px, W * (1 - s), 0),
    y: clamp(H / 2 - s * py, H * (1 - s), 0),
  };
}
// A gesture's framing: a tap centres its point; a drag centres its path and
// zooms less if both ends would not fit.
function frame(g) {
  if (g.kind === "tap") return aim(g.points[0].x, g.points[0].y, ZOOM);
  const [a, b] = g.points;
  const fit = Math.min(
    (W - 2 * EDGE) / Math.max(1, Math.abs(b.x - a.x)),
    (H - 2 * EDGE) / Math.max(1, Math.abs(b.y - a.y)),
  );
  return aim((a.x + b.x) / 2, (a.y + b.y) / 2, clamp(fit, 1, ZOOM));
}
const REST = { scale: 1, x: 0, y: 0 };
const camAt = []; // [{t, cam}] where the camera is settled, for caption placement
let cam = REST;
let free = 0.3; // the camera may move once the fade-up is done
function move(to, at, duration) {
  const start = Math.max(at, free);
  const d = Math.max(0.3, duration - (start - at));
  tl.fromTo("#camera", { ...cam }, { ...to, duration: d, ease: CAMERA_EASE, immediateRender: false }, start);
  cam = to;
  free = start + d;
}

if (gestures.length) {
  tl.set("#camera", REST, 0);
  // Group gestures into punch-ins; a chapter always starts a new one.
  const groups = [];
  gestures.forEach((g) => {
    const group = groups[groups.length - 1];
    const prev = group && group[group.length - 1];
    if (prev && prev.chapter === g.chapter && g.start - prev.end < MERGE_GAP) group.push(g);
    else groups.push([g]);
  });
  groups.forEach((group) => {
    // A punch-in that cannot land before its first touch (the camera is still
    // coming back from the last one, or the touch opens a chapter) would zoom
    // in after the fact: leave that group at 1x, its rings still show.
    if (Math.max(group[0].start - 0.75, free) + 0.3 > group[0].start) return;
    group.forEach((g, i) => {
      const target = frame(g);
      const lead = i === 0 ? 0.75 : 0.65; // land shortly before the touch
      move(target, g.start - lead, i === 0 ? 0.6 : 0.55);
      camAt.push({ t: g.start, cam: target });
    });
    // Back to 1x after the group, and by the next chapter at the latest: a new
    // change starts on the whole screen.
    const end = group[group.length - 1].end;
    const next = chapters.find((ch) => ch.t > end);
    move(REST, Math.min(end + 0.4, footageEnd, next ? next.t - 0.2 : Infinity), 0.7);
    camAt.push({ t: free, cam: REST });
  });
} else {
  // Footage with its own touches: one slow settle, nothing else.
  tl.fromTo("#camera", { scale: 1.04, x: -W * 0.02, y: -H * 0.02 }, { scale: 1, x: 0, y: 0, duration: 1.0, ease: EASE }, 0);
}
function screenY(py, t) {
  let c = REST;
  camAt.forEach((k) => {
    if (k.t <= t) c = k.cam;
  });
  return c.y + c.scale * py;
}
const inBottomBand = (s) => [s.y].concat(s.to ? [s.to.y] : []).some((py) => screenY(py, s.t) > BOTTOM_BAND);

// ---- Touch rings (in camera space, so they zoom with the footage) ----------
gestures.forEach((g) => {
  const ring = document.createElement("div");
  ring.className = "ring";
  ring.style.left = g.points[0].x + "px";
  ring.style.top = g.points[0].y + "px";
  document.getElementById("camera").appendChild(ring);
  const down = g.start;
  tl.fromTo(ring, { opacity: 0, scale: 1.15 }, { opacity: 1, scale: 1, duration: 0.1, ease: EASE, immediateRender: false }, down - 0.1);
  if (g.kind === "tap") {
    tl.fromTo(ring, { scale: 1 }, { scale: 0.88, duration: 0.1, ease: EASE, immediateRender: false }, down);
    tl.fromTo(ring, { scale: 0.88 }, { scale: 1, duration: 0.18, ease: EASE, immediateRender: false }, down + 0.1);
  } else {
    const [a, b] = g.points;
    tl.fromTo(ring, { scale: 1 }, { scale: 0.92, duration: 0.1, ease: EASE, immediateRender: false }, down);
    tl.fromTo(
      ring,
      { x: 0, y: 0 },
      { x: b.x - a.x, y: b.y - a.y, duration: Math.max(0.1, g.moveEnd - down), ease: "none", immediateRender: false },
      down,
    );
  }
  tl.fromTo(ring, { opacity: 1 }, { opacity: 0, scale: 1.25, duration: 0.42, ease: EASE, immediateRender: false }, g.end);
});

// ---- Caption sequence -------------------------------------------------------
// One caption card at a time. Without chapters: each step's label from just
// before its touch. With chapters: one card per chapter whose step line
// changes under the change's name. Last: the Try-it path, or "herdr mobile
// <version>" and the number of changes.
const count = chapters.reduce((n, ch) => Math.max(n, ch.total), chapters.length);
// A card goes to the top when its touches would sit under it, or when the
// steps say so ("place": "top", for a change that happens at the bottom of
// the screen, like a toast or a sheet).
const laneFor = (place, touches) =>
  place === "top" || (place !== "bottom" && touches.some(inBottomBand)) ? "lane-top" : "lane-bottom";
const cards = [];
touchSteps
  .filter((s) => chapterAt(s.t) === -1)
  .forEach((s) => {
    const lane = laneFor(s.place, [s]);
    cards.push({ at: s.t - 0.5, make: () => stepPill(lane, s.label), lines: [] });
  });
let finalLane = "lane-bottom";
chapters.forEach((ch, i) => {
  const next = chapters[i + 1];
  const own = touchSteps.filter((s) => s.t >= ch.t && (!next || s.t < next.t));
  const lane = laneFor(ch.place, own);
  finalLane = lane; // the last card replaces the last chapter's, in its place
  cards.push({
    at: ch.t - 0.1,
    make: () => chapterPill(lane, ch, count),
    lines: own.map((s) => ({ at: s.t - 0.5, text: s.label })),
  });
});
cards.sort((a, b) => a.at - b.at);
const lastEnd = gestures.length ? gestures[gestures.length - 1].end : 0;
if (vars.caption) {
  const at = chapters.length
    ? footageEnd - 0.2
    : touchSteps.length
      ? Math.min(lastEnd + 0.4, total - FADE - 1.6)
      : 0.5;
  cards.push({ at, make: () => tryPill(vars.caption, finalLane), lines: [] });
} else if (chapters.length) {
  cards.push({ at: footageEnd - 0.2, make: () => endPill(count, finalLane), lines: [] });
}

let earliest = 0.3;
let shown = null;
cards.forEach((card, i) => {
  const at = Math.max(card.at, earliest);
  const made = card.make();
  const el = made.el || made;
  if (shown) tl.fromTo(shown, { opacity: 1 }, { opacity: 0, duration: OUT, ease: EASE, immediateRender: false }, at);
  tl.fromTo(el, { opacity: 0, y: 40 }, { opacity: 1, y: 0, duration: IN, ease: EASE, immediateRender: false }, at);
  shown = el;
  earliest = at + 0.8; // each card stays long enough to read a few words

  // Step lines inside a chapter card: one at a time, crossfading in place.
  const until = cards[i + 1] ? cards[i + 1].at : total;
  let lineEarliest = at + 0.3;
  let lineShown = null;
  let lineText = null;
  card.lines.forEach((line) => {
    if (line.text === lineText) return; // a release that repeats its drag's label
    const lat = Math.max(line.at, lineEarliest);
    if (lat >= until - 0.3) return; // the next card is already due
    lineText = line.text;
    const lineEl = document.createElement("div");
    lineEl.className = "line";
    lineEl.setAttribute("data-layout-allow-overlap", "");
    fillText(lineEl, line.text);
    made.lines.appendChild(lineEl);
    if (lineShown) tl.fromTo(lineShown, { opacity: 1 }, { opacity: 0, duration: OUT, ease: EASE, immediateRender: false }, lat);
    tl.fromTo(lineEl, { opacity: 0, y: 12 }, { opacity: 1, y: 0, duration: IN, ease: EASE, immediateRender: false }, lat);
    lineShown = lineEl;
    lineEarliest = lat + 0.6;
  });
});

// ---- Fade up, fade out --------------------------------------------------------
tl.fromTo("#veil", { opacity: 1 }, { opacity: 0, duration: 0.3, ease: "power1.out" }, 0);
tl.fromTo("#veil", { opacity: 0 }, { opacity: 1, duration: FADE, ease: "power1.in", immediateRender: false }, total - FADE);

// index.html registers it (the linter wants the registration in the composition).
window.herdrClipTimeline = tl;
