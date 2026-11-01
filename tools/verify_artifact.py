#!/usr/bin/env python3
"""verify_artifact.py —— 检查 dylib 产物是否可被轻松签/越狱环境正常加载

用途：导入设备前先在本机跑一遍，确认文件本身没问题。
如果这里全绿但设备上没反应，问题就在导入/重签环节，不在产物。

检查项：
  1. Mach-O 头与架构（arm64）
  2. install_name 形式
  3. __mod_init_func 段（构造函数必须靠它被调用）
  4. ObjC 类数量（__objc_classlist）
  5. 外部依赖是否都是系统库
  6. 代码签名状态（越狱环境需要 ad-hoc 或伪签名）
  7. 是否含 Swift 运行时依赖（缺失会闪退）

用法: python tools/verify_artifact.py build/TYMemMCP.dylib
"""
import io
import os
import struct
import sys

SYS_PREFIXES = ("/System/Library/", "/usr/lib/")
KNOWN_EMBEDDED = ("@rpath/", "@executable_path/", "@loader_path/")


def u32(d, o):
    return struct.unpack("<I", d[o:o + 4])[0]


def u64(d, o):
    return struct.unpack("<Q", d[o:o + 8])[0]


def parse(d):
    if len(d) < 32:
        return None
    magic = u32(d, 0)
    if magic != 0xFEEDFACF:
        return {"bad_magic": magic}
    ncmds = u32(d, 16)
    flags = u32(d, 24)
    off = 32
    info = {
        "magic": magic, "ncmds": ncmds, "flags": flags,
        "cputype": u32(d, 4), "id": None, "libs": [],
        "init": None, "classlist_size": 0, "rpaths": [],
        "has_code_signature": False, "segments": [],
    }
    for _ in range(ncmds):
        if off + 8 > len(d):
            break
        cmd, cmdsize = u32(d, off), u32(d, off + 4)
        if cmdsize == 0:
            break
        if cmd == 0xD:  # LC_ID_DYLIB
            no = u32(d, off + 8)
            info["id"] = d[off + no:off + cmdsize].split(b"\0")[0].decode("utf-8", "replace")
        elif cmd in (0xC, 0x18, 0x1F, 0x23):  # LOAD / WEAK / REEXPORT / LAZY
            no = u32(d, off + 8)
            info["libs"].append(d[off + no:off + cmdsize].split(b"\0")[0].decode("utf-8", "replace"))
        elif cmd == 0x1C | 0x80000000 or cmd == 0x8000001C:  # LC_RPATH
            no = u32(d, off + 8)
            info["rpaths"].append(d[off + no:off + cmdsize].split(b"\0")[0].decode("utf-8", "replace"))
        elif cmd == 0x1D:  # LC_CODE_SIGNATURE
            info["has_code_signature"] = True
        elif cmd == 0x19:  # LC_SEGMENT_64
            seg = d[off + 8:off + 24].split(b"\0")[0].decode("utf-8", "replace")
            nsects = u32(d, off + 64)
            info["segments"].append(seg)
            so = off + 72
            for _s in range(nsects):
                sn = d[so:so + 16].split(b"\0")[0].decode("utf-8", "replace")
                size = u64(d, so + 40)
                if "init_func" in sn:
                    info["init"] = (seg, sn)
                if sn == "__objc_classlist":
                    info["classlist_size"] = size
                so += 80
        off += cmdsize
    return info


def main():
    p = sys.argv[1] if len(sys.argv) > 1 else "build/TYMemMCP.dylib"
    if not os.path.exists(p):
        print(f"找不到 {p}")
        return 1
    d = io.open(p, "rb").read()
    info = parse(d)
    if not info or "bad_magic" in info:
        print(f"✗ 不是 64 位 Mach-O（magic={info.get('bad_magic') if info else '?'}）")
        return 1

    fails, warns = [], []

    print(f"文件: {p}  ({len(d):,} 字节)")
    print()

    # 1 架构
    if info["cputype"] != 16777228:
        fails.append(f"CPU 类型 {info['cputype']} 不是 arm64(16777228)")
    print(f"  架构        : {'arm64' if info['cputype'] == 16777228 else info['cputype']}")

    # 2 install_name
    print(f"  install_name: {info['id']}")
    if not info["id"]:
        warns.append("没有 LC_ID_DYLIB")
    elif not info["id"].startswith(KNOWN_EMBEDDED):
        warns.append(f"install_name 不是 @rpath/@executable_path/@loader_path 形式: {info['id']}")
    print(f"  rpath       : {info['rpaths'] or '(无)'}")

    # 3 构造函数段
    print(f"  __mod_init_func: {info['init']}")
    if not info["init"]:
        fails.append("缺 __mod_init_func 段 —— 构造函数不会被调用，插件不会启动")

    # 4 ObjC 类
    nclass = info["classlist_size"] // 8
    print(f"  ObjC 类数量 : {nclass}")
    if nclass == 0:
        fails.append("__objc_classlist 为空 —— 没有编入任何 ObjC 类")

    # 5 依赖
    print(f"  依赖 ({len(info['libs'])}):")
    for l in info["libs"]:
        tag = ""
        if l.startswith(SYS_PREFIXES):
            tag = "系统"
        elif l.startswith(KNOWN_EMBEDDED):
            tag = "内嵌"
        else:
            tag = "!! 需注意"
            warns.append(f"非系统/非内嵌依赖: {l}")
        print(f"      [{tag}] {l}")
        if "libswiftCore" in l:
            fails.append("依赖 Swift 运行时（libswiftCore）—— 目标 app 没内嵌就会闪退")

    # 6 签名
    print(f"  代码签名    : {'有 LC_CODE_SIGNATURE' if info['has_code_signature'] else '无（裸文件）'}")
    if not info["has_code_signature"]:
        warns.append("没有签名字段；越狱环境通常需要 ldid 伪签，"
                     "或由轻松签在导入时自动重签")

    print()
    if warns:
        print("警告:")
        for w in warns:
            print("  !", w)
    if fails:
        print("致命问题:")
        for f in fails:
            print("  ✗", f)
        return 1
    print("✓ 产物结构正常，可交给轻松签导入")
    return 0


if __name__ == "__main__":
    sys.exit(main())
