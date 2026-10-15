//
//  NCMachO.m
//  进程内 Mach-O 镜像与符号表工具
//

#if DEBUG || NOCOMPILE_FORCE_ENABLE

#import "NCMachO.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <string.h>

@implementation NCImage

- (instancetype)initWithHeader:(const struct mach_header_64 *)header slide:(intptr_t)slide path:(NSString *)path {
    self = [super init];
    if (self) {
        _header = header;
        _slide = slide;
        _path = [path copy];
    }
    return self;
}

@end

/// 已注入镜像的路径集合
static NSMutableSet<NSString *> *NCInjectedPaths(void) {
    static NSMutableSet<NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = [NSMutableSet set];
    });
    return paths;
}

void NCRegisterInjectedImagePath(NSString *path) {
    @synchronized (NCInjectedPaths()) {
        [NCInjectedPaths() addObject:path];
    }
}

/// NoCompile 客户端自身所在镜像的路径，需要从"App 镜像"中排除，避免改写自己
static const char *NCSelfImagePath(void) {
    static const char *selfPath;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Dl_info info;
        if (dladdr((const void *)&NCSelfImagePath, &info) && info.dli_fname) {
            selfPath = strdup(info.dli_fname);
        }
    });
    return selfPath;
}

/// 判断一个镜像路径是否属于 App 自身
static BOOL NCIsAppImagePath(const char *path, NSString *bundlePath) {
    if (!path) {
        return NO;
    }
    const char *selfPath = NCSelfImagePath();
    // 客户端以静态库形式链入主程序时，selfPath 就是主程序，此时不能排除
    if (selfPath && strcmp(path, selfPath) == 0 && strstr(path, "NoCompileClient") != NULL) {
        return NO;
    }
    NSString *imagePath = @(path);
    @synchronized (NCInjectedPaths()) {
        if ([NCInjectedPaths() containsObject:imagePath]) {
            return YES;
        }
    }
    if (bundlePath.length > 0 && [imagePath hasPrefix:bundlePath]) {
        return YES;
    }
    // 模拟器 / macOS 上，Xcode 可能通过 DYLD_FRAMEWORK_PATH 直接加载 DerivedData 中的 framework
    if ([imagePath containsString:@"/Build/Products/"] || [imagePath containsString:@"/DerivedData/"]) {
        return YES;
    }
    return NO;
}

NSArray<NCImage *> *NCAppImages(void) {
    NSMutableArray<NCImage *> *images = [NSMutableArray array];
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) {
            continue;
        }
        if (!NCIsAppImagePath(name, bundlePath)) {
            continue;
        }
        [images addObject:[[NCImage alloc] initWithHeader:(const struct mach_header_64 *)header
                                                    slide:_dyld_get_image_vmaddr_slide(i)
                                                     path:@(name)]];
    }
    return images;
}

NCImage *NCImageForPath(NSString *path) {
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) {
            continue;
        }
        NSString *imagePath = @(name);
        if ([imagePath isEqualToString:path] || [imagePath.stringByResolvingSymlinksInPath isEqualToString:resolved]) {
            const struct mach_header *header = _dyld_get_image_header(i);
            if (!header || header->magic != MH_MAGIC_64) {
                return nil;
            }
            return [[NCImage alloc] initWithHeader:(const struct mach_header_64 *)header
                                             slide:_dyld_get_image_vmaddr_slide(i)
                                              path:imagePath];
        }
    }
    return nil;
}

/// 遍历 load command
static void NCEnumerateLoadCommands(NCImage *image, void (^block)(const struct load_command *command, BOOL *stop)) {
    const struct mach_header_64 *header = image.header;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    BOOL stop = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        block(command, &stop);
        if (stop) {
            break;
        }
        cursor += command->cmdsize;
    }
}

void NCEnumerateSections(NCImage *image, void (^block)(const struct segment_command_64 *, const struct section_64 *, BOOL *)) {
    NCEnumerateLoadCommands(image, ^(const struct load_command *command, BOOL *stopCommands) {
        if (command->cmd != LC_SEGMENT_64) {
            return;
        }
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        const struct section_64 *sections = (const struct section_64 *)(segment + 1);
        for (uint32_t j = 0; j < segment->nsects; j++) {
            BOOL stop = NO;
            block(segment, &sections[j], &stop);
            if (stop) {
                *stopCommands = YES;
                return;
            }
        }
    });
}

const struct section_64 *NCSectionAtIndex(NCImage *image, uint8_t index) {
    __block const struct section_64 *result = NULL;
    __block uint8_t current = 0;
    NCEnumerateSections(image, ^(const struct segment_command_64 *segment, const struct section_64 *section, BOOL *stop) {
        current++;
        if (current == index) {
            result = section;
            *stop = YES;
        }
    });
    return result;
}

