#!/usr/bin/env python3
"""Self-test the MCP protocol layer of macMCP end-to-end (shim ⇄ agent over the unix socket).

Starts a fresh agent, pipes JSON-RPC at the shim binary, and checks the responses. Exercises
initialize, tools/list, tools/call dispatch, arg validation, unknown-tool errors, and ping.
Only default-tier tools are touched (those need no TCC grant), so it runs headless in CI.
"""
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHIM = os.path.join(ROOT, ".build/debug/macmcp")
AGENT = os.path.join(ROOT, ".build/debug/macmcp-agent")
SOCK = os.path.expanduser("~/Library/Application Support/macMCP/agent.sock")

DEFAULT_TIER_TOOLS = {
    "mac_list_apps", "mac_app_info", "mac_list_windows", "mac_permissions", "mac_network_status",
}
FULL_TIER_TOOLS = {"mac_screenshot", "mac_read_ui", "mac_find_element"}
INPUT_TIER_TOOLS = {"mac_click", "mac_type", "mac_scroll", "mac_key", "mac_computer"}
NETWORK_TIER_TOOLS = {"mac_read_network"}
ALL_TOOLS = DEFAULT_TIER_TOOLS | FULL_TIER_TOOLS | INPUT_TIER_TOOLS | NETWORK_TIER_TOOLS

REQUESTS = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "selftest", "version": "0"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},   # notification: no reply
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "mac_app_info", "arguments": {}}},        # no target -> isError
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
     "params": {"name": "does_not_exist", "arguments": {}}},      # unknown -> JSON-RPC error
    {"jsonrpc": "2.0", "id": 5, "method": "ping"},
]


def fresh_agent():
    subprocess.run(["pkill", "-f", "macmcp-agent"], capture_output=True)
    try:
        os.remove(SOCK)
    except FileNotFoundError:
        pass
    agent = subprocess.Popen([AGENT], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(80):
        if os.path.exists(SOCK):
            break
        time.sleep(0.05)
    return agent


def main():
    if not (os.path.exists(SHIM) and os.path.exists(AGENT)):
        print("FATAL: build first (swift build). Missing shim or agent binary.")
        sys.exit(2)

    agent = fresh_agent()
    stdin = "".join(json.dumps(r) + "\n" for r in REQUESTS)
    try:
        proc = subprocess.run([SHIM], input=stdin, capture_output=True, text=True, timeout=25)
    finally:
        agent.terminate()
        try:
            agent.wait(timeout=5)
        except subprocess.TimeoutExpired:
            agent.kill()
        subprocess.run(["pkill", "-f", "macmcp-agent"], capture_output=True)

    responses = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)
        responses[o.get("id")] = o

    checks = []

    def check(name, cond, detail=""):
        checks.append((name, cond, detail))

    r1 = responses.get(1, {}).get("result", {})
    check("initialize serverInfo.name == macmcp",
          r1.get("serverInfo", {}).get("name") == "macmcp", str(r1.get("serverInfo")))
    check("initialize echoes protocolVersion",
          r1.get("protocolVersion") == "2025-06-18", str(r1.get("protocolVersion")))
    check("initialize advertises tools capability",
          "tools" in r1.get("capabilities", {}), str(r1.get("capabilities")))

    check("notification produced no spurious response",
          None not in responses or "method" not in responses.get(None, {}), "")

    tools = responses.get(2, {}).get("result", {}).get("tools", [])
    names = {t["name"] for t in tools}
    check(f"tools/list returns all {len(ALL_TOOLS)} tools (default + full tier)",
          names == ALL_TOOLS, str(sorted(names)))
    check("every tool has an object inputSchema",
          all(t.get("inputSchema", {}).get("type") == "object" for t in tools), "")
    check("every tool has a non-empty description",
          all(t.get("description") for t in tools), "")

    r3 = responses.get(3, {}).get("result", {})
    check("missing-target tool call -> isError result",
          r3.get("isError") is True
          and "target app" in r3.get("content", [{}])[0].get("text", ""),
          str(r3))

    e4 = responses.get(4, {}).get("error", {})
    check("unknown tool -> JSON-RPC error -32602",
          e4.get("code") == -32602 and "Unknown tool" in e4.get("message", ""), str(e4))

    check("ping -> empty result object",
          responses.get(5, {}).get("result") == {}, str(responses.get(5)))

    passed = sum(1 for _, c, _ in checks if c)
    for name, cond, detail in checks:
        mark = "PASS" if cond else "FAIL"
        line = f"[{mark}] {name}"
        if not cond and detail:
            line += f"  -- got: {detail}"
        print(line)

    print(f"\n{passed}/{len(checks)} checks passed")
    sys.exit(0 if passed == len(checks) else 1)


if __name__ == "__main__":
    main()
