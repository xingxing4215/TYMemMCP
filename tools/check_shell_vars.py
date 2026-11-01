#!/usr/bin/env python3
"""check_shell_vars.py —— 抓「$VAR 后紧跟中文」这类 bash 陷阱

背景：bash 里变量名的合法字符包括所有 ASCII 字母数字下划线，
但**非 ASCII 字节也会被当作变量名的一部分**（bash 按字节处理）。
所以写

    echo "来源: $REUSE_DIR（仓库内置）"

bash 会把变量名解析成 `REUSE_DIR（仓库内置）`，而它未定义，
在 set -u 下直接报 `unbound variable` 并退出。

这个坑在本项目真实发生过：CI 第 8 步「编译」因此失败，
而前 7 步（含三项自检）全部通过 —— 因为自检根本不执行 shell。

修法一律用花括号隔断：`${VAR}（说明）`

本脚本扫描 .sh 与 .yml 里所有 ``$VAR`` 紧邻 CJK 字符的位置。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILS = []

# CJK 统一表意文字 + 全角标点 + 常见中文符号
CJK = (
    "\u3000-\u303f"          # 中文标点
    "\u4e00-\u9fff"          # 汉字
    "\uff00-\uffef"          # 全角字符
    "\u3400-\u4dbf"          # 扩展 A
)

# $VAR 或 ${VAR} 后紧跟 CJK
PAT_BARE = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)([' + CJK + r'])')
# ${VAR} 是安全的
PAT_SAFE = re.compile(r'\$\{[A-Za-z_][A-Za-z0-9_]*\}')


def scan(path):
    text = io.open(path, encoding="utf-8").read()
    for lineno, line in enumerate(text.splitlines(), 1):
        # 跳过整行注释
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for m in PAT_BARE.finditer(line):
            # 若该 $VAR 正处于 ${...} 内则放行（不会匹配，因为花括号形式不同）
            var, ch = m.group(1), m.group(2)
            col = m.start() + 1
            FAILS.append(
                f"{os.path.relpath(path, ROOT)}:{lineno}:{col} "
                f"`${var}` 后紧跟中文 '{ch}' —— bash 会把中文并入变量名，"
                f"在 set -u 下报 unbound variable。改用 `${{{var}}}`"
            )


def main():
    files = []
    for dp, _, names in os.walk(ROOT):
        if "__pycache__" in dp or "/build" in dp.replace("\\", "/"):
            continue
        for nm in names:
            if nm.endswith((".sh", ".yml", ".yaml")):
                files.append(os.path.join(dp, nm))
    files.sort()

    print(f"扫描 {len(files)} 个 shell / workflow 文件…\n")
    for f in files:
        scan(f)

    if FAILS:
        print(f"✗ 发现 {len(FAILS)} 处隐患:")
        for x in FAILS:
            print("  -", x)
        return 1
    print("✓ 无「$VAR 紧邻中文」隐患")
    return 0


if __name__ == "__main__":
    sys.exit(main())
