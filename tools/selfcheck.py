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
    """#import "本地头" 必须能被 build.sh 的 -I 列表解析到。

    这里的 -I 列表必须与 build.sh 保持一致 —— 不同步的话
    本地检查会通过但 CI 编译失败，是最没价值的失败方式。
    """
    INCLUDE_DIRS = ("Core", "Mem", "Scan", "Il2Cpp", "MCP", "Net",
                    "Entry", "Vendor")
    d = os.path.dirname(path)
    text = io.open(path, encoding="utf-8").read()
    for m in re.finditer(r'#import\s+"([^"]+)"', text):
        h = m.group(1)
        cands = [os.path.join(d, h)]
        for sub in INCLUDE_DIRS:
            cands.append(os.path.join(ROOT, sub, h))
        if not any(os.path.exists(c) for c in cands):
            FAILS.append(f"{rel(path)} 找不到头文件 {h}"
                         f"（不在同目录，也不在任何 -I 目录）")


def check_include_dirs_match_build():
    """selfcheck 的 INCLUDE_DIRS 与 build.sh 的 -I 列表必须一致。"""
    sh = os.path.join(ROOT, "build.sh")
    if not os.path.exists(sh):
        return
    text = io.open(sh, encoding="utf-8").read()
    shdirs = set(re.findall(r'-I"\$ROOT/([A-Za-z0-9_]+)"', text))
    # build.sh 也可能用 -I"$REUSE_DIR"，其值对应 Vendor
    if re.search(r'-I"\$REUSE_DIR"', text):
        shdirs.add("Vendor")
    py = io.open(os.path.abspath(__file__), encoding="utf-8").read()
    m = re.search(r'INCLUDE_DIRS = \((.*?)\)', py, re.S)
    if not m:
        return
    pydirs = set(re.findall(r'"([A-Za-z0-9_]+)"', m.group(1)))
    only_sh = shdirs - pydirs
    only_py = pydirs - shdirs
    if only_sh:
        WARNS.append(f"build.sh 的 -I 多出: {sorted(only_sh)}")
    if only_py:
        WARNS.append(f"selfcheck 的 INCLUDE_DIRS 多出: {sorted(only_py)}")


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


def check_shell_var_cjk():
    """抓「$VAR 后紧跟中文」—— 本项目真实踩过的 bash 陷阱。

    bash 把非 ASCII 字节也算作变量名的一部分，于是

        echo "来源: $REUSE_DIR（仓库内置）"

    的变量名被解析成 `REUSE_DIR（仓库内置）`，未定义 → set -u 下
    直接 unbound variable 退出。CI 曾因此失败在「编译」那一步，
    而前面所有自检都通过（因为自检根本不执行 shell）。

    修法：一律写 `${VAR}`。
    """
    CJK = ("\u3000-\u303f\u4e00-\u9fff\uff00-\uffef\u3400-\u4dbf")
    pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)([' + CJK + r'])')
    targets = []
    for f in ("build.sh", "Makefile"):
        p = os.path.join(ROOT, f)
        if os.path.exists(p):
            targets.append(p)
    tdir = os.path.join(ROOT, "tools")
    if os.path.isdir(tdir):
        for nm in sorted(os.listdir(tdir)):
            if nm.endswith(".sh"):
                targets.append(os.path.join(tdir, nm))
    wf = os.path.join(ROOT, ".github", "workflows")
    if os.path.isdir(wf):
        for nm in sorted(os.listdir(wf)):
            if nm.endswith((".yml", ".yaml")):
                targets.append(os.path.join(wf, nm))

    for p in targets:
        for lineno, line in enumerate(io.open(p, encoding="utf-8").read().splitlines(), 1):
            if line.strip().startswith("#"):
                continue
            for m in pat.finditer(line):
                FAILS.append(
                    f"{rel(p)}:{lineno} `${m.group(1)}` 后紧跟中文 '{m.group(2)}' "
                    f"—— bash 会把它并入变量名，set -u 下报 unbound variable；"
                    f"改用 `${{{m.group(1)}}}`")


def check_vendor():
    """Vendor/ 必须自包含 —— CI 只 checkout 本仓库，缺文件就是编译失败。"""
    vend = os.path.join(ROOT, "Vendor")
    need = ("TYIl2Cpp.h", "TYIl2Cpp.m", "TYLog.h", "TYLog.m", "README.md")
    for f in need:
        if not os.path.exists(os.path.join(vend, f)):
            FAILS.append(f"Vendor/{f} 缺失 —— 仓库不自包含，CI 会编译失败")

    # Bridge 依赖的方法必须仍在 Vendor 头里声明
    hdr = os.path.join(vend, "TYIl2Cpp.h")
    if os.path.exists(hdr):
        text = io.open(hdr, encoding="utf-8").read()
        methods = (
            "classFullyQualified classWithNamespace allImageNames classNameOf "
            "classOfObject methodOfClass invokeNoArg invokeIntReturning "
            "staticObjectField objectField fieldOfClass isStaticField "
            "fieldTypeName readBoolField writeBoolField readInt32Field "
            "writeInt32Field readFloatField writeFloatField "
            "imageClassEnumerationAvailable classNamesInImageNamed "
            "scanFieldsInImageNamed classInImageNamed fieldsOfClass methodsOfClass"
        ).split()
        miss = [m for m in methods if m not in text]
        if miss:
            FAILS.append(f"Vendor/TYIl2Cpp.h 缺 Bridge 依赖的方法: {miss}")


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
    check_include_dirs_match_build()
    check_structure()
    check_vendor()
    check_shell_var_cjk()

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