void *NCSectionData(NCImage *image, const char *segmentName, const char *sectionName, size_t *size) {
    __block void *result = NULL;
    NCEnumerateSections(image, ^(const struct segment_command_64 *segment, const struct section_64 *section, BOOL *stop) {
        if (strncmp(section->sectname, sectionName, sizeof(section->sectname)) != 0) {
            return;
        }
        if (segmentName && strncmp(section->segname, segmentName, sizeof(section->segname)) != 0) {
            return;
        }
        result = (void *)(section->addr + image.slide);
        if (size) {
            *size = (size_t)section->size;
        }
        *stop = YES;
    });
    return result;
}

void NCEnumerateSymbols(NCImage *image, NCSymbolBlock block) {
    __block const struct symtab_command *symtab = NULL;
    __block const struct segment_command_64 *linkedit = NULL;
    NCEnumerateLoadCommands(image, ^(const struct load_command *command, BOOL *stop) {
        if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkedit = segment;
            }
        }
    });
    if (!symtab || !linkedit) {
        return;
    }
    // __LINKEDIT 在内存中的基址：文件偏移需要换算成虚拟地址
    uintptr_t linkeditBase = (uintptr_t)image.slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);

    // 预先收集节表，避免每个符号都线性查找
    NSMutableArray<NSValue *> *sections = [NSMutableArray array];
    NCEnumerateSections(image, ^(const struct segment_command_64 *segment, const struct section_64 *section, BOOL *stop) {
        [sections addObject:[NSValue valueWithPointer:section]];
    });

    BOOL stop = NO;
    for (uint32_t i = 0; i < symtab->nsyms && !stop; i++) {
        const struct nlist_64 *symbol = &symbols[i];
        // 跳过调试符号（STAB）
        if (symbol->n_type & N_STAB) {
            continue;
        }
        if (symbol->n_un.n_strx == 0 || symbol->n_un.n_strx >= symtab->strsize) {
            continue;
        }
        const char *name = strings + symbol->n_un.n_strx;
        uint8_t kind = symbol->n_type & N_TYPE;
        if (kind == N_SECT) {
            const struct section_64 *section = NULL;
            if (symbol->n_sect >= 1 && symbol->n_sect <= sections.count) {
                section = (const struct section_64 *)sections[symbol->n_sect - 1].pointerValue;
            }
            block(name, (uintptr_t)(symbol->n_value + image.slide), symbol->n_type, section, &stop);
        } else if (kind == N_UNDF) {
            block(name, 0, symbol->n_type, NULL, &stop);
        }
    }
}

BOOL NCWithWritableMemory(void *address, size_t size, void (NS_NOESCAPE ^block)(void)) {
    vm_size_t pageSize = (vm_size_t)getpagesize();
    uintptr_t start = (uintptr_t)address & ~(uintptr_t)(pageSize - 1);
    uintptr_t end = ((uintptr_t)address + size + pageSize - 1) & ~(uintptr_t)(pageSize - 1);

    // 查询原保护属性，以便恢复
    vm_address_t regionAddress = (vm_address_t)start;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    vm_prot_t originalProtection = VM_PROT_READ;
    kern_return_t kr = vm_region_64(mach_task_self(), &regionAddress, &regionSize, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &infoCount, &objectName);
    if (kr == KERN_SUCCESS) {
        originalProtection = info.protection;
    }
    // 本工具只修改数据页，代码页不在此函数的处理范围内
    if (originalProtection & VM_PROT_EXECUTE) {
        return NO;
    }
    if (originalProtection & VM_PROT_WRITE) {
        block();
        return YES;
    }
    if (mprotect((void *)start, end - start, PROT_READ | PROT_WRITE) != 0) {
        return NO;
    }
    block();
    int restore = PROT_NONE;
    if (originalProtection & VM_PROT_READ) {
        restore |= PROT_READ;
    }
    mprotect((void *)start, end - start, restore);
    return YES;
}

BOOL NCImageContainsAddress(NCImage *image, const void *address) {
    __block BOOL contains = NO;
    uintptr_t target = (uintptr_t)address;
    NCEnumerateLoadCommands(image, ^(const struct load_command *command, BOOL *stop) {
        if (command->cmd != LC_SEGMENT_64) {
            return;
        }
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        if (strcmp(segment->segname, SEG_PAGEZERO) == 0) {
            return;
        }
        uintptr_t start = (uintptr_t)segment->vmaddr + (uintptr_t)image.slide;
        if (target >= start && target < start + segment->vmsize) {
            contains = YES;
            *stop = YES;
        }
    });
    return contains;
}

#endif
