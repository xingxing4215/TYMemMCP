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
#import <stdlib.h>
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
        TYMLog(@"启动中 pid=%d", getpid());

        // 模块监听（热更 dylib 加载后模块表变化）
        [[TYModule shared] startWatching];

        // 等 Unity（给足 5 分钟，冷启动 + 热更可能很久）
        TYWaitForUnity(300);

        // 端口：环境变量覆盖
        uint16_t port = TY_DEFAULT_PORT;
        const char *env = getenv("TYMEM_MCP_PORT");
        if (env && *env) {
            int p = atoi(env);
            if (p >= 0 && p <= 65535) port = (uint16_t)p;
        }

        TYHTTPServer *srv = [TYHTTPServer shared];
        if (![srv startOnPort:port]) {
            // 默认端口被占就随机分配一个
            TYMLog(@"端口 %u 起不来，改用随机端口", port);
            if (![srv startOnPort:0]) {
                TYMLog(@"!! HTTP 服务器启动失败，功能不可用");
                return NULL;
            }
        }
        TYMLog(@"就绪：http://<设备IP>:%u/mcp", srv.actualPort);
        TYMLog(@"健康检查：http://<设备IP>:%u/health", srv.actualPort);
    }
    return NULL;
}

__attribute__((constructor))
static void TYMemMCPInit(void) {
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
