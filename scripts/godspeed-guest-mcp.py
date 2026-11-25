"""Connect a local MCP client to Godspeed in an independently logged-in macOS guest.

No host desktop input, unlock, credential storage, or privileged installer is used.
Configure and verify the SSH host alias and guest permissions yourself before use.
"""
import argparse
import json
import os
import re
import select
import subprocess
import time


REMOTE_COMMAND = 'exec "$HOME/.local/bin/godspeed-mcp"'
REQUIRED_TOOLS = {"get_app_state", "query", "batch", "handoff"}
MAX_RESPONSE = 8 * 1024 * 1024


def ssh_command(alias):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", alias):
        raise ValueError("Use an explicit SSH config host alias, not a URL, user@host or option.")
    options = {
        "BatchMode": "yes",
        "StrictHostKeyChecking": "yes",
        "ForwardAgent": "no",
        "ForwardX11": "no",
        "ClearAllForwardings": "yes",
        "RequestTTY": "no",
        "ConnectTimeout": "10",
        "ServerAliveInterval": "15",
        "ServerAliveCountMax": "3",
        "PermitLocalCommand": "no",
        "ControlMaster": "no",
        "ControlPath": "none",
    }
    command = ["/usr/bin/ssh", "-T"]
    for key, value in options.items():
        command.extend(["-o", f"{key}={value}"])
    return command + [alias, REMOTE_COMMAND]


class MCPProbe:
    def __init__(self, process, timeout=20):
        self.process = process
        self.timeout = timeout
        self.buffer = bytearray()
        self.next_id = 1

    def _read_message(self, deadline):
        while True:
            offset = self.buffer.find(b"\n")
            if offset >= 0:
                if offset > MAX_RESPONSE:
                    raise RuntimeError("Guest MCP reply exceeded the size limit.")
                line = bytes(self.buffer[:offset])
                del self.buffer[:offset + 1]
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeError):
                    raise RuntimeError("Guest returned non-MCP output; check the SSH login shell.") from None
                if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
                    raise RuntimeError("Guest returned an invalid JSON-RPC message.")
                return message
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RuntimeError("Guest MCP response timed out.")
            block = os.read(self.process.stdout.fileno(), 65536)
            if not block:
                raise RuntimeError("Guest MCP connection closed.")
            self.buffer.extend(block)
            if len(self.buffer) > MAX_RESPONSE:
                raise RuntimeError("Guest MCP reply exceeded the size limit.")

    def send(self, method, params, notification=False):
        event = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            event["id"] = self.next_id
            self.next_id += 1
        self.process.stdin.write((json.dumps(event) + "\n").encode("utf-8"))
        self.process.stdin.flush()
        if notification:
            return None
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            reply = self._read_message(deadline)
            if "id" not in reply and isinstance(reply.get("method"), str):
                continue
            if reply.get("id") != event["id"] or not isinstance(reply.get("result"), dict):
                raise RuntimeError(f"Invalid or unsuccessful guest MCP reply to {method}.")
            return reply["result"]
        raise RuntimeError("Guest MCP response timed out.")


def check_guest(command, expected_version=None, app=None, window_id=None, timeout=20):
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0) as process:
        try:
            probe = MCPProbe(process, timeout)
            initial = probe.send("initialize", {
                "protocolVersion": "2025-03-26", "capabilities": {},
                "clientInfo": {"name": "godspeed-guest-check", "version": "1"},
            })
            info = initial.get("serverInfo")
            if not isinstance(info, dict) or info.get("name") != "godspeed" or not isinstance(info.get("version"), str):
                raise RuntimeError("The guest did not identify itself as Godspeed.")
            if expected_version is not None and info["version"] != expected_version:
                raise RuntimeError("Guest Godspeed version does not match the requested version.")
            probe.send("notifications/initialized", {}, notification=True)
            listing = probe.send("tools/list", {}).get("tools")
            if not isinstance(listing, list):
                raise RuntimeError("Guest MCP tool list is missing.")
            names = {tool.get("name") for tool in listing if isinstance(tool, dict) and isinstance(tool.get("name"), str)}
            if not REQUIRED_TOOLS.issubset(names):
                raise RuntimeError("Guest MCP is missing required Godspeed tools.")
            if app is not None:
                # This is a read of a specifically supplied window, not an app launch or input action.
                state = probe.send("tools/call", {"name": "get_app_state", "arguments": {
                    "app": app, "window_id": window_id, "include_ax": True, "include_screenshot": False,
                    "include_menu_bar": False, "compact": True,
                }})
                contents = state.get("content")
                if state.get("isError") is not False or not isinstance(contents, list):
                    raise RuntimeError("Guest window probe failed. Check the guest login and permissions.")
                window_line = f"Window ID: {window_id}"
                text = [item.get("text", "") for item in contents if isinstance(item, dict) and item.get("type") == "text"]
                if not any(window_line in item.splitlines() for item in text if isinstance(item, str)):
                    raise RuntimeError("Guest probe did not return the requested window.")
            return {"version": info["version"], "tools": len(names), "window_read": app is not None}
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("guest", help="Previously configured, host-key-verified SSH alias for your macOS guest.")
    parser.add_argument("--check", action="store_true", help="Check MCP reachability without UI actions.")
    parser.add_argument("--version", help="Expected Godspeed version in check mode.")
    parser.add_argument("--probe-app", help="Optional disposable app already open inside the guest.")
    parser.add_argument("--window-id", type=int, help="Previously observed guest Window ID for the read-only probe.")
    args = parser.parse_args()
    if (args.probe_app is None) != (args.window_id is None):
        parser.error("--probe-app and --window-id must be supplied together.")
    if args.window_id is not None and not 0 < args.window_id <= 0xffffffff:
        parser.error("--window-id must be a positive CGWindowID.")
    if not args.check and (args.version is not None or args.probe_app is not None):
        parser.error("--version and window probes require --check.")
    try:
        command = ssh_command(args.guest)
        if not args.check:
            # SSH owns stdio in transport mode; do not consume or rewrite MCP frames.
            os.execv(command[0], command)
        result = check_guest(command, args.version, args.probe_app, args.window_id)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Godspeed guest: {error}\n")
    print(f"Guest Godspeed {result['version']} answered MCP and listed {result['tools']} tools.")
    if result["window_read"]:
        print("Read-only guest window probe passed.")
    print("This check does not establish the physical host lock state or verify input delivery.")


if __name__ == "__main__":
    main()
