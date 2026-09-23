// Optional DeskPilot backend for macOS Tahoe. Private API: availability is probed.
// Bridged operation and Mach-O lookup adapted from Hammerspoon PR #3889:
// https://github.com/Hammerspoon/hammerspoon/pull/3889
// Commit 8cde946e79d7a3e3d9aca366264a09a734b295bb, franzbu (2026-08-16).
// See LICENSE-Hammerspoon.txt for the upstream MIT license.
#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <errno.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <poll.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static const char *kSkyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
static const char *kAsyncSymbol = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
static BOOL framedOutput = NO;
static BOOL acknowledgedOutput = NO;
typedef int64_t (*PerformAsyncOperation)(void *operation);
typedef int (*MainConnection)(void);
typedef int (*SpaceType)(int connection, uint64_t space);
typedef CFArrayRef (*CopyWindowSpaces)(int connection, int mask, CFArrayRef windows);

@interface NSObject (DeskPilotBridgedOperation)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)spaceID;
@end

static BOOL waitForAcknowledgement(void) {
    static const char expected[] = "DESKPILOT-ACK/1\n";
    char received[sizeof(expected) - 1];
    size_t length = 0;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 4.0;
    while (length < sizeof(received)) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) return NO;
        struct pollfd input = { .fd = STDIN_FILENO, .events = POLLIN, .revents = 0 };
        int ready = poll(&input, 1, (int)(remaining * 1000 + 0.999));
        if (ready < 0) { if (errno == EINTR) continue; return NO; }
        if (ready == 0) continue;
        if (input.revents & (POLLERR | POLLNVAL)) return NO;
        ssize_t count = read(STDIN_FILENO, received + length, sizeof(received) - length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        length += (size_t)count;
        if (memcmp(received, expected, length) != 0) return NO;
    }
    return YES;
}

static int emit(int code, NSString *status, NSString *message, NSDictionary *extra) {
    NSMutableDictionary *result = [@{@"ok": code == 0 ? @YES : @NO, @"status": status, @"message": message} mutableCopy];
    if (extra) [result addEntriesFromDictionary:extra];
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    if (!json) {
        code = 5;
        json = [@"{\"ok\":false,\"status\":\"encoding_failed\",\"message\":\"Could not encode helper response.\"}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (framedOutput) {
        // ASCII avoids losing a chunk split inside UTF-8 in hs.task.
        // Length framing lets Lua wait for late reads without parsing fragments.
        NSData *payload = [json base64EncodedDataWithOptions:0];
        fprintf(stdout, "DESKPILOT-WINDOWS/1 %lu\n", (unsigned long)payload.length);
        fwrite(payload.bytes, 1, payload.length, stdout);
    } else {
        fwrite(json.bytes, 1, json.length, stdout);
    }
    fputc('\n', stdout);
    // Keep the process alive until the consumer has every stdout byte. Without
    // this handshake hs.task's termination reader races its streaming reader.
    if (acknowledgedOutput && code == 0) {
        if (fflush(stdout) != 0 || ferror(stdout) || !waitForAcknowledgement()) return 5;
    }
    return code;
}

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

static BOOL parseID(const char *text, uint64_t maximum, uint64_t *value) {
    if (!text || !*text) return NO;
    for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return NO;
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(text, &end, 10);
    if (errno == ERANGE || !end || *end || parsed == 0 || parsed > maximum) return NO;
    *value = parsed;
    return YES;
}

static NSArray *readSpaces(CopyWindowSpaces copy, int connection, NSArray *windows) {
    CFArrayRef result = copy(connection, 0x7, (__bridge CFArrayRef)windows);
    return result ? CFBridgingRelease(result) : nil;
}

static int listWindowMetadata(void) {
    CFArrayRef raw = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    if (!raw) return emit(5, @"query_failed", @"Could not enumerate WindowServer metadata.", nil);
    NSArray *descriptions = CFBridgingRelease(raw);
    NSMutableArray *windows = [NSMutableArray arrayWithCapacity:descriptions.count];
    // Bounds and on-screen state support schematic previews, including off-Space windows.
    // Explicit allow-list: window titles and image contents are never emitted.
    NSArray *keys = @[(__bridge NSString *)kCGWindowNumber, (__bridge NSString *)kCGWindowLayer,
                      (__bridge NSString *)kCGWindowOwnerPID, (__bridge NSString *)kCGWindowOwnerName,
                      (__bridge NSString *)kCGWindowBounds, (__bridge NSString *)kCGWindowIsOnscreen];
    for (NSDictionary *description in descriptions) {
        NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
        for (NSString *key in keys) if (description[key]) metadata[key] = description[key];
        if (metadata[(__bridge NSString *)kCGWindowNumber]) [windows addObject:metadata];
    }
    CGDirectDisplayID displayIDs[32];
    uint32_t count = 0;
    NSMutableArray *displays = [NSMutableArray array];
    if (CGGetActiveDisplayList(32, displayIDs, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID displayID = displayIDs[i];
            CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID);
            if (!uuid) continue;
            NSString *identifier = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid));
            CFRelease(uuid);
            if (identifier) [displays addObject:@{@"id": @(displayID), @"uuid": identifier,
                                                @"builtIn": CGDisplayIsBuiltin(displayID) ? @YES : @NO}];
        }
    }
    return emit(0, @"windows", @"Read-only window and physical display metadata; no titles/images.",
                @{@"windows": windows, @"displays": displays});
}

