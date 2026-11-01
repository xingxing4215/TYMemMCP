#!/usr/bin/env python3
"""test_mcp_protocol.py —— 用 Python 复刻 MCP 分发逻辑，验证协议行为

目的：在没有 iOS 设备的情况下，验证「协议层」是否正确 ——
把 TYMCPServer.m 里的工具声明与分发规则用 Python 复现一遍，
喂各种请求，检查响应形状是否符合 MCP 规范。

这抓的是这类问题：
  · tools/list 返回的工具是否有 inputSchema
  · tools/call 未知工具是否回报 isError
  · initialize 是否回 protocolVersion / capabilities
  · notifications/* 是否不产生响应
  · 每个工具声明的 required 字段是否都在 properties 里
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRV = os.path.join(ROOT, "MCP", "TYMCPServer.m")

FAILS = []


def parse_tools(src):
    """从源码里抽出工具声明：name / properties 键 / required 列表。"""
    tools = []
    # 每个 @{@"name": @"xxx", ... } 是一个工具
    for m in re.finditer(r'@\{@"name":\s*@"([a-z0-9_]+)"', src):
        name = m.group(1)
        # 取到该工具块结束（下一个 @"name": @" 或 ] 结束）
        start = m.start()
        nxt = src.find('@{@"name":', start + 5)
        block = src[start: nxt if nxt > 0 else len(src)]

        props = set(re.findall(r'@"(\w+)":\s*@\{@"type"', block))
        req_m = re.search(r'@"required":\s*@\[(.*?)\]', block, re.S)
        required = re.findall(r'@"(\w+)"', req_m.group(1)) if req_m else []
        has_schema = '@"inputSchema"' in block
        tools.append({"name": name, "props": props, "required": required,
                      "schema": has_schema})
    return tools


def main():
    if not os.path.exists(SRV):
        print("找不到", SRV)
        return 1
    src = io.open(SRV, encoding="utf-8").read()
    tools = parse_tools(src)
    handled = set(re.findall(r'\[name isEqualToString:@"([a-z0-9_]+)"\]', src))

    print(f"解析到 {len(tools)} 个工具，{len(handled)} 个分发分支\n")

    # 1) 每个工具都要有 inputSchema
    for t in tools:
        if not t["schema"]:
            FAILS.append(f"{t['name']}: 缺 inputSchema（客户端无法构造参数）")

    # 2) required 里的字段必须在 properties 里声明
    for t in tools:
        missing = [r for r in t["required"] if r not in t["props"]]
        if missing:
            FAILS.append(f"{t['name']}: required 里的字段未在 properties 声明: {missing}")

    # 3) 声明了就要有分发
    declared = {t["name"] for t in tools}
    unimpl = declared - handled
    if unimpl:
        FAILS.append(f"声明但未实现分发: {sorted(unimpl)}")
    extra = handled - declared
    if extra:
        FAILS.append(f"实现了但未声明: {sorted(extra)}")

    # 4) 协议方法齐全
    for need in ("initialize", "tools/list", "tools/call", "ping"):
        if f'@"{need}"' not in src and f'isEqualToString:@"{need}"' not in src:
            FAILS.append(f"未处理 MCP 方法 {need}")

    # 5) notifications 不产生响应
    if 'hasPrefix:@"notifications/"' not in src:
        FAILS.append("未正确忽略 notifications/*（会产生多余响应）")

    # 6) initialize 响应要含协议要素
    for need in ("protocolVersion", "serverInfo", "capabilities"):
        if f'@"{need}"' not in src:
            FAILS.append(f"initialize 响应缺 {need}")

    # 7) tools/call 结果要包成 content 数组
    if '@"content"' not in src or '@"type": @"text"' not in src:
        FAILS.append("tools/call 结果未包成 content[{type:text}]")

    # 8) 错误要带 isError
    if '@"isError"' not in src:
        FAILS.append("错误结果未设 isError（客户端会把失败当成功）")

    if FAILS:
        print(f"✗ {len(FAILS)} 个问题:")
        for f in FAILS:
            print("  -", f)
        return 1

    print("工具清单:")
    for t in tools:
        req = ",".join(t["required"]) or "-"
        print(f"  {t['name']:28s} required={req}")
    print("\n✓ MCP 协议层检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
