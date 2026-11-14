#!/usr/bin/env python3
"""tv-bridge: shows Claude Code's progress on the Mi Box and lets you answer its prompts from the couch (SPEC §8),
and sends the same prompts to the Boring Notch app. Permission prompts go to both and the first answer wins;
multiple-choice questions (AskUserQuestion) go to the notch only.

    tv-bridge pair <code> [--host <tv-ip>]     pair with the TV (Settings › Widgets › Mac Running Claude Code › Pair)
    tv-bridge install [--project <dir>]        add the hooks to ~/.claude/settings.json (or <dir>/.claude/settings.json)
    tv-bridge uninstall [--project <dir>]      remove them again
    tv-bridge status                           show the paired TV and check it answers
    tv-bridge snapshot <image> [--caption ..]  send a screenshot to the card
    tv-bridge unpair                           forget the TV on this Mac
    tv-bridge hook                             called by Claude Code; reads the hook JSON on stdin

Standard library only. A hook never breaks Claude Code: every failure is swallowed and the hook exits 0,
and a permission prompt the TV can't answer falls back to the normal terminal prompt (never auto-allow).
"""

import argparse
import base64
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HOME = pathlib.Path.home() / ".config" / "tv-bridge"
CONFIG = HOME / "config.json"
STATE = HOME / "state"
NOTCH_BRIDGE = pathlib.Path.home() / ".config" / "boring-notch" / "claude-bridge.json"
INSTALLED = HOME / "tv_bridge.py"
BIN = pathlib.Path.home() / ".local" / "bin" / "tv-bridge"
PORT = 8766
NSD_TYPE = "_mibox-claude._tcp"

# A permission prompt waits this long for the TV before the terminal prompt takes over.
DECISION_WAIT_S = 120
# The hook's own timeout must be longer than the wait (§8.3).
DECISION_HOOK_TIMEOUT_S = DECISION_WAIT_S + 30
# Fire-and-forget events must not slow Claude down.
EVENT_TIMEOUT_S = 1.5
# The notch is on this Mac; if it doesn't accept a connection within this, it isn't there.
NOTCH_CONNECT_TIMEOUT_S = 1.0
# After a failed call, skip the TV for this long instead of timing out on every tool call.
# (The notch is never backed off: a refused connection is instant and the app may relaunch any moment.)
DOWN_BACKOFF_S = 60

MARK = "tv_bridge.py hook"


# —— Config and per-session state ——

def load_config():
    try:
        return json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        return None


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.chmod(0o600)
    tmp.replace(path)


def state_path(session):
    return STATE / (re.sub(r"[^A-Za-z0-9_.-]", "_", session or "default") + ".json")


def load_state(session):
    try:
        return json.loads(state_path(session).read_text())
    except (OSError, ValueError):
        return {"tasks": [], "pending": None}


def mac_name():
    try:
        return subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True, timeout=2).stdout.strip() or socket.gethostname()
    except (OSError, subprocess.SubprocessError):
        return socket.gethostname()


# —— TV client ——

class TvDown(Exception):
    pass


class Tv:
    def __init__(self, config):
        self.config = config
        self.base = f"http://{config['host']}:{config.get('port', PORT)}/claude"

    def call(self, method, path, body=None, timeout=EVENT_TIMEOUT_S):
        if self.base is None:
            return None
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"Bearer {self.config['token']}")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise TvDown("the TV no longer knows this Mac; pair again") from e
            raise TvDown(f"HTTP {e.code}") from e
        except (OSError, ValueError) as e:
            raise TvDown(str(e)) from e

    def event(self, **fields):
        fields.setdefault("mac", self.config.get("name"))
        self.call("POST", "/event", fields)


class Silent:
    """Stands in for the TV when it isn't usable: events and snapshots go nowhere."""

    def event(self, **fields):
        pass

    def call(self, *args, **kwargs):
        return {}


