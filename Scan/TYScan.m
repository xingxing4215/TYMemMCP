//
//  TYScan.m
//  TYMemMCP —— 内存搜索层实现
//

#import "TYScan.h"
#import "TYMem.h"
#import "TYModule.h"
#import <string.h>
#import <math.h>

#pragma mark - TYScanResult

@implementation TYScanResult
- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [@{
        @"address": [NSString stringWithFormat:@"0x%llx", self.address],
        @"address_dec": @(self.address),
    } mutableCopy];
    NSDictionary *lk = [[TYModule shared] lookupAddress:self.address];
    if (lk) {
        if (lk[@"module"])         d[@"module"] = lk[@"module"];
        if (lk[@"offset"])         d[@"module_offset"] = lk[@"offset"];
        if (lk[@"segment"])        d[@"segment"] = lk[@"segment"];
    } else if (self.moduleName.length) {
        d[@"module"] = self.moduleName;
    }
    if (self.preview.length) d[@"preview"] = self.preview;
    return d;
}
@end

#pragma mark - TYScan

@implementation TYScan

+ (instancetype)shared {
    static TYScan *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TYScan alloc] init]; });
    return s;
}

+ (TYScanType)typeFromName:(NSString *)name {
    NSString *n = [name lowercaseString] ?: @"";
    if ([n isEqualToString:@"i8"]  || [n isEqualToString:@"byte"])   return TYScanI8;
    if ([n isEqualToString:@"i16"] || [n isEqualToString:@"short"])  return TYScanI16;
    if ([n isEqualToString:@"i32"] || [n isEqualToString:@"int"] ||
        [n isEqualToString:@"dword"])                                return TYScanI32;
    if ([n isEqualToString:@"i64"] || [n isEqualToString:@"long"] ||
        [n isEqualToString:@"qword"])                                return TYScanI64;
    if ([n isEqualToString:@"u8"]  || [n isEqualToString:@"ubyte"])  return TYScanU8;
    if ([n isEqualToString:@"u16"] || [n isEqualToString:@"ushort"]) return TYScanU16;
    if ([n isEqualToString:@"u32"] || [n isEqualToString:@"uint"])   return TYScanU32;
    if ([n isEqualToString:@"u64"] || [n isEqualToString:@"ulong"])  return TYScanU64;
    if ([n isEqualToString:@"f32"] || [n isEqualToString:@"float"])  return TYScanF32;
    if ([n isEqualToString:@"f64"] || [n isEqualToString:@"double"]) return TYScanF64;
    if ([n isEqualToString:@"bytes"] || [n isEqualToString:@"hex"])  return TYScanBytes;
    if ([n isEqualToString:@"utf16"] || [n isEqualToString:@"wstring"]) return TYScanUtf16;
    if ([n isEqualToString:@"utf8"] || [n isEqualToString:@"string"])   return TYScanUtf8;
    return TYScanF32;
}

static NSUInteger TYTypeWidth(TYScanType t) {
    switch (t) {
        case TYScanI8: case TYScanU8:   return 1;
        case TYScanI16: case TYScanU16: return 2;
        case TYScanI32: case TYScanU32: case TYScanF32: return 4;
        default: return 8;
    }
}

