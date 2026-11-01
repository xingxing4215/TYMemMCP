//
//  TYIl2Cpp.m
//  TaoYao 修复版 —— il2cpp 运行时绑定实现
//
//  关键约定（均为现代 il2cpp C ABI，经对照可用插件确认）：
//    · 实例字段：il2cpp_field_get_value(obj, field, &out)
//                il2cpp_field_set_value(obj, field, &val)   —— obj 在前
//    · 静态字段：il2cpp_field_static_get_value(field, &out)
//    · runtime_invoke(method, target, void** params, void** exc)
//                值类型参数 params[i] 指向该值；bool 用 1 字节
//    · 类查找遍历 domain 内全部 assemblies 的 image，不写死程序集名
//

#import "TYIl2Cpp.h"
#import "TYLog.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <string.h>

#pragma mark - 导出函数签名

typedef void *(*fn_domain_get)(void);
typedef const void **(*fn_domain_get_assemblies)(void *domain, size_t *count);
typedef void *(*fn_assembly_get_image)(const void *assembly);
typedef const char *(*fn_image_get_name)(const void *image);
typedef void *(*fn_domain_assembly_open)(void *domain, const char *name);
typedef const char *(*fn_class_get_name)(void *klass);
typedef const char *(*fn_class_get_namespace)(void *klass);
typedef void *(*fn_class_from_name)(void *image, const char *ns, const char *name);
typedef void *(*fn_class_get_method_from_name)(void *klass, const char *name, int argc);
typedef void *(*fn_class_get_field_from_name)(void *klass, const char *name);
typedef void *(*fn_field_get_type)(void *field);
typedef size_t (*fn_field_get_offset)(void *field);
typedef int (*fn_field_get_flags)(void *field);
typedef void (*fn_field_get_value)(void *obj, void *field, void *out);
typedef void (*fn_field_set_value)(void *obj, void *field, void *val);
typedef void (*fn_field_static_get_value)(void *field, void *out);
typedef void (*fn_field_static_set_value)(void *field, void *val);
typedef void *(*fn_runtime_invoke)(void *method, void *obj, void **params, void **exc);
typedef void *(*fn_object_get_class)(void *obj);
typedef void *(*fn_object_unbox)(void *obj);
typedef void *(*fn_thread_attach)(void *domain);
typedef char *(*fn_type_get_name)(void *type);
typedef void (*fn_free)(void *ptr);
// —— 云探针 / 对象查找（全部可选，缺失时探针返回空、查找返回 NULL） ——
typedef void *(*fn_class_get_fields)(void *klass, void **iter);
typedef void *(*fn_class_get_methods)(void *klass, void **iter);
typedef const char *(*fn_field_get_name)(void *field);
typedef const char *(*fn_method_get_name)(void *method);
typedef unsigned int (*fn_method_get_param_count)(void *method);
typedef uint32_t (*fn_method_get_flags)(void *method, uint32_t *iflags);
typedef void *(*fn_class_get_type)(void *klass);
typedef void *(*fn_type_get_object)(void *type);
// —— 安全对象枚举（按 AOT 基类 UnityEngine.Object 枚举，再在 il2cpp 层过滤） ——
typedef uintptr_t (*fn_array_length)(void *array);
typedef void *(*fn_array_addr_with_size)(void *array, int32_t size, uintptr_t idx);
typedef void *(*fn_class_get_parent)(void *klass);
typedef int8_t (*fn_class_is_assignable_from)(void *klass, void *oklass);
// —— 镜像类枚举 / 方法签名（均可选，缺失时枚举类探针降级报错） ——
typedef size_t (*fn_image_get_class_count)(const void *image);
typedef const void *(*fn_image_get_class)(const void *image, size_t index);
typedef const void *(*fn_method_get_return_type)(const void *method);
typedef const void *(*fn_method_get_param)(const void *method, uint32_t index);

typedef struct { const char *name; void **slot; BOOL required; } TYExport;

#pragma mark - 全局状态

static void *gHandle = NULL;
static void *gDomain = NULL;
static BOOL gAvailable = NO;
static NSString *gReason = nil;
static NSUInteger gResolved = 0;

