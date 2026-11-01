//
//  TYIl2Cpp.h
//  TaoYao 修复版 —— il2cpp 运行时绑定
//
//  定位游戏对象一律走 il2cpp 反射 API（按 命名空间.类名 + 成员名），
//  不写死内存偏移：游戏小版本更新只要 C# 名字没变就继续可用。
//  类查找遍历域内【全部程序集镜像】，不依赖固定的 Assembly-CSharp 名。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// il2cpp 原生不透明类型
typedef void *TYIl2CppDomain;
typedef void *TYIl2CppAssembly;
typedef void *TYIl2CppImage;
typedef void *TYIl2CppClass;
typedef void *TYIl2CppObject;
typedef void *TYIl2CppMethodInfo;
typedef void *TYIl2CppFieldInfo;
typedef void *TYIl2CppType;

/// FIELD_ATTRIBUTE_STATIC
static const int TY_IL2CPP_FIELD_STATIC = 0x0010;

@interface TYIl2Cpp : NSObject

/// 是否已成功绑定
+ (BOOL)available;
/// 失败原因（日志/诊断）
+ (nullable NSString *)failureReason;
/// 已解析导出数
+ (NSUInteger)resolvedExportCount;

/// 绑定，可重复调用；已绑定直接返回 YES
+ (BOOL)setup;
/// 强制重新绑定
+ (BOOL)retrySetup;

#pragma mark - 类查询（遍历全部镜像）

/// 按 "命名空间.类名" 或 "类名" 在所有程序集镜像里查找。
/// 这是业务层首选入口（自动按最后一个 '.' 拆命名空间）。
+ (nullable TYIl2CppClass)classFullyQualified:(NSString *)fullName;

/// 按 命名空间 + 类名 查找（ns 传 nil/空 表示空命名空间）
+ (nullable TYIl2CppClass)classWithNamespace:(nullable NSString *)ns
                                        name:(NSString *)name;

/// 全部镜像名（诊断）
+ (NSArray<NSString *> *)allImageNames;

/// 取对象所属类名
+ (nullable NSString *)classNameOf:(nullable TYIl2CppObject)obj;

/// 取对象运行时类句柄（多跳导航按真实类型解析字段/方法用）
+ (nullable TYIl2CppClass)classOfObject:(nullable TYIl2CppObject)obj;

#pragma mark - 方法

/// 查方法（paramCount 用于区分重载）
+ (nullable TYIl2CppMethodInfo)methodOfClass:(TYIl2CppClass)klass
                                        name:(NSString *)name
                                  paramCount:(int)paramCount;

/// 方法是否静态（决定 runtime_invoke 的 target 传 NULL 还是实例）
+ (BOOL)methodIsStatic:(nullable TYIl2CppMethodInfo)method;

#pragma mark - 托管调用

/// 调无参方法，返回对象/装箱结果；引用类型可直接当对象指针用
+ (nullable TYIl2CppObject)invokeNoArg:(TYIl2CppMethodInfo)method
                                target:(nullable TYIl2CppObject)target;

/// 调无参 void 方法，按是否有托管异常判定成功（void 返回值本身是 NULL）
+ (BOOL)invokeNoArgSuccess:(TYIl2CppMethodInfo)method
                    target:(nullable TYIl2CppObject)target;

/// 单 float 参数。返回是否调用成功（无托管异常）
+ (BOOL)invokeWithFloat:(TYIl2CppMethodInfo)method
                 target:(nullable TYIl2CppObject)target
                  value:(float)value;

/// 单 bool 参数（il2cpp bool 按 1 字节传）
+ (BOOL)invokeWithBool:(TYIl2CppMethodInfo)method
                target:(nullable TYIl2CppObject)target
                 value:(BOOL)value;

/// 单 int 参数
+ (BOOL)invokeWithInt:(TYIl2CppMethodInfo)method
               target:(nullable TYIl2CppObject)target
                value:(int)value;

