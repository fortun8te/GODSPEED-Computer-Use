"""Exercise an installed Godspeed launcher without issuing a desktop action."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launcher", type=Path, default=Path.home() / ".local/bin/godspeed-mcp")
    parser.add_argument("--version", help="Expected MCP version (default: this checkout's VERSION).")
    parser.add_argument("--direct", action="store_true", help="Use standalone stdio for an isolated checkout or CI.")
    args = parser.parse_args()
    if args.version is None:
        version_file = Path(__file__).resolve().parents[2] / "VERSION"
        if not version_file.is_file():
            parser.error("--version is required outside the Godspeed checkout")
        args.version = version_file.read_text(encoding="utf-8").strip()
    environment = os.environ.copy()
    if args.direct:
        environment["OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY"] = "1"
    with subprocess.Popen([str(args.launcher)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          text=True, encoding="utf-8", env=environment) as proc:
        try:
            def send(method, params, ident=None):
                event = {"jsonrpc": "2.0", "method": method, "params": params}
                if ident is not None:
                    event["id"] = ident
                proc.stdin.write(json.dumps(event) + "\n")
                proc.stdin.flush()
                if ident is None:
                    return None
                if not select.select([proc.stdout], [], [], 15)[0]:
                    raise RuntimeError(f"No response to {method}")
                line = proc.stdout.readline()
                if not line:
                    raise RuntimeError(f"Connection closed during {method}")
                response = json.loads(line)
                if response.get("id") != ident or "result" not in response:
                    raise RuntimeError(f"Invalid response to {method}")
                return response["result"]

            initial = send("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                          "clientInfo": {"name": "install-check", "version": "1"}}, 1)
            assert initial["serverInfo"] == {"name": "godspeed", "version": args.version}, initial["serverInfo"]
            send("notifications/initialized", {})
            tools = {tool["name"] for tool in send("tools/list", {}, 2)["tools"]}
            assert {"batch", "get_app_state", "query", "handoff"}.issubset(tools), tools
            print(f"Godspeed {args.version} answered initialize and listed {len(tools)} MCP tools.")
        finally:
            proc.stdin.close()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.terminate()
                proc.wait(timeout=3)


if __name__ == "__main__":
    main()
