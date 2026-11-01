//
//  TYMemMCPEntry.m
//  TYMemMCP —— 入口
//
//  ═══════════════════════════════════════════════════════════════════════
//  注入方式：__attribute__((constructor))
//  ═══════════════════════════════════════════════════════════════════════
//
//  dyld 加载本 dylib 时会在 main() 之前调用构造函数。这里只做三件事：
//
//    1) 起一个后台线程（**绝不在构造函数里做重活**，否则拖慢启动甚至卡死）
//    2) 在该线程里等 Unity 起来、等 il2cpp 就绪
//    3) 启动 HTTP 服务器开始服务
//
//  ═══════════════════════════════════════════════════════════════════════
//  为什么用 constructor 而不是 +load
//  ═══════════════════════════════════════════════════════════════════════
//
//  +load 在 Objective-C 运行时初始化阶段执行，此时 Foundation 未必完全
//  可用，且它属于「类加载」语义，在注入场景下不如 constructor 可靠
//  （实测原 TaoYao 产物缺 __mod_init_func 段时初始化不全，就是这个坑）。
//  constructor 走 __mod_init_func 段，dyld 直接调用，最稳。
//
//  ═══════════════════════════════════════════════════════════════════════
//  端口
//  ═══════════════════════════════════════════════════════════════════════
//
//  默认 27019（避开 MT-MCP 的 27018）。可用环境变量 TYMEM_MCP_PORT 覆盖，
//  或写成 0 让系统随机分配（此时端口见日志与 /health）。
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <unistd.h>

#import "TYHTTPServer.h"
#import "TYMCPServer.h"
#import "TYModule.h"
#import "TYMemLog.h"

#define TY_DEFAULT_PORT 27019

// 前置声明：TYBootTrace 定义在下方，但 TYWaitForUnity 里就要用
static void TYBootTrace(const char *stage);

//
//  ═══════════════════════════════════════════════════════════════════════
//  为什么不能 dlopen("UnityFramework", RTLD_NOLOAD)
//  ═══════════════════════════════════════════════════════════════════════
//
//  RTLD_NOLOAD 要求**精确匹配**已加载镜像的 install name。
//  UnityFramework 的 install name 是完整路径形式：
//
//      @executable_path/Frameworks/UnityFramework.framework/UnityFramework
//
//  用裸名 "UnityFramework" 去查永远匹配不上，于是死等 300 秒超时。
//  实测证据：tymcp.boot 里 before-wait-unity 与 after-wait-unity
//  的时间戳正好相差 300 秒，说明等待逻辑一次都没命中。
//
//  正确做法有两层：
//    1) 首选 dlsym(RTLD_DEFAULT, "il2cpp_domain_get")
//       —— 全局符号表查找，不关心镜像叫什么、装在哪。
//       只要 UnityFramework 已被加载且导出该符号，就能拿到。
//    2) 兜底遍历 _dyld_image_count()，找路径里含 UnityFramework 的镜像，
//       再用它的完整路径 dlopen(..., RTLD_NOLOAD)。
//
//  两层都拿不到才认为未就绪。
//

/// 在已加载镜像里找 UnityFramework 的完整路径
static const char *TYFindUnityImagePath(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "UnityFramework")) return nm;
    }
    return NULL;
}

/// 探测 il2cpp 是否可用：返回拿到符号的镜像句柄，失败返回 NULL
static void *TYProbeIl2Cpp(void) {
    // 1) 全局符号查找（最可靠，不依赖镜像名）
    void *sym = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    if (sym) {
        // 拿到符号即视为就绪。为后续调用方便，尝试返回镜像句柄。
        const char *p = TYFindUnityImagePath();
        if (p) {
            void *h = dlopen(p, RTLD_NOW | RTLD_NOLOAD);
            if (h) return h;
        }
        return RTLD_DEFAULT;   // 符号可用，但没定位到具体镜像
    }

    // 2) 兜底：按完整路径 dlopen
    const char *p = TYFindUnityImagePath();
    if (p) {
        void *h = dlopen(p, RTLD_NOW | RTLD_NOLOAD);
        if (h && dlsym(h, "il2cpp_domain_get")) return h;
    }
    return NULL;
}