/// 单 int/枚举参数且需要返回对象（导航用：EKEHPJEIIMD(mode) 返回 NEFIDMLNEEB）
+ (nullable TYIl2CppObject)invokeIntReturning:(TYIl2CppMethodInfo)method
                                       target:(nullable TYIl2CppObject)target
                                        value:(int)value;

/// 单对象参数调用，返回对象结果。
/// 组件体系用：Component.GetComponent(System.Type) → 组件实例；
/// Component.GetComponentsInChildren(System.Type) → 组件数组。
+ (nullable TYIl2CppObject)invokeWithObject:(TYIl2CppMethodInfo)method
                                     target:(nullable TYIl2CppObject)target
                                      value:(nullable TYIl2CppObject)value;

/// 类的 System.Type 对象（作 GetComponent / AddComponent 的实参）
+ (nullable TYIl2CppObject)typeObjectOfClass:(nullable TYIl2CppClass)klass;

/// 单 Vector3（3×float 值类型）参数调用，返回装箱结构体。
/// 用于 UnityEngine.Camera.WorldToScreenPoint 等按值传结构体的接口。
+ (nullable TYIl2CppObject)invokeWithVector3:(TYIl2CppMethodInfo)method
                                      target:(nullable TYIl2CppObject)target
                                         xyz:(const float *)xyz;

/// 取装箱对象的数据指针：值类型 → 内联数据；引用类型 → 对象本身。
/// 读 runtime_invoke 返回的装箱 Vector3（3×float）等结构体用。
+ (nullable void *)unbox:(nullable TYIl2CppObject)obj;

#pragma mark - 字段

+ (nullable TYIl2CppFieldInfo)fieldOfClass:(TYIl2CppClass)klass
                                      name:(NSString *)name;
+ (ptrdiff_t)offsetOfField:(nullable TYIl2CppFieldInfo)field;
+ (BOOL)isStaticField:(nullable TYIl2CppFieldInfo)field;

/// 字段的托管类型名，如 System.Single / System.Boolean（诊断与类型校验）
+ (nullable NSString *)fieldTypeName:(nullable TYIl2CppFieldInfo)field;

/// float 字段读写（校验 System.Single）。静态字段 obj 传 NULL。
+ (BOOL)readFloatField:(TYIl2CppFieldInfo)field
                  from:(nullable TYIl2CppObject)obj
                    to:(float *)out;
+ (BOOL)writeFloatField:(TYIl2CppFieldInfo)field
                     to:(nullable TYIl2CppObject)obj
                  value:(float)value;

/// bool 字段读写（校验 System.Boolean，1 字节）。静态字段 obj 传 NULL。
+ (BOOL)readBoolField:(TYIl2CppFieldInfo)field
                 from:(nullable TYIl2CppObject)obj
                   to:(BOOL *)out;
+ (BOOL)writeBoolField:(TYIl2CppFieldInfo)field
                    to:(nullable TYIl2CppObject)obj
                 value:(BOOL)value;

/// int32 字段读写（校验 System.Int32）。静态字段 obj 传 NULL。
+ (BOOL)readInt32Field:(TYIl2CppFieldInfo)field
                  from:(nullable TYIl2CppObject)obj
                    to:(int32_t *)out;
+ (BOOL)writeInt32Field:(TYIl2CppFieldInfo)field
                     to:(nullable TYIl2CppObject)obj
                  value:(int32_t)value;

/// 读引用类型字段（guard 判空用，如 curObj）；不做标量类型校验。
+ (nullable TYIl2CppObject)objectField:(TYIl2CppFieldInfo)field
                                   from:(TYIl2CppObject)obj;

/// 读【静态】引用类型字段（全局服务定位器入口，如 IKFNJKKEJIA.OMMDMKMKBPA）
+ (nullable TYIl2CppObject)staticObjectField:(TYIl2CppFieldInfo)field;

