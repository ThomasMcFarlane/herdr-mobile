#!/usr/bin/env python3
"""A scripted ACP agent that behaves like a real coding agent, for screenshots and demos.
Prompt -> thinks, reads, greps, explains in markdown, edits with a diff, runs tests (fails),
asks permission for a risky command, waits for the answer, then summarises."""
import json, os, sys, time

def send(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

def upd(sid, u):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u}})

def stream(sid, kind, mid, text, pause=0.02):
    for i in range(0, len(text), 18):
        upd(sid, {"sessionUpdate": kind, "messageId": mid, "content": {"type": "text", "text": text[i:i+18]}})
        time.sleep(pause)

def tool(sid, tid, title, kind, status, raw=None, content=None):
    u = {"sessionUpdate": "tool_call" if status == "in_progress" and content is None else "tool_call_update",
         "toolCallId": tid, "title": title, "kind": kind, "status": status}
    if raw: u["rawInput"] = raw
    if content: u["content"] = content
    upd(sid, u)

def text(t): return [{"type": "content", "content": {"type": "text", "text": t}}]

TEST_FAIL = "\n".join([
    "00:01 +3: SyncService retries after a dropped connection",
    "00:01 +3 -1: SyncService reconnects and flushes the queue [E]",
    "  Expected: <3>",
    "    Actual: <2>",
    "  package:matcher                       expect",
    "  test/sync_test.dart 48:7              main.<fn>.<fn>",
    "",
    "To run this test again: flutter test test/sync_test.dart -p vm --plain-name 'reconnects'",
    "00:01 +3 -1: Some tests failed.",
])

def run(sid, prompt):
    stream(sid, "agent_thought_chunk", "th1", "The test is flaky, so it probably races on a timer. Let me read it and the service before guessing.")
    time.sleep(0.25 + float(os.environ.get("DEMO_PAUSE", "0")))
    tool(sid, "t1", "Read test/sync_test.dart", "read", "in_progress", {"file_path": "test/sync_test.dart"})
    time.sleep(0.2)
    tool(sid, "t1", "Read test/sync_test.dart", "read", "completed", None, text("void main() {\n  test('reconnects', () async {\n    await Future.delayed(Duration(milliseconds: 50));\n    ...\n"))
    tool(sid, "t2", "Grep Future.delayed in lib/", "search", "in_progress", {"pattern": "Future.delayed", "path": "lib"})
    time.sleep(0.15)
    tool(sid, "t2", "Grep Future.delayed in lib/", "search", "completed", None, text("lib/sync.dart:88: await Future.delayed(retryDelay);"))
    time.sleep(0.2)
    stream(sid, "agent_message_chunk", "m1",
        "I found the cause. `SyncService` waits a fixed **50 ms** for the reconnect, and the test asserts right after:\n\n"
        "- the retry timer fires *after* the assertion on a slow machine\n"
        "- the queue is flushed in `onConnected`, which the test never awaits\n\n"
        "The fix is to make the service expose the reconnect as a `Future` and await that:\n\n"
        "```dart\nawait service.reconnect();\nexpect(service.flushed, 3);\n```\n")
    tool(sid, "t3", "Edit lib/sync.dart", "edit", "in_progress", {"file_path": "lib/sync.dart"})
    time.sleep(0.25)
    old = "class SyncService {\n  Future<void> connect() async {\n    _socket = await open();\n    await Future.delayed(retryDelay);\n    _flush();\n  }\n}\n"
    new = "class SyncService {\n  Future<void> connect() async {\n    _socket = await open();\n    await reconnect();\n  }\n\n  /// Completes once the queue is flushed.\n  Future<void> reconnect() async {\n    await _flush();\n  }\n}\n"
    upd(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "t3", "title": "Edit lib/sync.dart", "kind": "edit", "status": "completed",
              "content": [{"type": "diff", "path": "lib/sync.dart", "oldText": old, "newText": new}]})
    tool(sid, "t4", "Run flutter test test/sync_test.dart", "execute", "in_progress", {"command": "flutter test test/sync_test.dart"})
    time.sleep(0.5)
    tool(sid, "t4", "Run flutter test test/sync_test.dart", "execute", "failed", None, text(TEST_FAIL))
    stream(sid, "agent_message_chunk", "m2", "\nStill one failure. The assertion counts `flushed` before `_flush` finishes. I need to clear the stale build output first, then run the whole suite.\n")
    # a permission request
    send({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission", "params": {
        "sessionId": sid,
        "toolCall": {"toolCallId": "t5", "title": "Run rm -rf build/.dart_tool && flutter test", "kind": "execute",
                     "rawInput": {"command": "rm -rf build/.dart_tool && flutter test --coverage --no-pub"}},
        "options": [{"optionId": "once", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "always", "name": "Always allow `flutter test`", "kind": "allow_always"},
                    {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
    answer = None
    for line in sys.stdin:
        m = json.loads(line)
        if m.get("id") == 9001 and "result" in m:
            answer = m["result"]["outcome"].get("optionId"); break
        if m.get("method") == "session/cancel":
            return "cancelled"
    if answer == "no":
        stream(sid, "agent_message_chunk", "m3", "Understood, I will leave the build directory alone.")
        return "end_turn"
    tool(sid, "t5", "Run rm -rf build/.dart_tool && flutter test", "execute", "in_progress", {"command": "rm -rf build/.dart_tool && flutter test --coverage --no-pub"})
    time.sleep(0.6)
    tool(sid, "t5", "Run rm -rf build/.dart_tool && flutter test", "execute", "completed", None, text("All 214 tests passed!"))
    stream(sid, "agent_message_chunk", "m3",
        "\n## Result\n\nThe suite is green: **214 passed**, 0 failed.\n\n"
        "| file | change |\n|:--|--:|\n| `lib/sync.dart` | +6 −2 |\n| `test/sync_test.dart` | await `reconnect()` |\n\n"
        "1. `reconnect()` now returns a `Future`\n2. The test awaits it instead of sleeping\n\n"
        "> The 50 ms sleep was the whole bug; nothing else needed to change.\n")
    return "end_turn"

sid = "sess-1"
for line in sys.stdin:
    m = json.loads(line)
    mid, method = m.get("id"), m.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid}})
    elif method == "session/prompt":
        reason = run(sid, m["params"]["prompt"][0]["text"])
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": reason}})
    elif method == "session/load":
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": "unsupported while live"}})