/// 等 Unity 起来：至少 UnityFramework 已加载，且 il2cpp API 可用。
/// 返回是否在超时内就绪（不就绪也继续起服务，工具会回报 il2cpp 未就绪）。
static BOOL TYWaitForUnity(int timeoutSec) {
    time_t t0 = time(NULL);
    BOOL loggedImg = NO;

    while (time(NULL) - t0 < timeoutSec) {
        void *h = TYProbeIl2Cpp();
        if (h) {
            TYMLog(@"Unity + il2cpp 已就绪（等了 %lds）", (long)(time(NULL) - t0));
            return YES;
        }

        // 进度日志：区分「镜像还没加载」和「镜像有了但符号没有」
        if (!loggedImg) {
            const char *p = TYFindUnityImagePath();
            if (p) {
                TYMLog(@"已找到 UnityFramework 镜像：%s，等 il2cpp 符号…", p);
                loggedImg = YES;
            }
        }

        usleep(500000);
    }

    const char *p = TYFindUnityImagePath();
    if (!p) {
        TYMLog(@"等 Unity 超时（%ds）：始终没找到 UnityFramework 镜像", timeoutSec);
    } else {
        TYMLog(@"等 Unity 超时（%ds）：镜像在（%s）但没拿到 il2cpp_domain_get",
               timeoutSec, p);
    }
    return NO;
}

static void *TYBootThread(void *arg) {
    @autoreleasepool {
        TYBootTrace("thread-entered");
        TYMLog(@"启动中 pid=%d", getpid());

        // 模块监听（热更 dylib 加载后模块表变化）
        TYBootTrace("before-module-watch");
        [[TYModule shared] startWatching];
        TYBootTrace("after-module-watch");
        TYMLog(@"模块监听已启动，模块数=%lu",
               (unsigned long)[[TYModule shared] allModules].count);

        // ───────────────────────────────────────────────────────────────
        //  顺序很重要：先绑端口，再等 il2cpp
        // ───────────────────────────────────────────────────────────────
        //
        //  实测教训：原实现先 TYWaitForUnity(300) 再绑端口，
        //  而 il2cpp 检测因 dlopen 裸名匹配失败而超时，结果整整 300 秒
        //  内端口都不通 —— 期间 MCP 完全不可用，从外部看就是「插件没工作」。
        //
        //  但内存读写、模块查询、扫描这些工具**根本不需要 il2cpp**，
        //  只有 9 个 il2cpp_* 工具需要。没理由让全部功能陪着等。
        //
        //  现在先绑端口（毫秒级），服务立刻可用；再在后台等 il2cpp，
        //  就绪后 il2cpp_* 工具自然可用，未就绪时它们会明确回报状态。
        //

        // 端口：环境变量覆盖
        uint16_t port = TY_DEFAULT_PORT;
        const char *env = getenv("TYMEM_MCP_PORT");
        if (env && *env) {
            int p = atoi(env);
            if (p >= 0 && p <= 65535) port = (uint16_t)p;
            TYMLog(@"环境变量 TYMEM_MCP_PORT=%s → 端口 %u", env, port);
        }

        TYHTTPServer *srv = [TYHTTPServer shared];
        TYMLog(@"正在绑定端口 %u …", port);
        char stage[64];
        snprintf(stage, sizeof(stage), "before-bind-port-%u", port);
        TYBootTrace(stage);

        if (![srv startOnPort:port]) {
            // 默认端口被占就随机分配一个
            TYBootTrace("bind-failed-try-random");
            TYMLog(@"端口 %u 起不来，改用随机端口", port);
            if (![srv startOnPort:0]) {
                TYBootTrace("bind-random-FAILED");
                TYMLog(@"!! HTTP 服务器启动失败，功能不可用");
                return NULL;
            }
        }
        snprintf(stage, sizeof(stage), "bound-port-%u", srv.actualPort);
        TYBootTrace(stage);
        TYMLog(@"就绪：http://<设备IP>:%u/mcp", srv.actualPort);
        TYMLog(@"健康检查：http://<设备IP>:%u/health", srv.actualPort);

        // ───────────────────────────────────────────────────────────────
        //  服务已可用，再等 il2cpp（这一步可以慢慢来，不影响外部访问）
        // ───────────────────────────────────────────────────────────────
        TYBootTrace("before-wait-unity");
        BOOL il2cppReady = TYWaitForUnity(300);
        TYBootTrace(il2cppReady ? "unity-ready" : "unity-timeout");
        if (il2cppReady) {
            TYMLog(@"il2cpp 就绪：9 个 il2cpp_* 工具可用");
        } else {
            TYMLog(@"il2cpp 未就绪：il2cpp_* 工具会回报未就绪，"
                   @"内存/扫描类工具不受影响");
        }
    }
    return NULL;
}