class Target:
    """Somewhere a decision can be shown and answered. Subclasses: TvTarget, NotchTarget."""

    name = ""
    approvals_off = False

    def down_marker(self):
        return STATE / f"{self.name}.down"

    def available(self):
        try:
            return time.time() - self.down_marker().stat().st_mtime >= DOWN_BACKOFF_S
        except OSError:
            return True

    def mark_down(self):
        try:
            STATE.mkdir(parents=True, exist_ok=True)
            self.down_marker().touch()
        except OSError:
            pass

    def post_decision(self, payload):
        raise NotImplementedError

    def poll(self, decision_id, wait):
        raise NotImplementedError

    def delete(self, decision_id):
        raise NotImplementedError

    def event(self, **fields):
        pass


class TvTarget(Target):
    name = "tv"

    def __init__(self, config):
        self.tv = Tv(config)

    @classmethod
    def paired(cls):
        config = load_config()
        return cls(config) if config and config.get("token") else None

    def available(self):
        config = self.tv.config
        if time.time() < config.get("downUntil", 0):  # legacy marker from before multi-target
            return False
        return super().available()

    def post_decision(self, payload):
        body = {k: payload.get(k) for k in ("session", "question", "command", "explain", "step")}
        try:
            d = self.tv.call("POST", "/decision", body)
        except TvDown:
            self.mark_down()
            return None
        self.approvals_off = bool(d.get("approvalsOff"))
        return d.get("id")

    def poll(self, decision_id, wait):
        try:
            return self.tv.call("GET", f"/decision/{decision_id}?wait={wait}", timeout=wait + 10)
        except TvDown:
            self.mark_down()
            return None

    def delete(self, decision_id):
        try:
            self.tv.call("DELETE", f"/decision/{decision_id}")
        except (TvDown, AttributeError):
            pass

    def event(self, **fields):
        self.tv.event(**fields)


class NotchTarget(Target):
    """The Boring Notch app: a localhost HTTP server whose port and token are in a bridge file."""

    name = "notch"

    def __init__(self):
        self.base, self.token = None, None
        try:
            info = json.loads(NOTCH_BRIDGE.read_text())
            self.base, self.token = f"http://127.0.0.1:{int(info['port'])}", str(info["token"])
        except (OSError, ValueError, KeyError, TypeError):
            pass

    def available(self):
        return self.base is not None

    def mark_down(self):
        pass  # never backed off; see DOWN_BACKOFF_S

    def request(self, method, path, body=None, timeout=EVENT_TIMEOUT_S):
        """(status, json) or None if the app can't be reached. HTTP errors come back as a status."""
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read() or b"{}")
            except ValueError:
                return e.code, {}
        except (OSError, ValueError):
            return None

    def post_decision(self, payload):
        keys = ("session", "kind", "project", "question", "command", "explain", "questions")
        res = self.request("POST", "/decision", {k: payload[k] for k in keys if payload.get(k) is not None},
                           timeout=NOTCH_CONNECT_TIMEOUT_S + 0.5)
        return res[1].get("id") if res and res[0] == 201 else None

    def poll(self, decision_id, wait):
        res = self.request("GET", f"/decision/{decision_id}?wait={wait}", timeout=wait + 10)
        if res is None:
            return None
        return {"status": "gone"} if res[0] == 404 else res[1]

    def delete(self, decision_id):
        self.request("DELETE", f"/decision/{decision_id}")


def valid_answers(payload, answer):
    """An answer counts only for a question, with a non-empty dict of string -> string."""
    answers = answer.get("answers")
    return (payload.get("kind") == "question" and isinstance(answers, dict) and bool(answers)
            and all(isinstance(k, str) and isinstance(v, str) for k, v in answers.items()))