static int run(int argc, const char *argv[]) {
    acknowledgedOutput = argc >= 2 && strcmp(argv[1], "--windows-stream") == 0;
    framedOutput = acknowledgedOutput || (argc >= 2 && strcmp(argv[1], "--windows-framed") == 0);
    if (framedOutput && argc != 2)
        return emit(2, @"usage", @"Window metadata options do not accept additional arguments.", nil);
    if (framedOutput) return listWindowMetadata();
    if (argc == 2 && strcmp(argv[1], "--version") == 0)
        return emit(0, @"version", @"deskpilot-space-move 1.3.2", nil);
    if (argc == 2 && strcmp(argv[1], "--windows") == 0) return listWindowMetadata();
    if (argc == 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
        puts("Usage: deskpilot-space-move WINDOW_ID SPACE_ID\n"
             "       deskpilot-space-move --check | --windows | --windows-framed | --windows-stream | --version | --help\n"
             "--check only probes symbols. Moves require ordinary user Spaces.\n"
             "--windows reads metadata and bounds for all windows, including off-screen windows; no titles/images.\n"
             "--windows-framed returns the same metadata as a length-prefixed ASCII base64 frame.\n"
             "--windows-stream waits up to 4 seconds for DESKPILOT-ACK/1 plus newline on stdin after output.\n"
             "Move exit 0 means read-back confirmed the target Space; timeout is exit 6.\n"
             "No Space is created/deleted and no window is focused or resized.");
        return 0;
    }
    BOOL probe = argc == 2 && strcmp(argv[1], "--check") == 0;
    uint64_t windowID = 0, spaceID = 0;
    if (!probe && (argc != 3 || !parseID(argv[1], UINT32_MAX, &windowID) ||
                   !parseID(argv[2], UINT64_MAX, &spaceID)))
        return emit(2, @"usage", @"Expected positive WINDOW_ID SPACE_ID, or --check/--windows/--help/--version.", nil);

    void *framework = dlopen(kSkyLight, RTLD_LAZY | RTLD_LOCAL);
    if (!framework) return emit(3, @"unavailable", @"SkyLight could not be loaded.", nil);
    PerformAsyncOperation perform = (PerformAsyncOperation)findLocalSymbol(kSkyLight, kAsyncSymbol);
    MainConnection connectionFn = (MainConnection)dlsym(framework, "SLSMainConnectionID");
    SpaceType typeFn = (SpaceType)dlsym(framework, "SLSSpaceGetType");
    CopyWindowSpaces copyFn = (CopyWindowSpaces)dlsym(framework, "SLSCopySpacesForWindows");
    Class operationClass = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    BOOL initializer = operationClass && [operationClass instancesRespondToSelector:@selector(initWithWindows:spaceID:)];
    NSDictionary *features = @{@"bridgedSymbol": perform ? @YES : @NO, @"operationClass": operationClass ? @YES : @NO,
        @"initializer": @(initializer), @"querySymbols": (connectionFn && typeFn && copyFn) ? @YES : @NO,
        @"moveTested": @NO};
    if (!perform || !connectionFn || !typeFn || !copyFn || !initializer)
        return emit(3, @"unavailable", @"Required private API is unavailable; no move was attempted.", features);
    if (probe) return emit(0, @"available", @"Symbols are present. This does not verify moving windows or permissions.", features);

    int connection = connectionFn();
    if (!connection) return emit(5, @"connection_failed", @"No WindowServer connection.", nil);
    if (typeFn(connection, spaceID) != 0)
        return emit(4, @"invalid_target", @"Target must be an existing ordinary user Space.", nil);
    NSArray *windows = @[@(windowID)];
    NSArray *before = readSpaces(copyFn, connection, windows);
    if (!before) return emit(5, @"query_failed", @"Could not read the window's current Space.", nil);
    if (before.count != 1 || ![before.firstObject isKindOfClass:[NSNumber class]])
        return emit(4, @"ambiguous_window", @"Window must exist on exactly one Space; sticky windows are not moved.", nil);
    if (typeFn(connection, [before.firstObject unsignedLongLongValue]) != 0)
        return emit(4, @"invalid_source", @"Fullscreen and tiled windows are not moved.", nil);
    if ([before containsObject:@(spaceID)])
        return emit(0, @"already_on_target", @"Window is already on the requested Space.", @{@"windowID": @(windowID), @"spaceID": @(spaceID)});

    // Retain the operation until read-back completes, since submission is asynchronous.
    __attribute__((objc_precise_lifetime)) id operation = [[operationClass alloc] initWithWindows:windows spaceID:spaceID];
    if (!operation) return emit(5, @"operation_failed", @"Could not create bridged move operation.", nil);
    (void)perform((__bridge void *)operation);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 3.0;
    do {
        NSArray *after = readSpaces(copyFn, connection, windows);
        if (after.count == 1 && [after containsObject:@(spaceID)])
            return emit(0, @"moved", @"Read-back confirmed the target Space.", @{@"windowID": @(windowID), @"spaceID": @(spaceID)});
        // A CLI run loop may have no sources and return immediately; cap polling.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
        [NSThread sleepForTimeInterval:0.04];
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return emit(6, @"unconfirmed", @"Move was submitted but not confirmed within 3 seconds; do not retry blindly or delete Spaces.",
                @{@"windowID": @(windowID), @"spaceID": @(spaceID)});
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        @try { return run(argc, argv); }
        @catch (NSException *exception) {
            return emit(5, @"exception", exception.reason ?: @"Private API exception.", nil);
        }
    }
}
