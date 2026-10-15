#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#define string_equals(a, b) (strcmp((a), (b)) == 0)
#include "macho_dlsym.h"

// Standalone feasibility probe. It operates only on its own helper windows.
typedef int (*ConnectionFn)(void);
typedef CFArrayRef (*SpacesFn)(int);
typedef CFArrayRef (*WindowSpacesFn)(int, int, CFArrayRef);
typedef int (*WindowLevelFn)(int, uint32_t, int *);
typedef int (*SetLevelFn)(int, uint32_t, int);
typedef int64_t (*MoveFn)(void *);
static void *sky;
static ConnectionFn connection;
static SpacesFn displays;
static WindowSpacesFn windowSpaces;
static WindowLevelFn getLevel;
static SetLevelFn setLevel;
static MoveFn moveOperation;

static void loadSymbols(void) {
    sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
    connection = (ConnectionFn)dlsym(sky, "SLSMainConnectionID");
    displays = (SpacesFn)dlsym(sky, "SLSCopyManagedDisplaySpaces");
    windowSpaces = (WindowSpacesFn)dlsym(sky, "SLSCopySpacesForWindows");
    getLevel = (WindowLevelFn)dlsym(sky, "SLSGetWindowLevel");
    setLevel = (SetLevelFn)dlsym(sky, "SLSSetWindowLevel");
    moveOperation = (MoveFn)dlsym(sky, "SLSPerformAsynchronousBridgedWindowManagementOperation");
    if (!moveOperation) moveOperation = (MoveFn)macho_find_symbol(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
}

static NSArray *spacesForWindow(uint32_t wid) {
    if (!windowSpaces || !connection) return @[];
    CFArrayRef result = windowSpaces(connection(), 7, (__bridge CFArrayRef)@[@(wid)]);
    return result ? CFBridgingRelease(result) : @[];
}

static BOOL isOnScreen(uint32_t wid) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *window in windows) if ([window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] == wid) return YES;
    return NO;
}

static void printJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout); fflush(stdout);
}

@interface ProbeDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property NSString *role;
@end

