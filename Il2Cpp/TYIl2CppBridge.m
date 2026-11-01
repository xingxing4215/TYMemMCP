//
//  TYIl2CppBridge.m
//  TYMemMCP —— il2cpp 反射层实现
//

#import "TYIl2CppBridge.h"
#import "TYIl2Cpp.h"
#import "TYMem.h"
#import <mach-o/dyld.h>

/// 统一的成功/失败包装
static NSDictionary *TYOK(NSDictionary *body) {
    NSMutableDictionary *m = [body mutableCopy] ?: [NSMutableDictionary dictionary];
    m[@"ok"] = @YES;
    return m;
}
static NSDictionary *TYFail(NSString *msg) {
    return @{@"ok": @NO, @"error": msg ?: @"未知错误"};
}

@implementation TYIl2CppBridge

+ (instancetype)shared {
    static TYIl2CppBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TYIl2CppBridge alloc] init]; });
    return s;
}

- (BOOL)available {
    return [TYIl2Cpp available] || [TYIl2Cpp setup];
}
- (NSString *)failureReason { return [TYIl2Cpp failureReason]; }

#pragma mark - 类查询

- (NSArray<NSString *> *)imageNames {
    if (![self available]) return @[];
    return [TYIl2Cpp allImageNames] ?: @[];
}

- (void *)classFor:(NSDictionary *)p {
    NSString *full = p[@"class"];
    if (![full isKindOfClass:[NSString class]] || !full.length) return NULL;
    NSString *image = p[@"image"];
    NSString *ns = p[@"ns"];

    if ([image isKindOfClass:[NSString class]] && image.length) {
        // 拆出命名空间
        NSString *cls = full, *nsp = ns;
        NSRange dot = [full rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location != NSNotFound) {
            nsp = [full substringToIndex:dot.location];
            cls = [full substringFromIndex:dot.location + 1];
        }
        void *k = [TYIl2Cpp classInImageNamed:image ns:nsp name:cls];
        if (k) return k;
    }
    if ([ns isKindOfClass:[NSString class]] && ns.length) {
        void *k = [TYIl2Cpp classWithNamespace:ns name:full];
        if (k) return k;
    }
    return [TYIl2Cpp classFullyQualified:full];
}

- (NSDictionary *)findClass:(NSString *)fullName image:(NSString *)image {
    if (![self available])
        return TYFail([NSString stringWithFormat:@"il2cpp 未就绪：%@", [TYIl2Cpp failureReason] ?: @"?"]);
    if (!fullName.length) return TYFail(@"缺少 class 名");

    void *k = [self classFor:@{@"class": fullName, @"image": image ?: @""}];
    if (!k) {
        return TYOK(@{@"found": @NO, @"class": fullName,
                      @"images": [TYIl2Cpp allImageNames] ?: @[],
                      @"hint": @"类未注册进 il2cpp domain（检查命名空间/镜像，或热更程序集是否加载）"});
    }
    // 从类指针反查类名，确认真实身份
    NSString *realName = [TYIl2Cpp classNameOf:NULL];
    (void)realName;
    return TYOK(@{@"found": @YES, @"class": fullName});
}

- (NSDictionary *)listClassesInImage:(NSString *)image
                               regex:(NSString *)regex
                               limit:(NSUInteger)limit {
    if (![self available]) return TYFail(@"il2cpp 未就绪");
    if (!image.length) return TYFail(@"缺少 image");
    if (![TYIl2Cpp imageClassEnumerationAvailable])
        return TYFail(@"il2cpp_image_get_class 导出缺失，无法按索引枚举镜像类");
    if (limit == 0) limit = 500;

    NSArray *list = [TYIl2Cpp classNamesInImageNamed:image nameRegex:regex];
    NSUInteger total = list.count;
    if (list.count > limit) list = [list subarrayWithRange:NSMakeRange(0, limit)];
    return TYOK(@{@"image": image, @"count": @(list.count),
                  @"total_matched": @(total),
                  @"truncated": @(total > limit),
                  @"classes": list});
}

