# TYMemMCP —— 进程内内存调试 MCP 插件

一个注入进游戏进程的 iOS dylib，在**进程内**起一个 MCP 服务器，
让外部 AI 客户端能直接读/搜内存、查 il2cpp 类结构。

---

## 为什么要「进程内」

外部调试器（Frida / lldb / MT-MCP 之类）走的是 `task_for_pid` + `mach_vm_*`，
需要额外提权、需要 `get-task-allow`、在越狱环境还常被反调试挡。

本插件**就在目标进程里跑**，读写内存就是普通的 `mach_vm_read` / `mach_vm_write`：

- 不需要 `task_for_pid` 提权
- 不需要任何 entitlement
- 不受反调试检测影响（没有 ptrace 行为）
- 能直接拿到 il2cpp 运行时句柄，做反射查询

代价是必须注入，且和游戏同生共死（崩了会带崩游戏）。

---

## 架构

```
┌─────────────────────────────────────────────────────┐
│ 游戏进程 (czrxd)                                      │
│                                                      │
│  ┌──────────────────┐                                │
│  │ TYMemMCP.dylib   │  constructor → 后台线程        │
│  │                  │                                │
│  │  TYHTTPServer    │  ← BSD socket, 0.0.0.0:27019   │
│  │      ↓           │                                │
│  │  TYMCPServer     │  JSON-RPC 分发 / 21 个工具      │
│  │      ↓           │                                │
│  │  ┌────────────┐  │                                │
│  │  │ TYMem      │  │  mach_vm_read / region 切分     │
│  │  │ TYModule   │  │  dyld image 枚举 / 地址反查      │
│  │  │ TYScan     │  │  精确搜索 / 指针链 / 指针扫描     │
│  │  │ Il2CppBridge│ │  复用 TaoYao 的 il2cpp 绑定      │
│  │  └────────────┘  │                                │
│  └──────────────────┘                                │
└─────────────────────────────────────────────────────┘
         ↑ POST /mcp (JSON-RPC)
   外部 MCP 客户端
```

---

## 工具清单（21 个）

### 基础信息

| 工具 | 说明 |
|---|---|
| `get_info` | pid、模块数、il2cpp 状态、可读内存总量 |
| `list_modules` | 已加载模块（可按子串过滤） |
| `image_lookup` | 地址反查所属模块 / 模块内偏移 / 所在段 |

### 内存读

| 工具 | 说明 |
|---|---|
| `read_memory` | 读一段内存，返回 hex / ascii / 多类型解读 |
| `read_value` | 按类型读单个值（i8…u64 / f32 / f64） |
| `write_value` | 写单个值（要求目标页可写） |
| `list_regions` | 枚举 VM region（地址 / 大小 / 权限 / 模块） |

### 搜索

| 工具 | 说明 |
|---|---|
| `scan` | 精确值搜索（整数 / 浮点 / 字符串 / 字节序列） |
| `scan_refine` | 二次筛选：只保留值仍匹配的地址 |
| `scan_results` | 取回上次扫描结果（可同时读当前值） |
| `pointer_chain` | 多级指针链解析（基址 + 偏移数组） |
| `find_pointers` | 指针扫描：谁指向这个地址 |

### il2cpp

| 工具 | 说明 |
|---|---|
| `il2cpp_status` | 绑定状态与镜像清单 |
| `il2cpp_find_class` | 按类名 / 命名空间查类 |
| `il2cpp_list_classes` | 列镜像内类名（可正则过滤） |
| `il2cpp_fields` | 类的字段（名 / 类型 / 是否静态 / 偏移） |
| `il2cpp_methods` | 类的方法 |
| `il2cpp_find_by_field_type` | 反查「哪些类持有某类型的字段」 |
| `il2cpp_navigate` | 走 root + path 引用链，回报每跳真实类型 |
| `il2cpp_read_field` | 读字段（静态直读；实例需 root+path 定位） |
| `il2cpp_write_field` | 写字段并立即回读 |