static fn_domain_get                    p_domain_get;
static fn_domain_get_assemblies         p_domain_get_assemblies;
static fn_assembly_get_image            p_assembly_get_image;
static fn_image_get_name                p_image_get_name;
static fn_domain_assembly_open          p_domain_assembly_open;
static fn_class_get_name                p_class_get_name;
static fn_class_get_namespace           p_class_get_namespace;
static fn_class_from_name               p_class_from_name;
static fn_class_get_method_from_name    p_class_get_method_from_name;
static fn_class_get_field_from_name     p_class_get_field_from_name;
static fn_field_get_type                p_field_get_type;
static fn_field_get_offset              p_field_get_offset;
static fn_field_get_flags               p_field_get_flags;
static fn_field_get_value               p_field_get_value;
static fn_field_set_value               p_field_set_value;
static fn_field_static_get_value        p_field_static_get_value;
static fn_field_static_set_value        p_field_static_set_value;
static fn_runtime_invoke                p_runtime_invoke;
static fn_object_get_class              p_object_get_class;
static fn_object_unbox                  p_object_unbox;
static fn_thread_attach                 p_thread_attach;
static fn_type_get_name                p_type_get_name;
static fn_free                          p_free;
static fn_class_get_fields              p_class_get_fields;
static fn_class_get_methods             p_class_get_methods;
static fn_field_get_name                p_field_get_name;
static fn_method_get_name               p_method_get_name;
static fn_method_get_param_count        p_method_get_param_count;
static fn_method_get_flags              p_method_get_flags;
static fn_class_get_type                  p_class_get_type;
static fn_type_get_object                 p_type_get_object;
static fn_array_length                    p_array_length;
static fn_array_addr_with_size            p_array_addr_with_size;
static fn_class_get_parent                p_class_get_parent;
static fn_class_is_assignable_from        p_class_is_assignable_from;
static fn_image_get_class_count           p_image_get_class_count;
static fn_image_get_class                 p_image_get_class;
static fn_method_get_return_type          p_method_get_return_type;
static fn_method_get_param                p_method_get_param;

#pragma mark - UnityFramework 探测

static void *TYOpenUnity(void) {
    // 只查是否已加载（RTLD_NOLOAD），绝不主动 dlopen 改变 Unity 加载顺序。
    //
    // ★ 本地修正（TYMemMCP）：原实现只试 "UnityFramework" 与
    //   "@rpath/UnityFramework.framework/UnityFramework" 两个候选，
    //   但 RTLD_NOLOAD 要求**精确匹配**已加载镜像的 install name。
    //   实测 UnityFramework 的 install name 是
    //       @executable_path/Frameworks/UnityFramework.framework/UnityFramework
    //   两个候选都匹配不上 → 永远返回 NULL → il2cpp 不可用。
    //   证据：插件启动日志里等 il2cpp 正好卡满 300 秒超时。
    //
    //   修正办法：先用 dlsym(RTLD_DEFAULT, ...) 做全局符号查找
    //   （不关心镜像名叫什么），再兜底遍历 dyld 镜像按真实路径打开。

    // 1) 全局符号查找：最可靠
    if (dlsym(RTLD_DEFAULT, "il2cpp_domain_get")) return RTLD_DEFAULT;

    // 2) 遍历已加载镜像，按真实路径打开
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm || !strstr(nm, "UnityFramework")) continue;
        void *h = dlopen(nm, RTLD_NOW | RTLD_NOLOAD);
        if (h) return h;
    }

    // 3) 原候选（保留，某些环境下列表形式可能命中）
    const char *cands[] = {
        "UnityFramework",
        "@rpath/UnityFramework.framework/UnityFramework",
        NULL,
    };
    for (int i = 0; cands[i]; i++) {
        void *h = dlopen(cands[i], RTLD_NOW | RTLD_NOLOAD);
        if (h) return h;
    }
    return NULL;
}

static BOOL TYResolve(void *handle) {
    TYExport t[] = {
        {"il2cpp_domain_get",                   (void **)&p_domain_get, YES},
        {"il2cpp_domain_get_assemblies",        (void **)&p_domain_get_assemblies, YES},
        {"il2cpp_assembly_get_image",           (void **)&p_assembly_get_image, YES},
        {"il2cpp_image_get_name",               (void **)&p_image_get_name, YES},
        {"il2cpp_domain_assembly_open",         (void **)&p_domain_assembly_open, NO},
        {"il2cpp_class_get_name",               (void **)&p_class_get_name, NO},
        {"il2cpp_class_get_namespace",          (void **)&p_class_get_namespace, NO},
        {"il2cpp_class_from_name",              (void **)&p_class_from_name, YES},
        {"il2cpp_class_get_method_from_name",   (void **)&p_class_get_method_from_name, YES},
        {"il2cpp_class_get_field_from_name",    (void **)&p_class_get_field_from_name, YES},
        {"il2cpp_field_get_type",               (void **)&p_field_get_type, YES},
        {"il2cpp_field_get_offset",             (void **)&p_field_get_offset, YES},
        {"il2cpp_field_get_flags",              (void **)&p_field_get_flags, YES},
        {"il2cpp_field_get_value",              (void **)&p_field_get_value, YES},
        {"il2cpp_field_set_value",              (void **)&p_field_set_value, YES},
        {"il2cpp_field_static_get_value",       (void **)&p_field_static_get_value, NO},
        {"il2cpp_field_static_set_value",       (void **)&p_field_static_set_value, NO},
        {"il2cpp_runtime_invoke",               (void **)&p_runtime_invoke, YES},
        {"il2cpp_object_get_class",             (void **)&p_object_get_class, YES},
        {"il2cpp_object_unbox",                 (void **)&p_object_unbox, NO},
        {"il2cpp_thread_attach",                (void **)&p_thread_attach, YES},
        {"il2cpp_type_get_name",                  (void **)&p_type_get_name, YES},
        {"il2cpp_free",                         (void **)&p_free, NO},
        // 以下可选：仅云探针/FindObjectOfType 用到，缺失不影响主功能绑定
        {"il2cpp_class_get_fields",             (void **)&p_class_get_fields, NO},
        {"il2cpp_class_get_methods",            (void **)&p_class_get_methods, NO},
        {"il2cpp_field_get_name",               (void **)&p_field_get_name, NO},
        {"il2cpp_method_get_name",              (void **)&p_method_get_name, NO},
        {"il2cpp_method_get_param_count",       (void **)&p_method_get_param_count, NO},
        {"il2cpp_method_get_flags",             (void **)&p_method_get_flags, NO},
        {"il2cpp_class_get_type",              (void **)&p_class_get_type, NO},
        {"il2cpp_type_get_object",             (void **)&p_type_get_object, NO},
        {"il2cpp_array_length",                (void **)&p_array_length, NO},
        {"il2cpp_array_addr_with_size",        (void **)&p_array_addr_with_size, NO},
        {"il2cpp_class_get_parent",            (void **)&p_class_get_parent, NO},
        {"il2cpp_class_is_assignable_from",    (void **)&p_class_is_assignable_from, NO},
        {"il2cpp_image_get_class_count",       (void **)&p_image_get_class_count, NO},
        {"il2cpp_image_get_class",             (void **)&p_image_get_class, NO},
        {"il2cpp_method_get_return_type",      (void **)&p_method_get_return_type, NO},
        {"il2cpp_method_get_param",            (void **)&p_method_get_param, NO},
    };
    NSUInteger got = 0;
    NSMutableArray *missing = [NSMutableArray array];
    size_t n = sizeof(t) / sizeof(t[0]);
    for (size_t i = 0; i < n; i++) {
        void *s = dlsym(handle, t[i].name);
        *t[i].slot = s;
        if (s) { got++; }
        else if (t[i].required) [missing addObject:@(t[i].name)];
    }
    gResolved = got;
    if (missing.count) {
        gReason = [NSString stringWithFormat:@"缺少必需导出: %@",
                   [missing componentsJoinedByString:@","]];
        return NO;
    }
    return YES;
}