def race(targets, payload, deadline, ids=None):
    """Post the decision to every available target and poll them all; return the first real answer
    ({"status": "allow" | "deny" | "answer", "target": name, ...}) or None. The decision is deleted on every
    other target. `ids` (name -> id) is filled in and ends up holding only decisions left standing."""
    ids = {} if ids is None else ids
    live = []
    for t in targets:
        if not t.available():
            continue
        try:
            decision_id = t.post_decision(payload)
        except Exception:  # noqa: BLE001 — a failing target drops out; the others continue
            continue
        if decision_id and isinstance(decision_id, str):
            ids[t.name] = decision_id
            if not t.approvals_off:  # "answer on the Mac": the card stays up, the TV leaves the race
                live.append(t)
    result, lock, done = [], threading.Lock(), threading.Event()
    remaining = [len(live)]

    def watch(t):
        try:
            while not result and not done.is_set():
                left = deadline - time.time()
                if left <= 0:
                    break
                answer = t.poll(ids[t.name], max(1, min(55, int(left))))
                status = answer.get("status") if isinstance(answer, dict) else None
                if status == "answer" and not valid_answers(payload, answer):
                    break  # never turn a malformed or misplaced answer into an allow
                if status in ("allow", "deny", "answer"):
                    with lock:
                        if not result:
                            result.append({**answer, "target": t.name})
                    break
                if status != "pending":
                    break  # withdrawn, gone, or unreachable: this target leaves the race
        except Exception:  # noqa: BLE001 — a failing target must not stop the others
            pass
        finally:
            with lock:
                remaining[0] -= 1
                if remaining[0] == 0 or result:
                    done.set()

    for t in live:
        threading.Thread(target=watch, args=(t,), daemon=True).start()
    if live:
        done.wait(max(0, deadline - time.time()))
    done.set()

    winner = result[0] if result else None
    for t in targets:
        if t.name not in ids:
            continue
        if winner and t.name == winner["target"]:
            del ids[t.name]
        elif winner or t in live:
            try:
                t.delete(ids.pop(t.name))
            except Exception:  # noqa: BLE001
                pass
    return winner


# —— Hook handling (§8.3) ——

def first_line(text, limit=90):
    line = next((l.strip() for l in (text or "").splitlines() if l.strip()), "")
    line = re.sub(r"[*_`#>]+", "", line).strip()
    return line if len(line) <= limit else line[: limit - 1].rstrip() + "…"


def short_path(p):
    return pathlib.Path(p).name if p else ""


def action_text(tool, tin):
    """A short human line for the card ("Editing MainActivity.kt")."""
    if tool in ("Edit", "MultiEdit", "NotebookEdit"):
        return f"Editing {short_path(tin.get('file_path') or tin.get('notebook_path'))}"
    if tool == "Write":
        return f"Writing {short_path(tin.get('file_path'))}"
    if tool == "Read":
        return f"Reading {short_path(tin.get('file_path'))}"
    if tool == "Bash":
        return first_line(tin.get("description"), 70) or f"Running {first_line(tin.get('command'), 60)}"
    if tool in ("Grep", "Glob"):
        return f"Searching for {first_line(tin.get('pattern'), 50)}"
    if tool in ("WebFetch", "WebSearch"):
        return "Looking something up online"
    if tool in ("Agent", "Task"):
        return first_line(tin.get("description"), 70) or "Working with a helper agent"
    return None


def progress_from(state):
    tasks = state["tasks"]
    current = next((t["title"] for t in tasks if t["status"] == "in_progress"), None)
    return dict(
        done=sum(t["status"] == "completed" for t in tasks),
        total=len(tasks),
        current=current,
        steps=[{"title": t["title"], "status": t["status"]} for t in tasks],
    )


def update_tasks(state, tool, tin):
    """Track the task list from TodoWrite (older Claude Code) or TaskUpdate (newer). True if it changed."""
    if tool == "TodoWrite" and isinstance(tin.get("todos"), list):
        state["tasks"] = [
            {"id": str(i), "title": t.get("content") or t.get("activeForm") or "", "status": t.get("status", "pending")}
            for i, t in enumerate(tin["todos"])
        ]
        return True
    if tool == "TaskUpdate":
        task = next((t for t in state["tasks"] if t["id"] == str(tin.get("taskId"))), None)
        if task is None:
            return False
        if tin.get("status") == "deleted":
            state["tasks"].remove(task)
        else:
            task["status"] = tin.get("status") or task["status"]
            task["title"] = tin.get("subject") or task["title"]
        return True
    return False


def snapshot_target(command):
    """A PNG a command wrote, e.g. `adb exec-out screencap -p > shot.png`."""
    m = re.search(r">\s*([^\s|;&]+\.png)\b", command or "")
    return m.group(1) if m and "screencap" in command else None


def cancel_pending(targets, state):
    """A decision the terminal answered: every target drops its card (the TV shows "Answered on Mac", §8.4)."""
    pending = state.get("pending")
    if isinstance(pending, str):  # state written before multi-target
        pending = {"tv": pending}
    if isinstance(pending, dict):
        for t in targets:
            try:
                if pending.get(t.name) and t.available():
                    t.delete(pending[t.name])
            except Exception:  # noqa: BLE001 — cleanup must never break the hook
                pass
    state["pending"] = None


