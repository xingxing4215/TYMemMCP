# Vendor —— 从 TaoYao 复用的源文件

本目录的文件**不是**本工程编写的，是从 `TaoYaoFix` 仓库复制来的，
目的是让本仓库自包含、CI 不需要额外 checkout 另一个仓库。

| 文件 | 来源 | 作用 |
|---|---|---|
| `TYIl2Cpp.h` / `TYIl2Cpp.m` | `TaoYaoFix/Core/` | il2cpp 运行时绑定（符号解析、类/字段/方法查询、托管调用） |
| `TYLog.h` / `TYLog.m` | `TaoYaoFix/Core/` | 沙盒落盘日志（带截断） |

**来源版本**：`TaoYaoFix` @ `f1d9d21`

---

## 为什么复制而不是引用

CI（GitHub Actions）只 checkout 本仓库。若 `build.sh` 指向
`../TaoYaoFix/Core/`，CI 里那个路径不存在，构建直接失败。

可选方案与取舍：

- **复制到 Vendor/**（当前做法）
  仓库自包含，CI 简单，构建快。
  代价：两份拷贝，TaoYao 那边改了这里不会自动同步。

- CI 里额外 checkout TaoYao
  单一副本。但要配跨仓库访问权限，构建链变长，
  且两个仓库的分支状态会互相影响。

- 合并进 TaoYao 仓库
  彻底消除重复。但本插件与 TaoYao 的定位不同
  （TaoYao 是功能插件，本工程是调试工具），
  合并后 CI 与发布流程会互相牵扯。

---

## 同步方法

TaoYao 侧更新了 `TYIl2Cpp.*` / `TYLog.*` 之后，在本工程执行：

```bash
bash tools/sync_vendor.sh
```

该脚本会：

1. 从 `../TaoYaoFix/Core/` 复制最新文件到 `Vendor/`
2. 更新本文件顶部的来源版本号
3. 校验 `TYIl2Cpp.h` 是否仍声明了 `TYIl2CppBridge.m` 依赖的全部方法
   （TaoYao 删掉某个 API 而这里还在调，是跨仓库复用最常见的破坏方式）

同步后务必重跑 `python tools/selfcheck.py` 并重新构建。

---

## 注意

- **不要直接改 Vendor 里的文件**。改动会在下次同步时被覆盖。
  需要调整行为请在 `Il2Cpp/TYIl2CppBridge.*` 里包装。
- 本工程**不**包含 TaoYao 的业务代码（功能执行器、清单、云控等），
  只借它的 il2cpp 底层绑定。
