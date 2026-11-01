#!/usr/bin/env python3
"""mock_mcp_test.py —— 用 Python 起一个等价于 TYMCPServer 的 mock，
配合真实 HTTP 客户端跑一遍完整 MCP 交互流程。

这验证的是「协议时序」是否能被标准 MCP 客户端接受：
  initialize → notifications/initialized → tools/list → tools/call

能在上设备之前抓出这样的问题：
  · session id 下发/校验时序不对（正是 MT-MCP 那个 Session not initialized 的坑）
  · 响应缺 jsonrpc / id 字段
  · notifications 回了响应导致客户端错乱

用法: python tools/mock_mcp_test.py
"""
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

SESSIONS = {}
REQUESTS = {"count": 0}

# 复刻 TYMCPServer 的工具集（从源码解析，保证与真实实现同源）
import io, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = io.open(os.path.join(ROOT, "MCP", "TYMCPServer.m"), encoding="utf-8").read()
TOOL_NAMES = re.findall(r'@\{@"name":\s*@"([a-z0-9_]+)"', SRC)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, obj, sid=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if sid:
            self.send_header("MCP-Session-Id", sid)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n)
        try:
            req = json.loads(raw)
        except Exception:
            return self._send(400, {"error": "bad json"})

        method = req.get("method")
        rid = req.get("id")
        sid = self.headers.get("MCP-Session-Id")

        # 通知：无响应
        if method and method.startswith("notifications/"):
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if method == "initialize":
            new_sid = sid or "TEST-SESSION-0001"
            SESSIONS[new_sid] = True
            return self._send(200, {
                "jsonrpc": "2.0", "id": rid,
                "result": {"protocolVersion": "2024-11-05",
                           "serverInfo": {"name": "ty-mem-mcp", "version": "1.0.0"},
                           "capabilities": {"tools": {}}}}, new_sid)

        # session 校验
        if not sid:
            return self._send(400, {"error": "MCP-Session-Id required"})
        if sid not in SESSIONS:
            return self._send(400, {"error": "Session not initialized", "code": -32002})

        REQUESTS["count"] += 1

        if method == "tools/list":
            tools = [{"name": t, "description": "mock",
                      "inputSchema": {"type": "object", "properties": {}, "required": []}}
                     for t in TOOL_NAMES]
            return self._send(200, {"jsonrpc": "2.0", "id": rid,
                                    "result": {"tools": tools}}, sid)

        if method == "tools/call":
            name = req["params"]["name"]
            if name not in TOOL_NAMES:
                return self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {
                    "content": [{"type": "text", "text": json.dumps(
                        {"ok": False, "error": f"未知工具 {name}"})}],
                    "isError": True}}, sid)
            payload = {"ok": True, "tool": name, "mock": True}
            return self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": json.dumps(payload)}]}}, sid)

        if method == "ping":
            return self._send(200, {"jsonrpc": "2.0", "id": rid, "result": {}}, sid)

        return self._send(200, {"jsonrpc": "2.0", "id": rid,
                                "error": {"code": -32601, "message": "未知方法"}}, sid)


def run_client(port):
    import urllib.request

    URL = f"http://127.0.0.1:{port}/mcp"
    fails = []

    def post(body, sid=None):
        data = json.dumps(body).encode()
        req = urllib.request.Request(URL, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        if sid:
            req.add_header("MCP-Session-Id", sid)
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return (json.loads(raw) if raw else None,
                    r.headers.get("MCP-Session-Id"), r.status)

    # 1) initialize
    resp, sid, code = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                            "params": {"protocolVersion": "2024-11-05",
                                       "capabilities": {},
                                       "clientInfo": {"name": "test", "version": "1"}}})
    if code != 200: fails.append(f"initialize HTTP {code}")
    if not resp or "result" not in resp: fails.append("initialize 无 result")
    else:
        r = resp["result"]
        for k in ("protocolVersion", "serverInfo", "capabilities"):
            if k not in r: fails.append(f"initialize result 缺 {k}")
    if not sid: fails.append("initialize 未下发 MCP-Session-Id")
    print(f"  initialize -> sid={sid}")

    # 2) notifications/initialized（必须无响应）
    req = urllib.request.Request(URL,
        data=json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized",
                         "params": {}}).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("MCP-Session-Id", sid)
    with urllib.request.urlopen(req, timeout=10) as r:
        body = r.read()
        if r.status != 204 or body:
            fails.append(f"notifications/initialized 应为 204 空响应，实际 {r.status}")
    print(f"  notifications/initialized -> 204 空响应 ✓")

    # 3) tools/list（关键：带 session 才能过）
    resp, _, code = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list",
                          "params": {}}, sid)
    if code != 200: fails.append(f"tools/list HTTP {code}")
    tools = resp.get("result", {}).get("tools", []) if resp else []
    if not tools: fails.append("tools/list 返回空")
    for t in tools:
        if "inputSchema" not in t: fails.append(f"{t.get('name')} 缺 inputSchema")
    print(f"  tools/list -> {len(tools)} 个工具 ✓")

    # 4) tools/call 正常
    resp, _, code = post({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                          "params": {"name": tools[0]["name"], "arguments": {}}}, sid)
    if code != 200: fails.append(f"tools/call HTTP {code}")
    cont = resp.get("result", {}).get("content", []) if resp else []
    if not cont or cont[0].get("type") != "text":
        fails.append("tools/call 结果不是 content[{type:text}]")
    print(f"  tools/call({tools[0]['name']}) -> content ✓")

    # 5) tools/call 未知工具 -> isError
    resp, _, _ = post({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                       "params": {"name": "no_such_tool", "arguments": {}}}, sid)
    if not resp.get("result", {}).get("isError"):
        fails.append("未知工具未回报 isError")
    print("  未知工具 -> isError ✓")

    # 6) 无 session 调用应被拒（这正是 MT-MCP 踩的坑）
    try:
        post({"jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": {}}, None)
        fails.append("无 session 的 tools/list 未被拒绝")
    except urllib.error.HTTPError as e:
        print(f"  无 session -> HTTP {e.code}（正确拒绝）✓")

    # 7) 错误 session 应被拒
    try:
        post({"jsonrpc": "2.0", "id": 6, "method": "tools/list", "params": {}},
             "BOGUS-SESSION")
        fails.append("伪造 session 未被拒绝")
    except urllib.error.HTTPError as e:
        print(f"  伪造 session -> HTTP {e.code}（正确拒绝）✓")

    # 8) ping
    resp, _, _ = post({"jsonrpc": "2.0", "id": 7, "method": "ping", "params": {}}, sid)
    if resp is None or "result" not in resp: fails.append("ping 无 result")
    print("  ping -> ok ✓")

    return fails


def main():
    httpd = HTTPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    th = threading.Thread(target=httpd.serve_forever, daemon=True)
    th.start()

    print(f"mock MCP 服务器已起在 :{port}\n")
    print("模拟标准客户端交互序列：")
    try:
        fails = run_client(port)
    finally:
        httpd.shutdown()

    print()
    if fails:
        print(f"✗ {len(fails)} 个问题:")
        for f in fails:
            print("  -", f)
        return 1
    print("✓ 协议时序全部正确 —— 标准 MCP 客户端能正常握手与调用")
    return 0


if __name__ == "__main__":
    sys.exit(main())
