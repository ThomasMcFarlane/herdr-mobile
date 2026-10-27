---
name: herdr-explore
description: Find the best answer to a hard, open non-UI question by making several agents think in deliberately different directions, attacking each one for edge cases, then picking and merging. Use it for an architecture, protocol, process or prevention decision that will be costly to reverse or that more than one reasonable answer exists for: how to stop a recurring mistake, how to handle release numbers, how to model a new agent kind, how to keep a link alive in the background, whether to build or delete. Use it whenever the owner says "think hard", "cover edge cases", "explore options", "different directions", "what is the best way", "tear this apart", "which approach", or when two earlier answers disagreed. Skip it for a one-line fix, a decision the owner has already made, and a UI question (herdr-prototype). Pair it with herdr-plan (this is its section 3 when the design is open) and herdr-design (the journey).
---

# Exploring directions, then attacking them

One agent that thinks hard still thinks one way. In this repo's own evals, two agents given the same release-number question chose different mechanisms (a CI check, and a release step that allocates the number on `main`), and each found a fact the other missed: the check proved its rule on the real `b864c70`, the other found the cause, that the version is picked before the merge order is known. Neither answer alone was the best one. What finds the best answer is directions forced apart, then a separate attempt to break each, then a pick.

It costs about five times one agent. Use it when being wrong costs a release, a migration or a rework, not otherwise.

## 0. Is it worth it

| Use | Skip |
| --- | --- |
| Open decision, several defensible answers, costly to reverse | The owner already chose; implement via `herdr-plan` |
| Two prior answers disagreed | A UI/feel question: `herdr-prototype`, and the phone |
| A recurring mistake needs the right level of fix | A bug with a known cause: fix it |
| Contract with an outside system is unknown | Unknown contract only: capture it first (`herdr-plan` section 3), then decide |

## 1. Frame (you do this, not the agents)

Every candidate gets the same frame, so the frame is the contract.

- **The question** in one sentence, in the owner's words, and the moment (`herdr-design` step 1).
- **Facts already established**, with evidence (hash, `file:line`, command output). Candidates must not re-derive them or contradict them without proof. A premise nobody tested goes in as `assumed`: the first thing a candidate may do is test it (`references/prompts.md`, "premise").
- **Constraints that bind:** `AGENTS.md` principles and the docs of the subsystem. Name the ones that bite.
- **A rubric of 4-6 gradeable criteria,** written now and shown to candidates never, so none is tuned to it. Always include: does it survive the failure modes of `herdr-plan` section 4 (background, reconnect, odd input, bounds, trust, old data); cost to reverse; blast radius outside the diff; how a second agent in a worktree could misuse it; what has to be true to ship it (the proof). Add the criteria this question needs.
- **What else would show it is right,** other than the agent saying so: a failing-then-passing run on code from history, a capture, a command's output.

## 2. Pick the directions

Three or four, different on an axis, not three phrasings of one idea. Write each as a one-line assignment. Always one of them is **subtract**: do nothing, or delete, or the smallest change; it is the control every other direction must beat, and it is often right (`AGENTS.md`: delete dead weight).

Axes that fit this repo (pick the ones that actually split the question):

- **Where it lives:** eliminate by architecture (one owner, one way, the wrong thing cannot compile) / enforce by a check (a lint whose message names the fix, a CI step) / document (prose, last).
- **When it happens:** before the work (at branch, at plan) / during (a gate) / after (release, review).
- **Who bears it:** the agent / the tool / the owner.
- **Reuse or build:** extend what exists (`tool/design_lint.dart`, `check.sh`, a skill) / a new thing.

Diversity is by assignment, since the subagents share one model. A candidate that is told its direction and must argue against the others' obvious answer gives you the dissent a second model would.

## 3. Fan out

One `task` batch, all directions at once. Each gets the frame and its direction from `references/prompts.md` ("candidate"), and must return, in this order:

