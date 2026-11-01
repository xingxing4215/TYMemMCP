//
//  TYMem.m
//  TYMemMCP —— 内存读写层实现
//

#import "TYMem.h"
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/vm_region.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

//
// ═══════════════════════════════════════════════════════════════════════
// 为什么用 vm_* 而不是 mach_vm_*
// ═══════════════════════════════════════════════════════════════════════
//
// iOS SDK 里的 <mach/mach_vm.h> 是一个**故意留空的桩头**：
//
//     #error mach_vm.h unsupported.
//
// 包含它就编译失败（CI 实测：Mem/TYMem.m:7 → mach_vm.h unsupported）。
// mach_vm_* 属于内核接口，Apple 不在公共 SDK 里暴露。
//
// 对应支撑能力由 <mach/vm_map.h> 里的 vm_* 家族提供：
//
//     mach_vm_region      → vm_region_64
//     mach_vm_read        → vm_read
//     mach_vm_deallocate  → vm_deallocate
//     mach_vm_write       → vm_write
//
// 本插件在**自身进程内**操作，vm_* 完全够用，且是受支持的公共 API。
// 若换成外部进程调试（task_for_pid），才需要 mach_vm_* 的 64 位语义，
// 那种场景不属于本插件的定位。
//
// 返回值类型也从 mach_vm_* 换成 vm_*：地址用 vm_address_t，
// 大小用 vm_size_t，调用点相应调整。
//

#pragma mark - TYMemRegion

@implementation TYMemRegion
- (BOOL)readable   { return (self.protection & VM_PROT_READ) != 0; }
- (BOOL)writable   { return (self.protection & VM_PROT_WRITE) != 0; }
- (BOOL)executable { return (self.protection & VM_PROT_EXECUTE) != 0; }
- (NSString *)protectionString {
    return [NSString stringWithFormat:@"%c%c%c",
            self.readable ? 'r' : '-',
            self.writable ? 'w' : '-',
            self.executable ? 'x' : '-'];
}
- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [@{
        @"address": @(self.address),
        @"address_hex": [NSString stringWithFormat:@"0x%llx", self.address],
        @"size": @(self.size),
        @"protection": self.protectionString,
        @"shared": @(self.shared),
        @"reserved": @(self.reserved),
    } mutableCopy];
    if (self.segmentName.length) d[@"segment"] = self.segmentName;
    if (self.moduleName.length)  d[@"module"]  = self.moduleName;
    return d;
}
@end

#pragma mark - TYMemReadResult

@implementation TYMemReadResult
- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [@{
        @"ok": @(self.ok),
        @"address": [NSString stringWithFormat:@"0x%llx", self.address],
        @"requested_size": @(self.requestedSize),
        @"bytes_read": @(self.bytesRead),
        @"partial": @(self.partial),
    } mutableCopy];
    if (self.error.length) d[@"error"] = self.error;
    if (self.gaps.count)  d[@"gaps"] = self.gaps;
    if (self.data.length) d[@"hex"] = [TYMemReadResult hexOf:self.data];
    return d;
}
+ (NSString *)hexOf:(NSData *)d {
    const uint8_t *p = d.bytes;
    NSUInteger n = d.length;
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02X", p[i]];
    return s;
}
@end

#pragma mark - TYMem

@interface TYMem ()
@property (nonatomic, assign) mach_port_t task;
@end

@implementation TYMem

+ (instancetype)shared {
    static TYMem *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TYMem alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _task = mach_task_self_;
    }
    return self;
}

#pragma mark - region 查询