/// 把请求值序列化成字节（小端）
static NSData *TYEncodeValue(id value, TYScanType type, NSError **err) {
    switch (type) {
        case TYScanUtf8: {
            NSString *s = [value isKindOfClass:[NSString class]] ? value : [value description];
            NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
            return d.length ? d : nil;
        }
        case TYScanUtf16: {
            NSString *s = [value isKindOfClass:[NSString class]] ? value : [value description];
            NSData *d = [s dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
            return d.length ? d : nil;
        }
        case TYScanBytes: {
            // 接受 "0A 0B 0C" / "0a0b0c" / "0x0A,0x0B"
            NSString *s = [value isKindOfClass:[NSString class]] ? value : [value description];
            NSMutableString *clean = [NSMutableString string];
            for (NSUInteger i = 0; i < s.length; i++) {
                unichar c = [s characterAtIndex:i];
                if (isxdigit(c)) [clean appendFormat:@"%C", c];
            }
            if (clean.length == 0 || clean.length % 2 != 0) {
                if (err) *err = [NSError errorWithDomain:@"TYScan" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"bytes 需为偶数个十六进制字符"}];
                return nil;
            }
            NSMutableData *d = [NSMutableData data];
            for (NSUInteger i = 0; i < clean.length; i += 2) {
                unsigned v = 0;
                [[NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(i, 2)]]
                    scanHexInt:&v];
                uint8_t b = (uint8_t)v;
                [d appendBytes:&b length:1];
            }
            return d;
        }
        default: break;
    }

    if (![value isKindOfClass:[NSNumber class]]) {
        // 允许数字字符串
        NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
        NSNumber *n = [f numberFromString:[value description]];
        if (!n) {
            if (err) *err = [NSError errorWithDomain:@"TYScan" code:2
                             userInfo:@{NSLocalizedDescriptionKey: @"值不是数字"}];
            return nil;
        }
        value = n;
    }
    NSNumber *n = value;
    uint8_t buf[8] = {0};
    switch (type) {
        case TYScanI8: case TYScanU8: { int8_t v = (int8_t)n.integerValue; memcpy(buf,&v,1); return [NSData dataWithBytes:buf length:1]; }
        case TYScanI16: case TYScanU16: { int16_t v = (int16_t)n.integerValue; memcpy(buf,&v,2); return [NSData dataWithBytes:buf length:2]; }
        case TYScanI32: case TYScanU32: { int32_t v = (int32_t)n.integerValue; memcpy(buf,&v,4); return [NSData dataWithBytes:buf length:4]; }
        case TYScanI64: case TYScanU64: { int64_t v = (int64_t)n.longLongValue; memcpy(buf,&v,8); return [NSData dataWithBytes:buf length:8]; }
        case TYScanF32: { float v = n.floatValue;  memcpy(buf,&v,4); return [NSData dataWithBytes:buf length:4]; }
        case TYScanF64: { double v = n.doubleValue; memcpy(buf,&v,8); return [NSData dataWithBytes:buf length:8]; }
        default: return nil;
    }
}

/// 从缓冲区读出一个值（按类型）
static BOOL TYDecodeAt(const uint8_t *p, TYScanType t, double *outNum, uint64_t *outInt) {
    switch (t) {
        case TYScanI8:  { int8_t  v; memcpy(&v,p,1); *outInt=(uint64_t)(v&0xff); *outNum=v; return YES; }
        case TYScanU8:  { uint8_t v; memcpy(&v,p,1); *outInt=v; *outNum=v; return YES; }
        case TYScanI16: { int16_t v; memcpy(&v,p,2); *outInt=(uint64_t)v; *outNum=v; return YES; }
        case TYScanU16: { uint16_t v;memcpy(&v,p,2); *outInt=v; *outNum=v; return YES; }
        case TYScanI32: { int32_t v; memcpy(&v,p,4); *outInt=(uint64_t)v; *outNum=v; return YES; }
        case TYScanU32: { uint32_t v;memcpy(&v,p,4); *outInt=v; *outNum=v; return YES; }
        case TYScanI64: { int64_t v; memcpy(&v,p,8); *outInt=(uint64_t)v; *outNum=(double)v; return YES; }
        case TYScanU64: { uint64_t v;memcpy(&v,p,8); *outInt=v; *outNum=(double)v; return YES; }
        case TYScanF32: { float v;   memcpy(&v,p,4); *outNum=v; *outInt=0; return YES; }
        case TYScanF64: { double v;  memcpy(&v,p,8); *outNum=v; *outInt=0; return YES; }
        default: return NO;
    }
}

#pragma mark - 精确搜索