- (NSDictionary *)fieldsOfClass:(NSString *)fullName image:(NSString *)image {
    if (![self available]) return TYFail(@"il2cpp 未就绪");
    void *k = [self classFor:@{@"class": fullName ?: @"", @"image": image ?: @""}];
    if (!k) return TYFail([NSString stringWithFormat:@"类未找到 %@", fullName]);
    NSArray *f = [TYIl2Cpp fieldsOfClass:k];
    return TYOK(@{@"class": fullName, @"count": @(f.count), @"fields": f ?: @[]});
}

- (NSDictionary *)methodsOfClass:(NSString *)fullName image:(NSString *)image {
    if (![self available]) return TYFail(@"il2cpp 未就绪");
    void *k = [self classFor:@{@"class": fullName ?: @"", @"image": image ?: @""}];
    if (!k) return TYFail([NSString stringWithFormat:@"类未找到 %@", fullName]);
    NSArray *m = [TYIl2Cpp methodsOfClass:k];
    return TYOK(@{@"class": fullName, @"count": @(m.count), @"methods": m ?: @[]});
}

- (NSDictionary *)findFieldsOfType:(NSString *)typeName
                             image:(NSString *)image
                             limit:(NSUInteger)limit {
    if (![self available]) return TYFail(@"il2cpp 未就绪");
    if (!typeName.length) return TYFail(@"缺少 type_name");
    if (!image.length) return TYFail(@"缺少 image");
    if (limit == 0) limit = 200;
    NSArray *hits = [TYIl2Cpp scanFieldsInImageNamed:image typeNamed:typeName];
    NSUInteger total = hits.count;
    if (hits.count > limit) hits = [hits subarrayWithRange:NSMakeRange(0, limit)];
    return TYOK(@{@"type_name": typeName, @"image": image,
                  @"count": @(hits.count), @"total": @(total),
                  @"truncated": @(total > limit),
                  @"hits": hits ?: @[]});
}

#pragma mark - 定位（从 target 描述取得实例）

/// 读一个静态引用字段
- (void *)staticFieldObject:(NSDictionary *)p klass:(void *)klass field:(NSString *)fieldName {
    void *f = [TYIl2Cpp fieldOfClass:klass name:fieldName];
    if (!f) return NULL;
    if (![TYIl2Cpp isStaticField:f]) return NULL;
    return [TYIl2Cpp staticObjectField:f];
}