/// 用模块表给 region 补上段名/模块名（纯展示用，失败不影响主流程）
- (void)annotate:(TYMemRegion *)r {
    static NSArray<NSDictionary *> *images = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *arr = [NSMutableArray array];
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const struct mach_header_64 *h =
                (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (!h || h->magic != MH_MAGIC_64) continue;
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            const char *nm = _dyld_get_image_name(i);
            uint64_t textSize = 0, textStart = 0;
            const uint8_t *p = (const uint8_t *)h + sizeof(struct mach_header_64);
            for (uint32_t c = 0; c < h->ncmds; c++) {
                const struct load_command *lc = (const struct load_command *)p;
                if (lc->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
                    if (strcmp(sg->segname, "__TEXT") == 0) {
                        textStart = sg->vmaddr + slide;
                        textSize  = sg->vmsize;
                        break;
                    }
                }
                if (lc->cmdsize == 0) break;
                p += lc->cmdsize;
            }
            if (textSize) {
                [arr addObject:@{@"name": nm ? [NSString stringWithUTF8String:nm] : @"?",
                                 @"path": nm ? [NSString stringWithUTF8String:nm] : @"?",
                                 @"base": @(textStart),
                                 @"end": @(textStart + textSize)}];
            }
        }
        // 按基址降序，便于二分找最近的模块
        images = [arr sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"base"] compare:a[@"base"]];
        }];
    });
    for (NSDictionary *im in images) {
        uint64_t base = [im[@"base"] unsignedLongLongValue];
        uint64_t end  = [im[@"end"] unsignedLongLongValue];
        if (r.address >= base && r.address < end) {
            NSString *path = im[@"path"];
            r.moduleName = path.lastPathComponent;
            r.segmentName = @"__TEXT";
            return;
        }
    }
}

- (TYMemRegion *)regionAt:(uint64_t)addr {
    vm_address_t a = (vm_address_t)addr;
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(self.task, &a, &sz, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &cnt, &obj);
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    if (kr != KERN_SUCCESS) return nil;

    TYMemRegion *r = [[TYMemRegion alloc] init];
    r.address = a;
    r.size = sz;
    r.protection = info.protection;
    r.maxProtection = info.max_protection;
    r.shared = info.shared != 0;
    r.reserved = info.reserved != 0;
    [self annotate:r];
    return r;
}

- (NSArray<TYMemRegion *> *)regionsFrom:(uint64_t)start to:(uint64_t)end
                                  limit:(NSUInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    uint64_t cur = start;
    while (out.count < (limit ? limit : NSUIntegerMax)) {
        TYMemRegion *r = [self regionAt:cur];
        if (!r) break;
        [out addObject:r];
        uint64_t next = r.address + r.size;
        if (next <= cur) break;                 // 防死循环
        if (end && next >= end) break;
        cur = next;
        if (cur == 0) break;
    }
    return out;
}

#pragma mark - 读

- (TYMemReadResult *)readAt:(uint64_t)addr size:(uint64_t)size {
    TYMemReadResult *res = [[TYMemReadResult alloc] init];
    res.address = addr;
    res.requestedSize = size;

    if (size == 0) {
        res.ok = YES; res.data = [NSData data]; res.bytesRead = 0;
        return res;
    }
    if (size > (64ull << 20)) {                 // 单次上限 64MB，防误用
        res.error = @"请求过大（上限 64MB/次）";
        return res;
    }

    NSMutableData *acc = [NSMutableData dataWithCapacity:(NSUInteger)size];
    NSMutableArray *gaps = [NSMutableArray array];
    uint64_t remain = size;
    uint64_t cur = addr;
    BOOL anyGap = NO;

    while (remain > 0) {
        TYMemRegion *r = [self regionAt:cur];
        if (!r) {
            // 该地址未映射：记一个空洞，跳到下一页边界继续尝试
            anyGap = YES;
            [gaps addObject:[NSString stringWithFormat:@"0x%llx", cur]];
            uint64_t nextPage = (cur + 0x4000) & ~0x3FFFull;
            uint64_t skip = nextPage - cur;
            if (skip > remain) skip = remain;
            // 空洞用 0 填充，保持偏移对齐（调用方按 gaps 判断该段无效）
            [acc increaseLengthBy:(NSUInteger)skip];
            cur += skip;
            remain -= skip;
            continue;
        }

        if (!r.readable) {
            anyGap = YES;
            [gaps addObject:[NSString stringWithFormat:@"0x%llx", cur]];
            uint64_t skip = MIN(remain, r.address + r.size - cur);
            NSMutableData *pad = [NSMutableData dataWithLength:(NSUInteger)skip];
            [acc appendData:pad];
            cur += skip;
            remain -= skip;
            continue;
        }

        // 只在可读 region 内读，且不跨越 region 边界
        uint64_t regionEnd = r.address + r.size;
        uint64_t chunk = MIN(remain, regionEnd - cur);

        uint64_t done = 0;
        while (done < chunk) {
            uint64_t want = chunk - done;
            // vm_read 单次不要太大，分块更稳
            uint64_t step = MIN(want, 1ull << 20);
            vm_offset_t buf = 0;
            mach_msg_type_number_t got = 0;
            kern_return_t kr = vm_read(self.task, (vm_address_t)(cur + done),
                                       (vm_size_t)step, &buf, &got);
            if (kr != KERN_SUCCESS || got == 0) {
                if (res.kr == 0) res.kr = kr;
                anyGap = YES;
                [gaps addObject:[NSString stringWithFormat:@"0x%llx", cur + done]];
                NSMutableData *pad = [NSMutableData dataWithLength:(NSUInteger)(chunk - done)];
                [acc appendData:pad];
                done = chunk;
                break;
            }
            [acc appendBytes:(const void *)buf length:got];
            vm_deallocate(mach_task_self(), buf, got);
            done += got;
        }
        cur += chunk;
        remain -= chunk;
    }

    res.data = acc;
    res.bytesRead = acc.length;
    res.gaps = gaps.count ? gaps : nil;
    res.partial = anyGap;
    res.ok = YES;
    if (anyGap && acc.length == 0) {
        res.ok = NO;
        res.error = @"该地址不可读（未映射或权限不足）";
    }
    return res;
}

