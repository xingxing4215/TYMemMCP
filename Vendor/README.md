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

---

## 本工程的本地修正（重要）

`TYIl2Cpp.m` 里有一处**本工程做的修正**，上游没有。标记文字：
`本地修正（TYMemMCP）`。

### 修正内容：UnityFramework 探测

原实现：

```c
const char *cands[] = {
    "UnityFramework",
    "@rpath/UnityFramework.framework/UnityFramework",
    NULL,
};
for (...) dlopen(cands[i], RTLD_NOW | RTLD_NOLOAD);
```

问题：`RTLD_NOLOAD` 要求**精确匹配**已加载镜像的 install name。
UnityFramework 实际的 install name 是完整路径：

```
@executable_path/Frameworks/UnityFramework.framework/UnityFramework
```

两个候选都匹配不上，`TYOpenUnity()` 永远返回 NULL → il2cpp 永远不可用。

**实测证据**：插件启动日志里 `before-wait-unity` 与
`after-wait-unity` 的时间戳正好相差 300 秒（超时上限），
说明等待逻辑一次都没命中。

修正：

1. 首选 `dlsym(RTLD_DEFAULT, "il2cpp_domain_get")` —— 全局符号查找，
   不关心镜像叫什么、装在哪
2. 兜底遍历 `_dyld_image_count()`，按真实路径 `dlopen(..., RTLD_NOLOAD)`
3. 保留原候选作为最后尝试

### 对同步的影响

`tools/sync_vendor.sh` 检测到该标记时会**跳过** `TYIl2Cpp.m`，
避免把 bug 覆盖回来。要强制覆盖加 `--force`。
`selfcheck.py` 也会校验标记是否还在 —— 丢了就直接报错。

若上游已合并等效修正，可以 `--force` 同步，然后删掉本节的说明。