def decision_question(tool, tin):
    if tool == "Bash":
        cmd = tin.get("command", "")
        return f"Allow running {first_line(cmd, 48)}?", cmd, tin.get("description")
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        return f"Allow editing {short_path(tin.get('file_path') or tin.get('notebook_path'))}?", None, None
    if tool == "WebFetch":
        return "Allow fetching a web page?", tin.get("url"), None
    return f"Allow {tool}?", None, None


def permission_output(behavior, message=None, updated_input=None):
    decision = {"behavior": behavior}
    if message:
        decision["message"] = message
    if updated_input is not None:
        decision["updatedInput"] = updated_input
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}


def handle_permission(targets, data, state):
    """Ask on every target that can take it. Allow/deny/answer only on a real answer; otherwise print nothing
    → normal terminal prompt."""
    tool, tin = data.get("tool_name", ""), data.get("tool_input") or {}
    project = pathlib.Path(data.get("cwd") or ".").name
    step = progress_from(state)["done"] + 1 if state["tasks"] else None
    if tool == "AskUserQuestion":
        questions = tin.get("questions") or []
        if not questions:
            return None
        payload = dict(kind="question", question=questions[0].get("question") or "Question", questions=questions)
        targets = [t for t in targets if t.name == "notch"]
    else:
        question, command, explain = decision_question(tool, tin)
        payload = dict(kind="permission", question=question, command=command, explain=explain)
    payload.update(session=data.get("session_id"), project=project, step=step)

    ids = {}
    answer = race(targets, payload, time.time() + DECISION_WAIT_S, ids)
    state["pending"] = ids or None  # what's left (e.g. the TV card that says "answer on the Mac")
    if not answer:
        return None
    if answer["status"] == "allow":
        return permission_output("allow")
    if answer["status"] == "answer":
        return permission_output("allow", updated_input={**tin, "answers": answer.get("answers") or {}})
    return permission_output("deny", "Declined on the TV" if answer["target"] == "tv" else "Declined in the notch")


def handle_hook(data):
    event = data.get("hook_event_name")
    session = data.get("session_id")
    tv_target = TvTarget.paired()
    targets = [t for t in (tv_target, NotchTarget()) if t is not None]
    # Progress events and snapshots only go to the TV; without it they go nowhere.
    tv = tv_target.tv if tv_target and tv_target.available() else Silent()
    state = load_state(session)
    out = None
    try:
        if event != "PermissionRequest":
            cancel_pending(targets, state)
        project = pathlib.Path(data.get("cwd") or ".").name

        if event == "UserPromptSubmit":
            state = {"tasks": [], "pending": None}
            tv.event(type="session_start", session=session, project=project, task=first_line(data.get("prompt")) or "Working")
        elif event == "TaskCreated":
            state["tasks"].append({"id": str(data.get("task_id")), "title": data.get("task_subject") or "", "status": "pending"})
            tv.event(type="progress", session=session, **progress_from(state))
        elif event == "TaskCompleted":
            for t in state["tasks"]:
                if t["id"] == str(data.get("task_id")):
                    t["status"] = "completed"
            tv.event(type="progress", session=session, **progress_from(state))
        elif event == "PostToolUse":
            tool, tin = data.get("tool_name", ""), data.get("tool_input") or {}
            if update_tasks(state, tool, tin):
                tv.event(type="progress", session=session, **progress_from(state))
            text = action_text(tool, tin)
            if text:
                tv.event(type="action", session=session, text=text)
            shot = snapshot_target(tin.get("command")) if tool == "Bash" else None
            if shot:
                path = pathlib.Path(data.get("cwd") or ".") / shot
                if path.is_file():
                    send_snapshot(tv, path, f"after {text or 'a command'}", session, progress_from(state)["done"] or None)
        elif event == "PermissionRequest":
            out = handle_permission(targets, data, state)
        elif event == "Notification":
            if data.get("notification_type") == "idle_prompt":
                tv.event(type="action", session=session, text="Waiting for your reply")
        elif event == "Stop":
            p = progress_from(state)
            parts = [f"{p['done']} of {p['total']} steps"] if p["total"] else []
            changed = files_changed(data.get("cwd"))
            if changed:
                parts.append(f"{changed} file{'s' if changed != 1 else ''} changed")
            summary = " · ".join(parts) or first_line(data.get("last_assistant_message"), 70) or "Finished"
            tv.event(type="done", session=session, summary=summary)
        elif event == "SessionEnd":
            tv.event(type="session_end", session=session)
            state_path(session).unlink(missing_ok=True)
            return None
    except TvDown:
        tv_target.mark_down()
        out = None
    save_json(state_path(session), state)
    return out


