//
//  TYIl2CppBridge.h
//  TYMemMCP —— il2cpp 反射层（复用 TaoYao 的 TYIl2Cpp 绑定）
//
//  ═══════════════════════════════════════════════════════════════════════
//  为什么复用而不是重写
//  ═══════════════════════════════════════════════════════════════════════
//
//  TYIl2Cpp 已经处理了几个必须踩过才知道的坑：
//
//  1) **绝不主动 dlopen UnityFramework**，只用 RTLD_NOLOAD 探测是否已加载。
//     Unity 的加载顺序一旦被改变，会在 main() 之前崩，且现场极难复现。
//  2) 类查找遍历**域内全部程序集镜像**，不假定 Assembly-CSharp 这个名字
//     （HybridCLR 热更后程序集名是 UpdateScript_500.dll 之类）。
//  3) 字段读写带**声明类型守卫**（System.Single / System.Boolean / System.Int32），
//     避免拿 float 解释一个 int 字段写出脏值。
//  4) 枚举字段不能走 readInt32Field（il2cpp 里枚举类型名是枚举名本身），
//     单独走 readEnumIntField。
//
//  本层只做一件事：把 TYIl2Cpp 的能力包装成 MCP 工具所需的
//  「按名字查询 / 读字段 / 走引用链」三组操作，并统一错误回报。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TYIl2CppBridge : NSObject
+ (instancetype)shared;

/// il2cpp 是否可用（未就绪时所有查询返回 ok=NO）
- (BOOL)available;
- (nullable NSString *)failureReason;

#pragma mark - 类查询

/// 全部镜像名
- (NSArray<NSString *> *)imageNames;

/// 按 "命名空间.类名" 或 "类名" 查类；返回 {ok, found, class, ns, name}
- (NSDictionary *)findClass:(NSString *)fullName image:(nullable NSString *)image;

/// 列出某镜像内的类名（可正则过滤）
- (NSDictionary *)listClassesInImage:(NSString *)image
                               regex:(nullable NSString *)regex
                               limit:(NSUInteger)limit;

/// 类的字段清单（名/类型/是否静态/偏移）
- (NSDictionary *)fieldsOfClass:(NSString *)fullName image:(nullable NSString *)image;

/// 类的方法清单
- (NSDictionary *)methodsOfClass:(NSString *)fullName image:(nullable NSString *)image;

/// 全镜像反向扫描：哪些类的字段类型是 typeName（混淆名重排后重建锚点）
- (NSDictionary *)findFieldsOfType:(NSString *)typeName
                             image:(nullable NSString *)image
                             limit:(NSUInteger)limit;

#pragma mark - 字段读写

/// 读字段。params: {class, ns?, image?, field, from?:{...}, type?}
/// from 为空时读静态字段；否则按 from 描述走引用链拿到实例再读。
- (NSDictionary *)readField:(NSDictionary *)p;

/// 写字段（同 readField 定位方式）
- (NSDictionary *)writeField:(NSDictionary *)p;

#pragma mark - 引用链导航

/// 按 target 描述走引用链，返回每一跳的真实类型。
/// target: {class, ns?, image?, root:{field, static?, instance_getter?}, path:[{field}|{invoke,arg}]}
- (NSDictionary *)navigate:(NSDictionary *)target;

/// 静态字段当前值（引用类型）
- (nullable void *)staticObjectOfClass:(NSString *)fullName
                                 field:(NSString *)field
                                 image:(nullable NSString *)image;
@end

NS_ASSUME_NONNULL_END