//
//  ═══════════════════════════════════════════════════════════════════════
//  启动探针（不依赖日志系统，也不依赖网络）
//  ═══════════════════════════════════════════════════════════════════════
//
//  调试注入问题时，第一个要回答的问题是「dylib 到底被加载了吗」。
//  日志系统（TYLog）本身可能有依赖问题，所以这里用最原始的方式：
//  构造函数一进来就直接 fopen/fwrite 一个标记文件。
//
//  只用 libSystem 的 POSIX 调用，不碰 Foundation、不碰 Objective-C
//  运行时、不分配堆内存 —— 只要 dyld 调用了构造函数，这个文件必然出现。
//
//  落盘位置（按顺序尝试第一个可写的）：
//    $HOME/Documents/tymcp.boot
//    $HOME/Library/Caches/tymcp.boot
//    /tmp/tymcp.boot
//
//  ───────────────────────────────────────────────────────────────────────
//  为什么探针和日志要分开写
//  ───────────────────────────────────────────────────────────────────────
//
//  实测：装了探针后 tymcp.boot 正常出现，说明构造函数**确实执行了**。
//  但 taoyao.log 里没有任何 [memmcp] 行 —— 说明问题不在加载，
//  而在「日志没写出去」或「后续步骤卡住/崩了」。
//
//  日志走的是 TYLog，它依赖 Foundation 的
//  NSSearchPathForDirectoriesInDomains 与 NSMutableArray。
//  这些在构造函数早期的可靠性不如裸 POSIX 调用（探针就是纯 POSIX，
//  所以它能成功）。为排除「日志系统本身没起来」这个干扰，
//  这里再加一条纯 POSIX 的阶段日志，与探针写同一个文件。
//
//  这样 tymcp.boot 就同时承担两个职责：
//    · 存在性          → dylib 被加载了
//    · 内容里的阶段标记 → 启动流程走到哪一步
//

/// 往 tymcp.boot 追加一行阶段标记（纯 POSIX，不依赖 Foundation）
static void TYBootTrace(const char *stage) {
    const char *cands[] = {
        "Documents/tymcp.boot",
        "Library/Caches/tymcp.boot",
        "/tmp/tymcp.boot",
    };
    char path[1024];
    const char *home = getenv("HOME");

    for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        if (cands[i][0] == '/') {
            strlcpy(path, cands[i], sizeof(path));
        } else {
            if (!home) continue;
            snprintf(path, sizeof(path), "%s/%s", home, cands[i]);
        }
        FILE *f = fopen(path, "a");
        if (!f) continue;
        fprintf(f, "[stage] pid=%d ts=%ld %s\n", getpid(), (long)time(NULL), stage);
        // 立即刷盘：后面若崩了，这一步的证据必须already在磁盘上
        fflush(f);
        fclose(f);
        return;
    }
}

static void TYWriteBootMarker(void) {
    const char *cands[] = {
        "Documents/tymcp.boot",
        "Library/Caches/tymcp.boot",
        "/tmp/tymcp.boot",
    };
    char path[1024];
    const char *home = getenv("HOME");

    for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        if (cands[i][0] == '/') {
            strlcpy(path, cands[i], sizeof(path));
        } else {
            if (!home) continue;
            snprintf(path, sizeof(path), "%s/%s", home, cands[i]);
        }
        FILE *f = fopen(path, "a");
        if (!f) continue;
        fprintf(f, "pid=%d ts=%ld bundle=%s\n",
                getpid(), (long)time(NULL),
                getenv("CFBundleIdentifier") ? getenv("CFBundleIdentifier") : "?");
        fclose(f);
        // 让 home 下也留一份，便于用文件管理器看到
        return;
    }
}

__attribute__((constructor))
static void TYMemMCPInit(void) {
    // ★ 第一件事：写标记。放在最前面，确保「加载成功」这件事有据可查。
    //   任何后续步骤崩了都不影响这个证据。
    TYWriteBootMarker();

    // 构造函数里只起线程，不做重活
    pthread_t th;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    // 栈给 1MB：扫描线程可能递归较深
    pthread_attr_setstacksize(&at, 1024 * 1024);
    int rc = pthread_create(&th, &at, TYBootThread, NULL);
    pthread_attr_destroy(&at);
    if (rc != 0) {
        // 构造函数里不便抛异常，只记一行
        NSLog(@"[tymemmcp] 启动线程创建失败 rc=%d", rc);
    }
}