@implementation ProbeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 300, 620, 420)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = [self.role isEqual:@"authorize"] ? @"EdgeHider 全屏验证 · 权限准备" : [@"EdgeHider Probe " stringByAppendingString:self.role];
    self.window.delegate = self;
    self.window.releasedWhenClosed = NO;
    NSString *message = [self.role isEqual:@"host"] ? @"Fullscreen host — disposable test window"
        : [self.role isEqual:@"authorize"] ? @"请在系统设置的辅助功能列表中允许 EdgeHiderFullscreenProbe。授权后回到 Codex 告知已授权。"
        : @"Target window — type below to test real keyboard input";
    NSTextField *label = [NSTextField wrappingLabelWithString:message];
    label.frame = NSMakeRect(30, 320, 560, 50);
    [self.window.contentView addSubview:label];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 240, 520, 35)];
    input.placeholderString = @"Enter verification text here";
    if (![self.role isEqual:@"authorize"]) [self.window.contentView addSubview:input];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    NSString *path = [NSString stringWithFormat:@"/tmp/edgehider-probe-%@.json", self.role];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"pid":@(getpid()), @"window":@(self.window.windowNumber)} options:0 error:nil];
    [data writeToFile:path atomically:YES];
    if ([self.role isEqual:@"authorize"]) {
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
        NSButton *button = [NSButton buttonWithTitle:@"打开辅助功能设置" target:self action:@selector(openAccessibility:)];
        button.frame = NSMakeRect(30, 160, 220, 40);
        [self.window.contentView addSubview:button];
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            if (AXIsProcessTrusted()) label.stringValue = @"辅助功能权限已就绪。请回到 Codex 继续验证。";
        }];
    }
    if ([self.role isEqual:@"host"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self.window toggleFullScreen:nil];
        });
    }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)openAccessibility:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : [NSBundle.mainBundle.bundleIdentifier isEqual:@"com.edgehider.fullscreenprobe"] ? @"authorize" : @"inventory";
        loadSymbols();
        if ([mode isEqual:@"target"] || [mode isEqual:@"host"] || [mode isEqual:@"authorize"]) {
            NSApplication *app = [NSApplication sharedApplication];
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
            ProbeDelegate *delegate = [ProbeDelegate new];
            delegate.role = mode;
            app.delegate = delegate;
            [app run];
            return 0;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (!connection || !displays) { printJSON(@{@"error":@"Required symbols unavailable"}); return 1; }
        if ([mode isEqual:@"tagdiff"]) {
            int (*readTags)(int, uint32_t, uint64_t *, size_t) = dlsym(sky, "SLSGetWindowTags");
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,200,150)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
            [window orderFrontRegardless];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            uint32_t wid = (uint32_t)window.windowNumber;
            uint64_t before[2] = {0}, after[2] = {0};
            int a = readTags(connection(), wid, before, 64);
            window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllApplications | NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            int b = readTags(connection(), wid, after, 64);
            printJSON(@{@"before":@(before[0]), @"after":@(after[0]), @"setMask":@(after[0] & ~before[0]), @"clearMask":@(before[0] & ~after[0]), @"readBefore":@(a), @"readAfter":@(b)});
            return 0;
        }
        if ([mode isEqual:@"inventory"]) {
            CFArrayRef list = displays(connection());
            NSMutableArray *methods = [NSMutableArray new];
            for (Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation"); cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
                unsigned int count = 0;
                Method *items = class_copyMethodList(cls, &count);
                for (unsigned int i = 0; i < count; i++) [methods addObject:@{@"class":NSStringFromClass(cls), @"selector":NSStringFromSelector(method_getName(items[i])), @"type":@(method_getTypeEncoding(items[i]))}];
                free(items);
            }
            printJSON(@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,
                @"methods":methods,
                @"bridgeClass":@(NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation") != nil),
                @"bridgeFunction":@(moveOperation != NULL),
                @"levelFunction":@(setLevel != NULL),
                @"displays":list ? CFBridgingRelease(list) : @[]});
            return 0;
        }
        if (argc < 3) return 2;
        uint32_t wid = (uint32_t)strtoul(argv[2], NULL, 10);
        int level = -1;
        int readResult = getLevel ? getLevel(connection(), wid, &level) : -1;
        NSMutableDictionary *report = [@{@"window":@(wid), @"spacesBefore":spacesForWindow(wid),
            @"accessibilityTrusted":@(AXIsProcessTrusted()),
            @"levelBefore":@(level), @"levelReadResult":@(readResult)} mutableCopy];
        if ([mode isEqual:@"tags"] && argc > 4) {
            report[@"onScreenBefore"] = @(isOnScreen(wid));
            int (*writeTags)(int, uint32_t, uint64_t *, size_t) = dlsym(sky, "SLSSetWindowTags");
            int (*clearTags)(int, uint32_t, uint64_t *, size_t) = dlsym(sky, "SLSClearWindowTags");
            int (*readTags)(int, uint32_t, uint64_t *, size_t) = dlsym(sky, "SLSGetWindowTags");
            uint64_t initial[2] = {0}, after[2] = {0}, add = strtoull(argv[3], NULL, 10), remove = strtoull(argv[4], NULL, 10);
            int targetConnection = connection();
            if (argc > 5 && strcmp(argv[5], "owner") == 0) {
                int (*owner)(int, uint32_t, int *) = dlsym(sky, "SLSGetWindowOwner");
                report[@"ownerReadResult"] = @(owner(connection(), wid, &targetConnection));
            }
            report[@"requestedConnection"] = @(targetConnection);
            readTags(connection(), wid, initial, 64);
            report[@"setTagsResult"] = @(writeTags(targetConnection, wid, &add, 64));
            report[@"clearTagsResult"] = @(clearTags(targetConnection, wid, &remove, 64));
            readTags(connection(), wid, after, 64);
            report[@"tagsBefore"] = @(initial[0]); report[@"tagsAfter"] = @(after[0]);
            report[@"setLevelResult"] = @(setLevel(connection(), wid, NSScreenSaverWindowLevel));
            int levelNow = -1; getLevel(connection(), wid, &levelNow);
            report[@"levelImmediatelyAfter"] = @(levelNow);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            getLevel(connection(), wid, &levelNow); report[@"levelAfterDelay"] = @(levelNow);
            report[@"spacesAfter"] = spacesForWindow(wid);
            report[@"onScreenAfter"] = @(isOnScreen(wid));
            if (argc > 5 && strcmp(argv[5], "hold") == 0) {
                for (int i = 0; i < 100; i++) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }
        if ([mode isEqual:@"level"] && setLevel) {
            report[@"setLevelResult"] = @(setLevel(connection(), wid, NSScreenSaverWindowLevel));
            int changed = -1; getLevel(connection(), wid, &changed);
            report[@"levelAfter"] = @(changed);
            report[@"restoreLevelResult"] = @(setLevel(connection(), wid, level));
        }
        if (([mode isEqual:@"move"] || [mode isEqual:@"legacy"] || [mode isEqual:@"fallback"]) && argc > 3) {
            uint64_t sid = strtoull(argv[3], NULL, 10);
            Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
            SEL selector = NSSelectorFromString(@"initWithWindows:spaceID:");
            id obj = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([cls alloc], selector, @[@(wid)], sid);
            if ([mode isEqual:@"legacy"]) {
                void (*legacy)(int, CFArrayRef, uint64_t) = dlsym(sky, "SLSMoveWindowsToManagedSpace");
                if (legacy) legacy(connection(), (__bridge CFArrayRef)@[@(wid)], sid);
                report[@"dispatch"] = @"SLSMoveWindowsToManagedSpace";
            } else if ([mode isEqual:@"fallback"]) {
                ((void (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(@"invokeFallback"));
                report[@"dispatch"] = @"invokeFallback";
            } else if (moveOperation) {
                report[@"operationResult"] = @(moveOperation((__bridge void *)obj));
            } else {
                SEL perform = NSSelectorFromString(@"performWithWMBridgeDelegate");
                if (![obj respondsToSelector:perform]) { report[@"error"] = @"Bridge method unavailable"; printJSON(report); return 1; }
                ((void (*)(id, SEL))objc_msgSend)(obj, perform);
                report[@"dispatch"] = @"performWithWMBridgeDelegate";
            }
            for (int i = 0; i < 15; i++) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            report[@"spacesAfter"] = spacesForWindow(wid);
            report[@"targetSpace"] = @(sid);
        }
        printJSON(report);
    }
    return 0;
}