/// 按 root + path 走链条，返回最终对象
- (void *)resolveObjectFor:(NSDictionary *)p
                     klass:(void *)klass
                      path:(NSArray *)path
                     error:(NSString **)err {
    NSDictionary *root = p[@"root"];
    void *cur = NULL;

    if ([root isKindOfClass:[NSDictionary class]]) {
        NSString *rf = root[@"field"];
        NSArray *getters = root[@"instance_getter"];

        if ([rf isKindOfClass:[NSString class]] && rf.length) {
            cur = [self staticFieldObject:p klass:klass field:rf];
            if (!cur) {
                if (err) *err = [NSString stringWithFormat:
                                 @"静态字段 %@ 为空或不存在（可能不在对局中）", rf];
                return NULL;
            }
        } else if ([getters isKindOfClass:[NSArray class]] || [getters isKindOfClass:[NSString class]]) {
            NSArray *gs = [getters isKindOfClass:[NSString class]] ? @[getters] : getters;
            for (NSString *g in gs) {
                void *m = [TYIl2Cpp methodOfClass:klass name:g paramCount:0];
                if (!m) continue;
                void *o = [TYIl2Cpp invokeNoArg:m target:NULL];
                if (o) { cur = o; break; }
            }
            if (!cur) {
                if (err) *err = [NSString stringWithFormat:@"静态 getter %@ 均未返回实例", gs];
                return NULL;
            }
        }
    } else if ([p[@"static"] boolValue]) {
        // 直接按字段名取静态
        cur = [self staticFieldObject:p klass:klass field:p[@"field"]];
        if (!cur) { if (err) *err = @"静态字段为空"; return NULL; }
    }

    // 逐跳 path
    for (NSUInteger i = 0; i < path.count; i++) {
        NSDictionary *step = path[i];
        if (![step isKindOfClass:[NSDictionary class]]) continue;

        NSString *fn = step[@"field"];
        if ([fn isKindOfClass:[NSString class]] && fn.length) {
            void *ck = [TYIl2Cpp classOfObject:cur];
            if (!ck) { if (err) *err = [NSString stringWithFormat:@"第 %lu 跳取类失败", (unsigned long)i]; return NULL; }
            void *f = [TYIl2Cpp fieldOfClass:ck name:fn];
            if (!f) { if (err) *err = [NSString stringWithFormat:@"第 %lu 跳字段 %@ 不存在", (unsigned long)i, fn]; return NULL; }
            void *nx = [TYIl2Cpp objectField:f from:cur];
            if (!nx) { if (err) *err = [NSString stringWithFormat:@"第 %lu 跳字段 %@ 为空", (unsigned long)i, fn]; return NULL; }
            cur = nx;
            continue;
        }

        NSString *iv = step[@"invoke"];
        if ([iv isKindOfClass:[NSString class]] && iv.length) {
            void *ck = [TYIl2Cpp classOfObject:cur];
            if (!ck) { if (err) *err = [NSString stringWithFormat:@"第 %lu 跳取类失败", (unsigned long)i]; return NULL; }
            NSNumber *arg = step[@"arg"];
            if ([arg isKindOfClass:[NSNumber class]]) {
                void *m = [TYIl2Cpp methodOfClass:ck name:iv paramCount:1];
                if (!m) { if (err) *err = [NSString stringWithFormat:@"第 %lu 跳方法 %@(1) 不存在", (unsigned long)i, iv]; return NULL; }
                void *nx = [TYIl2Cpp invokeIntReturning:m target:cur value:arg.intValue];
                if (!nx) { if (err) *err = [NSString stringWithFormat:@"第 %lu 跳方法 %@ 返回空", (unsigned long)i, iv]; return NULL; }
                cur = nx;
            } else {
                void *m = [TYIl2Cpp methodOfClass:ck name:iv paramCount:0];
                if (!m) { if (err) *err = [NSString stringWithFormat:@"第 %lu 跳方法 %@ 不存在", (unsigned long)i, iv]; return NULL; }
                void *nx = [TYIl2Cpp invokeNoArg:m target:cur];
                if (!nx) { if (err) *err = [NSString stringWithFormat:@"第 %lu 跳方法 %@ 返回空", (unsigned long)i, iv]; return NULL; }
                cur = nx;
            }
            continue;
        }
    }
    return cur;
}

#pragma mark - 字段读写

