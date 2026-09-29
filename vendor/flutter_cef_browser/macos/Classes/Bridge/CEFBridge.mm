//
//  CEFBridge.mm
//  flutter_cef_browser
//
//  Main CEF bridge implementation
//

#import "CEFBridge.h"
#import "../CefDragParticipantView.h"
#include "include/cef_drag_data.h"
#include "include/cef_image.h"
#include "include/cef_parser.h"
#include "include/cef_stream.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <unordered_map>

static BOOL ShouldLogFrameSync(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_FRAME_DEBUG");
        if (!value || value[0] == '\0') {
            enabled = NO;
            return;
        }
        enabled = (strcmp(value, "0") != 0);
    });
    return enabled;
}

static BOOL ShouldLogFrameSyncDetail(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_FRAME_DEBUG_DETAIL");
        if (!value || value[0] == '\0') {
            enabled = NO;
            return;
        }
        enabled = (strcmp(value, "0") != 0);
    });
    return enabled;
}

static BOOL ShouldLogLifetimeDebug(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_LIFETIME_DEBUG");
        if (!value || value[0] == '\0') {
            enabled = NO;
            return;
        }
        enabled = (strcmp(value, "0") != 0);
    });
    return enabled;
}

static BOOL ShouldLogReliabilityDebug(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_RELIABILITY_DEBUG");
        if (!value || value[0] == '\0') {
            enabled = ShouldLogLifetimeDebug();
            return;
        }
        enabled = (strcmp(value, "0") != 0);
    });
    return enabled;
}

static BOOL ShouldLogKeyDebug(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_KEY_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

static BOOL ShouldLogPopupDebug(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_POPUP_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

static BOOL ShouldLogResizeDebug(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_RESIZE_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

static BOOL ShouldLogDragDebug(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_DRAG_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

static BOOL ShouldLogFpsDebug(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_FPS_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

// Avoid tearing down and recreating Chromium's FrameSinkVideoCapturer for
// transient tab/workspace selections while still parking genuinely hidden
// browsers promptly.
static constexpr int64_t kOsrHiddenParkDebounceMs = 180;

static char16_t MacCharacterForKeyCodeOnlyEvent(int windowsKeyCode) {
    switch (windowsKeyCode) {
        case 0x08: return 0x7F;  // Backspace.
        case 0x1B: return 0x1B;  // Escape.
        case 0x21: return NSPageUpFunctionKey;
        case 0x22: return NSPageDownFunctionKey;
        case 0x23: return NSEndFunctionKey;
        case 0x24: return NSHomeFunctionKey;
        case 0x25: return NSLeftArrowFunctionKey;
        case 0x26: return NSUpArrowFunctionKey;
        case 0x27: return NSRightArrowFunctionKey;
        case 0x28: return NSDownArrowFunctionKey;
        case 0x2D: return NSInsertFunctionKey;
        case 0x2E: return NSDeleteFunctionKey;
        default:
            if (windowsKeyCode >= 0x70 && windowsKeyCode <= 0x87) {
                return NSF1FunctionKey + (windowsKeyCode - 0x70);
            }
            return 0;
    }
}

static void RunWithoutImplicitLayerActions(void (^updates)(void)) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    updates();
    [CATransaction commit];
}

static BOOL CefNativeDevToolsEnabled(void) {
    const char* value = getenv("VIBECODE_CEF_NATIVE_DEVTOOLS");
    if (!value || value[0] == '\0') {
        return NO;
    }
    return strcmp(value, "0") != 0 &&
           strcmp(value, "false") != 0 &&
           strcmp(value, "FALSE") != 0;
}

static BOOL CefProfileRepairDisabled(void) {
    const char* appValue = getenv("VIBECODE_CEF_DISABLE_PROFILE_REPAIR");
    if (appValue && appValue[0] != '\0' && strcmp(appValue, "0") != 0) {
        return YES;
    }
    const char* cefValue = getenv("CEF_DISABLE_PROFILE_REPAIR");
    return cefValue && cefValue[0] != '\0' && strcmp(cefValue, "0") != 0;
}

static NSString* CefProfileRepairTimestamp(void) {
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

static BOOL FilePrefixContainsData(NSString* path, NSData* needle, NSUInteger maxBytes) {
    if (path.length == 0 || needle.length == 0) return NO;
    NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return NO;
    NSData* data = nil;
    @try {
        data = [handle readDataOfLength:maxBytes];
    } @catch (__unused NSException* exception) {
        data = nil;
    }
    @try {
        [handle closeFile];
    } @catch (__unused NSException* exception) {
    }
    if (data.length < needle.length) return NO;
    NSRange range = [data rangeOfData:needle
                              options:0
                                range:NSMakeRange(0, data.length)];
    return range.location != NSNotFound;
}

static BOOL DirectoryContainsData(NSString* directoryPath,
                                  NSData* needle,
                                  NSUInteger maxFiles,
                                  NSUInteger maxBytesPerFile) {
    if (directoryPath.length == 0 || needle.length == 0) return NO;
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSArray<NSString*>* entries = [fileManager contentsOfDirectoryAtPath:directoryPath error:nil];
    NSUInteger scannedFiles = 0;
    for (NSString* entry in entries) {
        if (scannedFiles >= maxFiles) break;
        NSString* path = [directoryPath stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) {
            continue;
        }
        scannedFiles += 1;
        if (FilePrefixContainsData(path, needle, maxBytesPerFile)) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSString*, id>* RepairCrashProneCefProfileData(NSString* cachePath,
                                                                    NSString* rootCachePath) {
    if (CefProfileRepairDisabled()) {
        return @{@"didRepair": @NO, @"reason": @"disabled"};
    }
    if (cachePath.length == 0) {
        return @{@"didRepair": @NO, @"reason": @"cache_path_empty"};
    }
    NSString* repairRootPath = rootCachePath.length > 0 ? rootCachePath : cachePath;
    if (repairRootPath.length == 0) {
        return @{@"didRepair": @NO, @"reason": @"root_cache_path_empty"};
    }

    NSMutableArray<NSString*>* candidatePaths = [NSMutableArray array];
    void (^addCandidate)(NSString*) = ^(NSString* basePath) {
        if (basePath.length == 0) {
            return;
        }
        NSString* candidate = [[basePath stringByAppendingPathComponent:@"Sync Data"]
            stringByAppendingPathComponent:@"LevelDB"];
        if (![candidatePaths containsObject:candidate]) {
            [candidatePaths addObject:candidate];
        }
    };
    addCandidate(cachePath);
    addCandidate([repairRootPath stringByAppendingPathComponent:@"default"]);

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSData* webAppMetadataNeedle =
        [@"web_apps-dt-DATABASE_METADATA" dataUsingEncoding:NSUTF8StringEncoding];
    const NSUInteger maxScannedFiles = 24;
    const NSUInteger maxScannedBytesPerFile = 1024 * 1024;
    NSMutableArray<NSString*>* matchingPaths = [NSMutableArray array];
    BOOL foundExistingSyncLevelDb = NO;
    for (NSString* syncLevelDbPath in candidatePaths) {
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:syncLevelDbPath isDirectory:&isDirectory] ||
            !isDirectory) {
            continue;
        }
        foundExistingSyncLevelDb = YES;
        if (DirectoryContainsData(syncLevelDbPath,
                                  webAppMetadataNeedle,
                                  maxScannedFiles,
                                  maxScannedBytesPerFile)) {
            [matchingPaths addObject:syncLevelDbPath];
        }
    }
    if (!foundExistingSyncLevelDb) {
        return @{@"didRepair": @NO, @"reason": @"sync_leveldb_missing", @"candidatePaths": candidatePaths};
    }
    if (matchingPaths.count == 0) {
        return @{@"didRepair": @NO, @"reason": @"no_web_app_metadata"};
    }

    NSString* quarantineRoot = [[[repairRootPath
        stringByAppendingPathComponent:@"_vibecode_profile_quarantine"]
        stringByAppendingPathComponent:@"native_repair_v1"]
        stringByAppendingPathComponent:CefProfileRepairTimestamp()];
    NSError* error = nil;
    if (![fileManager createDirectoryAtPath:quarantineRoot
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error]) {
        return @{
            @"didRepair": @NO,
            @"reason": @"quarantine_create_failed",
            @"error": error.localizedDescription ?: @"unknown",
        };
    }

    NSMutableArray<NSString*>* movedPaths = [NSMutableArray array];
    for (NSUInteger index = 0; index < matchingPaths.count; index++) {
        NSString* syncLevelDbPath = matchingPaths[index];
        NSString* movedName = index == 0
            ? @"Sync Data LevelDB"
            : [NSString stringWithFormat:@"Sync Data LevelDB %lu", (unsigned long)(index + 1)];
        NSString* movedPath = [quarantineRoot stringByAppendingPathComponent:movedName];
        error = nil;
        if (![fileManager moveItemAtPath:syncLevelDbPath toPath:movedPath error:&error]) {
            return @{
                @"didRepair": @NO,
                @"reason": @"move_failed",
                @"error": error.localizedDescription ?: @"unknown",
                @"source": syncLevelDbPath,
                @"target": movedPath,
                @"movedPaths": movedPaths,
            };
        }
        [movedPaths addObject:movedPath];
    }

    NSDictionary<NSString*, id>* metadata = @{
        @"repairVersion": @1,
        @"reason": @"web_app_database_migration_crash_risk",
        @"sourcePaths": matchingPaths,
        @"movedPaths": movedPaths,
        @"candidatePaths": candidatePaths,
        @"cachePath": cachePath,
        @"rootCachePath": repairRootPath,
        @"createdAt": CefProfileRepairTimestamp(),
    };
    NSData* metadataData = [NSJSONSerialization dataWithJSONObject:metadata
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:nil];
    if (metadataData) {
        [metadataData writeToFile:[quarantineRoot stringByAppendingPathComponent:@"repair.json"]
                       atomically:YES];
        [metadataData writeToFile:[repairRootPath stringByAppendingPathComponent:@".vibecode_cef_profile_repair_v1"]
                       atomically:YES];
    }

    return @{
        @"didRepair": @YES,
        @"reason": @"web_app_metadata_quarantined",
        @"quarantinePath": quarantineRoot,
        @"movedPaths": movedPaths,
    };
}

// Resizable divider view for DevTools
@interface ResizableDivider : NSView
@property (nonatomic, weak) NSView* leftView;   // Browser view
@property (nonatomic, weak) NSView* rightView;  // DevTools view
@property (nonatomic, assign) BOOL isVertical;  // YES for left/right split, NO for top/bottom
@property (nonatomic, assign) CGFloat minSize;
@end

@implementation ResizableDivider {
    NSPoint _lastMouseLocation;
    BOOL _isDragging;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    if (self = [super initWithFrame:frameRect]) {
        _minSize = 200;
        _isDragging = NO;
        self.wantsLayer = YES;
        // More visible color - dark gray with slight transparency
        self.layer.backgroundColor = [[NSColor colorWithWhite:0.3 alpha:0.8] CGColor];
    }
    return self;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    NSCursor* cursor = self.isVertical ? [NSCursor resizeLeftRightCursor] : [NSCursor resizeUpDownCursor];
    [self addCursorRect:self.bounds cursor:cursor];
}

- (void)mouseDown:(NSEvent *)event {
    _isDragging = YES;
    _lastMouseLocation = [self.superview convertPoint:event.locationInWindow fromView:nil];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_isDragging || !self.leftView || !self.rightView) return;

    NSPoint currentLocation = [self.superview convertPoint:event.locationInWindow fromView:nil];
    CGFloat delta = self.isVertical ?
        (currentLocation.x - _lastMouseLocation.x) :
        (currentLocation.y - _lastMouseLocation.y);

    NSRect leftFrame = self.leftView.frame;
    NSRect rightFrame = self.rightView.frame;
    NSRect dividerFrame = self.frame;

    if (self.isVertical) {
        // Horizontal resize (left/right split)
        CGFloat newLeftWidth = leftFrame.size.width + delta;
        CGFloat newRightWidth = rightFrame.size.width - delta;

        // Enforce minimum sizes
        if (newLeftWidth < self.minSize || newRightWidth < self.minSize) return;

        leftFrame.size.width = newLeftWidth;
        rightFrame.size.width = newRightWidth;
        rightFrame.origin.x = leftFrame.origin.x + leftFrame.size.width + dividerFrame.size.width;
        dividerFrame.origin.x = leftFrame.origin.x + leftFrame.size.width;
    } else {
        // Vertical resize (top/bottom split)
        CGFloat newTopHeight = leftFrame.size.height + delta;
        CGFloat newBottomHeight = rightFrame.size.height - delta;

        if (newTopHeight < self.minSize || newBottomHeight < self.minSize) return;

        leftFrame.size.height = newTopHeight;
        rightFrame.size.height = newBottomHeight;
        rightFrame.origin.y = leftFrame.origin.y + leftFrame.size.height + dividerFrame.size.height;
        dividerFrame.origin.y = leftFrame.origin.y + leftFrame.size.height;
    }

    self.leftView.frame = leftFrame;
    self.rightView.frame = rightFrame;
    self.frame = dividerFrame;

    _lastMouseLocation = currentLocation;
}

- (void)mouseUp:(NSEvent *)event {
    _isDragging = NO;
    // CEF will be notified via WasResized() when setViewFrame is called
}

@end

// Helper to check if CEF was already initialized by custom main.mm
// Uses dlsym for runtime lookup to avoid link-time dependency
static BOOL wasCEFInitializedByMain(void) {
    // Look for the global symbol in the running process
    BOOL* flagPtr = (BOOL*)dlsym(RTLD_DEFAULT, "g_cefInitializedByMain");
    NSLog(@"CEFBridge: dlsym lookup for g_cefInitializedByMain: %p", (void*)flagPtr);
    if (flagPtr != nullptr) {
        NSLog(@"CEFBridge: g_cefInitializedByMain value: %d", *flagPtr);
        return *flagPtr;
    }
    NSLog(@"CEFBridge: g_cefInitializedByMain symbol NOT FOUND");
    return NO;
}

// Best-effort helper to check if CEF context initialization already happened in main.mm.
// If the symbol is not present we assume "ready" because we won't receive OnContextInitialized.
static BOOL wasCEFContextInitializedByMain(void) {
    BOOL* flagPtr = (BOOL*)dlsym(RTLD_DEFAULT, "g_cefContextInitializedByMain");
    if (flagPtr != nullptr) {
        return *flagPtr;
    }
    return YES;
}

#import "CEFClientImpl.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_frame.h"
#include "include/cef_registration.h"
#include "include/cef_task.h"
#include "include/cef_values.h"
#include "include/internal/cef_time.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include <map>
#include <deque>
#include <vector>
#include <unordered_set>
#include <cstring>

typedef void (^ResponseBodyCompletion)(NSString* _Nullable body, BOOL base64Encoded);
typedef void (^CookieListCompletion)(NSArray<NSDictionary*>* cookies);
typedef void (^JavaScriptEvaluationCompletion)(NSString* _Nullable result, NSError* _Nullable error);
typedef void (^TextInputCompletion)(NSError* _Nullable error);
typedef void (^ScreenshotCompletion)(NSString* _Nullable data, NSError* _Nullable error);

static NSString* const kCefIssueSeverityWarning = @"warning";
static NSString* const kCefIssueSeverityFailure = @"failure";

static NSDictionary<NSString*, id>* CefPreflightIssue(NSString* code,
                                                      NSString* severity,
                                                      NSString* message,
                                                      NSDictionary<NSString*, id>* details) {
    NSMutableDictionary<NSString*, id>* issue = [@{
        @"code": code ?: @"unknown_issue",
        @"severity": severity ?: kCefIssueSeverityWarning,
        @"message": message ?: @"Unknown CEF issue",
    } mutableCopy];
    if (details.count > 0) {
        issue[@"details"] = details;
    }
    return [issue copy];
}

static NSString* StringValueOrNil(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) {
        NSString* stringValue = [(NSString*)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return stringValue.length > 0 ? stringValue : nil;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString* stringValue = [[value stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return stringValue.length > 0 ? stringValue : nil;
    }
    return nil;
}

static NSInteger IntegerValueOrDefault(id value, NSInteger fallback) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber*)value integerValue];
    }
    NSString* stringValue = StringValueOrNil(value);
    if (!stringValue) return fallback;
    return [stringValue integerValue];
}

static BOOL BoolValueOrDefault(id value, BOOL fallback) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber*)value boolValue];
    }
    NSString* stringValue = [StringValueOrNil(value) lowercaseString];
    if (!stringValue) return fallback;
    if ([stringValue isEqualToString:@"1"] ||
        [stringValue isEqualToString:@"true"] ||
        [stringValue isEqualToString:@"yes"]) {
        return YES;
    }
    if ([stringValue isEqualToString:@"0"] ||
        [stringValue isEqualToString:@"false"] ||
        [stringValue isEqualToString:@"no"]) {
        return NO;
    }
    return fallback;
}

static NSString* NormalizeRenderBackendName(NSString* rawBackend) {
    NSString* backend = StringValueOrNil(rawBackend) ?: @"nativeView";
    if ([backend isEqualToString:@"osrTexture"] ||
        [backend isEqualToString:@"acceleratedOsrTexture"]) {
        return backend;
    }
    return @"nativeView";
}

static CGFloat DeviceScaleFactorForView(NSView* view) {
    NSScreen* screen = view.window.screen ?: NSScreen.mainScreen;
    const CGFloat scale = screen ? screen.backingScaleFactor : 1.0;
    return MAX(1.0, scale);
}

static CGFloat EffectiveDeviceScaleFactor(CGFloat requestedScale, NSView* fallbackView) {
    if (requestedScale > 0.0 && isfinite(requestedScale)) {
        return MAX(1.0, requestedScale);
    }
    return DeviceScaleFactorForView(fallbackView);
}

static int MacKeyCodeToWindowsKeyCode(NSInteger keyCode) {
    switch (keyCode) {
        case 0: return 0x41;
        case 11: return 0x42;
        case 8: return 0x43;
        case 2: return 0x44;
        case 14: return 0x45;
        case 3: return 0x46;
        case 5: return 0x47;
        case 4: return 0x48;
        case 34: return 0x49;
        case 38: return 0x4A;
        case 40: return 0x4B;
        case 37: return 0x4C;
        case 46: return 0x4D;
        case 45: return 0x4E;
        case 31: return 0x4F;
        case 35: return 0x50;
        case 12: return 0x51;
        case 15: return 0x52;
        case 1: return 0x53;
        case 17: return 0x54;
        case 32: return 0x55;
        case 9: return 0x56;
        case 13: return 0x57;
        case 7: return 0x58;
        case 16: return 0x59;
        case 6: return 0x5A;
        case 29: return 0x30;
        case 18: return 0x31;
        case 19: return 0x32;
        case 20: return 0x33;
        case 21: return 0x34;
        case 23: return 0x35;
        case 22: return 0x36;
        case 26: return 0x37;
        case 28: return 0x38;
        case 25: return 0x39;
        case 122: return 0x70;
        case 120: return 0x71;
        case 99: return 0x72;
        case 118: return 0x73;
        case 96: return 0x74;
        case 97: return 0x75;
        case 98: return 0x76;
        case 100: return 0x77;
        case 101: return 0x78;
        case 109: return 0x79;
        case 103: return 0x7A;
        case 111: return 0x7B;
        case 123: return 0x25;
        case 124: return 0x27;
        case 125: return 0x28;
        case 126: return 0x26;
        case 116: return 0x21;
        case 121: return 0x22;
        case 115: return 0x24;
        case 119: return 0x23;
        case 117: return 0x2E;
        case 51: return 0x08;
        case 36: return 0x0D;
        case 48: return 0x09;
        case 53: return 0x1B;
        case 49: return 0x20;
        case 56:
        case 60:
            return 0x10;
        case 59:
        case 62:
            return 0x11;
        case 58:
        case 61:
            return 0x12;
        case 55: return 0x5B;
        case 54: return 0x5C;
        case 27: return 0xBD;
        case 24: return 0xBB;
        case 33: return 0xDB;
        case 30: return 0xDD;
        case 41: return 0xBA;
        case 39: return 0xDE;
        case 43: return 0xBC;
        case 47: return 0xBE;
        case 44: return 0xBF;
        case 42: return 0xDC;
        case 50: return 0xC0;
        case 82: return 0x60;
        case 83: return 0x61;
        case 84: return 0x62;
        case 85: return 0x63;
        case 86: return 0x64;
        case 87: return 0x65;
        case 88: return 0x66;
        case 89: return 0x67;
        case 91: return 0x68;
        case 92: return 0x69;
        case 65: return 0x6E;
        case 67: return 0x6A;
        case 69: return 0x6B;
        case 75: return 0x6F;
        case 78: return 0x6D;
        case 76: return 0x0D;
        case 81: return 0xBB;
        case 71: return 0x0C;
        default: return 0;
    }
}

static CefBrowserHost::MouseButtonType CefMouseButtonTypeFromString(NSString* button) {
    if ([button isEqualToString:@"right"]) {
        return MBT_RIGHT;
    }
    if ([button isEqualToString:@"middle"]) {
        return MBT_MIDDLE;
    }
    return MBT_LEFT;
}

static cef_key_event_type_t CefKeyEventTypeFromString(NSString* type) {
    if ([type isEqualToString:@"keyUp"]) {
        return KEYEVENT_KEYUP;
    }
    if ([type isEqualToString:@"char"]) {
        return KEYEVENT_CHAR;
    }
    if ([type isEqualToString:@"keyDown"]) {
        return KEYEVENT_KEYDOWN;
    }
    return KEYEVENT_RAWKEYDOWN;
}

static NSButton* ManagedPopupToolbarButton(NSString* systemSymbolName,
                                           NSString* fallbackTitle,
                                           NSString* tooltip,
                                           id target,
                                           SEL action) {
    NSButton* button = [NSButton buttonWithTitle:fallbackTitle ?: @""
                                          target:target
                                          action:action];
    if (@available(macOS 11.0, *)) {
        NSImage* image = [NSImage imageWithSystemSymbolName:systemSymbolName
                                   accessibilityDescription:tooltip];
        if (image) {
            button.image = image;
            button.title = @"";
            button.imagePosition = NSImageOnly;
        }
    }
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.toolTip = tooltip;
    button.translatesAutoresizingMaskIntoConstraints = YES;
    return button;
}

static NSTextField* ManagedPopupLabel(NSString* text, NSFont* font) {
    NSTextField* label = [NSTextField labelWithString:text ?: @""];
    label.font = font;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 1;
    label.translatesAutoresizingMaskIntoConstraints = YES;
    return label;
}

static NSRect ManagedPopupFrameForRequest(NSRect proposedFrame,
                                          NSDictionary* details,
                                          NSWindow* sourceWindow) {
    NSScreen* screen = sourceWindow.screen ?: NSScreen.mainScreen;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(80, 80, 960, 720);
    NSDictionary* popupFeatures = [details[@"popupFeatures"] isKindOfClass:[NSDictionary class]]
        ? (NSDictionary*)details[@"popupFeatures"]
        : @{};
    const BOOL xSet = BoolValueOrDefault(popupFeatures[@"xSet"], NO);
    const BOOL ySet = BoolValueOrDefault(popupFeatures[@"ySet"], NO);
    const BOOL hasExplicitOrigin = xSet || ySet;
    const CGFloat horizontalMargin = 48;
    const CGFloat verticalMargin = 64;
    const CGFloat width = MIN(MAX(proposedFrame.size.width, 360),
                              MAX(360, visibleFrame.size.width - horizontalMargin));
    const CGFloat height = MIN(MAX(proposedFrame.size.height, 320),
                               MAX(320, visibleFrame.size.height - verticalMargin));
    CGFloat x = proposedFrame.origin.x;
    CGFloat y = proposedFrame.origin.y;
    if (!hasExplicitOrigin) {
        if (sourceWindow) {
            NSRect sourceFrame = sourceWindow.frame;
            x = NSMidX(sourceFrame) - width / 2.0 + 36;
            y = NSMidY(sourceFrame) - height / 2.0 - 36;
        } else {
            x = NSMidX(visibleFrame) - width / 2.0;
            y = NSMidY(visibleFrame) - height / 2.0;
        }
    }
    x = MIN(MAX(x, NSMinX(visibleFrame) + 16), NSMaxX(visibleFrame) - width - 16);
    y = MIN(MAX(y, NSMinY(visibleFrame) + 16), NSMaxY(visibleFrame) - height - 16);
    return NSMakeRect(x, y, width, height);
}

static NSArray<NSString*>* StringArrayOrEmpty(id value) {
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (id item in (NSArray*)value) {
        NSString* stringValue = StringValueOrNil(item);
        if (stringValue.length > 0) {
            [out addObject:stringValue];
        }
    }
    return [out copy];
}

static NSError* CefJavaScriptError(NSString* flutterCode,
                                   NSString* message,
                                   NSDictionary<NSString*, id>* details) {
    NSMutableDictionary<NSString*, id>* userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"JavaScript operation failed";
    if (flutterCode.length > 0) {
        userInfo[@"flutterCode"] = flutterCode;
    }
    if (details.count > 0) {
        userInfo[@"details"] = details;
    }
    return [NSError errorWithDomain:@"CEFBridge.JavaScript"
                               code:1
                           userInfo:userInfo];
}

static NSString* NSStringFromCefString(const CefString& value) {
    const std::string utf8 = value.ToString();
    return [NSString stringWithUTF8String:utf8.c_str()] ?: @"";
}

static NSString* DevToolsRequestKey(int cefBrowserId, int messageId) {
    return [NSString stringWithFormat:@"%d:%d", cefBrowserId, messageId];
}

static double SecondsFromCefBaseTime(cef_basetime_t value) {
    cef_time_t exploded = {};
    if (!cef_time_from_basetime(value, &exploded)) return 0;
    double seconds = 0;
    if (!cef_time_to_doublet(&exploded, &seconds)) return 0;
    return seconds;
}

static NSDictionary* ParseDevToolsJsonDict(const void* bytes, size_t size) {
    if (!bytes || size == 0) return @{};
    NSData* data = [NSData dataWithBytes:bytes length:size];
    if (!data || data.length == 0) return @{};

    NSError* error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![parsed isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    return (NSDictionary*)parsed;
}

static void EnsureBrowserViewAttachedToContainer(NSView* browserView,
                                                 NSView* containerView,
                                                 int browserId,
                                                 NSString* context) {
    if (!browserView || !containerView) return;
    if (browserView == containerView) return;
    if (browserView.superview == containerView) return;

    if (ShouldLogFrameSync() || ShouldLogFrameSyncDetail()) {
        NSLog(@"CEFBridge: reparent browser NSView (context=%@) browserId=%d browserView=%@ oldSuperview=%@ newSuperview=%@",
              context ?: @"(unknown)",
              browserId,
              browserView,
              browserView.superview,
              containerView);
    }

    [browserView removeFromSuperviewWithoutNeedingDisplay];
    [containerView addSubview:browserView];
}

static NSView* RetainedBrowserSubviewForContainer(NSView* containerView) {
    if (!containerView) return nil;
    for (NSView* subview in containerView.subviews) {
        if (subview) return subview;
    }
    return nil;
}

static BOOL ResponderBelongsToBrowser(NSResponder* responder,
                                      NSView* browserView,
                                      NSView* containerView) {
    if (!responder) return NO;
    if (responder == browserView || responder == containerView) return YES;
    if (![responder isKindOfClass:[NSView class]]) return NO;
    NSView* responderView = (NSView*)responder;
    if (browserView && [responderView isDescendantOf:browserView]) return YES;
    if (containerView && [responderView isDescendantOf:containerView]) return YES;
    return NO;
}

static void AttemptBrowserFirstResponder(NSWindow* window,
                                         NSView* browserView,
                                         NSView* containerView) {
    if (!window) return;
    if (NSApp && !NSApp.isActive) return;
    if (!window.isKeyWindow && !window.isMainWindow) return;

    if (browserView && browserView.window == window) {
        if ([browserView acceptsFirstResponder]) {
            [window makeFirstResponder:browserView];
            if (window.firstResponder == browserView) {
                return;
            }
        }
    }

    if (containerView && containerView.window == window && [containerView acceptsFirstResponder]) {
        [window makeFirstResponder:containerView];
        if (window.firstResponder == containerView) {
            return;
        }
    }

    // Retry after the current runloop and once more shortly after. Embedded
    // NSViews created asynchronously by CEF can miss the first responder claim
    // on the initial attempt.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (browserView && browserView.window == window && [browserView acceptsFirstResponder]) {
            [window makeFirstResponder:browserView];
        } else if (containerView && containerView.window == window && [containerView acceptsFirstResponder]) {
            [window makeFirstResponder:containerView];
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (browserView && browserView.window == window && [browserView acceptsFirstResponder]) {
            [window makeFirstResponder:browserView];
        } else if (containerView && containerView.window == window && [containerView acceptsFirstResponder]) {
            [window makeFirstResponder:containerView];
        }
    });
}

static NSString* NormalizeSwitchName(NSString* rawName) {
    if (!rawName || ![rawName isKindOfClass:[NSString class]]) return nil;
    NSString* trimmed = [rawName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    while ([trimmed hasPrefix:@"-"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    return trimmed.length > 0 ? trimmed : nil;
}

static NSDictionary<NSString*, id>* SanitizeSwitchMap(NSDictionary* rawSwitches) {
    if (!rawSwitches || ![rawSwitches isKindOfClass:[NSDictionary class]]) return @{};

    NSMutableDictionary<NSString*, id>* out = [NSMutableDictionary dictionary];
    [rawSwitches enumerateKeysAndObjectsUsingBlock:^(id rawKey, id rawValue, __unused BOOL* stop) {
        if (![rawKey isKindOfClass:[NSString class]]) return;
        NSString* key = NormalizeSwitchName((NSString*)rawKey);
        if (!key) return;

        if (!rawValue || rawValue == [NSNull null]) {
            out[key] = [NSNull null];
            return;
        }
        if ([rawValue isKindOfClass:[NSString class]]) {
            out[key] = rawValue;
            return;
        }
        if ([rawValue isKindOfClass:[NSNumber class]]) {
            out[key] = [(NSNumber*)rawValue stringValue];
            return;
        }
        out[key] = [rawValue description] ?: @"";
    }];
    return [out copy];
}

static NSSet<NSString*>* SanitizeSwitchSet(NSArray* rawSwitches) {
    if (!rawSwitches || ![rawSwitches isKindOfClass:[NSArray class]]) return [NSSet set];

    NSMutableSet<NSString*>* out = [NSMutableSet set];
    for (id raw in rawSwitches) {
        if (![raw isKindOfClass:[NSString class]]) continue;
        NSString* key = NormalizeSwitchName((NSString*)raw);
        if (key.length > 0) {
            [out addObject:key];
        }
    }
    return [out copy];
}

static NSDictionary<NSString*, id>* BuiltInProfileSwitches(NSString* profileName) {
    NSString* profile = [[profileName ?: @"prod-safe" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (profile.length == 0) profile = @"prod-safe";

    if ([profile isEqualToString:@"dev"]) {
        return @{
            @"enable-logging": [NSNull null],
            @"log-severity": @"info",
            @"v": @"1",
        };
    }
    if ([profile isEqualToString:@"ci"]) {
        return @{
            @"disable-gpu": [NSNull null],
            @"disable-gpu-compositing": [NSNull null],
            @"mute-audio": [NSNull null],
            @"no-first-run": [NSNull null],
            @"disable-background-networking": [NSNull null],
        };
    }
    if ([profile isEqualToString:@"perf"]) {
        return @{
            @"process-per-site": [NSNull null],
            @"disable-renderer-backgrounding": [NSNull null],
            @"disable-backgrounding-occluded-windows": [NSNull null],
            @"disable-background-timer-throttling": [NSNull null],
        };
    }
    if ([profile isEqualToString:@"custom"]) {
        return @{};
    }

    // prod-safe default.
    return @{};
}

typedef NS_ENUM(NSInteger, CEFMessagePumpMode) {
    CEFMessagePumpModeSimple = 0,
    CEFMessagePumpModeSampleCompatible = 1,
};

static CEFMessagePumpMode ParseMessagePumpMode(NSString* rawMode) {
    NSString* mode = [[rawMode ?: @"cef_sample_compatible" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([mode isEqualToString:@"simple"]) {
        return CEFMessagePumpModeSimple;
    }
    return CEFMessagePumpModeSampleCompatible;
}

static NSString* MessagePumpModeName(CEFMessagePumpMode mode) {
    return mode == CEFMessagePumpModeSimple ? @"simple" : @"cef_sample_compatible";
}

static BOOL EnsureCefLibraryLoadedForBridge(void) {
    static BOOL s_loaded = NO;
    if (s_loaded) return YES;

    NSString* frameworksPath = [[NSBundle mainBundle] privateFrameworksPath];
    NSString* cefFrameworkPath = [frameworksPath stringByAppendingPathComponent:
        @"Chromium Embedded Framework.framework/Chromium Embedded Framework"];

    NSLog(@"CEFBridge: Ensuring CEF library loaded from: %@", cefFrameworkPath);
    if (!cef_load_library([cefFrameworkPath UTF8String])) {
        NSLog(@"CEFBridge: Failed to load CEF library in bridge");
        return NO;
    }

    s_loaded = YES;
    return YES;
}

static NSString* CurrentISO8601Timestamp(void) {
    static NSISO8601DateFormatter* formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [formatter stringFromDate:[NSDate date]];
}

static NSString* StandardizedPathOrEmpty(NSString* path) {
    if (!path || path.length == 0) return @"";
    return [[path stringByExpandingTildeInPath] stringByStandardizingPath];
}

static BOOL PathEqualsOrWithinRoot(NSString* rootPath, NSString* candidatePath) {
    NSString* root = StandardizedPathOrEmpty(rootPath);
    NSString* candidate = StandardizedPathOrEmpty(candidatePath);
    if (root.length == 0 || candidate.length == 0) return NO;
    if ([root isEqualToString:candidate]) return YES;
    NSString* rootWithSlash = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
    return [candidate hasPrefix:rootWithSlash];
}

static NSString* NearestExistingAncestorPath(NSString* path) {
    NSString* current = StandardizedPathOrEmpty(path);
    if (current.length == 0) return @"";

    NSFileManager* fileManager = [NSFileManager defaultManager];
    while (current.length > 1 && ![fileManager fileExistsAtPath:current]) {
        NSString* parent = [current stringByDeletingLastPathComponent];
        if (parent.length == 0 || [parent isEqualToString:current]) {
            break;
        }
        current = parent;
    }
    return current;
}

static NSString* CefFrameworksPath(void) {
    return [[NSBundle mainBundle] privateFrameworksPath] ?: @"";
}

static NSString* CefFrameworkBundlePath(void) {
    NSString* frameworksPath = CefFrameworksPath();
    if (frameworksPath.length == 0) return @"";
    return [frameworksPath stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
}

static NSString* CefFrameworkBinaryPath(void) {
    NSString* frameworkBundlePath = CefFrameworkBundlePath();
    if (frameworkBundlePath.length == 0) return @"";
    return [frameworkBundlePath stringByAppendingPathComponent:@"Chromium Embedded Framework"];
}

static NSString* CefFrameworkResourcesPath(void) {
    NSString* frameworkBundlePath = CefFrameworkBundlePath();
    if (frameworkBundlePath.length == 0) return @"";
    return [frameworkBundlePath stringByAppendingPathComponent:@"Resources"];
}

static NSDictionary<NSString*, id>* ResolveHelperMetadata(void) {
    NSString* frameworksPath = CefFrameworksPath();
    NSString* bundleName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    NSString* executableName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"];
    NSArray<NSString*>* helperBaseNames = @[
        @"webview_cef Helper",
        @"flutter_cef_browser Helper",
        executableName.length > 0 ? [NSString stringWithFormat:@"%@ Helper", executableName] : @"",
        bundleName.length > 0 ? [NSString stringWithFormat:@"%@ Helper", bundleName] : @"",
    ];

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* resolvedHelperPath = nil;
    NSString* resolvedHelperBaseName = nil;
    for (NSString* helperBaseName in helperBaseNames) {
        if (helperBaseName.length == 0) continue;
        NSString* candidate = [frameworksPath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.app/Contents/MacOS/%@", helperBaseName, helperBaseName]];
        if ([fileManager fileExistsAtPath:candidate]) {
            resolvedHelperPath = candidate;
            resolvedHelperBaseName = helperBaseName;
            break;
        }
    }

    NSMutableArray<NSString*>* missingHelperVariants = [NSMutableArray array];
    if (resolvedHelperBaseName.length > 0) {
        NSArray<NSString*>* variantSuffixes = @[@"", @" (GPU)", @" (Renderer)", @" (Plugin)"];
        for (NSString* suffix in variantSuffixes) {
            NSString* variantBase = [NSString stringWithFormat:@"%@%@", resolvedHelperBaseName, suffix];
            NSString* variantPath = [frameworksPath stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@.app/Contents/MacOS/%@", variantBase, variantBase]];
            if (![fileManager fileExistsAtPath:variantPath]) {
                [missingHelperVariants addObject:variantPath];
            }
        }
    }

    return @{
        @"frameworksPath": frameworksPath ?: @"",
        @"helperPath": resolvedHelperPath ?: @"",
        @"helperBaseName": resolvedHelperBaseName ?: @"",
        @"helperCandidateBaseNames": helperBaseNames,
        @"missingHelperVariants": [missingHelperVariants copy],
    };
}

// macOS CefAppProtocol injection (Flutter owns NSApplication, so we swizzle).
static BOOL g_cefHandlingSendEvent = NO;
static IMP g_originalSendEvent = NULL;
// Flutter receives the real AppKit mouse sequence, then forwards pointer
// movement back over a method channel. By the time CEF calls StartDragging,
// NSApp.currentEvent is no longer the initiating mouse-down. Retain that exact
// event while the button is held; AppKit's modern drag API requires it.
static NSEvent* g_cefLastLeftMouseDownEvent = nil;

static BOOL EventMayUpdateOsrCursor(NSEventType type) {
    switch (type) {
        case NSEventTypeMouseMoved:
        case NSEventTypeMouseEntered:
        case NSEventTypeMouseExited:
        case NSEventTypeLeftMouseDown:
        case NSEventTypeLeftMouseUp:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDown:
        case NSEventTypeRightMouseUp:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDown:
        case NSEventTypeOtherMouseUp:
        case NSEventTypeOtherMouseDragged:
        case NSEventTypeScrollWheel:
            return YES;
        default:
            return NO;
    }
}

static void SwizzledSendEvent(id self, SEL _cmd, NSEvent* event) {
    const BOOL wasHandling = g_cefHandlingSendEvent;
    g_cefHandlingSendEvent = YES;

    if (event.type == NSEventTypeLeftMouseDown) {
        g_cefLastLeftMouseDownEvent = event;
    } else if (event.type == NSEventTypeLeftMouseUp) {
        g_cefLastLeftMouseDownEvent = nil;
    }

    // OSR is displayed by Flutter but has no hit-testable AppKit view. Capture
    // scrolls before Flutter coarsens the trackpad stream, route every precise
    // and momentum tick to CEF, and skip Flutter to avoid double scrolling.
    CEFBridge* bridge = [CEFBridge sharedInstance];
    const BOOL handledNativeOsrScroll =
        event.type == NSEventTypeScrollWheel &&
        [bridge handleNativeScrollWheelEvent:event];

    if (g_originalSendEvent && !handledNativeOsrScroll) {
        // The prebuilt FlutterMacOS engine ships with live NSAsserts. Its
        // trackpad gesture state machine (-[FlutterViewController
        // dispatchMouseEvent:phase:], FlutterViewController.mm:662) raises
        // NSInternalInconsistencyException "Received gesture event with
        // unexpected phase" when a scroll gesture's NSEventPhaseEnded reaches
        // the FlutterView without its matching NSEventPhaseBegan. That happens
        // whenever the window/responder chain churns mid-scroll — keyboard
        // window-snapping (half/full), sidebar toggles, live resize — which is
        // core to how this IDE is driven. The exception is uncaught, so AppKit
        // escalates it via -reportException:/+_crashOnException: to SIGTRAP and
        // kills the app. We cannot rebuild the engine, and making our overlay
        // views hit-test-transparent (CefDragParticipantView) does not help
        // because the desync lives in the engine's private state machine, not
        // our view tree. Contain it here: for gesture events only, swallow the
        // engine's assertion (dropping one stray scroll beats crashing) and
        // re-raise anything that is not an assertion failure so unrelated bugs
        // still surface.
        const BOOL isGestureEvent = event.type == NSEventTypeScrollWheel ||
                                    event.type == NSEventTypeMagnify ||
                                    event.type == NSEventTypeRotate;
        if (isGestureEvent) {
            @try {
                ((void (*)(id, SEL, NSEvent*))g_originalSendEvent)(self, _cmd, event);
            } @catch (NSException* exception) {
                if (![exception.name isEqualToString:NSInternalInconsistencyException]) {
                    @throw;
                }
                NSLog(@"[flutter_cef_browser] swallowed Flutter gesture-phase "
                      @"assertion (event type %ld): %@",
                      (long)event.type, exception.reason);
            }
        } else {
            ((void (*)(id, SEL, NSEvent*))g_originalSendEvent)(self, _cmd, event);
        }
    }

    // Flutter's MouseRegion cursor update runs during sendEvent and otherwise
    // overwrites CEF's one-shot OnCursorChange result. Apply the stored browser
    // cursor last; outside an OSR rect this is a no-op so Flutter keeps control.
    if (EventMayUpdateOsrCursor(event.type)) {
        [bridge applyOsrCursorForEvent:event];
    }

    g_cefHandlingSendEvent = wasHandling;
}

static BOOL IsHandlingSendEvent(id self, SEL _cmd) {
    return g_cefHandlingSendEvent;
}

static void SetHandlingSendEvent(id self, SEL _cmd, BOOL handling) {
    g_cefHandlingSendEvent = handling;
}

static void InjectCefAppProtocol(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class appClass = [NSApplication class];

        // Provide CrAppProtocol / CrAppControlProtocol methods required by CEF.
        class_replaceMethod(appClass, @selector(isHandlingSendEvent), (IMP)IsHandlingSendEvent, "B@:");
        class_replaceMethod(appClass, @selector(setHandlingSendEvent:), (IMP)SetHandlingSendEvent, "v@:B");

        // Swizzle -[NSApplication sendEvent:] so isHandlingSendEvent reflects reality.
        Method originalMethod = class_getInstanceMethod(appClass, @selector(sendEvent:));
        g_originalSendEvent = method_getImplementation(originalMethod);
        method_setImplementation(originalMethod, (IMP)SwizzledSendEvent);
    });
}

// External message pump implementation.
@interface CEFMessagePump : NSObject
- (instancetype)initWithMode:(CEFMessagePumpMode)mode
               maxPumpDelayMs:(NSInteger)maxPumpDelayMs
    enableFallbackTimer:(BOOL)enableFallbackTimer;
- (void)scheduleWork:(int64_t)delayMs;
- (void)doMessageLoopWork;
- (NSDictionary<NSString*, id>*)statsSnapshot;
- (void)shutdown;
@end

@implementation CEFMessagePump {
    NSTimer* _fallbackTimer;
    BOOL _shuttingDown;
    BOOL _isDoingWork;
    BOOL _immediateWorkScheduled;
    uint64_t _scheduledGeneration;
    CEFMessagePumpMode _mode;
    NSTimeInterval _maxDelaySeconds;
    uint64_t _scheduleRequestsReceived;
    uint64_t _immediateScheduleCount;
    uint64_t _delayedScheduleCount;
    uint64_t _collapsedDelayedWorkCount;
    uint64_t _fallbackTimerFireCount;
    uint64_t _fallbackRescueCount;
    uint64_t _reentrantSkipCount;
    uint64_t _scheduleToWorkSampleCount;
    double _scheduleToWorkTotalMs;
    double _scheduleToWorkMaxMs;
    double _maxNoProgressIntervalMs;
    NSDate* _lastScheduleRequestAt;
    NSDate* _lastWorkCompletedAt;
}

- (instancetype)initWithMode:(CEFMessagePumpMode)mode
               maxPumpDelayMs:(NSInteger)maxPumpDelayMs
    enableFallbackTimer:(BOOL)enableFallbackTimer {
    self = [super init];
    if (self) {
        _shuttingDown = NO;
        _isDoingWork = NO;
        _immediateWorkScheduled = NO;
        _scheduledGeneration = 0;
        _mode = mode;
        const NSInteger clampedMaxDelayMs = MAX(1, MIN(maxPumpDelayMs, 1000));
        _maxDelaySeconds = ((NSTimeInterval)clampedMaxDelayMs) / 1000.0;
        _scheduleRequestsReceived = 0;
        _immediateScheduleCount = 0;
        _delayedScheduleCount = 0;
        _collapsedDelayedWorkCount = 0;
        _fallbackTimerFireCount = 0;
        _fallbackRescueCount = 0;
        _reentrantSkipCount = 0;
        _scheduleToWorkSampleCount = 0;
        _scheduleToWorkTotalMs = 0;
        _scheduleToWorkMaxMs = 0;
        _maxNoProgressIntervalMs = 0;
        _lastScheduleRequestAt = nil;
        _lastWorkCompletedAt = nil;

        if (enableFallbackTimer) {
            _fallbackTimer = [NSTimer scheduledTimerWithTimeInterval:_maxDelaySeconds
                                                              target:self
                                                            selector:@selector(handleFallbackTimer:)
                                                            userInfo:nil
                                                             repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:_fallbackTimer forMode:NSRunLoopCommonModes];
        } else {
            _fallbackTimer = nil;
        }
    }
    return self;
}

- (void)scheduleWork:(int64_t)delayMs {
    if (_shuttingDown) return;

    _scheduleRequestsReceived += 1;
    _lastScheduleRequestAt = [NSDate date];
    const NSTimeInterval delay = MIN(MAX((NSTimeInterval)delayMs / 1000.0, 0), _maxDelaySeconds);
    __weak CEFMessagePump* weakSelf = self;

    // "Simple" mode mirrors the old behavior and lets every callback schedule work.
    if (_mode == CEFMessagePumpModeSimple) {
        if (delay <= 0) {
            _immediateScheduleCount += 1;
            NSDate* scheduledAt = [NSDate date];
            dispatch_async(dispatch_get_main_queue(), ^{
                CEFMessagePump* strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf doMessageLoopWorkWithSource:@"schedule_immediate"
                                             scheduledAt:scheduledAt];
            });
            return;
        }
        _delayedScheduleCount += 1;
        NSDate* scheduledAt = [NSDate date];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CEFMessagePump* strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf doMessageLoopWorkWithSource:@"schedule_delayed"
                                         scheduledAt:scheduledAt];
        });
        return;
    }

    // "Sample-compatible" mode collapses stale delayed callbacks so the latest
    // CEF schedule hint wins.
    if (delayMs <= 0) {
        if (_immediateWorkScheduled) return;
        _immediateWorkScheduled = YES;
        _immediateScheduleCount += 1;
        NSDate* scheduledAt = [NSDate date];
        dispatch_async(dispatch_get_main_queue(), ^{
            CEFMessagePump* strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_immediateWorkScheduled = NO;
            [strongSelf doMessageLoopWorkWithSource:@"schedule_immediate"
                                         scheduledAt:scheduledAt];
        });
        return;
    }

    _scheduledGeneration += 1;
    _delayedScheduleCount += 1;
    const uint64_t generation = _scheduledGeneration;
    NSDate* scheduledAt = [NSDate date];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CEFMessagePump* strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_shuttingDown) return;
        if (generation != strongSelf->_scheduledGeneration) {
            strongSelf->_collapsedDelayedWorkCount += 1;
            return;
        }
        [strongSelf doMessageLoopWorkWithSource:@"schedule_delayed"
                                     scheduledAt:scheduledAt];
    });
}

- (void)handleFallbackTimer:(__unused NSTimer*)timer {
    _fallbackTimerFireCount += 1;
    [self doMessageLoopWorkWithSource:@"fallback_timer" scheduledAt:nil];
}

- (void)doMessageLoopWork {
    [self doMessageLoopWorkWithSource:@"direct" scheduledAt:nil];
}

- (void)doMessageLoopWorkWithSource:(NSString*)source
                        scheduledAt:(NSDate*)scheduledAt {
    if (_shuttingDown) return;
    if (_isDoingWork) {
        _reentrantSkipCount += 1;
        return;
    }
    NSDate* now = [NSDate date];
    if (_lastWorkCompletedAt != nil) {
        const double noProgressMs =
            [now timeIntervalSinceDate:_lastWorkCompletedAt] * 1000.0;
        if (noProgressMs > _maxNoProgressIntervalMs) {
            _maxNoProgressIntervalMs = noProgressMs;
        }
        if ([source isEqualToString:@"fallback_timer"]) {
            const double rescueThresholdMs = MAX(_maxDelaySeconds * 1000.0 * 1.5, 50.0);
            BOOL likelyRescue = (noProgressMs >= rescueThresholdMs);
            if (!likelyRescue && _lastScheduleRequestAt != nil &&
                [_lastScheduleRequestAt compare:_lastWorkCompletedAt] == NSOrderedDescending) {
                likelyRescue = YES;
            }
            if (likelyRescue) {
                _fallbackRescueCount += 1;
            }
        }
    }
    if (scheduledAt != nil) {
        const double latencyMs = [now timeIntervalSinceDate:scheduledAt] * 1000.0;
        _scheduleToWorkSampleCount += 1;
        _scheduleToWorkTotalMs += latencyMs;
        if (latencyMs > _scheduleToWorkMaxMs) {
            _scheduleToWorkMaxMs = latencyMs;
        }
    }
    _isDoingWork = YES;
    CefDoMessageLoopWork();
    _isDoingWork = NO;
    _lastWorkCompletedAt = [NSDate date];
}

- (NSDictionary<NSString*, id>*)statsSnapshot {
    const double averageScheduleToWorkMs = _scheduleToWorkSampleCount == 0
        ? 0
        : (_scheduleToWorkTotalMs / (double)_scheduleToWorkSampleCount);
    return @{
        @"scheduleRequestsReceived": @((unsigned long long)_scheduleRequestsReceived),
        @"immediateScheduleCount": @((unsigned long long)_immediateScheduleCount),
        @"delayedScheduleCount": @((unsigned long long)_delayedScheduleCount),
        @"collapsedDelayedWorkCount": @((unsigned long long)_collapsedDelayedWorkCount),
        @"fallbackTimerFireCount": @((unsigned long long)_fallbackTimerFireCount),
        @"fallbackRescueCount": @((unsigned long long)_fallbackRescueCount),
        @"reentrantSkipCount": @((unsigned long long)_reentrantSkipCount),
        @"scheduleToWorkSampleCount": @((unsigned long long)_scheduleToWorkSampleCount),
        @"scheduleToWorkAverageMs": @(averageScheduleToWorkMs),
        @"scheduleToWorkMaxMs": @(_scheduleToWorkMaxMs),
        @"maxNoProgressIntervalMs": @(_maxNoProgressIntervalMs),
    };
}

- (void)shutdown {
    _shuttingDown = YES;
    _scheduledGeneration += 1;
    [_fallbackTimer invalidate];
    _fallbackTimer = nil;
}

@end

static NSString* CefMenuLabelToNSString(const CefString& label) {
    NSString* text = [NSString stringWithUTF8String:label.ToString().c_str()] ?: @"";
    // CEF labels carry Windows-style '&' accelerator markers.
    return [text stringByReplacingOccurrencesOfString:@"&" withString:@""];
}

static NSArray<NSDictionary<NSString*, id>*>* SerializeCefMenuModel(
    CefRefPtr<CefMenuModel> model) {
    NSMutableArray<NSDictionary<NSString*, id>*>* items = [NSMutableArray array];
    if (!model) return items;
    const size_t count = model->GetCount();
    for (size_t index = 0; index < count; index++) {
        const CefMenuModel::MenuItemType type = model->GetTypeAt(index);
        NSString* typeName = nil;
        NSArray<NSDictionary<NSString*, id>*>* submenu = @[];
        switch (type) {
            case MENUITEMTYPE_SEPARATOR:
                typeName = @"separator";
                break;
            case MENUITEMTYPE_SUBMENU:
                typeName = @"submenu";
                submenu = SerializeCefMenuModel(model->GetSubMenuAt(index));
                break;
            case MENUITEMTYPE_COMMAND:
                typeName = @"command";
                break;
            case MENUITEMTYPE_CHECK:
                typeName = @"check";
                break;
            case MENUITEMTYPE_RADIO: {
                typeName = @"radio";
                break;
            }
            case MENUITEMTYPE_NONE:
                break;
        }
        if (!typeName) continue;
        const BOOL enabled = type != MENUITEMTYPE_SEPARATOR &&
            model->IsEnabledAt(index);
        const BOOL checked =
            (type == MENUITEMTYPE_CHECK || type == MENUITEMTYPE_RADIO) &&
            model->IsCheckedAt(index);
        [items addObject:@{
            @"commandId": @(model->GetCommandIdAt(index)),
            @"label": CefMenuLabelToNSString(model->GetLabelAt(index)),
            @"type": typeName,
            @"enabled": @(enabled),
            @"checked": @(checked),
            @"submenu": submenu,
        }];
    }
    return items;
}

@interface CEFBridge () <CEFClientDelegate, CefDragParticipantViewDelegate>
- (NSDictionary<NSString*, id>*)normalizedRuntimeConfigFromRawConfig:(NSDictionary<NSString*, id>*)rawConfig;
- (NSDictionary<NSString*, id>*)newPreflightReportWithConfig:(NSDictionary<NSString*, id>*)config
                                                      source:(NSString*)source;
- (void)addIssue:(NSDictionary<NSString*, id>*)issue
      toWarnings:(NSMutableArray<NSDictionary*>*)warnings
        failures:(NSMutableArray<NSDictionary*>*)failures;
- (NSDictionary<NSString*, id>*)finalizePreflightReport:(NSMutableDictionary<NSString*, id>*)report
                                                warnings:(NSMutableArray<NSDictionary*>*)warnings
                                                failures:(NSMutableArray<NSDictionary*>*)failures;
- (void)cancelPendingEvaluateJavaScriptForCefBrowserId:(int)cefBrowserId;
- (void)cancelPendingScreenshotsForCefBrowserId:(int)cefBrowserId;
- (void)handleContextInitialized;
- (void)handleScheduleMessagePumpWork:(int64_t)delayMs;
- (void)ensureDevToolsObserverForBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)removeDevToolsObserverForCefBrowserId:(int)cefBrowserId;
- (void)handleDevToolsMethodResultForCefBrowserId:(int)cefBrowserId
                                        messageId:(int)messageId
                                           success:(BOOL)success
                                            result:(NSDictionary*)result;
- (void)handleDevToolsEventForCefBrowserId:(int)cefBrowserId
                                     method:(NSString*)method
                                     params:(NSDictionary*)params;
- (void)emitNetworkEventForCefBrowserId:(int)cefBrowserId
                                  method:(NSString*)method
                                  params:(NSDictionary*)params;
- (NSDictionary*)normalizedNetworkEventForMethod:(NSString*)method
                                          params:(NSDictionary*)params;
- (void)cancelPendingResponseBodyForCefBrowserId:(int)cefBrowserId;
- (NSDictionary<NSString*, id>*)resolvedCommandLineSwitches;
- (void)recordInitializationFailureCode:(nullable NSString*)failureCode
                                  stage:(nullable NSString*)failureStage;
- (void)emitLifecycleDiagnostic:(NSDictionary<NSString*, id>*)diagnostic;
- (void)managedPopupGoBack:(id)sender;
- (void)managedPopupGoForward:(id)sender;
- (void)managedPopupReload:(id)sender;
- (void)managedPopupCopyURL:(id)sender;
- (void)managedPopupOpenExternal:(id)sender;
- (void)managedPopupClose:(id)sender;
- (void)resizeManagedPopupBrowser:(int)browserId;
- (BOOL)isManagedPopupBrowserId:(int)browserId;
- (void)orderOutManagedPopupWindowForBrowserId:(int)browserId;
- (void)cleanupManagedPopupForBrowserId:(int)browserId closeWindow:(BOOL)closeWindow;
- (void)cleanupAllManagedPopupWindows;
- (NSPoint)popupAdjustedInputPointForBrowserId:(int)browserId x:(CGFloat)x y:(CGFloat)y;
- (void)finishSyntheticPinchForBrowserId:(int)browserId generation:(uint64_t)generation;
- (void)emitCreateMappingDiagnosticForFlutterBrowserId:(int)flutterBrowserId
                                          cefBrowserId:(int)cefBrowserId
                                         mappingSource:(NSString*)mappingSource
                                       createRequestId:(nullable NSString*)createRequestId;
- (void)emitDeterministicCreateMappingFailureForCefBrowserId:(int)cefBrowserId
                                               browserView:(nullable NSView*)browserView;
- (BOOL)bindDefaultRequestContext;
- (void)ensureMessagePump;
- (void)invalidateCloseFallbackTimerForBrowserId:(int)browserId;
- (void)scheduleCloseFallbackTimerForBrowserId:(int)browserId;
- (void)cancelPendingContextMenusForBrowserId:(int)browserId;
- (void)cancelAllPendingContextMenus;
- (int)osrBrowserAtEvent:(NSEvent*)event localPoint:(NSPoint*)localPoint;
- (BOOL)browserPointForEvent:(NSEvent*)event
                  browserId:(int)browserId
                  localPoint:(NSPoint*)localPoint;
@end

@class CEFManagedPopupWindowDelegate;

@interface CEFManagedPopupWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, weak) CEFBridge* bridge;
@property (nonatomic, assign) int browserId;
@property (nonatomic, assign) BOOL closingProgrammatically;
@end

@implementation CEFManagedPopupWindowDelegate

- (BOOL)windowShouldClose:(id)sender {
    if (self.closingProgrammatically) {
        return YES;
    }
    NSWindow* window = [sender isKindOfClass:[NSWindow class]] ? (NSWindow*)sender : nil;
    [window orderOut:nil];
    [self.bridge closeBrowser:self.browserId];
    return NO;
}

- (void)windowDidResize:(NSNotification*)notification {
    [self.bridge resizeManagedPopupBrowser:self.browserId];
}

- (void)goBack:(id)sender { [self.bridge managedPopupGoBack:sender]; }
- (void)goForward:(id)sender { [self.bridge managedPopupGoForward:sender]; }
- (void)reload:(id)sender { [self.bridge managedPopupReload:sender]; }
- (void)copyURL:(id)sender { [self.bridge managedPopupCopyURL:sender]; }
- (void)openExternal:(id)sender { [self.bridge managedPopupOpenExternal:sender]; }
- (void)closePopup:(id)sender { [self.bridge managedPopupClose:sender]; }

@end

// Custom DevTools window that handles quit safely and tracks parent window
@interface DevToolsWindow : NSWindow
@property (nonatomic, assign) int browserId;
@property (nonatomic, weak) id devToolsDelegate;  // CEFBridge
@property (nonatomic, weak) NSWindow *hostWindow;
@property (nonatomic, copy) NSString *dockPosition;  // "bottom" or "right"
@property (nonatomic, assign) CGFloat dockSize;  // height for bottom, width for right
@end

@implementation DevToolsWindow

@synthesize browserId = _browserId;
@synthesize devToolsDelegate = _devToolsDelegate;
@synthesize hostWindow = _hostWindow;
@synthesize dockPosition = _dockPosition;
@synthesize dockSize = _dockSize;

- (instancetype)initWithContentRect:(NSRect)contentRect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backingStoreType
                              defer:(BOOL)flag {
    self = [super initWithContentRect:contentRect styleMask:style backing:backingStoreType defer:flag];
    if (self) {
        // Setup window observers for parent window changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(parentWindowDidResize:)
                                                     name:NSWindowDidResizeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(parentWindowDidMove:)
                                                     name:NSWindowDidMoveNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)parentWindowDidResize:(NSNotification *)notification {
    if (notification.object == self.hostWindow) {
        [self updatePositionForParentWindow];
    }
}

- (void)parentWindowDidMove:(NSNotification *)notification {
    if (notification.object == self.hostWindow) {
        [self updatePositionForParentWindow];
    }
}

- (void)updatePositionForParentWindow {
    if (!self.hostWindow) return;

    NSRect contentRect = [[self.hostWindow contentView] frame];
    NSPoint contentOrigin = [[self.hostWindow contentView] convertPoint:NSZeroPoint toView:nil];
    NSPoint screenOrigin = [self.hostWindow convertPointToScreen:contentOrigin];

    NSRect newFrame;
    if ([self.dockPosition isEqualToString:@"bottom"]) {
        // Position at bottom of main window
        newFrame = NSMakeRect(
            screenOrigin.x,
            screenOrigin.y,
            contentRect.size.width,
            self.dockSize
        );
    } else { // "right"
        // Position at right side
        newFrame = NSMakeRect(
            screenOrigin.x + contentRect.size.width - self.dockSize,
            screenOrigin.y,
            self.dockSize,
            contentRect.size.height
        );
    }

    [self setFrame:newFrame display:YES animate:NO];
}

- (void)performClose:(id)sender {
    // Intercept window close to notify CEFBridge
    NSLog(@"DevToolsWindow: performClose called, notifying delegate");
    if ([_devToolsDelegate respondsToSelector:@selector(hideDevTools:)]) {
        [_devToolsDelegate hideDevTools:_browserId];
    }
    // Don't call super - hideDevTools will close us properly
}

- (void)keyDown:(NSEvent *)event {
    // Intercept Cmd+Q to prevent crashing
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars isEqualToString:@"q"]) {
            NSLog(@"DevToolsWindow: Cmd+Q intercepted, closing DevTools only");
            [self performClose:nil];
            return;
        }
    }
    [super keyDown:event];
}

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return NO;  // Prevent it from becoming main window
}

@end

// CEF Application for browser process
class BrowserApp : public CefApp, public CefBrowserProcessHandler {
public:
    BrowserApp() {}

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }

    void OnBeforeCommandLineProcessing(const CefString& process_type,
                                       CefRefPtr<CefCommandLine> command_line) override {
        CEFBridge* bridge = [CEFBridge sharedInstance];
        if (!bridge) return;

        // Follow cefclient behavior: treat browser-process command-line policy
        // as authoritative and avoid ad-hoc mutations in subprocesses.
        const bool isBrowserProcess = process_type.empty();
        if (!isBrowserProcess) {
            return;
        }

        NSDictionary<NSString*, id>* switches = [bridge resolvedCommandLineSwitches];
        [switches enumerateKeysAndObjectsUsingBlock:^(NSString* key, id value, __unused BOOL* stop) {
            if (!key || key.length == 0) return;

            std::string switchName([key UTF8String]);
            if (!value || value == [NSNull null]) {
                if (!command_line->HasSwitch(switchName)) {
                    command_line->AppendSwitch(switchName);
                }
                return;
            }

            NSString* switchValue = [value isKindOfClass:[NSString class]]
                ? (NSString*)value
                : ([value description] ?: @"");
            command_line->AppendSwitchWithValue(switchName, [switchValue UTF8String]);
        }];

        // The DevTools frontend is served from a non-local origin
        // (chrome-devtools-frontend.appspot.com); Chromium 147 rejects its
        // remote-debugging WebSocket unless the origin is allow-listed. Permit
        // it so the docked DevTools pane can connect (loopback-bound port).
        if ([bridge remoteDebuggingEnabled] &&
            !command_line->HasSwitch("remote-allow-origins")) {
            command_line->AppendSwitchWithValue("remote-allow-origins", "*");
        }

        if ([bridge shouldEnableChromeRuntime]) {
            NSArray<NSString*>* extPaths = [bridge extensionPaths];
            if (extPaths.count > 0) {
                std::string joined;
                for (NSUInteger i = 0; i < extPaths.count; i++) {
                    NSString* p = extPaths[i];
                    if (!p || [p length] == 0) continue;
                    if (!joined.empty()) joined.append(",");
                    joined.append([p UTF8String]);
                }
                if (!joined.empty()) {
                    command_line->AppendSwitchWithValue("load-extension", joined);
                    command_line->AppendSwitchWithValue("disable-extensions-except", joined);
                }
            }
        }
    }

    void OnContextInitialized() override {
        CEF_REQUIRE_UI_THREAD();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[CEFBridge sharedInstance] handleContextInitialized];
        });
    }

    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        static bool logged = false;
        if (!logged) {
            NSLog(@"CEFBridge: OnScheduleMessagePumpWork called (first time), delay_ms: %lld", delay_ms);
            logged = true;
        }

        [[CEFBridge sharedInstance] handleScheduleMessagePumpWork:delay_ms];
    }

private:
    IMPLEMENT_REFCOUNTING(BrowserApp);
};

// Dedicated client for DevTools browsers.
//
// We intentionally do NOT route DevTools events into the Flutter layer, and we
// also do not cancel popups (DevTools may legitimately open windows).
class DevToolsClient : public CefClient, public CefLifeSpanHandler {
public:
    DevToolsClient() {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        NSLog(@"CEFBridge: Native DevTools browser created cefId=%d",
              browser ? browser->GetIdentifier() : -1);
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        NSLog(@"CEFBridge: Native DevTools browser closing cefId=%d",
              browser ? browser->GetIdentifier() : -1);
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int popup_id,
                       const CefString& target_url,
                       const CefString& target_frame_name,
                       WindowOpenDisposition target_disposition,
                       bool user_gesture,
                       const CefPopupFeatures& popupFeatures,
                       CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client,
                       CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info,
                       bool* no_javascript_access) override {
        // Allow DevTools popups to be handled by CEF normally.
        return false;
    }

private:
    IMPLEMENT_REFCOUNTING(DevToolsClient);
    DISALLOW_COPY_AND_ASSIGN(DevToolsClient);
};

@class CEFBridge;

class BridgeDevToolsObserver : public CefDevToolsMessageObserver {
public:
    BridgeDevToolsObserver(CEFBridge* bridge, int cefBrowserId)
        : bridge_(bridge), cefBrowserId_(cefBrowserId) {}

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                int message_id,
                                bool success,
                                const void* result,
                                size_t result_size) override;

    void OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                         const CefString& method,
                         const void* params,
                         size_t params_size) override;

private:
    __weak CEFBridge* bridge_;
    int cefBrowserId_;

    IMPLEMENT_REFCOUNTING(BridgeDevToolsObserver);
    DISALLOW_COPY_AND_ASSIGN(BridgeDevToolsObserver);
};

class CookieCollectorVisitor : public CefCookieVisitor {
public:
    CookieCollectorVisitor(CookieListCompletion completion,
                           std::shared_ptr<std::atomic_bool> done)
        : completion_(completion ? [completion copy] : nil),
          done_(std::move(done)),
          cookies_([[NSMutableArray alloc] init]) {}

    bool Visit(const CefCookie& cookie,
               int count,
               int total,
               bool& deleteCookie) override {
        deleteCookie = false;

        NSString* sameSite = @"unspecified";
        switch (cookie.same_site) {
            case CEF_COOKIE_SAME_SITE_NO_RESTRICTION:
                sameSite = @"none";
                break;
            case CEF_COOKIE_SAME_SITE_LAX_MODE:
                sameSite = @"lax";
                break;
            case CEF_COOKIE_SAME_SITE_STRICT_MODE:
                sameSite = @"strict";
                break;
            case CEF_COOKIE_SAME_SITE_UNSPECIFIED:
            default:
                sameSite = @"unspecified";
                break;
        }

        NSMutableDictionary* row = [NSMutableDictionary dictionaryWithDictionary:@{
            @"name": NSStringFromCefString(CefString(&cookie.name)),
            @"value": NSStringFromCefString(CefString(&cookie.value)),
            @"domain": NSStringFromCefString(CefString(&cookie.domain)),
            @"path": NSStringFromCefString(CefString(&cookie.path)),
            @"secure": @(cookie.secure),
            @"httpOnly": @(cookie.httponly),
            @"sameSite": sameSite,
            @"creation": @(SecondsFromCefBaseTime(cookie.creation)),
            @"lastAccess": @(SecondsFromCefBaseTime(cookie.last_access)),
            @"hasExpires": @(cookie.has_expires),
        }];
        if (cookie.has_expires) {
            row[@"expires"] = @(SecondsFromCefBaseTime(cookie.expires));
        }
        [cookies_ addObject:row];

        if (total <= 0 || count >= total - 1) {
            complete();
        }
        return true;
    }

    void complete() {
        if (!done_) return;
        if (done_->exchange(true)) return;
        NSArray* result = [cookies_ copy] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion_) completion_(result);
        });
    }

private:
    CookieListCompletion completion_;
    std::shared_ptr<std::atomic_bool> done_;
    NSMutableArray<NSDictionary*>* cookies_;

    IMPLEMENT_REFCOUNTING(CookieCollectorVisitor);
    DISALLOW_COPY_AND_ASSIGN(CookieCollectorVisitor);
};

void BridgeDevToolsObserver::OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                                    int message_id,
                                                    bool success,
                                                    const void* result,
                                                    size_t result_size) {
    CEFBridge* bridge = bridge_;
    if (!bridge) return;

    const int cefId = browser ? browser->GetIdentifier() : cefBrowserId_;
    NSDictionary* resultDict = ParseDevToolsJsonDict(result, result_size);
    dispatch_async(dispatch_get_main_queue(), ^{
        [bridge handleDevToolsMethodResultForCefBrowserId:cefId
                                                messageId:message_id
                                                   success:success
                                                    result:resultDict];
    });
}

void BridgeDevToolsObserver::OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                                             const CefString& method,
                                             const void* params,
                                             size_t params_size) {
    CEFBridge* bridge = bridge_;
    if (!bridge) return;

    const int cefId = browser ? browser->GetIdentifier() : cefBrowserId_;
    NSString* objcMethod = NSStringFromCefString(method);
    NSDictionary* paramsDict = ParseDevToolsJsonDict(params, params_size);
    dispatch_async(dispatch_get_main_queue(), ^{
        [bridge handleDevToolsEventForCefBrowserId:cefId
                                             method:objcMethod
                                             params:paramsDict];
    });
}

struct CefSyntheticPinchState {
    BOOL active = NO;
    double scale = 1.0;
    double anchorX = 0;
    double anchorY = 0;
    // Blink's gesture provider enforces a minimum scaling span (~125-200px);
    // a shrinking span below it is ignored, which killed pinch-OUT while
    // pinch-in (growing span) worked. Start wide, and never let the synthetic
    // span collapse below the recognizer's floor (see kMinSpanScale).
    double radius = 160.0;
    uint64_t generation = 0;
};

// Floor for the synthetic touch separation as a fraction of the base radius:
// 2*160*0.45 = 144px stays above Blink's minimum scaling span, so zoom-out
// keeps registering. Deeper zoom-out compounds across repeated gestures.
static const double kMinSpanScale = 0.45;

@implementation CEFBridge {
    CefRefPtr<CEFClientImpl> _client;
    CefRefPtr<DevToolsClient> _devToolsClient;
    CefRefPtr<CefRequestContext> _requestContext;
    CefRefPtr<CefRequestContext> _incognitoRequestContext;
    CefRefPtr<BrowserApp> _app;

    CEFMessagePump* _messagePump;
    BOOL _contextInitialized;
    NSMutableArray<NSDictionary*>* _pendingBrowserCreations;
    NSTimer* _contextInitPollTimer;

    std::map<int, __weak NSView*> _browserViews;        // Flutter browserId -> container NSView (weak)
    std::map<int, NSView*> _devToolsPanels;      // Flutter browserId -> DevTools NSView
    std::map<int, CefRefPtr<CefBrowser>> _devToolsBrowsers; // Flutter browserId -> DevTools browser
    std::map<int, ResizableDivider*> _devToolsDividers; // Flutter browserId -> Divider
    std::map<int, std::string> _devToolsDockPosition; // Flutter browserId -> "bottom"|"right"
    std::map<int, CGFloat> _devToolsSizes;       // Flutter browserId -> DevTools size (width or height)
    std::map<int, std::string> _devToolsTargetIdByFlutterBrowserId; // Flutter browserId -> CDP target id
    std::map<int, CefRefPtr<BridgeDevToolsObserver>> _devToolsObserversByCefId;
    std::map<int, CefRefPtr<CefRegistration>> _devToolsObserverRegsByCefId;
    std::map<int, int> _flutterToCefBrowserId;   // Flutter browserId -> CEF browserId
    std::map<int, int> _cefToFlutterBrowserId;   // CEF browserId -> Flutter browserId
    std::deque<int> _pendingFlutterBrowserIds;   // FIFO mapping for async CreateBrowser
    NSMutableDictionary<NSNumber*, NSDictionary*>* _pendingCreateMetadataByFlutterId;
    std::unordered_set<int> _pendingFlutterBrowserCloses; // Flutter browserId close requested before mapping
    std::unordered_set<int> _closingFlutterBrowserIds; // Flutter browserIds actively tearing down
    std::unordered_set<int> _incognitoFlutterBrowserIds; // Flutter browserIds using the shared incognito request context
    std::unordered_set<int> _osrFlutterBrowserIds; // Flutter browserIds using windowless texture rendering
    std::map<int, CGFloat> _osrDeviceScaleFactors; // Flutter browserId -> Flutter DPR for OSR
    std::map<int, int> _osrTargetFrameRates;       // Flutter browserId -> requested windowless fps
    std::unordered_set<int> _osrHiddenBrowserIds;  // Flutter browserIds Dart wants hidden
    std::unordered_set<int> _osrBackgroundActivityExemptBrowserIds;
    std::unordered_set<int> _osrFrameLeaseConfiguredBrowserIds;
    std::unordered_set<int> _osrFrameLeaseEnabledBrowserIds;
    std::unordered_set<int> _osrParkedBrowserIds;  // Flutter browserIds actually parked via WasHidden
    std::map<int, uint64_t> _osrPendingParkGenerations;
    uint64_t _nextOsrParkGeneration;
    BOOL _osrWindowOccluded;                       // Host window fully occluded/miniaturized
    std::unordered_set<int> _osrPopupVisibleBrowserIds;
    std::map<int, CGRect> _osrOriginalPopupRects;
    std::map<int, CGRect> _osrPopupRects;
    std::map<int, CefSyntheticPinchState> _syntheticPinches;
    int _nativeScrollGestureBrowserId;
    NSPoint _nativeScrollGesturePoint;
    double _nativeScrollRemainderX;
    double _nativeScrollRemainderY;
    int _nativeSwipeGestureBrowserId;
    double _nativeSwipeAccumulatedX;
    NSInteger _nativeSwipeDirection;
    BOOL _nativeSwipeGestureActive;
    BOOL _nativeSwipeSuppressMomentum;
    NSMutableDictionary<NSNumber*, NSCursor*>* _osrCursorsByBrowserId;
    int _activeOsrCursorBrowserId;
    NSMutableDictionary<NSNumber*, CefDragParticipantView*>* _dragParticipants; // OSR drag views
    std::map<int, CefRefPtr<CefDragData>> _outboundDragData; // retained while a session runs
    std::map<int, CefRefPtr<CefRunContextMenuCallback>> _pendingContextMenuCallbacks;
    std::map<int, int> _pendingContextMenuBrowserIds;
    int _nextContextMenuId;
    std::map<int, int> _devToolsFlutterIdByOwnerId;  // owner Flutter id -> devtools Flutter id
    std::map<int, int> _devToolsOwnerIdByFlutterId;  // devtools Flutter id -> owner Flutter id
    int _nextDevToolsFlutterBrowserId;               // windowless DevTools id space
    std::unordered_set<int> _managedPopupFlutterBrowserIds; // Native popout browser ids.
    NSMutableDictionary<NSNumber*, NSWindow*>* _managedPopupWindowsByBrowserId;
    NSMutableDictionary<NSNumber*, CEFManagedPopupWindowDelegate*>* _managedPopupDelegatesByBrowserId;
    NSMutableDictionary<NSNumber*, NSTextField*>* _managedPopupTitleLabelsByBrowserId;
    NSMutableDictionary<NSNumber*, NSTextField*>* _managedPopupUrlLabelsByBrowserId;
    int _nextManagedPopupBrowserId;
    BOOL _isInitialized;
    BOOL _isInitializing;
    BOOL _deterministicCreate;
    BOOL _chromeRuntime;
    std::vector<std::string> _extensionPaths;
    NSDictionary<NSString*, id>* _resolvedCommandLineSwitches;
    CEFMessagePumpMode _messagePumpMode;
    NSInteger _maxPumpDelayMs;
    BOOL _enableMessagePumpFallbackTimer;
    BOOL _enableWindowlessRenderingSupport;
    BOOL _forceImmediateClose;
    NSInteger _gracefulCloseTimeoutMs;
    BOOL _requireHelper;
    BOOL _useMockKeychain;
    NSInteger _remoteDebuggingPort;
    NSInteger _uncaughtExceptionStackSize;
    NSString* _logFilePath;
    NSString* _crashDumpsPath;
    NSMutableDictionary<NSNumber*, NSTimer*>* _closeFallbackTimers;
    NSMutableDictionary<NSNumber*, NSDate*>* _closeStartedAtByBrowserId;
    NSDate* _lastMessageLoopWorkAt;

    NSHashTable<id<CEFBridgeDelegate>>* _delegates;
    NSMutableDictionary<NSString*, ResponseBodyCompletion>* _pendingResponseBodyCallbacks;
    NSMutableDictionary<NSString*, JavaScriptEvaluationCompletion>* _pendingEvaluateJavaScriptCallbacks;
    NSMutableDictionary<NSString*, TextInputCompletion>* _pendingTextInputCallbacks;
    NSMutableDictionary<NSString*, ScreenshotCompletion>* _pendingScreenshotCallbacks;
    NSString* _lastInitializationFailureCode;
    NSString* _lastInitializationFailureStage;
}

+ (instancetype)sharedInstance {
    static CEFBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CEFBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isInitialized = NO;
        _isInitializing = NO;
        _contextInitialized = NO;
        _pendingBrowserCreations = [NSMutableArray array];
        _messagePump = nil;
        _contextInitPollTimer = nil;
        _resolvedCommandLineSwitches = @{};
        _messagePumpMode = CEFMessagePumpModeSampleCompatible;
        _maxPumpDelayMs = 33;
        _enableMessagePumpFallbackTimer = YES;
        _enableWindowlessRenderingSupport = NO;
        _forceImmediateClose = NO;
        _gracefulCloseTimeoutMs = 1200;
        _requireHelper = YES;
        _useMockKeychain = NO;
        _remoteDebuggingPort = 0;
        _uncaughtExceptionStackSize = 10;
        _logFilePath = @"";
        _crashDumpsPath = @"";
        _deterministicCreate = YES;
        _closeFallbackTimers = [NSMutableDictionary dictionary];
        _closeStartedAtByBrowserId = [NSMutableDictionary dictionary];
        _delegates = [NSHashTable weakObjectsHashTable];
        _pendingResponseBodyCallbacks = [NSMutableDictionary dictionary];
        _pendingEvaluateJavaScriptCallbacks = [NSMutableDictionary dictionary];
        _pendingTextInputCallbacks = [NSMutableDictionary dictionary];
        _pendingScreenshotCallbacks = [NSMutableDictionary dictionary];
        _pendingCreateMetadataByFlutterId = [NSMutableDictionary dictionary];
        _managedPopupWindowsByBrowserId = [NSMutableDictionary dictionary];
        _dragParticipants = [NSMutableDictionary dictionary];
        _managedPopupDelegatesByBrowserId = [NSMutableDictionary dictionary];
        _managedPopupTitleLabelsByBrowserId = [NSMutableDictionary dictionary];
        _managedPopupUrlLabelsByBrowserId = [NSMutableDictionary dictionary];
        _nextManagedPopupBrowserId = 1000000000;
        _nextDevToolsFlutterBrowserId = 2000000000;
        _nextContextMenuId = 0;
        _nativeScrollGestureBrowserId = -1;
        _nativeScrollGesturePoint = NSZeroPoint;
        _nativeScrollRemainderX = 0.0;
        _nativeScrollRemainderY = 0.0;
        _nativeSwipeGestureBrowserId = -1;
        _nativeSwipeAccumulatedX = 0.0;
        _nativeSwipeDirection = 0;
        _nativeSwipeGestureActive = NO;
        _nativeSwipeSuppressMomentum = NO;
        _osrCursorsByBrowserId = [NSMutableDictionary dictionary];
        _activeOsrCursorBrowserId = -1;
        _lastMessageLoopWorkAt = nil;
        _lastInitializationFailureCode = nil;
        _lastInitializationFailureStage = nil;
    }
    return self;
}

- (CefRefPtr<CefRequestContext>)sharedIncognitoRequestContext {
    if (_incognitoRequestContext) {
        return _incognitoRequestContext;
    }

    cef_request_context_settings_t settings = {};
    settings.size = sizeof(cef_request_context_settings_t);
    settings.persist_session_cookies = 0;

    _incognitoRequestContext = CefRequestContext::CreateContext(settings, nullptr);
    if (_incognitoRequestContext) {
        NSLog(@"CEFBridge: Created shared incognito request context");
    } else {
        NSLog(@"CEFBridge: Failed to create shared incognito request context");
    }
    return _incognitoRequestContext;
}

- (BOOL)bindDefaultRequestContext {
    _requestContext = CefRequestContext::GetGlobalContext();
    if (_requestContext) {
        NSLog(@"CEFBridge: Using global request context for normal browsing");
        return YES;
    }

    NSLog(@"CEFBridge: Failed to obtain global request context");
    [self recordInitializationFailureCode:@"global_request_context_unavailable"
                                    stage:@"request_context"];
    return NO;
}

- (void)maybeReleaseIncognitoRequestContext {
    if (!_incognitoFlutterBrowserIds.empty()) return;
    if (_incognitoRequestContext) {
        NSLog(@"CEFBridge: Releasing shared incognito request context");
        _incognitoRequestContext = nullptr;
    }
}

- (BOOL)isBrowserClosingOrClosed:(int)browserId {
    return _closingFlutterBrowserIds.find(browserId) != _closingFlutterBrowserIds.end() ||
           _pendingFlutterBrowserCloses.find(browserId) != _pendingFlutterBrowserCloses.end();
}

- (int)nextManagedPopupBrowserId {
    while (_browserViews.find(_nextManagedPopupBrowserId) != _browserViews.end() ||
           _managedPopupFlutterBrowserIds.find(_nextManagedPopupBrowserId) != _managedPopupFlutterBrowserIds.end() ||
           _pendingCreateMetadataByFlutterId[@(_nextManagedPopupBrowserId)] != nil) {
        _nextManagedPopupBrowserId += 1;
    }
    return _nextManagedPopupBrowserId++;
}

- (NSString*)currentURLForBrowserId:(int)browserId {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (!browser || !browser->GetMainFrame()) {
        return @"";
    }
    return NSStringFromCefString(browser->GetMainFrame()->GetURL());
}

- (BOOL)isManagedPopupBrowserId:(int)browserId {
    return _managedPopupFlutterBrowserIds.find(browserId) != _managedPopupFlutterBrowserIds.end();
}

- (void)orderOutManagedPopupWindowForBrowserId:(int)browserId {
    if (![self isManagedPopupBrowserId:browserId]) return;
    NSWindow* window = _managedPopupWindowsByBrowserId[@(browserId)];
    [window orderOut:nil];
}

- (void)cleanupManagedPopupForBrowserId:(int)browserId closeWindow:(BOOL)closeWindow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cleanupManagedPopupForBrowserId:browserId closeWindow:closeWindow];
        });
        return;
    }
    if (![self isManagedPopupBrowserId:browserId]) return;

    NSNumber* key = @(browserId);
    NSWindow* window = _managedPopupWindowsByBrowserId[key];
    CEFManagedPopupWindowDelegate* popupDelegate = _managedPopupDelegatesByBrowserId[key];
    popupDelegate.closingProgrammatically = YES;
    if (window) {
        window.delegate = nil;
        [window orderOut:nil];
        if (closeWindow) {
            [window close];
        }
    }

    [_managedPopupWindowsByBrowserId removeObjectForKey:key];
    [_managedPopupDelegatesByBrowserId removeObjectForKey:key];
    [_managedPopupTitleLabelsByBrowserId removeObjectForKey:key];
    [_managedPopupUrlLabelsByBrowserId removeObjectForKey:key];
    _managedPopupFlutterBrowserIds.erase(browserId);
}

- (void)cleanupAllManagedPopupWindows {
    NSArray<NSNumber*>* popupIds = [_managedPopupWindowsByBrowserId.allKeys copy];
    for (NSNumber* popupId in popupIds) {
        [self cleanupManagedPopupForBrowserId:popupId.intValue closeWindow:YES];
    }
    _managedPopupFlutterBrowserIds.clear();
    [_managedPopupWindowsByBrowserId removeAllObjects];
    [_managedPopupDelegatesByBrowserId removeAllObjects];
    [_managedPopupTitleLabelsByBrowserId removeAllObjects];
    [_managedPopupUrlLabelsByBrowserId removeAllObjects];
}

- (nullable NSView*)onBeforePopup:(int)browserId
                          details:(NSDictionary*)details
                    proposedFrame:(NSRect)proposedFrame {
    if (![NSThread isMainThread]) {
        __block NSView* popupView = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            popupView = [self onBeforePopup:browserId
                                    details:details
                              proposedFrame:proposedFrame];
        });
        return popupView;
    }

    NSDictionary* popupFeatures = [details[@"popupFeatures"] isKindOfClass:[NSDictionary class]]
        ? (NSDictionary*)details[@"popupFeatures"]
        : @{};
    NSString* disposition = StringValueOrNil(details[@"targetDispositionName"]) ?: @"unknown";
    const BOOL userGesture = BoolValueOrDefault(details[@"userGesture"], NO);
    const BOOL requestedPopupWindow =
        BoolValueOrDefault(popupFeatures[@"isPopup"], NO) ||
        [disposition isEqualToString:@"newPopup"] ||
        [disposition isEqualToString:@"newWindow"];
    if (!userGesture || !requestedPopupWindow) {
        return nil;
    }

    const int openerFlutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    NSWindow* sourceWindow = nil;
    auto openerViewIt = _browserViews.find(openerFlutterBrowserId);
    if (openerViewIt != _browserViews.end() && openerViewIt->second) {
        sourceWindow = openerViewIt->second.window;
    }
    if (!sourceWindow) {
        sourceWindow = NSApp.mainWindow ?: NSApp.keyWindow;
    }

    NSRect windowFrame = ManagedPopupFrameForRequest(proposedFrame, details, sourceWindow);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:windowFrame
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable |
                                                              NSWindowStyleMaskResizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(360, 320);
    if (@available(macOS 10.12, *)) {
        window.tabbingMode = NSWindowTabbingModeDisallowed;
    }

    const int popupBrowserId = [self nextManagedPopupBrowserId];
    NSNumber* popupKey = @(popupBrowserId);
    CEFManagedPopupWindowDelegate* popupDelegate = [[CEFManagedPopupWindowDelegate alloc] init];
    popupDelegate.bridge = self;
    popupDelegate.browserId = popupBrowserId;
    window.delegate = popupDelegate;

    NSString* targetUrl = StringValueOrNil(details[@"targetUrl"]) ?: @"";
    NSURL* parsedUrl = targetUrl.length > 0 ? [NSURL URLWithString:targetUrl] : nil;
    NSString* initialTitle = parsedUrl.host.length > 0 ? parsedUrl.host : @"Web Pop-up";
    window.title = initialTitle;

    const CGFloat toolbarHeight = 46.0;
    NSView* contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, windowFrame.size.width, windowFrame.size.height)];
    contentView.wantsLayer = YES;
    contentView.autoresizesSubviews = YES;
    contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView* toolbar = [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                               windowFrame.size.height - toolbarHeight,
                                                               windowFrame.size.width,
                                                               toolbarHeight)];
    toolbar.wantsLayer = YES;
    toolbar.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    NSView* browserContainer = [[NSView alloc] initWithFrame:NSMakeRect(0,
                                                                        0,
                                                                        windowFrame.size.width,
                                                                        windowFrame.size.height - toolbarHeight)];
    browserContainer.wantsLayer = YES;
    browserContainer.layer.masksToBounds = YES;
    browserContainer.autoresizesSubviews = YES;
    browserContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSButton* backButton = ManagedPopupToolbarButton(@"chevron.left", @"Back", @"Back", popupDelegate, @selector(goBack:));
    NSButton* forwardButton = ManagedPopupToolbarButton(@"chevron.right", @"Fwd", @"Forward", popupDelegate, @selector(goForward:));
    NSButton* reloadButton = ManagedPopupToolbarButton(@"arrow.clockwise", @"Reload", @"Reload", popupDelegate, @selector(reload:));
    NSButton* copyButton = ManagedPopupToolbarButton(@"doc.on.doc", @"Copy", @"Copy URL", popupDelegate, @selector(copyURL:));
    NSButton* externalButton = ManagedPopupToolbarButton(@"safari", @"Open", @"Open in default browser", popupDelegate, @selector(openExternal:));
    NSButton* closeButton = ManagedPopupToolbarButton(@"xmark", @"Close", @"Close", popupDelegate, @selector(closePopup:));
    NSArray<NSButton*>* buttons = @[backButton, forwardButton, reloadButton, copyButton, externalButton, closeButton];
    for (NSButton* button in buttons) {
        button.tag = popupBrowserId;
        [toolbar addSubview:button];
    }
    backButton.frame = NSMakeRect(8, 10, 30, 26);
    forwardButton.frame = NSMakeRect(42, 10, 30, 26);
    reloadButton.frame = NSMakeRect(76, 10, 32, 26);
    copyButton.frame = NSMakeRect(windowFrame.size.width - 130, 10, 32, 26);
    externalButton.frame = NSMakeRect(windowFrame.size.width - 92, 10, 32, 26);
    closeButton.frame = NSMakeRect(windowFrame.size.width - 54, 10, 32, 26);
    copyButton.autoresizingMask = NSViewMinXMargin;
    externalButton.autoresizingMask = NSViewMinXMargin;
    closeButton.autoresizingMask = NSViewMinXMargin;

    NSTextField* titleLabel = ManagedPopupLabel(initialTitle, [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]);
    NSTextField* urlLabel = ManagedPopupLabel(targetUrl.length > 0 ? targetUrl : @"about:blank", [NSFont systemFontOfSize:11]);
    titleLabel.frame = NSMakeRect(120, 24, MAX(80, windowFrame.size.width - 270), 16);
    urlLabel.frame = NSMakeRect(120, 7, MAX(80, windowFrame.size.width - 270), 15);
    titleLabel.autoresizingMask = NSViewWidthSizable;
    urlLabel.autoresizingMask = NSViewWidthSizable;
    urlLabel.textColor = NSColor.secondaryLabelColor;
    [toolbar addSubview:titleLabel];
    [toolbar addSubview:urlLabel];

    [contentView addSubview:browserContainer];
    [contentView addSubview:toolbar];
    window.contentView = contentView;

    _browserViews[popupBrowserId] = browserContainer;
    [self recordPendingCreateMetadataForFlutterId:popupBrowserId
                                  createRequestId:[NSString stringWithFormat:@"managed_popup_%d", popupBrowserId]
                                        incognito:NO
                                           queued:NO];
    if (!_deterministicCreate) {
        _pendingFlutterBrowserIds.push_back(popupBrowserId);
    }
    _managedPopupFlutterBrowserIds.insert(popupBrowserId);
    _managedPopupWindowsByBrowserId[popupKey] = window;
    _managedPopupDelegatesByBrowserId[popupKey] = popupDelegate;
    _managedPopupTitleLabelsByBrowserId[popupKey] = titleLabel;
    _managedPopupUrlLabelsByBrowserId[popupKey] = urlLabel;

    [window makeKeyAndOrderFront:nil];
    [self emitLifecycleDiagnostic:@{
        @"type": @"cef_managed_popup_created",
        @"browserId": @(popupBrowserId),
        @"openerBrowserId": @(openerFlutterBrowserId),
        @"targetUrl": targetUrl,
        @"targetDispositionName": disposition,
        @"windowFrame": NSStringFromRect(windowFrame),
    }];

    return browserContainer;
}

- (int)managedPopupBrowserIdFromSender:(id)sender {
    if ([sender respondsToSelector:@selector(tag)]) {
        return (int)[sender tag];
    }
    return -1;
}

- (void)managedPopupGoBack:(id)sender {
    int browserId = [self managedPopupBrowserIdFromSender:sender];
    if (browserId == -1) return;
    [self goBack:browserId];
}

- (void)managedPopupGoForward:(id)sender {
    int browserId = [self managedPopupBrowserIdFromSender:sender];
    if (browserId == -1) return;
    [self goForward:browserId];
}

- (void)managedPopupReload:(id)sender {
    int browserId = [self managedPopupBrowserIdFromSender:sender];
    if (browserId == -1) return;
    [self reload:browserId ignoreCache:NO];
}

- (void)managedPopupCopyURL:(id)sender {
    int browserId = [self managedPopupBrowserIdFromSender:sender];
    if (browserId == -1) return;
    NSString* url = [self currentURLForBrowserId:browserId];
    if (url.length == 0) return;
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:url forType:NSPasteboardTypeString];
}

- (void)managedPopupOpenExternal:(id)sender {
    int browserId = [self managedPopupBrowserIdFromSender:sender];
    if (browserId == -1) return;
    NSString* urlString = [self currentURLForBrowserId:browserId];
    NSURL* url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)managedPopupClose:(id)sender {
    int browserId = [self managedPopupBrowserIdFromSender:sender];
    if (browserId == -1) return;
    NSWindow* window = _managedPopupWindowsByBrowserId[@(browserId)];
    [window orderOut:nil];
    [self closeBrowser:browserId];
}

- (void)resizeManagedPopupBrowser:(int)browserId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resizeManagedPopupBrowser:browserId];
        });
        return;
    }
    auto containerIt = _browserViews.find(browserId);
    if (containerIt == _browserViews.end() || !containerIt->second) return;
    NSView* container = containerIt->second;
    for (NSView* subview in container.subviews) {
        subview.frame = container.bounds;
        subview.translatesAutoresizingMaskIntoConstraints = YES;
        subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (browser && browser->GetHost()) {
        browser->GetHost()->WasResized();
    }
}

- (void)recordPendingCreateMetadataForFlutterId:(int)browserId
                                createRequestId:(nullable NSString *)createRequestId
                                      incognito:(BOOL)incognito
                                         queued:(BOOL)queued {
    NSMutableDictionary* metadata = [NSMutableDictionary dictionary];
    metadata[@"browserId"] = @(browserId);
    metadata[@"incognito"] = @(incognito);
    metadata[@"queued"] = @(queued);
    if (createRequestId.length > 0) {
        metadata[@"createRequestId"] = createRequestId;
    }
    _pendingCreateMetadataByFlutterId[@(browserId)] = [metadata copy];
}

- (nullable NSDictionary *)pendingCreateMetadataForFlutterId:(int)browserId {
    return _pendingCreateMetadataByFlutterId[@(browserId)];
}

- (void)clearPendingCreateMetadataForFlutterId:(int)browserId {
    [_pendingCreateMetadataByFlutterId removeObjectForKey:@(browserId)];
}

- (int)solePendingFlutterBrowserIdOrNegativeOne {
    if (_pendingCreateMetadataByFlutterId.count != 1) {
        return -1;
    }
    NSNumber* browserId = _pendingCreateMetadataByFlutterId.allKeys.firstObject;
    return browserId != nil ? browserId.intValue : -1;
}

- (void)setDelegate:(id<CEFBridgeDelegate>)delegate {
    _delegate = delegate;
    if (delegate) {
        [_delegates addObject:delegate];
    }
}

- (NSDictionary<NSString*, id>*)resolvedCommandLineSwitches {
    return _resolvedCommandLineSwitches ?: @{};
}

- (NSDictionary<NSString*, id>*)normalizedRuntimeConfigFromRawConfig:(NSDictionary<NSString*, id>*)rawConfig {
    NSDictionary<NSString*, id>* config = [rawConfig isKindOfClass:[NSDictionary class]]
        ? rawConfig
        : @{};
    const char* requireHelperEnv = getenv("CEF_REQUIRE_HELPER");
    const char* useMockKeychainEnv = getenv("CEF_USE_MOCK_KEYCHAIN");

    NSDictionary<NSString*, id>* profileSwitches = SanitizeSwitchMap(config[@"profileSwitches"]);
    NSDictionary<NSString*, id>* extraSwitches = SanitizeSwitchMap(config[@"extraSwitches"]);
    NSArray<NSString*>* removeSwitches = [[[SanitizeSwitchSet(config[@"removeSwitches"]) allObjects]
        sortedArrayUsingSelector:@selector(compare:)] copy];

    NSString* cachePath = StringValueOrNil(config[@"cachePath"]) ?: @"";
    NSString* rootCachePath = StringValueOrNil(config[@"rootCachePath"]) ?: @"";
    if (cachePath.length == 0) {
        cachePath = @"";
    }
    if (rootCachePath.length == 0 && cachePath.length > 0) {
        rootCachePath = cachePath;
    }

    return @{
        @"cachePath": cachePath,
        @"rootCachePath": rootCachePath ?: @"",
        @"userAgent": StringValueOrNil(config[@"userAgent"]) ?: [NSNull null],
        @"chromeRuntime": @(BoolValueOrDefault(config[@"chromeRuntime"], NO)),
        @"extensionPaths": StringArrayOrEmpty(config[@"extensionPaths"]),
        @"cefProfile": StringValueOrNil(config[@"cefProfile"]) ?: @"prod-safe",
        @"profileSwitches": profileSwitches,
        @"extraSwitches": extraSwitches,
        @"removeSwitches": removeSwitches,
        @"closePolicy": StringValueOrNil(config[@"closePolicy"]) ?: @"graceful_then_force",
        @"gracefulCloseTimeoutMs": @(MAX(1, IntegerValueOrDefault(config[@"gracefulCloseTimeoutMs"], 1200))),
        @"messagePumpMode": StringValueOrNil(config[@"messagePumpMode"]) ?: @"cef_sample_compatible",
        @"maxPumpDelayMs": @(MAX(1, IntegerValueOrDefault(config[@"maxPumpDelayMs"], 33))),
        @"enableMessagePumpFallbackTimer": @(BoolValueOrDefault(config[@"enableMessagePumpFallbackTimer"], YES)),
        @"enableWindowlessRendering": @(BoolValueOrDefault(config[@"enableWindowlessRendering"], NO)),
        @"deterministicCreate": @(BoolValueOrDefault(config[@"deterministicCreate"], YES)),
        @"deterministicCreateTimeoutMs": @(MAX(1, IntegerValueOrDefault(config[@"deterministicCreateTimeoutMs"], 5000))),
        @"requireHelper": @(BoolValueOrDefault(config[@"requireHelper"], !requireHelperEnv || strcmp(requireHelperEnv, "0") != 0)),
        @"useMockKeychain": @(BoolValueOrDefault(
            useMockKeychainEnv
                ? [NSString stringWithUTF8String:useMockKeychainEnv]
                : nil,
            BoolValueOrDefault(config[@"useMockKeychain"], NO))),
        @"remoteDebuggingPort": @(MAX(0, IntegerValueOrDefault(config[@"remoteDebuggingPort"], 0))),
        @"logFilePath": StringValueOrNil(config[@"logFilePath"]) ?: @"",
        @"crashDumpsPath": StringValueOrNil(config[@"crashDumpsPath"]) ?: @"",
        @"uncaughtExceptionStackSize": @(MAX(0, IntegerValueOrDefault(config[@"uncaughtExceptionStackSize"], 10))),
        @"launchMode": StringValueOrNil(config[@"launchMode"]) ?: @"unknown",
    };
}

- (NSDictionary<NSString*, id>*)newPreflightReportWithConfig:(NSDictionary<NSString*, id>*)config
                                                      source:(NSString*)source {
    return [@{
        @"status": @"ok",
        @"source": source ?: @"native",
        @"capturedAt": CurrentISO8601Timestamp(),
        @"config": config ?: @{},
        @"native": [NSMutableDictionary dictionary],
    } mutableCopy];
}

- (void)addIssue:(NSDictionary<NSString*, id>*)issue
      toWarnings:(NSMutableArray<NSDictionary*>*)warnings
        failures:(NSMutableArray<NSDictionary*>*)failures {
    NSString* severity = [issue[@"severity"] isKindOfClass:[NSString class]]
        ? (NSString*)issue[@"severity"]
        : kCefIssueSeverityWarning;
    if ([severity isEqualToString:kCefIssueSeverityFailure]) {
        [failures addObject:issue];
    } else {
        [warnings addObject:issue];
    }
}

- (NSDictionary<NSString*, id>*)finalizePreflightReport:(NSMutableDictionary<NSString*, id>*)report
                                                warnings:(NSMutableArray<NSDictionary*>*)warnings
                                                failures:(NSMutableArray<NSDictionary*>*)failures {
    report[@"warnings"] = [warnings copy];
    report[@"failures"] = [failures copy];
    report[@"status"] = failures.count > 0 ? @"failed" : @"ok";
    return [report copy];
}

- (NSDictionary<NSString*, id>*)runPreflightWithConfig:(NSDictionary<NSString*, id>*)config {
    NSDictionary<NSString*, id>* normalized = [self normalizedRuntimeConfigFromRawConfig:config];
    NSString* source = wasCEFInitializedByMain() ? @"initialized_by_main" : @"native";
    NSMutableDictionary<NSString*, id>* report = [[self newPreflightReportWithConfig:normalized source:source] mutableCopy];
    NSMutableArray<NSDictionary*>* warnings = [NSMutableArray array];
    NSMutableArray<NSDictionary*>* failures = [NSMutableArray array];
    NSMutableDictionary<NSString*, id>* native = [report[@"native"] isKindOfClass:[NSMutableDictionary class]]
        ? (NSMutableDictionary<NSString*, id>*)report[@"native"]
        : [NSMutableDictionary dictionary];
    report[@"native"] = native;

    if (![NSThread isMainThread]) {
        [self addIssue:CefPreflightIssue(@"main_thread_unavailable",
                                         kCefIssueSeverityFailure,
                                         @"CEF preflight must run on the main thread",
                                         @{})
             toWarnings:warnings
               failures:failures];
    }

    NSString* frameworkBinaryPath = CefFrameworkBinaryPath();
    NSString* frameworkResourcesPath = CefFrameworkResourcesPath();
    native[@"frameworkBinaryPath"] = frameworkBinaryPath ?: @"";
    native[@"frameworkResourcesPath"] = frameworkResourcesPath ?: @"";

    NSFileManager* fileManager = [NSFileManager defaultManager];
    if (frameworkBinaryPath.length == 0 ||
        ![fileManager fileExistsAtPath:frameworkBinaryPath]) {
        [self addIssue:CefPreflightIssue(@"framework_missing",
                                         kCefIssueSeverityFailure,
                                         @"Chromium Embedded Framework binary is missing from the app bundle",
                                         @{@"path": frameworkBinaryPath ?: @""})
             toWarnings:warnings
               failures:failures];
    }

    NSMutableArray<NSString*>* missingResources = [NSMutableArray array];
    NSArray<NSString*>* requiredResources = @[
        @"icudtl.dat",
        @"chrome_100_percent.pak",
        @"chrome_200_percent.pak",
        @"resources.pak",
    ];
    NSArray<NSString*>* optionalResources = @[
        @"snapshot_blob.bin",
        @"v8_context_snapshot.bin",
    ];
    if (frameworkResourcesPath.length == 0 ||
        ![fileManager fileExistsAtPath:frameworkResourcesPath isDirectory:nil]) {
        [self addIssue:CefPreflightIssue(@"resource_bundle_missing",
                                         kCefIssueSeverityFailure,
                                         @"CEF resource bundle is missing from the app bundle",
                                         @{@"path": frameworkResourcesPath ?: @""})
             toWarnings:warnings
               failures:failures];
    } else {
        for (NSString* resourceName in requiredResources) {
            NSString* resourcePath = [frameworkResourcesPath stringByAppendingPathComponent:resourceName];
            if (![fileManager fileExistsAtPath:resourcePath]) {
                [missingResources addObject:resourcePath];
            }
        }
        NSMutableArray<NSString*>* missingOptionalResources = [NSMutableArray array];
        for (NSString* resourceName in optionalResources) {
            NSString* resourcePath = [frameworkResourcesPath stringByAppendingPathComponent:resourceName];
            if (![fileManager fileExistsAtPath:resourcePath]) {
                [missingOptionalResources addObject:resourcePath];
            }
        }
        if (missingOptionalResources.count > 0) {
            native[@"missingOptionalResources"] = [missingOptionalResources copy];
            [self addIssue:CefPreflightIssue(@"resource_optional_missing",
                                             kCefIssueSeverityWarning,
                                             @"Some optional CEF resources are not packaged in this app bundle layout",
                                             @{@"paths": [missingOptionalResources copy]})
                 toWarnings:warnings
                   failures:failures];
        } else {
            native[@"missingOptionalResources"] = @[];
        }

        BOOL localesIsDirectory = NO;
        NSString* localesPath = [frameworkResourcesPath stringByAppendingPathComponent:@"locales"];
        BOOL hasLocalesDirectory =
            [fileManager fileExistsAtPath:localesPath isDirectory:&localesIsDirectory] &&
            localesIsDirectory;
        NSArray<NSString*>* localePakMatches = [fileManager contentsOfDirectoryAtPath:frameworkResourcesPath
                                                                                 error:nil];
        NSUInteger localeLprojCount = 0;
        for (NSString* resourceName in localePakMatches) {
            if (![resourceName hasSuffix:@".lproj"]) continue;
            NSString* localePakPath = [[frameworkResourcesPath
                stringByAppendingPathComponent:resourceName]
                stringByAppendingPathComponent:@"locale.pak"];
            if ([fileManager fileExistsAtPath:localePakPath]) {
                localeLprojCount += 1;
            }
        }
        native[@"localePackaging"] = hasLocalesDirectory
            ? @"locales_dir"
            : (localeLprojCount > 0 ? @"lproj" : @"missing");
        native[@"localeLprojCount"] = @(localeLprojCount);
        if (!hasLocalesDirectory && localeLprojCount == 0) {
            [missingResources addObject:localesPath];
        }
    }
    if (missingResources.count > 0) {
        native[@"missingResources"] = [missingResources copy];
        [self addIssue:CefPreflightIssue(@"resource_missing",
                                         kCefIssueSeverityFailure,
                                         @"Required CEF resources are missing from the app bundle",
                                         @{@"paths": [missingResources copy]})
             toWarnings:warnings
               failures:failures];
    } else {
        native[@"missingResources"] = @[];
    }

    NSDictionary<NSString*, id>* helperMetadata = ResolveHelperMetadata();
    native[@"helperPath"] = helperMetadata[@"helperPath"] ?: @"";
    native[@"helperBaseName"] = helperMetadata[@"helperBaseName"] ?: @"";
    native[@"missingHelperVariants"] = helperMetadata[@"missingHelperVariants"] ?: @[];
    native[@"frameworksPath"] = helperMetadata[@"frameworksPath"] ?: @"";
    BOOL requireHelper = BoolValueOrDefault(normalized[@"requireHelper"], YES);
    if ([helperMetadata[@"helperPath"] length] == 0) {
        [self addIssue:CefPreflightIssue(@"helper_missing_base",
                                         requireHelper ? kCefIssueSeverityFailure : kCefIssueSeverityWarning,
                                         @"CEF helper executable is missing from the app bundle",
                                         @{@"candidates": helperMetadata[@"helperCandidateBaseNames"] ?: @[]})
             toWarnings:warnings
               failures:failures];
    }
    NSArray<NSString*>* missingHelperVariants = helperMetadata[@"missingHelperVariants"];
    if (missingHelperVariants.count > 0) {
        [self addIssue:CefPreflightIssue(@"helper_missing_variants",
                                         requireHelper ? kCefIssueSeverityFailure : kCefIssueSeverityWarning,
                                         @"CEF helper variant executables are missing from the app bundle",
                                         @{@"paths": missingHelperVariants})
             toWarnings:warnings
               failures:failures];
    }

    NSString* cachePath = StringValueOrNil(normalized[@"cachePath"]) ?: @"";
    NSString* rootCachePath = StringValueOrNil(normalized[@"rootCachePath"]) ?: @"";
    native[@"cachePath"] = cachePath;
    native[@"rootCachePath"] = rootCachePath;
    if (cachePath.length == 0) {
        [self addIssue:CefPreflightIssue(@"cache_path_empty",
                                         kCefIssueSeverityFailure,
                                         @"CEF cachePath is empty",
                                         @{})
             toWarnings:warnings
               failures:failures];
    }
    if (rootCachePath.length == 0) {
        [self addIssue:CefPreflightIssue(@"root_cache_path_empty",
                                         kCefIssueSeverityFailure,
                                         @"CEF rootCachePath is empty",
                                         @{})
             toWarnings:warnings
               failures:failures];
    }
    if (cachePath.length > 0 && ![cachePath isAbsolutePath]) {
        [self addIssue:CefPreflightIssue(@"cache_path_not_absolute",
                                         kCefIssueSeverityFailure,
                                         @"CEF cachePath must be absolute",
                                         @{@"path": cachePath})
             toWarnings:warnings
               failures:failures];
    }
    if (rootCachePath.length > 0 && ![rootCachePath isAbsolutePath]) {
        [self addIssue:CefPreflightIssue(@"root_cache_path_not_absolute",
                                         kCefIssueSeverityFailure,
                                         @"CEF rootCachePath must be absolute",
                                         @{@"path": rootCachePath})
             toWarnings:warnings
               failures:failures];
    }
    NSString* logFilePath = StringValueOrNil(normalized[@"logFilePath"]) ?: @"";
    native[@"logFilePath"] = logFilePath;
    if (logFilePath.length > 0 && ![logFilePath isAbsolutePath]) {
        [self addIssue:CefPreflightIssue(@"log_file_path_not_absolute",
                                         kCefIssueSeverityFailure,
                                         @"CEF logFilePath must be absolute",
                                         @{@"path": logFilePath})
             toWarnings:warnings
               failures:failures];
    }
    NSString* crashDumpsPath = StringValueOrNil(normalized[@"crashDumpsPath"]) ?: @"";
    native[@"crashDumpsPath"] = crashDumpsPath;
    if (crashDumpsPath.length > 0 && ![crashDumpsPath isAbsolutePath]) {
        [self addIssue:CefPreflightIssue(@"crash_dumps_path_not_absolute",
                                         kCefIssueSeverityFailure,
                                         @"CEF crashDumpsPath must be absolute",
                                         @{@"path": crashDumpsPath})
             toWarnings:warnings
               failures:failures];
    }
    NSInteger remoteDebuggingPort = IntegerValueOrDefault(normalized[@"remoteDebuggingPort"], 0);
    native[@"remoteDebuggingPort"] = @(remoteDebuggingPort);
    if (remoteDebuggingPort < 0 || remoteDebuggingPort > 65535) {
        [self addIssue:CefPreflightIssue(@"remote_debugging_port_invalid",
                                         kCefIssueSeverityFailure,
                                         @"CEF remoteDebuggingPort must be 0 or a valid TCP port",
                                         @{@"port": @(remoteDebuggingPort)})
             toWarnings:warnings
               failures:failures];
    }
    if (cachePath.length > 0 &&
        rootCachePath.length > 0 &&
        !PathEqualsOrWithinRoot(rootCachePath, cachePath)) {
        [self addIssue:CefPreflightIssue(@"cache_path_outside_root",
                                         kCefIssueSeverityFailure,
                                         @"CEF cachePath must be equal to or nested under rootCachePath",
                                         @{@"cachePath": cachePath, @"rootCachePath": rootCachePath})
             toWarnings:warnings
               failures:failures];
    }

    BOOL isDirectory = NO;
    if (rootCachePath.length > 0 &&
        [fileManager fileExistsAtPath:rootCachePath isDirectory:&isDirectory] &&
        !isDirectory) {
        [self addIssue:CefPreflightIssue(@"root_cache_path_invalid",
                                         kCefIssueSeverityFailure,
                                         @"CEF rootCachePath exists but is not a directory",
                                         @{@"path": rootCachePath})
             toWarnings:warnings
               failures:failures];
    }
    if (cachePath.length > 0 &&
        [fileManager fileExistsAtPath:cachePath isDirectory:&isDirectory] &&
        !isDirectory) {
        [self addIssue:CefPreflightIssue(@"cache_path_invalid",
                                         kCefIssueSeverityFailure,
                                         @"CEF cachePath exists but is not a directory",
                                         @{@"path": cachePath})
             toWarnings:warnings
               failures:failures];
    }

    NSString* writableProbePath = rootCachePath.length > 0 ? rootCachePath : cachePath;
    NSString* existingAncestor = NearestExistingAncestorPath(writableProbePath);
    native[@"writableAncestorPath"] = existingAncestor ?: @"";
    if (existingAncestor.length == 0) {
        [self addIssue:CefPreflightIssue(@"cache_path_ancestor_missing",
                                         kCefIssueSeverityFailure,
                                         @"CEF cache path does not have an existing ancestor directory",
                                         @{@"path": writableProbePath ?: @""})
             toWarnings:warnings
               failures:failures];
    } else if (![fileManager isWritableFileAtPath:existingAncestor]) {
        [self addIssue:CefPreflightIssue(@"cache_path_not_writable",
                                         kCefIssueSeverityFailure,
                                         @"CEF cache path ancestor is not writable",
                                         @{@"path": existingAncestor})
             toWarnings:warnings
               failures:failures];
    }

    const char* envChromeRuntime = getenv("CEF_CHROME_RUNTIME");
    if (envChromeRuntime && envChromeRuntime[0] != '\0') {
        [self addIssue:CefPreflightIssue(@"env_override_ignored_chrome_runtime",
                                         kCefIssueSeverityWarning,
                                         @"CEF_CHROME_RUNTIME is ignored in favor of the canonical Dart runtime config",
                                         @{@"envValue": [NSString stringWithUTF8String:envChromeRuntime] ?: @""})
             toWarnings:warnings
               failures:failures];
    }
    const char* envExtensions = getenv("CEF_EXTENSIONS");
    if (envExtensions && envExtensions[0] != '\0') {
        [self addIssue:CefPreflightIssue(@"env_override_ignored_extensions",
                                         kCefIssueSeverityWarning,
                                         @"CEF_EXTENSIONS is ignored in favor of the canonical Dart runtime config",
                                         @{@"envValue": [NSString stringWithUTF8String:envExtensions] ?: @""})
             toWarnings:warnings
               failures:failures];
    }

    if (wasCEFInitializedByMain()) {
        [self addIssue:CefPreflightIssue(@"initialized_by_main",
                                         kCefIssueSeverityWarning,
                                         @"CEF was already initialized by the host app before plugin startup",
                                         @{})
             toWarnings:warnings
               failures:failures];
    }

    return [self finalizePreflightReport:report warnings:warnings failures:failures];
}

- (NSDictionary<NSString*, id>*)initializeWithConfig:(NSDictionary<NSString*, id>*)config {
    NSDictionary<NSString*, id>* normalized = [self normalizedRuntimeConfigFromRawConfig:config];
    NSDictionary<NSString*, id>* preflightReport = [self runPreflightWithConfig:normalized];
    NSArray* failures = [preflightReport[@"failures"] isKindOfClass:[NSArray class]]
        ? (NSArray*)preflightReport[@"failures"]
        : @[];
    if (failures.count > 0) {
        NSDictionary* firstFailure = [failures.firstObject isKindOfClass:[NSDictionary class]]
            ? (NSDictionary*)failures.firstObject
            : @{};
        NSString* failureCode = StringValueOrNil(firstFailure[@"code"]) ?: @"preflight_failed";
        [self recordInitializationFailureCode:failureCode stage:@"preflight"];
        return @{
            @"success": @NO,
            @"failureCode": failureCode,
            @"failureStage": @"preflight",
            @"message": StringValueOrNil(firstFailure[@"message"]) ?: @"CEF preflight failed",
            @"preflightReport": preflightReport,
        };
    }

    _requireHelper = BoolValueOrDefault(normalized[@"requireHelper"], YES);
    _useMockKeychain = BoolValueOrDefault(normalized[@"useMockKeychain"], NO);
    _remoteDebuggingPort = MAX(0, IntegerValueOrDefault(normalized[@"remoteDebuggingPort"], 0));
    _logFilePath = StringValueOrNil(normalized[@"logFilePath"]) ?: @"";
    _crashDumpsPath = StringValueOrNil(normalized[@"crashDumpsPath"]) ?: @"";
    _uncaughtExceptionStackSize = MAX(0, IntegerValueOrDefault(normalized[@"uncaughtExceptionStackSize"], 10));
    [self recordInitializationFailureCode:nil stage:nil];

    BOOL success = [self initializeWithCachePath:StringValueOrNil(normalized[@"cachePath"]) ?: @""
                                   rootCachePath:StringValueOrNil(normalized[@"rootCachePath"])
                                       userAgent:StringValueOrNil(normalized[@"userAgent"])
                                   chromeRuntime:BoolValueOrDefault(normalized[@"chromeRuntime"], NO)
                                  extensionPaths:StringArrayOrEmpty(normalized[@"extensionPaths"])
                                      cefProfile:StringValueOrNil(normalized[@"cefProfile"]) ?: @"prod-safe"
                                 profileSwitches:SanitizeSwitchMap(normalized[@"profileSwitches"])
                                   extraSwitches:SanitizeSwitchMap(normalized[@"extraSwitches"])
                                  removeSwitches:StringArrayOrEmpty(normalized[@"removeSwitches"])
                                     closePolicy:StringValueOrNil(normalized[@"closePolicy"]) ?: @"graceful_then_force"
                          gracefulCloseTimeoutMs:IntegerValueOrDefault(normalized[@"gracefulCloseTimeoutMs"], 1200)
                                 messagePumpMode:StringValueOrNil(normalized[@"messagePumpMode"]) ?: @"cef_sample_compatible"
                                  maxPumpDelayMs:IntegerValueOrDefault(normalized[@"maxPumpDelayMs"], 33)
                     enableMessagePumpFallbackTimer:BoolValueOrDefault(normalized[@"enableMessagePumpFallbackTimer"], YES)
                     enableWindowlessRendering:BoolValueOrDefault(normalized[@"enableWindowlessRendering"], NO)
                                 deterministicCreate:BoolValueOrDefault(normalized[@"deterministicCreate"], NO)];
    if (!success) {
        return @{
            @"success": @NO,
            @"failureCode": _lastInitializationFailureCode ?: @"initialize_failed",
            @"failureStage": _lastInitializationFailureStage ?: @"native_initialize",
            @"message": @"CEF initialization failed",
            @"preflightReport": preflightReport,
        };
    }

    return @{
        @"success": @YES,
        @"preflightReport": preflightReport,
        @"details": @{
            @"source": preflightReport[@"source"] ?: @"native",
        },
    };
}

- (void)recordInitializationFailureCode:(nullable NSString*)failureCode
                                  stage:(nullable NSString*)failureStage {
    _lastInitializationFailureCode = failureCode;
    _lastInitializationFailureStage = failureStage;
}

- (void)emitLifecycleDiagnostic:(NSDictionary<NSString*, id>*)diagnostic {
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onLifecycleDiagnostic:)]) {
            [delegate onLifecycleDiagnostic:diagnostic];
        }
    }
}

- (void)emitCreateMappingDiagnosticForFlutterBrowserId:(int)flutterBrowserId
                                          cefBrowserId:(int)cefBrowserId
                                         mappingSource:(NSString*)mappingSource
                                       createRequestId:(nullable NSString*)createRequestId {
    NSMutableDictionary<NSString*, id>* diagnostic = [@{
        @"type": @"cef_create_mapping_resolved",
        @"browserId": @(flutterBrowserId),
        @"cefBrowserId": @(cefBrowserId),
        @"mappingSource": mappingSource ?: @"unknown",
        @"deterministicCreate": @(_deterministicCreate),
    } mutableCopy];
    if (createRequestId.length > 0) {
        diagnostic[@"createRequestId"] = createRequestId;
    }
    [self emitLifecycleDiagnostic:diagnostic];
}

- (void)emitDeterministicCreateMappingFailureForCefBrowserId:(int)cefBrowserId
                                               browserView:(nullable NSView*)browserView {
    [self emitLifecycleDiagnostic:@{
        @"type": @"cef_deterministic_create_mapping_failed",
        @"cefBrowserId": @(cefBrowserId),
        @"deterministicCreate": @(_deterministicCreate),
        @"pendingCreateCount": @((NSInteger)_pendingCreateMetadataByFlutterId.count),
        @"pendingFifoCount": @((unsigned long)_pendingFlutterBrowserIds.size()),
        @"browserViewAvailable": @(browserView != nil),
    }];
}

- (void)emitMessagePumpStatsWithReason:(NSString*)reason {
    if (!_messagePump) return;
    NSMutableDictionary<NSString*, id>* diagnostic =
        [[_messagePump statsSnapshot] mutableCopy];
    diagnostic[@"type"] = @"cef_message_pump_stats";
    diagnostic[@"reason"] = reason ?: @"unspecified";
    diagnostic[@"pumpMode"] = MessagePumpModeName(_messagePumpMode);
    diagnostic[@"maxPumpDelayMs"] = @(_maxPumpDelayMs);
    diagnostic[@"fallbackTimerEnabled"] = @(_enableMessagePumpFallbackTimer);
    [self emitLifecycleDiagnostic:diagnostic];
    if (ShouldLogReliabilityDebug()) {
        NSLog(@"CEFBridge: message pump stats reason=%@ stats=%@",
              reason ?: @"unspecified",
              diagnostic);
    }
}

- (void)ensureMessagePump {
    if (_messagePump) return;
    _messagePump = [[CEFMessagePump alloc] initWithMode:_messagePumpMode
                                          maxPumpDelayMs:_maxPumpDelayMs
                                      enableFallbackTimer:_enableMessagePumpFallbackTimer];
}

- (void)invalidateCloseFallbackTimerForBrowserId:(int)browserId {
    NSNumber* key = @(browserId);
    NSTimer* timer = _closeFallbackTimers[key];
    if (timer) {
        [timer invalidate];
        [_closeFallbackTimers removeObjectForKey:key];
    }
}

- (void)scheduleCloseFallbackTimerForBrowserId:(int)browserId {
    [self invalidateCloseFallbackTimerForBrowserId:browserId];

    if (_forceImmediateClose) return;
    const NSTimeInterval timeout = ((NSTimeInterval)MAX(_gracefulCloseTimeoutMs, 1)) / 1000.0;
    if (timeout <= 0) return;

    __weak CEFBridge* weakSelf = self;
    NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                     repeats:NO
                                                       block:^(__unused NSTimer* _) {
        CEFBridge* strongSelf = weakSelf;
        if (!strongSelf) return;

        NSNumber* key = @(browserId);
        [strongSelf->_closeFallbackTimers removeObjectForKey:key];

        const int cefId = [strongSelf cefBrowserIdForFlutterId:browserId];
        if (!strongSelf->_client || cefId < 0) return;

        CefRefPtr<CefBrowser> browser = strongSelf->_client->GetBrowser(cefId);
        if (!browser || !browser->GetHost()) return;

        if (ShouldLogLifetimeDebug()) {
            NSLog(@"CEFBridge: close fallback timeout -> force close flutterId=%d cefId=%d", browserId, cefId);
        }
        browser->GetHost()->CloseBrowser(true);
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    _closeFallbackTimers[@(browserId)] = timer;
}

- (void)closeDockedDevToolsForBrowser:(int)browserId restoreBrowserFrame:(BOOL)restoreBrowserFrame {
    const int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> ownerBrowser =
        (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (CefNativeDevToolsEnabled() &&
        ownerBrowser &&
        ownerBrowser->GetHost() &&
        ownerBrowser->GetHost()->HasDevTools()) {
        ownerBrowser->GetHost()->CloseDevTools();
    }

    // Older builds created DevTools as a normal browser. Keep this cleanup for
    // stale state during hot restart or when closing an app upgraded in place.
    auto devBrowserIt = _devToolsBrowsers.find(browserId);
    if (devBrowserIt != _devToolsBrowsers.end() && devBrowserIt->second && devBrowserIt->second->GetHost()) {
        devBrowserIt->second->GetHost()->CloseBrowser(true);
    }
    _devToolsBrowsers.erase(browserId);

    auto panelIt = _devToolsPanels.find(browserId);
    auto dividerIt = _devToolsDividers.find(browserId);

    if (panelIt == _devToolsPanels.end() || !panelIt->second) {
        if (dividerIt != _devToolsDividers.end() && dividerIt->second) {
            [dividerIt->second removeFromSuperview];
            _devToolsDividers.erase(dividerIt);
        }
        _devToolsDockPosition.erase(browserId);
        _devToolsSizes.erase(browserId);
        return;
    }

    NSView* devToolsPanel = panelIt->second;
    ResizableDivider* divider = (dividerIt != _devToolsDividers.end()) ? dividerIt->second : nil;

    auto posIt = _devToolsDockPosition.find(browserId);
    NSString* dockPos = (posIt != _devToolsDockPosition.end()) ?
        [NSString stringWithUTF8String:posIt->second.c_str()] : @"bottom";

    // Restore browser container to full size when requested.
    if (restoreBrowserFrame) {
        auto browserIt = _browserViews.find(browserId);
        if (browserIt != _browserViews.end() && browserIt->second && devToolsPanel.superview) {
            NSView* browserContainer = browserIt->second;
            CGFloat dividerThickness = divider ? 8 : 0;

            NSRect fullFrame;
            if ([dockPos isEqualToString:@"bottom"]) {
                fullFrame = NSMakeRect(
                    browserContainer.frame.origin.x,
                    devToolsPanel.frame.origin.y,  // Start where DevTools was
                    browserContainer.frame.size.width,
                    browserContainer.frame.size.height + devToolsPanel.frame.size.height + dividerThickness
                );
            } else { // "right"
                fullFrame = NSMakeRect(
                    browserContainer.frame.origin.x,
                    browserContainer.frame.origin.y,
                    browserContainer.frame.size.width + devToolsPanel.frame.size.width + dividerThickness,
                    browserContainer.frame.size.height
                );
            }

            browserContainer.frame = fullFrame;

            CefRefPtr<CefBrowser> browser =
                ownerBrowser ? ownerBrowser : ((_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr);
            if (browser) {
                browser->GetHost()->WasResized();
            }
        }
    }

    [devToolsPanel removeFromSuperview];
    if (divider) {
        [divider removeFromSuperview];
    }

    _devToolsPanels.erase(panelIt);
    if (dividerIt != _devToolsDividers.end()) {
        _devToolsDividers.erase(dividerIt);
    }
    _devToolsDockPosition.erase(browserId);
    _devToolsSizes.erase(browserId);
}

- (BOOL)initializeWithCachePath:(NSString *)cachePath
                  rootCachePath:(NSString *)rootCachePath
                      userAgent:(NSString *)userAgent
                  chromeRuntime:(BOOL)chromeRuntime
                 extensionPaths:(NSArray<NSString *> *)extensionPaths
                     cefProfile:(NSString *)cefProfile
                profileSwitches:(NSDictionary<NSString *, id> *)profileSwitches
                  extraSwitches:(NSDictionary<NSString *, id> *)extraSwitches
                 removeSwitches:(NSArray<NSString *> *)removeSwitches
                    closePolicy:(NSString *)closePolicy
         gracefulCloseTimeoutMs:(NSInteger)gracefulCloseTimeoutMs
                messagePumpMode:(NSString *)messagePumpMode
                 maxPumpDelayMs:(NSInteger)maxPumpDelayMs
enableMessagePumpFallbackTimer:(BOOL)enableMessagePumpFallbackTimer {
    return [self initializeWithCachePath:cachePath
                           rootCachePath:rootCachePath
                               userAgent:userAgent
                           chromeRuntime:chromeRuntime
                          extensionPaths:extensionPaths
                              cefProfile:cefProfile
                         profileSwitches:profileSwitches
                           extraSwitches:extraSwitches
                          removeSwitches:removeSwitches
                             closePolicy:closePolicy
                  gracefulCloseTimeoutMs:gracefulCloseTimeoutMs
                         messagePumpMode:messagePumpMode
                          maxPumpDelayMs:maxPumpDelayMs
             enableMessagePumpFallbackTimer:enableMessagePumpFallbackTimer
             enableWindowlessRendering:NO
                         deterministicCreate:YES];
}

- (BOOL)initializeWithCachePath:(NSString *)cachePath
                  rootCachePath:(NSString *)rootCachePath
                      userAgent:(NSString *)userAgent
                  chromeRuntime:(BOOL)chromeRuntime
                 extensionPaths:(NSArray<NSString *> *)extensionPaths
                     cefProfile:(NSString *)cefProfile
                profileSwitches:(NSDictionary<NSString *, id> *)profileSwitches
                  extraSwitches:(NSDictionary<NSString *, id> *)extraSwitches
                 removeSwitches:(NSArray<NSString *> *)removeSwitches
                    closePolicy:(NSString *)closePolicy
         gracefulCloseTimeoutMs:(NSInteger)gracefulCloseTimeoutMs
                messagePumpMode:(NSString *)messagePumpMode
                 maxPumpDelayMs:(NSInteger)maxPumpDelayMs
enableMessagePumpFallbackTimer:(BOOL)enableMessagePumpFallbackTimer
      enableWindowlessRendering:(BOOL)enableWindowlessRendering
            deterministicCreate:(BOOL)deterministicCreate {
    if (_isInitialized) return YES;

    [self recordInitializationFailureCode:nil stage:nil];

    InjectCefAppProtocol();
    [_pendingBrowserCreations removeAllObjects];
    [_pendingCreateMetadataByFlutterId removeAllObjects];
    _pendingFlutterBrowserIds.clear();
    _pendingFlutterBrowserCloses.clear();
    _closingFlutterBrowserIds.clear();
    _deterministicCreate = deterministicCreate;

    // The CEF C++ wrapper uses per-binary global function pointers when
    // USING_CEF_SHARED=1. If the app initializes CEF in another binary
    // (e.g. custom main.mm), we must still call cef_load_library() from this
    // framework to populate our copy of those pointers.
    if (!EnsureCefLibraryLoadedForBridge()) {
        [self recordInitializationFailureCode:@"framework_load_failed" stage:@"load_library"];
        return NO;
    }

    _chromeRuntime = chromeRuntime;

    _extensionPaths.clear();
    if (extensionPaths && extensionPaths.count > 0) {
        for (NSString* p in extensionPaths) {
            if (!p || [p length] == 0) continue;
            _extensionPaths.push_back([p UTF8String]);
        }
    }

    // Resolve command-line profile and switch overrides.
    NSString* normalizedProfile = [[cefProfile ?: @"prod-safe" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalizedProfile.length == 0) {
        normalizedProfile = @"prod-safe";
    }

    NSMutableDictionary<NSString*, id>* resolvedSwitches = [NSMutableDictionary dictionary];
    NSDictionary<NSString*, id>* builtInProfile = BuiltInProfileSwitches(normalizedProfile);
    [resolvedSwitches addEntriesFromDictionary:builtInProfile];

    // Keep defaults that avoid popup/quit noise and keychain prompts.
    resolvedSwitches[@"disable-popup-blocking"] = [NSNull null];
    resolvedSwitches[@"disable-hang-monitor"] = [NSNull null];
    // FlutterMacOS and Chromium Embedded Framework both ship AXPlatformNodeCocoa.
    // In this embedding, we do not currently rely on CEF-managed accessibility,
    // so keep renderer accessibility disabled unless explicitly overridden.
    const char* allowAccessibility = getenv("CEF_ALLOW_ACCESSIBILITY");
    if (!allowAccessibility || strcmp(allowAccessibility, "0") == 0) {
        resolvedSwitches[@"disable-renderer-accessibility"] = [NSNull null];
        [resolvedSwitches removeObjectForKey:@"force-renderer-accessibility"];
    }
    if (_useMockKeychain) {
        resolvedSwitches[@"use-mock-keychain"] = [NSNull null];
    }
    if (_crashDumpsPath.length > 0) {
        resolvedSwitches[@"crash-dumps-dir"] = _crashDumpsPath;
    }

    NSDictionary<NSString*, id>* sanitizedProfileSwitches = SanitizeSwitchMap(profileSwitches);
    NSDictionary<NSString*, id>* sanitizedExtraSwitches = SanitizeSwitchMap(extraSwitches);
    NSSet<NSString*>* sanitizedRemoveSwitches = SanitizeSwitchSet(removeSwitches);

    [resolvedSwitches addEntriesFromDictionary:sanitizedProfileSwitches];
    [resolvedSwitches addEntriesFromDictionary:sanitizedExtraSwitches];
    for (NSString* key in sanitizedRemoveSwitches) {
        [resolvedSwitches removeObjectForKey:key];
    }
    _resolvedCommandLineSwitches = [resolvedSwitches copy];

    NSString* normalizedClosePolicy = [[closePolicy ?: @"graceful_then_force" lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _forceImmediateClose = [normalizedClosePolicy isEqualToString:@"force_immediate"];
    _gracefulCloseTimeoutMs = MAX(1, gracefulCloseTimeoutMs > 0 ? gracefulCloseTimeoutMs : 1200);

    _messagePumpMode = ParseMessagePumpMode(messagePumpMode);
    _maxPumpDelayMs = MAX(1, maxPumpDelayMs > 0 ? maxPumpDelayMs : 33);
    _enableMessagePumpFallbackTimer = enableMessagePumpFallbackTimer;
    _enableWindowlessRenderingSupport = enableWindowlessRendering;

    if (ShouldLogLifetimeDebug()) {
        NSLog(@"CEFBridge: init profile=%@ closePolicy=%@ gracefulTimeoutMs=%ld pumpMode=%@ maxPumpDelayMs=%ld fallbackTimer=%@ windowlessSupport=%@ switches=%@",
              normalizedProfile,
              _forceImmediateClose ? @"force_immediate" : @"graceful_then_force",
              (long)_gracefulCloseTimeoutMs,
              _messagePumpMode == CEFMessagePumpModeSimple ? @"simple" : @"cef_sample_compatible",
              (long)_maxPumpDelayMs,
              _enableMessagePumpFallbackTimer ? @"YES" : @"NO",
              _enableWindowlessRenderingSupport ? @"YES" : @"NO",
              _resolvedCommandLineSwitches);
    }

    // Check if CEF was already initialized by custom main.mm
    if (wasCEFInitializedByMain()) {
        NSLog(@"CEFBridge: CEF already initialized in main.mm, skipping re-initialization");

        // CEF library is already loaded, just create our client and context.
        // Use the global request context for the default profile. Newer CEF
        // versions model profile data beneath root_cache_path, and attempting
        // to create an additional persistent request context here has proven
        // fragile for this embedding.
        _client = new CEFClientImpl(self);
        if (![self bindDefaultRequestContext]) {
            _client = nullptr;
            return NO;
        }

        _contextInitialized = wasCEFContextInitializedByMain();
        if (!_contextInitialized) {
            [self startContextInitPollingIfNeeded];
        }

        [self ensureMessagePump];

        _isInitialized = YES;
        NSLog(@"CEFBridge: Using existing CEF context from main.mm");
        return YES;
    }

    // Normal initialization path - CEF not yet initialized
    // CEF library is already loaded above.

    _contextInitialized = NO;

    NSDictionary<NSString*, id>* profileRepair =
        RepairCrashProneCefProfileData(cachePath, rootCachePath);
    if ([profileRepair[@"didRepair"] boolValue]) {
        NSLog(@"CEFBridge: repaired crash-prone CEF profile data before CefInitialize: %@",
              profileRepair);
    } else if (![profileRepair[@"reason"] isEqualToString:@"sync_leveldb_missing"] &&
               ![profileRepair[@"reason"] isEqualToString:@"no_web_app_metadata"]) {
        NSLog(@"CEFBridge: CEF profile repair skipped before CefInitialize: %@",
              profileRepair);
    }

    CefMainArgs main_args(0, nullptr);
    _app = new BrowserApp();

    // Pre-warm macOS appearance system to avoid CEF conflicts (Fix 5)
    @autoreleasepool {
        NSAppearance *appearance = [NSApp effectiveAppearance];
        NSString *name = appearance.name;  // Force resolution
        (void)name;  // Suppress unused warning

        // Also pre-warm color system
        NSColor *color = [NSColor controlBackgroundColor];
        [color colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    }
    NSLog(@"CEFBridge: Pre-warmed macOS appearance system");

    CefSettings settings;
    settings.no_sandbox = true;
    settings.external_message_pump = true;  // Let Flutter control run loop (Fix 1)
    settings.multi_threaded_message_loop = false;
    settings.windowless_rendering_enabled = enableWindowlessRendering;
    // Note: chrome_runtime is only available in newer CEF. Guard for older headers.
#if defined(CEF_VERSION_MAJOR) && (CEF_VERSION_MAJOR >= 128)
    settings.chrome_runtime = _chromeRuntime;
#endif

    // Cache path for persistent storage.
    if (cachePath && cachePath.length > 0) {
        CefString(&settings.cache_path).FromASCII([cachePath UTF8String]);
    }
    if (rootCachePath && rootCachePath.length > 0) {
        CefString(&settings.root_cache_path).FromASCII([rootCachePath UTF8String]);
    } else if (cachePath && cachePath.length > 0) {
        // Backward-compatible default: keep root/cache aligned when an explicit
        // root is not provided.
        CefString(&settings.root_cache_path).FromASCII([cachePath UTF8String]);
    }

    // User agent
    if (userAgent) {
        CefString(&settings.user_agent).FromASCII([userAgent UTF8String]);
    }
    if (_remoteDebuggingPort > 0) {
        settings.remote_debugging_port = static_cast<int>(_remoteDebuggingPort);
    }
    if (_logFilePath.length > 0) {
        CefString(&settings.log_file).FromASCII([_logFilePath UTF8String]);
    }
    if (_uncaughtExceptionStackSize > 0) {
        settings.uncaught_exception_stack_size = static_cast<int>(_uncaughtExceptionStackSize);
    }
    settings.persist_session_cookies = true;

    NSDictionary<NSString*, id>* helperMetadata = ResolveHelperMetadata();
    NSString* resolvedHelperPath = helperMetadata[@"helperPath"];
    NSArray<NSString*>* missingHelperVariants = helperMetadata[@"missingHelperVariants"];

    if (resolvedHelperPath.length > 0 && missingHelperVariants.count == 0) {
        CefString(&settings.browser_subprocess_path).FromASCII([resolvedHelperPath UTF8String]);
        NSLog(@"CEFBridge: Using helper at %@", resolvedHelperPath);
    } else {
        if (resolvedHelperPath.length == 0) {
            NSLog(@"CEFBridge: Helper not found. Checked names: %@", helperMetadata[@"helperCandidateBaseNames"]);
        } else {
            NSLog(@"CEFBridge: Helper variants missing for base '%@': %@",
                  helperMetadata[@"helperBaseName"],
                  missingHelperVariants);
        }
        NSLog(@"CEFBridge: Frameworks path: %@", helperMetadata[@"frameworksPath"]);
        if (_requireHelper) {
            NSLog(@"CEFBridge: Initialization aborted because required helper executables are missing.");
            [self recordInitializationFailureCode:(resolvedHelperPath.length == 0 ? @"helper_missing_base" : @"helper_missing_variants")
                                            stage:@"helper_validation"];
            return NO;
        }
        NSLog(@"CEFBridge: Continuing without helper because requireHelper=NO");
    }

    // Log settings
    settings.log_severity = LOGSEVERITY_WARNING;

    // Detailed logging for debugging
    NSLog(@"CEFBridge: About to call CefInitialize");
    NSLog(@"CEFBridge: Main thread: %@", [NSThread isMainThread] ? @"YES" : @"NO");
    NSLog(@"CEFBridge: NSApp: %@", NSApp);
    NSLog(@"CEFBridge: NSApp.mainWindow: %@", NSApp.mainWindow);
    NSLog(@"CEFBridge: Settings - windowless_rendering_enabled: %d", settings.windowless_rendering_enabled);
    NSLog(@"CEFBridge: Settings - external_message_pump: %d", settings.external_message_pump);
    NSLog(@"CEFBridge: Settings - no_sandbox: %d", settings.no_sandbox);
    if (ShouldLogLifetimeDebug()) {
        NSLog(@"CEFBridge: Settings - cache_path: %s", CefString(&settings.cache_path).ToString().c_str());
        NSLog(@"CEFBridge: Settings - root_cache_path: %s", CefString(&settings.root_cache_path).ToString().c_str());
        NSLog(@"CEFBridge: Runtime - closePolicy=%@ gracefulTimeoutMs=%ld pumpMode=%@ maxPumpDelayMs=%ld fallbackTimer=%@ windowlessSupport=%@",
              _forceImmediateClose ? @"force_immediate" : @"graceful_then_force",
              (long)_gracefulCloseTimeoutMs,
              _messagePumpMode == CEFMessagePumpModeSimple ? @"simple" : @"cef_sample_compatible",
              (long)_maxPumpDelayMs,
              _enableMessagePumpFallbackTimer ? @"YES" : @"NO",
              _enableWindowlessRenderingSupport ? @"YES" : @"NO");
    }

    [self ensureMessagePump];
    _isInitializing = YES;
    const BOOL cefInitialized = CefInitialize(main_args, settings, _app.get(), nullptr);
    _isInitializing = NO;
    if (!cefInitialized) {
        NSLog(@"CEFBridge: Failed to initialize CEF");
        if (_messagePump) {
            [_messagePump shutdown];
            _messagePump = nil;
        }
        [self recordInitializationFailureCode:@"cef_initialize_failed" stage:@"cef_initialize"];
        return NO;
    }
    NSLog(@"CEFBridge: CefInitialize succeeded!");

    // Create client
    _client = new CEFClientImpl(self);

    // Use the global request context for the default profile. Persistent
    // session cookies are enabled above on CefSettings.
    if (![self bindDefaultRequestContext]) {
        CefShutdown();
        if (_messagePump) {
            [_messagePump shutdown];
            _messagePump = nil;
        }
        _client = nullptr;
        _requestContext = nullptr;
        _app = nullptr;
        return NO;
    }

    _isInitialized = YES;
    [self recordInitializationFailureCode:nil stage:nil];
    NSLog(@"CEFBridge: CEF initialized successfully");

    return YES;
}

- (void)shutdown {
    if (!_isInitialized) return;

    [self cancelAllPendingContextMenus];

    // Close all browsers
    std::vector<int> browserIds;
    browserIds.reserve(_browserViews.size());
    for (const auto& pair : _browserViews) {
        browserIds.push_back(pair.first);
    }
    for (int browserId : browserIds) {
        [self closeBrowser:browserId];
    }
    [self cleanupAllManagedPopupWindows];
    for (NSNumber* browserId in [_closeFallbackTimers allKeys]) {
        [self invalidateCloseFallbackTimerForBrowserId:browserId.intValue];
    }

    // Flush cookies to disk before tearing down the request contexts so that
    // session cookies survive across app restarts.
    if (_requestContext) {
        CefRefPtr<CefCookieManager> cookieManager =
            _requestContext->GetCookieManager(nullptr);
        if (cookieManager) {
            cookieManager->FlushStore(nullptr);
            NSLog(@"CEFBridge: Flushed cookie store to disk");
        }
    }

    _devToolsTargetIdByFlutterBrowserId.clear();
    _devToolsObserverRegsByCefId.clear();
    _devToolsObserversByCefId.clear();
    [_pendingResponseBodyCallbacks removeAllObjects];
    [_pendingEvaluateJavaScriptCallbacks removeAllObjects];
    [_pendingTextInputCallbacks removeAllObjects];
    [_pendingScreenshotCallbacks removeAllObjects];
    [_pendingBrowserCreations removeAllObjects];
    [_pendingCreateMetadataByFlutterId removeAllObjects];
    _pendingFlutterBrowserIds.clear();
    _pendingFlutterBrowserCloses.clear();
    _closingFlutterBrowserIds.clear();
    [_closeStartedAtByBrowserId removeAllObjects];
    _resolvedCommandLineSwitches = @{};
    [self recordInitializationFailureCode:nil stage:nil];

    _client = nullptr;
    _requestContext = nullptr;
    _incognitoRequestContext = nullptr;
    _app = nullptr;
    _incognitoFlutterBrowserIds.clear();

    if (_contextInitPollTimer) {
        [_contextInitPollTimer invalidate];
        _contextInitPollTimer = nil;
    }

    if (_messagePump) {
        [self emitMessagePumpStatsWithReason:@"shutdown"];
        [_messagePump shutdown];
        _messagePump = nil;
    }

    CefShutdown();
    _isInitialized = NO;
    _contextInitialized = NO;

    NSLog(@"CEFBridge: CEF shutdown complete");
}

- (void)closeAllBrowsersImmediately {
    NSLog(@"CEFBridge: Closing all browsers immediately for app quit");

    // Best-effort cookie flush before force-closing browsers.
    if (_requestContext) {
        CefRefPtr<CefCookieManager> cookieManager =
            _requestContext->GetCookieManager(nullptr);
        if (cookieManager) {
            cookieManager->FlushStore(nullptr);
        }
    }

    for (NSNumber* browserId in [_closeFallbackTimers allKeys]) {
        [self invalidateCloseFallbackTimerForBrowserId:browserId.intValue];
    }
    if (!_client) {
        [self cleanupAllManagedPopupWindows];
        return;
    }

    // Force close all browsers without confirmation
    std::vector<int> cefBrowserIds;
    for (const auto& pair : _flutterToCefBrowserId) {
        cefBrowserIds.push_back(pair.second);  // Get CEF IDs
    }

    for (int cefId : cefBrowserIds) {
        CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
        if (browser) {
            // Force close immediately - don't wait for unload handlers
            browser->GetHost()->CloseBrowser(true);  // true = force close
        }
    }
    [self cleanupAllManagedPopupWindows];

    _closingFlutterBrowserIds.clear();

    NSLog(@"CEFBridge: Closed %zu browsers", cefBrowserIds.size());
}

- (void)handleContextInitialized {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleContextInitialized];
        });
        return;
    }

    _contextInitialized = YES;
    NSLog(@"CEFBridge: CEF context initialized - ready for browser creation");

    if (_pendingBrowserCreations.count == 0) {
        return;
    }

    NSArray<NSDictionary*>* pending = [_pendingBrowserCreations copy];
    [_pendingBrowserCreations removeAllObjects];

    for (NSDictionary* req in pending) {
        NSNumber* browserIdNum = req[@"id"];
        NSString* url = req[@"url"];
        NSNumber* incognitoNum = req[@"incognito"];
        NSView* parentView = req[@"parentView"];
        NSValue* frameValue = req[@"frame"];
        NSString* createRequestId = req[@"createRequestId"];
        NSString* renderBackend = req[@"renderBackend"];
        NSNumber* deviceScaleFactorNum = req[@"deviceScaleFactor"];

        if (!browserIdNum || !parentView || !frameValue) {
            continue;
        }

        [self createBrowserWithId:browserIdNum.intValue
                              url:url ?: @""
                       incognito:incognitoNum.boolValue
                       parentView:parentView
		                            frame:frameValue.rectValue
		                  createRequestId:createRequestId
		                    renderBackend:renderBackend ?: @"nativeView"
		                deviceScaleFactor:deviceScaleFactorNum.doubleValue];
    }
}

- (void)handleScheduleMessagePumpWork:(int64_t)delayMs {
    if (!_isInitialized && !_isInitializing) return;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleScheduleMessagePumpWork:delayMs];
        });
        return;
    }

    [self ensureMessagePump];
    [_messagePump scheduleWork:delayMs];
}

- (void)startContextInitPollingIfNeeded {
    if (_contextInitPollTimer || _contextInitialized) return;

    _contextInitPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                             target:self
                                                           selector:@selector(pollContextInitializedByMain)
                                                           userInfo:nil
                                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_contextInitPollTimer forMode:NSRunLoopCommonModes];
}

- (void)pollContextInitializedByMain {
    if (_contextInitialized) {
        [_contextInitPollTimer invalidate];
        _contextInitPollTimer = nil;
        return;
    }

    if (wasCEFContextInitializedByMain()) {
        [_contextInitPollTimer invalidate];
        _contextInitPollTimer = nil;
        [self handleContextInitialized];
    }
}

- (BOOL)createBrowserWithId:(int)browserId
                        url:(NSString *)url
                 incognito:(BOOL)incognito
                 parentView:(NSView *)parentView
                      frame:(NSRect)frame {
    return [self createBrowserWithId:browserId
                                 url:url
                          incognito:incognito
		                          parentView:parentView
		                               frame:frame
		                     createRequestId:nil
		                       renderBackend:@"nativeView"
		                   deviceScaleFactor:0.0];
}

- (BOOL)createBrowserWithId:(int)browserId
                        url:(NSString *)url
                 incognito:(BOOL)incognito
		                 parentView:(NSView *)parentView
		                      frame:(NSRect)frame
		            createRequestId:(nullable NSString *)createRequestId
		              renderBackend:(nullable NSString *)renderBackend {
    return [self createBrowserWithId:browserId
                                 url:url
                          incognito:incognito
                          parentView:parentView
                               frame:frame
                     createRequestId:createRequestId
                       renderBackend:renderBackend
                   deviceScaleFactor:0.0];
}

- (BOOL)createBrowserWithId:(int)browserId
                        url:(NSString *)url
                 incognito:(BOOL)incognito
                 parentView:(NSView *)parentView
                      frame:(NSRect)frame
            createRequestId:(nullable NSString *)createRequestId
              renderBackend:(nullable NSString *)renderBackend
          deviceScaleFactor:(CGFloat)deviceScaleFactor {
    if (!_isInitialized) return NO;
    NSString* requestedBackend = NormalizeRenderBackendName(renderBackend);
    const BOOL useAcceleratedOsr =
        [requestedBackend isEqualToString:@"acceleratedOsrTexture"];
    const BOOL useOsrTexture = useAcceleratedOsr ||
        [requestedBackend isEqualToString:@"osrTexture"];

    NSLog(@"CEFBridge: createBrowserWithId - flutterBrowserId: %d, requestId: %@, backend: %@, url: %@",
          browserId,
          createRequestId ?: @"<none>",
          requestedBackend,
          url);

    // Ensure UI thread.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self createBrowserWithId:browserId
                                  url:url
                           incognito:incognito
                           parentView:parentView
                                frame:frame
                      createRequestId:createRequestId
                        renderBackend:requestedBackend
                    deviceScaleFactor:deviceScaleFactor];
        });
        return YES;
    }

    if (!_contextInitialized) {
        [self recordPendingCreateMetadataForFlutterId:browserId
                                      createRequestId:createRequestId
                                            incognito:incognito
                                               queued:YES];
        [_pendingBrowserCreations addObject:@{
            @"id": @(browserId),
            @"url": url ?: @"",
            @"incognito": @(incognito),
            @"parentView": parentView,
            @"frame": [NSValue valueWithRect:frame],
            @"createRequestId": createRequestId ?: @"",
            @"renderBackend": requestedBackend,
            @"deviceScaleFactor": @(deviceScaleFactor),
        }];
        NSLog(@"CEFBridge: Browser creation queued - waiting for context initialization");
        return YES;
    }

    if (frame.size.width <= 0 || frame.size.height <= 0) {
        NSLog(@"CEFBridge: ERROR - parent view has zero size (%.0f x %.0f)", frame.size.width, frame.size.height);
        [self clearPendingCreateMetadataForFlutterId:browserId];
        return NO;
    }

    if (!useOsrTexture && !parentView.window) {
        NSLog(@"CEFBridge: ERROR - parent view is not in a window hierarchy");
        [self clearPendingCreateMetadataForFlutterId:browserId];
        return NO;
    }

    // Ensure layer-backed compositing is enabled before browser creation.
    [[[parentView window] contentView] setWantsLayer:YES];
    parentView.wantsLayer = YES;

    [self ensureMessagePump];

    // Configure window info for native window mode or experimental windowless mode.
    CefWindowInfo windowInfo;
    if (useOsrTexture) {
        if (!_enableWindowlessRenderingSupport) {
            NSLog(@"CEFBridge: ERROR - osrTexture backend requested before windowless rendering was enabled");
            [self clearPendingCreateMetadataForFlutterId:browserId];
            return NO;
        }
        const CGFloat osrScale = EffectiveDeviceScaleFactor(deviceScaleFactor, parentView);
        _client->QueuePendingOsrViewSize((int)ceil(MAX(1.0, frame.size.width)),
                                         (int)ceil(MAX(1.0, frame.size.height)),
                                         (float)osrScale);
        // Use no native parent for OSR. CEF's macOS windowless path supports a
        // nil parent and the older texture-only implementation in this repo did
        // the same; passing a transparent Flutter NSView here can cause the
        // windowless browser to close as soon as it is created.
        windowInfo.SetAsWindowless(nullptr);
        windowInfo.shared_texture_enabled = useAcceleratedOsr;
        _osrFlutterBrowserIds.insert(browserId);
        _osrDeviceScaleFactors[browserId] = osrScale;
    } else {
        windowInfo.SetAsChild((__bridge void*)parentView,
                              CefRect(0, 0, frame.size.width, frame.size.height));
        _osrFlutterBrowserIds.erase(browserId);
        _osrDeviceScaleFactors.erase(browserId);
        _osrTargetFrameRates.erase(browserId);
        _osrHiddenBrowserIds.erase(browserId);
        _osrBackgroundActivityExemptBrowserIds.erase(browserId);
        _osrFrameLeaseConfiguredBrowserIds.erase(browserId);
        _osrFrameLeaseEnabledBrowserIds.erase(browserId);
        _osrParkedBrowserIds.erase(browserId);
        _osrPendingParkGenerations.erase(browserId);
    }

    CefBrowserSettings browserSettings;
    if (useOsrTexture) {
        // Initial pacing; kept in sync with the hosting display afterwards via
        // setFramePacing -> SetWindowlessFrameRate (CEF 147 has no 60 fps cap).
        auto pacingIt = _osrTargetFrameRates.find(browserId);
        browserSettings.windowless_frame_rate =
            pacingIt != _osrTargetFrameRates.end() ? pacingIt->second : 60;
        if (ShouldLogFpsDebug()) {
            NSLog(@"CEFFps: CreateBrowser browserId=%d initialFps=%d",
                  browserId, browserSettings.windowless_frame_rate);
        }
    }
    // Use a dark background to avoid white flash before CEF renders its first
    // frame.  Most IDE/dark-theme apps will benefit from this.
    browserSettings.background_color = CefColorSetARGB(255, 30, 30, 30);

    CefString cefUrl([url UTF8String]);

    CefRefPtr<CefRequestContext> requestContext = incognito
        ? [self sharedIncognitoRequestContext]
        : _requestContext;
    if (!requestContext) {
        NSLog(@"CEFBridge: ERROR - No request context available for browserId=%d incognito=%@",
              browserId,
              incognito ? @"YES" : @"NO");
        [self clearPendingCreateMetadataForFlutterId:browserId];
        return NO;
    }

    // Store container view reference and pending creation order (for async mapping).
    _browserViews[browserId] = parentView;
    [self recordPendingCreateMetadataForFlutterId:browserId
                                  createRequestId:createRequestId
                                        incognito:incognito
                                           queued:NO];
    if (!_deterministicCreate) {
        _pendingFlutterBrowserIds.push_back(browserId);
    }
    if (incognito) {
        _incognitoFlutterBrowserIds.insert(browserId);
    } else {
        _incognitoFlutterBrowserIds.erase(browserId);
    }

    NSLog(@"CEFBridge: Calling async CreateBrowser backend=%@...", requestedBackend);
    const bool success = CefBrowserHost::CreateBrowser(
        windowInfo,
        _client,
        cefUrl,
        browserSettings,
        nullptr,  // extra_info
        requestContext
    );

    if (!success) {
        NSLog(@"CEFBridge: CreateBrowser FAILED - returned false");
        if (useOsrTexture) {
            _client->DiscardPendingOsrViewSize();
        }
        _browserViews.erase(browserId);
        if (!_deterministicCreate &&
            !_pendingFlutterBrowserIds.empty() &&
            _pendingFlutterBrowserIds.back() == browserId) {
            _pendingFlutterBrowserIds.pop_back();
        }
        [self clearPendingCreateMetadataForFlutterId:browserId];
        _incognitoFlutterBrowserIds.erase(browserId);
        _osrFlutterBrowserIds.erase(browserId);
        _osrDeviceScaleFactors.erase(browserId);
        _osrTargetFrameRates.erase(browserId);
        _osrHiddenBrowserIds.erase(browserId);
        _osrBackgroundActivityExemptBrowserIds.erase(browserId);
        _osrFrameLeaseConfiguredBrowserIds.erase(browserId);
        _osrFrameLeaseEnabledBrowserIds.erase(browserId);
        _osrParkedBrowserIds.erase(browserId);
        _osrPendingParkGenerations.erase(browserId);
        [self maybeReleaseIncognitoRequestContext];
    } else {
        NSLog(@"CEFBridge: Browser creation initiated successfully");
    }

    return success;
}

- (BOOL)isBrowserReadyToBeClosed:(int)browserId {
    if (!_client) return YES;

    if (![NSThread isMainThread]) {
        __block BOOL ready = YES;
        dispatch_sync(dispatch_get_main_queue(), ^{
            ready = [self isBrowserReadyToBeClosed:browserId];
        });
        return ready;
    }

    // If close was requested before a mapping existed, keep the host window alive.
    if (_pendingFlutterBrowserCloses.find(browserId) != _pendingFlutterBrowserCloses.end()) {
        const int maybeCefId = [self cefBrowserIdForFlutterId:browserId];
        if (maybeCefId < 0) {
            return NO;
        }
    }

    const int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = (cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (!browser || !browser->GetHost()) return YES;
    return browser->GetHost()->IsReadyToBeClosed();
}

- (void)closeBrowser:(int)browserId {
    [self closeBrowser:browserId force:NO];
}

- (void)closeBrowser:(int)browserId force:(BOOL)force {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self closeBrowser:browserId force:force];
        });
        return;
    }

    [self cancelPendingContextMenusForBrowserId:browserId];

    // A page browser never outlives its docked DevTools binding.
    [self closeWindowlessDevToolsForBrowserId:browserId];

    const BOOL isManagedPopup = [self isManagedPopupBrowserId:browserId];
    if (isManagedPopup) {
        [self orderOutManagedPopupWindowForBrowserId:browserId];
    }

    _closingFlutterBrowserIds.insert(browserId);
    _closeStartedAtByBrowserId[@(browserId)] = [NSDate date];

    // Close docked DevTools first to avoid leaving a stray DevTools renderer behind.
    [self closeDockedDevToolsForBrowser:browserId restoreBrowserFrame:NO];
    _devToolsTargetIdByFlutterBrowserId.erase(browserId);

    if (!_client) {
        [self invalidateCloseFallbackTimerForBrowserId:browserId];
        [_closeStartedAtByBrowserId removeObjectForKey:@(browserId)];
        _closingFlutterBrowserIds.erase(browserId);
        return;
    }

    // Best-effort: if this browser was queued for creation (context not ready yet),
    // drop the pending request so we don't create a renderer for a window that's
    // already closing.
    if (_pendingBrowserCreations.count > 0) {
        NSIndexSet* indexes = [_pendingBrowserCreations indexesOfObjectsPassingTest:^BOOL(NSDictionary* obj, __unused NSUInteger idx, __unused BOOL* stop) {
            NSNumber* browserIdNum = obj[@"id"];
            return browserIdNum && browserIdNum.intValue == browserId;
        }];
        if (indexes.count > 0) {
            [_pendingBrowserCreations removeObjectsAtIndexes:indexes];
            auto staleViewIt = _browserViews.find(browserId);
            if (staleViewIt != _browserViews.end() && staleViewIt->second) {
                [staleViewIt->second removeFromSuperview];
            }
            _browserViews.erase(browserId);
            auto pendingIdIt = std::find(_pendingFlutterBrowserIds.begin(),
                                         _pendingFlutterBrowserIds.end(),
                                         browserId);
            if (pendingIdIt != _pendingFlutterBrowserIds.end()) {
                _pendingFlutterBrowserIds.erase(pendingIdIt);
            }
            if (ShouldLogLifetimeDebug()) {
                NSLog(@"CEFBridge: closeBrowser removed %lu pending creation(s) for flutterId=%d",
                      (unsigned long)indexes.count,
                      browserId);
            }
            [self clearPendingCreateMetadataForFlutterId:browserId];
            _incognitoFlutterBrowserIds.erase(browserId);
            _osrFlutterBrowserIds.erase(browserId);
            _osrDeviceScaleFactors.erase(browserId);
            _osrTargetFrameRates.erase(browserId);
            _osrHiddenBrowserIds.erase(browserId);
            _osrBackgroundActivityExemptBrowserIds.erase(browserId);
            _osrFrameLeaseConfiguredBrowserIds.erase(browserId);
            _osrFrameLeaseEnabledBrowserIds.erase(browserId);
            _osrParkedBrowserIds.erase(browserId);
            _osrPendingParkGenerations.erase(browserId);
            [self maybeReleaseIncognitoRequestContext];
            [self invalidateCloseFallbackTimerForBrowserId:browserId];
            [_closeStartedAtByBrowserId removeObjectForKey:@(browserId)];
            if (isManagedPopup) {
                [self cleanupManagedPopupForBrowserId:browserId closeWindow:YES];
            }
            if (_pendingFlutterBrowserCloses.erase(browserId) > 0) {
                [self emitLifecycleDiagnostic:@{
                    @"type": @"cef_pending_close_without_mapping_resolved",
                    @"browserId": @(browserId),
                    @"reason": @"pending_create_removed",
                }];
            }
            _closingFlutterBrowserIds.erase(browserId);
            return;
        }
    }

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    if (cefId >= 0) {
        [self cancelPendingResponseBodyForCefBrowserId:cefId];
    }
    CefRefPtr<CefBrowser> browser = (cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (ShouldLogLifetimeDebug()) {
        const bool onUi = CefCurrentlyOn(TID_UI);
        const bool hasHost = browser && browser->GetHost();
        NSLog(@"CEFBridge: closeBrowser flutterId=%d cefId=%d browser=%s",
              browserId,
              cefId,
              browser ? "valid" : "NULL");
        NSLog(@"CEFBridge: closeBrowser thread onUI=%s host=%s isClosing=%s",
              onUi ? "YES" : "NO",
              hasHost ? "YES" : "NO",
              "(n/a)");
    }
    CefRefPtr<CefBrowserHost> host = browser ? browser->GetHost() : nullptr;
    if (browser && host) {
        // Do not message the NSView returned from CefBrowserHost::GetWindowHandle
        // during close. Crash reports showed that handle can already be a
        // Chromium zombie object while the CefBrowser/CefBrowserHost wrapper is
        // still non-null. CEF owns the native browser view teardown; the bridge
        // only removes its Flutter-side container below.

        auto containerIt = _browserViews.find(browserId);
        if (containerIt != _browserViews.end() && containerIt->second) {
            NSView* containerView = containerIt->second;
            [containerView setHidden:YES];
            NSArray<NSView*>* subviews = [containerView.subviews copy];
            for (NSView* subview in subviews) {
                [subview removeFromSuperviewWithoutNeedingDisplay];
            }
            if (containerView.superview) {
                [containerView removeFromSuperviewWithoutNeedingDisplay];
            }
            _browserViews.erase(containerIt);
        }

        if (_pendingFlutterBrowserCloses.erase(browserId) > 0) {
            [self emitLifecycleDiagnostic:@{
                @"type": @"cef_pending_close_without_mapping_resolved",
                @"browserId": @(browserId),
                @"reason": @"browser_resolved",
            }];
        }
        if (force || _forceImmediateClose) {
            [self invalidateCloseFallbackTimerForBrowserId:browserId];
            host->CloseBrowser(true);
        } else {
            host->CloseBrowser(false);
            [self scheduleCloseFallbackTimerForBrowserId:browserId];
        }
    } else {
        if (isManagedPopup && cefId < 0) {
            _pendingFlutterBrowserCloses.insert(browserId);
            [self emitLifecycleDiagnostic:@{
                @"type": @"cef_pending_close_without_mapping",
                @"browserId": @(browserId),
                @"reason": @"managed_popup_close_requested_before_mapping",
            }];
            return;
        }

        auto containerIt = _browserViews.find(browserId);
        if (containerIt != _browserViews.end() && containerIt->second) {
            [containerIt->second setHidden:YES];
            if (containerIt->second.superview) {
                [containerIt->second removeFromSuperviewWithoutNeedingDisplay];
            }
            _browserViews.erase(containerIt);
        }
        [self invalidateCloseFallbackTimerForBrowserId:browserId];
        if (ShouldLogLifetimeDebug()) {
            NSLog(@"CEFBridge: closeBrowser unable to resolve browser for flutterId=%d (cefId=%d)", browserId, cefId);
        }
        [self clearPendingCreateMetadataForFlutterId:browserId];
        [_closeStartedAtByBrowserId removeObjectForKey:@(browserId)];
        _closingFlutterBrowserIds.erase(browserId);
        _pendingFlutterBrowserCloses.insert(browserId);
        [self emitLifecycleDiagnostic:@{
            @"type": @"cef_pending_close_without_mapping",
            @"browserId": @(browserId),
            @"reason": @"close_requested_before_mapping",
        }];
    }
}

- (void)closeBrowsersInWindow:(NSWindow *)window reason:(nullable NSString *)reason {
    if (!window) return;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self closeBrowsersInWindow:window reason:reason];
        });
        return;
    }

    std::vector<int> browserIds;
    for (const auto& pair : _browserViews) {
        const int browserId = pair.first;
        NSView* containerView = pair.second;
        if (!containerView) continue;
        if (containerView.window == window) {
            browserIds.push_back(browserId);
        }
    }

    if (browserIds.empty()) return;

    if (ShouldLogLifetimeDebug()) {
        NSMutableArray<NSNumber*>* ids = [NSMutableArray arrayWithCapacity:browserIds.size()];
        for (int browserId : browserIds) {
            [ids addObject:@(browserId)];
        }
        NSLog(@"CEFBridge: closeBrowsersInWindow reason=%@ window=%@ count=%lu ids=%@",
              reason ?: @"(null)",
              window,
              (unsigned long)browserIds.size(),
              ids);
    }

    for (int browserId : browserIds) {
        [self closeBrowser:browserId];
    }
}

- (NSView *)browserViewForId:(int)browserId {
    auto it = _browserViews.find(browserId);
    if (it != _browserViews.end()) {
        return it->second;
    }
    return nil;
}

// Helper to translate Flutter browserId to CEF browserId
- (int)cefBrowserIdForFlutterId:(int)flutterId {
    auto it = _flutterToCefBrowserId.find(flutterId);
    if (it != _flutterToCefBrowserId.end()) {
        return it->second;
    }
    return -1;
}

// Helper to translate CEF browserId to Flutter browserId
- (int)flutterBrowserIdForCefId:(int)cefId {
    auto it = _cefToFlutterBrowserId.find(cefId);
    if (it != _cefToFlutterBrowserId.end()) {
        return it->second;
    }
    // Fall back to CEF ID if we never mapped it.
    return cefId;
}

- (void)ensureDevToolsObserverForBrowser:(CefRefPtr<CefBrowser>)browser {
    if (!browser || !browser->GetHost()) return;

    const int cefBrowserId = browser->GetIdentifier();
    auto regIt = _devToolsObserverRegsByCefId.find(cefBrowserId);
    if (regIt != _devToolsObserverRegsByCefId.end() && regIt->second) {
        return;
    }

    CefRefPtr<BridgeDevToolsObserver> observer = new BridgeDevToolsObserver(self, cefBrowserId);
    CefRefPtr<CefRegistration> registration = browser->GetHost()->AddDevToolsMessageObserver(observer);
    if (!registration) {
        NSLog(@"CEFBridge: Failed to register DevTools observer for browser %d", cefBrowserId);
        return;
    }

    _devToolsObserversByCefId[cefBrowserId] = observer;
    _devToolsObserverRegsByCefId[cefBrowserId] = registration;
}

- (void)removeDevToolsObserverForCefBrowserId:(int)cefBrowserId {
    _devToolsObserverRegsByCefId.erase(cefBrowserId);
    _devToolsObserversByCefId.erase(cefBrowserId);
    [self cancelPendingResponseBodyForCefBrowserId:cefBrowserId];
    [self cancelPendingEvaluateJavaScriptForCefBrowserId:cefBrowserId];
    [self cancelPendingScreenshotsForCefBrowserId:cefBrowserId];
    NSString* prefix = [NSString stringWithFormat:@"%d:", cefBrowserId];
    for (NSString* key in [_pendingTextInputCallbacks.allKeys copy]) {
        if (![key hasPrefix:prefix]) continue;
        TextInputCompletion completion = _pendingTextInputCallbacks[key];
        [_pendingTextInputCallbacks removeObjectForKey:key];
        completion(CefJavaScriptError(@"INPUT_BROWSER_CLOSED", @"Browser closed before input completed", @{}));
    }
}

- (void)cancelPendingResponseBodyForCefBrowserId:(int)cefBrowserId {
    NSString* prefix = [NSString stringWithFormat:@"%d:", cefBrowserId];
    NSArray<NSString*>* keys = [_pendingResponseBodyCallbacks.allKeys copy];
    for (NSString* key in keys) {
        if (![key hasPrefix:prefix]) continue;
        ResponseBodyCompletion completion = _pendingResponseBodyCallbacks[key];
        [_pendingResponseBodyCallbacks removeObjectForKey:key];
        if (completion) {
            completion(nil, NO);
        }
    }
}

- (void)cancelPendingEvaluateJavaScriptForCefBrowserId:(int)cefBrowserId {
    NSString* prefix = [NSString stringWithFormat:@"%d:", cefBrowserId];
    NSArray<NSString*>* keys = [_pendingEvaluateJavaScriptCallbacks.allKeys copy];
    for (NSString* key in keys) {
        if (![key hasPrefix:prefix]) continue;
        JavaScriptEvaluationCompletion completion = _pendingEvaluateJavaScriptCallbacks[key];
        [_pendingEvaluateJavaScriptCallbacks removeObjectForKey:key];
        if (completion) {
            completion(nil, CefJavaScriptError(@"JS_BROWSER_CLOSED",
                                               @"Browser closed before JavaScript evaluation completed",
                                               @{}));
        }
    }
}

- (void)cancelPendingScreenshotsForCefBrowserId:(int)cefBrowserId {
    NSString* prefix = [NSString stringWithFormat:@"%d:", cefBrowserId];
    NSArray<NSString*>* keys = [_pendingScreenshotCallbacks.allKeys copy];
    for (NSString* key in keys) {
        if (![key hasPrefix:prefix]) continue;
        ScreenshotCompletion completion = _pendingScreenshotCallbacks[key];
        [_pendingScreenshotCallbacks removeObjectForKey:key];
        if (completion) {
            completion(nil, CefJavaScriptError(@"SCREENSHOT_BROWSER_CLOSED",
                                               @"Browser closed before screenshot completed",
                                               @{}));
        }
    }
}

- (void)handleDevToolsMethodResultForCefBrowserId:(int)cefBrowserId
                                        messageId:(int)messageId
                                           success:(BOOL)success
                                            result:(NSDictionary*)result {
    NSString* key = DevToolsRequestKey(cefBrowserId, messageId);
    ResponseBodyCompletion completion = _pendingResponseBodyCallbacks[key];
    if (completion) {
        [_pendingResponseBodyCallbacks removeObjectForKey:key];

        NSString* body = nil;
        BOOL base64Encoded = NO;
        if (success && [result isKindOfClass:[NSDictionary class]]) {
            id bodyValue = result[@"body"];
            if ([bodyValue isKindOfClass:[NSString class]]) {
                body = (NSString*)bodyValue;
            } else if (bodyValue && bodyValue != [NSNull null]) {
                body = [bodyValue description];
            }

            id base64Value = result[@"base64Encoded"];
            if ([base64Value isKindOfClass:[NSNumber class]]) {
                base64Encoded = [(NSNumber*)base64Value boolValue];
            }
        }
        completion(body, base64Encoded);
        return;
    }

    TextInputCompletion inputCompletion = _pendingTextInputCallbacks[key];
    if (inputCompletion) {
        [_pendingTextInputCallbacks removeObjectForKey:key];
        inputCompletion(success ? nil : CefJavaScriptError(@"INPUT_ERROR", @"Chromium input failed", result ?: @{}));
        return;
    }

    ScreenshotCompletion screenshotCompletion = _pendingScreenshotCallbacks[key];
    if (screenshotCompletion) {
        [_pendingScreenshotCallbacks removeObjectForKey:key];
        NSString* data = nil;
        if (success && [result isKindOfClass:[NSDictionary class]] &&
            [result[@"data"] isKindOfClass:[NSString class]]) {
            data = (NSString*)result[@"data"];
        }
        if (data.length == 0) {
            screenshotCompletion(nil, CefJavaScriptError(@"SCREENSHOT_ERROR",
                                                         @"Page.captureScreenshot failed",
                                                         [result isKindOfClass:[NSDictionary class]] ? result : @{}));
        } else {
            screenshotCompletion(data, nil);
        }
        return;
    }

    JavaScriptEvaluationCompletion evaluationCompletion = _pendingEvaluateJavaScriptCallbacks[key];
    if (!evaluationCompletion) return;
    [_pendingEvaluateJavaScriptCallbacks removeObjectForKey:key];

    if (!success || ![result isKindOfClass:[NSDictionary class]]) {
        evaluationCompletion(nil, CefJavaScriptError(@"JS_EVAL_ERROR",
                                                     @"Runtime.evaluate failed",
                                                     [result isKindOfClass:[NSDictionary class]] ? result : @{}));
        return;
    }

    NSDictionary* exceptionDetails = [result[@"exceptionDetails"] isKindOfClass:[NSDictionary class]]
        ? (NSDictionary*)result[@"exceptionDetails"]
        : nil;
    if (exceptionDetails.count > 0) {
        NSString* exceptionText = StringValueOrNil(exceptionDetails[@"text"]) ?: @"JavaScript evaluation threw an exception";
        evaluationCompletion(nil, CefJavaScriptError(@"JS_EVAL_ERROR",
                                                     exceptionText,
                                                     exceptionDetails));
        return;
    }

    NSDictionary* remoteObject = [result[@"result"] isKindOfClass:[NSDictionary class]]
        ? (NSDictionary*)result[@"result"]
        : @{};
    NSString* type = StringValueOrNil(remoteObject[@"type"]) ?: @"";
    NSString* subtype = StringValueOrNil(remoteObject[@"subtype"]) ?: @"";
    if ([type isEqualToString:@"undefined"] || [subtype isEqualToString:@"null"]) {
        evaluationCompletion(nil, nil);
        return;
    }
    if ([type isEqualToString:@"string"]) {
        id value = remoteObject[@"value"];
        if ([value isKindOfClass:[NSString class]]) {
            evaluationCompletion((NSString*)value, nil);
            return;
        }
        if (value && value != [NSNull null]) {
            evaluationCompletion([value description], nil);
            return;
        }
        evaluationCompletion(nil, nil);
        return;
    }
    evaluationCompletion(nil, CefJavaScriptError(@"JS_RESULT_TYPE",
                                                 @"JavaScript evaluation returned a non-string result",
                                                 @{
                                                     @"type": type,
                                                     @"subtype": subtype,
                                                 }));
}

- (void)handleDevToolsEventForCefBrowserId:(int)cefBrowserId
                                     method:(NSString*)method
                                     params:(NSDictionary*)params {
    if (![method hasPrefix:@"Network."]) return;
    [self emitNetworkEventForCefBrowserId:cefBrowserId method:method params:params ?: @{}];
}

- (void)emitNetworkEventForCefBrowserId:(int)cefBrowserId
                                  method:(NSString*)method
                                  params:(NSDictionary*)params {
    NSDictionary* event = [self normalizedNetworkEventForMethod:method params:params];
    if (!event) return;

    const int flutterBrowserId = [self flutterBrowserIdForCefId:cefBrowserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onNetworkEvent:flutterBrowserId data:event];
    }
}

- (NSDictionary*)normalizedNetworkEventForMethod:(NSString*)method
                                          params:(NSDictionary*)params {
    NSString* (^safeString)(id, NSString*) = ^NSString* (id value, NSString* fallback) {
        if (!value || value == [NSNull null]) return fallback;
        if ([value isKindOfClass:[NSString class]]) return (NSString*)value;
        return [value description] ?: fallback;
    };
    double (^safeDouble)(id, double) = ^double (id value, double fallback) {
        if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber*)value doubleValue];
        if ([value isKindOfClass:[NSString class]]) return [(NSString*)value doubleValue];
        return fallback;
    };
    BOOL (^safeBool)(id, BOOL) = ^BOOL (id value, BOOL fallback) {
        if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber*)value boolValue];
        if ([value isKindOfClass:[NSString class]]) {
            NSString* lowered = [(NSString*)value lowercaseString];
            if ([lowered isEqualToString:@"true"] || [lowered isEqualToString:@"1"]) return YES;
            if ([lowered isEqualToString:@"false"] || [lowered isEqualToString:@"0"]) return NO;
        }
        return fallback;
    };

    NSString* requestId = safeString(params[@"requestId"], @"");
    if (requestId.length == 0) return nil;
    const double timestamp = safeDouble(params[@"timestamp"], [[NSDate date] timeIntervalSince1970]);

    if ([method isEqualToString:@"Network.requestWillBeSent"]) {
        NSDictionary* request = [params[@"request"] isKindOfClass:[NSDictionary class]]
            ? (NSDictionary*)params[@"request"]
            : @{};

        NSDictionary* rawReqHeaders = [request[@"headers"] isKindOfClass:[NSDictionary class]]
            ? (NSDictionary*)request[@"headers"]
            : @{};
        NSMutableDictionary* reqHeaders = [NSMutableDictionary dictionaryWithCapacity:rawReqHeaders.count];
        [rawReqHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL* stop) {
            reqHeaders[safeString(key, @"")] = safeString(obj, @"");
        }];

        return @{
            @"type": @"requestWillBeSent",
            @"requestId": requestId,
            @"url": safeString(request[@"url"], @""),
            @"method": safeString(request[@"method"], @"GET"),
            @"resourceType": safeString(params[@"type"], @"Other"),
            @"timestamp": @(timestamp),
            @"requestHeaders": reqHeaders,
        };
    }

    if ([method isEqualToString:@"Network.responseReceived"]) {
        NSDictionary* response = [params[@"response"] isKindOfClass:[NSDictionary class]]
            ? (NSDictionary*)params[@"response"]
            : @{};
        NSDictionary* rawHeaders = [response[@"headers"] isKindOfClass:[NSDictionary class]]
            ? (NSDictionary*)response[@"headers"]
            : @{};

        NSMutableDictionary* headers = [NSMutableDictionary dictionaryWithCapacity:rawHeaders.count];
        [rawHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL* stop) {
            headers[safeString(key, @"")] = safeString(obj, @"");
        }];

        NSMutableDictionary* out = [NSMutableDictionary dictionaryWithDictionary:@{
            @"type": @"responseReceived",
            @"requestId": requestId,
            @"url": safeString(response[@"url"], @""),
            @"resourceType": safeString(params[@"type"], @"Other"),
            @"timestamp": @(timestamp),
            @"status": @((int)safeDouble(response[@"status"], 0)),
            @"statusText": safeString(response[@"statusText"], @""),
            @"mimeType": safeString(response[@"mimeType"], @""),
            @"headers": headers,
        }];
        if ([response[@"timing"] isKindOfClass:[NSDictionary class]]) {
            out[@"timing"] = response[@"timing"];
        }
        return out;
    }

    if ([method isEqualToString:@"Network.loadingFinished"]) {
        return @{
            @"type": @"loadingFinished",
            @"requestId": requestId,
            @"url": @"",
            @"timestamp": @(timestamp),
            @"encodedDataLength": @((int)safeDouble(params[@"encodedDataLength"], 0)),
        };
    }

    if ([method isEqualToString:@"Network.loadingFailed"]) {
        return @{
            @"type": @"loadingFailed",
            @"requestId": requestId,
            @"url": @"",
            @"timestamp": @(timestamp),
            @"errorText": safeString(params[@"errorText"], @""),
            @"canceled": @(safeBool(params[@"canceled"], NO)),
        };
    }

    return nil;
}

// Navigation

- (void)loadUrl:(int)browserId url:(NSString *)url {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    NSLog(@"CEFBridge: loadUrl - flutterId: %d, cefId: %d, url: %@", browserId, cefId, url);
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    NSLog(@"CEFBridge: GetBrowser(%d) returned: %s", cefId, browser ? "valid" : "NULL");
    if (browser) {
        browser->GetMainFrame()->LoadURL([url UTF8String]);
        NSLog(@"CEFBridge: LoadURL called successfully");
    } else {
        NSLog(@"CEFBridge: ERROR - No browser found for cefId %d (flutterId: %d)", cefId, browserId);
    }
}

- (void)reload:(int)browserId ignoreCache:(BOOL)ignoreCache {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser) {
        if (ignoreCache) {
            browser->ReloadIgnoreCache();
        } else {
            browser->Reload();
        }
    }
}

- (void)stop:(int)browserId {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser) {
        browser->StopLoad();
    }
}

- (void)goBack:(int)browserId {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser && browser->CanGoBack()) {
        browser->GoBack();
    }
}

- (void)goForward:(int)browserId {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser && browser->CanGoForward()) {
        browser->GoForward();
    }
}

- (void)findInPage:(int)browserId
             query:(NSString *)query
           forward:(BOOL)forward
          findNext:(BOOL)findNext
         matchCase:(BOOL)matchCase {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (!browser || !browser->GetHost()) return;
    browser->GetHost()->Find(
        CefString((query ?: @"").UTF8String),
        forward,
        matchCase,
        findNext);
}

- (void)stopFinding:(int)browserId clearSelection:(BOOL)clearSelection {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser && browser->GetHost()) {
        browser->GetHost()->StopFinding(clearSelection);
    }
}

// JavaScript

- (void)executeJavaScript:(int)browserId
                     code:(NSString *)code
               completion:(void(^)(NSError * _Nullable))completion {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser) {
        browser->GetMainFrame()->ExecuteJavaScript([code UTF8String], "", 0);
        if (completion) {
            completion(nil);
        }
    } else if (completion) {
        completion(CefJavaScriptError(@"JS_BROWSER_NOT_FOUND",
                                      @"Browser not found",
                                      @{
                                          @"browserId": @(browserId),
                                      }));
    }
}

- (void)evaluateJavaScript:(int)browserId
                 expression:(NSString *)expression
                 completion:(void(^)(NSString * _Nullable, NSError * _Nullable))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self evaluateJavaScript:browserId expression:expression completion:completion];
        });
        return;
    }

    if (!completion) {
        return;
    }
    if (expression.length == 0) {
        completion(nil, CefJavaScriptError(@"JS_EMPTY_EXPRESSION",
                                           @"JavaScript expression must not be empty",
                                           @{}));
        return;
    }

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (!browser || !browser->GetHost()) {
        completion(nil, CefJavaScriptError(@"JS_BROWSER_NOT_FOUND",
                                           @"Browser not found",
                                           @{
                                               @"browserId": @(browserId),
                                           }));
        return;
    }

    [self ensureDevToolsObserverForBrowser:browser];
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("expression", [expression UTF8String]);
    params->SetBool("returnByValue", true);
    params->SetBool("awaitPromise", true);
    int messageId = browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
    if (messageId <= 0) {
        completion(nil, CefJavaScriptError(@"JS_EVAL_ERROR",
                                           @"Runtime.evaluate did not return a valid message id",
                                           @{
                                               @"browserId": @(browserId),
                                           }));
        return;
    }

    NSString* key = DevToolsRequestKey(cefId, messageId);
    _pendingEvaluateJavaScriptCallbacks[key] = [completion copy];
}

- (void)captureViewportScreenshot:(int)browserId
                           format:(NSString *)format
                          quality:(NSInteger)quality
                       completion:(void(^)(NSString * _Nullable, NSError * _Nullable))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self captureViewportScreenshot:browserId format:format quality:quality completion:completion];
        });
        return;
    }
    if (!completion) return;

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (!browser || !browser->GetHost()) {
        completion(nil, CefJavaScriptError(@"SCREENSHOT_BROWSER_NOT_FOUND",
                                           @"Browser not found",
                                           @{@"browserId": @(browserId)}));
        return;
    }

    NSString* normalizedFormat = [[format lowercaseString] isEqualToString:@"jpeg"] ? @"jpeg" : @"png";
    [self ensureDevToolsObserverForBrowser:browser];
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("format", [normalizedFormat UTF8String]);
    params->SetBool("fromSurface", true);
    params->SetBool("captureBeyondViewport", false);
    if ([normalizedFormat isEqualToString:@"jpeg"]) {
        params->SetInt("quality", (int)MAX(1, MIN(100, quality)));
    }
    int messageId = browser->GetHost()->ExecuteDevToolsMethod(0, "Page.captureScreenshot", params);
    if (messageId <= 0) {
        completion(nil, CefJavaScriptError(@"SCREENSHOT_ERROR",
                                           @"Page.captureScreenshot did not return a valid message id",
                                           @{@"browserId": @(browserId)}));
        return;
    }
    NSString* key = DevToolsRequestKey(cefId, messageId);
    _pendingScreenshotCallbacks[key] = [completion copy];
}

- (void)dispatchInput:(int)browserId
                   method:(NSString *)method
                   params:(NSDictionary *)inputParams
               completion:(void(^)(NSError * _Nullable))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dispatchInput:browserId method:method params:inputParams completion:completion];
        });
        return;
    }
    if (!completion) return;
    if (![@[@"Input.dispatchMouseEvent", @"Input.dispatchKeyEvent", @"Input.insertText"] containsObject:method]) {
        completion(CefJavaScriptError(@"INPUT_INVALID", @"Unsupported Chromium input method", @{}));
        return;
    }
    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (!browser || !browser->GetHost()) {
        completion(CefJavaScriptError(@"INPUT_BROWSER_NOT_FOUND", @"Browser not found", @{}));
        return;
    }
    NSError* serializationError = nil;
    NSData* json = [NSJSONSerialization dataWithJSONObject:inputParams options:0 error:&serializationError];
    CefRefPtr<CefValue> value = json ? CefParseJSON(json.bytes, json.length, JSON_PARSER_RFC) : nullptr;
    if (!value || value->GetType() != VTYPE_DICTIONARY) {
        completion(CefJavaScriptError(@"INPUT_INVALID", @"Invalid input parameters", @{}));
        return;
    }
    [self ensureDevToolsObserverForBrowser:browser];
    int messageId = browser->GetHost()->ExecuteDevToolsMethod(0, method.UTF8String, value->GetDictionary());
    if (messageId <= 0) {
        completion(CefJavaScriptError(@"INPUT_ERROR", @"Chromium input did not dispatch", @{}));
        return;
    }
    NSString* key = DevToolsRequestKey(browser->GetIdentifier(), messageId);
    _pendingTextInputCallbacks[key] = [completion copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        TextInputCompletion pending = self->_pendingTextInputCallbacks[key];
        if (!pending) return;
        [self->_pendingTextInputCallbacks removeObjectForKey:key];
        pending(CefJavaScriptError(@"INPUT_TIMEOUT", @"Input acknowledgement timed out; not retried", @{}));
    });
}

// Editing

- (BOOL)performEditCommand:(NSString *)command browserId:(int)browserId {
    if (![NSThread isMainThread]) {
        __block BOOL handled = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            handled = [self performEditCommand:command browserId:browserId];
        });
        return handled;
    }

    if (command.length == 0 || [self isBrowserClosingOrClosed:browserId]) {
        return NO;
    }

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser =
        (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (!browser || !browser->GetHost()) {
        return NO;
    }

    CefRefPtr<CefFrame> frame = browser->GetFocusedFrame();
    if (!frame || !frame->IsValid()) {
        frame = browser->GetMainFrame();
    }
    if (!frame || !frame->IsValid()) {
        return NO;
    }

    NSString* normalized = [[command lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if ([normalized isEqualToString:@"undo"]) {
        frame->Undo();
        return YES;
    }
    if ([normalized isEqualToString:@"redo"]) {
        frame->Redo();
        return YES;
    }
    if ([normalized isEqualToString:@"cut"]) {
        frame->Cut();
        return YES;
    }
    if ([normalized isEqualToString:@"copy"]) {
        frame->Copy();
        return YES;
    }
    if ([normalized isEqualToString:@"paste"]) {
        frame->Paste();
        return YES;
    }
    if ([normalized isEqualToString:@"selectall"]) {
        frame->SelectAll();
        return YES;
    }
    if ([normalized isEqualToString:@"delete"]) {
        frame->Delete();
        return YES;
    }

    return NO;
}

- (BOOL)performBrowserCommand:(NSString *)command browserId:(int)browserId {
    if (![NSThread isMainThread]) {
        __block BOOL handled = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            handled = [self performBrowserCommand:command browserId:browserId];
        });
        return handled;
    }

    NSString* normalized =
        [[command lowercaseString] stringByReplacingOccurrencesOfString:@"-"
                                                             withString:@""];
    if ([normalized isEqualToString:@"undo"] ||
        [normalized isEqualToString:@"redo"] ||
        [normalized isEqualToString:@"cut"] ||
        [normalized isEqualToString:@"copy"] ||
        [normalized isEqualToString:@"paste"] ||
        [normalized isEqualToString:@"selectall"] ||
        [normalized isEqualToString:@"delete"]) {
        return [self performEditCommand:command browserId:browserId];
    }

    if ([self isBrowserClosingOrClosed:browserId]) {
        return NO;
    }
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser =
        (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (!browser || !browser->GetHost()) {
        return NO;
    }

    if ([normalized isEqualToString:@"zoomin"]) {
        const double level = browser->GetHost()->GetZoomLevel() + 0.5;
        browser->GetHost()->SetZoomLevel(level);
        for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
            [delegate onZoomChanged:browserId level:level reset:NO];
        }
        return YES;
    }
    if ([normalized isEqualToString:@"zoomout"]) {
        const double level = browser->GetHost()->GetZoomLevel() - 0.5;
        browser->GetHost()->SetZoomLevel(level);
        for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
            [delegate onZoomChanged:browserId level:level reset:NO];
        }
        return YES;
    }
    if ([normalized isEqualToString:@"zoomreset"]) {
        browser->GetHost()->SetZoomLevel(0.0);
        for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
            [delegate onZoomChanged:browserId level:0.0 reset:YES];
        }
        return YES;
    }

    CefRefPtr<CefFrame> frame = browser->GetMainFrame();
    if (!frame || !frame->IsValid()) {
        return NO;
    }
    if ([normalized isEqualToString:@"scrolltotop"]) {
        frame->ExecuteJavaScript("window.scrollTo({top: 0})", frame->GetURL(), 0);
        return YES;
    }
    if ([normalized isEqualToString:@"scrolltobottom"]) {
        frame->ExecuteJavaScript(
            "window.scrollTo({top: document.body.scrollHeight})",
            frame->GetURL(),
            0);
        return YES;
    }

    return NO;
}

// Focus

- (void)setFocus:(int)browserId focused:(BOOL)focused {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setFocus:browserId focused:focused];
        });
        return;
    }

    if ([self isBrowserClosingOrClosed:browserId]) {
        return;
    }

    auto containerIt = _browserViews.find(browserId);
    NSView* browserContainer = (containerIt != _browserViews.end()) ? containerIt->second : nil;
    if (!browserContainer) {
        return;
    }
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (_osrFlutterBrowserIds.find(browserId) != _osrFlutterBrowserIds.end()) {
        if (browser && browser->GetHost()) {
            browser->GetHost()->SetFocus(focused);
        }
        return;
    }
    NSWindow* window = browserContainer.window;
    if (!window) {
        if (focused) {
            __weak CEFBridge* weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CEFBridge* strongSelf = weakSelf;
                if (!strongSelf || [strongSelf isBrowserClosingOrClosed:browserId]) {
                    return;
                }
                [strongSelf setFocus:browserId focused:focused];
            });
        }
        return;
    }

    if (browser && browser->GetHost()) {
        browser->GetHost()->SetFocus(focused);
    }

    // Avoid asking CEF for its NSView during focus churn. Crash logs showed
    // GetWindowHandle could return an Objective-C zombie after stale pane
    // restoration. The retained child of our container is safe to message.
    NSView* browserView = RetainedBrowserSubviewForContainer(browserContainer);
    if (focused) {
        [browserContainer setHidden:NO];
        if (browserView) {
            [browserView setHidden:NO];
        }
    }

    if (focused) {
        AttemptBrowserFirstResponder(window, browserView, browserContainer);
        return;
    }

    NSResponder* currentResponder = window.firstResponder;
    if (ResponderBelongsToBrowser(currentResponder, browserView, browserContainer)) {
        if (window.contentView && [window.contentView acceptsFirstResponder]) {
            [window makeFirstResponder:window.contentView];
        } else {
            [window makeFirstResponder:nil];
        }
    }
}

- (void)setVisible:(int)browserId visible:(BOOL)visible {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setVisible:browserId visible:visible];
        });
        return;
    }

    if ([self isBrowserClosingOrClosed:browserId]) {
        return;
    }

    auto containerIt = _browserViews.find(browserId);
    if (containerIt == _browserViews.end() || !containerIt->second) return;

    NSView* browserContainer = containerIt->second;
    [browserContainer setHidden:!visible];

	    int cefId = [self cefBrowserIdForFlutterId:browserId];
	    CefRefPtr<CefBrowser> browser = (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
	    if (browser && browser->GetHost()) {
            if (!visible) {
                browser->GetHost()->SetFocus(false);
            }
	        NSView* browserView = RetainedBrowserSubviewForContainer(browserContainer);
	        if (browserView && browserView != browserContainer) {
	            [browserView setHidden:!visible];
	        }
            if (!visible) {
                NSWindow* window = browserContainer.window;
                NSResponder* currentResponder = window.firstResponder;
                if (ResponderBelongsToBrowser(currentResponder, browserView, browserContainer)) {
                    if (window.contentView && [window.contentView acceptsFirstResponder]) {
                        [window makeFirstResponder:window.contentView];
                    } else {
                        [window makeFirstResponder:nil];
                    }
                }
            }
	    }

    auto panelIt = _devToolsPanels.find(browserId);
    if (panelIt != _devToolsPanels.end() && panelIt->second) {
        [panelIt->second setHidden:!visible];
    }

    auto dividerIt = _devToolsDividers.find(browserId);
    if (dividerIt != _devToolsDividers.end() && dividerIt->second) {
        [dividerIt->second setHidden:!visible];
    }
}

- (void)setAcceleratedFrameLeaseEnabled:(int)browserId
                                enabled:(BOOL)enabled {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setAcceleratedFrameLeaseEnabled:browserId enabled:enabled];
        });
        return;
    }
    _osrFrameLeaseConfiguredBrowserIds.insert(browserId);
    if (enabled && CEFAcceleratedFrameLeaseApiAvailable()) {
        _osrFrameLeaseEnabledBrowserIds.insert(browserId);
    } else {
        _osrFrameLeaseEnabledBrowserIds.erase(browserId);
    }
    const int cefId = [self cefBrowserIdForFlutterId:browserId];
    if (_client && cefId >= 0) {
        _client->SetAcceleratedFrameLeaseEnabled(
            cefId, enabled && CEFAcceleratedFrameLeaseApiAvailable());
    }
}

// Off-screen rendering input

- (CefRefPtr<CefBrowser>)browserForInputDispatch:(int)browserId {
    if ([self isBrowserClosingOrClosed:browserId]) {
        return nullptr;
    }
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    return (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
}

- (NSPoint)popupAdjustedInputPointForBrowserId:(int)browserId
                                             x:(CGFloat)x
                                             y:(CGFloat)y {
    NSPoint point = NSMakePoint(x, y);
    if (_osrPopupVisibleBrowserIds.find(browserId) ==
        _osrPopupVisibleBrowserIds.end()) {
        return point;
    }
    auto popupIt = _osrPopupRects.find(browserId);
    auto originalIt = _osrOriginalPopupRects.find(browserId);
    if (popupIt == _osrPopupRects.end() ||
        originalIt == _osrOriginalPopupRects.end()) {
        return point;
    }
    const CGRect popup = popupIt->second;
    if (x >= CGRectGetMinX(popup) && x < CGRectGetMaxX(popup) &&
        y >= CGRectGetMinY(popup) && y < CGRectGetMaxY(popup)) {
        point.x += originalIt->second.origin.x - popup.origin.x;
        point.y += originalIt->second.origin.y - popup.origin.y;
    }
    return point;
}

- (void)sendMouseMove:(int)browserId
                    x:(CGFloat)x
                    y:(CGFloat)y
            modifiers:(NSInteger)modifiers
           mouseLeave:(BOOL)mouseLeave {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendMouseMove:browserId
                              x:x
                              y:y
                      modifiers:modifiers
                     mouseLeave:mouseLeave];
        });
        return;
    }
    if (!isfinite(x) || !isfinite(y)) return;

    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (!browser || !browser->GetHost()) {
        return;
    }

    const NSPoint point =
        [self popupAdjustedInputPointForBrowserId:browserId x:x y:y];
    CefMouseEvent event;
    event.x = (int)llround(point.x);
    event.y = (int)llround(point.y);
    event.modifiers = (uint32_t)modifiers;
    browser->GetHost()->SendMouseMoveEvent(event, mouseLeave);
}

- (void)sendMouseClick:(int)browserId
                     x:(CGFloat)x
                     y:(CGFloat)y
                button:(NSString *)button
               mouseUp:(BOOL)mouseUp
            clickCount:(NSInteger)clickCount
             modifiers:(NSInteger)modifiers {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendMouseClick:browserId
                               x:x
                               y:y
                          button:button
                         mouseUp:mouseUp
                      clickCount:clickCount
                       modifiers:modifiers];
        });
        return;
    }
    if (!isfinite(x) || !isfinite(y)) return;

    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (!browser || !browser->GetHost()) {
        return;
    }

    const NSPoint point =
        [self popupAdjustedInputPointForBrowserId:browserId x:x y:y];
    if (ShouldLogPopupDebug()) {
        auto viewIt = _browserViews.find(browserId);
        NSView* view = viewIt != _browserViews.end() ? viewIt->second : nil;
        NSLog(@"CEFBridge: SendMouseClick browserId=%d local=(%.2f,%.2f) adjusted=(%.2f,%.2f) popup=%d viewFrame=%@ viewBounds=%@",
              browserId, x, y, point.x, point.y,
              _osrPopupVisibleBrowserIds.count(browserId) ? 1 : 0,
              view ? NSStringFromRect(view.frame) : @"(null)",
              view ? NSStringFromRect(view.bounds) : @"(null)");
    }
    CefMouseEvent event;
    event.x = (int)llround(point.x);
    event.y = (int)llround(point.y);
    event.modifiers = (uint32_t)modifiers;
    browser->GetHost()->SendMouseClickEvent(
        event,
        CefMouseButtonTypeFromString(button),
        mouseUp,
        (int)MAX(1, clickCount));
}

- (void)sendMouseWheel:(int)browserId
                     x:(CGFloat)x
                     y:(CGFloat)y
                deltaX:(NSInteger)deltaX
                deltaY:(NSInteger)deltaY
             modifiers:(NSInteger)modifiers {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendMouseWheel:browserId
                               x:x
                               y:y
                          deltaX:deltaX
                          deltaY:deltaY
                       modifiers:modifiers];
        });
        return;
    }
    if (!isfinite(x) || !isfinite(y)) return;

    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (!browser || !browser->GetHost()) {
        return;
    }

    const NSPoint point =
        [self popupAdjustedInputPointForBrowserId:browserId x:x y:y];
    CefMouseEvent event;
    event.x = (int)llround(point.x);
    event.y = (int)llround(point.y);
    event.modifiers = (uint32_t)modifiers;
    browser->GetHost()->SendMouseWheelEvent(event, (int)deltaX, (int)deltaY);
}

static uint32_t CefMouseModifiersForNativeEvent(NSEvent* event) {
    uint32_t modifiers = EVENTFLAG_NONE;
    const NSEventModifierFlags flags =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags & NSEventModifierFlagShift) modifiers |= EVENTFLAG_SHIFT_DOWN;
    if (flags & NSEventModifierFlagControl) modifiers |= EVENTFLAG_CONTROL_DOWN;
    if (flags & NSEventModifierFlagOption) modifiers |= EVENTFLAG_ALT_DOWN;
    if (flags & NSEventModifierFlagCommand) modifiers |= EVENTFLAG_COMMAND_DOWN;
    if (flags & NSEventModifierFlagCapsLock) modifiers |= EVENTFLAG_CAPS_LOCK_ON;
    if (flags & NSEventModifierFlagNumericPad) modifiers |= EVENTFLAG_NUM_LOCK_ON;

    const NSUInteger buttons = [NSEvent pressedMouseButtons];
    if (buttons & (1U << 0)) modifiers |= EVENTFLAG_LEFT_MOUSE_BUTTON;
    if (buttons & (1U << 1)) modifiers |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
    if (buttons & (1U << 2)) modifiers |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
    return modifiers;
}

- (BOOL)browserPointForEvent:(NSEvent*)event
                  browserId:(int)browserId
                  localPoint:(NSPoint*)localPoint {
    if (!event.window ||
        _osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end() ||
        _osrHiddenBrowserIds.count(browserId) > 0 ||
        _osrParkedBrowserIds.count(browserId) > 0 ||
        [self isBrowserClosingOrClosed:browserId]) {
        return NO;
    }
    auto viewIt = _browserViews.find(browserId);
    NSView* view = viewIt != _browserViews.end() ? viewIt->second : nil;
    if (!view || !view.superview || view.window != event.window ||
        NSIsEmptyRect(view.bounds)) {
        return NO;
    }

    const NSPoint point = [view convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(point, view.bounds)) {
        return NO;
    }
    if (localPoint) {
        const CGFloat x = point.x - NSMinX(view.bounds);
        const CGFloat y = view.isFlipped
            ? point.y - NSMinY(view.bounds)
            : NSMaxY(view.bounds) - point.y;
        *localPoint = NSMakePoint(x, y);
    }
    return YES;
}

- (int)osrBrowserAtEvent:(NSEvent*)event localPoint:(NSPoint*)localPoint {
    int selectedBrowserId = -1;
    NSPoint selectedPoint = NSZeroPoint;
    CGFloat selectedArea = CGFLOAT_MAX;
    for (int browserId : _osrFlutterBrowserIds) {
        NSPoint point = NSZeroPoint;
        if (![self browserPointForEvent:event browserId:browserId localPoint:&point]) {
            continue;
        }
        auto viewIt = _browserViews.find(browserId);
        NSView* view = viewIt != _browserViews.end() ? viewIt->second : nil;
        const CGFloat area = view ? NSWidth(view.bounds) * NSHeight(view.bounds) : 0;
        // Split DevTools/page textures do not overlap. If stale containers do,
        // prefer the narrower visible surface instead of an old full-window one.
        if (selectedBrowserId < 0 || area < selectedArea) {
            selectedBrowserId = browserId;
            selectedPoint = point;
            selectedArea = area;
        }
    }
    if (selectedBrowserId >= 0 && localPoint) {
        *localPoint = selectedPoint;
    }
    return selectedBrowserId;
}

- (BOOL)handleNativeScrollWheelEvent:(NSEvent*)event {
    if (![NSThread isMainThread] || event.type != NSEventTypeScrollWheel) {
        return NO;
    }

    const NSEventPhase phase = event.phase;
    const NSEventPhase momentumPhase = event.momentumPhase;
    const BOOL beginsGesture =
        (phase & (NSEventPhaseMayBegin | NSEventPhaseBegan)) != 0;
    const BOOL standaloneWheelTick =
        phase == NSEventPhaseNone && momentumPhase == NSEventPhaseNone;

    int browserId = _nativeScrollGestureBrowserId;
    NSPoint browserPoint = _nativeScrollGesturePoint;
    if (beginsGesture || standaloneWheelTick || browserId < 0) {
        browserId = [self osrBrowserAtEvent:event localPoint:&browserPoint];
        if (browserId != _nativeScrollGestureBrowserId) {
            _nativeScrollRemainderX = 0.0;
            _nativeScrollRemainderY = 0.0;
        }
        _nativeScrollGestureBrowserId = browserId;
        _nativeScrollGesturePoint = browserPoint;
    } else {
        // AppKit latches momentum to the view where the gesture began even if
        // the pointer moves. Update the target point only while it remains in
        // the same browser; otherwise retain the last in-bounds point.
        NSPoint currentPoint = NSZeroPoint;
        if ([self browserPointForEvent:event
                             browserId:browserId
                             localPoint:&currentPoint]) {
            browserPoint = currentPoint;
            _nativeScrollGesturePoint = currentPoint;
        }
    }

    CefRefPtr<CefBrowser> browser =
        browserId >= 0 ? [self browserForInputDispatch:browserId] : nullptr;
    if (!browser || !browser->GetHost()) {
        if (browserId >= 0) {
            _nativeScrollGestureBrowserId = -1;
            _nativeScrollRemainderX = 0.0;
            _nativeScrollRemainderY = 0.0;
        }
        return NO;
    }

    // A precise, phase-bearing horizontal trackpad gesture is browser
    // navigation when it is dominant and history exists in that direction.
    // Keep it separate from ordinary horizontal page scrolling and latch the
    // browser selected at gesture start through the final phase.
    const BOOL hasGesturePhase = phase != NSEventPhaseNone;
    if (beginsGesture) {
        _nativeSwipeGestureBrowserId = browserId;
        _nativeSwipeAccumulatedX = 0.0;
        _nativeSwipeDirection = 0;
        _nativeSwipeGestureActive = NO;
        _nativeSwipeSuppressMomentum = NO;
    } else if (standaloneWheelTick) {
        _nativeSwipeSuppressMomentum = NO;
    }

    if (_nativeSwipeSuppressMomentum && momentumPhase != NSEventPhaseNone) {
        if ((momentumPhase & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0) {
            _nativeSwipeSuppressMomentum = NO;
        }
        return YES;
    }

    const double swipeDeltaX = event.scrollingDeltaX;
    const double swipeDeltaY = event.scrollingDeltaY;
    const BOOL horizontallyDominant =
        fabs(swipeDeltaX) > MAX(1.0, fabs(swipeDeltaY) * 1.2);
    if (event.hasPreciseScrollingDeltas &&
        (_nativeSwipeGestureActive || (hasGesturePhase && horizontallyDominant))) {
        _nativeSwipeAccumulatedX += swipeDeltaX;
        const NSInteger direction = _nativeSwipeAccumulatedX >= 0.0 ? 1 : -1;
        const BOOL canNavigate = direction > 0
            ? browser->CanGoBack()
            : browser->CanGoForward();

        if (!_nativeSwipeGestureActive && canNavigate &&
            fabs(_nativeSwipeAccumulatedX) >= 2.0) {
            _nativeSwipeGestureActive = YES;
            _nativeSwipeGestureBrowserId = browserId;
            _nativeSwipeDirection = direction;
        }

        if (_nativeSwipeGestureActive) {
            if (direction != _nativeSwipeDirection) {
                _nativeSwipeAccumulatedX = swipeDeltaX;
                _nativeSwipeDirection = direction;
            }
            const double threshold = 110.0;
            const double progress = MIN(1.0, fabs(_nativeSwipeAccumulatedX) / threshold);
            const BOOL cancelled =
                (phase & NSEventPhaseCancelled) != 0 ||
                (momentumPhase & NSEventPhaseCancelled) != 0;
            const BOOL ended =
                (phase & NSEventPhaseEnded) != 0 ||
                (momentumPhase & NSEventPhaseEnded) != 0;
            const BOOL committed = ended && !cancelled && progress >= 1.0 && canNavigate;
            NSString* phaseName = cancelled
                ? @"cancelled"
                : ended ? @"ended" : beginsGesture ? @"began" : @"updated";
            for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
                if (![delegate respondsToSelector:@selector(onSwipeNavigationForBrowserId:direction:progress:phase:committed:)]) {
                    continue;
                }
                [delegate onSwipeNavigationForBrowserId:browserId
                                              direction:_nativeSwipeDirection > 0 ? @"back" : @"forward"
                                               progress:progress
                                                  phase:phaseName
                                              committed:committed];
            }
            if (ended || cancelled) {
                _nativeSwipeSuppressMomentum = YES;
                _nativeSwipeGestureBrowserId = -1;
                _nativeSwipeAccumulatedX = 0.0;
                _nativeSwipeDirection = 0;
                _nativeSwipeGestureActive = NO;
            }
            return YES;
        }
    }

    // AppKit reports trackpads in points and traditional wheels in lines.
    // Convert coarse line ticks to Chrome-like pixels; precise deltas, including
    // the full momentum tail, pass through at their native point resolution.
    const double deltaScale = event.hasPreciseScrollingDeltas ? 1.0 : 40.0;
    const double accumulatedX =
        event.scrollingDeltaX * deltaScale + _nativeScrollRemainderX;
    const double accumulatedY =
        event.scrollingDeltaY * deltaScale + _nativeScrollRemainderY;
    const int deltaX = (int)std::trunc(accumulatedX);
    const int deltaY = (int)std::trunc(accumulatedY);
    _nativeScrollRemainderX = accumulatedX - deltaX;
    _nativeScrollRemainderY = accumulatedY - deltaY;

    if (deltaX != 0 || deltaY != 0) {
        const NSPoint adjustedPoint =
            [self popupAdjustedInputPointForBrowserId:browserId
                                                   x:browserPoint.x
                                                   y:browserPoint.y];
        CefMouseEvent mouseEvent;
        mouseEvent.x = (int)llround(adjustedPoint.x);
        mouseEvent.y = (int)llround(adjustedPoint.y);
        mouseEvent.modifiers = CefMouseModifiersForNativeEvent(event);
        browser->GetHost()->SendMouseWheelEvent(mouseEvent, deltaX, deltaY);
    }

    if ((momentumPhase & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0 ||
        (phase & NSEventPhaseCancelled) != 0) {
        _nativeScrollGestureBrowserId = -1;
        _nativeScrollRemainderX = 0.0;
        _nativeScrollRemainderY = 0.0;
    }
    return YES;
}

static NSCursor* CursorForCefType(NSInteger rawType, NSCursor* nativeCursor) {
    // CEF supplies an NSCursor handle on macOS, including CT_CUSTOM. Prefer it
    // verbatim; the type mapping keeps standard feedback working if a future
    // CEF callback omits the native handle.
    if (nativeCursor) return nativeCursor;

    switch ((cef_cursor_type_t)rawType) {
        case CT_CROSS:
        case CT_CELL:
            return [NSCursor crosshairCursor];
        case CT_HAND:
            return [NSCursor pointingHandCursor];
        case CT_IBEAM:
            return [NSCursor IBeamCursor];
        case CT_VERTICALTEXT:
            return [NSCursor IBeamCursorForVerticalLayout];
        case CT_EASTRESIZE:
        case CT_WESTRESIZE:
        case CT_EASTWESTRESIZE:
        case CT_COLUMNRESIZE:
        case CT_MIDDLE_PANNING_HORIZONTAL:
            return [NSCursor resizeLeftRightCursor];
        case CT_NORTHRESIZE:
        case CT_SOUTHRESIZE:
        case CT_NORTHSOUTHRESIZE:
        case CT_ROWRESIZE:
        case CT_MIDDLE_PANNING_VERTICAL:
            return [NSCursor resizeUpDownCursor];
        case CT_NORTHEASTRESIZE:
        case CT_NORTHWESTRESIZE:
        case CT_SOUTHEASTRESIZE:
        case CT_SOUTHWESTRESIZE:
        case CT_NORTHEASTSOUTHWESTRESIZE:
        case CT_NORTHWESTSOUTHEASTRESIZE:
            return [NSCursor crosshairCursor];
        case CT_CONTEXTMENU:
            return [NSCursor contextualMenuCursor];
        case CT_ALIAS:
        case CT_DND_LINK:
            return [NSCursor dragLinkCursor];
        case CT_COPY:
        case CT_DND_COPY:
            return [NSCursor dragCopyCursor];
        case CT_NODROP:
        case CT_NOTALLOWED:
        case CT_DND_NONE:
            return [NSCursor operationNotAllowedCursor];
        case CT_GRABBING:
            return [NSCursor closedHandCursor];
        case CT_GRAB:
        case CT_MOVE:
        case CT_MIDDLEPANNING:
        case CT_EASTPANNING:
        case CT_NORTHPANNING:
        case CT_NORTHEASTPANNING:
        case CT_NORTHWESTPANNING:
        case CT_SOUTHPANNING:
        case CT_SOUTHEASTPANNING:
        case CT_SOUTHWESTPANNING:
        case CT_WESTPANNING:
        case CT_DND_MOVE:
            return [NSCursor openHandCursor];
        case CT_ZOOMIN:
            if (@available(macOS 15.0, *)) return [NSCursor zoomInCursor];
            return [NSCursor pointingHandCursor];
        case CT_ZOOMOUT:
            if (@available(macOS 15.0, *)) return [NSCursor zoomOutCursor];
            return [NSCursor pointingHandCursor];
        case CT_POINTER:
        case CT_WAIT:
        case CT_HELP:
        case CT_PROGRESS:
        case CT_NONE:
        case CT_CUSTOM:
        case CT_NUM_VALUES:
            return [NSCursor arrowCursor];
    }

    return [NSCursor arrowCursor];
}

- (void)applyOsrCursorForEvent:(NSEvent*)event {
    if (![NSThread isMainThread] || !event.window) return;
    const int browserId = [self osrBrowserAtEvent:event localPoint:nullptr];
    if (browserId < 0) {
        _activeOsrCursorBrowserId = -1;
        return;
    }

    _activeOsrCursorBrowserId = browserId;
    NSCursor* cursor = _osrCursorsByBrowserId[@(browserId)] ?: [NSCursor arrowCursor];
    [cursor set];
}

- (void)sendKeyEvent:(int)browserId
                type:(NSString *)type
      windowsKeyCode:(NSInteger)windowsKeyCode
       nativeKeyCode:(NSInteger)nativeKeyCode
           character:(NSInteger)character
 unmodifiedCharacter:(NSInteger)unmodifiedCharacter
           modifiers:(NSInteger)modifiers
         isSystemKey:(BOOL)isSystemKey {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendKeyEvent:browserId
                          type:type
                windowsKeyCode:windowsKeyCode
                 nativeKeyCode:nativeKeyCode
                     character:character
           unmodifiedCharacter:unmodifiedCharacter
                     modifiers:modifiers
                   isSystemKey:isSystemKey];
        });
        return;
    }

    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (!browser || !browser->GetHost()) {
        return;
    }

    CefKeyEvent event;
    event.type = CefKeyEventTypeFromString(type);
    event.modifiers = (uint32_t)modifiers;
    event.native_key_code = (int)nativeKeyCode;
    event.windows_key_code = windowsKeyCode > 0
        ? (int)windowsKeyCode
        : MacKeyCodeToWindowsKeyCode(nativeKeyCode);
    event.character = (char16_t)MAX(0, character);
    event.unmodified_character = (char16_t)MAX(0, unmodifiedCharacter);
    event.is_system_key = isSystemKey ? 1 : 0;
    if (event.type != KEYEVENT_CHAR && event.character == 0 &&
        event.unmodified_character == 0) {
        // CEF 147's macOS translator treats two empty character fields as an
        // NSEventTypeFlagsChanged event, even for RAWKEYDOWN/KEYUP. Preserve
        // real AppKit characters for keycode-only keys so KEYUP stays a key-up.
        const char16_t keyCharacter =
            MacCharacterForKeyCodeOnlyEvent(event.windows_key_code);
        event.character = keyCharacter;
        event.unmodified_character = keyCharacter;
    }
    if (ShouldLogKeyDebug()) {
        NSLog(@"CEFBridge: SendKeyEvent browserId=%d type=%d windows_key_code=%d native_key_code=%d character=%u",
              browserId,
              static_cast<int>(event.type),
              event.windows_key_code,
              event.native_key_code,
              static_cast<unsigned int>(event.character));
    }
    browser->GetHost()->SendKeyEvent(event);
}

- (void)imeSetComposition:(int)browserId
                     text:(NSString*)text
                 selStart:(NSInteger)selStart
                   selEnd:(NSInteger)selEnd {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self imeSetComposition:browserId
                               text:text
                           selStart:selStart
                             selEnd:selEnd];
        });
        return;
    }
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return;
    }
    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (!browser || !browser->GetHost()) return;
    browser->GetHost()->ImeSetComposition(
        CefString((text ?: @"").UTF8String),
        std::vector<CefCompositionUnderline>{},
        CefRange(UINT32_MAX, UINT32_MAX),
        CefRange(static_cast<uint32_t>(selStart), static_cast<uint32_t>(selEnd)));
}

- (void)imeCommitText:(int)browserId text:(NSString*)text {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self imeCommitText:browserId text:text];
        });
        return;
    }
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return;
    }
    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (!browser || !browser->GetHost()) return;
    browser->GetHost()->ImeCommitText(
        CefString((text ?: @"").UTF8String), CefRange(UINT32_MAX, UINT32_MAX), 0);
}

- (void)imeFinishComposing:(int)browserId keepSelection:(BOOL)keepSelection {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self imeFinishComposing:browserId keepSelection:keepSelection];
        });
        return;
    }
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return;
    }
    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (browser && browser->GetHost()) {
        browser->GetHost()->ImeFinishComposingText(keepSelection);
    }
}

- (void)imeCancelComposition:(int)browserId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self imeCancelComposition:browserId];
        });
        return;
    }
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return;
    }
    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (browser && browser->GetHost()) {
        browser->GetHost()->ImeCancelComposition();
    }
}

- (void)setZoomLevel:(int)browserId level:(double)level {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setZoomLevel:browserId level:level];
        });
        return;
    }
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return;
    }
    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (browser && browser->GetHost()) {
        browser->GetHost()->SetZoomLevel(level);
    }
}

- (void)pinchZoom:(int)browserId scale:(double)scale x:(double)x y:(double)y {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pinchZoom:browserId scale:scale x:x y:y];
        });
        return;
    }
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end() ||
        !isfinite(scale) || scale <= 0 || !isfinite(x) || !isfinite(y)) {
        return;
    }
    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (!browser || !browser->GetHost()) return;

    CefSyntheticPinchState& state = _syntheticPinches[browserId];
    if (!state.active) {
        if (fabs(scale - 1.0) < 0.0001) return;
        state.active = YES;
        state.scale = 1.0;
        state.anchorX = x;
        state.anchorY = y;

        // CEF 147's OSR host feeds SendTouchEvent into FilteredGestureProvider,
        // which emits Blink pinch gestures and changes the visual viewport page
        // scale. This is intentionally not CefBrowserHost::SetZoomLevel.
        for (int touchId = 0; touchId < 2; touchId++) {
            CefTouchEvent event;
            event.id = touchId;
            event.x = (float)(state.anchorX + (touchId == 0 ? -state.radius : state.radius));
            event.y = (float)state.anchorY;
            event.pressure = 1.0f;
            event.type = CEF_TET_PRESSED;
            event.pointer_type = CEF_POINTER_TYPE_TOUCH;
            browser->GetHost()->SendTouchEvent(event);
        }
    }

    const double boundedScale = MIN(MAX(scale, 0.1), 10.0);
    const double spanScale = MAX(boundedScale, kMinSpanScale);
    if (fabs(boundedScale - state.scale) >= 0.0001) {
        for (int touchId = 0; touchId < 2; touchId++) {
            CefTouchEvent event;
            event.id = touchId;
            event.x = (float)(state.anchorX +
                (touchId == 0 ? -state.radius : state.radius) * spanScale);
            event.y = (float)state.anchorY;
            event.pressure = 1.0f;
            event.type = CEF_TET_MOVED;
            event.pointer_type = CEF_POINTER_TYPE_TOUCH;
            browser->GetHost()->SendTouchEvent(event);
        }
        state.scale = boundedScale;
    }

    const uint64_t generation = ++state.generation;
    __weak CEFBridge* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf finishSyntheticPinchForBrowserId:browserId generation:generation];
    });
}

- (void)finishSyntheticPinchForBrowserId:(int)browserId generation:(uint64_t)generation {
    auto stateIt = _syntheticPinches.find(browserId);
    if (stateIt == _syntheticPinches.end() || !stateIt->second.active ||
        stateIt->second.generation != generation) {
        return;
    }
    CefSyntheticPinchState state = stateIt->second;
    CefRefPtr<CefBrowser> browser = [self browserForInputDispatch:browserId];
    if (browser && browser->GetHost()) {
        for (int touchId = 0; touchId < 2; touchId++) {
            CefTouchEvent event;
            event.id = touchId;
            event.x = (float)(state.anchorX +
                (touchId == 0 ? -state.radius : state.radius) *
                    MAX(state.scale, kMinSpanScale));
            event.y = (float)state.anchorY;
            event.type = CEF_TET_RELEASED;
            event.pointer_type = CEF_POINTER_TYPE_TOUCH;
            browser->GetHost()->SendTouchEvent(event);
        }
    }
    _syntheticPinches.erase(stateIt);
}

- (void)resolveJsDialog:(int)browserId
             callbackId:(int)callbackId
                 success:(BOOL)success
               userInput:(NSString*)userInput {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resolveJsDialog:browserId
                       callbackId:callbackId
                           success:success
                         userInput:userInput];
        });
        return;
    }
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return;
    }
    const int cefId = [self cefBrowserIdForFlutterId:browserId];
    if (_client && cefId >= 0) {
        _client->ResolveJsDialog(cefId,
                                 callbackId,
                                 success,
                                 std::string((userInput ?: @"").UTF8String));
    }
}

- (void)resolvePermissionPrompt:(int)browserId
                       promptId:(NSString*)promptId
                          allow:(BOOL)allow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resolvePermissionPrompt:browserId
                                 promptId:promptId
                                    allow:allow];
        });
        return;
    }
    const int cefId = [self cefBrowserIdForFlutterId:browserId];
    if (_client && cefId >= 0 && promptId.length > 0) {
        _client->ResolvePermissionPrompt(
            cefId,
            std::string(promptId.UTF8String),
            allow == YES);
    }
}

// View management

- (void)setViewFrame:(int)browserId frame:(NSRect)frame {
    [self setViewFrame:browserId frame:frame deviceScaleFactor:0.0];
}

// Applies the effective WasHidden state from Dart intent + window occlusion.
// Hidden pacing is applied immediately, but capture shutdown is debounced so
// a fast tab/workspace sweep does not repeatedly stop and restart Chromium's
// FrameSinkVideoCapturer for every transient selection.
- (void)applyOsrParkStateForBrowserId:(int)browserId
                    debounceIfHiding:(BOOL)debounceIfHiding {
    if ([self isBrowserClosingOrClosed:browserId]) return;
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser =
        (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (!browser || !browser->GetHost()) return;

    const bool activityExempt =
        _osrBackgroundActivityExemptBrowserIds.count(browserId) > 0;
    const bool shouldPark =
        !activityExempt &&
        (_osrHiddenBrowserIds.count(browserId) > 0 || _osrWindowOccluded);
    const bool parked = _osrParkedBrowserIds.count(browserId) > 0;

    CefRefPtr<CefBrowserHost> host = browser->GetHost();
    if (shouldPark) {
        if (parked) {
            _osrPendingParkGenerations.erase(browserId);
            return;
        }
        if (debounceIfHiding && !_osrWindowOccluded) {
            if (_osrPendingParkGenerations.count(browserId) > 0) return;
            _nextOsrParkGeneration += 1;
            if (_nextOsrParkGeneration == 0) {
                _nextOsrParkGeneration = 1;
            }
            const uint64_t generation = _nextOsrParkGeneration;
            _osrPendingParkGenerations[browserId] = generation;
            __weak CEFBridge* weakSelf = self;
            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    kOsrHiddenParkDebounceMs * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                    CEFBridge* strongSelf = weakSelf;
                    if (!strongSelf) return;
                    const auto pending =
                        strongSelf->_osrPendingParkGenerations.find(browserId);
                    if (pending ==
                            strongSelf->_osrPendingParkGenerations.end() ||
                        pending->second != generation) {
                        return;
                    }
                    strongSelf->_osrPendingParkGenerations.erase(pending);
                    [strongSelf applyOsrParkStateForBrowserId:browserId
                                            debounceIfHiding:NO];
                });
            return;
        }
        _osrPendingParkGenerations.erase(browserId);
        _osrParkedBrowserIds.insert(browserId);
        host->WasHidden(true);
    } else {
        _osrPendingParkGenerations.erase(browserId);
        if (!parked) return;
        _osrParkedBrowserIds.erase(browserId);
        host->WasHidden(false);
        host->Invalidate(PET_VIEW);
    }
}

- (void)applyOsrParkStateForBrowserId:(int)browserId {
    [self applyOsrParkStateForBrowserId:browserId debounceIfHiding:YES];
}

- (void)setFramePacing:(int)browserId
              targetFps:(int)targetFps
                visible:(BOOL)visible
backgroundActivityExempt:(BOOL)backgroundActivityExempt {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setFramePacing:browserId
                       targetFps:targetFps
                         visible:visible
        backgroundActivityExempt:backgroundActivityExempt];
        });
        return;
    }
    if ([self isBrowserClosingOrClosed:browserId]) return;

    const int clampedFps = MAX(1, MIN(targetFps, 240));
    // Stash before creation/mapping so CefBrowserSettings and OnAfterCreated
    // can both observe a pacing request that races async CreateBrowser.
    _osrTargetFrameRates[browserId] = clampedFps;
    if (visible) {
        _osrHiddenBrowserIds.erase(browserId);
    } else {
        _osrHiddenBrowserIds.insert(browserId);
    }
    if (backgroundActivityExempt) {
        _osrBackgroundActivityExemptBrowserIds.insert(browserId);
    } else {
        _osrBackgroundActivityExemptBrowserIds.erase(browserId);
    }

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser =
        (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (ShouldLogFpsDebug()) {
        NSLog(@"CEFFps: setFramePacing browserId=%d requestedFps=%d clampedFps=%d cefId=%d isOsr=%d getBrowser=%d",
              browserId, targetFps, clampedFps, cefId,
              (int)(_osrFlutterBrowserIds.find(browserId) !=
                    _osrFlutterBrowserIds.end()),
              browser ? 1 : 0);
    }
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return;  // Native views pace themselves; safe no-op for teardown races.
    }
    if (!browser || !browser->GetHost()) return;

    browser->GetHost()->SetWindowlessFrameRate(clampedFps);
    if (ShouldLogFpsDebug()) {
        NSLog(@"CEFFps: setFramePacing applied browserId=%d clampedFps=%d storedFps=%d",
              browserId, clampedFps,
              browser->GetHost()->GetWindowlessFrameRate());
    }
    [self applyOsrParkStateForBrowserId:browserId];
    if (ShouldLogFrameSync()) {
        NSLog(@"CEFBridge: setFramePacing browserId=%d fps=%d visible=%d exempt=%d occluded=%d",
              browserId, clampedFps, (int)visible,
              (int)backgroundActivityExempt, (int)_osrWindowOccluded);
    }
}

- (void)setWindowOccluded:(BOOL)occluded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setWindowOccluded:occluded];
        });
        return;
    }
    if (_osrWindowOccluded == occluded) return;
    _osrWindowOccluded = occluded;
    for (int browserId : _osrFlutterBrowserIds) {
        [self applyOsrParkStateForBrowserId:browserId
                          debounceIfHiding:!occluded];
    }
    if (ShouldLogFrameSync()) {
        NSLog(@"CEFBridge: setWindowOccluded=%d for %lu OSR browser(s)",
              (int)occluded, (unsigned long)_osrFlutterBrowserIds.size());
    }
}

- (void)setViewFrame:(int)browserId frame:(NSRect)frame deviceScaleFactor:(CGFloat)deviceScaleFactor {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setViewFrame:browserId frame:frame deviceScaleFactor:deviceScaleFactor];
        });
        return;
    }

    if ([self isBrowserClosingOrClosed:browserId]) return;

    auto it = _browserViews.find(browserId);
    if (it == _browserViews.end() || !it->second) return;

    NSView* browserContainer = it->second;
    browserContainer.translatesAutoresizingMaskIntoConstraints = YES;
    browserContainer.autoresizesSubviews = YES;
    browserContainer.wantsLayer = YES;
    browserContainer.layer.masksToBounds = YES;
    auto panelIt = _devToolsPanels.find(browserId);
    auto dividerIt = _devToolsDividers.find(browserId);

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (_osrFlutterBrowserIds.find(browserId) != _osrFlutterBrowserIds.end()) {
        if (!NSEqualRects(browserContainer.frame, frame)) {
            [browserContainer setFrame:frame];
        }
        if (_client && cefId >= 0) {
            CGFloat requestedScale = deviceScaleFactor;
            auto scaleIt = _osrDeviceScaleFactors.find(browserId);
            if ((requestedScale <= 0.0 || !isfinite(requestedScale)) &&
                scaleIt != _osrDeviceScaleFactors.end()) {
                requestedScale = scaleIt->second;
            }
            const CGFloat osrScale = EffectiveDeviceScaleFactor(requestedScale, browserContainer);
            _osrDeviceScaleFactors[browserId] = osrScale;
            if (ShouldLogResizeDebug()) {
                NSLog(@"CEFBridge: CEF_RESIZE_DEBUG setViewFrame browserId=%d requested=%dx%d scale=%.3f frame=%@ bounds=%@",
                      browserId,
                      (int)ceil(MAX(1.0, frame.size.width)),
                      (int)ceil(MAX(1.0, frame.size.height)),
                      osrScale,
                      NSStringFromRect(browserContainer.frame),
                      NSStringFromRect(browserContainer.bounds));
            }
            _client->SetOsrViewSize(cefId,
                                    (int)ceil(MAX(1.0, frame.size.width)),
                                    (int)ceil(MAX(1.0, frame.size.height)),
                                    (float)osrScale);
        }
        if (browser && browser->GetHost()) {
            browser->GetHost()->NotifyScreenInfoChanged();
            browser->GetHost()->WasResized();
            browser->GetHost()->Invalidate(PET_VIEW);
        }
        [self scheduleOsrPoolKickForBrowserId:browserId];
        [self syncDragParticipantForBrowserId:browserId
                                     hostView:browserContainer
                                        frame:frame];
        return;
    }
    NSView* browserView = RetainedBrowserSubviewForContainer(browserContainer);

    if ((ShouldLogFrameSync() || ShouldLogFrameSyncDetail()) &&
        browserView &&
        browserView.superview != browserContainer) {
        NSLog(@"CEFBridge: setViewFrame browserId=%d browserView.superview mismatch container=%@ browserView=%@ superview=%@",
              browserId,
              browserContainer,
              browserView,
              browserView.superview);
    }
    if (browserView && browserView.superview != browserContainer) {
        EnsureBrowserViewAttachedToContainer(
            browserView,
            browserContainer,
            browserId,
            @"setViewFrame");
    }

    const BOOL hasDevToolsPanel = panelIt != _devToolsPanels.end() && panelIt->second;
    NSView* devToolsPanel = hasDevToolsPanel ? panelIt->second : nil;
    ResizableDivider* divider =
        (dividerIt != _devToolsDividers.end()) ? dividerIt->second : nil;
    NSString* dockPos = @"bottom";
    if (hasDevToolsPanel) {
        auto posIt = _devToolsDockPosition.find(browserId);
        dockPos = (posIt != _devToolsDockPosition.end()) ?
            [NSString stringWithUTF8String:posIt->second.c_str()] : @"bottom";
    }

    RunWithoutImplicitLayerActions(^{
    if (!hasDevToolsPanel) {
        // No DevTools: browser takes full frame
        [browserContainer setFrame:frame];
        // Keep the embedded CEF NSView sized to container bounds.
        for (NSView* subview in browserContainer.subviews) {
            subview.frame = browserContainer.bounds;
            subview.translatesAutoresizingMaskIntoConstraints = YES;
            subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        }
        if (browserView && browserView != browserContainer) {
            browserView.frame = browserContainer.bounds;
            browserView.translatesAutoresizingMaskIntoConstraints = YES;
            browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        }
    } else {
        // DevTools docked: maintain split layout with fixed DevTools size
        // Get current DevTools size (respects manual divider resizing)
        CGFloat currentDevToolsSize = [dockPos isEqualToString:@"right"] ?
            devToolsPanel.frame.size.width : devToolsPanel.frame.size.height;
        CGFloat dividerThickness = divider ? 8 : 0;

        // Use current size, but ensure minimums
        CGFloat devToolsSize = MAX(currentDevToolsSize, 200);

        NSRect newBrowserFrame;
        NSRect newDevToolsFrame;
        NSRect newDividerFrame;

        if ([dockPos isEqualToString:@"right"]) {
            // DevTools on right - maintain width
            CGFloat devToolsWidth = MIN(devToolsSize, frame.size.width - 200 - dividerThickness);

            newDevToolsFrame = NSMakeRect(
                frame.origin.x + frame.size.width - devToolsWidth,
                frame.origin.y,
                devToolsWidth,
                frame.size.height
            );

            newDividerFrame = NSMakeRect(
                frame.origin.x + frame.size.width - devToolsWidth - dividerThickness,
                frame.origin.y,
                dividerThickness,
                frame.size.height
            );

            newBrowserFrame = NSMakeRect(
                frame.origin.x,
                frame.origin.y,
                frame.size.width - devToolsWidth - dividerThickness,
                frame.size.height
            );
        } else { // bottom
            // DevTools on bottom - maintain height
            CGFloat devToolsHeight = MIN(devToolsSize, frame.size.height - 200 - dividerThickness);

            newDevToolsFrame = NSMakeRect(
                frame.origin.x,
                frame.origin.y,
                frame.size.width,
                devToolsHeight
            );

            newDividerFrame = NSMakeRect(
                frame.origin.x,
                frame.origin.y + devToolsHeight,
                frame.size.width,
                dividerThickness
            );

            newBrowserFrame = NSMakeRect(
                frame.origin.x,
                frame.origin.y + devToolsHeight + dividerThickness,
                frame.size.width,
                frame.size.height - devToolsHeight - dividerThickness
            );
        }

        [browserContainer setFrame:newBrowserFrame];
        for (NSView* subview in browserContainer.subviews) {
            subview.frame = browserContainer.bounds;
            subview.translatesAutoresizingMaskIntoConstraints = YES;
            subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        }
        if (browserView && browserView != browserContainer) {
            browserView.frame = browserContainer.bounds;
            browserView.translatesAutoresizingMaskIntoConstraints = YES;
            browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        }

        devToolsPanel.autoresizesSubviews = YES;
        devToolsPanel.wantsLayer = YES;
        devToolsPanel.layer.masksToBounds = YES;
        [devToolsPanel setFrame:newDevToolsFrame];
        for (NSView* subview in devToolsPanel.subviews) {
            subview.frame = devToolsPanel.bounds;
            subview.translatesAutoresizingMaskIntoConstraints = YES;
            subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        }
        if (divider) {
            [divider setFrame:newDividerFrame];
        }
    }
    });

    [browserContainer setNeedsLayout:YES];
    [browserContainer layoutSubtreeIfNeeded];

    if (ShouldLogFrameSyncDetail()) {
        NSLog(@"CEFBridge: setViewFrame browserId=%d applied container.frame=%@ bounds=%@ subviews=%lu browserView=%@ frame=%@",
              browserId,
              NSStringFromRect(browserContainer.frame),
              NSStringFromRect(browserContainer.bounds),
              (unsigned long)browserContainer.subviews.count,
              browserView,
              browserView ? NSStringFromRect(browserView.frame) : @"(null)");
        for (NSView* subview in browserContainer.subviews) {
            NSLog(@"CEFBridge: setViewFrame subview=%@ frame=%@ bounds=%@",
                  subview,
                  NSStringFromRect(subview.frame),
                  NSStringFromRect(subview.bounds));
        }
    }
}

// DevTools

- (void)showDevTools:(int)browserId docked:(BOOL)docked position:(NSString *)position {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showDevTools:browserId docked:docked position:position];
        });
        return;
    }

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (!browser) {
        NSLog(@"CEFBridge: No browser found for Flutter ID %d", browserId);
        return;
    }

    // Check if DevTools already exist for this browser
    auto it = _devToolsPanels.find(browserId);
    if (it != _devToolsPanels.end() && it->second) {
        NSLog(@"CEFBridge: DevTools already open for browser %d", browserId);
        return;
    }

    if (CefNativeDevToolsEnabled()) {
        if (browser->GetHost() && browser->GetHost()->HasDevTools()) {
            NSLog(@"CEFBridge: Closing existing native DevTools before re-docking browser %d", browserId);
            browser->GetHost()->CloseDevTools();
        }

        NSLog(@"CEFBridge: Creating native CEF DevTools for browser %d (CEF ID: %d)", browserId, cefId);
        [self createEmbeddedDevToolsBrowser:nil
                                     docked:docked
                                   position:position
                                 forBrowser:browserId];
        return;
    }

    NSLog(@"CEFBridge: Starting embedded DevTools discovery for browser %d (CEF ID: %d)", browserId, cefId);

    NSString* browserMainUrl = @"";
    if (browser->GetMainFrame()) {
        browserMainUrl = NSStringFromCefString(browser->GetMainFrame()->GetURL());
    }
    NSString* cachedTargetId = nil;
    auto cachedIt = _devToolsTargetIdByFlutterBrowserId.find(browserId);
    if (cachedIt != _devToolsTargetIdByFlutterBrowserId.end()) {
        cachedTargetId = [NSString stringWithUTF8String:cachedIt->second.c_str()];
    }

    // Query the remote-debugging endpoint and embed its DevTools frontend. CEF's
    // native ShowDevTools path currently trips a Chromium DCHECK on this build.
    int* debugPortPtr = (int*)dlsym(RTLD_DEFAULT, "g_cefDebugPort");
    int debugPort = (debugPortPtr != nullptr && *debugPortPtr > 0)
        ? *debugPortPtr
        : (_remoteDebuggingPort > 0 ? static_cast<int>(_remoteDebuggingPort) : 9422);
    NSLog(@"CEFBridge: Using debug port: %d (dynamic: %s)", debugPort, debugPortPtr ? "yes" : "no");

    NSString* debugUrl = [NSString stringWithFormat:@"http://localhost:%d/json/list", debugPort];
    NSURL* url = [NSURL URLWithString:debugUrl];
    NSURLSession* session = [NSURLSession sharedSession];

    [[session dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (error || !data) {
            NSLog(@"CEFBridge: Failed to get debug targets: %@", error ?: @"No data");
            return;
        }

        NSError* jsonError = nil;
        id decodedTargets = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![decodedTargets isKindOfClass:[NSArray class]] || [(NSArray*)decodedTargets count] == 0) {
            NSLog(@"CEFBridge: No debug targets found or JSON parse error: %@", jsonError);
            return;
        }
        NSArray* targets = (NSArray*)decodedTargets;

        NSLog(@"CEFBridge: Found %lu debug target(s)", (unsigned long)targets.count);

        NSString* (^normalizeUrl)(id) = ^NSString* (id input) {
            if (![input isKindOfClass:[NSString class]] || [(NSString*)input length] == 0) return @"";
            NSURL* parsed = [NSURL URLWithString:(NSString*)input];
            return parsed.absoluteString ?: (NSString*)input;
        };

        NSDictionary* target = nil;
        NSString* desiredUrl = normalizeUrl(browserMainUrl);

        // 1) Reuse prior target for this browser when still available.
        if (cachedTargetId.length > 0) {
            for (id raw in targets) {
                if (![raw isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary* candidate = (NSDictionary*)raw;
                NSString* candidateId = [candidate[@"id"] isKindOfClass:[NSString class]]
                    ? candidate[@"id"]
                    : nil;
                if (candidateId && [candidateId isEqualToString:cachedTargetId]) {
                    target = candidate;
                    break;
                }
            }
        }

        // 2) Exact URL match for the current browser URL.
        if (!target && desiredUrl.length > 0) {
            for (id raw in targets) {
                if (![raw isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary* candidate = (NSDictionary*)raw;
                NSString* candidateUrl = normalizeUrl(candidate[@"url"]);
                if ([candidateUrl isEqualToString:desiredUrl]) {
                    target = candidate;
                    break;
                }
            }
        }

        // 3) Fallback to first "page" target, avoiding devtools:// entries.
        if (!target) {
            for (id raw in targets) {
                if (![raw isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary* candidate = (NSDictionary*)raw;
                NSString* candidateType = [candidate[@"type"] isKindOfClass:[NSString class]]
                    ? candidate[@"type"]
                    : @"";
                NSString* candidateUrl = [candidate[@"url"] isKindOfClass:[NSString class]]
                    ? candidate[@"url"]
                    : @"";
                if ([candidateType isEqualToString:@"page"] &&
                    ![candidateUrl hasPrefix:@"devtools://"]) {
                    target = candidate;
                    break;
                }
            }
        }

        // 4) Last resort.
        if (!target && [targets[0] isKindOfClass:[NSDictionary class]]) {
            target = targets[0];
        }
        if (!target) {
            NSLog(@"CEFBridge: Unable to select a valid DevTools target");
            return;
        }

        NSString* webSocketDebuggerUrl = [target[@"webSocketDebuggerUrl"] isKindOfClass:[NSString class]]
            ? target[@"webSocketDebuggerUrl"]
            : nil;
        NSString* targetId = [target[@"id"] isKindOfClass:[NSString class]]
            ? target[@"id"]
            : nil;
        NSString* targetTitle = [target[@"title"] isKindOfClass:[NSString class]]
            ? target[@"title"]
            : @"";
        NSString* targetUrl = [target[@"url"] isKindOfClass:[NSString class]]
            ? target[@"url"]
            : @"";

        NSLog(@"CEFBridge: Target selected - id: '%@' title: '%@', url: '%@', ws: '%@' (browserUrl='%@')",
              targetId, targetTitle, targetUrl, webSocketDebuggerUrl, browserMainUrl);

        if (!webSocketDebuggerUrl) {
            NSLog(@"CEFBridge: No webSocketDebuggerUrl in target");
            return;
        }

        NSArray* components = [webSocketDebuggerUrl componentsSeparatedByString:@"/"];
        NSString* pageId = components.count > 0 ? [components lastObject] : nil;
        if (targetId.length > 0) {
            pageId = targetId;
        }
        if (pageId.length == 0) {
            NSLog(@"CEFBridge: Unable to extract DevTools page id");
            return;
        }

        NSLog(@"CEFBridge: Extracted page ID: %@", pageId);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (targetId.length > 0) {
                self->_devToolsTargetIdByFlutterBrowserId[browserId] = [targetId UTF8String];
            }
            [self createEmbeddedDevToolsBrowser:pageId
                                         docked:docked
                                       position:position
                                     forBrowser:browserId];
        });
    }] resume];
}

- (void)createEmbeddedDevToolsBrowser:(NSString*)pageId
                               docked:(BOOL)docked
                             position:(NSString*)position
                           forBrowser:(int)browserId {
    (void)docked;
    const BOOL useNativeDevTools = CefNativeDevToolsEnabled();
    NSString* devToolsUrl = nil;

    if (useNativeDevTools) {
        NSLog(@"CEFBridge: Creating docked native DevTools browser for Flutter browser %d", browserId);
    } else {
        if (pageId.length == 0) {
            NSLog(@"CEFBridge: Cannot create embedded DevTools without a page id");
            return;
        }

        int* debugPortPtr = (int*)dlsym(RTLD_DEFAULT, "g_cefDebugPort");
        int debugPort = (debugPortPtr != nullptr && *debugPortPtr > 0)
            ? *debugPortPtr
            : (_remoteDebuggingPort > 0 ? static_cast<int>(_remoteDebuggingPort) : 9422);

        devToolsUrl = [NSString stringWithFormat:
            @"devtools://devtools/bundled/inspector.html?ws=localhost:%d/devtools/page/%@&panel=elements",
            debugPort, pageId];

        NSLog(@"CEFBridge: Creating embedded remote DevTools browser for page %@", pageId);
        NSLog(@"CEFBridge: DevTools URL: %@", devToolsUrl);
    }

    // Get the browser container view
    auto browserIt = _browserViews.find(browserId);
    if (browserIt == _browserViews.end() || !browserIt->second) {
        NSLog(@"CEFBridge: No browser container view found for browser %d", browserId);
        return;
    }

    NSView* browserContainer = browserIt->second;
    NSView* parentView = browserContainer.superview;

    if (!parentView) {
        NSLog(@"CEFBridge: No parent view for browser container");
        return;
    }

    // Calculate DevTools panel size and position
    CGFloat devToolsHeight = 300;
    CGFloat devToolsWidth = 600;  // Preferred width for right-side positioning
    CGFloat dividerThickness = 8;  // Resizable divider thickness - thicker for visibility

    NSRect browserFrame = browserContainer.frame;
    NSRect devToolsFrame;
    NSRect newBrowserFrame;
    NSRect dividerFrame;
    BOOL isVertical = [position isEqualToString:@"right"];

    if ([position isEqualToString:@"bottom"]) {
        // Clamp DevTools height to available space to avoid negative sizes on small windows.
        devToolsHeight = MIN(devToolsHeight, MAX(200, browserFrame.size.height - 200 - dividerThickness));

        // DevTools at bottom with horizontal divider
        devToolsFrame = NSMakeRect(
            browserFrame.origin.x,
            browserFrame.origin.y,
            browserFrame.size.width,
            devToolsHeight
        );

        dividerFrame = NSMakeRect(
            browserFrame.origin.x,
            browserFrame.origin.y + devToolsHeight,
            browserFrame.size.width,
            dividerThickness
        );

        // Shrink browser to make room for DevTools + divider
        newBrowserFrame = NSMakeRect(
            browserFrame.origin.x,
            browserFrame.origin.y + devToolsHeight + dividerThickness,
            browserFrame.size.width,
            browserFrame.size.height - devToolsHeight - dividerThickness
        );
    } else { // "right"
        // Clamp DevTools width to available space to avoid negative sizes on small windows.
        devToolsWidth = MIN(devToolsWidth, MAX(240, browserFrame.size.width - 200 - dividerThickness));

        // DevTools at right with vertical divider
        devToolsFrame = NSMakeRect(
            browserFrame.origin.x + browserFrame.size.width - devToolsWidth,
            browserFrame.origin.y,
            devToolsWidth,
            browserFrame.size.height
        );

        dividerFrame = NSMakeRect(
            browserFrame.origin.x + browserFrame.size.width - devToolsWidth - dividerThickness,
            browserFrame.origin.y,
            dividerThickness,
            browserFrame.size.height
        );

        // Shrink browser to make room for DevTools + divider
        newBrowserFrame = NSMakeRect(
            browserFrame.origin.x,
            browserFrame.origin.y,
            browserFrame.size.width - devToolsWidth - dividerThickness,
            browserFrame.size.height
        );
    }

    // Resize browser first
    browserContainer.frame = newBrowserFrame;

    // Create resizable divider
    ResizableDivider* divider = [[ResizableDivider alloc] initWithFrame:dividerFrame];
    divider.isVertical = isVertical;
    divider.leftView = browserContainer;
    [parentView addSubview:divider positioned:NSWindowAbove relativeTo:browserContainer];

    // Create container view for DevTools
    NSView* devToolsContainer = [[NSView alloc] initWithFrame:devToolsFrame];
    devToolsContainer.wantsLayer = YES;
    devToolsContainer.layer.masksToBounds = YES;
    devToolsContainer.autoresizesSubviews = YES;
    devToolsContainer.autoresizingMask = NSViewNotSizable;  // Manual layout only

    // Add DevTools container as sibling to browser
    [parentView addSubview:devToolsContainer positioned:NSWindowAbove relativeTo:divider];

    // Link divider to DevTools
    divider.rightView = devToolsContainer;

    // Store DevTools panel, divider, and size
    _devToolsPanels[browserId] = devToolsContainer;
    _devToolsDividers[browserId] = divider;
    _devToolsDockPosition[browserId] = [position isEqualToString:@"right"] ? "right" : "bottom";
    _devToolsSizes[browserId] = isVertical ? devToolsWidth : devToolsHeight;

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
    if (!browser || !browser->GetHost()) {
        NSLog(@"CEFBridge: Failed to create DevTools: no target browser for Flutter browser %d", browserId);
        [devToolsContainer removeFromSuperview];
        [divider removeFromSuperview];
        browserContainer.frame = browserFrame;
        _devToolsPanels.erase(browserId);
        _devToolsDividers.erase(browserId);
        _devToolsDockPosition.erase(browserId);
        _devToolsSizes.erase(browserId);
        return;
    }

    // Create either the opt-in native DevTools browser or the default embedded
    // remote-debugging frontend browser in the docked pane.
    CefWindowInfo windowInfo;
    windowInfo.SetAsChild(
        (__bridge void*)devToolsContainer,
        CefRect(0, 0, devToolsFrame.size.width, devToolsFrame.size.height)
    );

    CefBrowserSettings browserSettings;

    if (!_devToolsClient) {
        _devToolsClient = new DevToolsClient();
    }

    if (useNativeDevTools) {
        browser->GetHost()->ShowDevTools(windowInfo, _devToolsClient, browserSettings, CefPoint());
        NSLog(@"CEFBridge: Native DevTools requested at %@ with resizable divider",
              [position isEqualToString:@"bottom"] ? @"bottom" : @"right");
    } else {
        CefRefPtr<CefBrowser> devToolsBrowser = CefBrowserHost::CreateBrowserSync(
            windowInfo,
            _devToolsClient,
            [devToolsUrl UTF8String],
            browserSettings,
            nullptr,
            _requestContext
        );

        if (devToolsBrowser) {
            _devToolsBrowsers[browserId] = devToolsBrowser;
            NSLog(@"CEFBridge: Embedded remote DevTools browser created at %@ with resizable divider",
                  [position isEqualToString:@"bottom"] ? @"bottom" : @"right");
        } else {
            NSLog(@"CEFBridge: Failed to create embedded remote DevTools browser");
            [devToolsContainer removeFromSuperview];
            [divider removeFromSuperview];
            browserContainer.frame = browserFrame;
            _devToolsPanels.erase(browserId);
            _devToolsDividers.erase(browserId);
            _devToolsDockPosition.erase(browserId);
            _devToolsSizes.erase(browserId);
            return;
        }
    }

    // Notify CEF that browser was resized
    if (browser) {
        browser->GetHost()->WasResized();
    }
}

- (void)hideDevTools:(int)browserId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideDevTools:browserId];
        });
        return;
    }

    auto panelIt = _devToolsPanels.find(browserId);
    if (panelIt == _devToolsPanels.end() || !panelIt->second) {
        // Still close any tracked DevTools browser handle if present.
        [self closeDockedDevToolsForBrowser:browserId restoreBrowserFrame:NO];
        NSLog(@"CEFBridge: No DevTools to hide for browser %d", browserId);
        return;
    }

    NSLog(@"CEFBridge: Closing embedded DevTools for browser %d", browserId);
    [self closeDockedDevToolsForBrowser:browserId restoreBrowserFrame:YES];
    NSLog(@"CEFBridge: Removed docked DevTools panel, divider, and restored browser size");
}

#pragma mark - Appearance

- (void)setPreferredColorScheme:(int)browserId scheme:(nullable NSString *)scheme {
    // Treat nil/NSNull/empty as "clear override".
    if ((id)scheme == [NSNull null] || (scheme && [scheme length] == 0)) {
        scheme = nil;
    }

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    if (!_client) return;
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (!browser) return;

    // Build DevTools params for Emulation.setEmulatedMedia with features.
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    CefRefPtr<CefListValue> features = CefListValue::Create();

    // Empty/unknown scheme => clear override (empty features list).
    if (scheme && [scheme length] > 0) {
        NSString* lowered = [scheme lowercaseString];
        NSString* value = nil;
        if ([lowered isEqualToString:@"dark"]) {
            value = @"dark";
        } else if ([lowered isEqualToString:@"light"]) {
            value = @"light";
        } else if ([lowered isEqualToString:@"no-preference"]) {
            value = @"no-preference";
        }
        if (value) {
            CefRefPtr<CefDictionaryValue> feature = CefDictionaryValue::Create();
            feature->SetString("name", "prefers-color-scheme");
            feature->SetString("value", [value UTF8String]);
            features->SetDictionary(0, feature);
        }
    }

    params->SetList("features", features);
    browser->GetHost()->ExecuteDevToolsMethod(0, "Emulation.setEmulatedMedia", params);
}

// CDP / Logging

- (void)enableNetworkLogging:(int)browserId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self enableNetworkLogging:browserId];
        });
        return;
    }
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser) {
        [self ensureDevToolsObserverForBrowser:browser];
        browser->GetHost()->ExecuteDevToolsMethod(0, "Network.enable", nullptr);
    }
}

- (void)enableConsoleLogging:(int)browserId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self enableConsoleLogging:browserId];
        });
        return;
    }
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser) {
        [self ensureDevToolsObserverForBrowser:browser];
        browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.enable", nullptr);
        browser->GetHost()->ExecuteDevToolsMethod(0, "Log.enable", nullptr);
    }
}

- (void)getResponseBody:(int)browserId
              requestId:(NSString *)requestId
             completion:(void(^)(NSString *, BOOL))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self getResponseBody:browserId requestId:requestId completion:completion];
        });
        return;
    }

    if (!completion || !requestId || requestId.length == 0) {
        if (completion) completion(nil, NO);
        return;
    }

    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (!browser || !browser->GetHost()) {
        completion(nil, NO);
        return;
    }

    [self ensureDevToolsObserverForBrowser:browser];
    // Ensure Network domain is enabled before querying response bodies.
    browser->GetHost()->ExecuteDevToolsMethod(0, "Network.enable", nullptr);

    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("requestId", [requestId UTF8String]);
    int messageId = browser->GetHost()->ExecuteDevToolsMethod(0, "Network.getResponseBody", params);
    if (messageId <= 0) {
        completion(nil, NO);
        return;
    }

    NSString* key = DevToolsRequestKey(cefId, messageId);
    _pendingResponseBodyCallbacks[key] = [completion copy];
}

// Cookies

- (void)clearCookies:(BOOL)incognito {
    CefRefPtr<CefRequestContext> requestContext = incognito
        ? [self sharedIncognitoRequestContext]
        : _requestContext;
    if (!requestContext) return;

    CefRefPtr<CefCookieManager> manager = requestContext->GetCookieManager(nullptr);
    if (manager) {
        manager->DeleteCookies("", "", nullptr);
    }

    if (incognito && _incognitoFlutterBrowserIds.empty()) {
        [self maybeReleaseIncognitoRequestContext];
    }
}

- (void)getCookiesForUrl:(NSString *)url
             incognito:(BOOL)incognito
             completion:(void(^)(NSArray<NSDictionary *> *))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self getCookiesForUrl:url incognito:incognito completion:completion];
        });
        return;
    }

    if (!completion) return;
    CefRefPtr<CefRequestContext> requestContext = incognito
        ? [self sharedIncognitoRequestContext]
        : _requestContext;
    if (!requestContext) {
        completion(@[]);
        return;
    }

    CefRefPtr<CefCookieManager> manager = requestContext->GetCookieManager(nullptr);
    if (!manager) {
        completion(@[]);
        if (incognito && _incognitoFlutterBrowserIds.empty()) {
            [self maybeReleaseIncognitoRequestContext];
        }
        return;
    }

    auto done = std::make_shared<std::atomic_bool>(false);
    __weak CEFBridge* weakSelf = self;
    void (^wrappedCompletion)(NSArray<NSDictionary*>*) = ^(NSArray<NSDictionary*>* cookies) {
        completion(cookies);
        CEFBridge* strongSelf = weakSelf;
        if (incognito && strongSelf && strongSelf->_incognitoFlutterBrowserIds.empty()) {
            [strongSelf maybeReleaseIncognitoRequestContext];
        }
    };
    CefRefPtr<CookieCollectorVisitor> visitor =
        new CookieCollectorVisitor(wrappedCompletion, done);

    const bool hasUrl = (url && [url length] > 0);
    const bool started = hasUrl
        ? manager->VisitUrlCookies([url UTF8String], true, visitor)
        : manager->VisitAllCookies(visitor);

    if (!started) {
        completion(@[]);
        if (incognito && _incognitoFlutterBrowserIds.empty()) {
            [self maybeReleaseIncognitoRequestContext];
        }
        return;
    }

    // Visit callbacks are per-cookie. If there are no matching cookies,
    // some builds never invoke Visit. Resolve to an empty list in that case.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (!done->exchange(true)) {
            wrappedCompletion(@[]);
        }
    });
}

// Downloads

- (void)pauseDownload:(uint32_t)downloadId {
    if (_client) {
        _client->PauseDownload(downloadId);
    }
}

- (void)resumeDownload:(uint32_t)downloadId {
    if (_client) {
        _client->ResumeDownload(downloadId);
    }
}

- (void)cancelDownload:(uint32_t)downloadId {
    if (_client) {
        _client->CancelDownload(downloadId);
    }
}

// Printing

- (void)print:(int)browserId {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser) {
        browser->GetHost()->Print();
    }
}

- (void)printToPdf:(int)browserId
              path:(NSString *)path
        completion:(void(^)(BOOL))completion {
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefId);
    if (browser) {
        CefPdfPrintSettings settings;
        // Use default settings

        class PdfCallback : public CefPdfPrintCallback {
        public:
            void(^completion)(BOOL);

            void OnPdfPrintFinished(const CefString& path, bool ok) override {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) {
                        completion(ok);
                    }
                });
            }

            IMPLEMENT_REFCOUNTING(PdfCallback);
        };

        CefRefPtr<PdfCallback> callback = new PdfCallback();
        callback->completion = completion;

        browser->GetHost()->PrintToPDF([path UTF8String], settings, callback);
    } else if (completion) {
        completion(NO);
    }
}

// Authentication

- (void)provideAuthCredentials:(NSString *)username password:(NSString *)password {
    if (_client) {
        _client->ProvideAuthCredentials([username UTF8String], [password UTF8String]);
    }
}

- (void)cancelAuth {
    if (_client) {
        _client->CancelAuth();
    }
}

// Message loop

static BOOL g_messageLoopLoggedOnce = NO;

- (void)doMessageLoopWork {
    NSDate* now = [NSDate date];
    if (ShouldLogReliabilityDebug() && _lastMessageLoopWorkAt != nil) {
        const NSTimeInterval gapMs =
            [now timeIntervalSinceDate:_lastMessageLoopWorkAt] * 1000.0;
        const double thresholdMs = MAX((double)_maxPumpDelayMs * 2.0, 100.0);
        if (gapMs > thresholdMs) {
            NSLog(@"CEFBridge: message pump gap %.1fms (mode=%ld maxDelayMs=%ld fallbackTimer=%@)",
                  gapMs,
                  (long)_messagePumpMode,
                  (long)_maxPumpDelayMs,
                  _enableMessagePumpFallbackTimer ? @"YES" : @"NO");
        }
    }
    _lastMessageLoopWorkAt = now;
    if (!g_messageLoopLoggedOnce) {
        NSLog(@"CEFBridge: doMessageLoopWork called - message loop is running!");
        g_messageLoopLoggedOnce = YES;
    }
    [self ensureMessagePump];
    [_messagePump doMessageLoopWork];
}

#pragma mark - CEFClientDelegate

- (void)onBrowserCreated:(int)cefBrowserId {
    int flutterBrowserId = -1;
    NSString* mappingSource = @"unknown";
    NSDictionary* pendingMetadata = nil;

    // Prefer mapping based on the created browser's NSView being a descendant of
    // the container NSView we passed to SetAsChild. This is deterministic across
    // multiple engines creating browsers concurrently (FIFO can mis-map).
    NSView* browserView = nil;
    if (_client) {
        CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefBrowserId);
        if (browser && browser->GetHost()) {
            CefWindowHandle handle = browser->GetHost()->GetWindowHandle();
            browserView = (__bridge NSView*)handle;
        }
    }

    if (browserView) {
        for (const auto& pair : _browserViews) {
            const int candidateId = pair.first;
            NSView* containerView = pair.second;
            if (!containerView) continue;

            if (browserView == containerView || [browserView isDescendantOf:containerView]) {
                flutterBrowserId = candidateId;
                mappingSource = @"view";
                break;
            }
        }
    }

    if (flutterBrowserId >= 0) {
        pendingMetadata = [self pendingCreateMetadataForFlutterId:flutterBrowserId];
    }

    if (flutterBrowserId < 0) {
        if (_deterministicCreate) {
            const int solePendingFlutterId = [self solePendingFlutterBrowserIdOrNegativeOne];
            if (solePendingFlutterId >= 0) {
                flutterBrowserId = solePendingFlutterId;
                pendingMetadata = [self pendingCreateMetadataForFlutterId:flutterBrowserId];
                mappingSource = @"single_pending";
            }
        } else if (!_pendingFlutterBrowserIds.empty()) {
            flutterBrowserId = _pendingFlutterBrowserIds.front();
            _pendingFlutterBrowserIds.pop_front();
            pendingMetadata = [self pendingCreateMetadataForFlutterId:flutterBrowserId];
            mappingSource = @"fifo";
        }
    }

    if (flutterBrowserId < 0) {
        if (_deterministicCreate) {
            NSLog(@"CEFBridge: unable to resolve deterministic create mapping for cefId=%d; closing orphan browser",
                  cefBrowserId);
            [self emitDeterministicCreateMappingFailureForCefBrowserId:cefBrowserId
                                                            browserView:browserView];
            if (_client) {
                CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefBrowserId);
                if (browser && browser->GetHost()) {
                    browser->GetHost()->CloseBrowser(true);
                }
            }
            return;
        }

        flutterBrowserId = cefBrowserId;
        mappingSource = @"cefId";
    }

    // If we mapped by view (or otherwise not via pop_front), remove the ID from
    // the pending list so future browsers don't get mis-mapped.
    if (!_deterministicCreate) {
        auto pendingIt = std::find(_pendingFlutterBrowserIds.begin(),
                                   _pendingFlutterBrowserIds.end(),
                                   flutterBrowserId);
        if (pendingIt != _pendingFlutterBrowserIds.end()) {
            _pendingFlutterBrowserIds.erase(pendingIt);
        }
    }

    _flutterToCefBrowserId[flutterBrowserId] = cefBrowserId;
    _cefToFlutterBrowserId[cefBrowserId] = flutterBrowserId;
    if (_client &&
        _osrFrameLeaseConfiguredBrowserIds.find(flutterBrowserId) !=
            _osrFrameLeaseConfiguredBrowserIds.end()) {
        _client->SetAcceleratedFrameLeaseEnabled(
            cefBrowserId,
            _osrFrameLeaseEnabledBrowserIds.find(flutterBrowserId) !=
                _osrFrameLeaseEnabledBrowserIds.end());
    }
    NSString* createRequestId = pendingMetadata[@"createRequestId"];
    if (ShouldLogLifetimeDebug() || ShouldLogFrameSync()) {
        NSLog(@"CEFBridge: Mapped browser (source=%@ requestId=%@) Flutter browserId %d -> CEF browserId %d (browserView=%@)",
              mappingSource,
              createRequestId ?: @"<none>",
              flutterBrowserId,
              cefBrowserId,
              browserView);
    } else {
        NSLog(@"CEFBridge: Mapped Flutter browserId %d -> CEF browserId %d (requestId=%@)",
              flutterBrowserId,
              cefBrowserId,
              createRequestId ?: @"<none>");
    }
    [self emitCreateMappingDiagnosticForFlutterBrowserId:flutterBrowserId
                                           cefBrowserId:cefBrowserId
                                          mappingSource:mappingSource
                                        createRequestId:createRequestId];
    [self clearPendingCreateMetadataForFlutterId:flutterBrowserId];

    // Windowless browsers do not get a real child NSView from CEF. Once the
    // Flutter browser id is mapped to the CEF browser id, replay the queued
    // size and explicitly invalidate the view so CEF schedules the first OSR
    // paint into the registered Flutter texture.
    if (_osrFlutterBrowserIds.find(flutterBrowserId) != _osrFlutterBrowserIds.end()) {
        auto containerIt = _browserViews.find(flutterBrowserId);
        NSView* containerView = containerIt != _browserViews.end() ? containerIt->second : nil;
        CefRefPtr<CefBrowser> browser = _client ? _client->GetBrowser(cefBrowserId) : nullptr;
        if (browser && browser->GetHost()) {
            auto pacingIt = _osrTargetFrameRates.find(flutterBrowserId);
            if (pacingIt != _osrTargetFrameRates.end()) {
                browser->GetHost()->SetWindowlessFrameRate(pacingIt->second);
                if (ShouldLogFpsDebug()) {
                    NSLog(@"CEFFps: OnAfterCreated reapplied browserId=%d cefId=%d targetFps=%d storedFps=%d",
                          flutterBrowserId, cefBrowserId, pacingIt->second,
                          browser->GetHost()->GetWindowlessFrameRate());
                }
            }
            [self applyOsrParkStateForBrowserId:flutterBrowserId];
        }
        if (browser && browser->GetHost() && containerView) {
            const NSRect bounds = containerView.bounds;
            CGFloat osrScale = EffectiveDeviceScaleFactor(0.0, containerView);
            auto scaleIt = _osrDeviceScaleFactors.find(flutterBrowserId);
            if (scaleIt != _osrDeviceScaleFactors.end()) {
                osrScale = EffectiveDeviceScaleFactor(scaleIt->second, containerView);
            }
            _client->SetOsrViewSize(cefBrowserId,
                                    (int)ceil(MAX(1.0, bounds.size.width)),
                                    (int)ceil(MAX(1.0, bounds.size.height)),
                                    (float)osrScale);
            browser->GetHost()->NotifyScreenInfoChanged();
            browser->GetHost()->WasResized();
            browser->GetHost()->Invalidate(PET_VIEW);
            NSLog(@"CEFBridge: primed OSR browser flutterId=%d cefId=%d bounds=%@ scale=%.2f",
                  flutterBrowserId,
                  cefBrowserId,
                  NSStringFromRect(bounds),
                  (double)osrScale);
        } else {
            NSLog(@"CEFBridge: unable to prime OSR browser flutterId=%d cefId=%d browser=%p host=%d container=%@",
                  flutterBrowserId,
                  cefBrowserId,
                  browser.get(),
                  browser && browser->GetHost() ? 1 : 0,
                  containerView);
        }
    }

    // In windowed mode (SetAsChild), ensure the native browser NSView fills the container view
    // and is clipped to the container bounds. Without this, abrupt window resizes can leave the
    // CEF view drawing outside its intended region until the next manual resize.
    auto containerIt = _browserViews.find(flutterBrowserId);
    if (_osrFlutterBrowserIds.find(flutterBrowserId) == _osrFlutterBrowserIds.end() &&
        containerIt != _browserViews.end() && containerIt->second && _client) {
        CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefBrowserId);
        if (browser && browser->GetHost()) {
            const char* allowAccessibility = getenv("CEF_ALLOW_ACCESSIBILITY");
            if (!allowAccessibility || strcmp(allowAccessibility, "0") == 0) {
                browser->GetHost()->SetAccessibilityState(STATE_DISABLED);
            }
            CefWindowHandle handle = browser->GetHost()->GetWindowHandle();
            NSView* browserView = (__bridge NSView*)handle;
            NSView* containerView = containerIt->second;
            if (browserView && containerView) {
                containerView.autoresizesSubviews = YES;
                containerView.wantsLayer = YES;
                containerView.layer.masksToBounds = YES;

                EnsureBrowserViewAttachedToContainer(
                    browserView,
                    containerView,
                    flutterBrowserId,
                    @"onBrowserCreated");
                browserView.frame = containerView.bounds;
                browserView.translatesAutoresizingMaskIntoConstraints = YES;
                browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

                if (ShouldLogFrameSyncDetail()) {
                    NSLog(@"CEFBridge: onBrowserCreated flutterId=%d cefId=%d container.frame=%@ container.bounds=%@ subviews=%lu browserView=%@ superview=%@ browserView.frame=%@",
                          flutterBrowserId,
                          cefBrowserId,
                          NSStringFromRect(containerView.frame),
                          NSStringFromRect(containerView.bounds),
                          (unsigned long)containerView.subviews.count,
                          browserView,
                          browserView.superview,
                          NSStringFromRect(browserView.frame));
                    for (NSView* subview in containerView.subviews) {
                        NSLog(@"CEFBridge: onBrowserCreated subview=%@ frame=%@ bounds=%@",
                              subview,
                              NSStringFromRect(subview.frame),
                              NSStringFromRect(subview.bounds));
                    }
                }
            }
        }
    }

    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onBrowserCreated:flutterBrowserId];
    }

    // If the window was closed before the async CreateBrowser mapping completed,
    // close immediately now to avoid leaking renderer processes.
    if (_pendingFlutterBrowserCloses.find(flutterBrowserId) != _pendingFlutterBrowserCloses.end() && _client) {
        CefRefPtr<CefBrowser> browser = _client->GetBrowser(cefBrowserId);
        if (browser && browser->GetHost()) {
            if (ShouldLogLifetimeDebug()) {
                NSLog(@"CEFBridge: pending close for flutterId=%d; closing newly-created cefId=%d",
                      flutterBrowserId,
                      cefBrowserId);
            }
            [self emitLifecycleDiagnostic:@{
                @"type": @"cef_pending_close_without_mapping_resolved",
                @"browserId": @(flutterBrowserId),
                @"reason": @"late_create",
            }];
            [self closeBrowser:flutterBrowserId];
        }
    }
}

- (void)onBrowserClosed:(int)cefBrowserId {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:cefBrowserId];
    [self cancelPendingContextMenusForBrowserId:flutterBrowserId];
    NSDate* closeStartedAt = _closeStartedAtByBrowserId[@(flutterBrowserId)];
    [self invalidateCloseFallbackTimerForBrowserId:flutterBrowserId];
    if (_pendingFlutterBrowserCloses.erase(flutterBrowserId) > 0) {
        [self emitLifecycleDiagnostic:@{
            @"type": @"cef_pending_close_without_mapping_resolved",
            @"browserId": @(flutterBrowserId),
            @"reason": @"browser_closed",
        }];
    }
    _closingFlutterBrowserIds.erase(flutterBrowserId);
    [_closeStartedAtByBrowserId removeObjectForKey:@(flutterBrowserId)];
    [self clearPendingCreateMetadataForFlutterId:flutterBrowserId];
    _devToolsTargetIdByFlutterBrowserId.erase(flutterBrowserId);
    [self removeDevToolsObserverForCefBrowserId:cefBrowserId];
    _incognitoFlutterBrowserIds.erase(flutterBrowserId);
    _osrFlutterBrowserIds.erase(flutterBrowserId);
    _osrDeviceScaleFactors.erase(flutterBrowserId);
    _osrTargetFrameRates.erase(flutterBrowserId);
    _osrHiddenBrowserIds.erase(flutterBrowserId);
    _osrBackgroundActivityExemptBrowserIds.erase(flutterBrowserId);
    _osrFrameLeaseConfiguredBrowserIds.erase(flutterBrowserId);
    _osrFrameLeaseEnabledBrowserIds.erase(flutterBrowserId);
    _osrParkedBrowserIds.erase(flutterBrowserId);
    _osrPendingParkGenerations.erase(flutterBrowserId);
    _osrPopupVisibleBrowserIds.erase(flutterBrowserId);
    _osrOriginalPopupRects.erase(flutterBrowserId);
    _osrPopupRects.erase(flutterBrowserId);
    _syntheticPinches.erase(flutterBrowserId);
    [_osrCursorsByBrowserId removeObjectForKey:@(flutterBrowserId)];
    if (_activeOsrCursorBrowserId == flutterBrowserId) {
        _activeOsrCursorBrowserId = -1;
    }
    if (_nativeScrollGestureBrowserId == flutterBrowserId) {
        _nativeScrollGestureBrowserId = -1;
        _nativeScrollRemainderX = 0.0;
        _nativeScrollRemainderY = 0.0;
    }
    if (_nativeSwipeGestureBrowserId == flutterBrowserId) {
        _nativeSwipeGestureBrowserId = -1;
        _nativeSwipeAccumulatedX = 0.0;
        _nativeSwipeDirection = 0;
        _nativeSwipeGestureActive = NO;
        _nativeSwipeSuppressMomentum = NO;
    }
    [self removeDragParticipantForBrowserId:flutterBrowserId];
    {
        auto ownerIt = _devToolsOwnerIdByFlutterId.find(flutterBrowserId);
        if (ownerIt != _devToolsOwnerIdByFlutterId.end()) {
            const int ownerBrowserId = ownerIt->second;
            _devToolsFlutterIdByOwnerId.erase(ownerBrowserId);
            _devToolsOwnerIdByFlutterId.erase(ownerIt);
            for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
                if ([delegate respondsToSelector:@selector(onDevToolsClosedForBrowserId:devToolsBrowserId:)]) {
                    [delegate onDevToolsClosedForBrowserId:ownerBrowserId
                                         devToolsBrowserId:flutterBrowserId];
                }
            }
        }
        // Owner closed with DevTools maps already torn down via CloseDevTools.
        _devToolsFlutterIdByOwnerId.erase(flutterBrowserId);
    }
    if (_client) {
        _client->RemoveOsrViewSize(cefBrowserId);
    }
    [self maybeReleaseIncognitoRequestContext];
    if (ShouldLogLifetimeDebug()) {
        NSLog(@"CEFBridge: onBrowserClosed cefId=%d flutterId=%d", cefBrowserId, flutterBrowserId);
    }
    if (ShouldLogReliabilityDebug() && closeStartedAt != nil) {
        NSLog(@"CEFBridge: close completed flutterId=%d cefId=%d closeLatencyMs=%.1f",
              flutterBrowserId,
              cefBrowserId,
              [[NSDate date] timeIntervalSinceDate:closeStartedAt] * 1000.0);
    }
    if ([self isManagedPopupBrowserId:flutterBrowserId]) {
        [self cleanupManagedPopupForBrowserId:flutterBrowserId closeWindow:YES];
        [self emitLifecycleDiagnostic:@{
            @"type": @"cef_managed_popup_closed",
            @"browserId": @(flutterBrowserId),
            @"cefBrowserId": @(cefBrowserId),
        }];
    }
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onBrowserClosed:flutterBrowserId];
    }

    // Ensure any embedded DevTools for this browser are torn down.
    [self closeDockedDevToolsForBrowser:flutterBrowserId restoreBrowserFrame:NO];

    // Cleanup mappings and any associated views/panels without messaging deallocated pointers.
    auto it = _cefToFlutterBrowserId.find(cefBrowserId);
    if (it != _cefToFlutterBrowserId.end()) {
        const int flutterId = it->second;
        auto viewIt = _browserViews.find(flutterId);
        if (viewIt != _browserViews.end() && viewIt->second) {
            [viewIt->second removeFromSuperview];
        }
        _cefToFlutterBrowserId.erase(it);
        _flutterToCefBrowserId.erase(flutterId);
        _browserViews.erase(flutterId);
    }

    if (ShouldLogLifetimeDebug()) {
        NSLog(@"CEFBridge: after onBrowserClosed activeBrowsers=%lu",
              (unsigned long)_flutterToCefBrowserId.size());
    }
}

- (void)onTitleChanged:(int)browserId title:(NSString *)title {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    if ([self isManagedPopupBrowserId:flutterBrowserId]) {
        NSString* windowTitle = title.length > 0 ? title : @"Web Pop-up";
        NSNumber* key = @(flutterBrowserId);
        NSTextField* titleLabel = _managedPopupTitleLabelsByBrowserId[key];
        NSWindow* window = _managedPopupWindowsByBrowserId[key];
        titleLabel.stringValue = windowTitle;
        window.title = windowTitle;
    }
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onTitleChanged:flutterBrowserId title:title];
    }
}

- (void)onUrlChanged:(int)browserId url:(NSString *)url {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    if ([self isManagedPopupBrowserId:flutterBrowserId]) {
        NSString* urlText = url.length > 0 ? url : @"about:blank";
        NSTextField* urlLabel = _managedPopupUrlLabelsByBrowserId[@(flutterBrowserId)];
        urlLabel.stringValue = urlText;
    }
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onUrlChanged:flutterBrowserId url:url];
    }
}

- (void)onLoadEnd:(int)browserId url:(NSString *)url {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onLoadEnd:flutterBrowserId url:url];
    }
}

- (void)onStatusMessage:(int)browserId text:(NSString *)text {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onStatusMessage:flutterBrowserId text:text];
    }
}

- (void)onAudioStateChanged:(int)browserId audible:(BOOL)audible {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onAudioStateChanged:flutterBrowserId audible:audible];
    }
}

- (void)onLoadingStateChanged:(int)browserId
                    isLoading:(BOOL)isLoading
                    canGoBack:(BOOL)canGoBack
                 canGoForward:(BOOL)canGoForward {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onLoadingStateChanged:flutterBrowserId
                              isLoading:isLoading
                              canGoBack:canGoBack
                           canGoForward:canGoForward];
    }
}

- (void)onFindResult:(int)browserId
          identifier:(int)identifier
               count:(int)count
  activeMatchOrdinal:(int)activeMatchOrdinal
         finalUpdate:(BOOL)finalUpdate {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onFindResult:flutterBrowserId
                     identifier:identifier
                          count:count
             activeMatchOrdinal:activeMatchOrdinal
                    finalUpdate:finalUpdate];
    }
}

- (void)onLoadError:(int)browserId
          errorCode:(int)errorCode
          errorText:(NSString *)errorText
                url:(NSString *)url {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onLoadError:flutterBrowserId errorCode:errorCode errorText:errorText url:url];
    }
}

- (void)onLoadProgress:(int)browserId progress:(double)progress {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onLoadProgress:flutterBrowserId progress:progress];
    }
}

- (void)onPopupRequested:(int)browserId details:(NSDictionary *)details {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    NSMutableDictionary* mappedDetails = details ? [details mutableCopy] : [NSMutableDictionary dictionary];
    mappedDetails[@"browserId"] = @(flutterBrowserId);
    mappedDetails[@"openerBrowserId"] = @(flutterBrowserId);
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onPopupRequested:flutterBrowserId details:mappedDetails];
    }
}

- (void)onFaviconChanged:(int)browserId urls:(NSArray<NSString *> *)urls {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onFaviconChanged:flutterBrowserId urls:urls];
    }
}

- (void)onDownloadStarted:(uint32_t)downloadId
                browserId:(int)browserId
                      url:(NSString *)url
                 filename:(NSString *)filename
                 mimeType:(NSString *)mimeType
               totalBytes:(int64_t)totalBytes
                  fullPath:(NSString *)fullPath {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onDownloadStarted:downloadId
                          browserId:flutterBrowserId
                                url:url
                           filename:filename
                           mimeType:mimeType
                         totalBytes:totalBytes
                            fullPath:fullPath];
    }
}

- (void)onDownloadProgress:(uint32_t)downloadId
             receivedBytes:(int64_t)receivedBytes
                totalBytes:(int64_t)totalBytes
                     speed:(int64_t)speed
           percentComplete:(int)percent {
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onDownloadProgress:downloadId
                       receivedBytes:receivedBytes
                          totalBytes:totalBytes
                               speed:speed
                     percentComplete:percent];
    }
}

- (void)onDownloadComplete:(uint32_t)downloadId path:(NSString *)path {
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onDownloadComplete:downloadId path:path];
    }
}

- (void)onDownloadCancelled:(uint32_t)downloadId {
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onDownloadCancelled:downloadId];
    }
}

- (void)onConsoleMessage:(int)browserId
                   level:(int)level
                 message:(NSString *)message
                  source:(NSString *)source
                    line:(int)line {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onConsoleMessage:flutterBrowserId level:level message:message source:source line:line];
    }
}

- (void)onAuthRequired:(int)browserId
               isProxy:(BOOL)isProxy
                  host:(NSString *)host
                 realm:(NSString *)realm {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onAuthRequired:flutterBrowserId isProxy:isProxy host:host realm:realm];
    }
}

- (void)onFocusChanged:(int)browserId focused:(BOOL)focused {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        [delegate onFocusChanged:flutterBrowserId focused:focused];
    }
}

- (BOOL)onCursorChangeForCefBrowserId:(int)cefBrowserId
                                cursor:(NSCursor*)nativeCursor
                                  type:(NSInteger)type {
    if (![NSThread isMainThread]) {
        __block BOOL handled = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            handled = [self onCursorChangeForCefBrowserId:cefBrowserId
                                                    cursor:nativeCursor
                                                      type:type];
        });
        return handled;
    }

    const int flutterBrowserId = [self flutterBrowserIdForCefId:cefBrowserId];
    NSCursor* cursor = CursorForCefType(type, nativeCursor);
    if (_osrFlutterBrowserIds.find(flutterBrowserId) == _osrFlutterBrowserIds.end()) {
        // Preserve the previous direct AppKit behavior for native-view
        // browsers; OSR needs the stored/reapplied path below because Flutter
        // owns the visible surface and updates the cursor during sendEvent:.
        [cursor set];
        return YES;
    }

    _osrCursorsByBrowserId[@(flutterBrowserId)] = cursor;
    if (_activeOsrCursorBrowserId == flutterBrowserId) {
        [cursor set];
    }
    return YES;
}

- (void)onOsrPaintForCefBrowserId:(int)browserId
                              type:(int)type
                            buffer:(const void *)buffer
                             width:(int)width
                            height:(int)height
                        dirtyRect:(CGRect)dirtyRect {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    if (_osrFlutterBrowserIds.find(flutterBrowserId) == _osrFlutterBrowserIds.end()) {
        return;
    }

    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onOsrPaintForBrowserId:type:buffer:width:height:dirtyRect:)]) {
            [delegate onOsrPaintForBrowserId:flutterBrowserId
                                         type:type
                                       buffer:buffer
                                        width:width
                                       height:height
                                    dirtyRect:dirtyRect];
        }
    }
}

- (void)onAcceleratedOsrPaintForCefBrowserId:(int)browserId
                                         type:(int)type
                                    ioSurface:(void *)ioSurface
                                       format:(int)format
                                    dirtyRect:(CGRect)dirtyRect
                                        extra:(NSDictionary *)extra {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    if (_osrFlutterBrowserIds.find(flutterBrowserId) == _osrFlutterBrowserIds.end()) {
        return;
    }

    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onAcceleratedOsrPaintForBrowserId:type:ioSurface:format:dirtyRect:extra:)]) {
            [delegate onAcceleratedOsrPaintForBrowserId:flutterBrowserId
                                                      type:type
                                                 ioSurface:ioSurface
                                                    format:format
                                               dirtyRect:dirtyRect
                                                     extra:extra];
        }
    }
}

#if defined(CEF_ACCELERATED_FRAME_LEASE_API)
- (BOOL)onLeasedAcceleratedOsrFrameForCefBrowserId:(int)browserId
                                               type:(int)type
                                          ioSurface:(void *)ioSurface
                                             format:(int)format
                                          dirtyRect:(CGRect)dirtyRect
                                              extra:(NSDictionary *)extra
                                              lease:(CEFAcceleratedFrameLease *)lease {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    if (_osrFlutterBrowserIds.find(flutterBrowserId) ==
        _osrFlutterBrowserIds.end()) {
        return NO;
    }

    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if (![delegate respondsToSelector:
                @selector(onLeasedAcceleratedOsrFrameForBrowserId:
                              type:ioSurface:format:dirtyRect:extra:lease:)]) {
            continue;
        }
        if ([delegate
                onLeasedAcceleratedOsrFrameForBrowserId:flutterBrowserId
                                                    type:type
                                               ioSurface:ioSurface
                                                  format:format
                                               dirtyRect:dirtyRect
                                                   extra:extra
                                                   lease:lease]) {
            return YES;
        }
    }
    return NO;
}
#endif

- (BOOL)getOsrScreenPointForCefBrowserId:(int)browserId
                                   viewX:(int)viewX
                                   viewY:(int)viewY
                                 screenX:(int*)screenX
                                 screenY:(int*)screenY {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    if (_osrFlutterBrowserIds.find(flutterBrowserId) ==
        _osrFlutterBrowserIds.end()) {
        return NO;
    }
    auto viewIt = _browserViews.find(flutterBrowserId);
    NSView* view = viewIt != _browserViews.end() ? viewIt->second : nil;
    if (!view || !view.window || !screenX || !screenY) return NO;

    // CEF supplies upper-left-origin view DIPs. AppKit view coordinates use a
    // lower-left origin, and macOS GetScreenPoint also expects screen DIPs.
    NSPoint viewPoint = NSMakePoint(viewX, NSHeight(view.bounds) - viewY);
    NSPoint windowPoint = [view convertPoint:viewPoint toView:nil];
    NSPoint screenPoint = [view.window convertRectToScreen:
        NSMakeRect(windowPoint.x, windowPoint.y, 0, 0)].origin;
    *screenX = (int)llround(screenPoint.x);
    *screenY = (int)llround(screenPoint.y);
    if (ShouldLogPopupDebug()) {
        NSLog(@"CEFBridge: GetScreenPoint browserId=%d local=(%d,%d) viewFrame=%@ viewBounds=%@ screen=(%d,%d)",
              flutterBrowserId, viewX, viewY,
              NSStringFromRect(view.frame), NSStringFromRect(view.bounds),
              *screenX, *screenY);
    }
    return YES;
}

- (BOOL)getOsrRootScreenRectForCefBrowserId:(int)browserId
                                          x:(int*)x
                                          y:(int*)y
                                      width:(int*)width
                                     height:(int*)height {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    auto viewIt = _browserViews.find(flutterBrowserId);
    NSView* view = viewIt != _browserViews.end() ? viewIt->second : nil;
    NSWindow* window = view.window;
    NSScreen* screen = window.screen ?: NSScreen.mainScreen;
    if (!window || !screen || !x || !y || !width || !height ||
        window.miniaturized || NSEqualRects(window.frame, screen.frame)) {
        return NO;
    }
    const NSRect frame = window.frame;
    const NSRect screenFrame = screen.frame;
    *x = (int)llround(frame.origin.x);
    *y = (int)llround(screenFrame.size.height - frame.size.height - frame.origin.y);
    *width = MAX(1, (int)llround(frame.size.width));
    *height = MAX(1, (int)llround(frame.size.height));
    if (ShouldLogPopupDebug()) {
        NSLog(@"CEFBridge: GetRootScreenRect browserId=%d rect=(%d,%d %dx%d) browserFrame=%@",
              flutterBrowserId, *x, *y, *width, *height,
              NSStringFromRect(view.frame));
    }
    return YES;
}

- (void)onOsrPopupShowForCefBrowserId:(int)browserId show:(BOOL)show {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    if (_osrFlutterBrowserIds.find(flutterBrowserId) == _osrFlutterBrowserIds.end()) {
        return;
    }
    if (show) {
        _osrPopupVisibleBrowserIds.insert(flutterBrowserId);
    } else {
        _osrPopupVisibleBrowserIds.erase(flutterBrowserId);
        _osrOriginalPopupRects.erase(flutterBrowserId);
        _osrPopupRects.erase(flutterBrowserId);
    }
    if (ShouldLogPopupDebug()) {
        auto viewIt = _browserViews.find(flutterBrowserId);
        NSView* view = viewIt != _browserViews.end() ? viewIt->second : nil;
        NSLog(@"CEFBridge: OnPopupShow browserId=%d show=%d viewFrame=%@ viewBounds=%@",
              flutterBrowserId, (int)show,
              view ? NSStringFromRect(view.frame) : @"(null)",
              view ? NSStringFromRect(view.bounds) : @"(null)");
    }
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onOsrPopupShowForBrowserId:show:)]) {
            [delegate onOsrPopupShowForBrowserId:flutterBrowserId show:show];
        }
    }
}

- (void)onOsrPopupSizeForCefBrowserId:(int)browserId rect:(CGRect)rect {
    const int flutterBrowserId = [self flutterBrowserIdForCefId:browserId];
    if (_osrFlutterBrowserIds.find(flutterBrowserId) == _osrFlutterBrowserIds.end()) {
        return;
    }
    CGRect popupRect = rect;
    auto viewIt = _browserViews.find(flutterBrowserId);
    NSView* view = viewIt != _browserViews.end() ? viewIt->second : nil;
    const CGFloat viewWidth = view ? NSWidth(view.bounds) : 0;
    const CGFloat viewHeight = view ? NSHeight(view.bounds) : 0;
    if (popupRect.origin.x < 0) popupRect.origin.x = 0;
    if (popupRect.origin.y < 0) popupRect.origin.y = 0;
    if (viewWidth > 0 && CGRectGetMaxX(popupRect) > viewWidth) {
        popupRect.origin.x = viewWidth - popupRect.size.width;
    }
    if (viewHeight > 0 && CGRectGetMaxY(popupRect) > viewHeight) {
        popupRect.origin.y = viewHeight - popupRect.size.height;
    }
    if (popupRect.origin.x < 0) popupRect.origin.x = 0;
    if (popupRect.origin.y < 0) popupRect.origin.y = 0;
    _osrOriginalPopupRects[flutterBrowserId] = rect;
    _osrPopupRects[flutterBrowserId] = popupRect;
    if (ShouldLogPopupDebug()) {
        NSLog(@"CEFBridge: OnPopupSize browserId=%d original=%@ localComposite=%@ viewBounds=%@",
              flutterBrowserId, NSStringFromRect(rect),
              NSStringFromRect(popupRect),
              view ? NSStringFromRect(view.bounds) : @"(null)");
    }
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onOsrPopupSizeForBrowserId:rect:)]) {
            [delegate onOsrPopupSizeForBrowserId:flutterBrowserId rect:popupRect];
        }
    }
}

- (void)onTooltipForCefBrowserId:(int)cefBrowserId text:(NSString*)text {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) return;
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onTooltipForBrowserId:text:)]) {
            [delegate onTooltipForBrowserId:browserId text:text ?: @""];
        }
    }
}

- (void)onJsDialogForCefBrowserId:(int)cefBrowserId
                       callbackId:(int)callbackId
                              kind:(NSString*)kind
                           message:(NSString*)message
                     defaultPrompt:(NSString*)defaultPrompt {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) return;
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onJsDialogForBrowserId:callbackId:kind:message:defaultPrompt:)]) {
            [delegate onJsDialogForBrowserId:browserId
                                  callbackId:callbackId
                                         kind:kind
                                      message:message
                                defaultPrompt:defaultPrompt];
        }
    }
}

- (void)onPermissionPromptForCefBrowserId:(int)cefBrowserId
                                  promptId:(NSString*)promptId
                                     origin:(NSString*)origin
                                permissions:(NSArray<NSString*>*)permissions {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    if (browserId < 0) return;
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onPermissionPromptForBrowserId:promptId:origin:permissions:)]) {
            [delegate onPermissionPromptForBrowserId:browserId
                                            promptId:promptId ?: @""
                                               origin:origin ?: @""
                                          permissions:permissions ?: @[]];
        }
    }
}

- (void)onFullscreenModeChangeForCefBrowserId:(int)cefBrowserId
                                     fullscreen:(BOOL)fullscreen {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) return;
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onFullscreenModeChangeForBrowserId:fullscreen:)]) {
            [delegate onFullscreenModeChangeForBrowserId:browserId fullscreen:fullscreen];
        }
    }
}

- (void)onImeCompositionRangeChangedForCefBrowserId:(int)cefBrowserId
                                           caretRect:(CGRect)caretRect {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) return;
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onImeCompositionRangeChangedForBrowserId:caretRect:)]) {
            [delegate onImeCompositionRangeChangedForBrowserId:browserId caretRect:caretRect];
        }
    }
}

- (void)onTextInputStateChangedForCefBrowserId:(int)cefBrowserId
                                       editable:(BOOL)editable {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) return;
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onTextInputStateChangedForBrowserId:editable:)]) {
            [delegate onTextInputStateChangedForBrowserId:browserId editable:editable];
        }
    }
}

#pragma mark - OSR context menu

- (void)onResetDialogStateForCefBrowserId:(int)cefBrowserId {
    [self cancelPendingContextMenusForBrowserId:
        [self flutterBrowserIdForCefId:cefBrowserId]];
}

- (void)resolveContextMenu:(int)browserId
                    menuId:(int)menuId
                 commandId:(int)commandId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resolveContextMenu:browserId menuId:menuId commandId:commandId];
        });
        return;
    }
    auto callbackIt = _pendingContextMenuCallbacks.find(menuId);
    auto browserIt = _pendingContextMenuBrowserIds.find(menuId);
    if (callbackIt == _pendingContextMenuCallbacks.end() ||
        browserIt == _pendingContextMenuBrowserIds.end() ||
        browserIt->second != browserId) {
        return;
    }
    CefRefPtr<CefRunContextMenuCallback> callback = callbackIt->second;
    _pendingContextMenuCallbacks.erase(callbackIt);
    _pendingContextMenuBrowserIds.erase(browserIt);
    if (callback) callback->Continue(commandId, EVENTFLAG_NONE);
}

- (void)cancelContextMenu:(int)browserId menuId:(int)menuId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cancelContextMenu:browserId menuId:menuId];
        });
        return;
    }
    auto callbackIt = _pendingContextMenuCallbacks.find(menuId);
    auto browserIt = _pendingContextMenuBrowserIds.find(menuId);
    if (callbackIt == _pendingContextMenuCallbacks.end() ||
        browserIt == _pendingContextMenuBrowserIds.end() ||
        browserIt->second != browserId) {
        return;
    }
    CefRefPtr<CefRunContextMenuCallback> callback = callbackIt->second;
    _pendingContextMenuCallbacks.erase(callbackIt);
    _pendingContextMenuBrowserIds.erase(browserIt);
    if (callback) callback->Cancel();
}

- (void)cancelPendingContextMenusForBrowserId:(int)browserId {
    std::vector<int> menuIds;
    for (const auto& entry : _pendingContextMenuBrowserIds) {
        if (entry.second == browserId) menuIds.push_back(entry.first);
    }
    for (int menuId : menuIds) {
        [self cancelContextMenu:browserId menuId:menuId];
    }
}

- (void)cancelAllPendingContextMenus {
    std::vector<std::pair<int, int>> pendingMenus;
    for (const auto& entry : _pendingContextMenuBrowserIds) {
        pendingMenus.push_back(entry);
    }
    for (const auto& entry : pendingMenus) {
        [self cancelContextMenu:entry.second menuId:entry.first];
    }
}

- (BOOL)onOsrRunContextMenuForCefBrowserId:(int)cefBrowserId
                                    params:(CefRefPtr<CefContextMenuParams>)params
                                     model:(CefRefPtr<CefMenuModel>)model
                                  callback:(CefRefPtr<CefRunContextMenuCallback>)callback {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return NO;  // Native-view browsers keep CEF's default menu runner.
    }
    if (!callback || !model || model->GetCount() == 0) {
        if (callback) callback->Cancel();
        return YES;
    }

    [self cancelPendingContextMenusForBrowserId:browserId];
    const int menuId = ++_nextContextMenuId;
    _pendingContextMenuCallbacks[menuId] = callback;
    _pendingContextMenuBrowserIds[menuId] = browserId;
    const int x = params ? params->GetXCoord() : 0;
    const int y = params ? params->GetYCoord() : 0;
    NSArray<NSDictionary<NSString*, id>*>* items = SerializeCefMenuModel(model);
    BOOL emitted = NO;
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onContextMenuForBrowserId:menuId:x:y:items:)]) {
            emitted = YES;
            [delegate onContextMenuForBrowserId:browserId
                                         menuId:menuId
                                               x:x
                                               y:y
                                           items:items];
        }
    }
    if (!emitted) {
        [self cancelContextMenu:browserId menuId:menuId];
    }
    return YES;
}

- (void)onInspectElementRequestedForCefBrowserId:(int)cefBrowserId
                                               x:(int)x
                                               y:(int)y {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onInspectElementRequestedForBrowserId:x:y:)]) {
            [delegate onInspectElementRequestedForBrowserId:browserId x:x y:y];
        }
    }
}

- (void)onDevToolsShortcutForCefBrowserId:(int)cefBrowserId {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    for (id<CEFBridgeDelegate> delegate in _delegates.allObjects) {
        if ([delegate respondsToSelector:@selector(onDevToolsShortcutForBrowserId:)]) {
            [delegate onDevToolsShortcutForBrowserId:browserId];
        }
    }
}

#pragma mark - Windowless DevTools

// Creates a windowless DevTools browser for an OSR page browser, rendered
// through the same client/texture pipeline (spec 016 US4, research D6). The
// caller (plugin) has already registered the texture and container view under
// |devToolsBrowserId|.
- (BOOL)openWindowlessDevToolsForBrowserId:(int)browserId
                         devToolsBrowserId:(int)devToolsBrowserId
                                parentView:(NSView*)parentView
                                     frame:(NSRect)frame
                             renderBackend:(NSString*)renderBackend
                                  inspectX:(int)inspectX
                                  inspectY:(int)inspectY {
    if (![NSThread isMainThread]) {
        NSLog(@"CEFBridge: openWindowlessDevTools must run on the main thread");
        return NO;
    }
    CefRefPtr<CefBrowser> owner = [self osrBrowserForFlutterId:browserId];
    if (!owner || !owner->GetHost()) {
        NSLog(@"CEFBridge: openWindowlessDevTools: no OSR owner browser %d", browserId);
        return NO;
    }
    if (_devToolsFlutterIdByOwnerId.count(browserId) > 0) {
        NSLog(@"CEFBridge: DevTools already open for browser %d", browserId);
        return NO;
    }
    if (owner->GetHost()->HasDevTools()) {
        owner->GetHost()->CloseDevTools();
    }

    const CGFloat osrScale = _osrDeviceScaleFactors.count(browserId)
        ? _osrDeviceScaleFactors[browserId]
        : 1.0;
    _client->QueuePendingOsrViewSize((int)ceil(MAX(1.0, frame.size.width)),
                                     (int)ceil(MAX(1.0, frame.size.height)),
                                     (float)osrScale);

    _browserViews[devToolsBrowserId] = parentView;
    _osrFlutterBrowserIds.insert(devToolsBrowserId);
    _osrDeviceScaleFactors[devToolsBrowserId] = osrScale;
    auto pacingIt = _osrTargetFrameRates.find(browserId);
    if (pacingIt != _osrTargetFrameRates.end()) {
        _osrTargetFrameRates[devToolsBrowserId] = pacingIt->second;
    }
    [self recordPendingCreateMetadataForFlutterId:devToolsBrowserId
                                  createRequestId:[NSString stringWithFormat:@"devtools_%d", devToolsBrowserId]
                                        incognito:NO
                                           queued:NO];
    if (!_deterministicCreate) {
        _pendingFlutterBrowserIds.push_back(devToolsBrowserId);
    }
    _devToolsFlutterIdByOwnerId[browserId] = devToolsBrowserId;
    _devToolsOwnerIdByFlutterId[devToolsBrowserId] = browserId;

    CefWindowInfo windowInfo;
    windowInfo.SetAsWindowless(nullptr);
    windowInfo.shared_texture_enabled =
        [renderBackend isEqualToString:@"acceleratedOsrTexture"];

    CefBrowserSettings settings;
    auto devPacingIt = _osrTargetFrameRates.find(devToolsBrowserId);
    settings.windowless_frame_rate =
        devPacingIt != _osrTargetFrameRates.end() ? devPacingIt->second : 60;
    settings.background_color = CefColorSetARGB(255, 30, 30, 30);

    const CefPoint inspectAt =
        (inspectX >= 0 && inspectY >= 0) ? CefPoint(inspectX, inspectY) : CefPoint();
    owner->GetHost()->ShowDevTools(windowInfo, _client, settings, inspectAt);
    NSLog(@"CEFBridge: windowless DevTools requested owner=%d devtools=%d shared=%d",
          browserId, devToolsBrowserId, (int)windowInfo.shared_texture_enabled);
    return YES;
}

- (int)allocateDevToolsFlutterBrowserId {
    return _nextDevToolsFlutterBrowserId++;
}

- (int)devToolsFlutterBrowserIdForOwner:(int)browserId {
    auto it = _devToolsFlutterIdByOwnerId.find(browserId);
    return it != _devToolsFlutterIdByOwnerId.end() ? it->second : -1;
}

- (int)devToolsOwnerForFlutterBrowserId:(int)browserId {
    auto it = _devToolsOwnerIdByFlutterId.find(browserId);
    return it != _devToolsOwnerIdByFlutterId.end() ? it->second : -1;
}

- (void)closeWindowlessDevToolsForBrowserId:(int)browserId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self closeWindowlessDevToolsForBrowserId:browserId];
        });
        return;
    }
    if (_devToolsFlutterIdByOwnerId.count(browserId) == 0) return;
    CefRefPtr<CefBrowser> owner = [self osrBrowserForFlutterId:browserId];
    if (owner && owner->GetHost() && owner->GetHost()->HasDevTools()) {
        owner->GetHost()->CloseDevTools();
    }
}

#pragma mark - OSR drag and drop

static NSDragOperation NSDragOperationFromCefMask(int cefOps) {
    // cef_drag_operations_mask_t and NSDragOperation share bit values for
    // copy/link/generic/private/move/delete.
    return (NSDragOperation)(cefOps & 0x3F);
}

static CefBrowserHost::DragOperationsMask CefDragMaskFromNSDragOperation(
    NSDragOperation operation) {
    return static_cast<CefBrowserHost::DragOperationsMask>(
        ((unsigned long)operation) & 0x3F);
}

- (CefRefPtr<CefBrowser>)osrBrowserForFlutterId:(int)browserId {
    if (_osrFlutterBrowserIds.find(browserId) == _osrFlutterBrowserIds.end()) {
        return nullptr;
    }
    int cefId = [self cefBrowserIdForFlutterId:browserId];
    return (_client && cefId >= 0) ? _client->GetBrowser(cefId) : nullptr;
}

// Debounced viz-capture-pool rebuild after a resize settles (env-gated:
// CEF_RESIZE_POOL_KICK). Rapid resizes can leave one of the capturer's ~4
// pooled IOSurfaces poisoned (delivered full-content per metadata, but holding
// stale bytes) — it then re-delivers as a diagonal-shred frame every pool
// cycle until the pool is rebuilt. Parking and immediately unparking the
// browser (WasHidden true/false) stops and restarts the FrameSinkVideoCapturer,
// which allocates a fresh pool and evicts the poisoned slot.
static std::map<int, uint64_t> g_osrPoolKickGeneration;  // main thread only

- (void)scheduleOsrPoolKickForBrowserId:(int)browserId {
    static BOOL kickEnabled = NO;
    static dispatch_once_t kickOnce;
    dispatch_once(&kickOnce, ^{
        const char* v = getenv("CEF_RESIZE_POOL_KICK");
        kickEnabled = v && v[0] != '\0' && strcmp(v, "0") != 0;
    });
    if (!kickEnabled) return;

    const uint64_t generation = ++g_osrPoolKickGeneration[browserId];
    __weak CEFBridge* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CEFBridge* strongSelf = weakSelf;
        if (!strongSelf) return;
        // Debounce: only the last scheduled kick after the final resize runs.
        auto it = g_osrPoolKickGeneration.find(browserId);
        if (it == g_osrPoolKickGeneration.end() || it->second != generation) {
            return;
        }
        // Never toggle a parked browser: the kick would leave it unparked
        // (WasHidden(false)) against the park bookkeeping's intent.
        if (strongSelf->_osrParkedBrowserIds.count(browserId) > 0) return;
        CefRefPtr<CefBrowser> browser =
            [strongSelf browserForInputDispatch:browserId];
        if (!browser || !browser->GetHost()) return;
        if (ShouldLogResizeDebug()) {
            NSLog(@"CEFBridge: CEF_RESIZE_POOL_KICK restarting capturer browserId=%d", browserId);
        }
        browser->GetHost()->WasHidden(true);
        browser->GetHost()->WasHidden(false);
        browser->GetHost()->Invalidate(PET_VIEW);
    });
}

- (void)syncDragParticipantForBrowserId:(int)browserId
                               hostView:(NSView*)hostView
                                  frame:(NSRect)frame {
    if (!hostView) return;
    // |frame| is expressed in the Flutter host view's (flipped) coordinate
    // space — the same space the OSR container's own frame lives in — so the
    // participant must be the container's SIBLING, not its child.
    NSView* parentView = hostView.superview ?: hostView;
    CefDragParticipantView* participant = _dragParticipants[@(browserId)];
    if (!participant) {
        participant = [[CefDragParticipantView alloc] initWithBrowserId:browserId
                                                               delegate:self];
        _dragParticipants[@(browserId)] = participant;
    }
    if (participant.superview != parentView) {
        [participant removeFromSuperview];
        [parentView addSubview:participant
                    positioned:NSWindowAbove
                    relativeTo:(hostView.superview ? hostView : nil)];
    }
    if (!NSEqualRects(participant.frame, frame)) {
        participant.frame = frame;
    }
}

- (void)removeDragParticipantForBrowserId:(int)browserId {
    CefDragParticipantView* participant = _dragParticipants[@(browserId)];
    if (!participant) return;
    [participant abandonSession];
    [participant removeFromSuperview];
    [_dragParticipants removeObjectForKey:@(browserId)];
    _outboundDragData.erase(browserId);
}

// The participant is flipped and exactly overlays the browser rect, so local
// points ARE browser-view coordinates (top-left origin DIPs).
static NSPoint BrowserPointFromParticipantPoint(CefDragParticipantView* participant,
                                                NSPoint localPoint) {
    (void)participant;
    return localPoint;
}

- (BOOL)onOsrStartDraggingForCefBrowserId:(int)cefBrowserId
                                 dragData:(CefRefPtr<CefDragData>)dragData
                               allowedOps:(int)allowedOps
                                        x:(int)x
                                        y:(int)y {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    CefDragParticipantView* participant = _dragParticipants[@(browserId)];
    if (!participant || !participant.window || !dragData) {
        return NO;  // CEF cancels the drag.
    }
    if (participant.hasActiveSession) {
        return NO;
    }

    NSMutableArray<NSDraggingItem*>* items = [NSMutableArray array];
    const NSPoint localPoint = NSMakePoint(x, y);  // participant is flipped
    const CGFloat backingScale = _osrDeviceScaleFactors.count(browserId)
        ? MAX(1.0, _osrDeviceScaleFactors[browserId])
        : MAX(1.0, participant.window.backingScaleFactor);

    // Drag image from CEF when available.
    NSImage* dragImage = nil;
    NSPoint dragImageHotspot = NSZeroPoint;
    int dragImagePixelWidth = 0;
    int dragImagePixelHeight = 0;
    CefRefPtr<CefImage> image = dragData->GetImage();
    if (image && !image->IsEmpty()) {
        CefRefPtr<CefBinaryValue> png =
            image->GetAsPNG((float)backingScale, true,
                            dragImagePixelWidth, dragImagePixelHeight);
        if (png && png->GetSize() > 0) {
            NSMutableData* pngData = [NSMutableData dataWithLength:png->GetSize()];
            png->GetData(pngData.mutableBytes, png->GetSize(), 0);
            dragImage = [[NSImage alloc] initWithData:pngData];
            if (dragImage && dragImagePixelWidth > 0 && dragImagePixelHeight > 0) {
                dragImage.size = NSMakeSize(dragImagePixelWidth / backingScale,
                                             dragImagePixelHeight / backingScale);
                const CefPoint hotspot = dragData->GetImageHotspot();
                dragImageHotspot = NSMakePoint(hotspot.x / backingScale,
                                                hotspot.y / backingScale);
                if (NSEqualPoints(dragImageHotspot, NSZeroPoint)) {
                    dragImageHotspot = NSMakePoint(dragImage.size.width / 2,
                                                    dragImage.size.height / 2);
                }
            }
        }
    }

    const size_t promisedFileSize = dragData->IsFile()
        ? dragData->GetFileContents(nullptr)
        : 0;

    NSPasteboardItem* pasteboardItem = [[NSPasteboardItem alloc] init];
    BOOL hasPayload = NO;
    if (dragData->IsLink()) {
        NSString* url = [NSString stringWithUTF8String:
            dragData->GetLinkURL().ToString().c_str()] ?: @"";
        NSString* title = [NSString stringWithUTF8String:
            dragData->GetLinkTitle().ToString().c_str()] ?: @"";
        if (url.length > 0) {
            [pasteboardItem setString:url forType:NSPasteboardTypeURL];
            [pasteboardItem setString:url forType:NSPasteboardTypeString];
            if (title.length > 0) {
                [pasteboardItem setString:title
                                  forType:@"public.url-name"];
            }
            hasPayload = YES;
        }
    }
    if (dragData->IsFragment()) {
        NSString* text = [NSString stringWithUTF8String:
            dragData->GetFragmentText().ToString().c_str()] ?: @"";
        NSString* html = [NSString stringWithUTF8String:
            dragData->GetFragmentHtml().ToString().c_str()] ?: @"";
        if (text.length > 0) {
            [pasteboardItem setString:text forType:NSPasteboardTypeString];
            hasPayload = YES;
        }
        if (html.length > 0) {
            [pasteboardItem setString:html forType:NSPasteboardTypeHTML];
            hasPayload = YES;
        }
    }
    if (hasPayload && promisedFileSize == 0) {
        NSDraggingItem* item =
            [[NSDraggingItem alloc] initWithPasteboardWriter:pasteboardItem];
        const NSSize imageSize =
            dragImage ? dragImage.size : NSMakeSize(64, 48);
        const NSPoint hotspot = dragImage
            ? dragImageHotspot
            : NSMakePoint(imageSize.width / 2, imageSize.height / 2);
        NSRect imageFrame = NSMakeRect(localPoint.x - hotspot.x,
                                       localPoint.y - hotspot.y,
                                       imageSize.width,
                                       imageSize.height);
        [item setDraggingFrame:imageFrame contents:dragImage];
        [items addObject:item];
        if (ShouldLogDragDebug()) {
            NSLog(@"CEFDrag: StartDragging browserId=%d x=%d y=%d allowedOps=0x%x imagePixels=%dx%d hotspot=%@ frame=%@",
                  browserId, x, y, allowedOps, dragImagePixelWidth,
                  dragImagePixelHeight, NSStringFromPoint(hotspot),
                  NSStringFromRect(imageFrame));
        }
    }

    // File payload (dragged image/file) via a file promise fulfilled from
    // CefDragData::GetFileContents at drop time.
    if (promisedFileSize > 0) {
        NSString* fileName = [NSString stringWithUTF8String:
            dragData->GetFileName().ToString().c_str()] ?: @"download";
        fileName = fileName.lastPathComponent;
        if (fileName.length == 0) fileName = @"download";
        NSString* extension = fileName.pathExtension.lowercaseString;
        NSString* typeIdentifier = @"public.data";
        if (extension.length > 0) {
            if (@available(macOS 11.0, *)) {
                UTType* type = [UTType typeWithFilenameExtension:extension];
                if (type) typeIdentifier = type.identifier;
            }
        }
        participant.promiseFileName = fileName;
        NSFilePromiseProvider* promise =
            [[NSFilePromiseProvider alloc] initWithFileType:typeIdentifier
                                                   delegate:participant];
        NSDraggingItem* item =
            [[NSDraggingItem alloc] initWithPasteboardWriter:promise];
        const NSSize imageSize =
            dragImage ? dragImage.size : NSMakeSize(64, 64);
        const NSPoint hotspot = dragImage
            ? dragImageHotspot
            : NSMakePoint(imageSize.width / 2, imageSize.height / 2);
        NSRect imageFrame = NSMakeRect(localPoint.x - hotspot.x,
                                       localPoint.y - hotspot.y,
                                       imageSize.width,
                                       imageSize.height);
        NSImage* fileImage = dragImage;
        if (!fileImage) {
            fileImage = [[NSWorkspace sharedWorkspace] iconForFileType:extension ?: @""];
        }
        [item setDraggingFrame:imageFrame contents:fileImage];
        [items addObject:item];
        if (ShouldLogDragDebug()) {
            NSLog(@"CEFDrag: StartDragging browserId=%d x=%d y=%d allowedOps=0x%x imagePixels=%dx%d hotspot=%@ frame=%@ promisedBytes=%zu fileType=%@",
                  browserId, x, y, allowedOps, dragImagePixelWidth,
                  dragImagePixelHeight, NSStringFromPoint(hotspot),
                  NSStringFromRect(imageFrame), promisedFileSize,
                  typeIdentifier);
        }
    }

    if (items.count == 0) {
        return NO;
    }

    // beginDraggingSessionWithItems:event:source: requires the original
    // mouse-down event, not the later mouse-dragged/current platform-channel
    // event. Validate the retained event against this browser participant so
    // another window/browser can never donate its click.
    NSEvent* event = g_cefLastLeftMouseDownEvent;
    if (event && event.window == participant.window) {
        const NSPoint mouseDownPoint =
            [participant convertPoint:event.locationInWindow fromView:nil];
        if (!NSPointInRect(mouseDownPoint, participant.bounds) ||
            ([NSEvent pressedMouseButtons] & 1) == 0) {
            event = nil;
        }
    } else {
        event = nil;
    }
    if (!event) {
        // Defensive fallback for embedders that install the CEF App protocol
        // after the initiating click. Preserve AppKit's required event type;
        // a synthetic dragged event is rejected before a session starts.
        NSEvent* currentEvent = [NSApp currentEvent];
        const NSPoint windowPoint = [participant convertPoint:localPoint toView:nil];
        event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                   location:windowPoint
                              modifierFlags:currentEvent ? currentEvent.modifierFlags : 0
                                  timestamp:currentEvent
                                                ? currentEvent.timestamp
                                                : [[NSProcessInfo processInfo] systemUptime]
                               windowNumber:participant.window.windowNumber
                                    context:nil
                                eventNumber:currentEvent ? currentEvent.eventNumber : 0
                                 clickCount:1
                                   pressure:1.0];
    }
    if (!event) {
        return NO;
    }

    participant.sourceOperationMask = NSDragOperationFromCefMask(allowedOps);
    if (promisedFileSize > 0) {
        // Materializing a file in another app is always a copy operation.
        participant.sourceOperationMask |= NSDragOperationCopy;
    }
    participant.currentCefOperation = NSDragOperationCopy;
    _outboundDragData[browserId] = dragData;
    if (![participant beginDragSessionWithItems:items event:event]) {
        participant.promiseFileName = nil;
        _outboundDragData.erase(browserId);
        return NO;
    }
    return YES;
}

- (void)onOsrUpdateDragCursorForCefBrowserId:(int)cefBrowserId
                                   operation:(int)operation {
    const int browserId = [self flutterBrowserIdForCefId:cefBrowserId];
    CefDragParticipantView* participant = _dragParticipants[@(browserId)];
    participant.currentCefOperation = NSDragOperationFromCefMask(operation);
}

#pragma mark - CefDragParticipantViewDelegate

- (void)dragParticipantSessionEndedAtScreenPoint:(NSPoint)screenPoint
                                       operation:(NSDragOperation)operation
                                       browserId:(int)browserId {
    CefDragParticipantView* participant = _dragParticipants[@(browserId)];
    const BOOL filePromisePending =
        participant.promiseFileName.length > 0 && operation != NSDragOperationNone;
    CefRefPtr<CefBrowser> browser = [self osrBrowserForFlutterId:browserId];
    if (browser && browser->GetHost() && participant && participant.window) {
        if (operation == (NSDragOperationMove | NSDragOperationCopy)) {
            operation &= ~NSDragOperationMove;
        }
        const NSRect screenRect = NSMakeRect(screenPoint.x, screenPoint.y, 0, 0);
        const NSPoint windowPoint =
            [participant.window convertRectFromScreen:screenRect].origin;
        const NSPoint localPoint = [participant convertPoint:windowPoint
                                                    fromView:nil];
        const NSPoint browserPoint =
            BrowserPointFromParticipantPoint(participant, localPoint);
        if (ShouldLogDragDebug()) {
            NSLog(@"CEFDrag: DragSourceEndedAt+DragSourceSystemDragEnded browserId=%d x=%d y=%d operation=0x%lx types=%@",
                  browserId, (int)browserPoint.x, (int)browserPoint.y,
                  (unsigned long)operation, participant.offeredPasteboardTypes);
        }
        browser->GetHost()->DragSourceEndedAt(
            (int)browserPoint.x,
            (int)browserPoint.y,
            CefDragMaskFromNSDragOperation(operation));
        browser->GetHost()->DragSourceSystemDragEnded();
    }
    participant.promiseFileName = nil;
    if (!filePromisePending) {
        _outboundDragData.erase(browserId);
    }
}

- (void)dragParticipantWriteFilePromiseToURL:(NSURL*)url
                                   browserId:(int)browserId
                           completionHandler:(void (^)(NSError* _Nullable))handler {
    auto it = _outboundDragData.find(browserId);
    if (it == _outboundDragData.end() || !it->second) {
        if (ShouldLogDragDebug()) {
            NSLog(@"CEFDrag: file promise browserId=%d url=%@ failed=no_drag_data",
                  browserId, url.path);
        }
        handler([NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSFileWriteUnknownError
                                userInfo:@{NSLocalizedDescriptionKey:
                                               @"Drag data no longer available"}]);
        return;
    }
    CefRefPtr<CefDragData> dragData = it->second;
    const size_t expected = dragData->GetFileContents(nullptr);
    CefRefPtr<CefStreamWriter> writer = CefStreamWriter::CreateForFile(
        CefString([url.path UTF8String]));
    if (!writer) {
        if (ShouldLogDragDebug()) {
            NSLog(@"CEFDrag: file promise browserId=%d url=%@ failed=no_writer",
                  browserId, url.path);
        }
        _outboundDragData.erase(browserId);
        handler([NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSFileWriteUnknownError
                                userInfo:nil]);
        return;
    }
    const size_t written = dragData->GetFileContents(writer);
    _outboundDragData.erase(browserId);
    if (ShouldLogDragDebug()) {
        NSLog(@"CEFDrag: file promise browserId=%d url=%@ expectedBytes=%zu writtenBytes=%zu success=%d",
              browserId, url.path, expected, written,
              (int)(expected > 0 && written == expected));
    }
    handler(expected > 0 && written == expected
                ? nil
                : [NSError errorWithDomain:NSCocoaErrorDomain
                                      code:NSFileWriteUnknownError
                                  userInfo:nil]);
}

- (CefMouseEvent)dragMouseEventForInfo:(id<NSDraggingInfo>)info
                           participant:(CefDragParticipantView*)participant {
    const NSPoint localPoint = [participant convertPoint:info.draggingLocation
                                                fromView:nil];
    const NSPoint browserPoint =
        BrowserPointFromParticipantPoint(participant, localPoint);
    CefMouseEvent event;
    event.x = (int)browserPoint.x;
    event.y = (int)browserPoint.y;
    event.modifiers = 0;
    return event;
}

- (CefRefPtr<CefDragData>)dragDataFromPasteboard:(NSPasteboard*)pasteboard {
    CefRefPtr<CefDragData> data = CefDragData::Create();
    NSArray<NSURL*>* fileUrls = [pasteboard
        readObjectsForClasses:@[ [NSURL class] ]
                      options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
    for (NSURL* url in fileUrls) {
        if (url.path.length > 0) {
            data->AddFile(CefString([url.path UTF8String]),
                          CefString([url.lastPathComponent UTF8String]));
        }
    }
    NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
    if (text.length > 0) {
        data->SetFragmentText(CefString([text UTF8String]));
    }
    NSString* html = [pasteboard stringForType:NSPasteboardTypeHTML];
    if (html.length > 0) {
        data->SetFragmentHtml(CefString([html UTF8String]));
    }
    if (fileUrls.count == 0) {
        NSString* url = [pasteboard stringForType:NSPasteboardTypeURL];
        if (url.length > 0) {
            data->SetLinkURL(CefString([url UTF8String]));
        }
    }
    return data;
}

- (NSDragOperation)dragParticipantEntered:(id<NSDraggingInfo>)info
                                browserId:(int)browserId {
    CefRefPtr<CefBrowser> browser = [self osrBrowserForFlutterId:browserId];
    CefDragParticipantView* participant = _dragParticipants[@(browserId)];
    if (!browser || !browser->GetHost() || !participant) {
        return NSDragOperationNone;
    }
    CefRefPtr<CefDragData> data =
        [self dragDataFromPasteboard:info.draggingPasteboard];
    const CefMouseEvent event = [self dragMouseEventForInfo:info
                                                participant:participant];
    browser->GetHost()->DragTargetDragEnter(
        data, event,
        CefDragMaskFromNSDragOperation(info.draggingSourceOperationMask));
    participant.currentCefOperation =
        (info.draggingSourceOperationMask & NSDragOperationCopy)
            ? NSDragOperationCopy
            : info.draggingSourceOperationMask;
    return participant.currentCefOperation;
}

- (NSDragOperation)dragParticipantUpdated:(id<NSDraggingInfo>)info
                                browserId:(int)browserId {
    CefRefPtr<CefBrowser> browser = [self osrBrowserForFlutterId:browserId];
    CefDragParticipantView* participant = _dragParticipants[@(browserId)];
    if (!browser || !browser->GetHost() || !participant) {
        return NSDragOperationNone;
    }
    const CefMouseEvent event = [self dragMouseEventForInfo:info
                                                participant:participant];
    browser->GetHost()->DragTargetDragOver(
        event,
        CefDragMaskFromNSDragOperation(info.draggingSourceOperationMask));
    return participant.currentCefOperation;
}

- (void)dragParticipantExited:(nullable id<NSDraggingInfo>)info
                    browserId:(int)browserId {
    CefRefPtr<CefBrowser> browser = [self osrBrowserForFlutterId:browserId];
    if (browser && browser->GetHost()) {
        browser->GetHost()->DragTargetDragLeave();
    }
}

- (BOOL)dragParticipantPerformDrop:(id<NSDraggingInfo>)info
                         browserId:(int)browserId {
    CefRefPtr<CefBrowser> browser = [self osrBrowserForFlutterId:browserId];
    CefDragParticipantView* participant = _dragParticipants[@(browserId)];
    if (!browser || !browser->GetHost() || !participant) {
        return NO;
    }
    const CefMouseEvent event = [self dragMouseEventForInfo:info
                                                participant:participant];
    browser->GetHost()->DragTargetDrop(event);
    return YES;
}

#pragma mark - Chrome Runtime Helpers

- (BOOL)shouldEnableChromeRuntime {
    return _chromeRuntime;
}

- (BOOL)remoteDebuggingEnabled {
    return _remoteDebuggingPort > 0;
}

- (NSArray<NSString*>*)extensionPaths {
    NSMutableArray<NSString*>* arr = [NSMutableArray arrayWithCapacity:_extensionPaths.size()];
    for (const auto& p : _extensionPaths) {
        [arr addObject:[NSString stringWithUTF8String:p.c_str()]];
    }
    return arr;
}

@end