#pragma mark - 镜像遍历

@interface TYIl2Cpp ()
/// 取 domain 并确保线程已 attach（内部方法，先声明供 allImageNames 前置调用）
+ (BOOL)ensureDomain;
@end

/// 枚举域内全部 image，回调返回 YES 提前结束
static void TYEnumerateImages(void (^block)(TYIl2CppImage image, const char *name, BOOL *stop)) {
    if (!gDomain || !p_domain_get_assemblies || !p_assembly_get_image) return;
    size_t count = 0;
    const void **asms = p_domain_get_assemblies(gDomain, &count);
    if (!asms) return;
    BOOL stop = NO;
    for (size_t i = 0; i < count && !stop; i++) {
        if (!asms[i]) continue;
        void *img = p_assembly_get_image((void *)asms[i]);
        if (!img) continue;
        const char *nm = p_image_get_name ? p_image_get_name(img) : NULL;
        block(img, nm, &stop);
    }
}

/// Il2CppType* → 类型名字符串（调用方无需 free）
static NSString *TYTypeNameOf(const void *t) {
    if (!t || !p_type_get_name) return nil;
    char *p = p_type_get_name((void *)t);
    if (!p) return nil;
    NSString *s = @(p);
    if (p_free) p_free(p);
    return s;
}

/// 按镜像名（不带扩展名、大小写不敏感）取 image 句柄
static const void *TYImageNamed(NSString *imageName) {
    if (!imageName.length || !gDomain) return NULL;
    NSString *want = [imageName stringByDeletingPathExtension].lowercaseString;
    __block const void *found = NULL;
    TYEnumerateImages(^(TYIl2CppImage img, const char *iname, BOOL *stop) {
        if (!iname) return;
        NSString *have = [@(iname) stringByDeletingPathExtension].lowercaseString;
        if ([have isEqualToString:want]) { found = img; *stop = YES; }
    });
    return found;
}

@implementation TYIl2Cpp

+ (BOOL)available { return gAvailable; }
+ (NSString *)failureReason { return gReason; }
+ (NSUInteger)resolvedExportCount { return gResolved; }

+ (BOOL)setup {
    if (gAvailable) return YES;
    return [self retrySetup];
}

+ (BOOL)retrySetup {
    @try {
        void *h = TYOpenUnity();
        if (!h) { gReason = @"UnityFramework 尚未加载（等待中）"; gAvailable = NO; return NO; }
        gHandle = h;

        if (!TYResolve(h)) { gAvailable = NO; return NO; }

        gDomain = p_domain_get();
        if (!gDomain) { gReason = @"il2cpp domain 尚未就绪"; gAvailable = NO; return NO; }

        // 无条件 attach 当前线程（重复 attach 幂等），保证后续反射调用有效
        if (p_thread_attach) p_thread_attach(gDomain);

        gAvailable = YES;
        gReason = nil;
        return YES;
    } @catch (NSException *e) {
        gReason = [NSString stringWithFormat:@"setup 异常: %@", e.reason];
        gAvailable = NO;
        return NO;
    }
}

#pragma mark - 类查询

