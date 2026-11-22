"""Standalone loopback runtime for the optional Godspeed decision adapters."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time

ROLES = ("action", "read", "recover")


class Scorer:
    """One shared resident checkpoint across every local connection."""

    def __init__(self, models, load, clear, idle=180):
        self.models = models
        self.load = load
        self.clear = clear
        self.idle = idle
        self.lock = threading.Lock()
        self.model = None
        self.role = None
        self.last_use = 0

    def unload(self):
        self.model = None
        self.role = None
        self.clear()

    def score(self, role, state, question):
        if self.role != role:
            self.unload()
            self.model, _ = self.load(str(self.models / role))
            self.role = role
        started = time.monotonic()
        try:
            probs = self.model.system_one(state, {"decision": question})["answers"]["decision"]["probabilities"]
            return {"model": f"gsd1-{role}", "probs": probs, "ms": (time.monotonic() - started) * 1000}
        finally:
            self.last_use = time.monotonic()

    def unload_if_idle(self):
        with self.lock:
            if self.model is not None and time.monotonic() - self.last_use >= self.idle:
                self.unload()


def request(body):
    if not isinstance(body, dict) or body.get("role") not in ROLES:
        raise ValueError("invalid role")
    state, question = body.get("state"), body.get("question")
    if not isinstance(state, (str, dict)) or not isinstance(question, dict) or question.get("type") != "choice":
        raise ValueError("expected state and choice question")
    options, instructions = question.get("criteria"), question.get("instructions")
    if (not isinstance(instructions, str) or not instructions or not isinstance(options, dict)
            or not 2 <= len(options) <= 15
            or any(not key or not isinstance(value, str) or not value for key, value in options.items())):
        raise ValueError("expected instructions and 2 to 15 named options")
    return body["role"], state, {"type": "choice", "instructions": instructions, "criteria": options}


def handler(scorer):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body):
            raw = json.dumps(body).encode()
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            if self.path != "/health":
                return self.reply(404, {"error": "not found"})
            role = scorer.role
            self.reply(200, {"ok": True, "typed_only": True, "max_resident": 1,
                             "loaded": [role] if role else []})

        def do_POST(self):
            if self.path != "/gsd1/score":
                return self.reply(404, {"error": "not found"})
            try:
                length = int(self.headers.get("Content-Length", 0))
                if not 0 < length <= 64 * 1024:
                    raise ValueError("invalid length")
                role, state, question = request(json.loads(self.rfile.read(length)))
            except (TypeError, ValueError):
                return self.reply(400, {"error": "invalid typed decision request"})
            if not scorer.lock.acquire(blocking=False):
                return self.reply(503, {"error": "local inference busy"})
            try:
                reply = scorer.score(role, state, question)
            except Exception:
                return self.reply(500, {"error": "could not score the local checkpoint"})
            finally:
                scorer.lock.release()
            self.reply(200, reply)
    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("models", type=Path)
    p.add_argument("--port", type=int, default=18765)
    args = p.parse_args()
    import mlx.core as mx
    from mlx_vlm import load
    scorer = Scorer(args.models, load, mx.clear_cache)

    def janitor():
        while True:
            time.sleep(5)
            scorer.unload_if_idle()

    with ThreadingHTTPServer(("127.0.0.1", args.port), handler(scorer)) as server:
        threading.Thread(target=janitor, daemon=True).start()
        server.serve_forever()


if __name__ == "__main__":
    main()