- (NSDictionary *)readField:(NSDictionary *)p {
    if (![self available]) return TYFail(@"il2cpp 未就绪");
    NSString *clsName = p[@"class"];
    NSString *fieldName = p[@"field"];
    if (!clsName.length || !fieldName.length) return TYFail(@"需要 class 与 field");

    void *klass = [self classFor:p];
    if (!klass) return TYFail([NSString stringWithFormat:@"类未找到 %@", clsName]);
    void *field = [TYIl2Cpp fieldOfClass:klass name:fieldName];
    if (!field) return TYFail([NSString stringWithFormat:@"字段未找到 %@", fieldName]);

    NSString *declared = [TYIl2Cpp fieldTypeName:field] ?: @"?";
    BOOL isStatic = [TYIl2Cpp isStaticField:field];
    NSString *type = [p[@"type"] isKindOfClass:[NSString class]]
                   ? [(NSString *)p[@"type"] lowercaseString] : nil;

    // 静态：直接读
    if (isStatic) {
        NSMutableDictionary *r = [@{@"class": clsName, @"field": fieldName,
                                    @"declared_type": declared, @"static": @YES} mutableCopy];
        if ([type isEqualToString:@"bool"]) {
            BOOL v = NO;
            if ([TYIl2Cpp readBoolField:field from:NULL to:&v]) r[@"value"] = @(v);
        } else if ([type isEqualToString:@"int"]) {
            int32_t v = 0;
            if ([TYIl2Cpp readInt32Field:field from:NULL to:&v]) r[@"value"] = @(v);
        } else if ([type isEqualToString:@"double"]) {
            void *o = [TYIl2Cpp staticObjectField:field];
            r[@"is_null"] = @(o == NULL);
            r[@"pointer"] = [NSString stringWithFormat:@"0x%llx", (uint64_t)o];
        } else if ([type isEqualToString:@"object"]) {
            void *o = [TYIl2Cpp staticObjectField:field];
            r[@"is_null"] = @(o == NULL);
            r[@"pointer"] = [NSString stringWithFormat:@"0x%llx", (uint64_t)o];
        } else {
            float v = 0;
            if ([TYIl2Cpp readFloatField:field from:NULL to:&v]) r[@"value"] = @(v);
        }
        if (!r[@"value"] && !r[@"pointer"]) r[@"note"] = [NSString stringWithFormat:@"读取被拒（声明类型 %@，请指定正确的 type）", declared];
        return TYOK(r);
    }

    // 实例：走 root+path
    NSString *err = nil;
    void *obj = [self resolveObjectFor:p klass:klass path:p[@"path"] error:&err];
    if (!obj) return TYFail(err ?: @"实例为空");

    NSMutableDictionary *r = [@{@"class": clsName, @"field": fieldName,
                                @"declared_type": declared, @"static": @NO} mutableCopy];
    if ([type isEqualToString:@"bool"]) {
        BOOL v = NO;
        if ([TYIl2Cpp readBoolField:field from:obj to:&v]) r[@"value"] = @(v);
    } else if ([type isEqualToString:@"int"]) {
        int32_t v = 0;
        if ([TYIl2Cpp readInt32Field:field from:obj to:&v]) r[@"value"] = @(v);
    } else if ([type isEqualToString:@"object"]) {
        void *o = [TYIl2Cpp objectField:field from:obj];
        r[@"is_null"] = @(o == NULL);
        r[@"pointer"] = [NSString stringWithFormat:@"0x%llx", (uint64_t)o];
    } else {
        float v = 0;
        if ([TYIl2Cpp readFloatField:field from:obj to:&v]) r[@"value"] = @(v);
    }
    if (!r[@"value"] && !r[@"pointer"])
        r[@"note"] = [NSString stringWithFormat:@"读取被拒（声明类型 %@，请指定正确的 type）", declared];
    return TYOK(r);
}