+ (NSArray<NSString *> *)allImageNames {
    NSMutableArray *out = [NSMutableArray array];
    if (![self ensureDomain]) return out;
    TYEnumerateImages(^(TYIl2CppImage img, const char *name, BOOL *stop) {
        if (name) [out addObject:@(name)];
    });
    return out;
}

/// 取 domain 并确保线程已 attach
+ (BOOL)ensureDomain {
    if (gDomain) return YES;
    if (!p_domain_get) return NO;
    gDomain = p_domain_get();
    if (gDomain && p_thread_attach) p_thread_attach(gDomain);
    return gDomain != NULL;
}

+ (TYIl2CppClass)classWithNamespace:(NSString *)ns name:(NSString *)name {
    if (!gAvailable || !name.length || ![self ensureDomain]) return NULL;
    const char *cns = ns.length ? ns.UTF8String : "";
    const char *cnm = name.UTF8String;
    __block void *found = NULL;
    TYEnumerateImages(^(TYIl2CppImage img, const char *imgName, BOOL *stop) {
        void *k = p_class_from_name(img, cns, cnm);
        if (k) { found = k; *stop = YES; }
    });
    return found;
}

+ (TYIl2CppClass)classFullyQualified:(NSString *)fullName {
    if (!fullName.length) return NULL;
    NSRange dot = [fullName rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location > 0) {
        NSString *ns = [fullName substringToIndex:dot.location];
        NSString *nm = [fullName substringFromIndex:dot.location + 1];
        void *k = [self classWithNamespace:ns name:nm];
        if (k) return k;
    }
    return [self classWithNamespace:nil name:fullName];
}

+ (TYIl2CppClass)classInImageNamed:(NSString *)imageName
                                 ns:(NSString *)ns
                               name:(NSString *)name {
    if (!gAvailable || !name.length || !imageName.length || ![self ensureDomain]) return NULL;
    const char *cns = ns.length ? ns.UTF8String : "";
    const char *cnm = name.UTF8String;
    const void *img = TYImageNamed(imageName);   // 兼容镜像名带不带 .dll
    if (!img) return NULL;
    return p_class_from_name((void *)img, cns, cnm);
}

+ (NSString *)classNameOf:(TYIl2CppObject)obj {
    if (!obj || !p_object_get_class || !p_class_get_name) return nil;
    @try {
        void *k = p_object_get_class(obj);
        if (!k) return nil;
        const char *n = p_class_get_name(k);
        return n ? @(n) : nil;
    } @catch (NSException *e) { return nil; }
}

+ (TYIl2CppClass)classOfObject:(TYIl2CppObject)obj {
    if (!obj || !p_object_get_class) return NULL;
    @try { return p_object_get_class(obj); }
    @catch (NSException *e) { return NULL; }
}

#pragma mark - 方法 / 调用

+ (TYIl2CppMethodInfo)methodOfClass:(TYIl2CppClass)klass
                               name:(NSString *)name
                         paramCount:(int)paramCount {
    if (!klass || !name.length || !p_class_get_method_from_name) return NULL;
    @try {
        return p_class_get_method_from_name(klass, name.UTF8String, paramCount);
    } @catch (NSException *e) { return NULL; }
}

+ (BOOL)methodIsStatic:(TYIl2CppMethodInfo)method {
    if (!method || !p_method_get_flags) return NO;
    @try {
        // 出参用真实栈变量（1.13 逆向导证明：il2cpp 实现首条即 cbz x1 跳过写回，
        // 传 NULL 不会崩；但按 ABI 约定仍传合法指针，避免换引擎版本踩坑）。
        uint32_t iflags = 0;
        // METHOD_ATTRIBUTE_STATIC = 0x0010
        return (p_method_get_flags(method, &iflags) & 0x0010u) != 0;
    } @catch (NSException *e) { return NO; }
}

+ (TYIl2CppObject)invokeNoArg:(TYIl2CppMethodInfo)method
                       target:(TYIl2CppObject)target {
    if (!method || !p_runtime_invoke) return NULL;
    @try {
        void *exc = NULL;
        void *r = p_runtime_invoke(method, target, NULL, &exc);
        return exc ? NULL : r;
    } @catch (NSException *e) { return NULL; }
}

+ (BOOL)invokeNoArgSuccess:(TYIl2CppMethodInfo)method
                    target:(TYIl2CppObject)target {
    if (!method || !p_runtime_invoke) return NO;
    @try {
        void *exc = NULL;
        p_runtime_invoke(method, target, NULL, &exc);
        return exc == NULL;
    } @catch (NSException *e) { return NO; }
}

+ (BOOL)invokeWithFloat:(TYIl2CppMethodInfo)method
                 target:(TYIl2CppObject)target
                  value:(float)value {
    if (!method || !p_runtime_invoke) return NO;
    if (isnan(value) || isinf(value)) return NO;
    @try {
        void *args[1] = { &value };
        void *exc = NULL;
        p_runtime_invoke(method, target, args, &exc);
        return exc == NULL;
    } @catch (NSException *e) { return NO; }
}