def files_changed(cwd):
    try:
        r = subprocess.run(["git", "diff", "--name-only", "HEAD"], cwd=cwd or ".", capture_output=True, text=True, timeout=3)
        return len([l for l in r.stdout.splitlines() if l.strip()]) if r.returncode == 0 else 0
    except (OSError, subprocess.SubprocessError):
        return 0


def send_snapshot(tv, path, caption, session=None, step=None):
    image = base64.b64encode(pathlib.Path(path).read_bytes()).decode()
    tv.call("POST", "/snapshot", {"session": session, "step": step, "caption": caption, "image": image}, timeout=20)


# —— Commands ——

def discover(timeout=4.0):
    """Find the TV with Bonjour (`dns-sd` ships with macOS). Returns an IPv4 address or None."""
    def run(args):
        try:
            p = subprocess.Popen(["dns-sd", *args], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            time.sleep(timeout / 2)
            p.terminate()
            return p.communicate(timeout=2)[0]
        except (OSError, subprocess.SubprocessError):
            return ""

    browse = run(["-B", NSD_TYPE, "local."])
    names = [l.split(NSD_TYPE + ".", 1)[1].strip() for l in browse.splitlines() if " Add " in l and NSD_TYPE in l]
    if not names:
        return None
    resolved = run(["-L", names[0], NSD_TYPE, "local."])
    m = re.search(r"can be reached at (\S+?)\.?:(\d+)", resolved)
    if not m:
        return None
    addr = run(["-G", "v4", m.group(1)])
    m2 = re.search(r"\s(\d+\.\d+\.\d+\.\d+)\s", addr)
    return m2.group(1) if m2 else None


def cmd_pair(args):
    host = args.host or discover()
    if not host:
        sys.exit("Couldn't find the TV on the network. Pass its address: tv-bridge pair <code> --host 192.168.x.x")
    name = mac_name()
    body = json.dumps({"code": args.code, "name": name}).encode()
    req = urllib.request.Request(f"http://{host}:{PORT}/claude/pair", data=body, method="POST", headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            token = json.loads(r.read())["token"]
    except urllib.error.HTTPError as e:
        sys.exit(f"The TV refused the code (HTTP {e.code}). Check the 6 digits on the TV; a code lasts five minutes.")
    except OSError as e:
        sys.exit(f"Couldn't reach the TV at {host}: {e}")
    save_json(CONFIG, {"host": host, "port": PORT, "token": token, "name": name})
    print(f"Paired with the TV at {host} as “{name}”.")


def notch_status():
    notch = NotchTarget()
    if not notch.available():
        return f"no bridge file at {NOTCH_BRIDGE} (is Boring Notch running with Claude enabled?)"
    res = notch.request("GET", "/decision/none?wait=0", timeout=NOTCH_CONNECT_TIMEOUT_S + 1)
    if res is None:
        return f"not reachable at {notch.base} (stale bridge file?)"
    return "reachable" if res[0] in (200, 404) else f"answered HTTP {res[0]}"


def cmd_status(_args):
    config = load_config()
    if not config:
        print(f"TV · not paired (run: tv-bridge pair <code>)\nNotch · {notch_status()}")
        return
    config.pop("downUntil", None)
    save_json(CONFIG, config)
    (STATE / "tv.down").unlink(missing_ok=True)
    try:
        Tv(config).call("GET", "/decision/none?wait=0", timeout=4)
        result = "reachable"
    except TvDown as e:
        # 404 means the token was accepted and there's simply no such decision.
        result = "reachable" if "HTTP 404" in str(e) else f"not reachable ({e})"
    print(f"TV {config['host']} · this Mac is “{config.get('name')}” · {result}")
    print(f"Notch · {notch_status()}")


def cmd_snapshot(args):
    config = load_config()
    if not config:
        sys.exit("Not paired. Run: tv-bridge pair <code>")
    try:
        send_snapshot(Tv(config), args.image, args.caption or pathlib.Path(args.image).stem)
    except TvDown as e:
        sys.exit(f"Couldn't send: {e}")
    print("Sent.")


def cmd_unpair(_args):
    CONFIG.unlink(missing_ok=True)
    shutil.rmtree(STATE, ignore_errors=True)
    print("Forgot the TV. To remove this Mac on the TV too: Settings › Widgets › Unpair.")


def settings_file(project):
    return (pathlib.Path(project).resolve() / ".claude" / "settings.json") if project else pathlib.Path.home() / ".claude" / "settings.json"


def hook_entries():
    command = f"python3 -I {INSTALLED} hook"
    plain = {"type": "command", "command": command, "timeout": 10}
    return {
        "UserPromptSubmit": [{"hooks": [plain]}],
        "TaskCreated": [{"hooks": [plain]}],
        "TaskCompleted": [{"hooks": [plain]}],
        "PostToolUse": [{"matcher": "*", "hooks": [plain]}],
        "PermissionRequest": [{"matcher": "*", "hooks": [{**plain, "timeout": DECISION_HOOK_TIMEOUT_S}]}],
        "Notification": [{"hooks": [plain]}],
        "Stop": [{"hooks": [plain]}],
        "SessionEnd": [{"hooks": [plain]}],
    }


def strip_ours(hooks):
    """Remove only tv-bridge's handlers; everything else in the file is left as it was."""
    for event in list(hooks):
        groups = []
        for g in hooks[event]:
            kept = [h for h in g.get("hooks", []) if MARK not in h.get("command", "")]
            if kept:
                groups.append({**g, "hooks": kept})
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]


def cmd_install(args):
    HOME.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(__file__, INSTALLED)
    INSTALLED.chmod(0o755)
    BIN.parent.mkdir(parents=True, exist_ok=True)
    if BIN.is_symlink() or not BIN.exists():
        BIN.unlink(missing_ok=True)
        BIN.symlink_to(INSTALLED)

    path = settings_file(args.project)
    settings = json.loads(path.read_text()) if path.exists() else {}
    if path.exists():
        shutil.copyfile(path, path.with_name(path.name + ".before-tv-bridge"))
    hooks = settings.setdefault("hooks", {})
    strip_ours(hooks)
    for event, groups in hook_entries().items():
        hooks.setdefault(event, []).extend(groups)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, indent=2) + "\n")
    print(f"Hooks added to {path} (backup next to it). The command is {BIN}.")


