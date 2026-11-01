//
//  TYMCPServer.m
//  TYMemMCP —— MCP JSON-RPC 分发实现
//

#import "TYMCPServer.h"
#import "TYMem.h"
#import "TYModule.h"
#import "TYScan.h"
#import "TYIl2CppBridge.h"
#import <mach-o/dyld.h>
#import <string.h>

#define TY_MCP_PROTOCOL @"2024-11-05"
#define TY_MCP_VERSION  @"1.0.0"

/// 把结果包成 MCP tools/call 的 content 形状
static NSDictionary *TYContent(id payload) {
    NSString *json;
    if ([payload isKindOfClass:[NSString class]]) {
        json = payload;
    } else {
        NSData *d = [NSJSONSerialization dataWithJSONObject:payload
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:NULL];
        json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
    }
    return @{@"content": @[@{@"type": @"text", @"text": json ?: @"{}"}]};
}

static NSDictionary *TYErrContent(id payload) {
    NSString *json;
    if ([payload isKindOfClass:[NSString class]]) {
        json = payload;
    } else {
        NSData *d = [NSJSONSerialization dataWithJSONObject:payload
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:NULL];
        json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
    }
    return @{@"content": @[@{@"type": @"text", @"text": json ?: @"{}"}],
             @"isError": @YES};
}

/// 解析十六进制或十进制地址
static BOOL TYParseAddr(id v, uint64_t *out) {
    if ([v isKindOfClass:[NSNumber class]]) { *out = [v unsignedLongLongValue]; return YES; }
    if (![v isKindOfClass:[NSString class]]) return NO;
    NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
    if (!s.length) return NO;
    if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
        unsigned long long x = 0;
        if ([[NSScanner scannerWithString:[s substringFromIndex:2]] scanHexLongLong:&x]) {
            *out = x; return YES;
        }
        return NO;
    }
    unsigned long long x = 0;
    if ([[NSScanner scannerWithString:s] scanUnsignedLongLong:&x]) { *out = x; return YES; }
    return NO;
}

@implementation TYMCPServer

+ (instancetype)shared {
    static TYMCPServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TYMCPServer alloc] init]; });
    return s;
}

#pragma mark - 服务器信息

- (NSDictionary *)serverInfo {
    return @{
        @"name": @"ty-mem-mcp",
        @"version": TY_MCP_VERSION,
        @"description": @"TaoYao 进程内内存调试 MCP 服务器（ARM64 / iOS）",
    };
}

#pragma mark - 工具清单