`il2cpp_find_by_field_type` 是应对**混淆名重排**的关键工具：
游戏每次更新会把 `CINBLKINBLA`、`HIIILCBEIJG` 这类混淆名整体打乱，
但「谁持有 `WarFogAgent` 类型的字段」这个**结构事实**不变。
按结构反查就能在新版本上重建锚点。

---

## 编译

需要 macOS + Xcode（iOS arm64 目标只有 Xcode 提供）：

```bash
./build.sh release      # 或 debug
```

产物：`build/TYMemMCP.dylib`

脚本会硬校验两件事，任一不过就中断：

1. **`install_name` = `@executable_path/TYMemMCP.dylib`**
   宿主 `czrxd` 只有一个 rpath `@executable_path/Frameworks`，
   而本 app 的注入约定是把 dylib 放 `.app` 根目录。写 `@rpath/...`
   会让 dyld 在 `main()` 之前终止进程 —— 表现就是点开即闪退。

2. **`__mod_init_func` 段存在**
   本插件入口是 `__attribute__((constructor))`，靠该段被 dyld 调用。
   缺段 = 注入后压根不初始化。

`MH_PIE` 仅作记录，不作门槛 —— 本 app 里正常工作
的 dylib（UnityFramework / Sentry / librecast / 既有注入产物）都没有该位。

依赖 `../TaoYaoFix/Core/TYIl2Cpp.m`（复用其 il2cpp 绑定）。可用
环境变量 `TAOYAO_SRC` 指定别的路径。

---

## 注入

把 `TYMemMCP.dylib` 放进 `Payload/czrxd.app/`，然后：

- 主二进制加 `LC_LOAD_WEAK_DYLIB -> @executable_path/TYMemMCP.dylib`，或
- 用你现有的注入方式（与 `TaoYao-39.dylib` 同样的做法）

启动后日志在 `Documents/taoyao.log`（与 TaoYao 共用），搜 `[memmcp]`。

---

## 使用

默认监听 `0.0.0.0:27019`（避开 MT-MCP 的 27018）。
可用环境变量 `TYMEM_MCP_PORT` 覆盖，设为 `0` 则随机分配。

```bash
# 健康检查
curl http://<设备IP>:27019/health

# 建立会话
SID=$(curl -s -D - -o /dev/null -X POST http://<设备IP>:27019/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cli","version":"1"}}}' \
  | grep -i mcp-session-id | tr -d '\r' | awk '{print $2}')

# ★ 必须补发 initialized 通知，否则后续调用报 Session not initialized
curl -s -X POST http://<设备IP>:27019/mcp \
  -H 'Content-Type: application/json' -H "MCP-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'

# 列工具
curl -s -X POST http://<设备IP>:27019/mcp \
  -H 'Content-Type: application/json' -H "MCP-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

直接配置到 MCP 客户端也可以（URL 填 `http://<设备IP>:27019/mcp`）。

---

## 自检（不需要设备 / Xcode）

```bash
python tools/selfcheck.py          # 括号配平 / 头文件 / 全角标点 / 结构要求
python tools/test_mcp_protocol.py  # 工具声明与分发一致性、必填字段
python tools/mock_mcp_test.py      # 起 mock 服务器跑完整握手时序
```

`mock_mcp_test.py` 最关键：它验证 `initialize → notifications/initialized
→ tools/list → tools/call` 这条时序能被标准客户端接受。
这正是 MT-MCP 那个 `Session not initialized` 的坑 —— 少了
`notifications/initialized` 通知，后续调用全被拒。

---

## 已知限制

- **不支持 SSE 流式**：`GET /mcp` 返回 405 并说明原因。
  工具调用都是短请求，一次性 JSON 响应足够；客户端若强制要求 SSE 需另行适配。
- **搜索是同步阻塞的**：`scan` 全地址空间可能耗时数秒到数十秒。
  期间 HTTP 连接保持打开，客户端超时要设得足够长。
- **单次读上限 64MB、写要求整段在同一可写 region 内**。
- **与游戏同生共死**：本插件在游戏进程内，任何崩溃都会带崩游戏。
  搜索类操作建议先限定 `module` 或地址区间。