- (BOOL)isReadable:(uint64_t)addr {
    TYMemRegion *r = [self regionAt:addr];
    return r != nil && r.readable;
}

#pragma mark - 写

- (BOOL)writeAt:(uint64_t)addr data:(NSData *)data error:(NSString **)err {
    if (data.length == 0) { if (err) *err = @"空数据"; return NO; }

    // 整段必须落在同一个可写 region 内 —— 不跨 region、不改权限
    TYMemRegion *r = [self regionAt:addr];
    if (!r) { if (err) *err = @"地址未映射"; return NO; }
    if (!r.writable) {
        if (err) *err = [NSString stringWithFormat:@"页不可写（权限 %@）", r.protectionString];
        return NO;
    }
    if (addr + data.length > r.address + r.size) {
        if (err) *err = @"写入跨越 region 边界，已拒绝";
        return NO;
    }

    kern_return_t kr = vm_write(self.task, (vm_address_t)addr,
                                (vm_offset_t)data.bytes,
                                (mach_msg_type_number_t)data.length);
    if (kr != KERN_SUCCESS) {
        if (err) *err = [NSString stringWithFormat:@"vm_write 失败 kr=%d", kr];
        return NO;
    }
    return YES;
}

#pragma mark - 便捷标量

- (BOOL)readU64At:(uint64_t)addr value:(uint64_t *)out {
    TYMemReadResult *r = [self readAt:addr size:8];
    if (!r.ok || r.bytesRead < 8) return NO;
    memcpy(out, r.data.bytes, 8);
    return YES;
}
- (BOOL)readU32At:(uint64_t)addr value:(uint32_t *)out {
    TYMemReadResult *r = [self readAt:addr size:4];
    if (!r.ok || r.bytesRead < 4) return NO;
    memcpy(out, r.data.bytes, 4);
    return YES;
}
- (BOOL)readFloatAt:(uint64_t)addr value:(float *)out {
    TYMemReadResult *r = [self readAt:addr size:4];
    if (!r.ok || r.bytesRead < 4) return NO;
    memcpy(out, r.data.bytes, 4);
    return YES;
}
- (BOOL)readDoubleAt:(uint64_t)addr value:(double *)out {
    TYMemReadResult *r = [self readAt:addr size:8];
    if (!r.ok || r.bytesRead < 8) return NO;
    memcpy(out, r.data.bytes, 8);
    return YES;
}

- (BOOL)followPointers:(uint64_t)addr depth:(int)depth out:(uint64_t *)out {
    uint64_t cur = addr;
    for (int i = 0; i < depth; i++) {
        uint64_t v = 0;
        if (![self readU64At:cur value:&v]) return NO;
        if (v == 0) return NO;                  // 空指针终止
        cur = v;
    }
    *out = cur;
    return YES;
}

@end
