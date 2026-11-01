//
//  TYScan.h
//  TYMemMCP —— 内存搜索层
//
//  能力：
//    · 精确值搜索（整型 / 浮点 / 字符串），支持对齐、区间、可写页过滤
//    · 结果二次筛选（改值后再搜，缩小范围）
//    · 多级指针链解析（基址 + [offset...] → 最终地址）
//    · 指针扫描（找出所有指向某地址的指针，构建稳定路径）
//
//  设计取舍：搜索在**后台串行队列**执行，逐 region 分段读、分段比对，
//  不一次性把整个地址空间读进内存（Unity 进程常有几百 MB 可读页）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 数值类型
typedef NS_ENUM(NSInteger, TYScanType) {
    TYScanI8 = 0, TYScanI16, TYScanI32, TYScanI64,
    TYScanU8, TYScanU16, TYScanU32, TYScanU64,
    TYScanF32, TYScanF64,
    TYScanBytes,      ///< 十六进制字节串
    TYScanUtf8,       ///< UTF-8 字符串
    TYScanUtf16,      ///< UTF-16LE 字符串
};

@interface TYScanResult : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, copy,   nullable) NSString *moduleName;   ///< 若属某模块
@property (nonatomic, copy,   nullable) NSString *preview;      ///< 附近字节预览
- (NSDictionary *)dictionaryRepresentation;
@end

@interface TYScan : NSObject
+ (instancetype)shared;

/// 解析类型名（i32 / u64 / f32 / utf8 / bytes …）
+ (TYScanType)typeFromName:(nullable NSString *)name;

/// 精确值搜索。
///   value     —— 数值（NSNumber）或字符串（NSString）或 hex（NSString @"0A 0B"）
///   type      —— 见 TYScanType
///   start/end —— 地址区间；end=0 表示到最高地址
///   writableOnly —— 只搜可写页（找游戏状态变量时常用）
///   aligned   —— 按类型宽度对齐
///   maxResults—— 命中上限（默认 2000，防爆内存）
- (NSArray<TYScanResult *> *)scanValue:(id)value
                                  type:(TYScanType)type
                             startAddr:(uint64_t)start
                               endAddr:(uint64_t)end
                          writableOnly:(BOOL)writableOnly
                               aligned:(BOOL)aligned
                            maxResults:(NSUInteger)maxResults;

/// 对上一次结果做筛选：只保留当前值仍 == value 的地址
- (NSArray<TYScanResult *> *)refineResults:(NSArray<TYScanResult *> *)prev
                                     value:(id)value
                                      type:(TYScanType)type;

/// 读取一批地址的当前值（用于「变了/没变」比较）
- (NSArray<NSDictionary *> *)readValues:(NSArray<TYScanResult *> *)addrs
                                   type:(TYScanType)type;

/// 指针链解析：base + offsets[] → 最终地址；返回 {ok, address, steps[]}
- (NSDictionary *)resolvePointerChain:(uint64_t)base
                              offsets:(NSArray<NSNumber *> *)offsets;

/// 指针扫描：在可写/可读页里找出所有「值 == target」的 8 字节指针
- (NSArray<TYScanResult *> *)findPointersTo:(uint64_t)target
                                  startAddr:(uint64_t)start
                                    endAddr:(uint64_t)end
                                 maxResults:(NSUInteger)maxResults
                                       limit:(NSUInteger)scanLimit;
@end

NS_ASSUME_NONNULL_END