- (NSArray<TYScanResult *> *)scanValue:(id)value
                                  type:(TYScanType)type
                             startAddr:(uint64_t)start
                               endAddr:(uint64_t)end
                          writableOnly:(BOOL)writableOnly
                               aligned:(BOOL)aligned
                            maxResults:(NSUInteger)maxResults {
    NSError *err = nil;
    NSData *needle = TYEncodeValue(value, type, &err);
    if (!needle.length) return @[];

    if (maxResults == 0) maxResults = 2000;
    if (end == 0) end = UINT64_MAX;

    const uint8_t *nd = needle.bytes;
    NSUInteger nlen = needle.length;
    NSUInteger align = aligned ? TYTypeWidth(type) : 1;
    if (align < 1) align = 1;

    NSMutableArray *hits = [NSMutableArray array];
    TYMem *mem = [TYMem shared];

    // 按 region 推进
    uint64_t cur = start;
    NSUInteger guard = 0;
    while (cur < end && hits.count < maxResults && guard++ < 200000) {
        TYMemRegion *r = [mem regionAt:cur];
        if (!r) {
            uint64_t np = (cur + 0x4000) & ~0x3FFFull;
            if (np <= cur) break;
            cur = np;
            continue;
        }
        uint64_t rEnd = r.address + r.size;
        if (rEnd <= cur) break;

        BOOL skipRegion = !r.readable || (writableOnly && !r.writable);
        if (skipRegion) { cur = rEnd; continue; }

        // 分块读该 region
        uint64_t pos = cur;
        const uint64_t CH = 1ull << 20;     // 1MB 一块
        while (pos < rEnd && hits.count < maxResults) {
            uint64_t chunk = MIN(CH, rEnd - pos);
            // 多读 nlen-1 字节，处理跨块命中
            uint64_t readLen = MIN(chunk + nlen - 1, rEnd - pos);
            TYMemReadResult *rr = [mem readAt:pos size:readLen];
            if (!rr.ok || rr.bytesRead < nlen) { pos += chunk; continue; }

            const uint8_t *base = rr.data.bytes;
            NSUInteger avail = (NSUInteger)rr.bytesRead;
            if (avail < nlen) { pos += chunk; continue; }

            for (NSUInteger i = 0; i + nlen <= avail; i += align) {
                if (memcmp(base + i, nd, nlen) != 0) continue;
                uint64_t addr = pos + i;
                if (addr >= end) break;

                TYScanResult *hit = [[TYScanResult alloc] init];
                hit.address = addr;
                // 预览：该地址起 16 字节
                NSUInteger pv = MIN((NSUInteger)16, avail - i);
                NSMutableString *pvS = [NSMutableString string];
                for (NSUInteger k = 0; k < pv; k++) [pvS appendFormat:@"%02X ", base[i + k]];
                hit.preview = pvS;
                [hits addObject:hit];

                if (hits.count >= maxResults) break;
            }
            pos += chunk;
        }
        cur = rEnd;
    }
    return hits;
}

#pragma mark - 筛选

- (NSArray<TYScanResult *> *)refineResults:(NSArray<TYScanResult *> *)prev
                                     value:(id)value
                                      type:(TYScanType)type {
    if (!prev.count) return @[];
    NSData *needle = TYEncodeValue(value, type, NULL);
    if (!needle.length) return prev;
    NSMutableArray *out = [NSMutableArray array];
    TYMem *mem = [TYMem shared];
    for (TYScanResult *r in prev) {
        TYMemReadResult *rr = [mem readAt:r.address size:needle.length];
        if (!rr.ok || rr.bytesRead < needle.length) continue;
        if (memcmp(rr.data.bytes, needle.bytes, needle.length) == 0) [out addObject:r];
    }
    return out;
}

- (NSArray<NSDictionary *> *)readValues:(NSArray<TYScanResult *> *)addrs
                                   type:(TYScanType)type {
    NSMutableArray *out = [NSMutableArray array];
    TYMem *mem = [TYMem shared];
    NSUInteger w = TYTypeWidth(type);
    if (type == TYScanBytes || type == TYScanUtf8 || type == TYScanUtf16) w = 32;
    for (TYScanResult *r in addrs) {
        TYMemReadResult *rr = [mem readAt:r.address size:w];
        NSMutableDictionary *d = [@{@"address": [NSString stringWithFormat:@"0x%llx", r.address]} mutableCopy];
        if (rr.ok && rr.bytesRead >= TYTypeWidth(type)) {
            double num = 0; uint64_t iv = 0;
            if (TYDecodeAt(rr.data.bytes, type, &num, &iv)) {
                if (type == TYScanF32 || type == TYScanF64) d[@"value"] = @(num);
                else d[@"value"] = @(iv);
            }
            d[@"hex"] = [[TYScanResult alloc] init].preview ?: @"";
            const uint8_t *p = rr.data.bytes;
            NSMutableString *s = [NSMutableString string];
            for (NSUInteger k = 0; k < rr.bytesRead && k < 32; k++) [s appendFormat:@"%02X", p[k]];
            d[@"hex"] = s;
        } else {
            d[@"error"] = @"不可读";
        }
        [out addObject:d];
    }
    return out;
}

