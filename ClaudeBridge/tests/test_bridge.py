import http.server
import json
import pathlib
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import tv_bridge  # noqa: E402


class Fake:
    """A fake TV (prefix "/claude") or notch (no prefix) on 127.0.0.1."""

    def __init__(self, prefix="", token="tok", poll="pending", answers=None, post_extra=None):
        self.prefix, self.token = prefix, token
        self.poll, self.answers, self.post_extra = poll, answers, post_extra or {}
        self.posts, self.deletes, self.events, self.polls = [], [], [], 0
        self.lock = threading.Lock()
        fake = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, code, body=None):
                raw = json.dumps(body).encode() if body is not None else b""
                self.send_response(code)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def route(self):
                path = urlparse(self.path).path
                return path[len(fake.prefix):] if path.startswith(fake.prefix) else None

            def authed(self):
                return self.headers.get("Authorization") == f"Bearer {fake.token}"

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                r = self.route()
                if not self.authed():
                    return self.reply(401, {})
                with fake.lock:
                    if r == "/decision":
                        fake.posts.append(body)
                        return self.reply(201, {"id": f"{fake.prefix.strip('/') or 'notch'}-1", **fake.post_extra})
                    fake.events.append(body)
                self.reply(200, {})

            def do_GET(self):
                with fake.lock:
                    fake.polls += 1
                    deleted = f"/decision/{urlparse(self.path).path.rsplit('/', 1)[-1]}" in fake.deletes
                if deleted:  # like the real servers: a deleted decision is gone
                    return self.reply(404, {})
                if fake.poll == "pending":
                    time.sleep(0.2)
                    return self.reply(200, {"status": "pending"})
                out = {"status": fake.poll}
                if fake.answers:
                    out["answers"] = fake.answers
                self.reply(200, out)

            def do_DELETE(self):
                with fake.lock:
                    fake.deletes.append(self.route())
                self.reply(204)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def closed_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


