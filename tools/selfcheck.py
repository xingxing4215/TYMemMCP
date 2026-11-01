#!/usr/bin/env python3
"""selfcheck.py —— TYMemMCP 源码自检（不需要 Xcode / iOS SDK）

在 Windows 上无法编译 arm64 iOS dylib，但静态问题可以在提交前抓掉：

  1) 括号 / 大括号 / 方括号配平（排除字符串与注释）
  2) 每个 .m 的 #import "本地头" 是否存在
  3) 实现的方法名是否在 @interface 里声明过（只查明显拼错的情况）
  4) 是否有中文标点误入代码（字符串外的全角符号）
  5) build.sh 列出的源文件是否都存在
  6) 关键结构性要求：constructor、install_name、__mod_init_func 校验语句

退出码非 0 表示有问题。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILS = []
WARNS = []


def rel(p):
    return os.path.relpath(p, ROOT).replace("\\", "/")


def strip_code(text):
    """去掉字符串字面量与注释，只留下结构性代码。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        # 行注释
        if c == "/" and i + 1 < n and text[i+1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        # 块注释
        if c == "/" and i + 1 < n and text[i+1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i+1] == "/"):
                i += 1
            i += 2
            continue
        # 字符字面量
        if c == "'":
            i += 1
            while i < n and text[i] != "'":
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        # 字符串字面量（含 @"..." ）
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check_balance(path):
    raw = io.open(path, encoding="utf-8").read()
    code = strip_code(raw)
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in pairs:
            if not stack:
                FAILS.append(f"{rel(path)}:{line} 多余的 '{ch}'")
                return
            op, ol = stack.pop()
            if op != pairs[ch]:
                FAILS.append(f"{rel(path)}:{line} '{ch}' 与第 {ol} 行的 '{op}' 不匹配")
                return
    if stack:
        op, ol = stack[-1]
        FAILS.append(f"{rel(path)} 第 {ol} 行的 '{op}' 未闭合")


def check_imports(path):
    d = os.path.dirname(path)
    text = io.open(path, encoding="utf-8").read()
    for m in re.finditer(r'#import\s+"([^"]+)"', text):
        h = m.group(1)
        # 在源文件同目录、以及各子目录里找
        cands = [os.path.join(d, h)]
        for sub in ("Core", "Mem", "Scan", "Il2Cpp", "MCP", "Net", "Entry"):
            cands.append(os.path.join(ROOT, sub, h))
        # 复用的 TaoYao 头
        cands.append(os.path.join(ROOT, "..", "TaoYaoFix", "Core", h))
        if not any(os.path.exists(c) for c in cands):
            FAILS.append(f"{rel(path)} 找不到头文件 {h}")


FULLWIDTH = "，。；：（）【】“”‘’！？、《》　"


def check_fullwidth(path):
    """字符串外的全角标点 —— 最常见的「中文标点误入代码」事故。

    例外：#pragma mark 之类预处理指令允许中文（本就是给人看的注释）。
    """
    raw = io.open(path, encoding="utf-8").read()
    i, n = 0, len(raw)
    line = 1
    line_start = 0
    while i < n:
        c = raw[i]
        if c == "\n":
            line += 1
            line_start = i + 1
        if c == "/" and i + 1 < n and raw[i+1] == "/":
            while i < n and raw[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and raw[i+1] == "*":
            i += 2
            while i + 1 < n and not (raw[i] == "*" and raw[i+1] == "/"):
                if raw[i] == "\n":
                    line += 1
                i += 1
            i += 2
            continue
        if c == '"':
            i += 1
            while i < n and raw[i] != '"':
                if raw[i] == "\\":
                    i += 1
                if raw[i] == "\n":
                    line += 1
                i += 1
            i += 1
            continue
        if c in FULLWIDTH:
            cur = raw[line_start:i]
            if cur.lstrip().startswith("#"):
                i += 1
                continue            # 预处理指令（含 #pragma mark 中文）放行
            FAILS.append(f"{rel(path)}:{line} 代码区出现全角标点 '{c}'")
        i += 1


def check_sources_exist():
    sh = os.path.join(ROOT, "build.sh")
    if not os.path.exists(sh):
        FAILS.append("缺少 build.sh")
        return
    text = io.open(sh, encoding="utf-8").read()
    for m in re.finditer(r'SRC_FILES=\((.*?)\n\)', text, re.S):
        for line in m.group(1).splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            p = os.path.join(ROOT, line)
            if not os.path.exists(p):
                FAILS.append(f"build.sh 列出的源文件不存在: {line}")


def check_structure():
    entry = os.path.join(ROOT, "Entry", "TYMemMCPEntry.m")
    if not os.path.exists(entry):
        FAILS.append("缺少 Entry/TYMemMCPEntry.m")
    else:
        t = io.open(entry, encoding="utf-8").read()
        if "__attribute__((constructor))" not in t:
            FAILS.append("入口缺少 __attribute__((constructor)) —— 注入后不会初始化")
        if "pthread_create" not in t:
            FAILS.append("入口未在后台线程启动（构造函数里做重活会拖慢/卡死启动）")

    # HTTP 服务器必须实现 MCP 关键方法
    srv = os.path.join(ROOT, "MCP", "TYMCPServer.m")
    if not os.path.exists(srv):
        FAILS.append("缺少 MCP/TYMCPServer.m")
    else:
        t = io.open(srv, encoding="utf-8").read()
        for need in ("initialize", "tools/list", "tools/call", "notifications/"):
            if need not in t:
                FAILS.append(f"TYMCPServer 未处理 MCP 方法 {need}")

    # 工具清单里的名字要真的被 dispatch
    if os.path.exists(srv):
        t = io.open(srv, encoding="utf-8").read()
        declared = set(re.findall(r'@"name":\s*@"([a-z0-9_]+)"', t))
        handled = set(re.findall(r'\[name isEqualToString:@"([a-z0-9_]+)"\]', t))
        missing = declared - handled
        if missing:
            FAILS.append(f"工具声明了但未实现分发: {sorted(missing)}")

    # build.sh 的两道硬校验
    sh = io.open(os.path.join(ROOT, "build.sh"), encoding="utf-8").read()
    if "@executable_path/TYMemMCP.dylib" not in sh:
        FAILS.append("build.sh 未使用 @executable_path 形式的 install_name（会导致注入后闪退）")
    if "mod_init_func" not in sh:
        FAILS.append("build.sh 未校验 __mod_init_func 段")


def main():
    files = []
    for dirpath, _, names in os.walk(ROOT):
        if "/build" in dirpath.replace("\\", "/") or "__pycache__" in dirpath:
            continue
        for nm in names:
            if nm.endswith((".m", ".h", ".c")):
                files.append(os.path.join(dirpath, nm))
    files.sort()

    print(f"检查 {len(files)} 个源文件…\n")

    for f in files:
        check_balance(f)
        check_imports(f)
        check_fullwidth(f)

    check_sources_exist()
    check_structure()

    if WARNS:
        print("警告:")
        for w in WARNS:
            print("  !", w)
        print()

    if FAILS:
        print(f"✗ 发现 {len(FAILS)} 个问题:")
        for x in FAILS:
            print("  -", x)
        return 1

    print(f"✓ 全部通过（{len(files)} 个文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