+ (BOOL)invokeWithBool:(TYIl2CppMethodInfo)method
                target:(TYIl2CppObject)target
                 value:(BOOL)value {
    if (!method || !p_runtime_invoke) return NO;
    @try {
        int8_t b = value ? 1 : 0;   // il2cpp System.Boolean 占 1 字节
        void *args[1] = { &b };
        void *exc = NULL;
        p_runtime_invoke(method, target, args, &exc);
        return exc == NULL;
    } @catch (NSException *e) { return NO; }
}

+ (BOOL)invokeWithInt:(TYIl2CppMethodInfo)method
               target:(TYIl2CppObject)target
                value:(int)value {
    if (!method || !p_runtime_invoke) return NO;
    @try {
        void *args[1] = { &value };
        void *exc = NULL;
        p_runtime_invoke(method, target, args, &exc);
        return exc == NULL;
    } @catch (NSException *e) { return NO; }
}

+ (TYIl2CppObject)invokeIntReturning:(TYIl2CppMethodInfo)method
                              target:(TYIl2CppObject)target
                               value:(int)value {
    if (!method || !p_runtime_invoke) return NULL;
    @try {
        void *args[1] = { &value };
        void *exc = NULL;
        void *r = p_runtime_invoke(method, target, args, &exc);
        return exc ? NULL : r;
    } @catch (NSException *e) { return NULL; }
}

+ (TYIl2CppObject)invokeWithObject:(TYIl2CppMethodInfo)method
                            target:(TYIl2CppObject)target
                             value:(TYIl2CppObject)value {
    if (!method || !p_runtime_invoke || !value) return NULL;
    @try {
        void *args[1] = { value };   // 引用类型实参：直接传对象指针
        void *exc = NULL;
        void *r = p_runtime_invoke(method, target, args, &exc);
        return exc ? NULL : r;
    } @catch (NSException *e) { return NULL; }
}

+ (TYIl2CppObject)typeObjectOfClass:(TYIl2CppClass)klass {
    if (!klass || !p_class_get_type || !p_type_get_object) return NULL;
    @try {
        void *t = p_class_get_type(klass);
        if (!t) return NULL;
        return p_type_get_object(t);
    } @catch (NSException *e) { return NULL; }
}

+ (TYIl2CppObject)invokeWithVector3:(TYIl2CppMethodInfo)method
                             target:(TYIl2CppObject)target
                                xyz:(const float *)xyz {
    if (!method || !p_runtime_invoke || !xyz) return NULL;
    @try {
        void *args[1] = { (void *)xyz };   // 值类型实参：传指向该值的指针
        void *exc = NULL;
        void *r = p_runtime_invoke(method, target, args, &exc);
        return exc ? NULL : r;
    } @catch (NSException *e) { return NULL; }
}

+ (void *)unbox:(TYIl2CppObject)obj {
    if (!obj) return NULL;
    @try {
        if (p_object_unbox) return p_object_unbox(obj);
        return obj;   // 无 unbox 导出时退化为对象本身（引用类型足够）
    } @catch (NSException *e) { return NULL; }
}

#pragma mark - 字段

+ (TYIl2CppFieldInfo)fieldOfClass:(TYIl2CppClass)klass name:(NSString *)name {
    if (!klass || !name.length || !p_class_get_field_from_name) return NULL;
    @try { return p_class_get_field_from_name(klass, name.UTF8String); }
    @catch (NSException *e) { return NULL; }
}

+ (ptrdiff_t)offsetOfField:(TYIl2CppFieldInfo)field {
    if (!field || !p_field_get_offset) return 0;
    @try { return (ptrdiff_t)p_field_get_offset(field); }
    @catch (NSException *e) { return 0; }
}

+ (BOOL)isStaticField:(TYIl2CppFieldInfo)field {
    if (!field || !p_field_get_flags) return NO;
    return (p_field_get_flags(field) & TY_IL2CPP_FIELD_STATIC) != 0;
}

+ (NSString *)fieldTypeName:(TYIl2CppFieldInfo)field {
    if (!field || !p_field_get_type || !p_type_get_name) return nil;
    @try {
        void *t = p_field_get_type(field);
        if (!t) return nil;
        char *p = p_type_get_name(t);
        if (!p) return nil;
        NSString *s = @(p);
        if (p_free) p_free(p);
        return s;
    } @catch (NSException *e) { return nil; }
}

+ (BOOL)readFloatField:(TYIl2CppFieldInfo)field
                  from:(TYIl2CppObject)obj
                    to:(float *)out {
    if (!field || !out) return NO;
    BOOL st = [self isStaticField:field];
    if (!st && !obj) return NO;
    if (!p_field_get_value || (st && !p_field_static_get_value)) return NO;
    NSString *tn = [self fieldTypeName:field];
    if (tn && ![tn isEqualToString:@"System.Single"]) return NO;
    @try {
        float v = 0;
        if (st) p_field_static_get_value(field, &v);
        else    p_field_get_value(obj, field, &v);
        if (isnan(v) || isinf(v)) return NO;
        *out = v;
        return YES;
    } @catch (NSException *e) { return NO; }
}

