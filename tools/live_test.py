#!/usr/bin/env python3
"""live_test.py —— 对真机上的 TYMemMCP 跑一遍完整冒烟测试

覆盖：
  · 协议握手（initialize + notifications/initialized）
  · tools/list（21 个工具是否都在）
  · get_info / list_modules / image_lookup
  · read_value / read_memory / list_regions
  · scan（精确搜索）
  · pointer_chain
  · il2cpp_status（验证 dlopen 修正是否生效）

用法:
  python tools/live_test.py [IP] [PORT]
  python tools/live_test.py 192.168.31.139 27019
"""
import json
import sys
import urllib.error
import urllib.request

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.31.139"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 27019
URL = f"http://{HOST}:{PORT}/mcp"

SID = None
RID = [0]
FAILS = []


def post(body, sid=None):
    data = json.dumps(body).encode()
    req = urllib.request.Request(URL, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    if sid:
        req.add_header("MCP-Session-Id", sid)
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return (json.loads(raw) if raw else None,
                r.headers.get("MCP-Session-Id"), r.status)


def notify(method, sid):
    req = urllib.request.Request(
        URL, data=json.dumps({"jsonrpc": "2.0", "method": method,
                              "params": {}}).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("MCP-Session-Id", sid)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            r.read()
    except Exception:
        pass


def call(tool, args=None, timeout=90):
    """调用一个工具，返回解析后的 payload（dict）"""
    RID[0] += 1
    body = {"jsonrpc": "2.0", "id": RID[0], "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}}}
    try:
        data, _, _ = post(body, SID)
    except Exception as e:
        FAILS.append(f"{tool}: 请求失败 {e}")
        return None
    if not data or "result" not in data:
        FAILS.append(f"{tool}: 无 result {str(data)[:200]}")
        return None
    res = data["result"]
    if res.get("isError"):
        FAILS.append(f"{tool}: isError")
    content = res.get("content") or []
    if not content:
        FAILS.append(f"{tool}: content 为空")
        return None
    txt = content[0].get("text", "")
    try:
        return json.loads(txt)
    except Exception:
        return {"_raw": txt}


def main():
    global SID

    print(f"连接到 {URL}\n")

    # ---- 握手 ----
    data, SID, code = post({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "live-test", "version": "1"}}})
    if not SID:
        print("✗ 未拿到 session id")
        return 1
    notify("notifications/initialized", SID)
    si = data.get("result", {}).get("serverInfo", {})
    print(f"✓ 握手成功  {si.get('name')} v{si.get('version')}  sid={SID[:8]}…\n")

    # ---- 工具清单 ----
    RID[0] += 1
    data, _, _ = post({"jsonrpc": "2.0", "id": RID[0],
                       "method": "tools/list", "params": {}}, SID)
    tools = [t["name"] for t in data.get("result", {}).get("tools", [])]
    print(f"✓ tools/list  {len(tools)} 个工具")
    if len(tools) != 21:
        FAILS.append(f"工具数 {len(tools)} != 21")
    print()

    # ---- 1. get_info ----
    print("── get_info ──")
    info = call("get_info")
    if info:
        for k in ("pid", "module_count", "il2cpp_available", "il2cpp_reason",
                  "readable_bytes"):
            if k in info:
                print(f"   {k}: {info[k]}")
    print()

    # ---- 2. list_modules ----
    print("── list_modules ──")
    mods = call("list_modules")
    if mods:
        arr = mods.get("modules") or []
        print(f"   共 {len(arr)} 个模块")
        for m in arr[:8]:
            print(f"     {m.get('name'):28s} base={m.get('base')} size={m.get('size')}")
        if len(arr) > 8:
            print(f"     … 还有 {len(arr)-8} 个")
    print()

    # ---- 3. il2cpp_status（验证 dlopen 修正）----
    print("── il2cpp_status（关键：验证 dlopen 修正）──")
    st = call("il2cpp_status")
    if st:
        print(f"   available: {st.get('available')}")
        if st.get("reason"):
            print(f"   reason   : {st.get('reason')}")
        imgs = st.get("images") or []
        print(f"   镜像数   : {len(imgs)}")
        for im in imgs[:6]:
            print(f"     {im}")
    print()

    # ---- 4. image_lookup ----
    print("── image_lookup ──")
    if mods and mods.get("modules"):
        base = mods["modules"][0].get("base")
        lk = call("image_lookup", {"address": base})
        if lk:
            for k in ("found", "module", "offset", "segment"):
                if k in lk:
                    print(f"   {k}: {lk[k]}")
    print()

    # ---- 5. list_regions ----
    print("── list_regions ──")
    if mods and mods.get("modules"):
        base = int(mods["modules"][0].get("base", "0x0"), 16) \
            if isinstance(mods["modules"][0].get("base"), str) else mods["modules"][0].get("base")
        rg = call("list_regions", {"start": base, "limit": 5})
        if rg:
            arr = rg.get("regions") or []
            print(f"   返回 {len(arr)} 个 region")
            for r in arr[:5]:
                print(f"     {r.get('address')}  {r.get('size'):>10}  {r.get('protection')}  {r.get('module') or ''}")
    print()

    # ---- 6. read_value ----
    print("── read_value ──")
    if mods and mods.get("modules"):
        base = mods["modules"][0].get("base")
        rv = call("read_value", {"address": base, "type": "u32"})
        if rv:
            print(f"   {rv}")
    print()

    # ---- 7. read_memory ----
    print("── read_memory ──")
    if mods and mods.get("modules"):
        base = mods["modules"][0].get("base")
        rm = call("read_memory", {"address": base, "size": 16})
        if rm:
            print(f"   hex   : {rm.get('hex')}")
            print(f"   bytes : {rm.get('bytes_read')}")
    print()

    # ---- 8. scan（在小范围内搜 mach-o magic）----
    print("── scan（搜索 arm64 Mach-O magic）──")
    if mods and mods.get("modules"):
        m0 = mods["modules"][0]
        base = m0.get("base")
        b = int(base, 16) if isinstance(base, str) else base
        size = m0.get("size")
        s = int(size, 16) if isinstance(size, str) else size
        sc = call("scan", {"value": "cffaedfe", "type": "bytes",
                           "start": b, "end": b + min(s or 0x4000, 0x4000),
                           "max_results": 5})
        if sc:
            res = sc.get("results") or []
            print(f"   命中 {sc.get('count', len(res))} 处")
            for r in res[:5]:
                print(f"     {r.get('address')}")
    print()

    # ---- 9. pointer_chain ----
    print("── pointer_chain ──")
    if mods and mods.get("modules"):
        base = mods["modules"][0].get("base")
        pc = call("pointer_chain", {"base": base, "offsets": []})
        if pc:
            print(f"   {pc}")
    print()

    # ---- 汇总 ----
    print("=" * 60)
    if FAILS:
        print(f"✗ {len(FAILS)} 个问题:")
        for f in FAILS:
            print("  -", f)
        return 1
    print("✓ 全部工具冒烟测试通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
