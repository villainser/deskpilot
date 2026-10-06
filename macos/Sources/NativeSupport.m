// Native Space support adapted from DeskPilot and Hammerspoon PR #3889.
// See LICENSE-Hammerspoon.txt. Private APIs are probed, never assumed.
#import "NativeSupport.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
static const char *kSkyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
static const char *kAsyncSymbol = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
typedef int64_t (*PerformAsyncOperation)(void *operation);
@interface NSObject (DeskPilotBridgedOperation)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)spaceID;
@end
// The upstream operation is a local Mach-O symbol; dlsym alone cannot find it.
// Inspect only the already-loaded, system-provided SkyLight image.
static void *findLocalSymbol(const char *imagePath, const char *symbolName) {
    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, imagePath) == 0) {
            header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!header || header->magic != MH_MAGIC_64) return NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(*header);
    const uint8_t *end = cursor + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return NULL;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return NULL;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname)) == 0) linkedit = segment;
        } else if (command->cmd == LC_SYMTAB && command->cmdsize >= sizeof(struct symtab_command)) {
            symtab = (const struct symtab_command *)command;
        }
        cursor += command->cmdsize;
    }
    if (!linkedit || !symtab) return NULL;
    uint64_t symbolsEnd = (uint64_t)symtab->symoff + (uint64_t)symtab->nsyms * sizeof(struct nlist_64);
    uint64_t stringsEnd = (uint64_t)symtab->stroff + symtab->strsize;
    uint64_t linkeditEnd = linkedit->fileoff + linkedit->filesize;
    if (symtab->symoff < linkedit->fileoff || symtab->stroff < linkedit->fileoff ||
        symbolsEnd > linkeditEnd || stringsEnd > linkeditEnd) return NULL;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const char *strings = (const char *)(base + symtab->stroff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    for (uint32_t i = 0; i < symtab->nsyms; ++i) {
        uint32_t index = symbols[i].n_un.n_strx;
        if (!index || index >= symtab->strsize || (symbols[i].n_type & N_TYPE) != N_SECT) continue;
        const char *name = strings + index;
        size_t remaining = symtab->strsize - index;
        if (!memchr(name, '\0', remaining)) continue;
        if (strcmp(name, symbolName) == 0) return (void *)((uintptr_t)slide + symbols[i].n_value);
    }
    return NULL;
}


static void *library(void) { static void *handle; static dispatch_once_t once; dispatch_once(&once, ^{ handle = dlopen(kSkyLight, RTLD_LAZY | RTLD_LOCAL); }); return handle; }
static int connection(void) { int (*fn)(void) = dlsym(library(), "SLSMainConnectionID"); return fn ? fn() : 0; }
NSArray *DPSpaces(void) {
    @try {
        CFArrayRef (*fn)(int) = dlsym(library(), "SLSCopyManagedDisplaySpaces");
        if (!fn || !connection()) return nil;
        CFArrayRef value = fn(connection());
        return value ? CFBridgingRelease(value) : nil;
    } @catch (NSException *e) { return nil; }
}
NSArray *DPWindowSpaces(uint32_t window) {
    CFArrayRef (*fn)(int,int,CFArrayRef) = dlsym(library(), "SLSCopySpacesForWindows");
    if (!fn) return nil;
    CFArrayRef result = fn(connection(), 7, (__bridge CFArrayRef)@[@(window)]);
    return result ? CFBridgingRelease(result) : nil;
}
uint32_t DPWindowID(AXUIElementRef element) {
    static AXError (*fn)(AXUIElementRef, uint32_t *);
    if (!fn) fn = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    uint32_t result = 0; if (fn) fn(element, &result); return result;
}
static id retainedOperation;
BOOL DPCanMove(void) {
    library();
    Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    return findLocalSymbol(kSkyLight,kAsyncSymbol) && cls && [cls instancesRespondToSelector:@selector(initWithWindows:spaceID:)];
}
NSString *DPBeginMove(uint32_t window, uint64_t target) {
    @try {
        if (!AXIsProcessTrusted()) return @"Brak uprawnienia Dostępność.";
        if (!DPCanMove()) return @"Ta wersja macOS nie udostępnia obsługi przenoszenia.";
        int (*type)(int,uint64_t) = dlsym(library(), "SLSSpaceGetType");
        NSArray *before = DPWindowSpaces(window);
        if (!type || before.count != 1 || type(connection(),[before.firstObject unsignedLongLongValue]) != 0 || type(connection(), target) != 0)
            return @"Przenosić można zwykłe okna na zwykłych biurkach.";
        Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
        retainedOperation = [[cls alloc] initWithWindows:@[@(window)] spaceID:target];
        if (!retainedOperation) return @"Nie udało się przygotować przeniesienia.";
        PerformAsyncOperation perform = findLocalSymbol(kSkyLight,kAsyncSymbol);
        perform((__bridge void *)retainedOperation);
        return nil;
    } @catch (NSException *e) { return e.reason ?: @"Błąd macOS."; }
}
void DPEndMove(void) { retainedOperation = nil; }
