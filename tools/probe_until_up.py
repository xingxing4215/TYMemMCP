#!/usr/bin/env python3
"""probe_until_up.py —— 持续探测 MCP 端口，直到它活过来

用途：iOS 把后台 app 挂起时，socket 仍绑着但不响应（表现为连接超时）。
本脚本持续轮询，一旦游戏切到前台、进程被唤醒，就立刻报出结果，
省得反复手敲 curl 猜时机。

用法:
  python tools/probe_until_up.py [IP] [PORT] [超时秒数]

  python tools/probe_until_up.py                    # 默认 192.168.31.139:27019
  python tools/probe_until_up.py 192.168.31.139 27019 300
"""
import json
import socket
import sys
import time
import urllib.request


def probe(host, port, timeout=3.0):
    """返回 (状态, 详细)。状态: up / refused / timeout / error"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        return "up", ""
    except ConnectionRefusedError:
        return "refused", "端口无监听"
    except socket.timeout:
        return "timeout", "无响应（进程可能被挂起）"
    except Exception as e:
        return "error", f"{type(e).__name__}: {e}"
    finally:
        s.close()


def health(host, port):
    try:
        with urllib.request.urlopen(
                f"http://{host}:{port}/health", timeout=5) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except Exception as e:
        return None, str(e)


def mcp_info(host, port):
    """跑一遍 initialize，确认 MCP 协议层真的可用"""
    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "probe", "version": "1"}},
    }).encode()
    req = urllib.request.Request(f"http://{host}:{port}/mcp", data=body,
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            sid = r.headers.get("MCP-Session-Id")
            data = json.loads(r.read() or b"{}")
            return sid, data
    except Exception as e:
        return None, {"error": str(e)}


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.31.139"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 27019
    budget = int(sys.argv[3]) if len(sys.argv) > 3 else 180

    print(f"探测 {host}:{port}，最长等 {budget}s")
    print("（把游戏切到前台，脚本会自动抓到它醒来的那一刻）")
    print()

    t0 = time.time()
    last = None
    try:
        while time.time() - t0 < budget:
            st, detail = probe(host, port)
            elapsed = time.time() - t0
            if st != last:
                if st == "up":
                    print(f"  [{elapsed:5.1f}s] ✓ 端口已开放")
                elif st == "refused":
                    print(f"  [{elapsed:5.1f}s] ✗ 拒绝 —— {detail}")
                    print(f"           dylib 没加载，或服务器没起来")
                elif st == "timeout":
                    print(f"  [{elapsed:5.1f}s] … 超时 —— {detail}")
                else:
                    print(f"  [{elapsed:5.1f}s] ? {detail}")
                last = st

            if st == "up":
                time.sleep(0.3)
                code, body = health(host, port)
                print()
                print(f"  /health → HTTP {code}")
                if body:
                    print(f"  {body[:400]}")
                print()
                sid, data = mcp_info(host, port)
                if sid:
                    print(f"  MCP initialize → session={sid}")
                    res = data.get("result", {})
                    si = res.get("serverInfo", {})
                    print(f"    serverInfo: {si.get('name')} v{si.get('version')}")
                    print(f"    protocolVersion: {res.get('protocolVersion')}")
                    print()
                    print("✓ MCP 服务完全可用")
                else:
                    print(f"  MCP initialize 失败: {data}")
                return 0

            # 超时时不必频繁重试，省得日志刷屏
            time.sleep(2 if st == "timeout" else 1)

    except KeyboardInterrupt:
        print("\n已中断")
        return 130

    print()
    print(f"✗ {budget}s 内未恢复")
    print("  · 若一直「拒绝」：dylib 未加载，重装并检查 tymcp.boot")
    print("  · 若一直「超时」：进程被挂起，确认游戏在前台且未被系统杀后台")
    return 1


if __name__ == "__main__":
    sys.exit(main())