- (NSDictionary *)toolList {
    NSArray *tools = @[
        // ---------------- 基础信息 ----------------
        @{@"name": @"get_info",
          @"description": @"获取服务器与宿主进程状态：pid、可读内存总量、il2cpp 是否就绪、已加载模块数。",
          @"inputSchema": @{@"type": @"object", @"properties": @{}, @"required": @[]}},

        @{@"name": @"list_modules",
          @"description": @"列出已加载模块（dyld image）。可按名称子串过滤、可含系统库。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"filter": @{@"type": @"string", @"description": @"名称/路径子串"},
                  @"include_system": @{@"type": @"boolean", @"description": @"是否包含系统库，默认 false"},
                  @"limit": @{@"type": @"integer", @"description": @"上限，默认 200"}},
              @"required": @[]}},

        @{@"name": @"image_lookup",
          @"description": @"地址反查：给出该地址属于哪个模块、模块内偏移、所在段。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{@"address": @{@"type": @"string", @"description": @"十六进制地址，如 0x106000000"}},
              @"required": @[@"address"]}},

        // ---------------- 内存读 ----------------
        @{@"name": @"read_memory",
          @"description": @"读取一段内存，返回 hex / ascii / 多种类型解读。自动按 region 切分，跳过不可读页并报告空洞。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"address": @{@"type": @"string"},
                  @"size": @{@"type": @"integer", @"description": @"字节数，默认 64，上限 65536"}},
              @"required": @[@"address"]}},

        @{@"name": @"read_value",
          @"description": @"从指定地址读取单个值，按 type 解释。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"address": @{@"type": @"string"},
                  @"type": @{@"type": @"string",
                             @"description": @"i8/i16/i32/i64/u8/u16/u32/u64/f32/f64/ptr"}},
              @"required": @[@"address", @"type"]}},

        @{@"name": @"write_value",
          @"description": @"向指定地址写入一个值。要求目标页可写，否则拒绝。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"address": @{@"type": @"string"},
                  @"type": @{@"type": @"string"},
                  @"value": @{@"type": @"string", @"description": @"值（数字或浮点）"}},
              @"required": @[@"address", @"type", @"value"]}},

        @{@"name": @"list_regions",
          @"description": @"枚举地址区间内的 VM region（地址/大小/权限/所属模块）。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"start": @{@"type": @"string"},
                  @"end": @{@"type": @"string", @"description": @"结束地址，可省略表示到最高地址"},
                  @"filter": @{@"type": @"string", @"description": @"只看这些权限，如 rw / r-x"},
                  @"limit": @{@"type": @"integer", @"description": @"默认 200"}},
              @"required": @[@"start"]}},

        // ---------------- 搜索 ----------------
        @{@"name": @"scan",
          @"description": @"在内存中搜索精确值（整数/浮点/字符串/字节序列）。可按可写页过滤。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"value": @{@"type": @"string", @"description": @"要搜的值；bytes 类型填十六进制串"},
                  @"type": @{@"type": @"string", @"description": @"i32/u32/f32/f64/utf8/utf16/bytes 等"},
                  @"start": @{@"type": @"string", @"description": @"起始地址，省略则扫全部模块"},
                  @"end": @{@"type": @"string", @"description": @"结束地址，可省略"},
                  @"module": @{@"type": @"string", @"description": @"只扫该模块，如 UnityFramework"},
                  @"writable_only": @{@"type": @"boolean", @"description": @"只搜可写页，默认 false"},
                  @"aligned": @{@"type": @"boolean", @"description": @"按类型宽度对齐，默认 true"},
                  @"max_results": @{@"type": @"integer", @"description": @"命中上限，默认 500"}},
              @"required": @[@"value", @"type"]}},

        @{@"name": @"scan_refine",
          @"description": @"对上一次 scan 的结果做二次筛选：只保留当前值 == 新值的地址。需要先在同一会话里 scan 过。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"value": @{@"type": @"string"},
                  @"type": @{@"type": @"string"}},
              @"required": @[@"value", @"type"]}},

        @{@"name": @"scan_results",
          @"description": @"取出上一次 scan（或 refine）的当前结果列表。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"limit": @{@"type": @"integer", @"description": @"默认 100"},
                  @"read_values": @{@"type": @"boolean", @"description": @"是否同时读出当前值"}},
              @"required": @[]}},

        @{@"name": @"pointer_chain",
          @"description": @"按基址 + 偏移数组解析多级指针链，返回每一跳的中间地址。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"base": @{@"type": @"string", @"description": @"基址，如 0x106AAA000"},
                  @"offsets": @{@"type": @"array", @"items": @{@"type": @"integer"},
                                @"description": @"偏移数组，按顺序应用；支持负数"}},
              @"required": @[@"base", @"offsets"]}},

        @{@"name": @"find_pointers",
          @"description": @"指针扫描：在可写页里找出所有「值等于 target」的 8 字节指针，用于构建稳定路径。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"target": @{@"type": @"string", @"description": @"目标地址"},
                  @"module": @{@"type": @"string", @"description": @"限定在模块内扫"},
                  @"start": @{@"type": @"string"},
                  @"end": @{@"type": @"string"},
                  @"limit_bytes": @{@"type": @"integer", @"description": @"最多扫多少字节，默认 256MB"},
                  @"max_results": @{@"type": @"integer", @"description": @"默认 200"}},
              @"required": @[@"target"]}},

        // ---------------- il2cpp ----------------
        @{@"name": @"il2cpp_status",
          @"description": @"il2cpp 绑定状态与镜像清单。",
          @"inputSchema": @{@"type": @"object", @"properties": @{}, @"required": @[]}},

        @{@"name": @"il2cpp_find_class",
          @"description": @"按「命名空间.类名」或「类名」查找 il2cpp 类。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"class": @{@"type": @"string"},
                  @"image": @{@"type": @"string", @"description": @"限定镜像，如 UpdateScript_500.dll"}},
              @"required": @[@"class"]}},

        @{@"name": @"il2cpp_list_classes",
          @"description": @"列出某镜像内的类名，可用正则过滤。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"image": @{@"type": @"string"},
                  @"regex": @{@"type": @"string", @"description": @"类名正则，可省略"},
                  @"limit": @{@"type": @"integer", @"description": @"默认 500"}},
              @"required": @[@"image"]}},

        @{@"name": @"il2cpp_fields",
          @"description": @"列出类的全部字段（名 / 声明类型 / 是否静态 / 偏移）。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"class": @{@"type": @"string"},
                  @"image": @{@"type": @"string"}},
              @"required": @[@"class"]}},

        @{@"name": @"il2cpp_methods",
          @"description": @"列出类的全部方法（名 / 参数个数）。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"class": @{@"type": @"string"},
                  @"image": @{@"type": @"string"}},
              @"required": @[@"class"]}},

        @{@"name": @"il2cpp_find_by_field_type",
          @"description": @"反向扫描：找出所有「字段声明类型等于 type_name」的类与字段。混淆名整体重排后用它重建锚点。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"type_name": @{@"type": @"string", @"description": @"类型名，如 WarFogAgent"},
                  @"image": @{@"type": @"string"},
                  @"limit": @{@"type": @"integer", @"description": @"默认 200"}},
              @"required": @[@"type_name", @"image"]}},

        @{@"name": @"il2cpp_navigate",
          @"description": @"按 root + path 走引用链，返回每跳的地址与对象真实类名。用于验证锚点。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"class": @{@"type": @"string", @"description": @"起点类"},
                  @"image": @{@"type": @"string"},
                  @"root": @{@"type": @"object",
                             @"description": @{@"field": @{@"type": @"string"},
                                               @"instance_getter": @{@"type": @"array", @"items": @{@"type": @"string"}}}},
                  @"path": @{@"type": @"array",
                             @"items": @{@"type": @"object"},
                             @"description": @"每跳 {field:名} 或 {invoke:方法名, arg:整数}"}},
              @"required": @[@"class"]}},

        @{@"name": @"il2cpp_read_field",
          @"description": @"读取 il2cpp 字段值（静态字段直接读；实例字段需给 root+path 定位实例）。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"class": @{@"type": @"string"},
                  @"image": @{@"type": @"string"},
                  @"field": @{@"type": @"string"},
                  @"type": @{@"type": @"string", @"description": @"bool/int/float/object"},
                  @"root": @{@"type": @"object"},
                  @"path": @{@"type": @"array", @"items": @{@"type": @"object"}}},
              @"required": @[@"class", @"field"]}},

        @{@"name": @"il2cpp_write_field",
          @"description": @"写入 il2cpp 字段值，并立即回读确认。",
          @"inputSchema": @{
              @"type": @"object",
              @"properties": @{
                  @"class": @{@"type": @"string"},
                  @"image": @{@"type": @"string"},
                  @"field": @{@"type": @"string"},
                  @"type": @{@"type": @"string"},
                  @"value": @{@"type": @"number"},
                  @"root": @{@"type": @"object"},
                  @"path": @{@"type": @"array", @"items": @{@"type": @"object"}}},
              @"required": @[@"class", @"field", @"value"]}},
    ];
    return @{@"tools": tools};
}

