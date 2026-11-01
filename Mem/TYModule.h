//
//  TYModule.h
//  TYMemMCP —— 模块（dyld image）枚举与地址反查
//
//  与 MT-MCP 的 list_modules / image_lookup_addr 对齐：
//  给出运行时地址属于哪个模块、模块内偏移是多少。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TYModuleInfo : NSObject
@property (nonatomic, copy)   NSString *name;        ///< 文件名
@property (nonatomic, copy)   NSString *path;        ///< 完整路径
@property (nonatomic, assign) uint64_t base;         ///< 运行时基址（__TEXT 装载地址）
@property (nonatomic, assign) uint64_t size;         ///< __TEXT vmsize
@property (nonatomic, assign) uint64_t fileBase;     ///< 首选装载地址（vmaddr）
@property (nonatomic, assign) intptr_t slide;        ///< dyld slide
@property (nonatomic, assign) uint32_t index;
@property (nonatomic, assign) BOOL isSystem;         ///< 是否系统库
@property (nonatomic, copy)   NSArray<NSDictionary *> *segments;  ///< 各段 {name,addr,size,prot}
@property (nonatomic, readonly) uint64_t end;
@property (nonatomic, readonly, copy) NSString *uuid;  ///< LC_UUID
- (NSDictionary *)dictionaryRepresentation;
@end

@interface TYModule : NSObject
+ (instancetype)shared;

/// 全部已加载模块（含系统库）
- (NSArray<TYModuleInfo *> *)allModules;

/// 按名称/路径子串过滤；includeSystem=NO 时排除 /usr/lib、/System 等
- (NSArray<TYModuleInfo *> *)modulesMatching:(nullable NSString *)filter
                               includeSystem:(BOOL)includeSystem;

/// 按名称精确/前缀找模块
- (nullable TYModuleInfo *)moduleNamed:(NSString *)name;

/// 地址反查：返回 {module, base, offset, segment}
- (nullable NSDictionary *)lookupAddress:(uint64_t)addr;

/// 异步模块加载通知（热更 DLL 后模块表会变）
- (void)startWatching;
@end

NS_ASSUME_NONNULL_END
