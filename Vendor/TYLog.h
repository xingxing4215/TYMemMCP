//
//  TYLog.h
//  TaoYao 修复版 —— 日志模块
//
//  设计要点：日志自身必须「零依赖、可降级」。
//  原版本把 NSLog 当成唯一手段，且没有做限流；
//  一旦初始化阶段出现异常，日志也会跟着炸，形成连锁闪退。
//  这里改成：内存环形缓冲 + 文件落盘 + NSLog，三层互不影响。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 版本信息
#define TY_VERSION_STRING  @"1.0.4"
#define TY_BUILD_TAG       @"cloud"
#define TY_DISPLAY_NAME    @"桃夭"

/// 整数构建号：CI 编译时用 -DTY_BUILD_NUMBER=$GITHUB_RUN_NUMBER 覆盖，
/// 本地编译为 0。云更新（OTA）用它比较新旧，不用易出错的版本字符串。
#ifndef TY_BUILD_NUMBER
#define TY_BUILD_NUMBER 0
#endif

typedef NS_ENUM(NSInteger, TYLogLevel) {
    TYLogLevelDebug = 0,
    TYLogLevelInfo,
    TYLogLevelWarn,
    TYLogLevelError,
};

/// 初始化日志（幂等）。失败则自动降级为仅 NSLog。
void TYLogInit(void);

/// 写一条日志。等级低于当前阈值时直接丢弃。
void TYLogWrite(TYLogLevel level, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

#define TYLogDebug(fmt, ...) TYLogWrite(TYLogLevelDebug, fmt, ##__VA_ARGS__)
#define TYLogInfo(fmt, ...)  TYLogWrite(TYLogLevelInfo,  fmt, ##__VA_ARGS__)
#define TYLogWarn(fmt, ...)  TYLogWrite(TYLogLevelWarn,  fmt, ##__VA_ARGS__)
#define TYLogError(fmt, ...) TYLogWrite(TYLogLevelError, fmt, ##__VA_ARGS__)

/// 取最近 n 条日志（用于 UI 显示）
NSArray<NSString *> *TYLogRecent(NSUInteger count);

/// 日志总数
NSUInteger TYLogTotalCount(void);

/// 日志文件的绝对路径（可能为 nil）
NSString *_Nullable TYLogFilePath(void);

/// 清空日志
void TYLogClear(void);

/// 日志 sink：每条日志落环/落盘后在锁外回调一次，供云端批量回传。
/// sink 内必须极轻量（只入队），不得再调用 TYLog（会递归）、不得阻塞。
/// 传 nil 取消挂载。level 为等级，line 为已拼好的整行（含时间戳）。
typedef void (^TYLogSink)(TYLogLevel level, NSString *line, NSTimeInterval ts);
void TYLogSetSink(_Nullable TYLogSink sink);

NS_ASSUME_NONNULL_END