/// 枚举字段按底层 int 读取（枚举的 il2cpp 类型名是枚举名而非 System.Int32，
/// 不能走 readInt32Field 的类型守卫）。仅用于已知枚举字段（如 JAPKKFCKGAH）。
+ (BOOL)readEnumIntField:(TYIl2CppFieldInfo)field
                    from:(nullable TYIl2CppObject)obj
                      to:(int32_t *)out;

#pragma mark - 托管数组（List<T> 遍历用）

/// 托管数组长度；非数组或导出缺失返回 0
+ (uintptr_t)arrayLengthOf:(nullable TYIl2CppObject)array;

/// 取引用类型数组下标元素（如 List 内部 T[]、List<DIGLCECMPAB> 的 _items）
+ (nullable TYIl2CppObject)arrayElementAt:(nullable TYIl2CppObject)array
                                    index:(uintptr_t)idx;

#pragma mark - 按镜像精确找类（云探针 / HybridCLR）

/// 只在指定镜像名（如 UpdateScript_500.dll）内找类；找不到返回 NULL。
+ (nullable TYIl2CppClass)classInImageNamed:(NSString *)imageName
                                         ns:(nullable NSString *)ns
                                       name:(NSString *)name;

#pragma mark - 成员枚举（云调试探针，导出缺失时返回空）

/// 类的全部字段：每项 {name:NSString*, type:NSString*, static:NSNumber*}
+ (NSArray<NSDictionary *> *)fieldsOfClass:(TYIl2CppClass)klass;
/// 类的全部方法：每项 {name:NSString*, argc:NSNumber*}
+ (NSArray<NSDictionary *> *)methodsOfClass:(TYIl2CppClass)klass;

#pragma mark - 镜像类枚举（热更混淆名整体重排时，按结构指纹重建锚点）

/// 镜像是否可按索引枚举类（il2cpp_image_get_class(_count) 导出存在）
+ (BOOL)imageClassEnumerationAvailable;
/// 镜像内全部类（每项包装 class 指针的 NSValue）；导出缺失返回 nil
+ (nullable NSArray<NSValue *> *)classesInImageNamed:(NSString *)imageName;
/// 镜像内类名+命名空间清单：每项 {name, ns}；nameRegex 非空时仅返回匹配类
+ (NSArray<NSDictionary *> *)classNamesInImageNamed:(NSString *)imageName
                                          nameRegex:(nullable NSString *)nameRegex;
/// 全镜像反向扫描：找字段类型名（去掉命名空间后）等于 typeName 的全部字段。
/// 返回每项 {class, ns, field, static, type}，供混淆重排后反查引用关系。
+ (NSArray<NSDictionary *> *)scanFieldsInImageNamed:(NSString *)imageName
                                           typeNamed:(NSString *)typeName;
/// 类的方法签名详情：{name, argc, ret, params:[类型名...]}
+ (NSArray<NSDictionary *> *)methodsDetailOfClass:(TYIl2CppClass)klass;

#pragma mark - Unity 对象查找

/// 用 UnityEngine.Object.FindObjectOfType(Type[,bool]) 取一个组件实例。
/// 用于没有 get_instance 的 MonoBehaviour 单例（如秒互动控制器）。
/// 仅当该类已注册进 il2cpp domain 时有效——这正是探针要验证的前提。
+ (nullable TYIl2CppObject)findUnityObjectOfClass:(TYIl2CppClass)klass
                                   includeInactive:(BOOL)includeInactive;

#pragma mark - 单例

/// 通过候选 getter（get_instance/current/instance...）取类单例对象
+ (nullable TYIl2CppObject)singletonOfClass:(TYIl2CppClass)klass
                                getterNames:(NSArray<NSString *> *)names;

#pragma mark - 诊断

+ (NSString *)dumpBinding;

@end

NS_ASSUME_NONNULL_END
