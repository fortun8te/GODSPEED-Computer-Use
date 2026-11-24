"""Loopback opt-in Godspeed helper using the three merged Mac checkpoints."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import threading
import time

HOME = Path.home() / ".ocu-referee"
ROOT = HOME / "candidates/gsd1-pilots"
ROLES = ("action", "read", "recover")
MAX_BYTES = 64 * 1024


def load_stock_service():
    spec = importlib.util.spec_from_file_location("godspeed_stock", HOME / "server_mlx.py")
    stock = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(HOME))
    spec.loader.exec_module(stock)
    return stock


def validate(body):
    if not isinstance(body, dict) or body.get("role") not in ROLES:
        raise ValueError("role must be action, read, or recover")
    state, question = body.get("state"), body.get("question")
    if not isinstance(state, (str, dict)) or not isinstance(question, dict) or question.get("type") != "choice":
        raise ValueError("Expected a state and a typed choice question")
    options = question.get("criteria")
    instructions = question.get("instructions")
    if (not isinstance(instructions, str) or not isinstance(options, dict) or not 2 <= len(options) <= 15
            or any(not key or not isinstance(value, str) or not value for key, value in options.items())):
        raise ValueError("Expected 2 to 15 named text options")
    return body["role"], state, {"type": "choice", "instructions": instructions, "criteria": options}


def serve():
    stock = load_stock_service()
    if stock.PORT == 8765:
        raise SystemExit("Set OCU_REFEREE_PORT to an unused loopback port for the GSD1 candidate.")
    typed_only = os.environ.get("GSD1_TYPED_ONLY") == "1"
    choose_tuned = not typed_only and os.environ.get("GSD1_CHOOSE_MODEL") == "action"
    load = stock.get
    resident = None

    def get(name):
        nonlocal resident
        if name == "d1" and choose_tuned and getattr(request_role, "action", False):
            name = "action"
        if name not in ROLES:
            return load(name)
        if name != resident:
            if resident is not None:
                stock.models.pop(resident, None)
                stock.last_used.pop(resident, None)
                stock.clear_cache()
            resident = name
        if name not in stock.models:
            stock.models[name] = stock.load(str(ROOT / name))
        stock.last_used[name] = time.time()
        stock.IDLE_BY_MODEL.setdefault(name, stock.IDLE_BY_MODEL["d1"])
        return stock.models[name]

    request_role = threading.local()
    stock.get = get

    class Handler(stock.Handler):
        def do_GET(self):
            if not typed_only:
                return super().do_GET()
            if self.path != "/health":
                return self.reply(404, {"error": "not found"})
            return self.reply(200, {"ok": True, "runtime": "mlx", "loaded": sorted(stock.models),
                                    "roles": list(ROLES), "max_resident": 1, "typed_only": True})

        def do_POST(self):
            if self.path != "/gsd1/score":
                if typed_only:
                    return self.reply(404, {"error": "not found"})
                request_role.action = self.path == "/choose"
                try:
                    return super().do_POST()
                finally:
                    request_role.action = False
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BYTES:
                    return self.reply(400, {"error": "invalid body length"})
                role, state, question = validate(json.loads(self.rfile.read(length)))
            except (TypeError, ValueError):
                return self.reply(400, {"error": "invalid typed decision request"})
            if not stock.lock.acquire(blocking=False):
                return self.reply(503, {"error": "local inference busy"})
            try:
                model, _ = get(role)
                start = time.perf_counter()
                probs = model.system_one(state, {"decision": question})["answers"]["decision"]["probabilities"]
                result = {"model": "gsd1-" + role, "probs": probs, "ms": (time.perf_counter()-start)*1000}
            except Exception as error:
                return self.reply(500, {"error": str(error)[:200]})
            finally:
                stock.lock.release()
            return self.reply(200, result)

    threading.Thread(target=stock.janitor, daemon=True).start()
    stock.ThreadingHTTPServer(("127.0.0.1", stock.PORT), Handler).serve_forever()


if __name__ == "__main__":
    serve()
