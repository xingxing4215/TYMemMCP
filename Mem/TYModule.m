//
//  TYModule.m
//  TYMemMCP —— 模块枚举实现
//

#import "TYModule.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach/vm_prot.h>
#import <string.h>
#import <dlfcn.h>

@implementation TYModuleInfo
- (uint64_t)end { return self.base + self.size; }

- (NSString *)uuid {
    const struct mach_header_64 *h = (const struct mach_header_64 *)self.base;
    if (!h) return @"";
    const uint8_t *p = (const uint8_t *)h + sizeof(struct mach_header_64);
    for (uint32_t c = 0; c < h->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_UUID) {
            const struct uuid_command *uc = (const struct uuid_command *)lc;
            return [NSString stringWithFormat:
                    @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    uc->uuid[0], uc->uuid[1], uc->uuid[2], uc->uuid[3],
                    uc->uuid[4], uc->uuid[5], uc->uuid[6], uc->uuid[7],
                    uc->uuid[8], uc->uuid[9], uc->uuid[10], uc->uuid[11],
                    uc->uuid[12], uc->uuid[13], uc->uuid[14], uc->uuid[15]];
        }
        if (lc->cmdsize == 0) break;
        p += lc->cmdsize;
    }
    return @"";
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [@{
        @"name": self.name ?: @"",
        @"path": self.path ?: @"",
        @"base": [NSString stringWithFormat:@"0x%llx", self.base],
        @"size": @(self.size),
        @"end": [NSString stringWithFormat:@"0x%llx", self.end],
        @"slide": [NSString stringWithFormat:@"0x%llx", (uint64_t)self.slide],
        @"index": @(self.index),
        @"system": @(self.isSystem),
    } mutableCopy];
    NSString *u = self.uuid;
    if (u.length) d[@"uuid"] = u;
    if (self.segments.count) d[@"segments"] = self.segments;
    return d;
}
@end

#pragma mark -

@interface TYModule ()
@property (nonatomic, assign) BOOL watching;
@end

@implementation TYModule

+ (instancetype)shared {
    static TYModule *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TYModule alloc] init]; });
    return s;
}

- (NSArray<TYModuleInfo *> *)allModules {
    NSMutableArray *out = [NSMutableArray array];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header_64 *h =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;

        TYModuleInfo *m = [[TYModuleInfo alloc] init];
        m.index = i;
        m.slide = _dyld_get_image_vmaddr_slide(i);
        const char *nm = _dyld_get_image_name(i);
        m.path = nm ? [NSString stringWithUTF8String:nm] : @"";
        m.name = m.path.lastPathComponent ?: @"";

        // 遍历段：取 __TEXT 作为基址与大小，同时收集全部段
        NSMutableArray *segs = [NSMutableArray array];
        const uint8_t *p = (const uint8_t *)h + sizeof(struct mach_header_64);
        uint64_t textVm = 0, textSize = 0;
        for (uint32_t c = 0; c < h->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
                NSString *sname = [NSString stringWithUTF8String:sg->segname];
                uint64_t addr = sg->vmaddr + m.slide;
                [segs addObject:@{
                    @"name": sname ?: @"",
                    @"addr": [NSString stringWithFormat:@"0x%llx", addr],
                    @"size": @(sg->vmsize),
                    @"file_size": @(sg->filesize),
                    @"prot": [NSString stringWithFormat:@"%c%c%c",
                              (sg->initprot & VM_PROT_READ) ? 'r' : '-',
                              (sg->initprot & VM_PROT_WRITE) ? 'w' : '-',
                              (sg->initprot & VM_PROT_EXECUTE) ? 'x' : '-'],
                }];
                if (strcmp(sg->segname, "__TEXT") == 0) {
                    textVm = sg->vmaddr;
                    textSize = sg->vmsize;
                }
            }
            if (lc->cmdsize == 0) break;
            p += lc->cmdsize;
        }
        m.fileBase = textVm;
        m.base = textVm + m.slide;
        m.size = textSize;
        m.segments = segs;
        m.isSystem = [m.path hasPrefix:@"/usr/lib/"] ||
                     [m.path hasPrefix:@"/System/"] ||
                     [m.path hasPrefix:@"/Developer/"];
        [out addObject:m];
    }
    return out;
}

- (NSArray<TYModuleInfo *> *)modulesMatching:(NSString *)filter
                               includeSystem:(BOOL)includeSystem {
    NSArray *all = [self allModules];
    NSMutableArray *out = [NSMutableArray array];
    for (TYModuleInfo *m in all) {
        if (!includeSystem && m.isSystem) continue;
        if (filter.length) {
            BOOL hit = [m.name rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound
                    || [m.path rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (!hit) continue;
        }
        [out addObject:m];
    }
    return out;
}

- (TYModuleInfo *)moduleNamed:(NSString *)name {
    if (!name.length) return nil;
    for (TYModuleInfo *m in [self allModules]) {
        if ([m.name isEqualToString:name]) return m;
    }
    for (TYModuleInfo *m in [self allModules]) {
        if ([m.name hasPrefix:name]) return m;
    }
    return nil;
}

- (NSDictionary *)lookupAddress:(uint64_t)addr {
    for (TYModuleInfo *m in [self allModules]) {
        if (addr >= m.base && addr < m.end) {
            // 再定位到具体段
            NSString *segName = nil;
            uint64_t segOff = 0;
            for (NSDictionary *s in m.segments) {
                uint64_t a = strtoull([s[@"addr"] UTF8String], NULL, 16);
                uint64_t sz = [s[@"size"] unsignedLongLongValue];
                if (addr >= a && addr < a + sz) {
                    segName = s[@"name"];
                    segOff = addr - a;
                    break;
                }
            }
            NSMutableDictionary *d = [@{
                @"found": @YES,
                @"address": [NSString stringWithFormat:@"0x%llx", addr],
                @"module": m.name,
                @"path": m.path,
                @"module_base": [NSString stringWithFormat:@"0x%llx", m.base],
                @"offset": [NSString stringWithFormat:@"0x%llx", addr - m.base],
                @"offset_dec": @(addr - m.base),
            } mutableCopy];
            if (segName) {
                d[@"segment"] = segName;
                d[@"segment_offset"] = [NSString stringWithFormat:@"0x%llx", segOff];
            }
            return d;
        }
    }
    return @{@"found": @NO,
             @"address": [NSString stringWithFormat:@"0x%llx", addr],
             @"note": @"地址不属于任何已加载模块（可能在堆/栈/匿名映射）"};
}

/// dyld 注册回调：热更 dylib 加载后模块表变化，记录下来供上层感知。
static void TYModuleAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
}

- (void)startWatching {
    if (self.watching) return;
    self.watching = YES;
    _dyld_register_func_for_add_image(TYModuleAdded);
}

@end