#pragma mark - 指针链

- (NSDictionary *)resolvePointerChain:(uint64_t)base
                              offsets:(NSArray<NSNumber *> *)offsets {
    TYMem *mem = [TYMem shared];
    NSMutableArray *steps = [NSMutableArray array];

    uint64_t cur = base;
    [steps addObject:@{@"step": @0,
                       @"base": [NSString stringWithFormat:@"0x%llx", base]}];
    if (![mem isReadable:cur]) {
        return @{@"ok": @NO,
                 @"error": @"基址不可读",
                 @"base": [NSString stringWithFormat:@"0x%llx", base],
                 @"steps": steps};
    }

    for (NSUInteger i = 0; i < offsets.count; i++) {
        uint64_t ptr = 0;
        if (![mem readU64At:cur value:&ptr]) {
            return @{@"ok": @NO,
                     @"error": [NSString stringWithFormat:@"第 %lu 跳解引用失败", (unsigned long)i],
                     @"steps": steps};
        }
        int64_t off = offsets[i].longLongValue;
        uint64_t next = ptr + (uint64_t)off;
        [steps addObject:@{
            @"step": @(i + 1),
            @"read_at": [NSString stringWithFormat:@"0x%llx", cur],
            @"ptr": [NSString stringWithFormat:@"0x%llx", ptr],
            @"offset": @(off),
            @"next": [NSString stringWithFormat:@"0x%llx", next],
        }];
        if (ptr == 0) {
            return @{@"ok": @NO, @"error": @"空指针", @"steps": steps};
        }
        cur = next;
        if (![mem isReadable:cur]) {
            return @{@"ok": @NO, @"error": @"中间地址不可读", @"steps": steps};
        }
    }

    return @{@"ok": @YES,
             @"address": [NSString stringWithFormat:@"0x%llx", cur],
             @"steps": steps,
             @"module": [[TYModule shared] lookupAddress:cur] ?: @{}};
}

#pragma mark - 指针扫描

- (NSArray<TYScanResult *> *)findPointersTo:(uint64_t)target
                                  startAddr:(uint64_t)start
                                    endAddr:(uint64_t)end
                                 maxResults:(NSUInteger)maxResults
                                       limit:(NSUInteger)scanLimit {
    if (maxResults == 0) maxResults = 500;
    if (scanLimit == 0) scanLimit = 1ull << 28;      // 默认只扫 256MB
    if (end == 0) end = start + scanLimit;
    if (end - start > scanLimit) end = start + scanLimit;

    NSMutableArray *hits = [NSMutableArray array];
    TYMem *mem = [TYMem shared];
    uint64_t needle = target;
    uint64_t scanned = 0;

    uint64_t cur = start;
    NSUInteger guard = 0;
    while (cur < end && hits.count < maxResults && scanned < scanLimit && guard++ < 100000) {
        TYMemRegion *r = [mem regionAt:cur];
        if (!r) {
            uint64_t np = (cur + 0x4000) & ~0x3FFFull;
            if (np <= cur) break;
            cur = np; continue;
        }
        uint64_t rEnd = r.address + r.size;
        if (rEnd <= cur) break;
        // 指针一定在可写页（堆/数据段），只扫这些
        if (!r.readable || !r.writable) { cur = rEnd; continue; }

        uint64_t pos = cur;
        const uint64_t CH = 1ull << 20;
        while (pos < rEnd && hits.count < maxResults) {
            uint64_t chunk = MIN(CH, rEnd - pos);
            TYMemReadResult *rr = [mem readAt:pos size:chunk];
            scanned += chunk;
            if (!rr.ok || rr.bytesRead < 8) { pos += chunk; continue; }
            const uint8_t *b = rr.data.bytes;
            NSUInteger n = (NSUInteger)rr.bytesRead;
            for (NSUInteger i = 0; i + 8 <= n; i += 8) {
                uint64_t v = 0;
                memcpy(&v, b + i, 8);
                if (v != needle) continue;
                TYScanResult *h = [[TYScanResult alloc] init];
                h.address = pos + i;
                [hits addObject:h];
                if (hits.count >= maxResults) break;
            }
            pos += chunk;
        }
        cur = rEnd;
    }
    return hits;
}

@end
