#!/usr/bin/env python3
"""Records what the python keeper's ReplayLog does on seeded random sessions, for
the Rust port to be compared against (rust/crates/keeper/tests/replay_differential.rs).

The reference is the python embedded in app/lib/data/services/keeper_script.dart,
extracted and run unchanged. The Rust test runs this script itself (and skips when
python3 is missing), so nothing generated is committed:
    python3 tool/gen-replay-fixtures.py OUT.json
"""
import copy
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "app", "lib", "data", "services", "keeper_script.dart")


def load_reference():
    text = open(SRC, encoding="utf-8").read()
    body = text.split("const keeperPython = r'''\n", 1)[1].rsplit("\n''';", 1)[0]
    body = body.replace("@@ROUTES@@", "[]")
    ns = {"__name__": "keeper_reference", "__file__": "keeper-reference.py"}
    exec(compile(body, "keeper_script", "exec"), ns)
    return ns


def enc_len(ns, msg):
    return len(ns["enc"](msg))


def note(update):
    return {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": update}}


def text_of(rng, n):
    alphabet = "abcdefg hijé→\U0001F600"
    return "".join(rng.choice(alphabet) for _ in range(n))


def make_message(rng, state):
    r = rng.random()
    if r < 0.14:
        state["u"] += 1
        return note({"sessionUpdate": "user_message_chunk", "messageId": "u%d" % state["u"],
                     "content": {"type": "text", "text": text_of(rng, rng.randint(1, 40))}}), None
    if r < 0.38:
        mid = "m%d" % rng.randint(max(0, state["m"] - 1), state["m"] + (1 if rng.random() < 0.4 else 0))
        state["m"] = max(state["m"], int(mid[1:]))
        kind = "agent_thought_chunk" if rng.random() < 0.2 else "agent_message_chunk"
        u = {"sessionUpdate": kind, "messageId": mid, "content": {"type": "text", "text": text_of(rng, rng.randint(1, 300))}}
        if rng.random() < 0.05:
            u["_meta"] = {"x": 1}
        return note(u), None
    if r < 0.50:
        k = rng.choice(["available_commands_update", "current_mode_update", "config_option_update",
                        "session_info_update", "usage_update"])
        return note({"sessionUpdate": k, "value": text_of(rng, rng.randint(1, 80))}), None
    # a tool call
    if rng.random() < 0.45 or not state["tools"]:
        state["t"] += 1
        tid = "t%d" % state["t"]
        state["tools"].append(tid)
        kind, status = "tool_call", "pending"
    else:
        tid = rng.choice(state["tools"][-4:])
        kind, status = "tool_call_update", rng.choice(["in_progress", "in_progress", "completed", "failed"])
    u = {"sessionUpdate": kind, "toolCallId": tid, "title": "run " + text_of(rng, rng.randint(1, 60)),
         "kind": rng.choice(["execute", "read", "edit"]), "status": status,
         "locations": [{"path": "/p%d" % i} for i in range(rng.randint(0, 25))]}
    if rng.random() < 0.7:
        u["rawInput"] = rng.choice([
            {"command": "ls " + text_of(rng, rng.randint(1, 400)), "env": text_of(rng, 30)},
            "cmd " + text_of(rng, rng.randint(1, 400)),
            {"other": 1},
            None,
        ])
    if rng.random() < 0.8:
        u["rawOutput"] = "o" * rng.randint(0, 3000)
    if rng.random() < 0.6:
        u["content"] = [rng.choice([
            {"type": "terminal", "terminalId": "z" * rng.randint(1, 600)},
            {"type": "content", "content": {"type": "text", "text": text_of(rng, rng.randint(1, 800))}},
            {"type": "diff", "path": "/a", "newText": "n" * rng.randint(1, 900)},
        ]) for _ in range(rng.randint(1, 3))]
    elif rng.random() < 0.05:
        u["content"] = None
    meta = {}
    if rng.random() < 0.3:
        meta["terminal_output"] = {"data": "d" * 50}
    if rng.random() < 0.3:
        meta["claudeCode"] = {"toolName": "Bash", "parentToolUseId": rng.choice(["", "p1", "p2"]),
                              "toolResponse": "r" * rng.choice([10, 3000])}
    if rng.random() < 0.2:
        meta["big"] = "b" * 2500
    if meta:
        u["_meta"] = meta
    if rng.random() < 0.1:
        u["extra"] = "e" * rng.choice([5, 2500])
    return note(u), tid


def scenario(ns, rng, seed):
    max_bytes = rng.choice([2500, 6000, 20000, 90000])
    max_entries = rng.choice([12, 40, 200, 5000])
    full = rng.choice([1, 2, 3])
    soft = rng.choice([None, max_bytes // 2, max_bytes // 4])
    log = ns["ReplayLog"](max_bytes, max_entries, full, soft)
    state = {"u": 0, "m": 0, "t": 0, "tools": []}
    ops, steps, entries_by_op = [], [], {}
    for i in range(rng.randint(30, 140)):
        if rng.random() < 0.06 and entries_by_op:
            target = rng.choice(sorted(entries_by_op))
            ok = log.remove(entries_by_op[target])
            ops.append({"remove": target})
            steps.append({"removed": ok, **stats(log)})
            continue
        msg, tid = make_message(rng, state)
        waiting = sorted(set(rng.sample(state["tools"], min(len(state["tools"]), rng.randint(0, 2))))) if state["tools"] and rng.random() < 0.3 else []
        size = enc_len(ns, msg)
        ops.append({"add": copy.deepcopy(msg), "size": size, "waiting": waiting})
        entries_by_op[i] = log.add(copy.deepcopy(msg), size, lambda w=set(waiting): w)
        steps.append(stats(log))
    final = [[e["o"], e["n"], seq] for e, seq in log.replay(None)]
    since = {}
    for k in (0, 1, log.next_seq // 2, max(0, log.next_seq - 1)):
        since[str(k)] = [[e["o"], seq] for e, seq in log.replay(k)]
    return {"seed": seed, "params": {"max_bytes": max_bytes, "max_entries": max_entries, "full_turns": full, "soft_bytes": soft},
            "ops": ops, "steps": steps, "final": final, "since": since}


def stats(log):
    return {"bytes": log.bytes, "count": log.count, "dropped": log.dropped, "trimmed": log.trimmed,
            "turns": len(log.turns), "next_seq": log.next_seq}


def main():
    ns = load_reference()
    if len(sys.argv) != 2:
        sys.exit("usage: gen-replay-fixtures.py OUT.json")
    out = [scenario(ns, random.Random(seed), seed) for seed in range(60)]
    with open(sys.argv[1], "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"))


if __name__ == "__main__":
    sys.exit(main())
