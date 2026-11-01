//
//  TYLog.m
//  TaoYao 修复版 —— 日志实现
//

#import "TYLog.h"
#import <pthread.h>
#import <stdarg.h>
#import <os/lock.h>

/// 内存中保留的最大条数。超出后丢最旧的。
static const NSUInteger kTYLogRingCapacity = 512;

/// 日志阈值。Debug 版本才输出 Debug 级。
#if DEBUG
static TYLogLevel gTYLogLevel = TYLogLevelDebug;
#else
static TYLogLevel gTYLogLevel = TYLogLevelInfo;
#endif

/// 环形缓冲 + 互斥。用 os_unfair_lock，比 NSLock 轻量且不会引入
/// ObjC 消息发送开销（日志路径上越少 ObjC 越安全）。
static os_unfair_lock gTYLogLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *gTYLogRing = nil;
static NSUInteger gTYLogTotal = 0;
static NSString *gTYLogPath = nil;
static FILE *gTYLogFile = NULL;
static BOOL gTYLogInited = NO;
/// 云端日志回调。与环形缓冲共用同一把锁保护指针；实际回调在锁外执行。
static TYLogSink gTYLogSink = nil;

/// 时间戳格式器。懒加载，避免在 +load/constructor 早期创建。
static NSDateFormatter *TYLogFormatter(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return fmt;
}

void TYLogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            gTYLogRing = [NSMutableArray arrayWithCapacity:kTYLogRingCapacity];

            // 落盘位置：优先 Documents（沙盒可写），失败退到 /tmp。
            NSString *dir = nil;
            @try {
                NSArray *paths = NSSearchPathForDirectoriesInDomains(
                    NSDocumentDirectory, NSUserDomainMask, YES);
                if (paths.count > 0) dir = paths.firstObject;
            } @catch (NSException *e) { dir = nil; }

            if (dir.length == 0) dir = @"/tmp";

            gTYLogPath = [dir stringByAppendingPathComponent:@"taoyao.log"];

            // 用 C 的 fopen 而不是 NSFileHandle：构造函数阶段
            // NSFileHandle 可能还未完全可用。
            gTYLogFile = fopen(gTYLogPath.UTF8String, "a");
            if (gTYLogFile) {
                // 关闭缓冲，保证崩溃前的内容一定落盘
                setvbuf(gTYLogFile, NULL, _IONBF, 0);
            }
        } @catch (NSException *e) {
            // 任何异常都不能往外抛 —— 日志不可用也必须让程序继续跑
            gTYLogFile = NULL;
            gTYLogPath = nil;
        }
        gTYLogInited = YES;
    });
}

void TYLogWrite(TYLogLevel level, NSString *format, ...) {
    if (level < gTYLogLevel) return;

    // 组装消息。format 可能为 nil（调用方疏忽），先挡一道。
    if (format == nil) format = @"(nil)";

    NSString *msg = nil;
    @try {
        va_list args;
        va_start(args, format);
        msg = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
    } @catch (NSException *e) {
        // 格式化失败就用格式串本身，绝不抛出去
        msg = format;
    }
    if (msg == nil) msg = @"(format failed)";

    const char *levelTag = "INFO ";
    switch (level) {
        case TYLogLevelDebug: levelTag = "DEBUG"; break;
        case TYLogLevelInfo:  levelTag = "INFO "; break;
        case TYLogLevelWarn:  levelTag = "WARN "; break;
        case TYLogLevelError: levelTag = "ERROR"; break;
    }

    NSString *line = nil;
    @try {
        line = [NSString stringWithFormat:@"[%@][%s] %@",
                TYLogFormatter() ? [TYLogFormatter() stringFromDate:[NSDate date]] : @"--:--:--.---",
                levelTag, msg];
    } @catch (NSException *e) {
        line = [NSString stringWithFormat:@"[%s] %@", levelTag, msg];
    }
    if (line == nil) return;

    // --- 内存环 ---
    os_unfair_lock_lock(&gTYLogLock);
    if (gTYLogRing) {
        if (gTYLogRing.count >= kTYLogRingCapacity) {
            [gTYLogRing removeObjectAtIndex:0];
        }
        [gTYLogRing addObject:line];
    }
    gTYLogTotal++;

    // --- 文件 ---
    if (gTYLogFile) {
        // 用 fwrite 直接写 UTF-8，避免 NSString 方法可能抛的异常
        const char *c = line.UTF8String;
        if (c) {
            fwrite(c, 1, strlen(c), gTYLogFile);
            fwrite("\n", 1, 1, gTYLogFile);
        }
    }
    // 锁内取一份 sink 强引用，unlock 后再回调，避免持锁回调与 set 竞争。
    TYLogSink sink = gTYLogSink;
    os_unfair_lock_unlock(&gTYLogLock);

    // --- 云端回调（锁外，@try 隔离，绝不因 sink 异常影响游戏） ---
    if (sink) {
        @try {
            sink(level, line, [[NSDate date] timeIntervalSince1970]);
        } @catch (NSException *e) { /* 忽略 */ }
    }

    // --- 系统日志 ---
    // 放在最后：NSLog 在极端早期可能有问题，但它挂了也只影响自己。
    NSLog(@"[TaoYao]%@", line);
}

NSArray<NSString *> *TYLogRecent(NSUInteger count) {
    os_unfair_lock_lock(&gTYLogLock);
    NSArray *copy = nil;
    if (gTYLogRing) {
        NSUInteger n = MIN(count, gTYLogRing.count);
        copy = [gTYLogRing subarrayWithRange:NSMakeRange(gTYLogRing.count - n, n)];
    }
    os_unfair_lock_unlock(&gTYLogLock);
    return copy ?: @[];
}

NSUInteger TYLogTotalCount(void) {
    os_unfair_lock_lock(&gTYLogLock);
    NSUInteger n = gTYLogTotal;
    os_unfair_lock_unlock(&gTYLogLock);
    return n;
}

NSString *TYLogFilePath(void) {
    return gTYLogPath;
}

void TYLogClear(void) {
    os_unfair_lock_lock(&gTYLogLock);
    [gTYLogRing removeAllObjects];
    gTYLogTotal = 0;
    os_unfair_lock_unlock(&gTYLogLock);
}

void TYLogSetSink(TYLogSink sink) {
    os_unfair_lock_lock(&gTYLogLock);
    // copy：把可能的栈 block 搬到堆，长期持有；nil 即取消。
    gTYLogSink = sink ? [sink copy] : nil;
    os_unfair_lock_unlock(&gTYLogLock);
}