+ (BOOL)writeFloatField:(TYIl2CppFieldInfo)field
                     to:(TYIl2CppObject)obj
                  value:(float)value {
    if (!field) return NO;
    BOOL st = [self isStaticField:field];
    if (!st && !obj) return NO;
    if (!p_field_set_value || (st && !p_field_static_set_value)) return NO;
    if (isnan(value) || isinf(value)) return NO;
    NSString *tn = [self fieldTypeName:field];
    if (tn && ![tn isEqualToString:@"System.Single"]) return NO;
    @try {
        float v = value;
        if (st) p_field_static_set_value(field, &v);
        else    p_field_set_value(obj, field, &v);
        return YES;
    } @catch (NSException *e) { return NO; }
}

+ (BOOL)readBoolField:(TYIl2CppFieldInfo)field
                 from:(TYIl2CppObject)obj
                   to:(BOOL *)out {
    if (!field || !out) return NO;
    BOOL st = [self isStaticField:field];
    if (!st && !obj) return NO;
    if (!p_field_get_value || (st && !p_field_static_get_value)) return NO;
    NSString *tn = [self fieldTypeName:field];
    if (tn && ![tn isEqualToString:@"System.Boolean"]) return NO;
    @try {
        uint8_t v = 0;
        if (st) p_field_static_get_value(field, &v);
        else    p_field_get_value(obj, field, &v);
        *out = v != 0;
        return YES;
    } @catch (NSException *e) { return NO; }
}

+ (BOOL)writeBoolField:(TYIl2CppFieldInfo)field
                    to:(TYIl2CppObject)obj
                 value:(BOOL)value {
    if (!field) return NO;
    BOOL st = [self isStaticField:field];
    if (!st && !obj) return NO;
    if (!p_field_set_value || (st && !p_field_static_set_value)) return NO;
    NSString *tn = [self fieldTypeName:field];
    if (tn && ![tn isEqualToString:@"System.Boolean"]) return NO;
    @try {
        uint8_t v = value ? 1 : 0;
        if (st) p_field_static_set_value(field, &v);
        else    p_field_set_value(obj, field, &v);
        return YES;
    } @catch (NSException *e) { return NO; }
}

+ (BOOL)readInt32Field:(TYIl2CppFieldInfo)field
                  from:(TYIl2CppObject)obj
                    to:(int32_t *)out {
    if (!field || !out) return NO;
    BOOL st = [self isStaticField:field];
    if (!st && !obj) return NO;
    if (!p_field_get_value || (st && !p_field_static_get_value)) return NO;
    NSString *tn = [self fieldTypeName:field];
    if (tn && ![tn isEqualToString:@"System.Int32"]) return NO;
    @try {
        int32_t v = 0;
        if (st) p_field_static_get_value(field, &v);
        else    p_field_get_value(obj, field, &v);
        *out = v;
        return YES;
    } @catch (NSException *e) { return NO; }
}

+ (BOOL)writeInt32Field:(TYIl2CppFieldInfo)field
                     to:(TYIl2CppObject)obj
                  value:(int32_t)value {
    if (!field) return NO;
    BOOL st = [self isStaticField:field];
    if (!st && !obj) return NO;
    if (!p_field_set_value || (st && !p_field_static_set_value)) return NO;
    NSString *tn = [self fieldTypeName:field];
    if (tn && ![tn isEqualToString:@"System.Int32"]) return NO;
    @try {
        int32_t v = value;
        if (st) p_field_static_set_value(field, &v);
        else    p_field_set_value(obj, field, &v);
        return YES;
    } @catch (NSException *e) { return NO; }
}

#pragma mark - 成员枚举（云探针）

+ (TYIl2CppObject)objectField:(TYIl2CppFieldInfo)field from:(TYIl2CppObject)obj {
    if (!field || !obj || !p_field_get_value) return NULL;
    if ([self isStaticField:field]) return NULL;
    @try {
        void *v = NULL;
        p_field_get_value(obj, field, &v);   // 引用类型：写出对象指针
        return v;
    } @catch (NSException *e) { return NULL; }
}

+ (TYIl2CppObject)staticObjectField:(TYIl2CppFieldInfo)field {
    if (!field || !p_field_static_get_value) return NULL;
    if (![self isStaticField:field]) return NULL;
    @try {
        void *v = NULL;
        p_field_static_get_value(field, &v);
        return v;
    } @catch (NSException *e) { return NULL; }
}

+ (BOOL)readEnumIntField:(TYIl2CppFieldInfo)field
                    from:(TYIl2CppObject)obj
                      to:(int32_t *)out {
    if (!field || !out) return NO;
    BOOL st = [self isStaticField:field];
    if (!st && !obj) return NO;
    if (!p_field_get_value || (st && !p_field_static_get_value)) return NO;
    @try {
        int32_t v = 0;   // 零初始化：byte/sbyte 支撑的枚举只写低字节
        if (st) p_field_static_get_value(field, &v);
        else    p_field_get_value(obj, field, &v);
        *out = v;
        return YES;
    } @catch (NSException *e) { return NO; }
}

+ (uintptr_t)arrayLengthOf:(TYIl2CppObject)array {
    if (!array || !p_array_length) return 0;
    @try { return p_array_length(array); }
    @catch (NSException *e) { return 0; }
}