#pragma mark - 单次 scan 结果缓存（供 refine / results 复用）

static NSArray<TYScanResult *> *gLastResults = nil;
static TYScanType gLastType = TYScanF32;

#pragma mark - 分发

- (NSDictionary *)handle:(NSDictionary *)req {
    NSString *method = req[@"method"];
    id rid = req[@"id"];
    NSDictionary *params = [req[@"params"] isKindOfClass:[NSDictionary class]] ? req[@"params"] : @{};

    // 通知类：无 id 且是 notifications/*，不回应
    if ([method hasPrefix:@"notifications/"]) return nil;

    if ([method isEqualToString:@"initialize"]) {
        return @{@"jsonrpc": @"2.0",
                 @"id": rid ?: NSNull.null,
                 @"result": @{
                     @"protocolVersion": TY_MCP_PROTOCOL,
                     @"serverInfo": [self serverInfo],
                     @"capabilities": @{@"tools": @{}}}};
    }
    if ([method isEqualToString:@"ping"]) {
        return @{@"jsonrpc": @"2.0", @"id": rid ?: NSNull.null, @"result": @{}};
    }
    if ([method isEqualToString:@"tools/list"]) {
        return @{@"jsonrpc": @"2.0", @"id": rid ?: NSNull.null, @"result": [self toolList]};
    }
    if ([method isEqualToString:@"tools/call"]) {
        NSString *name = params[@"name"];
        NSDictionary *args = [params[@"arguments"] isKindOfClass:[NSDictionary class]]
                           ? params[@"arguments"] : @{};
        NSDictionary *r = [self callTool:name args:args];
        return @{@"jsonrpc": @"2.0", @"id": rid ?: NSNull.null, @"result": r};
    }

    return @{@"jsonrpc": @"2.0", @"id": rid ?: NSNull.null,
             @"error": @{@"code": @(-32601),
                         @"message": [NSString stringWithFormat:@"未知方法 %@", method ?: @"?"]}};
}