PERMISSION = {"hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/nonexistent",
              "tool_name": "Bash", "tool_input": {"command": "ls", "description": "list"}}


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.saved = {k: getattr(tv_bridge, k) for k in ("HOME", "CONFIG", "STATE", "NOTCH_BRIDGE", "DECISION_WAIT_S")}
        self.addCleanup(lambda: [setattr(tv_bridge, k, v) for k, v in self.saved.items()])
        tv_bridge.HOME = self.tmp / "tv"
        tv_bridge.CONFIG = tv_bridge.HOME / "config.json"
        tv_bridge.STATE = tv_bridge.HOME / "state"
        tv_bridge.NOTCH_BRIDGE = self.tmp / "boring-notch" / "claude-bridge.json"
        tv_bridge.DECISION_WAIT_S = 5
        self.fakes = []
        self.addCleanup(lambda: [f.stop() for f in self.fakes])

    def tv(self, **kw):
        f = Fake(prefix="/claude", token="tvtok", **kw)
        self.fakes.append(f)
        tv_bridge.save_json(tv_bridge.CONFIG, {"host": "127.0.0.1", "port": f.port, "token": "tvtok", "name": "Mac"})
        return f

    def notch(self, **kw):
        f = Fake(token="notchtok", **kw)
        self.fakes.append(f)
        self.bridge_file(f.port)
        return f

    def bridge_file(self, port):
        tv_bridge.save_json(tv_bridge.NOTCH_BRIDGE, {"port": port, "token": "notchtok", "pid": 1})

    def test_notch_allow_wins_and_tv_deleted(self):
        tv, notch = self.tv(poll="pending"), self.notch(poll="allow")
        out = tv_bridge.handle_hook(dict(PERMISSION))
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "allow"})
        self.assertEqual(tv.deletes, ["/decision/claude-1"])
        self.assertEqual(notch.posts[0]["kind"], "permission")
        self.assertEqual(notch.posts[0]["question"], "Allow running ls?")

    def test_tv_deny_wins(self):
        self.tv(poll="deny"), self.notch(poll="pending")
        out = tv_bridge.handle_hook(dict(PERMISSION))
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "deny", "message": "Declined on the TV"})
        self.assertEqual(self.fakes[1].deletes, ["/decision/notch-1"])

    def test_notch_deny_message(self):
        self.notch(poll="deny")
        out = tv_bridge.handle_hook(dict(PERMISSION))
        self.assertEqual(out["hookSpecificOutput"]["decision"]["message"], "Declined in the notch")

    def test_no_targets_prints_nothing(self):
        self.assertIsNone(tv_bridge.handle_hook(dict(PERMISSION)))

    def test_stale_bridge_file_falls_back_within_2s(self):
        self.bridge_file(closed_port())
        t = time.time()
        self.assertIsNone(tv_bridge.handle_hook(dict(PERMISSION)))
        self.assertLess(time.time() - t, 2)
        self.assertFalse((tv_bridge.STATE / "notch.down").exists())

    def test_tv_down_notch_still_works(self):
        tv_bridge.save_json(tv_bridge.CONFIG, {"host": "127.0.0.1", "port": closed_port(), "token": "x", "name": "Mac"})
        self.notch(poll="allow")
        out = tv_bridge.handle_hook(dict(PERMISSION))
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "allow"})
        self.assertTrue(tv_bridge.state_path("s1").exists())

    def test_question_goes_to_notch_only_and_returns_updated_input(self):
        tv = self.tv(poll="allow")
        notch = self.notch(poll="answer", answers={"Which?": "A"})
        questions = [{"question": "Which?", "options": [{"label": "A"}, {"label": "B"}]}]
        data = {**PERMISSION, "tool_name": "AskUserQuestion", "tool_input": {"questions": questions}}
        out = tv_bridge.handle_hook(data)
        self.assertEqual(out["hookSpecificOutput"]["decision"],
                         {"behavior": "allow", "updatedInput": {"questions": questions, "answers": {"Which?": "A"}}})
        self.assertEqual(tv.posts, [])
        self.assertEqual((notch.posts[0]["kind"], notch.posts[0]["question"], notch.posts[0]["questions"]),
                         ("question", "Which?", questions))

    def test_timeout_prints_nothing(self):
        tv, notch = self.tv(poll="pending"), self.notch(poll="pending")
        tv_bridge.DECISION_WAIT_S = 1
        t = time.time()
        self.assertIsNone(tv_bridge.handle_hook(dict(PERMISSION)))
        self.assertLess(time.time() - t, 3)
        self.assertEqual((tv.deletes, notch.deletes), (["/decision/claude-1"], ["/decision/notch-1"]))

    def test_approvals_off_keeps_waiting_on_notch(self):
        tv = self.tv(poll="allow", post_extra={"approvalsOff": True})
        self.notch(poll="allow")
        out = tv_bridge.handle_hook(dict(PERMISSION))
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "allow"})
        self.assertEqual(tv.polls, 0)

    def test_withdrawn_notch_leaves_race_others_continue(self):
        self.tv(poll="deny"), self.notch(poll="withdrawn")
        out = tv_bridge.handle_hook(dict(PERMISSION))
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_withdrawn_notch_alone_prints_nothing(self):
        self.notch(poll="withdrawn")
        self.assertIsNone(tv_bridge.handle_hook(dict(PERMISSION)))

    def test_answer_without_answers_is_not_allow(self):
        for answers in (None, {}, {"Which?": 1}):
            self.notch(poll="answer", answers=answers)
            data = {**PERMISSION, "tool_name": "AskUserQuestion", "tool_input": {"questions": [{"question": "Which?"}]}}
            self.assertIsNone(tv_bridge.handle_hook(data), answers)

    def test_answer_on_permission_prompt_is_not_allow(self):
        self.notch(poll="answer", answers={"Which?": "A"})
        self.assertIsNone(tv_bridge.handle_hook(dict(PERMISSION)))

    def test_cancel_pending_with_no_bridge_file_does_not_raise(self):
        state = {"tasks": [], "pending": {"tv": "t9", "notch": "n9"}}
        tv_bridge.cancel_pending([tv_bridge.NotchTarget()], state)
        self.assertIsNone(state["pending"])
        tv_bridge.save_json(tv_bridge.state_path("s1"), {"tasks": [], "pending": {"notch": "n9"}})
        self.assertIsNone(tv_bridge.handle_hook({"hook_event_name": "Stop", "session_id": "s1", "cwd": "/nonexistent"}))

    def test_target_returning_json_list_drops_out(self):
        f = Fake(token="notchtok")
        f.server.RequestHandlerClass.reply = lambda h, code, body=None: (
            h.send_response(201), h.send_header("Content-Length", "2"), h.end_headers(), h.wfile.write(b"[]"))
        self.fakes.append(f)
        self.bridge_file(f.port)
        self.tv(poll="allow")
        out = tv_bridge.handle_hook(dict(PERMISSION))
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "allow"})
        self.assertTrue(tv_bridge.state_path("s1").exists())

    def test_other_event_cancels_pending_on_all_targets(self):
        tv, notch = self.tv(), self.notch()
        tv_bridge.save_json(tv_bridge.state_path("s1"), {"tasks": [], "pending": {"tv": "t9", "notch": "n9"}})
        tv_bridge.handle_hook({"hook_event_name": "Stop", "session_id": "s1", "cwd": "/nonexistent"})
        self.assertEqual(tv.deletes, ["/decision/t9"])
        self.assertEqual(notch.deletes, ["/decision/n9"])
        self.assertIsNone(tv_bridge.load_state("s1")["pending"])

    def test_pending_ids_persisted_while_polling_so_terminal_answer_cancels(self):
        notch = self.notch(poll="pending")
        tv_bridge.DECISION_WAIT_S = 10
        result = {}
        t = threading.Thread(target=lambda: result.setdefault("out", tv_bridge.handle_hook(dict(PERMISSION))))
        start = time.time()
        t.start()
        # The ids must be on disk while the race is still polling.
        while tv_bridge.load_state("s1").get("pending") != {"notch": "notch-1"}:
            self.assertLess(time.time() - start, 3, "pending ids never persisted before polling")
            time.sleep(0.05)
        self.assertTrue(t.is_alive())
        # Answered in the terminal: the next hook event cancels the decision.
        tv_bridge.handle_hook({"hook_event_name": "PostToolUse", "session_id": "s1", "cwd": "/nonexistent",
                               "tool_name": "Bash", "tool_input": {"command": "ls"}})
        self.assertEqual(notch.deletes, ["/decision/notch-1"])
        t.join(3)
        self.assertFalse(t.is_alive(), "the in-flight poll did not end after the decision was deleted")
        self.assertLess(time.time() - start, 4)
        self.assertIsNone(result["out"])  # gone is never an allow
        self.assertIsNone(tv_bridge.load_state("s1")["pending"])

    def test_allow_on_question_prints_nothing(self):
        self.notch(poll="allow")
        data = {**PERMISSION, "tool_name": "AskUserQuestion", "tool_input": {"questions": [{"question": "Which?"}]}}
        self.assertIsNone(tv_bridge.handle_hook(data))


if __name__ == "__main__":
    unittest.main()