def cmd_uninstall(args):
    path = settings_file(args.project)
    if path.exists():
        settings = json.loads(path.read_text())
        strip_ours(settings.get("hooks", {}))
        if not settings.get("hooks"):
            settings.pop("hooks", None)
        path.write_text(json.dumps(settings, indent=2) + "\n")
        print(f"Hooks removed from {path}.")


def main():
    ap = argparse.ArgumentParser(prog="tv-bridge", description="Claude Code → Mi Box Launcher")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pair"); p.add_argument("code"); p.add_argument("--host")
    p = sub.add_parser("install"); p.add_argument("--project")
    p = sub.add_parser("uninstall"); p.add_argument("--project")
    sub.add_parser("status")
    p = sub.add_parser("snapshot"); p.add_argument("image"); p.add_argument("--caption")
    sub.add_parser("unpair")
    sub.add_parser("hook")
    args = ap.parse_args()

    if args.cmd == "hook":
        try:
            out = handle_hook(json.load(sys.stdin))
            if out:
                print(json.dumps(out))
        except Exception:  # noqa: BLE001 — a hook must never break Claude Code
            pass
        return
    {"pair": cmd_pair, "install": cmd_install, "uninstall": cmd_uninstall, "status": cmd_status,
     "snapshot": cmd_snapshot, "unpair": cmd_unpair}[args.cmd](args)


if __name__ == "__main__":
    main()
