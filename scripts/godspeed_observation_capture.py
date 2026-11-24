"""Private, filtered local observations for later Godspeed analysis.

Never store screenshots, raw arguments, clipboard data or editable-field values.
An acknowledgement and a changed observation are not task-success labels.
"""
import collections
import datetime
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import uuid
from pathlib import Path

TOOLS = frozenset({"get_app_state", "query", "click", "batch", "handoff", "browser", "press_key", "press_menu", "set_value", "type_text", "scroll", "select_text", "drag", "wait_for", "open", "list_apps", "perform_secondary_action"})
ROLES = frozenset({"button", "text", "text field", "text area", "secure text field", "toggle button", "check box", "radio button", "menu button", "menu", "menu item", "scroll area", "table", "row", "column", "list", "image", "slider", "pop up button", "standard window", "window", "group", "unknown", "link", "combo box", "tab group"})
_KEYS = sorted(ROLES, key=len, reverse=True)
_NODE = re.compile(r"^(\s*)\d+\s+(.*)$")
_EDITABLE = re.compile(r"^(?:secure\s+)?(?:text field|text area|search field|combo box|editable text)\b", re.I)
_SECURE = re.compile(r"\b(password|passcode|wachtwoord|secure text|one.time.code|verification code|otp)\b", re.I)
_SECRET = re.compile(r"(?i)(?:\b(?:sk-|ghp_|github_pat_|xox[baprs]-)[a-z0-9_\-]{8,}|\b(?:bearer\s+)[a-z0-9._\-]+|\b(?:api[_ -]?key|access[_ -]?token|password|passcode)\s*[:=]\s*\S+)")