+ (TYIl2CppObject)arrayElementAt:(TYIl2CppObject)array index:(uintptr_t)idx {
    if (!array || idx >= [self arrayLengthOf:array]) return NULL;
    @try {
        void *slot = NULL;
        if (p_array_addr_with_size) {
            slot = p_array_addr_with_size(array, (int32_t)sizeof(void *), idx);
        } else {
            // 64 位 il2cpp 引用向量：对象头16 + bounds8 + length8 = 32
            const uintptr_t kVectorOffset = sizeof(void *) == 8 ? 32 : 20;
            slot = (void *)((uintptr_t)array + kVectorOffset + idx * sizeof(void *));
        }
        return slot ? *(void **)slot : NULL;
    } @catch (NSException *e) { return NULL; }
}

+ (NSArray<NSDictionary *> *)fieldsOfClass:(TYIl2CppClass)klass {
    NSMutableArray *out = [NSMutableArray array];
    if (!klass || !p_class_get_fields || !p_field_get_name) return out;
    @try {
        void *iter = NULL;
        void *f = NULL;
        while ((f = p_class_get_fields(klass, &iter)) != NULL) {
            const char *nm = p_field_get_name(f);
            NSString *name = nm ? @(nm) : @"?";
            NSString *type = [self fieldTypeName:f] ?: @"?";
            BOOL st = [self isStaticField:f];
            [out addObject:@{@"name": name, @"type": type, @"static": @(st)}];
        }
    } @catch (NSException *e) { }
    return out;
}

+ (NSArray<NSDictionary *> *)methodsOfClass:(TYIl2CppClass)klass {
    NSMutableArray *out = [NSMutableArray array];
    if (!klass || !p_class_get_methods || !p_method_get_name) return out;
    @try {
        void *iter = NULL;
        void *m = NULL;
        while ((m = p_class_get_methods(klass, &iter)) != NULL) {
            const char *nm = p_method_get_name(m);
            if (!nm) continue;
            unsigned argc = p_method_get_param_count ? p_method_get_param_count(m) : 0;
            [out addObject:@{@"name": @(nm), @"argc": @(argc)}];
        }
    } @catch (NSException *e) { }
    return out;
}

#pragma mark - 镜像类枚举

+ (BOOL)imageClassEnumerationAvailable {
    return p_image_get_class_count != NULL && p_image_get_class != NULL;
}

+ (NSArray<NSValue *> *)classesInImageNamed:(NSString *)imageName {
    if (!gAvailable || ![self ensureDomain] || ![self imageClassEnumerationAvailable]) return nil;
    const void *img = TYImageNamed(imageName);
    if (!img) return nil;
    NSMutableArray<NSValue *> *out = [NSMutableArray array];
    @try {
        size_t cnt = p_image_get_class_count(img);
        // 安全上限：热更镜像近万类已足够，异常数据直接截断
        if (cnt > 200000) cnt = 200000;
        for (size_t i = 0; i < cnt; i++) {
            const void *k = p_image_get_class(img, i);
            if (k) [out addObject:[NSValue valueWithPointer:k]];
        }
    } @catch (NSException *e) { }
    return out;
}

+ (NSArray<NSDictionary *> *)classNamesInImageNamed:(NSString *)imageName
                                          nameRegex:(nullable NSString *)nameRegex {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSArray<NSValue *> *classes = [self classesInImageNamed:imageName];
    if (!classes) return out;
    NSRegularExpression *rx = nil;
    if (nameRegex.length) {
        rx = [NSRegularExpression regularExpressionWithPattern:nameRegex
                                                       options:0 error:NULL];
    }
    @try {
        for (NSValue *v in classes) {
            void *k = v.pointerValue;
            if (!p_class_get_name) continue;
            const char *cn = p_class_get_name(k);
            if (!cn) continue;
            NSString *name = @(cn);
            if (rx && [rx numberOfMatchesInString:name options:0
                                            range:NSMakeRange(0, name.length)] == 0) continue;
            NSString *ns = @"";
            if (p_class_get_namespace) {
                const char *cns = p_class_get_namespace(k);
                if (cns) ns = @(cns);
            }
            [out addObject:@{@"name": name, @"ns": ns}];
        }
    } @catch (NSException *e) { }
    return out;
}

/// 取类型名最后一个 '.' 之后的短名（泛型去掉 `[[...]]`/`<...>` 噪声后粗比较）
static NSString *TYShortTypeName(NSString *full) {
    if (!full) return @"";
    NSString *s = full;
    NSRange dot = [s rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound) s = [s substringFromIndex:dot.location + 1];
    // il2cpp 泛型名形如 List`1[[Foo, asm]]，取反引号前主名
    NSRange bt = [s rangeOfString:@"`"];
    if (bt.location != NSNotFound) s = [s substringToIndex:bt.location];
    return s;
}

