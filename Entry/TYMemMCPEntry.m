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

/// 等 Unity 起来：至少 UnityFramework 已加载，且 il2cpp API 可用。
/// 返回是否在超时内就绪（不就绪也继续起服务，工具会回报 il2cpp 未就绪）。
static BOOL TYWaitForUnity(int timeoutSec) {
    time_t t0 = time(NULL);
    BOOL logged = NO;
    while (time(NULL) - t0 < timeoutSec) {
        void *h = dlopen("UnityFramework", RTLD_NOW | RTLD_NOLOAD);
        if (h) {
            void *sym = dlsym(h, "il2cpp_domain_get");
            if (sym) {
                if (!logged) TYMLog(@"Unity + il2cpp 已就绪（等了 %lds）",
                                   (long)(time(NULL) - t0));
                return YES;
            }
            if (!logged) { TYMLog(@"UnityFramework 已加载，等 il2cpp 符号…"); logged = YES; }
        }
        usleep(500000);
    }
    TYMLog(@"等 Unity 超时（%ds），仍启动服务", timeoutSec);
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

        // 等 Unity（给足 5 分钟，冷启动 + 热更可能很久）
        TYBootTrace("before-wait-unity");
        TYWaitForUnity(300);
        TYBootTrace("after-wait-unity");

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