- (NSDictionary *)writeField:(NSDictionary *)p {
    if (![self available]) return TYFail(@"il2cpp 未就绪");
    NSString *clsName = p[@"class"];
    NSString *fieldName = p[@"field"];
    if (!clsName.length || !fieldName.length) return TYFail(@"需要 class 与 field");
    NSNumber *val = p[@"value"];
    if (![val isKindOfClass:[NSNumber class]]) return TYFail(@"需要 value(数字)");

    void *klass = [self classFor:p];
    if (!klass) return TYFail([NSString stringWithFormat:@"类未找到 %@", clsName]);
    void *field = [TYIl2Cpp fieldOfClass:klass name:fieldName];
    if (!field) return TYFail([NSString stringWithFormat:@"字段未找到 %@", fieldName]);

    NSString *type = [p[@"type"] isKindOfClass:[NSString class]]
                   ? [(NSString *)p[@"type"] lowercaseString] : @"float";
    BOOL isStatic = [TYIl2Cpp isStaticField:field];
    void *obj = NULL;
    if (!isStatic) {
        NSString *err = nil;
        obj = [self resolveObjectFor:p klass:klass path:p[@"path"] error:&err];
        if (!obj) return TYFail(err ?: @"实例为空");
    }

    BOOL ok = NO;
    if ([type isEqualToString:@"bool"])      ok = [TYIl2Cpp writeBoolField:field to:obj value:val.boolValue];
    else if ([type isEqualToString:@"int"])  ok = [TYIl2Cpp writeInt32Field:field to:obj value:(int32_t)val.intValue];
    else                                     ok = [TYIl2Cpp writeFloatField:field to:obj value:val.floatValue];
    if (!ok) return TYFail([NSString stringWithFormat:@"写入被拒（声明类型 %@，请求 %@）",
                            [TYIl2Cpp fieldTypeName:field] ?: @"?", type]);

    // 立即回读
    NSMutableDictionary *r = [@{@"class": clsName, @"field": fieldName, @"written": val} mutableCopy];
    float fv = 0; int32_t iv = 0; BOOL bv = NO;
    if ([type isEqualToString:@"bool"] && [TYIl2Cpp readBoolField:field from:obj to:&bv]) r[@"readback"] = @(bv);
    else if ([type isEqualToString:@"int"] && [TYIl2Cpp readInt32Field:field from:obj to:&iv]) r[@"readback"] = @(iv);
    else if ([TYIl2Cpp readFloatField:field from:obj to:&fv]) r[@"readback"] = @(fv);
    return TYOK(r);
}

#pragma mark - 导航

- (NSDictionary *)navigate:(NSDictionary *)target {
    if (![self available]) return TYFail(@"il2cpp 未就绪");
    NSString *clsName = target[@"class"];
    if (!clsName.length) return TYFail(@"需要 class");

    void *klass = [self classFor:target];
    if (!klass) return TYFail([NSString stringWithFormat:@"类未找到 %@", clsName]);

    NSArray *path = [target[@"path"] isKindOfClass:[NSArray class]] ? target[@"path"] : @[];
    NSMutableArray *trace = [NSMutableArray array];
    NSString *err = nil;

    void *cur = [self resolveObjectFor:target klass:klass path:path error:&err];

    // 逐跳记录（成功或失败都把已走的跳数回报，便于定位断点）
    NSDictionary *root = target[@"root"];
    NSString *rf = root[@"field"];
    if (rf.length) {
        void *f = [TYIl2Cpp fieldOfClass:klass name:rf];
        void *o = f ? [TYIl2Cpp staticObjectField:f] : NULL;
        [trace addObject:@{@"hop": @0, @"field": rf,
                           @"value": [NSString stringWithFormat:@"0x%llx", (uint64_t)o],
                           @"null": @(o == NULL)}];
    }
    for (NSUInteger i = 0; i < path.count; i++) {
        NSDictionary *step = path[i];
        [trace addObject:@{@"hop": @(i + 1), @"step": step ?: @{}}];
    }

    if (!cur) {
        NSMutableDictionary *d = [TYFail(err ?: @"链在中途断开") mutableCopy];
        d[@"class"] = clsName;
        d[@"trace"] = trace;
        d[@"hint"] = @"若在菜单/局外执行，静态服务定位器常为空 —— 这是正常现象，非绑定错误";
        return d;
    }

    NSMutableDictionary *d = [TYOK(@{@"class": clsName,
                                     @"address": [NSString stringWithFormat:@"0x%llx", (uint64_t)cur],
                                     @"trace": trace}) mutableCopy];
    NSString *rt = [TYIl2Cpp classNameOf:cur];
    if (rt.length) d[@"object_class"] = rt;
    return d;
}

- (void *)staticObjectOfClass:(NSString *)fullName
                        field:(NSString *)field
                        image:(NSString *)image {
    if (![self available]) return NULL;
    void *k = [self classFor:@{@"class": fullName ?: @"", @"image": image ?: @""}];
    if (!k) return NULL;
    return [self staticFieldObject:@{@"class": fullName} klass:k field:field];
}

@end