+ (NSArray<NSDictionary *> *)scanFieldsInImageNamed:(NSString *)imageName
                                           typeNamed:(NSString *)typeName {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (!typeName.length || !p_class_get_fields || !p_field_get_name) return out;
    NSArray<NSValue *> *classes = [self classesInImageNamed:imageName];
    if (!classes) return out;
    @try {
        for (NSValue *v in classes) {
            void *k = v.pointerValue;
            const char *cn = p_class_get_name ? p_class_get_name(k) : NULL;
            if (!cn) continue;
            NSString *className = @(cn);
            NSString *ns = @"";
            if (p_class_get_namespace) {
                const char *cns = p_class_get_namespace(k);
                if (cns) ns = @(cns);
            }
            void *iter = NULL, *f = NULL;
            while ((f = p_class_get_fields(k, &iter)) != NULL) {
                const char *fn = p_field_get_name(f);
                if (!fn) continue;
                NSString *ft = TYTypeNameOf(p_field_get_type(f)) ?: @"";
                if (![TYShortTypeName(ft) isEqualToString:typeName]) continue;
                BOOL st = p_field_get_flags && (p_field_get_flags(f) & TY_IL2CPP_FIELD_STATIC);
                [out addObject:@{@"class": className, @"ns": ns,
                                 @"field": @(fn), @"static": @(st != NO), @"type": ft}];
                if (out.count >= 300) return out;   // 结果体量护栏
            }
        }
    } @catch (NSException *e) { }
    return out;
}

+ (NSArray<NSDictionary *> *)methodsDetailOfClass:(TYIl2CppClass)klass {
    NSMutableArray *out = [NSMutableArray array];
    if (!klass || !p_class_get_methods || !p_method_get_name) return out;
    @try {
        void *iter = NULL, *m = NULL;
        while ((m = p_class_get_methods(klass, &iter)) != NULL) {
            const char *nm = p_method_get_name(m);
            if (!nm) continue;
            unsigned argc = p_method_get_param_count ? p_method_get_param_count(m) : 0;
            NSString *ret = p_method_get_return_type
                ? (TYTypeNameOf(p_method_get_return_type(m)) ?: @"") : @"";
            NSMutableArray *params = [NSMutableArray array];
            if (p_method_get_param) {
                for (unsigned i = 0; i < argc; i++) {
                    NSString *pn = TYTypeNameOf(p_method_get_param(m, i)) ?: @"?";
                    [params addObject:pn];
                }
            }
            [out addObject:@{@"name": @(nm), @"argc": @(argc),
                             @"ret": ret, @"params": params}];
        }
    } @catch (NSException *e) { }
    return out;
}

#pragma mark - Unity 对象查找

/// 对象类是否为 klass（或其子类）。优先 il2cpp 内建判定，缺失时走父类链。
+ (BOOL)objectClass:(TYIl2CppClass)oc isKindOfClass:(TYIl2CppClass)klass {
    if (!oc || !klass) return NO;
    if (oc == klass) return YES;
    if (p_class_is_assignable_from) {
        // klass 能否从 oc 赋值（oc 是 klass 或其子类）
        return p_class_is_assignable_from(klass, oc) != 0;
    }
    if (p_class_get_parent) {
        void *p = oc;
        for (int i = 0; i < 32 && p; i++) {
            p = p_class_get_parent(p);
            if (p == klass) return YES;
        }
    }
    return NO;
}

+ (TYIl2CppObject)findUnityObjectOfClass:(TYIl2CppClass)klass
                         includeInactive:(BOOL)includeInactive {
    // 【2026-10-15 真机闪退事故后永久禁用】
    // 即便只枚举 AOT 基类 UnityEngine.Object 再按 il2cpp 类过滤，「枚举场景
    // 全部对象」这一步在 HybridCLR 对局主线程上仍会直接卡死（云探针 3 连
    // find 任务无回报 → 看门狗杀进程闪退）。本游戏对象获取的唯一允许路径：
    //   静态 getter（get_instance 等）/ 静态字段 root + 引用多跳 path。
    // 本方法保留签名仅为兼容调用点编译，任何时候都返回 NULL，不得复活枚举。
    TYLogWarn(@"已拒绝全场景对象枚举（真机事故禁用）：请改用静态入口/root+path 导航");
    return NULL;
}

#pragma mark - 单例

+ (TYIl2CppObject)singletonOfClass:(TYIl2CppClass)klass
                       getterNames:(NSArray<NSString *> *)names {
    if (!klass || !names.count) return NULL;
    for (NSString *n in names) {
        void *m = [self methodOfClass:klass name:n paramCount:0];
        if (m) {
            void *r = [self invokeNoArg:m target:NULL];
            if (r) return r;
        }
    }
    return NULL;
}

#pragma mark - 诊断

+ (NSString *)dumpBinding {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"可用=%@ 导出=%lu handle=%p domain=%p",
     gAvailable ? @"是" : @"否", (unsigned long)gResolved, gHandle, gDomain];
    if (gReason) [s appendFormat:@" 原因=%@", gReason];
    if (gAvailable) {
        [s appendFormat:@"\n镜像(%lu): %@",
         (unsigned long)[self allImageNames].count,
         [[self allImageNames] componentsJoinedByString:@", "]];
    }
    return s;
}

@end
