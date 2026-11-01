//
//  TYMemLog.h
//  TYMemMCP —— 日志门面
//
//  直接复用 TaoYao 的 TYLog（避免符号冲突，也不重复实现沙盒落盘/截断逻辑）。
//  本文件只提供本工程惯用的 TYMLog 宏名，内部转发到 TYLogWrite。
//

#import <Foundation/Foundation.h>
#import "TYLog.h"

#define TYMLog(fmt, ...)   TYLogWrite(TYLogLevelInfo,  @"[memmcp] " fmt, ##__VA_ARGS__)
#define TYMLogW(fmt, ...)  TYLogWrite(TYLogLevelWarn,  @"[memmcp] " fmt, ##__VA_ARGS__)
#define TYMLogE(fmt, ...)  TYLogWrite(TYLogLevelError, @"[memmcp] " fmt, ##__VA_ARGS__)

/// 本工程日志文件路径（即 TaoYao 日志，同进程共用一份）
FOUNDATION_EXPORT NSString *TYMLogPath(void);