class ObservationCapture:
    def __init__(self, directory=None, max_bytes=20 * 1024 * 1024, directory_max_bytes=2 * 1024 * 1024 * 1024):
        self.directory = Path(directory or (Path.home() / ".godspeed" / "observations"))
        self.session = str(uuid.uuid4())
        self.key = secrets.token_bytes(32)
        self.max_bytes = max_bytes
        self.directory_max_bytes = directory_max_bytes
        self.sequence = 0
        self.states = {}
        self.actions = {}
        self.content_suspended = False
        self.directory_full = False
        self.lock = threading.Lock()

    def digest(self, text):
        return hmac.new(self.key, str(text).encode("utf-8", "replace"), hashlib.sha256).hexdigest()[:24]

    @staticmethod
    def state_text(response):
        result = response.get("result")
        if not isinstance(result, dict):
            return None
        for item in result.get("content", []):
            if isinstance(item, dict) and item.get("type") == "text":
                value = item.get("text")
                if isinstance(value, str) and value.startswith("App=") and "\nWindow:" in value[:1000]:
                    return value
        return None

    @staticmethod
    def roles(text):
        counts = collections.Counter()
        for line in text.splitlines():
            line = re.sub(r"^\s*\d+\s+", "", line, count=1).lower()
            for role in _KEYS:
                if line == role or line.startswith(role + " ") or line.startswith(role + ","):
                    counts[role.replace(" ", "_")] += 1
                    break
        return dict(sorted(counts.items()))

    def remember_inputs(self, tool, args):
        """Stop content recording after input so later echoes are not retained."""
        if tool == "clipboard":
            self.content_suspended = True
        if tool == "press_key" and isinstance(args.get("key"), str):
            key = args["key"].lower()
            if len(key) == 1 or key in {"cmd+v", "ctrl+v"}:
                self.content_suspended = True
        if tool == "browser" and args.get("action") in {"paste", "type", "fill_field", "key"}:
            if args.get("action") == "paste":
                self.content_suspended = True
            if args.get("action") == "key" and isinstance(args.get("key"), str):
                key = args["key"].lower()
                if len(key) == 1 or key in {"cmd+v", "ctrl+v"}:
                    self.content_suspended = True
            self._remember(args.get("text"))
        if tool == "type_text":
            self._remember(args.get("text"))
        if tool == "set_value":
            self._remember(args.get("value"))
        if tool in {"batch", "handoff", "fill"}:
            for value in (args.get("values"), args.get("fields")):
                if isinstance(value, dict):
                    for item in value.values(): self._remember(item)
            for step in args.get("steps", []):
                if isinstance(step, dict): self.remember_inputs(step.get("tool", ""), step)

    def _remember(self, value):
        if isinstance(value, str) and value:
            # Echoes can be transformed, split across controls, or later sent as messages.
            # Stop recording text for this connection after any supplied input.
            self.content_suspended = True

    def filtered_state(self, state):
        # Secure windows may have values in unexpected descendants: omit all content.
        if self.content_suspended or _SECURE.search(state):
            return None
        output = []
        skipped_indent = None
        for line in state.splitlines():
            match = _NODE.match(line)
            if match:
                indent = len(match.group(1).expandtabs(4))
                if skipped_indent is not None and indent > skipped_indent:
                    continue
                skipped_indent = None
                if _EDITABLE.match(match.group(2)):
                    output.append(match.group(1) + "editable field [redacted]")
                    skipped_indent = indent
                    continue
            elif skipped_indent is not None and (line.startswith(" ") or line.startswith("\t")):
                continue
            if "focused ui element" in line.lower() and re.search(r"(?:secure\s+)?(?:text field|text area|search field|combo box|editable text)\b", line, re.I):
                output.append("Focused editable field [redacted]")
            else:
                output.append(line)
        text = "\n".join(output)
        return _SECRET.sub("[sensitive value redacted]", text)[:16000]

    def safe_label(self, value):
        if not isinstance(value, str) or self.content_suspended or _SECURE.search(value):
            return None
        return _SECRET.sub("[sensitive value redacted]", value)[:200]

    def record(self, tool, args, response, duration_ms):
        try:
            self._record(tool, args, response, duration_ms)
        except Exception:
            # Recording must never change or delay an action's outcome.
            return False
        return True

    def _record(self, tool, args, response, duration_ms):
        args = args if isinstance(args, dict) else {}
        response = response if isinstance(response, dict) else {}
        original_tool = tool
        tool = tool if tool in TOOLS else "other"
        app = args.get("app") if isinstance(args.get("app"), str) else None
        app_key = self.digest(app.lower()) if app else None
        result = response.get("result") if isinstance(response.get("result"), dict) else {}
        error = bool(response.get("error") or result.get("isError"))
        with self.lock:
            self.remember_inputs(original_tool, args)
            self.sequence += 1
            row = {"schema": 1, "session": self.session, "sequence": self.sequence,
                   "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds"),
                   "tool": tool, "app_session_key": app_key,
                   "duration_ms": max(0, round(duration_ms, 1)),
                   "response": "error" if error else "acknowledged",
                   "task_verification": "not_checked", "content_mode": "filtered_visible_text"}
            if tool in {"click", "query", "set_value", "select_text", "scroll", "perform_secondary_action"}:
                row["target_method"] = next((key for key in ("ref", "label", "element_index", "x") if key in args), "unspecified")
                if isinstance(args.get("label"), str):
                    row["target_session_key"] = self.digest(args["label"])
                    if tool == "click":
                        label = self.safe_label(args["label"])
                        if label is not None: row["target_label"] = label
            if tool in {"batch", "handoff"}:
                row["step_count"] = len(args.get("steps", [])) if isinstance(args.get("steps"), list) else 0
                row["check_requested"] = bool(args.get("done_when"))
                if tool == "batch" and isinstance(args.get("steps"), list):
                    steps = []
                    for step in args["steps"][:100]:
                        if not isinstance(step, dict): continue
                        value = step.get("tool")
                        action = value if isinstance(value, str) and value in TOOLS else "other"
                        summary = {"tool": action, "execution": "unknown"}
                        if action == "click":
                            label = self.safe_label(step.get("label"))
                            if label is not None: summary["target_label"] = label
                        steps.append(summary)
                    row["requested_steps"] = steps
            if tool in {"click", "set_value", "type_text", "press_key", "press_menu", "scroll", "select_text", "drag", "batch", "handoff", "perform_secondary_action"} and app_key:
                row["prior_observation"] = self.states.get(app_key, {}).get("sequence")
                self.actions[app_key] = {"sequence": self.sequence, "state": self.states.get(app_key, {}).get("digest")}
            state = self.state_text(response) if tool == "get_app_state" and not error else None
            if state is not None and app_key:
                digest = self.digest(state)
                row["roles"] = self.roles(state)
                filtered = self.filtered_state(state)
                if filtered is not None:
                    row["visible_state"] = filtered
                else:
                    row["content_omitted"] = True
                action = self.actions.pop(app_key, None)
                if action:
                    row["after_action"] = action["sequence"]
                    row["view_changed"] = None if action["state"] is None else digest != action["state"]
                self.states[app_key] = {"sequence": self.sequence, "digest": digest}
            self._append(row)

    def _append(self, row):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.directory.is_symlink():
            raise OSError("observation directory is a symlink")
        os.chmod(self.directory, 0o700)
        if self.directory_full:
            raise OSError("observation directory full; existing records preserved")
        if self.sequence == 1 or self.sequence % 128 == 0:
            total = sum(p.stat().st_size for p in self.directory.glob("*.jsonl") if p.is_file() and not p.is_symlink())
            if total >= self.directory_max_bytes:
                self.directory_full = True
                raise OSError("observation directory full; existing records preserved")
        path = self.directory / (self.session + ".jsonl")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.fchmod(fd, 0o600)
            data = (json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n").encode()
            if os.fstat(fd).st_size + len(data) > self.max_bytes:
                raise OSError("observation session full; existing records preserved")
            offset = 0
            while offset < len(data):
                written = os.write(fd, data[offset:])
                if written <= 0:
                    raise OSError("incomplete observation write")
                offset += written
        finally:
            os.close(fd)