#pragma mark - 工具实现

- (NSDictionary *)callTool:(NSString *)name args:(NSDictionary *)a {
    @try {
        // ============ 基础信息 ============
        if ([name isEqualToString:@"get_info"]) {
            NSMutableDictionary *d = [@{
                @"pid": @(getpid()),
                @"server": [self serverInfo],
                @"module_count": @(_dyld_image_count()),
                @"il2cpp": @([[TYIl2CppBridge shared] available]),
            } mutableCopy];
            NSString *fr = [[TYIl2CppBridge shared] failureReason];
            if (fr.length) d[@"il2cpp_failure"] = fr;
            NSArray *mods = [[TYModule shared] modulesMatching:nil includeSystem:NO];
            d[@"user_modules"] = @(mods.count);
            // 统计可读内存
            uint64_t total = 0;
            for (TYMemRegion *r in [[TYMem shared] regionsFrom:0x100000000 to:0 limit:20000]) {
                if (r.readable) total += r.size;
            }
            d[@"readable_bytes"] = @(total);
            d[@"readable_mb"] = @(total / 1048576.0);
            return TYContent(d);
        }

        if ([name isEqualToString:@"list_modules"]) {
            NSString *filter = a[@"filter"];
            BOOL incSys = [a[@"include_system"] boolValue];
            NSUInteger limit = [a[@"limit"] integerValue] ?: 200;
            NSArray *mods = [[TYModule shared] modulesMatching:filter includeSystem:incSys];
            NSUInteger total = mods.count;
            if (mods.count > limit) mods = [mods subarrayWithRange:NSMakeRange(0, limit)];
            NSMutableArray *out = [NSMutableArray array];
            for (TYModuleInfo *m in mods) [out addObject:[m dictionaryRepresentation]];
            return TYContent(@{@"count": @(out.count), @"total": @(total),
                               @"truncated": @(total > limit), @"modules": out});
        }

        if ([name isEqualToString:@"image_lookup"]) {
            uint64_t addr = 0;
            if (!TYParseAddr(a[@"address"], &addr)) return TYErrContent(@"address 无效");
            NSDictionary *lk = [[TYModule shared] lookupAddress:addr];
            NSMutableDictionary *d = [lk mutableCopy] ?: [NSMutableDictionary dictionary];
            // 附带该地址的 region 权限
            TYMemRegion *r = [[TYMem shared] regionAt:addr];
            if (r) d[@"region"] = [r dictionaryRepresentation];
            return TYContent(d);
        }

        // ============ 内存读 ============
        if ([name isEqualToString:@"read_memory"]) {
            uint64_t addr = 0;
            if (!TYParseAddr(a[@"address"], &addr)) return TYErrContent(@"address 无效");
            uint64_t size = [a[@"size"] integerValue] ?: 64;
            if (size > 65536) size = 65536;
            TYMemReadResult *r = [[TYMem shared] readAt:addr size:size];
            NSMutableDictionary *d = [[r dictionaryRepresentation] mutableCopy];
            if (r.data.length) {
                // ascii 视图
                const uint8_t *p = r.data.bytes;
                NSMutableString *asc = [NSMutableString string];
                for (NSUInteger i = 0; i < r.data.length; i++) {
                    uint8_t c = p[i];
                    [asc appendFormat:@"%C", (c >= 32 && c < 127) ? (unichar)c : (unichar)'.'];
                }
                d[@"ascii"] = asc;
                // 若长度够，附多类型解读
                if (r.data.length >= 8) {
                    uint64_t u64 = 0; uint32_t u32 = 0; float f32 = 0; double f64 = 0;
                    memcpy(&u64, p, 8); memcpy(&u32, p, 4);
                    memcpy(&f32, p, 4); memcpy(&f64, p, 8);
                    d[@"interpret"] = @{
                        @"u32": @(u32), @"i32": @((int32_t)u32),
                        @"f32": @(f32), @"f64": @(f64),
                        @"u64": [NSString stringWithFormat:@"0x%llx", u64],
                    };
                }
            }
            return TYContent(d);
        }

        if ([name isEqualToString:@"read_value"]) {
            uint64_t addr = 0;
            if (!TYParseAddr(a[@"address"], &addr)) return TYErrContent(@"address 无效");
            NSString *t = [a[@"type"] lowercaseString] ?: @"u32";
            TYMem *mem = [TYMem shared];
            NSMutableDictionary *d = [@{@"address": [NSString stringWithFormat:@"0x%llx", addr],
                                        @"type": t} mutableCopy];
            if ([t isEqualToString:@"i8"] || [t isEqualToString:@"u8"]) {
                TYMemReadResult *r = [mem readAt:addr size:1];
                if (r.ok && r.bytesRead >= 1) {
                    uint8_t v = ((const uint8_t *)r.data.bytes)[0];
                    d[@"value"] = ([t isEqualToString:@"i8"]) ? @((int8_t)v) : @(v);
                } else { d[@"error"] = @"不可读"; }
            } else if ([t isEqualToString:@"i16"] || [t isEqualToString:@"u16"]) {
                uint32_t v = 0;
                if ([mem readU32At:addr value:&v]) {
                    uint16_t x = (uint16_t)v;
                    d[@"value"] = ([t isEqualToString:@"i16"]) ? @((int16_t)x) : @(x);
                } else { d[@"error"] = @"不可读"; }
            } else if ([t isEqualToString:@"i32"] || [t isEqualToString:@"u32"]) {
                uint32_t v = 0;
                if ([mem readU32At:addr value:&v]) {
                    d[@"value"] = ([t isEqualToString:@"i32"]) ? @((int32_t)v) : @(v);
                } else { d[@"error"] = @"不可读"; }
            } else if ([t isEqualToString:@"f32"]) {
                float v = 0;
                if ([mem readFloatAt:addr value:&v]) d[@"value"] = @(v);
                else d[@"error"] = @"不可读";
            } else if ([t isEqualToString:@"f64"]) {
                double v = 0;
                if ([mem readDoubleAt:addr value:&v]) d[@"value"] = @(v);
                else d[@"error"] = @"不可读";
            } else if ([t isEqualToString:@"i64"] || [t isEqualToString:@"u64"] || [t isEqualToString:@"ptr"]) {
                uint64_t v = 0;
                if ([mem readU64At:addr value:&v]) {
                    if ([t isEqualToString:@"i64"]) d[@"value"] = @((int64_t)v);
                    else d[@"value"] = [NSString stringWithFormat:@"0x%llx", v];
                } else { d[@"error"] = @"不可读"; }
            } else {
                return TYErrContent([NSString stringWithFormat:@"不支持的类型 %@", t]);
            }
            return TYContent(d);
        }

        if ([name isEqualToString:@"write_value"]) {
            uint64_t addr = 0;
            if (!TYParseAddr(a[@"address"], &addr)) return TYErrContent(@"address 无效");
            NSString *t = [a[@"type"] lowercaseString] ?: @"u32";
            NSString *vs = a[@"value"];
            double dv = [vs doubleValue];
            NSData *payload = nil;
            if ([t isEqualToString:@"u8"] || [t isEqualToString:@"i8"]) {
                uint8_t v = (uint8_t)dv; payload = [NSData dataWithBytes:&v length:1];
            } else if ([t isEqualToString:@"u16"] || [t isEqualToString:@"i16"]) {
                uint16_t v = (uint16_t)dv; payload = [NSData dataWithBytes:&v length:2];
            } else if ([t isEqualToString:@"u32"] || [t isEqualToString:@"i32"]) {
                uint32_t v = (uint32_t)dv; payload = [NSData dataWithBytes:&v length:4];
            } else if ([t isEqualToString:@"f32"]) {
                float v = (float)dv; payload = [NSData dataWithBytes:&v length:4];
            } else if ([t isEqualToString:@"f64"]) {
                double v = dv; payload = [NSData dataWithBytes:&v length:8];
            } else if ([t isEqualToString:@"u64"] || [t isEqualToString:@"i64"] || [t isEqualToString:@"ptr"]) {
                unsigned long long v = 0;
                [[NSScanner scannerWithString:vs] scanHexLongLong:&v];
                payload = [NSData dataWithBytes:&v length:8];
            } else {
                return TYErrContent([NSString stringWithFormat:@"不支持的类型 %@", t]);
            }
            NSString *err = nil;
            BOOL ok = [[TYMem shared] writeAt:addr data:payload error:&err];
            return TYContent(@{@"address": [NSString stringWithFormat:@"0x%llx", addr],
                               @"written": vs, @"bytes": @(payload.length),
                               @"success": @(ok),
                               @"error": err ?: @""});
        }

        if ([name isEqualToString:@"list_regions"]) {
            uint64_t start = 0, end = 0;
            if (!TYParseAddr(a[@"start"], &start)) return TYErrContent(@"start 无效");
            if (a[@"end"]) TYParseAddr(a[@"end"], &end);
            NSUInteger limit = [a[@"limit"] integerValue] ?: 200;
            NSString *pf = a[@"filter"];
            NSArray *rs = [[TYMem shared] regionsFrom:start to:end limit:limit * 4];
            NSMutableArray *out = [NSMutableArray array];
            for (TYMemRegion *r in rs) {
                if (pf.length) {
                    NSString *ps = r.protectionString;
                    // 支持 rw / r-x / r 之类简写
                    BOOL good = YES;
                    for (NSUInteger i = 0; i < pf.length; i++) {
                        unichar c = [pf characterAtIndex:i];
                        if (c == '-') continue;
                        if ([ps characterAtIndex:i] != c) { good = NO; break; }
                    }
                    if (!good) continue;
                }
                [out addObject:[r dictionaryRepresentation]];
                if (out.count >= limit) break;
            }
            return TYContent(@{@"count": @(out.count), @"regions": out});
        }

        // ============ 搜索 ============
        if ([name isEqualToString:@"scan"]) {
            NSString *tname = a[@"type"];
            TYScanType t = [TYScan typeFromName:tname];
            uint64_t start = 0, end = 0;
            BOOL hasRange = NO;
            if (a[@"start"]) { if (TYParseAddr(a[@"start"], &start)) hasRange = YES; }
            if (a[@"end"]) TYParseAddr(a[@"end"], &end);

            // 限定模块时自动取范围
            NSString *modName = a[@"module"];
            if (modName.length) {
                TYModuleInfo *m = [[TYModule shared] moduleNamed:modName];
                if (!m) return TYErrContent([NSString stringWithFormat:@"模块未找到 %@", modName]);
                start = m.base; end = m.end; hasRange = YES;
            }
            if (!hasRange) {
                // 默认扫全部非系统模块
                NSArray *mods = [[TYModule shared] modulesMatching:nil includeSystem:NO];
                NSMutableArray *hits = [NSMutableArray array];
                NSUInteger perMax = [a[@"max_results"] integerValue] ?: 500;
                for (TYModuleInfo *m in mods) {
                    NSArray *h = [[TYScan shared] scanValue:a[@"value"] type:t
                                                  startAddr:m.base endAddr:m.end
                                               writableOnly:[a[@"writable_only"] boolValue]
                                                    aligned:(a[@"aligned"] ? [a[@"aligned"] boolValue] : YES)
                                                 maxResults:perMax];
                    [hits addObjectsFromArray:h];
                    if (hits.count >= perMax) break;
                }
                gLastResults = hits; gLastType = t;
                NSMutableArray *out = [NSMutableArray array];
                for (TYScanResult *r in hits) [out addObject:[r dictionaryRepresentation]];
                return TYContent(@{@"count": @(hits.count), @"type": tname,
                                   @"results": out,
                                   @"hint": hits.count ? @"用 scan_refine 缩小范围" : @"无命中：确认类型/值，或试试 writable_only"});
            }

            NSUInteger maxR = [a[@"max_results"] integerValue] ?: 500;
            NSArray *hits = [[TYScan shared] scanValue:a[@"value"] type:t
                                             startAddr:start endAddr:end
                                          writableOnly:[a[@"writable_only"] boolValue]
                                               aligned:(a[@"aligned"] ? [a[@"aligned"] boolValue] : YES)
                                            maxResults:maxR];
            gLastResults = hits; gLastType = t;
            NSMutableArray *out = [NSMutableArray array];
            for (TYScanResult *r in hits) [out addObject:[r dictionaryRepresentation]];
            return TYContent(@{@"count": @(hits.count), @"type": tname, @"results": out});
        }

        if ([name isEqualToString:@"scan_refine"]) {
            if (!gLastResults) return TYErrContent(@"还没有扫描结果，请先调用 scan");
            NSString *tname = a[@"type"];
            TYScanType t = tname.length ? [TYScan typeFromName:tname] : gLastType;
            NSArray *hc = [[TYScan shared] refineResults:gLastResults value:a[@"value"] type:t];
            gLastResults = hc; gLastType = t;
            NSMutableArray *out = [NSMutableArray array];
            for (TYScanResult *r in hc) [out addObject:[r dictionaryRepresentation]];
            return TYContent(@{@"count": @(hc.count), @"type": tname ?: @"(沿用)", @"results": out});
        }

        if ([name isEqualToString:@"scan_results"]) {
            if (!gLastResults) return TYContent(@{@"count": @0, @"results": @[],
                                                  @"note": @"还没有扫描结果"});
            NSUInteger limit = [a[@"limit"] integerValue] ?: 100;
            NSArray *src = gLastResults;
            NSUInteger total = src.count;
            if (src.count > limit) src = [src subarrayWithRange:NSMakeRange(0, limit)];
            NSMutableArray *out = [NSMutableArray array];
            if ([a[@"read_values"] boolValue]) {
                NSArray *vals = [[TYScan shared] readValues:src type:gLastType];
                for (NSDictionary *v in vals) [out addObject:v];
                return TYContent(@{@"count": @(out.count), @"total": @(total),
                                   @"values": out});
            }
            for (TYScanResult *r in src) [out addObject:[r dictionaryRepresentation]];
            return TYContent(@{@"count": @(out.count), @"total": @(total), @"results": out});
        }

        if ([name isEqualToString:@"pointer_chain"]) {
            uint64_t base = 0;
            if (!TYParseAddr(a[@"base"], &base)) return TYErrContent(@"base 无效");
            NSArray *offs = a[@"offsets"];
            if (![offs isKindOfClass:[NSArray class]]) return TYErrContent(@"offsets 需为数组");
            NSDictionary *r = [[TYScan shared] resolvePointerChain:base offsets:offs];
            return TYContent(r);
        }

        if ([name isEqualToString:@"find_pointers"]) {
            uint64_t target = 0;
            if (!TYParseAddr(a[@"target"], &target)) return TYErrContent(@"target 无效");
            uint64_t start = 0, end = 0;
            NSString *modName = a[@"module"];
            if (modName.length) {
                TYModuleInfo *m = [[TYModule shared] moduleNamed:modName];
                if (!m) return TYErrContent([NSString stringWithFormat:@"模块未找到 %@", modName]);
                start = m.base; end = m.end;
            } else {
                if (a[@"start"]) TYParseAddr(a[@"start"], &start);
                if (a[@"end"]) TYParseAddr(a[@"end"], &end);
                if (!start) return TYErrContent(@"需要 module 或 start");
            }
            NSUInteger maxR = [a[@"max_results"] integerValue] ?: 200;
            NSUInteger lim = [a[@"limit_bytes"] integerValue] ?: (256u << 20);
            NSArray *hits = [[TYScan shared] findPointersTo:target startAddr:start endAddr:end
                                                 maxResults:maxR limit:lim];
            NSMutableArray *out = [NSMutableArray array];
            for (TYScanResult *r in hits) [out addObject:[r dictionaryRepresentation]];
            return TYContent(@{@"count": @(hits.count), @"target": [NSString stringWithFormat:@"0x%llx", target],
                               @"results": out});
        }

        // ============ il2cpp ============
        TYIl2CppBridge *br = [TYIl2CppBridge shared];

        if ([name isEqualToString:@"il2cpp_status"]) {
            return TYContent(@{@"available": @([br available]),
                               @"failure": [br failureReason] ?: @"",
                               @"images": [br imageNames]});
        }
        if ([name isEqualToString:@"il2cpp_find_class"]) {
            return TYContent([br findClass:a[@"class"] image:a[@"image"]]);
        }
        if ([name isEqualToString:@"il2cpp_list_classes"]) {
            return TYContent([br listClassesInImage:a[@"image"] regex:a[@"regex"]
                                              limit:[a[@"limit"] integerValue]]);
        }
        if ([name isEqualToString:@"il2cpp_fields"]) {
            return TYContent([br fieldsOfClass:a[@"class"] image:a[@"image"]]);
        }
        if ([name isEqualToString:@"il2cpp_methods"]) {
            return TYContent([br methodsOfClass:a[@"class"] image:a[@"image"]]);
        }
        if ([name isEqualToString:@"il2cpp_find_by_field_type"]) {
            return TYContent([br findFieldsOfType:a[@"type_name"] image:a[@"image"]
                                            limit:[a[@"limit"] integerValue]]);
        }
        if ([name isEqualToString:@"il2cpp_navigate"]) {
            return TYContent([br navigate:a]);
        }
        if ([name isEqualToString:@"il2cpp_read_field"]) {
            return TYContent([br readField:a]);
        }
        if ([name isEqualToString:@"il2cpp_write_field"]) {
            return TYContent([br writeField:a]);
        }

        return TYErrContent([NSString stringWithFormat:@"未知工具 %@", name ?: @"?"]);
    } @catch (NSException *e) {
        return TYErrContent([NSString stringWithFormat:@"工具执行异常：%@ (%@)",
                             e.reason ?: @"?", e.name ?: @"?"]);
    }
}

@end
