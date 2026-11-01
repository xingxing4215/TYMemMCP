#!/usr/bin/env bash
#
# sync_vendor.sh —— 从 TaoYaoFix 同步复用的源文件到 Vendor/
#
# 跨仓库复用最容易出的问题：TaoYao 那边删掉/改名了某个 API，
# 而本工程还在调 —— 编译期才发现。本脚本在同步时就把它查出来。
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="${TAOYAO_SRC:-$ROOT/../TaoYaoFix}"
FILES=(TYIl2Cpp.h TYIl2Cpp.m TYLog.h TYLog.m)

if [ ! -d "$SRC/Core" ]; then
  echo "✗ 找不到源目录: $SRC/Core"
  echo "  用 TAOYAO_SRC=<路径> 指定 TaoYao 仓库位置"
  exit 1
fi

echo "源: $SRC/Core"
echo

# 记录来源版本
if git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then
  REV="$(git -C "$SRC" rev-parse --short HEAD)"
  echo "TaoYao 版本: $REV"
else
  REV="unknown"
  echo "TaoYao 版本: 无法读取（非 git 仓库）"
fi
echo

mkdir -p Vendor

changed=0
for f in "${FILES[@]}"; do
  if [ ! -f "$SRC/Core/$f" ]; then
    echo "  ✗ 源文件缺失: Core/$f"
    exit 1
  fi
  if [ -f "Vendor/$f" ] && cmp -s "$SRC/Core/$f" "Vendor/$f"; then
    echo "  = ${f}（无变化）"
  else
    cp "$SRC/Core/$f" "Vendor/$f"
    echo "  ↑ ${f}（已更新）"
    changed=1
  fi
done

echo

# ---- 关键校验：Bridge 依赖的方法是否仍全部存在 ----
echo "校验 TYIl2Cpp.h 是否仍声明 Bridge 依赖的方法…"
HDR="Vendor/TYIl2Cpp.h"
METHODS=(
  classFullyQualified classWithNamespace allImageNames classNameOf classOfObject
  methodOfClass invokeNoArg invokeIntReturning staticObjectField objectField
  fieldOfClass isStaticField fieldTypeName readBoolField writeBoolField
  readInt32Field writeInt32Field readFloatField writeFloatField
  imageClassEnumerationAvailable classNamesInImageNamed scanFieldsInImageNamed
  classInImageNamed fieldsOfClass methodsOfClass
)
missing=0
for m in "${METHODS[@]}"; do
  if ! grep -q "$m" "$HDR"; then
    echo "  ✗ 缺失: $m"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo
  echo "✗ TYIl2Cpp.h 缺少上述方法 —— Il2Cpp/TYIl2CppBridge.m 会编译失败"
  echo "  请在 TaoYao 侧恢复这些 API，或修改 Bridge 的调用方式"
  exit 1
fi
echo "  ✓ 全部 ${#METHODS[@]} 个方法都在"

# ---- 更新 Vendor/README.md 里的版本号 ----
if [ "$REV" != "unknown" ]; then
  python - "$REV" <<'PY'
import io, re, sys
rev = sys.argv[1]
p = "Vendor/README.md"
s = io.open(p, encoding="utf-8").read()
s2 = re.sub(r'(\*\*来源版本\*\*：`TaoYaoFix` @ )`[0-9a-f]+`', r'\1`%s`' % rev, s)
if s2 != s:
    io.open(p, "w", encoding="utf-8").write(s2)
    print(f"  README 版本号已更新为 {rev}")
PY
fi

echo
if [ "$changed" -eq 0 ]; then
  echo "✓ 已是最新，无需改动"
else
  echo "✓ 同步完成。请重跑 python tools/selfcheck.py 并重新构建"
fi
