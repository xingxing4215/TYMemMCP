#
# Makefile —— TYMemMCP 便捷入口
#
# 实际编译逻辑在 build.sh（含 install_name 与 __mod_init_func 硬校验）。
# 本文件只是给习惯 make 的人一个统一入口。
#

SHELL := /bin/bash
ROOT  := $(shell pwd)

.PHONY: all release debug check clean dist help

help:
	@echo "TYMemMCP 构建"
	@echo
	@echo "  make release   编译 release 版 dylib"
	@echo "  make debug     编译 debug 版 dylib"
	@echo "  make check     只跑静态自检（不需要 macOS）"
	@echo "  make dist      编译 + 打包成可注入的 zip"
	@echo "  make clean     清理产物"
	@echo
	@echo "  make sync      从 TaoYaoFix 同步 Vendor 文件"

all: release

release:
	bash build.sh release

debug:
	bash build.sh debug

check:
	@echo "== 源码结构自检 =="
	@python3 tools/selfcheck.py
	@echo
	@echo "== MCP 协议层一致性 =="
	@python3 tools/test_mcp_protocol.py
	@echo
	@echo "== MCP 握手时序 =="
	@python3 tools/mock_mcp_test.py

sync:
	bash tools/sync_vendor.sh

dist: release
	@set -euo pipefail; \
	NAME="TYMemMCP-$$(date +%Y%m%d-%H%M)"; \
	mkdir -p "build/$$NAME"; \
	cp build/TYMemMCP.dylib "build/$$NAME/"; \
	cp README.md "build/$$NAME/"; \
	( cd build && zip -qr "$$NAME.zip" "$$NAME" ); \
	rm -rf "build/$$NAME"; \
	echo "已打包: build/$$NAME.zip"; \
	ls -lh "build/$$NAME.zip"

clean:
	rm -rf build
