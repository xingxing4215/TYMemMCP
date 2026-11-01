#!/usr/bin/env bash
#
# build.sh —— TYMemMCP 交叉编译脚本
#
# ═══════════════════════════════════════════════════════════════════════
# 与 TaoYao 的 build.sh 共用同一套关键结论（踩过的坑不再踩）
# ═══════════════════════════════════════════════════════════════════════
#
# ★ install_name 必须与宿主注入约定一致
#   宿主 czrxd 的 LC_RPATH 只有 @executable_path/Frameworks，
#   而本 app 的注入约定是把 dylib 放 .app 根目录
#   （既有产物 星星💫超自然.dylib / TaoYao-39.dylib 都在根目录）。
#   写成 @rpath/... 会解析到 Frameworks/ 下 → dyld 在 main() 之前终止
#   → 点开即闪退。本脚本用 @executable_path/TYMemMCP.dylib 并硬校验。
#
# ★ 必须有 __mod_init_func 段
#   本工程入口是 __attribute__((constructor))，靠该段被 dyld 调用。
#   缺段 = 注入后压根不初始化。编译后硬校验。
#
# ★ MH_PIE 不是 dylib 加载前提
#   与本 app 其余正常 dylib（UnityFramework / Sentry / librecast /
#   既有注入产物）一致，不置该位，也不硬改 Mach-O header（会作废签名）。
#
# ★ 不请求额外权限
#   本插件在游戏**进程内**运行，读写内存不需要 task_for_pid 提权，
#   也不需要 get-task-allow 或任何 entitlement。
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
case "$CONFIG" in
  release) OPT="-O2 -DNDEBUG" ;;
  debug)   OPT="-O0 -g -DDEBUG" ;;
  *) echo "未知配置: $CONFIG（可选 release/debug）"; exit 1 ;;
esac

OUT_DIR="$ROOT/build"
mkdir -p "$OUT_DIR"
OUT_DYLIB="$OUT_DIR/TYMemMCP.dylib"

# TaoYao 源码根（复用其 TYIl2Cpp 绑定与 TYLog）
# 注意：TAOYAO_SRC 不设默认值 —— 留空表示用仓库内置的 Vendor/。
# 只有显式指定时才去外部 TaoYao 仓库取。

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version)"
CLANG="$(xcrun --sdk iphoneos -f clang)"

echo "== 工具链 =="
echo "   clang    : $CLANG"
echo "   SDK 路径 : $SDK_PATH"
echo "   SDK 版本 : $SDK_VER"
echo "   配置     : $CONFIG"
echo "   复用来源 : ${TAOYAO_SRC:-$ROOT/Vendor}"
echo

# ---------------------------------------------------------------- 源文件
SRC_FILES=(
  Core/TYMemLog.m
  Mem/TYMem.m
  Mem/TYModule.m
  Scan/TYScan.m
  Il2Cpp/TYIl2CppBridge.m
  MCP/TYMCPServer.m
  Net/TYHTTPServer.m
  Entry/TYMemMCPEntry.m
)

# 复用的 il2cpp 绑定与日志实现。
#
# 默认用 Vendor/（仓库自包含，CI 直接能编）。
# 若设了 TAOYAO_SRC，则改为从 TaoYao 仓库取 —— 适合本地开发时
# 想实时跟着 TaoYao 的改动编译。CI 不设该变量，走 Vendor/。
if [ -n "${TAOYAO_SRC:-}" ]; then
  REUSE_DIR="$TAOYAO_SRC/Core"
  echo "复用来源: $REUSE_DIR（TAOYAO_SRC 已指定）"
else
  REUSE_DIR="$ROOT/Vendor"
  echo "复用来源: $REUSE_DIR（仓库内置）"
fi

REUSE_FILES=(
  "$REUSE_DIR/TYIl2Cpp.m"
  "$REUSE_DIR/TYLog.m"
)

echo "== 源文件 =="
for f in "${SRC_FILES[@]}"; do
  if [ ! -f "$f" ]; then echo "   缺失: $f"; exit 1; fi
  echo "   $f"
done
echo "   --- 复用 ---"
for f in "${REUSE_FILES[@]}"; do
  if [ ! -f "$f" ]; then echo "   缺失: $f"; exit 1; fi
  echo "   $f"
done
echo

# ---------------------------------------------------------------- 编译
echo "== 编译 =="

CFLAGS=(
  -arch arm64
  -isysroot "$SDK_PATH"
  -miphoneos-version-min=12.0
  -fPIE
  -fno-common
  -fobjc-arc
  -fmodules
  -Wno-deprecated-declarations
  -Wno-unused-parameter
  $OPT
  -I"$ROOT/Core"
  -I"$ROOT/Mem"
  -I"$ROOT/Scan"
  -I"$ROOT/Il2Cpp"
  -I"$ROOT/MCP"
  -I"$ROOT/Net"
  -I"$ROOT/Entry"
  -I"$REUSE_DIR"
)

LDFLAGS=(
  -arch arm64
  -isysroot "$SDK_PATH"
  -miphoneos-version-min=12.0
  -dynamiclib
  # ★ 与宿主注入约定对齐（见文件头）
  -install_name "@executable_path/TYMemMCP.dylib"
  -dead_strip
  -Wl,-no_implicit_dylibs
  -framework Foundation
  -framework UIKit
)

set -x
"$CLANG" "${CFLAGS[@]}" "${SRC_FILES[@]}" "${REUSE_FILES[@]}" "${LDFLAGS[@]}" -o "$OUT_DYLIB"
set +x

echo
echo "== 编译完成 =="
ls -lh "$OUT_DYLIB"

# ---------------------------------------------------------------- 校验
echo
echo "== 产物校验 =="
file "$OUT_DYLIB"
lipo -info "$OUT_DYLIB" || true

echo "--- install_name（闪退根因）---"
INSTALL_NAME="$(otool -D "$OUT_DYLIB" 2>/dev/null | tail -n 1)"
echo "   install_name = $INSTALL_NAME"
case "$INSTALL_NAME" in
  "@executable_path/TYMemMCP.dylib")
    echo "   ✓ 与 app 注入约定一致" ;;
  *)
    echo "   ✗ install_name 不符！期望 @executable_path/TYMemMCP.dylib"
    exit 1 ;;
esac

echo "--- __mod_init_func（构造函数段）---"
if otool -l "$OUT_DYLIB" | grep -q "mod_init_func"; then
  echo "   ✓ 存在"
else
  echo "   ✗ 缺少 __mod_init_func —— 注入后不会初始化！"
  exit 1
fi

echo "--- 依赖列表 ---"
otool -L "$OUT_DYLIB" || true

echo "--- 关键符号 ---"
nm -gU "$OUT_DYLIB" 2>/dev/null | grep -E 'TYMemMCPInit|TYBootThread|OBJC_CLASS_\$_TY' | head -20 || true

echo
echo "== 全部校验通过 =="
echo
echo "落地位置建议：Payload/czrxd.app/TYMemMCP.dylib"
echo "注入：主二进制加 LC_LOAD_WEAK_DYLIB -> @executable_path/TYMemMCP.dylib"
echo "或直接用你现有的注入方式加载该 dylib。"
