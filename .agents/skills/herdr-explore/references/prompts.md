# Prompt templates

Fill the `<...>`. Paste the frame whole into every task: the agents start blank.

## Shared header (every candidate and attacker)

```
Repo: /home/tuannd12/workspace/herdr-mobile (read AGENTS.md first).
Hard rules:
- Work only in a scratch CLONE, never a git worktree (a worktree shares .git/config, remotes, tags and branches with the real repo; a `remote set-url` or `fetch --prune` there rewrites the real one): git clone --no-hardlinks /home/tuannd12/workspace/herdr-mobile /tmp/<your-name>-clone. Set scratch remotes only inside the clone. Never edit, create or delete a file in the real working tree, never commit, never run git fetch/remote/config/tag/branch against the real repo. Remove your clone when done.
- Never kill a process you did not start; no pkill/killall. Never call a mutating herdr method with empty params.
- Do not read other agents' output under local/ or /tmp.
- Cite evidence as a commit hash, file:line, or a command with its real output. "Not run" is a valid answer; say it.
Write your answer to <output path>.md. Final message: just the path.
```

## candidate

```
<shared header>

# Question
<one sentence, owner's words> Moment: <who, where, what they need>.

# Established (do not re-derive; contradict only with proof)
<facts with evidence>
# Assumed (untested)
<premises>

# Constraints that bind
<AGENTS.md principles and docs by name>

# Your direction: <axis, one line>
Argue this direction as hard as it can honestly be argued. You are one of several agents each told a different direction. Do not hedge toward the middle: if another direction is better, say what it would have to be and why you still could not make yours work.

# Return, in this order
1. The proposal, concrete enough to implement: files, commands, who does what when.
2. The premise it stands on. Test it if cheap (premise: write the one sentence every part of the proposal assumes, then make an observation that would come out differently if it were false).
3. Edge cases: a table `scenario -> what happens -> handled or not`. Cover lifecycle (backgrounded, killed, link drops), state (stale, replay, reset), input (odd spellings, empty, huge), bounds (memory, rows, timers, battery), trust (anything from an agent, a page or a remote host), old data and sessions already running, and two agents or worktrees doing it at once. Use this question's actual scenario for each, not the class name.
4. What you rejected and why, including the strongest other direction.
5. Proof: run the proposal on the real code in your clone, including on the code of a past commit that shows the mistake (git show <hash>^:<path>), and paste what happened.
6. What you cannot judge from here (the phone, a hosted CI runner, the owner's call).
```

## subtract (the control)

```
<same as candidate, with:>
# Your direction: subtract
Argue for doing nothing, or deleting, or the smallest change that could work. Show what today's code and docs already do about this (read them: the thing may already be enforced, as a lint rule that exists and is clean). Say exactly what is left unprotected and what it would cost. This is the control: every other direction has to beat it.
```

## attacker

```
<shared header>

# Frame
<question, established facts, constraints>

# The proposal under attack (verbatim)
<proposal and its premise. NOT its author's edge-case list or proof.>

# Your job
Break it. You are not balanced and not asked for strengths. Find concrete scenarios in which it fails, is bypassed, adds more upkeep than the mistake costs, or makes things worse.
First replay the real incident, not the frame's account of it: how did it actually happen (`git log --format='%h %cn %s'`, merge committers, which refs were pushed by whom)? A proposal that guards a path the incident never took does nothing, however well it is proven on its own path (the first run: `git push --atomic` guards a direct push, but 0.1.21 went through GitHub PR merges).
Try at least: the premise false; two agents or two worktrees at once; a crash halfway; data and sessions of an older version; the check passing on main but never failing on the mistake it targets; a path or input spelled another way; what happens in a month when nobody remembers why.
For each finding: `scenario in one sentence -> what happens -> ran (output) or reasoned`. Run what is cheap in your scratch clone. Drop anything you cannot state as a scenario.
Also return: the one fact the proposal's safety rests on, and whether you tested it.
```