1. **The proposal,** concrete enough to implement: files, commands, who does what when.
2. **The premise it stands on,** tested if cheap.
3. **Edge cases it found,** each as `scenario -> what happens -> handled / not`; at least the six classes of `herdr-plan` section 4, with this question's scenario, not the class name.
4. **What it rejected, and why,** including the strongest other direction.
5. **Proof,** run in a scratch clone (`git clone --no-hardlinks <repo> /tmp/<name>-clone`), with the real output. "Not run" is a valid answer, stated.
6. **What it cannot judge** (the phone, a hosted runner, the owner's call).

Rules in every candidate's task text, because they have each been broken: **scratch work is a full clone, never a `git worktree`.** A worktree shares `.git/config`, remotes, tags and branches with the real repo, so a `git remote set-url`, `git fetch --prune` or `git tag` there rewrote the real repo's `origin` and pruned every `origin/*` ref (three attackers in the first run; repaired by `set-url` and `fetch`). A clone's config is its own: point its `origin` at a scratch bare repo there. Also: leave the real tree untouched (a with-skill agent once edited `AGENTS.md` and `ci.yml` in the real repo, then restored them); never kill a process it did not start; no mutating herdr call with empty params; do not read other candidates' work. After the batch, check the real repo yourself, not only `git status`: `git remote -v`, `git for-each-ref refs/remotes | wc -l`, `git tag | wc -l`, `git stash list`. Anything unexpected is the first thing to report.

A candidate that produces nothing: go on with N-1 and say so; a parked agent can be nudged with `write agent://<name>`.

## 4. Attack

A different agent per surviving candidate (or one for each pair), told only to break it, not to be balanced (`references/prompts.md`, "attacker"). It gets the proposal and the frame, never the candidate's own edge-case list: a list the author wrote is the list the author thought of. It must come back with concrete failing scenarios, each marked `ran` (with output) or `reasoned`, and the one fact the proposal's safety rests on, tested if cheap.

Look for: the premise false; two agents or worktrees doing it at once; the state after a crash halfway; the old data and sessions already running; the check passing on `main` but never proven on the mistake it targets; a rule that adds more upkeep than the mistake costs.

A finding is **kept** only with a scenario you can state in one sentence. "Might be fragile" is dropped.

## 5. Pick, then merge

- Score every candidate against the rubric, criterion by criterion, from the work and the attacks, not a feel. Read all of it first.
- If one direction wins on every criterion that matters, take it. If they win on different ones, graft: take the base, then one or two pieces from the others by hand, so the result is one design under one mental model, not a paste.
- If the candidates converge on one shape, say it: that is the strongest signal you will get. If they diverge wildly, the frame was loose. Reframe and rerun the part that diverged, do not average.
- **Subtract still beats nothing proven.** If the control survives the attacks and the others do not clearly beat it, recommend it.
- Anything the winner cannot be proven by (a phone, hosted CI, the owner's taste) goes to the owner as a decision with your recommendation (`herdr-plan` section 1), not into the plan as settled.

## 6. Report

Short. A table first:

| Direction | Verdict | Survived (what the attack could not break) | Broke on (scenario) | Proof |
| --- | --- | --- | --- | --- |

Then: the recommendation and the one fact it rests on; grafts and their source; what was rejected and why; edge cases still open; decisions for the owner; what was not run. Do not apply the change: hand over a plan (`herdr-plan`) unless the owner said to build.

## Never / Instead

| Never | Instead |
| --- | --- |
| Three directions that are one idea reworded | Pick an axis; include subtract |
| Let a candidate grade itself | A separate attacker, which does not see the author's edge cases |
| Average two answers | Pick a base, graft by hand, or reframe |
| Count "might be fragile" as a finding | A scenario in one sentence, `ran` or `reasoned` |
| Trust a proof that never failed on the old mistake | Run it on code from history |
| Explore a decided or tiny question | Section 0 |
