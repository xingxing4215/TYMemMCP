//
//  TYMem.h
//  TYMemMCP —— 内存读写层
//
//  职责：在【自己的进程内】安全地读写任意已映射地址。
//
//  ═══════════════════════════════════════════════════════════════════════
//  为什么不用 mach_vm_* 裸读
//  ═══════════════════════════════════════════════════════════════════════
//
//  iOS SDK 的 <mach/mach_vm.h> 是刻意留空的桩头（`#error mach_vm.h unsupported.`），
//  mach_vm_* 属于内核接口，不在公共 SDK 里。本层改用 <mach/vm_map.h>
//  的 vm_* 家族 —— 在自身进程内操作，它完全够用且是受支持 API。
//
//  直接裸读（无论 vm_read 还是 mach_vm_read）有两个问题：
//
//  1) 未映射地址会返回 KERN_INVALID_ADDRESS，但**跨段边界**的读会
//     部分成功、部分失败，返回值只有一个，无法知道读到了多少。
//  2) 只读页 / 守卫页 / __LINKEDIT 末尾等边界处容易出现「看起来能读，
//     实际读到空洞」的情况，若调用方拿它当有效数据会写出脏值。
//
//  本层的做法：
//    · 读之前先用 vm_region_64 把整个区间按 VM region 切开，
//      只在 VM_PROT_READ 的 region 内读；
//    · 每条 region 内再按页边界夹取，绝不跨 region 连续读；
//    · 读成功与否、实际读到多少字节，都显式回报给上层。
//
//  写入额外要求 VM_PROT_WRITE，否则直接拒绝（不尝试 mprotect 改权限，
//  那会污染宿主进程的内存布局，得不偿失）。
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_region.h>

NS_ASSUME_NONNULL_BEGIN

/// 一段内存区域描述
@interface TYMemRegion : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, assign) uint64_t size;
@property (nonatomic, assign) vm_prot_t protection;   ///< 当前权限
@property (nonatomic, assign) vm_prot_t maxProtection;
@property (nonatomic, assign) BOOL shared;
@property (nonatomic, assign) BOOL reserved;
@property (nonatomic, assign) uint32_t userTag;
@property (nonatomic, copy, nullable) NSString *segmentName;  ///< 若属某模块的段
@property (nonatomic, copy, nullable) NSString *moduleName;

/// 是否可读 / 可写 / 可执行
@property (nonatomic, readonly) BOOL readable;
@property (nonatomic, readonly) BOOL writable;
@property (nonatomic, readonly) BOOL executable;
/// "rwx" 形式
@property (nonatomic, readonly, copy) NSString *protectionString;

/// 序列化（供 MCP 响应）
- (NSDictionary *)dictionaryRepresentation;
@end

/// 一次读取的结果
@interface TYMemReadResult : NSObject
@property (nonatomic, assign) BOOL ok;
@property (nonatomic, strong, nullable) NSData *data;     ///< 实际读到的字节
@property (nonatomic, assign) uint64_t address;           ///< 请求起始地址
@property (nonatomic, assign) uint64_t requestedSize;
@property (nonatomic, assign) uint64_t bytesRead;
@property (nonatomic, assign) kern_return_t kr;
@property (nonatomic, copy, nullable) NSString *error;
/// 部分成功：前面某些 region 不可读导致空洞
@property (nonatomic, assign) BOOL partial;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *gaps;  ///< 不可读区间的起址

/// 序列化（供 MCP 响应）
- (NSDictionary *)dictionaryRepresentation;
@end

@interface TYMem : NSObject

+ (instancetype)shared;

/// 当前任务的 mach port（mach_task_self_）
@property (nonatomic, readonly) mach_port_t task;

/// 查询某地址所在的 VM region（失败返回 nil）
- (nullable TYMemRegion *)regionAt:(uint64_t)addr;

/// 枚举 [start, end) 内的所有 VM region；end=0 表示到最高地址
- (NSArray<TYMemRegion *> *)regionsFrom:(uint64_t)start to:(uint64_t)end
                                  limit:(NSUInteger)limit;

/// 读内存：自动按 region 切分，跳过不可读区间。
/// 返回 TYMemReadResult，ok=YES 表示至少读到了一些字节。
- (TYMemReadResult *)readAt:(uint64_t)addr size:(uint64_t)size;

/// 写内存：要求目标页 VM_PROT_WRITE，否则拒绝。
- (BOOL)writeAt:(uint64_t)addr data:(NSData *)data error:(NSString *_Nullable *_Nullable)err;

/// 地址是否落在任一已映射、可读的 region 内
- (BOOL)isReadable:(uint64_t)addr;

/// 便捷读标量（小端）
- (BOOL)readU64At:(uint64_t)addr value:(uint64_t *)out;
- (BOOL)readU32At:(uint64_t)addr value:(uint32_t *)out;
- (BOOL)readFloatAt:(uint64_t)addr value:(float *)out;
- (BOOL)readDoubleAt:(uint64_t)addr value:(double *)out;

/// 把指针跟随 depth 次（读 8 字节解引用），返回最终地址。
/// 中间任一步不可读即失败。
- (BOOL)followPointers:(uint64_t)addr depth:(int)depth out:(uint64_t *)out;

@end

NS_ASSUME_NONNULL_END
