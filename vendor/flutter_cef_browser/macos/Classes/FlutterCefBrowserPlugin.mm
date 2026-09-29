//
//  FlutterCefBrowserPlugin.mm
//  flutter_cef_browser
//
//  Plugin entry point for Flutter
//

#import "FlutterCefBrowserPlugin.h"
#import "Bridge/CEFBridge.h"
#include "include/internal/cef_types_color.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <deque>
#import <map>
#import <math.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#include <unordered_map>

typedef void (^CefOsrGpuCompletionCallback)(void);

@interface FlutterCefBrowserPlugin () <CEFBridgeDelegate>
- (BOOL)hasFocusedBrowser;
- (BOOL)performFocusedBrowserCommand:(NSString*)command inWindow:(NSWindow*)window;
- (NSDictionary*)hideStaleBrowsersKeepingBrowserIds:(NSSet<NSNumber*>*)keepVisibleBrowserIds
                                             reason:(NSString*)reason;
+ (NSDictionary*)hideStaleBrowsersAcrossInstancesKeepingBrowserIds:(NSSet<NSNumber*>*)keepVisibleBrowserIds
                                                            reason:(NSString*)reason;
@end

// Message loop is now handled by OnScheduleMessagePumpWork in CEFBridge's BrowserApp
// No additional timer needed - CEF tells us when to pump via the callback

static int GetBrowserId(NSDictionary* args) {
    id value = args[@"id"];
    if (!value || value == [NSNull null]) {
        value = args[@"browserId"];
    }
    return value ? [value intValue] : 0;
}

static NSString* ConsoleLevelToString(int level) {
    // Map CEF log severity to Dart ConsoleLevel strings.
    // cef_log_severity_t: DEFAULT(0), VERBOSE(1), INFO(2), WARNING(3), ERROR(4), FATAL(5)
    switch (level) {
        case 0: // LOGSEVERITY_DEFAULT
        case 1: // LOGSEVERITY_VERBOSE
            return @"debug";
        case 2: // LOGSEVERITY_INFO
            return @"info";
        case 3: // LOGSEVERITY_WARNING
            return @"warning";
        default:
            return @"error";
    }
}

static NSString* EventStreamKeyFromArguments(id arguments) {
    if (!arguments || arguments == [NSNull null]) return nil;
    if ([arguments isKindOfClass:[NSString class]]) {
        return (NSString*)arguments;
    }
    if ([arguments isKindOfClass:[NSDictionary class]]) {
        id key = ((NSDictionary*)arguments)[@"channel"];
        if ([key isKindOfClass:[NSString class]]) {
            return (NSString*)key;
        }
    }
    return nil;
}

// Global flag: true when any CEF browser has been given focus via setFocus(true).
// Cleared when setFocus(false) is called or all browsers are closed.
// The host app's NSWindow subclass can check this to decide whether to
// forward browser-owned shortcuts to CEF instead of Flutter.
static std::atomic<bool> gCefBrowserHasFocus{false};

static void RunWithoutImplicitLayerActions(void (^updates)(void)) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    updates();
    [CATransaction commit];
}

static BOOL RectsApproximatelyEqual(NSRect lhs, NSRect rhs) {
    const CGFloat epsilon = 0.01;
    return fabs(lhs.origin.x - rhs.origin.x) <= epsilon &&
           fabs(lhs.origin.y - rhs.origin.y) <= epsilon &&
           fabs(lhs.size.width - rhs.size.width) <= epsilon &&
           fabs(lhs.size.height - rhs.size.height) <= epsilon;
}

static NSHashTable<FlutterCefBrowserPlugin*>* FlutterCefBrowserPluginInstances(void) {
    static NSHashTable<FlutterCefBrowserPlugin*>* instances = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instances = [NSHashTable weakObjectsHashTable];
    });
    return instances;
}

static void SyncGlobalCefBrowserFocusFlag(void) {
    BOOL anyFocused = NO;
    for (FlutterCefBrowserPlugin* instance in FlutterCefBrowserPluginInstances()) {
        if ([instance hasFocusedBrowser]) {
            anyFocused = YES;
            break;
        }
    }
    gCefBrowserHasFocus.store(anyFocused, std::memory_order_relaxed);
}

BOOL FlutterCefBrowserPlugin_isCefBrowserFocused(void) {
    return gCefBrowserHasFocus.load(std::memory_order_relaxed);
}

BOOL FlutterCefBrowserPlugin_performFocusedBrowserEditCommand(NSString* command, NSWindow* window) {
    return FlutterCefBrowserPlugin_performFocusedBrowserCommand(command, window);
}

BOOL FlutterCefBrowserPlugin_performFocusedBrowserCommand(NSString* command, NSWindow* window) {
    if (command.length == 0 || !window) {
        return NO;
    }

    if (![NSThread isMainThread]) {
        __block BOOL handled = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            handled = FlutterCefBrowserPlugin_performFocusedBrowserCommand(command, window);
        });
        return handled;
    }

    for (FlutterCefBrowserPlugin* instance in FlutterCefBrowserPluginInstances()) {
        if ([instance performFocusedBrowserCommand:command inWindow:window]) {
            return YES;
        }
    }
    return NO;
}

// Windowless browsers only need an AppKit view as a live CEF parent handle;
// Flutter's texture is the actual input surface. The transparent container
// can overlap Flutter after native view-hierarchy churn, so it must never win
// hit testing and swallow a click intended for CefTextureInputSurface.
@interface CefOsrContainerView : NSView
@end

@implementation CefOsrContainerView
- (NSView*)hitTest:(NSPoint)point {
    return nil;
}
@end

@interface CefOsrTexture : NSObject <FlutterTexture>
- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry
                          backend:(NSString*)backend;
- (void)setTextureId:(int64_t)textureId;
- (void)updateBGRAWithBuffer:(const void*)buffer
                       width:(int)width
                      height:(int)height
                   dirtyRect:(CGRect)dirtyRect;
- (void)updateWithIOSurface:(IOSurfaceRef)ioSurface
                     format:(int)format
                  dirtyRect:(CGRect)dirtyRect
                      extra:(NSDictionary * _Nullable)extra;
- (NSString *)setFrameLeaseMode:(NSString *_Nullable)mode;
- (BOOL)canAcceptAcceleratedFrameLease;
- (BOOL)updateWithLeasedIOSurface:(IOSurfaceRef)ioSurface
                           format:(int)format
                        dirtyRect:(CGRect)dirtyRect
                            extra:(NSDictionary *_Nullable)extra
                            lease:(CEFAcceleratedFrameLease *)lease;
- (BOOL)tryUpdateWithDirectLeasedIOSurface:(IOSurfaceRef)ioSurface
                                    format:(int)format
                                 dirtyRect:(CGRect)dirtyRect
                                     extra:(NSDictionary *_Nullable)extra
                                     lease:(CEFAcceleratedFrameLease *)lease;
- (BOOL)copyIOSurface:(IOSurfaceRef)ioSurface
               format:(int)format
            dirtyRect:(CGRect)dirtyRect
                extra:(NSDictionary *_Nullable)extra
           frameLease:(CEFAcceleratedFrameLease *_Nullable)frameLease;
- (void)noteUnleasedAcceleratedFrameFallbackIfRequested;
- (void)invalidatePendingAsyncFrameLeases;
- (void)setPopupVisible:(BOOL)visible;
- (void)setPopupRectDips:(CGRect)rectDips;
- (void)updatePopupBGRAWithBuffer:(const void*)buffer width:(int)width height:(int)height;
- (void)updatePopupWithIOSurface:(IOSurfaceRef)ioSurface format:(int)format;
- (void)setTargetFps:(int)targetFps;
- (void)setEffectiveScale:(double)effectiveScale;
- (void)setRequestedViewWidth:(int)width
                       height:(int)height
               effectiveScale:(double)effectiveScale;
- (NSUInteger)updateCount;
- (NSDictionary<NSString*, id>*)performanceStats;
@end

// Damage accumulated per produced frame so a reused pool buffer (holding an
// older frame) can be brought current by copying only what changed since.
struct CefOsrDamageEntry {
    uint64_t serial;
    CGRect rect;
};

// Depth covers the pool (3-4 outstanding buffers) with margin; a buffer older
// than this forces a full-frame copy.
static const uint64_t kCefOsrDamageHistoryDepth = 8;

// IOSurface quarantine (fixes the fast-resize diagonal-shear tearing).
//
// Flutter's macOS engine BORROWS (never copies) an MTLTexture view of our pool
// buffer's IOSurface and composites it on its own GPU queue AFTER it has already
// released our CVPixelBuffer. Our CVPixelBufferPool accounts CVPixelBuffer
// objects, not IOSurface references, so it would re-vend that IOSurface and our
// producer would blit the next frame into it while the engine is still reading —
// two unsynchronized queues on one IOSurface, tiled overwrite = diagonal shear.
// Steady state hides this (the 3-4 deep rotation keeps the producer ahead); a
// resize teardown/rebuild collapses that phase offset, so it surfaces.
//
// Fix: when a buffer stops being the published frame, do NOT release it (which
// returns its IOSurface to the pool for re-vending) immediately — hold a retain
// for a bounded window past the engine's max composition latency, then release.
// Likewise defer old-pool destruction across a resize so the new pool cannot
// recycle an old-pool IOSurface the engine is still sampling.
// ~40ms comfortably covers the engine's borrowed-read tail (~2 display frames /
// ~16ms at 120Hz) with margin, while keeping the quarantine shallow enough that
// frame bursts don't overrun the cap.
static const CFTimeInterval kCefOsrQuarantineSeconds = 0.04;

// The pool must be allowed enough outstanding buffers to cover the working set
// (published + in-flight blit + engine-held) PLUS the quarantine depth, or the
// quarantine would starve the pool into dropped frames. Sized above the cap so a
// burst never forces an early release. Was 4 before the quarantine existed.
static const NSUInteger kCefOsrPoolAllocationThreshold = 18;

// Cap on quarantined buffers. Sized to absorb bursty frame delivery (the pump
// can dump a backlog well above the 120fps average); forced releases here mean
// the cap/window are mis-tuned, not that a stall occurred. Kept below the pool
// threshold so the working set always has room.
static const size_t kCefOsrQuarantineMaxBuffers = 14;

// A retired IOSurface-backed buffer (or pool) awaiting release once the engine's
// borrowed GPU read has certainly retired.
struct CefOsrQuarantinedBuffer {
    CVPixelBufferRef buffer;
    CFTimeInterval releaseAfter;
};
struct CefOsrQuarantinedPool {
    CVPixelBufferPoolRef pool;
    CFTimeInterval releaseAfter;
};

// --- Per-frame capture (diagnostic) ---
//
// When CEF_FRAME_CAPTURE names a directory (or "1" -> /tmp/vten_cef_frames),
// every published frame is written as a downscaled PNG plus a manifest line
// (frames.ndjson) carrying its serial, wall + monotonic time, size, and render
// state. A too-fast-to-screenshot on-screen tear can then be scrubbed
// frame-by-frame (see `cefaudit scrub`) and correlated with the logs. Encoding
// is async on a serial queue and skips when backed up, to bound perturbation.
static const int kCefFrameCaptureMaxPending = 3;
static const uint64_t kCefFrameCaptureRing = 900;      // keep the last N PNGs
static const int kCefFrameCaptureMaxWidth = 1400;      // downscale for volume

static NSString* FrameCaptureDir(void) {
    static NSString* dir = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_FRAME_CAPTURE");
        if (value && value[0] != '\0' && strcmp(value, "0") != 0) {
            NSString* raw = [NSString stringWithUTF8String:value];
            dir = ([raw isEqualToString:@"1"] || [raw isEqualToString:@"on"])
                ? @"/tmp/vten_cef_frames"
                : raw;
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }
    });
    return dir;
}

static dispatch_queue_t FrameCaptureQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("ai.vten.cef.framecapture",
                                      DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static std::atomic<int> g_frameCapturePending{0};
static std::atomic<uint64_t> g_frameCaptureSkipped{0};

// Encodes raw BGRA bytes (any row stride) to a PNG on disk (downscaled unless
// CEF_FRAME_CAPTURE_FULLRES). Runs on the capture queue. Returns YES on success.
static BOOL WriteBGRABytesPNG(const void* base,
                              size_t width,
                              size_t height,
                              size_t bytesPerRow,
                              NSString* path) {
    BOOL ok = NO;
    if (base && width > 0 && height > 0) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        // BGRA little-endian premultiplied = the CVPixelBuffer's native layout.
        const CGBitmapInfo bitmapInfo =
            kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
        CGContextRef src = CGBitmapContextCreate((void*)base, width, height, 8,
                                                 bytesPerRow, space, bitmapInfo);
        CGImageRef srcImage = src ? CGBitmapContextCreateImage(src) : NULL;
        if (srcImage) {
            // Downscale to bound file size while preserving the shear geometry.
            // CEF_FRAME_CAPTURE_FULLRES=1 skips it so a captured shred frame
            // preserves exact byte geometry (needed to recover the writer's
            // row stride mathematically).
            static BOOL fullRes = NO;
            static dispatch_once_t fullResOnce;
            dispatch_once(&fullResOnce, ^{
                const char* v = getenv("CEF_FRAME_CAPTURE_FULLRES");
                fullRes = v && v[0] != '\0' && strcmp(v, "0") != 0;
            });
            size_t outW = width, outH = height;
            if (!fullRes && width > (size_t)kCefFrameCaptureMaxWidth) {
                const double scale = (double)kCefFrameCaptureMaxWidth / width;
                outW = (size_t)(width * scale);
                outH = (size_t)(height * scale);
            }
            CGContextRef dst = CGBitmapContextCreate(
                NULL, outW, outH, 8, 0, space,
                kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGImageRef outImage = NULL;
            if (dst) {
                CGContextSetInterpolationQuality(dst, kCGInterpolationNone);
                CGContextDrawImage(dst, CGRectMake(0, 0, outW, outH), srcImage);
                outImage = CGBitmapContextCreateImage(dst);
            }
            CGImageRef finalImage = outImage ? outImage : srcImage;
            CFURLRef url = (__bridge_retained CFURLRef)
                [NSURL fileURLWithPath:path];
            CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
                url, CFSTR("public.png"), 1, NULL);
            if (dest) {
                CGImageDestinationAddImage(dest, finalImage, NULL);
                ok = CGImageDestinationFinalize(dest);
                CFRelease(dest);
            }
            if (url) CFRelease(url);
            if (outImage) CGImageRelease(outImage);
            if (dst) CGContextRelease(dst);
            CGImageRelease(srcImage);
        }
        if (src) CGContextRelease(src);
        CGColorSpaceRelease(space);
    }
    return ok;
}

// Encodes an IOSurface-backed BGRA CVPixelBuffer to PNG (see WriteBGRABytesPNG).
static BOOL WritePixelBufferPNG(CVPixelBufferRef buffer, NSString* path) {
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return NO;
    }
    const BOOL ok = WriteBGRABytesPNG(CVPixelBufferGetBaseAddress(buffer),
                                      CVPixelBufferGetWidth(buffer),
                                      CVPixelBufferGetHeight(buffer),
                                      CVPixelBufferGetBytesPerRow(buffer),
                                      path);
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return ok;
}

// Mirrors cef_paint_element_type_t (PET_VIEW = 0, PET_POPUP = 1) without
// pulling CEF C++ headers into this file.
static const int kCefPaintElementView = 0;
static const int kCefPaintElementPopup = 1;

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

// Test-only completion gate for deterministically saturating CEF's bounded
// frame-lease admission. The blit itself runs normally, but command-buffer
// completion (and therefore lease release) waits for the CPU-signaled event.
// Unset in production and capped so an accidental test value cannot create an
// unbounded shutdown delay.
static useconds_t LeasedFrameCompletionDelayUs(void) {
    static useconds_t delayUs = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_LEASE_COMPLETION_DELAY_US");
        if (value && value[0] != '\0') {
            const long parsed = strtol(value, NULL, 10);
            delayUs = (useconds_t)MAX(0L, MIN(parsed, 5000000L));
        }
    });
    return delayUs;
}

@implementation CefOsrTexture {
    __weak NSObject<FlutterTextureRegistry>* _registry;
    NSLock* _lock;
    CVPixelBufferRef _latestPixelBuffer;
  CEFAcceleratedFrameLease *_latestFrameLease;
  BOOL _latestPixelBufferIsLeased;
  BOOL _gpuCompletionApiObserved;
    CVPixelBufferPoolRef _pixelBufferPool;
    id<MTLDevice> _metalDevice;
    id<MTLCommandQueue> _metalCommandQueue;
    NSString* _backend;
    int64_t _textureId;
    NSUInteger _updateCount;
    NSUInteger _acceleratedFrameCount;
    NSUInteger _cpuFrameCount;
    NSUInteger _textureReadCount;
    NSUInteger _uniqueTextureReadCount;
    NSUInteger _lastTextureReadUpdateCount;
    NSUInteger _textureReadAttemptCount;
    NSUInteger _droppedFrameCount;
    NSUInteger _coalescedFrameCount;
  NSUInteger _zeroCopyFrameCount;
  NSUInteger _leasedAsyncBlitFrameCount;
  NSUInteger _staleAsyncLeaseDropCount;
  NSUInteger _frameLeaseFallbackCount;
  NSString *_lastFrameTransferMode;
  NSString *_requestedFrameLeaseMode;
    uint64_t _totalCopyDurationMicros;
    uint64_t _maxCopyDurationMicros;
    uint64_t _lastCopyDurationMicros;
    uint64_t _copiedBytes;
    NSUInteger _fullFrameCopies;
    NSUInteger _partialCopies;
    double _damageCoverageSum;
    int _targetFps;
    double _effectiveScale;
    int _requestedViewWidth;
    int _requestedViewHeight;
    int _expectedPixelWidth;
    int _expectedPixelHeight;
    int _width;
    int _height;
    int _poolWidth;
    int _poolHeight;
    BOOL _forceFullFrameCopy;
    BOOL _notificationPending;
  BOOL _acceptingFrames;
  uint64_t _surfaceGeneration;
  uint64_t _lastPublishedLeasedFrameId;
    NSString* _lastError;
    // Damage history (touched only on the CEF UI thread).
    uint64_t _frameSerial;
    std::deque<CefOsrDamageEntry> _recentDamage;
    std::unordered_map<const void*, uint64_t> _bufferSerials;
    // Popup widget surface (select/autocomplete); producer-thread only.
    BOOL _popupVisible;
    CGRect _popupRectDips;
    uint8_t* _popupPixels;
    int _popupWidth;
    int _popupHeight;
    // IOSurface quarantine (producer/main-thread only; see kCefOsrQuarantineSeconds).
    std::deque<CefOsrQuarantinedBuffer> _quarantinedBuffers;
    std::deque<CefOsrQuarantinedPool> _quarantinedPools;
    NSUInteger _quarantineReleasedTotal;
    NSUInteger _quarantineForcedReleases;
    // Source-write fence stats (see the fence in updateWithIOSurface:).
    uint64_t _sourceFenceLastMicros;
    uint64_t _sourceFenceMaxMicros;
    NSUInteger _sourceFenceFailures;
    // CEF_SOURCE_TOUCH: full CPU read of every source byte pre-blit (diagnostic).
    void* _sourceTouchScratch;
    size_t _sourceTouchScratchSize;
    uint64_t _sourceTouchLastMicros;
    uint64_t _sourceTouchMaxMicros;
    // viz capture-delivery metadata for the most recent accelerated view frame
    // (producer thread only; merged into the frame-capture manifest).
    NSDictionary* _lastSourceExtra;
    NSUInteger _partialSourceDrops;
    // Pair capture: set when this frame's SOURCE was dumped at ingress, so the
    // published result of the SAME frame is dumped too (guaranteed pairs).
    BOOL _pairCaptureArmed;
}

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry
                          backend:(NSString*)backend {
    self = [super init];
    if (self) {
        _registry = registry;
        _lock = [[NSLock alloc] init];
        _latestPixelBuffer = NULL;
    _latestFrameLease = nil;
    _latestPixelBufferIsLeased = NO;
    _gpuCompletionApiObserved = NO;
        _pixelBufferPool = NULL;
        _metalDevice = MTLCreateSystemDefaultDevice();
        _metalCommandQueue = [_metalDevice newCommandQueue];
        _backend = [backend copy] ?: @"osrTexture";
        _textureId = 0;
        _updateCount = 0;
        _acceleratedFrameCount = 0;
        _cpuFrameCount = 0;
        _textureReadCount = 0;
        _uniqueTextureReadCount = 0;
        _lastTextureReadUpdateCount = 0;
        _textureReadAttemptCount = 0;
        _droppedFrameCount = 0;
        _coalescedFrameCount = 0;
    _zeroCopyFrameCount = 0;
    _leasedAsyncBlitFrameCount = 0;
    _staleAsyncLeaseDropCount = 0;
    _frameLeaseFallbackCount = 0;
    _lastFrameTransferMode = @"copied";
    const char *leaseEnabled = getenv("CEF_OSR_FRAME_LEASE");
    const BOOL requestedLease =
        leaseEnabled && leaseEnabled[0] != '\0' &&
        strcmp(leaseEnabled, "0") != 0;
    const char *leaseMode = getenv("CEF_OSR_FRAME_LEASE_MODE");
    if (!requestedLease || !CEFAcceleratedFrameLeaseApiAvailable()) {
      _requestedFrameLeaseMode = @"copied";
    } else if (leaseMode && strcmp(leaseMode, "async") == 0) {
      _requestedFrameLeaseMode = @"leased_async_blit";
    } else {
      _requestedFrameLeaseMode = @"leased_direct";
    }
        _totalCopyDurationMicros = 0;
        _maxCopyDurationMicros = 0;
        _lastCopyDurationMicros = 0;
        _copiedBytes = 0;
        _fullFrameCopies = 0;
        _partialCopies = 0;
        _damageCoverageSum = 0;
        _targetFps = 0;
        _effectiveScale = 0;
        _requestedViewWidth = 0;
        _requestedViewHeight = 0;
        _expectedPixelWidth = 0;
        _expectedPixelHeight = 0;
        _width = 0;
        _height = 0;
        _poolWidth = 0;
        _poolHeight = 0;
        _forceFullFrameCopy = YES;
        _notificationPending = NO;
    _acceptingFrames = YES;
    _surfaceGeneration = 1;
    _lastPublishedLeasedFrameId = 0;
        _lastError = @"";
        _quarantineReleasedTotal = 0;
        _quarantineForcedReleases = 0;
        _sourceFenceLastMicros = 0;
        _sourceFenceMaxMicros = 0;
        _sourceFenceFailures = 0;
        _sourceTouchScratch = NULL;
        _sourceTouchScratchSize = 0;
        _sourceTouchLastMicros = 0;
        _sourceTouchMaxMicros = 0;
        _lastSourceExtra = nil;
        _partialSourceDrops = 0;
    }
    return self;
}

// --- IOSurface quarantine (main/producer thread only) ---
//
// See kCefOsrQuarantineSeconds. These structures are touched only on the CEF UI
// thread (== main thread): publish, resize, and the paint entry points all run
// there, and copyPixelBuffer (raster thread) never touches them — so no lock is
// needed here (the _latestPixelBuffer handoff itself remains lock-guarded).

// Hand a retired buffer to the quarantine instead of releasing it. Takes
// ownership of the +1 reference the caller was about to drop.
- (void)quarantineBuffer:(CVPixelBufferRef)buffer {
    if (!buffer) return;
    _quarantinedBuffers.push_back(
        {buffer, CACurrentMediaTime() + kCefOsrQuarantineSeconds});
    // Pathological-stall backstop: never grow unbounded.
    while (_quarantinedBuffers.size() > kCefOsrQuarantineMaxBuffers) {
        CVBufferRelease(_quarantinedBuffers.front().buffer);
        _quarantinedBuffers.pop_front();
        _quarantineForcedReleases += 1;
    }
}

// Defer destruction of a superseded pool so the new pool cannot recycle an
// old-pool IOSurface the engine may still be sampling.
- (void)quarantinePool:(CVPixelBufferPoolRef)pool {
    if (!pool) return;
    _quarantinedPools.push_back(
        {pool, CACurrentMediaTime() + kCefOsrQuarantineSeconds});
}

// Release everything whose window has elapsed. Call before any pool allocation
// so freed slots become available again.
- (void)drainQuarantine {
    const CFTimeInterval now = CACurrentMediaTime();
    while (!_quarantinedBuffers.empty() &&
           _quarantinedBuffers.front().releaseAfter <= now) {
        CVBufferRelease(_quarantinedBuffers.front().buffer);
        _quarantinedBuffers.pop_front();
        _quarantineReleasedTotal += 1;
    }
    while (!_quarantinedPools.empty() &&
           _quarantinedPools.front().releaseAfter <= now) {
        CVPixelBufferPoolRelease(_quarantinedPools.front().pool);
        _quarantinedPools.pop_front();
    }
}

// Force-release the entire quarantine (teardown paths only).
- (void)flushQuarantine {
    for (auto& entry : _quarantinedBuffers) {
        CVBufferRelease(entry.buffer);
    }
    _quarantinedBuffers.clear();
    for (auto& entry : _quarantinedPools) {
        CVPixelBufferPoolRelease(entry.pool);
    }
    _quarantinedPools.clear();
}

// Diagnostic PRE-BLIT source dump (CEF_FRAME_CAPTURE_SOURCE=1, requires
// CEF_FRAME_CAPTURE). CPU-copies the CEF-delivered IOSurface bytes at its OWN
// pitch BEFORE our Metal blit touches it, then encodes async. This is the
// decisive discriminator the adversarial audit demanded: if a shredded
// published frame's matching source dump is ALREADY sheared, the corruption is
// upstream (viz/CEF); if the source is clean and the published copy is
// sheared, it is ours. The copy must complete before the callback returns
// (CEF recycles the surface), hence the synchronous memcpy under lock.
- (void)captureSourceIfEnabled:(IOSurfaceRef)ioSurface
                 pendingSerial:(uint64_t)pendingSerial {
    static BOOL sourceCaptureEnabled = NO;
    static dispatch_once_t srcOnce;
    dispatch_once(&srcOnce, ^{
        const char* v = getenv("CEF_FRAME_CAPTURE_SOURCE");
        sourceCaptureEnabled = v && v[0] != '\0' && strcmp(v, "0") != 0;
    });
    NSString* dir = FrameCaptureDir();
    if (!sourceCaptureEnabled || !dir || !ioSurface) return;
    if (g_frameCapturePending.load() >= kCefFrameCaptureMaxPending) {
        return;  // shared budget with the published-frame capture
    }
    if (IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL) !=
        kIOSurfaceSuccess) {
        return;
    }
    const size_t width = IOSurfaceGetWidth(ioSurface);
    const size_t height = IOSurfaceGetHeight(ioSurface);
    const size_t bytesPerRow = IOSurfaceGetBytesPerRow(ioSurface);
    const void* base = IOSurfaceGetBaseAddress(ioSurface);
    void* copy = NULL;
    if (base && width > 0 && height > 0) {
        copy = malloc(bytesPerRow * height);
        if (copy) {
            memcpy(copy, base, bytesPerRow * height);
        }
    }
    const uint32_t surfaceId = IOSurfaceGetID(ioSurface);
    IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    if (!copy) return;
    _pairCaptureArmed = YES;  // guarantee the published half of this pair

    g_frameCapturePending.fetch_add(1);
    dispatch_async(FrameCaptureQueue(), ^{
        NSString* name =
            [NSString stringWithFormat:@"src_%08llu.png",
                                       (unsigned long long)pendingSerial];
        NSString* path = [dir stringByAppendingPathComponent:name];
        const BOOL ok =
            WriteBGRABytesPNG(copy, width, height, bytesPerRow, path);
        NSDictionary* rec = @{
            @"kind": @"source",
            @"serial": @(pendingSerial),
            @"file": name,
            @"w": @((int)width),
            @"h": @((int)height),
            @"bytesPerRow": @((int)bytesPerRow),
            @"surfaceId": @(surfaceId),
            @"ok": @(ok),
        };
        NSData* json = [NSJSONSerialization dataWithJSONObject:rec
                                                       options:0
                                                         error:nil];
        if (json) {
            NSMutableData* line = [json mutableCopy];
            [line appendBytes:"\n" length:1];
            NSString* manifest =
                [dir stringByAppendingPathComponent:@"frames.ndjson"];
            NSFileManager* fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:manifest]) {
                [fm createFileAtPath:manifest contents:nil attributes:nil];
            }
            NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:manifest];
            @try {
                [fh seekToEndOfFile];
                [fh writeData:line];
            } @catch (__unused NSException* e) {
            }
            [fh closeFile];
        }
        free(copy);
        g_frameCapturePending.fetch_sub(1);
    });
}

// Diagnostic per-frame capture (see FrameCaptureDir / CEF_FRAME_CAPTURE).
// Snapshots render state on the producer thread, then encodes the PNG + appends
// the manifest line asynchronously so it barely perturbs frame production.
- (void)captureFrameIfEnabled:(CVPixelBufferRef)buffer serial:(uint64_t)serial {
    NSString* dir = FrameCaptureDir();
    if (!dir || !buffer) return;
    const BOOL paired = _pairCaptureArmed;
    _pairCaptureArmed = NO;
    // A paired capture (source half already on disk) uses a relaxed budget so
    // the pair is never split by backpressure; unpaired captures keep the
    // strict cap.
    const int budget = paired ? (kCefFrameCaptureMaxPending * 2)
                              : kCefFrameCaptureMaxPending;
    if (g_frameCapturePending.load() >= budget) {
        g_frameCaptureSkipped.fetch_add(1);  // protect the app if encoding lags
        return;
    }

    // Snapshot state at publish time (producer/main thread).
    NSMutableDictionary<NSString*, id>* metaBuilder = [NSMutableDictionary new];
    if (_lastSourceExtra) {
        // viz delivery metadata for the source this frame was blitted from —
        // the discriminator for stale/letterboxed deliveries.
        metaBuilder[@"srcExtra"] = _lastSourceExtra;
    }
    NSDictionary<NSString*, id>* meta = @{
        @"serial": @(serial),
        @"wallMs": @([[NSDate date] timeIntervalSince1970] * 1000.0),
        @"monotonic": @(CACurrentMediaTime()),
        @"w": @((int)CVPixelBufferGetWidth(buffer)),
        @"h": @((int)CVPixelBufferGetHeight(buffer)),
        @"bytesPerRow": @((int)CVPixelBufferGetBytesPerRow(buffer)),
        @"expectedW": @(_expectedPixelWidth),
        @"expectedH": @(_expectedPixelHeight),
        @"requestedW": @(_requestedViewWidth),
        @"requestedH": @(_requestedViewHeight),
        @"quarantineDepth": @((NSUInteger)_quarantinedBuffers.size()),
        @"quarantinePoolsHeld": @((NSUInteger)_quarantinedPools.size()),
        @"droppedTotal": @(_droppedFrameCount),
        @"captureSkipped": @(g_frameCaptureSkipped.load()),
        @"backend": _backend ?: @"osrTexture",
        @"textureId": @(_textureId),
    };
    [metaBuilder addEntriesFromDictionary:meta];
    meta = metaBuilder;

    CVBufferRetain(buffer);
    g_frameCapturePending.fetch_add(1);
    dispatch_async(FrameCaptureQueue(), ^{
        NSString* name =
            [NSString stringWithFormat:@"frame_%08llu.png",
                                       (unsigned long long)serial];
        NSString* path = [dir stringByAppendingPathComponent:name];
        const BOOL ok = WritePixelBufferPNG(buffer, path);

        NSMutableDictionary* rec = [meta mutableCopy];
        rec[@"file"] = name;
        rec[@"ok"] = @(ok);
        NSData* json = [NSJSONSerialization dataWithJSONObject:rec
                                                       options:0
                                                         error:nil];
        if (json) {
            NSMutableData* line = [json mutableCopy];
            [line appendBytes:"\n" length:1];
            NSString* manifest =
                [dir stringByAppendingPathComponent:@"frames.ndjson"];
            NSFileManager* fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:manifest]) {
                [fm createFileAtPath:manifest contents:nil attributes:nil];
            }
            NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:manifest];
            @try {
                [fh seekToEndOfFile];
                [fh writeData:line];
            } @catch (__unused NSException* e) {
            }
            [fh closeFile];
        }

        // Ring: delete the PNG that fell out of the window.
        if (serial > kCefFrameCaptureRing) {
            NSString* oldName =
                [NSString stringWithFormat:@"frame_%08llu.png",
                            (unsigned long long)(serial - kCefFrameCaptureRing)];
            [[NSFileManager defaultManager]
                removeItemAtPath:[dir stringByAppendingPathComponent:oldName]
                           error:nil];
        }

        CVBufferRelease(buffer);
        g_frameCapturePending.fetch_sub(1);
    });
}

- (void)dealloc {
    if (_popupPixels) {
        free(_popupPixels);
        _popupPixels = NULL;
    }
    if (_sourceTouchScratch) {
        free(_sourceTouchScratch);
        _sourceTouchScratch = NULL;
        _sourceTouchScratchSize = 0;
    }
    [_lock lock];
    CVPixelBufferRef buffer = _latestPixelBuffer;
  CEFAcceleratedFrameLease *lease = _latestFrameLease;
    _latestPixelBuffer = NULL;
  _latestFrameLease = nil;
  _latestPixelBufferIsLeased = NO;
    [_lock unlock];
  [lease releaseFrame];
    if (buffer) {
        CVBufferRelease(buffer);
    }
    [self flushQuarantine];
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
}

- (void)setTextureId:(int64_t)textureId {
    _textureId = textureId;
}

- (NSUInteger)updateCount {
    [_lock lock];
    const NSUInteger count = _updateCount;
    [_lock unlock];
    return count;
}

- (void)recordDroppedFrame:(NSString*)error {
    [_lock lock];
    _droppedFrameCount += 1;
    _lastError = [error copy] ?: @"unknown OSR transfer error";
    [_lock unlock];
    // A dropped frame means CEF content advanced without a matching publish,
    // so buffer contents can no longer be proven current by damage history.
    [self resetDamageHistory];
}

- (void)resetDamageHistory {
    _frameSerial = 0;
    _recentDamage.clear();
    _bufferSerials.clear();
}

// Returns the region that must be copied into |buffer| to bring it to the
// current frame.
//
// Partial dirty-rect copies are DISABLED — this always returns the full rect.
// The destination is a rotating pool buffer (3-4 slots), so a "partial" blit
// would land on whatever stale frame that slot last held, not the
// immediately-previous frame, leaving the rest of the surface as sparse
// streaks over old/black content (the diagonal corruption seen after a
// resize). A full Metal blit is sub-millisecond even at 4K, so the copy-byte
// optimization is not worth the correctness risk. `frameDirty` and the damage
// bookkeeping remain live but advisory only.
- (CGRect)copyRegionForBuffer:(CVPixelBufferRef)buffer
                     fullRect:(CGRect)fullRect
                   frameDirty:(CGRect)frameDirty
                    isPartial:(BOOL*)isPartial {
    (void)frameDirty;
    *isPartial = NO;
    const CGRect destinationRect = CGRectMake(
        0, 0, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer));
    const CGRect boundedFullRect =
        CGRectIntegral(CGRectIntersection(fullRect, destinationRect));
    return CGRectIsEmpty(boundedFullRect) ? CGRectZero : boundedFullRect;
}

- (void)noteFramePublishedForBuffer:(CVPixelBufferRef)buffer
                         frameDirty:(CGRect)frameDirty
                           fullRect:(CGRect)fullRect {
    const CGRect clamped =
        CGRectIntegral(CGRectIntersection(frameDirty, fullRect));
    _frameSerial += 1;
    _recentDamage.push_back(
        {_frameSerial, CGRectIsEmpty(clamped) ? fullRect : clamped});
    while (_recentDamage.size() > kCefOsrDamageHistoryDepth) {
        _recentDamage.pop_front();
    }
    _bufferSerials[(const void*)buffer] = _frameSerial;
}

- (void)setPopupVisible:(BOOL)visible {
    if (_popupVisible == visible) return;
    _popupVisible = visible;
    if (!visible) {
        if (_popupPixels) {
            free(_popupPixels);
            _popupPixels = NULL;
        }
        _popupWidth = 0;
        _popupHeight = 0;
        _popupRectDips = CGRectZero;
    }
    // Published buffers now diverge from pure view content (or stop doing
    // so); either way prior damage bookkeeping is no longer trustworthy.
    [self resetDamageHistory];
}

- (void)setPopupRectDips:(CGRect)rectDips {
    if (CGRectEqualToRect(_popupRectDips, rectDips)) return;
    _popupRectDips = rectDips;
    // Moving the popup changes pixels outside its own damage surface. The
    // accompanying PET_VIEW invalidation will rebuild a clean base frame.
    [self resetDamageHistory];
}

// Overlays the retained popup pixels onto |buffer| (view-sized, BGRA,
// IOSurface-backed, CPU-accessible after the copy that filled it completed).
- (void)compositePopupIntoBuffer:(CVPixelBufferRef)buffer {
    if (!_popupVisible || !_popupPixels || _popupWidth <= 0 || _popupHeight <= 0) {
        return;
    }
    const int bufferWidth = (int)CVPixelBufferGetWidth(buffer);
    const int bufferHeight = (int)CVPixelBufferGetHeight(buffer);
    if (bufferWidth <= 0 || bufferHeight <= 0) return;

    double scale = 0;
    if (_popupRectDips.size.width > 0) {
        scale = _popupWidth / _popupRectDips.size.width;
    }
    if (scale <= 0 || !isfinite(scale)) {
        scale = _effectiveScale > 0 ? _effectiveScale : 1.0;
    }
    const CGRect popupRect = CGRectMake(
        llround(_popupRectDips.origin.x * scale),
        llround(_popupRectDips.origin.y * scale),
        _popupWidth,
        _popupHeight);
    const CGRect clippedRect = CGRectIntersection(
        popupRect, CGRectMake(0, 0, bufferWidth, bufferHeight));
    if (CGRectIsEmpty(clippedRect)) return;
    const int destX = (int)clippedRect.origin.x;
    const int destY = (int)clippedRect.origin.y;
    const int sourceX = destX - (int)popupRect.origin.x;
    const int sourceY = destY - (int)popupRect.origin.y;
    const int copyWidth = MIN((int)clippedRect.size.width, _popupWidth - sourceX);
    const int copyHeight = MIN((int)clippedRect.size.height, _popupHeight - sourceY);
    if (copyWidth <= 0 || copyHeight <= 0) return;

    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t* dest = (uint8_t*)CVPixelBufferGetBaseAddress(buffer);
    const size_t destBytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
    const size_t sourceBytesPerRow = (size_t)_popupWidth * 4;
    if (!dest || destBytesPerRow < (size_t)bufferWidth * 4) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        return;
    }
    for (int row = 0; row < copyHeight; row++) {
        memcpy(dest + ((size_t)(destY + row) * destBytesPerRow) + (size_t)destX * 4,
               _popupPixels + ((size_t)(sourceY + row) * sourceBytesPerRow) +
                   (size_t)sourceX * 4,
               (size_t)copyWidth * 4);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

// Republishes the latest view frame with the current popup overlay when the
// popup repaints without an accompanying view frame.
- (void)republishWithPopupOverlay {
    if (!_popupVisible) return;
    [_lock lock];
    CVPixelBufferRef previous =
        _latestPixelBuffer ? CVBufferRetain(_latestPixelBuffer) : NULL;
  const BOOL previousWasLeased = _latestPixelBufferIsLeased;
    [_lock unlock];
    if (!previous) return;  // No view frame yet; composite happens on arrival.
  if (previousWasLeased) {
    // The engine completion callback, not this plugin, owns the lifetime
    // after a direct frame is borrowed. Wait for the invalidated legacy
    // view frame instead of starting an untracked popup-composite read.
    CVBufferRelease(previous);
    return;
  }

    const int width = (int)CVPixelBufferGetWidth(previous);
    const int height = (int)CVPixelBufferGetHeight(previous);
    if (width <= 0 || height <= 0 || !_metalDevice || !_metalCommandQueue ||
        ![self ensurePixelBufferPoolWidth:width height:height]) {
        CVBufferRelease(previous);
        return;
    }

    NSDictionary* allocationAttributes = @{
        (NSString*)kCVPixelBufferPoolAllocationThresholdKey:
            @(kCefOsrPoolAllocationThreshold),
    };
    CVPixelBufferRef nextBuffer = NULL;
    CVReturn poolStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault,
        _pixelBufferPool,
        (__bridge CFDictionaryRef)allocationAttributes,
        &nextBuffer);
    if (poolStatus != kCVReturnSuccess || !nextBuffer) {
        CVBufferRelease(previous);
        [self recordDroppedFrame:[NSString stringWithFormat:@"popup republish pool allocation failed: %d", poolStatus]];
        return;
    }

    IOSurfaceRef sourceSurface = CVPixelBufferGetIOSurface(previous);
    IOSurfaceRef destinationSurface = CVPixelBufferGetIOSurface(nextBuffer);
    if (!sourceSurface || !destinationSurface) {
        CVBufferRelease(previous);
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"popup republish requires IOSurface-backed buffers"];
        return;
    }

    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:(NSUInteger)width
                                                         height:(NSUInteger)height
                                                      mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> sourceTexture =
        [_metalDevice newTextureWithDescriptor:descriptor iosurface:sourceSurface plane:0];
    id<MTLTexture> destinationTexture =
        [_metalDevice newTextureWithDescriptor:descriptor iosurface:destinationSurface plane:0];
    if (!sourceTexture || !destinationTexture) {
        CVBufferRelease(previous);
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"popup republish could not create Metal textures"];
        return;
    }

    const CFTimeInterval startedAt = CACurrentMediaTime();
    id<MTLCommandBuffer> commandBuffer = [_metalCommandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    if (!commandBuffer || !blitEncoder) {
        CVBufferRelease(previous);
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"popup republish could not create Metal blit"];
        return;
    }
    [blitEncoder copyFromTexture:sourceTexture toTexture:destinationTexture];
    [blitEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    CVBufferRelease(previous);
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        NSString* message = commandBuffer.error.localizedDescription ?: @"popup republish blit failed";
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:message];
        return;
    }

    [self compositePopupIntoBuffer:nextBuffer];
    const uint64_t durationMicros =
        (uint64_t)((CACurrentMediaTime() - startedAt) * 1000000.0);
    [self invalidatePendingAsyncFrameLeases];
    [_lock lock];
  _lastFrameTransferMode = @"copied";
  [_lock unlock];
  [self publishPixelBuffer:nextBuffer
              durationMicros:durationMicros
                 accelerated:[_backend isEqualToString:@"acceleratedOsrTexture"]
                 copiedBytes:(uint64_t)width * (uint64_t)height * 4
              damageCoverage:1.0
                     partial:NO];
}

- (void)updatePopupBGRAWithBuffer:(const void*)buffer width:(int)width height:(int)height {
    if (!buffer || width <= 0 || height <= 0) return;
    const size_t byteCount = (size_t)width * (size_t)height * 4;
    if (_popupWidth != width || _popupHeight != height || !_popupPixels) {
        uint8_t* resized = (uint8_t*)realloc(_popupPixels, byteCount);
        if (!resized) return;
        _popupPixels = resized;
        _popupWidth = width;
        _popupHeight = height;
    }
    memcpy(_popupPixels, buffer, byteCount);
    [self republishWithPopupOverlay];
}

- (void)updatePopupWithIOSurface:(IOSurfaceRef)ioSurface format:(int)format {
    if (!ioSurface) return;
    if (format != CEF_COLOR_TYPE_BGRA_8888 &&
        format != CEF_COLOR_TYPE_RGBA_8888) {
        [self recordDroppedFrame:[NSString stringWithFormat:@"Unsupported CEF popup format: %d", format]];
        return;
    }
    const int width = (int)IOSurfaceGetWidth(ioSurface);
    const int height = (int)IOSurfaceGetHeight(ioSurface);
    if (width <= 0 || height <= 0) return;
    // Popup surfaces are dropdown-sized; a CPU readback keeps the retained
    // copy simple and avoids extra Metal round trips.
    if (IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL) != kIOSurfaceSuccess) {
        return;
    }
    const uint8_t* base = (const uint8_t*)IOSurfaceGetBaseAddress(ioSurface);
    const size_t sourceBytesPerRow = IOSurfaceGetBytesPerRow(ioSurface);
    const size_t byteCount = (size_t)width * (size_t)height * 4;
    if (_popupWidth != width || _popupHeight != height || !_popupPixels) {
        uint8_t* resized = (uint8_t*)realloc(_popupPixels, byteCount);
        if (!resized) {
            IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
            return;
        }
        _popupPixels = resized;
        _popupWidth = width;
        _popupHeight = height;
    }
    for (int row = 0; row < height; row++) {
        uint8_t* destination =
            _popupPixels + ((size_t)row * (size_t)width * 4);
        const uint8_t* source = base + ((size_t)row * sourceBytesPerRow);
        if (format == CEF_COLOR_TYPE_BGRA_8888) {
            memcpy(destination, source, (size_t)width * 4);
        } else {
            // CEF 147 documents RGBA as the normal macOS shared-texture
            // format; Flutter's retained CVPixelBuffer is BGRA.
            for (int column = 0; column < width; column++) {
                destination[column * 4] = source[column * 4 + 2];
                destination[column * 4 + 1] = source[column * 4 + 1];
                destination[column * 4 + 2] = source[column * 4];
                destination[column * 4 + 3] = source[column * 4 + 3];
            }
        }
    }
    IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    [self republishWithPopupOverlay];
}

- (void)scheduleFrameNotification {
    [_lock lock];
    if (_notificationPending) {
        _coalescedFrameCount += 1;
        [_lock unlock];
        return;
    }
    _notificationPending = YES;
    [_lock unlock];

    __weak CefOsrTexture* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CefOsrTexture* strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf->_lock lock];
        strongSelf->_notificationPending = NO;
        NSObject<FlutterTextureRegistry>* registry = strongSelf->_registry;
        const int64_t textureId = strongSelf->_textureId;
        [strongSelf->_lock unlock];

        if (registry && textureId != 0) {
            [registry textureFrameAvailable:textureId];
        }
    });
}

- (void)publishPixelBuffer:(CVPixelBufferRef)nextBuffer
             durationMicros:(uint64_t)durationMicros
                accelerated:(BOOL)accelerated
                copiedBytes:(uint64_t)copiedBytes
             damageCoverage:(double)damageCoverage
                    partial:(BOOL)partial {
    const int nextWidth = (int)CVPixelBufferGetWidth(nextBuffer);
    const int nextHeight = (int)CVPixelBufferGetHeight(nextBuffer);
    if ((_expectedPixelWidth > 0 && nextWidth != _expectedPixelWidth) ||
        (_expectedPixelHeight > 0 && nextHeight != _expectedPixelHeight)) {
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:[NSString stringWithFormat:@"Published frame %dx%d does not "
                                         @"match requested size %dx%d",
            nextWidth, nextHeight, _expectedPixelWidth, _expectedPixelHeight]];
        return;
    }
    if (ShouldLogResizeDebug()) {
        NSLog(@"CefOsrTexture: CEF_RESIZE_DEBUG publish textureId=%lld "
          @"requested=%dx%d scale=%.3f pool=%dx%d CVPixelBuffer=%dx%d "
          @"CVPixelBufferGetBytesPerRow=%zu",
              (long long)_textureId,
              _requestedViewWidth, _requestedViewHeight, _effectiveScale,
              _poolWidth, _poolHeight, nextWidth, nextHeight,
              CVPixelBufferGetBytesPerRow(nextBuffer));
    }
    [_lock lock];
    CVPixelBufferRef previous = _latestPixelBuffer;
  CEFAcceleratedFrameLease *previousLease = _latestFrameLease;
  const BOOL previousWasLeased = _latestPixelBufferIsLeased;
    _latestPixelBuffer = nextBuffer;
  _latestFrameLease = nil;
  _latestPixelBufferIsLeased = NO;
    _updateCount += 1;
    if (accelerated) {
        _acceleratedFrameCount += 1;
    } else {
        _cpuFrameCount += 1;
    }
    _width = (int)CVPixelBufferGetWidth(nextBuffer);
    _height = (int)CVPixelBufferGetHeight(nextBuffer);
    _lastCopyDurationMicros = durationMicros;
    _totalCopyDurationMicros += durationMicros;
    _maxCopyDurationMicros = MAX(_maxCopyDurationMicros, durationMicros);
    _copiedBytes += copiedBytes;
    if (partial) {
        _partialCopies += 1;
    } else {
        _fullFrameCopies += 1;
    }
    _damageCoverageSum += MIN(MAX(damageCoverage, 0.0), 1.0);
    _lastError = @"";
    [_lock unlock];

  // A pending lease was never borrowed by Flutter, so it has no GPU users.
  [previousLease releaseFrame];

    // The engine may still be compositing a borrowed MTLTexture view of
    // |previous|'s IOSurface; quarantine it instead of releasing so the pool
    // cannot re-vend that surface into an in-flight blit (diagonal-shear fix).
    if (previous) {
    if (previousWasLeased) {
      // A borrowed direct frame is protected by the callback-held lease,
      // not by this plugin's destination-buffer quarantine.
      CVBufferRelease(previous);
    } else {
        [self quarantineBuffer:previous];
    }
    }
    // Diagnostic: dump this exact published frame (no-op unless CEF_FRAME_CAPTURE
    // is set). _updateCount is the frame serial; safe to read on the producer
    // thread (its only writer is the just-completed locked section above).
    [self captureFrameIfEnabled:nextBuffer serial:_updateCount];
    [self scheduleFrameNotification];
}

- (void)updateBGRAWithBuffer:(const void*)buffer
                       width:(int)width
                      height:(int)height
                   dirtyRect:(CGRect)dirtyRect {
    if (!buffer || width <= 0 || height <= 0) {
        return;
    }

    const BOOL sizeChanged = !_pixelBufferPool ||
        _poolWidth != width || _poolHeight != height;
    const CFTimeInterval startedAt = CACurrentMediaTime();
    if (![self ensurePixelBufferPoolWidth:width height:height]) {
        return;
    }

    NSDictionary* allocationAttributes = @{
        (NSString*)kCVPixelBufferPoolAllocationThresholdKey:
            @(kCefOsrPoolAllocationThreshold),
    };
    CVPixelBufferRef nextBuffer = NULL;
    CVReturn poolStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault,
        _pixelBufferPool,
        (__bridge CFDictionaryRef)allocationAttributes,
        &nextBuffer);
    if (poolStatus != kCVReturnSuccess || !nextBuffer) {
        [self recordDroppedFrame:[NSString stringWithFormat:@"CVPixelBufferPool allocation failed: %d", poolStatus]];
        return;
    }

    const int destinationWidth = (int)CVPixelBufferGetWidth(nextBuffer);
    const int destinationHeight = (int)CVPixelBufferGetHeight(nextBuffer);
    if (destinationWidth != width || destinationHeight != height) {
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"CPU frame dimensions do not match destination buffer"];
        return;
    }

    const CGRect fullRect = CGRectMake(0, 0, destinationWidth, destinationHeight);
    BOOL partial = NO;
    CGRect copyRect = (sizeChanged || _forceFullFrameCopy)
        ? fullRect
        : [self copyRegionForBuffer:nextBuffer
                           fullRect:fullRect
                         frameDirty:dirtyRect
                          isPartial:&partial];
    copyRect = CGRectIntegral(CGRectIntersection(copyRect, fullRect));
    if (CGRectIsEmpty(copyRect)) {
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"CPU copy region is outside destination buffer"];
        return;
    }
    partial = partial && !sizeChanged && !_forceFullFrameCopy;
    const int copyX = (int)copyRect.origin.x;
    const int copyY = (int)copyRect.origin.y;
    const int copyW = (int)copyRect.size.width;
    const int copyH = (int)copyRect.size.height;

    CVPixelBufferLockBaseAddress(nextBuffer, 0);
    uint8_t* dest = (uint8_t*)CVPixelBufferGetBaseAddress(nextBuffer);
    const size_t destBytesPerRow = CVPixelBufferGetBytesPerRow(nextBuffer);
    const size_t sourceBytesPerRow = (size_t)width * 4;
    const uint8_t* source = (const uint8_t*)buffer;
    if (!dest || destBytesPerRow < sourceBytesPerRow) {
        CVPixelBufferUnlockBaseAddress(nextBuffer, 0);
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"CPU destination row stride is too small"];
        return;
    }
    if (ShouldLogResizeDebug()) {
        NSLog(@"CefOsrTexture: CEF_RESIZE_DEBUG paint=cpu textureId=%lld "
          @"requested=%dx%d scale=%.3f expected=%dx%d pool=%dx%d "
          @"incoming=%dx%d incomingBytesPerRow=%zu destination=%dx%d "
          @"CVPixelBufferGetBytesPerRow=%zu",
              (long long)_textureId,
              _requestedViewWidth, _requestedViewHeight, _effectiveScale,
              _expectedPixelWidth, _expectedPixelHeight,
              _poolWidth, _poolHeight, width, height, sourceBytesPerRow,
              destinationWidth, destinationHeight, destBytesPerRow);
    }
    for (int row = copyY; row < copyY + copyH; row++) {
        memcpy(dest + ((size_t)row * destBytesPerRow) + (size_t)copyX * 4,
               source + ((size_t)row * sourceBytesPerRow) + (size_t)copyX * 4,
               (size_t)copyW * 4);
    }
    CVPixelBufferUnlockBaseAddress(nextBuffer, 0);
    [self compositePopupIntoBuffer:nextBuffer];
    [self noteFramePublishedForBuffer:nextBuffer
                           frameDirty:dirtyRect
                             fullRect:fullRect];
    _forceFullFrameCopy = NO;

  [self invalidatePendingAsyncFrameLeases];
  [_lock lock];
  _lastFrameTransferMode = @"copied";
  [_lock unlock];

    const uint64_t durationMicros =
        (uint64_t)((CACurrentMediaTime() - startedAt) * 1000000.0);
    const double coverage =
        ((double)copyW * (double)copyH) / ((double)width * (double)height);
    [self publishPixelBuffer:nextBuffer
              durationMicros:durationMicros
                 accelerated:NO
                 copiedBytes:(uint64_t)copyW * (uint64_t)copyH * 4
              damageCoverage:coverage
                     partial:partial];
    const NSUInteger updateCount = [self updateCount];

    if (updateCount <= 3 || updateCount == 10 || updateCount == 30 || updateCount == 60) {
        NSLog(@"CefOsrTexture: update textureId=%lld count=%lu size=%dx%d "
          @"bytesPerRow=%zu partial=%d",
              (long long)_textureId,
              (unsigned long)updateCount,
              width,
              height,
              destBytesPerRow,
              (int)partial);
    }

}

- (BOOL)ensurePixelBufferPoolWidth:(int)width height:(int)height {
    // Runs before every pool allocation (both paint paths call this first) and
    // before the early returns below, so expired quarantined buffers are freed
    // back to the pool every frame — otherwise steady-state publishes would fill
    // the quarantine and starve the pool into dropped frames.
    [self drainQuarantine];
    if ((_expectedPixelWidth > 0 && width != _expectedPixelWidth) ||
        (_expectedPixelHeight > 0 && height != _expectedPixelHeight)) {
        if (ShouldLogResizeDebug()) {
            NSLog(@"CefOsrTexture: CEF_RESIZE_DEBUG reject-stale-frame "
            @"textureId=%lld requested=%dx%d scale=%.3f expected=%dx%d "
            @"incoming=%dx%d pool=%dx%d",
                  (long long)_textureId,
                  _requestedViewWidth, _requestedViewHeight, _effectiveScale,
                  _expectedPixelWidth, _expectedPixelHeight,
                  width, height, _poolWidth, _poolHeight);
        }
        [self recordDroppedFrame:[NSString stringWithFormat:
            @"Incoming frame %dx%d does not match requested size %dx%d",
            width, height, _expectedPixelWidth, _expectedPixelHeight]];
        return NO;
    }
    if (_pixelBufferPool && _poolWidth == width && _poolHeight == height) {
        return YES;
    }

    if (_pixelBufferPool) {
        // Defer destruction (see quarantinePool:) rather than freeing memory the
        // engine may still be sampling.
        [self quarantinePool:_pixelBufferPool];
        _pixelBufferPool = NULL;
    }
    _poolWidth = 0;
    _poolHeight = 0;
    // New pool means new buffer identities and a size change; prior damage
    // bookkeeping no longer applies.
    [self resetDamageHistory];
    _forceFullFrameCopy = YES;

    NSDictionary* poolAttributes = @{
        (NSString*)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    // Match the destination row pitch to the source IOSurface's pitch
    // (Chromium's allocator uses 128-byte row alignment; CoreVideo's default
    // here was 64, e.g. 13888 vs 13952 for width 3464). Byte forensics on
    // captured shear frames show the published buffer holding SOURCE-pitch
    // rows crammed at DEST pitch — the diagonal-shear shear is born in the
    // source->dest copy when the pitches differ. Equal pitches make even a
    // degenerate row-linear copy correct.
    NSDictionary* pixelAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey: @(width),
        (NSString*)kCVPixelBufferHeightKey: @(height),
        (NSString*)kCVPixelBufferBytesPerRowAlignmentKey: @128,
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVReturn status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttributes,
        (__bridge CFDictionaryRef)pixelAttributes,
        &_pixelBufferPool);
    if (status != kCVReturnSuccess || !_pixelBufferPool) {
        [self recordDroppedFrame:[NSString stringWithFormat:@"CVPixelBufferPoolCreate failed: %d", status]];
        return NO;
    }
    _poolWidth = width;
    _poolHeight = height;
    if (ShouldLogResizeDebug()) {
        NSLog(@"CefOsrTexture: CEF_RESIZE_DEBUG pool-created textureId=%lld "
          @"pool=%dx%d requested=%dx%d scale=%.3f",
              (long long)_textureId, _poolWidth, _poolHeight,
              _requestedViewWidth, _requestedViewHeight, _effectiveScale);
    }
    return YES;
}

- (void)invalidatePendingAsyncFrameLeases {
  [_lock lock];
  _surfaceGeneration += 1;
  [_lock unlock];
}

- (BOOL)canAcceptAcceleratedFrameLease {
  [_lock lock];
  const BOOL requested =
      ![_requestedFrameLeaseMode isEqualToString:@"copied"];
  const BOOL accepted =
      CEFAcceleratedFrameLeaseApiAvailable() && requested &&
      _acceptingFrames &&
      [_backend isEqualToString:@"acceleratedOsrTexture"];
  if (requested && !accepted) {
    _frameLeaseFallbackCount += 1;
  }
  [_lock unlock];
  return accepted;
}

- (BOOL)shouldUseDirectFrameLease {
  [_lock lock];
  const BOOL requestedDirect =
      [_requestedFrameLeaseMode isEqualToString:@"leased_direct"];
  const BOOL observed = _gpuCompletionApiObserved;
  [_lock unlock];
  return requestedDirect && observed && !_popupVisible;
}

- (NSString *)setFrameLeaseMode:(NSString *_Nullable)mode {
  NSString *selectedMode = @"copied";
  if ([mode isEqualToString:@"leased_async_blit"]) {
    selectedMode = @"leased_async_blit";
  } else if ([mode isEqualToString:@"leased_direct"]) {
    selectedMode = @"leased_direct";
  }
  if (!CEFAcceleratedFrameLeaseApiAvailable()) {
    selectedMode = @"copied";
  }

  CVPixelBufferRef staleBuffer = NULL;
  CEFAcceleratedFrameLease *staleLease = nil;
  [_lock lock];
  if (!_acceptingFrames) {
    selectedMode = @"copied";
  }
  const BOOL changed =
      ![_requestedFrameLeaseMode isEqualToString:selectedMode];
  _requestedFrameLeaseMode = [selectedMode copy];
  if (changed) {
    // Invalidates leased asynchronous blits. Their Metal completion retains
    // and releases the CEF source lease, but the destination must not publish
    // after a mode transition.
    _surfaceGeneration += 1;

    // A direct frame not yet borrowed by Flutter can be revoked immediately.
    // Once borrowed, the engine owns the producer lease through its GPU
    // completion callback and this ivar is already nil.
    if (_latestFrameLease) {
      staleBuffer = _latestPixelBuffer;
      staleLease = _latestFrameLease;
      _latestPixelBuffer = NULL;
      _latestFrameLease = nil;
      _latestPixelBufferIsLeased = NO;
    }
  }
  [_lock unlock];

  [staleLease releaseFrame];
  if (staleBuffer) {
    CVBufferRelease(staleBuffer);
  }
  return selectedMode;
}

- (BOOL)updateWithLeasedIOSurface:(IOSurfaceRef)ioSurface
                     format:(int)format
                  dirtyRect:(CGRect)dirtyRect
                      extra:(NSDictionary * _Nullable)extra
                            lease:(CEFAcceleratedFrameLease *)lease {
    if (!ioSurface || !lease || ![self canAcceptAcceleratedFrameLease]) {
    return NO;
  }
  if ([self shouldUseDirectFrameLease] &&
      [self tryUpdateWithDirectLeasedIOSurface:ioSurface
                                        format:format
                                     dirtyRect:dirtyRect
                                         extra:extra
                                         lease:lease]) {
    return YES;
  }
  return [self copyIOSurface:ioSurface
                      format:format
                   dirtyRect:dirtyRect
                       extra:extra
                  frameLease:lease];
}

- (BOOL)tryUpdateWithDirectLeasedIOSurface:(IOSurfaceRef)ioSurface
                                    format:(int)format
                                 dirtyRect:(CGRect)dirtyRect
                                     extra:(NSDictionary *_Nullable)extra
                                     lease:(CEFAcceleratedFrameLease *)lease {
  if (!ioSurface || !lease || format != CEF_COLOR_TYPE_BGRA_8888) {
    return NO;
  }

  const int width = (int)IOSurfaceGetWidth(ioSurface);
  const int height = (int)IOSurfaceGetHeight(ioSurface);
  if (width <= 0 || height <= 0 ||
      (_expectedPixelWidth > 0 && width != _expectedPixelWidth) ||
      (_expectedPixelHeight > 0 && height != _expectedPixelHeight)) {
    return NO;
  }

  NSDictionary *attributes = @{
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVPixelBufferRef nextBuffer = NULL;
  const CVReturn status = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault, ioSurface, (__bridge CFDictionaryRef)attributes,
      &nextBuffer);
  if (status != kCVReturnSuccess || !nextBuffer ||
      CVPixelBufferGetPixelFormatType(nextBuffer) !=
          kCVPixelFormatType_32BGRA) {
    if (nextBuffer) {
      CVBufferRelease(nextBuffer);
    }
    return NO;
  }

  // Direct frames do not need the destination pool. Retire it after the
  // first successful lease so the old copy-path IOSurfaces can age out.
  [self drainQuarantine];
  if (_pixelBufferPool) {
    [self quarantinePool:_pixelBufferPool];
    _pixelBufferPool = NULL;
    _poolWidth = 0;
    _poolHeight = 0;
  }

  _lastSourceExtra = extra;
  [_lock lock];
  CVPixelBufferRef previous = _latestPixelBuffer;
  CEFAcceleratedFrameLease *previousLease = _latestFrameLease;
  const BOOL previousWasLeased = _latestPixelBufferIsLeased;
  _latestPixelBuffer = nextBuffer;
  _latestFrameLease = lease;
  _latestPixelBufferIsLeased = YES;
  _updateCount += 1;
  _acceleratedFrameCount += 1;
  _zeroCopyFrameCount += 1;
  _lastFrameTransferMode = @"leased_direct";
  _lastPublishedLeasedFrameId = MAX(_lastPublishedLeasedFrameId, lease.frameId);
  _width = width;
  _height = height;
  _lastCopyDurationMicros = 0;
  _lastError = @"";
  [_lock unlock];

  // A superseded pending lease was never handed to the engine. Once the
  // engine borrows a frame, the completion block owns the lease instead and
  // this ivar is nil.
  [previousLease releaseFrame];
  if (previous) {
    if (previousWasLeased) {
      CVBufferRelease(previous);
    } else {
      [self quarantineBuffer:previous];
    }
  }
  [self scheduleFrameNotification];
  return YES;
}

- (void)updateWithIOSurface:(IOSurfaceRef)ioSurface
                     format:(int)format
                  dirtyRect:(CGRect)dirtyRect
                      extra:(NSDictionary *_Nullable)extra {
  [self noteUnleasedAcceleratedFrameFallbackIfRequested];
  [self copyIOSurface:ioSurface
               format:format
            dirtyRect:dirtyRect
                extra:extra
           frameLease:nil];
}

- (void)noteUnleasedAcceleratedFrameFallbackIfRequested {
  [_lock lock];
  if (_acceptingFrames &&
      ![_requestedFrameLeaseMode isEqualToString:@"copied"]) {
    // CEF's bounded admission returns rejected leases through the legacy
    // OnAcceleratedPaint callback. Count that path here; no lease object ever
    // reaches canAcceptAcceleratedFrameLease for it.
    _frameLeaseFallbackCount += 1;
  }
  [_lock unlock];
}

- (BOOL)copyIOSurface:(IOSurfaceRef)ioSurface
               format:(int)format
            dirtyRect:(CGRect)dirtyRect
                extra:(NSDictionary *_Nullable)extra
           frameLease:(CEFAcceleratedFrameLease *_Nullable)frameLease {
  if (!ioSurface) {
        [self recordDroppedFrame:@"CEF accelerated paint returned no IOSurface"];
        return NO;
    }
    _lastSourceExtra = extra;

    // Env-gated (CEF_DROP_PARTIAL_SOURCE): reject deliveries whose blitted
    // content region does not cover the full buffer. viz letterboxes resize
    // transitions (content_rect < coded_size) and, under load, can recycle a
    // pool buffer whose blit never landed at all — stale garbage that shows as
    // full-frame diagonal shred. Off by default until the capture manifest
    // proves which metadata signature the stale deliveries carry.
    static BOOL dropPartial = NO;
    static dispatch_once_t dropOnce;
    dispatch_once(&dropOnce, ^{
        const char* v = getenv("CEF_DROP_PARTIAL_SOURCE");
        dropPartial = v && v[0] != '\0' && strcmp(v, "0") != 0;
    });
    if (dropPartial && extra) {
        const int codedW = [extra[@"codedW"] intValue];
        const int codedH = [extra[@"codedH"] intValue];
        const int contentW = [extra[@"contentW"] intValue];
        const int contentH = [extra[@"contentH"] intValue];
        if (codedW > 0 && codedH > 0 &&
            (contentW < codedW - 2 || contentH < codedH - 2)) {
            _partialSourceDrops += 1;
            [self recordDroppedFrame:[NSString stringWithFormat:@"Partial source content %dx%d in "
                                           @"%dx%d buffer (letterbox/stale)",
                contentW, contentH, codedW, codedH]];
            return NO;
        }
    }
    if (format != CEF_COLOR_TYPE_BGRA_8888) {
        [self recordDroppedFrame:[NSString stringWithFormat:@"Unsupported CEF accelerated format: %d", format]];
        return NO;
    }
    if (!_metalDevice || !_metalCommandQueue) {
        [self recordDroppedFrame:@"Metal device or command queue unavailable"];
        return NO;
    }

    // CEF_BLIT_DELAY_US (diagnostic dial): stall N microseconds before the
    // blit. The pump services CEF in bursts of 3-4 deliveries; the newest
    // delivery in a burst can arrive before the GPU process's write into its
    // IOSurface has completed (Chromium does not bump IOSurface use counts, so
    // no macOS primitive can wait on it — the IOSurfaceLock fence below is
    // provably a no-op for cross-process writes). A small delay gives the
    // write time to land; if it eliminates the diagonal shred, the
    // read-before-write-complete race is confirmed and this becomes the
    // stopgap while a proper CEF-side sync patch is prepared.
    static useconds_t blitDelayUs = 0;
    static dispatch_once_t delayOnce;
    dispatch_once(&delayOnce, ^{
        const char* v = getenv("CEF_BLIT_DELAY_US");
        if (v && v[0] != '\0') {
            const long parsed = strtol(v, NULL, 10);
            blitDelayUs = (useconds_t)MAX(0L, MIN(parsed, 8000L));
        }
        if (blitDelayUs > 0) {
            NSLog(@"CefOsrTexture: CEF_BLIT_DELAY_US active: %u", blitDelayUs);
        }
    });
    if (!frameLease &&blitDelayUs > 0) {
        usleep(blitDelayUs);
    }

    // Source-write fence (diagonal-shear tearing fix). CEF's accelerated OSR
    // delivers this IOSurface through viz's FrameSinkVideoCapturer with NO
    // cross-process GPU fence (CefVideoConsumerOSR::OnFrameCaptured hands over
    // the raw surface; the sync token stays inside Chromium). Under GPU load,
    // viz's blit INTO the surface can still be executing in the GPU process
    // when this callback runs; a Metal read at that instant copies a
    // half-written, tile-ordered frame — captured as frames 568/573 in the
    // 2026-07-13 frame-capture session. IOSurfaceLock for CPU access waits for
    // pending GPU writes to the surface (the popup path CPU-reads under the
    // same lock and has never torn); an immediate unlock turns it into a pure
    // fence. NOT the reverted "lock/unlock after blit" experiment — that
    // locked the DESTINATION after the copy (pure latency, no sync); this
    // locks the SOURCE before it.
  if (!frameLease) {
    const CFTimeInterval fenceStart = CACurrentMediaTime();
    if (IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL) ==
        kIOSurfaceSuccess) {
        IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    } else {
        _sourceFenceFailures += 1;
    }
    _sourceFenceLastMicros =
        (uint64_t)((CACurrentMediaTime() - fenceStart) * 1e6);
    _sourceFenceMaxMicros = MAX(_sourceFenceMaxMicros, _sourceFenceLastMicros);
  } else {
    // Patched CEF delivers a lease only after Viz's capture copy has
    // completed, so the lease path needs neither a CPU fence nor a delay.
    _sourceFenceLastMicros = 0;
  }

    // CEF_SOURCE_TOUCH: full linear CPU read of every source byte before the
    // Metal blit. Diagnosis: frames CPU-read in full pre-blit appear never to
    // shear, while unsampled frames shear (writer lays rows at a stale pitch,
    // e.g. 14016 into a 13952-pitch surface). Bare IOSurfaceLock/Unlock (the
    // fence above) does NOT heal; the hypothesis is that a full linear READ
    // forces the kernel/GPU to materialize the surface's linear representation,
    // after which the cross-process Metal texture view reads correct texels.
    // If enabling this kills on-screen shear, it is both the confirmed
    // mechanism and a shippable embedder-side mitigation.
    static BOOL sourceTouch = NO;
    static dispatch_once_t sourceTouchOnce;
    dispatch_once(&sourceTouchOnce, ^{
        const char* v = getenv("CEF_SOURCE_TOUCH");
        sourceTouch = v && v[0] != '\0' && strcmp(v, "0") != 0;
        if (sourceTouch) {
            NSLog(@"CefOsrTexture: CEF_SOURCE_TOUCH active");
        }
    });
    if (sourceTouch && !frameLease) {
        const CFTimeInterval touchStart = CACurrentMediaTime();
        if (IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL) ==
            kIOSurfaceSuccess) {
            const size_t bytes =
                IOSurfaceGetBytesPerRow(ioSurface) * IOSurfaceGetHeight(ioSurface);
            void* base = IOSurfaceGetBaseAddress(ioSurface);
            if (base && bytes > 0) {
                if (bytes > _sourceTouchScratchSize) {
                    void* grown = realloc(_sourceTouchScratch, bytes);
                    if (grown) {
                        _sourceTouchScratch = grown;
                        _sourceTouchScratchSize = bytes;
                    }
                }
                if (_sourceTouchScratch && bytes <= _sourceTouchScratchSize) {
                    memcpy(_sourceTouchScratch, base, bytes);
                }
            }
            IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
        }
        _sourceTouchLastMicros =
            (uint64_t)((CACurrentMediaTime() - touchStart) * 1e6);
        _sourceTouchMaxMicros =
            MAX(_sourceTouchMaxMicros, _sourceTouchLastMicros);
    }

    // Pre-blit source dump (no-op unless CEF_FRAME_CAPTURE_SOURCE): the
    // pending publish serial is _updateCount+1 when this frame survives.
    [self captureSourceIfEnabled:ioSurface pendingSerial:_updateCount + 1];

    const int width = (int)IOSurfaceGetWidth(ioSurface);
    const int height = (int)IOSurfaceGetHeight(ioSurface);
    const BOOL sizeChanged = !_pixelBufferPool ||
        _poolWidth != width || _poolHeight != height;
    if (width <= 0 || height <= 0 ||
        ![self ensurePixelBufferPoolWidth:width height:height]) {
        return NO;
    }

    NSDictionary* allocationAttributes = @{
        (NSString*)kCVPixelBufferPoolAllocationThresholdKey:
            @(kCefOsrPoolAllocationThreshold),
    };
    CVPixelBufferRef nextBuffer = NULL;
    CVReturn poolStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault,
        _pixelBufferPool,
        (__bridge CFDictionaryRef)allocationAttributes,
        &nextBuffer);
    if (poolStatus != kCVReturnSuccess || !nextBuffer) {
        [self recordDroppedFrame:[NSString stringWithFormat:@"CVPixelBufferPool allocation failed: %d", poolStatus]];
        return NO;
    }

    const int destinationWidth = (int)CVPixelBufferGetWidth(nextBuffer);
    const int destinationHeight = (int)CVPixelBufferGetHeight(nextBuffer);
    const size_t sourceBytesPerRow = IOSurfaceGetBytesPerRow(ioSurface);
    const size_t destinationBytesPerRow =
        CVPixelBufferGetBytesPerRow(nextBuffer);
    if (destinationWidth != width || destinationHeight != height ||
        sourceBytesPerRow < (size_t)width * 4 ||
        destinationBytesPerRow < (size_t)destinationWidth * 4) {
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"Accelerated frame dimensions do not match destination buffer"];
        return NO;
    }
    if (ShouldLogResizeDebug()) {
        NSLog(@"CefOsrTexture: CEF_RESIZE_DEBUG paint=accelerated textureId=%lld "
          @"requested=%dx%d scale=%.3f expected=%dx%d pool=%dx%d "
          @"incoming=%dx%d incomingBytesPerRow=%zu destination=%dx%d "
          @"CVPixelBufferGetBytesPerRow=%zu",
              (long long)_textureId,
              _requestedViewWidth, _requestedViewHeight, _effectiveScale,
              _expectedPixelWidth, _expectedPixelHeight,
              _poolWidth, _poolHeight, width, height, sourceBytesPerRow,
              destinationWidth, destinationHeight, destinationBytesPerRow);
    }

    IOSurfaceRef destinationSurface = CVPixelBufferGetIOSurface(nextBuffer);
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:(NSUInteger)width
                                                         height:(NSUInteger)height
                                                      mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;

    id<MTLTexture> sourceTexture =
        [_metalDevice newTextureWithDescriptor:descriptor iosurface:ioSurface plane:0];
    id<MTLTexture> destinationTexture =
        [_metalDevice newTextureWithDescriptor:descriptor iosurface:destinationSurface plane:0];
    if (!sourceTexture || !destinationTexture) {
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"Could not create Metal texture views for IOSurfaces"];
        return NO;
    }

    const CGRect fullRect = CGRectMake(0, 0, destinationWidth, destinationHeight);
    BOOL partial = NO;
    CGRect copyRect = (sizeChanged || _forceFullFrameCopy)
        ? fullRect
        : [self copyRegionForBuffer:nextBuffer
                           fullRect:fullRect
                         frameDirty:dirtyRect
                          isPartial:&partial];
    copyRect = CGRectIntegral(CGRectIntersection(copyRect, fullRect));
    if (CGRectIsEmpty(copyRect)) {
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"Metal copy region is outside destination buffer"];
        return NO;
    }
    partial = partial && !sizeChanged && !_forceFullFrameCopy;

    const CFTimeInterval startedAt = CACurrentMediaTime();
    id<MTLCommandBuffer> commandBuffer = [_metalCommandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    if (!commandBuffer || !blitEncoder) {
        CVBufferRelease(nextBuffer);
        [self recordDroppedFrame:@"Could not create Metal blit command"];
        return NO;
    }

    if (partial) {
        const MTLOrigin origin = MTLOriginMake((NSUInteger)copyRect.origin.x,
                                               (NSUInteger)copyRect.origin.y,
                                               0);
        const MTLSize size = MTLSizeMake((NSUInteger)copyRect.size.width,
                                         (NSUInteger)copyRect.size.height,
                                         1);
        [blitEncoder copyFromTexture:sourceTexture
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:origin
                          sourceSize:size
                           toTexture:destinationTexture
                    destinationSlice:0
                    destinationLevel:0
                   destinationOrigin:origin];
    } else {
        [blitEncoder copyFromTexture:sourceTexture toTexture:destinationTexture];
    }
    [blitEncoder endEncoding];
  if (frameLease) {
    const useconds_t completionDelayUs = LeasedFrameCompletionDelayUs();
    id<MTLSharedEvent> completionGate =
        completionDelayUs > 0 ? [_metalDevice newSharedEvent] : nil;
    if (completionGate) {
      [commandBuffer encodeWaitForEvent:completionGate value:1];
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)completionDelayUs * NSEC_PER_USEC),
          dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            completionGate.signaledValue = 1;
          });
    }
  }
  const double coverage = (copyRect.size.width * copyRect.size.height) /
                          ((double)width * (double)height);
  const uint64_t copiedBytes =
      (uint64_t)copyRect.size.width * (uint64_t)copyRect.size.height * 4;

  if (frameLease) {
    [_lock lock];
    const uint64_t generation = _surfaceGeneration;
    [_lock unlock];
    const uint64_t frameId = frameLease.frameId;
    CefOsrTexture *strongSelf = self;
    [commandBuffer
        addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
          // Metal has finished reading the CEF source. Viz may recycle
          // that IOSurface now; publishing the independent destination
          // buffer can happen later on the main thread.
          [frameLease releaseFrame];

    const uint64_t durationMicros =
        (uint64_t)((CACurrentMediaTime() - startedAt) * 1000000.0);
          NSString *error =
              completedCommandBuffer.status == MTLCommandBufferStatusCompleted
                  ? nil
                  : (completedCommandBuffer.error.localizedDescription
                         ?: @"Asynchronous Metal blit failed");
          dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf->_lock lock];
    const BOOL stale =
                !strongSelf->_acceptingFrames ||
                strongSelf->_surfaceGeneration != generation ||
                frameId <= strongSelf->_lastPublishedLeasedFrameId;
            if (stale) {
              strongSelf->_staleAsyncLeaseDropCount += 1;
            } else if (!error) {
              strongSelf->_lastPublishedLeasedFrameId = frameId;
              strongSelf->_leasedAsyncBlitFrameCount += 1;
              strongSelf->_lastFrameTransferMode = @"leased_async_blit";
            }
            [strongSelf->_lock unlock];

            if (stale) {
              CVBufferRelease(nextBuffer);
              return;
            }
            if (error) {
              CVBufferRelease(nextBuffer);
              [strongSelf recordDroppedFrame:error];
              return;
            }
            [strongSelf compositePopupIntoBuffer:nextBuffer];
            [strongSelf noteFramePublishedForBuffer:nextBuffer
                                         frameDirty:dirtyRect
                                           fullRect:fullRect];
            strongSelf->_forceFullFrameCopy = NO;
            [strongSelf publishPixelBuffer:nextBuffer
                            durationMicros:durationMicros
                               accelerated:YES
                               copiedBytes:copiedBytes
                            damageCoverage: coverage
                                   partial:partial];
          });
        }];
    [commandBuffer commit];
    return YES;
  }

  [commandBuffer commit];
  // Stock CEF recycles its source IOSurface as soon as this callback returns.
  // Complete the compatibility copy here so no GPU work accesses it later.
  [commandBuffer waitUntilCompleted];

  if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
    NSString *message =
        commandBuffer.error.localizedDescription ?: @"Metal blit failed";
    CVBufferRelease(nextBuffer);
    [self recordDroppedFrame:message];
    return NO;
  }
  [self compositePopupIntoBuffer:nextBuffer];
  [self noteFramePublishedForBuffer:nextBuffer
                         frameDirty:dirtyRect
                           fullRect:fullRect];
  _forceFullFrameCopy = NO;

  const uint64_t durationMicros =
      (uint64_t)((CACurrentMediaTime() - startedAt) * 1000000.0);
  // A capacity fallback is newer than every async copy already in flight.
  // Invalidate those completion blocks before publishing this synchronous
  // result, otherwise a queued older completion can repaint stale content.
  [self invalidatePendingAsyncFrameLeases];
  [_lock lock];
  _lastFrameTransferMode = @"copied";
  [_lock unlock];
    [self publishPixelBuffer:nextBuffer
              durationMicros:durationMicros
                 accelerated:YES
                 copiedBytes:copiedBytes
              damageCoverage:coverage
                     partial:partial];
  return YES;
}

- (void)setTargetFps:(int)targetFps {
    [_lock lock];
    _targetFps = targetFps;
    [_lock unlock];
}

- (void)setEffectiveScale:(double)effectiveScale {
    [_lock lock];
    _effectiveScale = effectiveScale;
    [_lock unlock];
}

- (void)setRequestedViewWidth:(int)width
                       height:(int)height
               effectiveScale:(double)effectiveScale {
    const int requestedWidth = MAX(1, width);
    const int requestedHeight = MAX(1, height);
    const double scale = effectiveScale > 0 && isfinite(effectiveScale)
        ? MAX(1.0, effectiveScale)
        : 1.0;
    const int expectedWidth = (int)ceil(requestedWidth * scale);
    const int expectedHeight = (int)ceil(requestedHeight * scale);
    if (_requestedViewWidth == requestedWidth &&
        _requestedViewHeight == requestedHeight &&
        _expectedPixelWidth == expectedWidth &&
        _expectedPixelHeight == expectedHeight) {
        _effectiveScale = scale;
        return;
    }

    if (ShouldLogResizeDebug()) {
        NSLog(@"CefOsrTexture: CEF_RESIZE_DEBUG transition textureId=%lld "
          @"requested=%dx%d scale=%.3f expected=%dx%d oldRequested=%dx%d "
          @"oldExpected=%dx%d pool=%dx%d latest=%dx%d",
              (long long)_textureId,
              requestedWidth, requestedHeight, scale,
              expectedWidth, expectedHeight,
              _requestedViewWidth, _requestedViewHeight,
              _expectedPixelWidth, _expectedPixelHeight,
              _poolWidth, _poolHeight, _width, _height);
    }
    _requestedViewWidth = requestedWidth;
    _requestedViewHeight = requestedHeight;
    _effectiveScale = scale;
    _expectedPixelWidth = expectedWidth;
    _expectedPixelHeight = expectedHeight;

    [_lock lock];
  _surfaceGeneration += 1;
  [_lock unlock];

  [self drainQuarantine];
    if (_pixelBufferPool) {
        // Defer destruction: the engine may still sample an old-pool IOSurface,
        // and the new pool must not recycle that memory mid-read.
        [self quarantinePool:_pixelBufferPool];
        _pixelBufferPool = NULL;
    }
    _poolWidth = 0;
    _poolHeight = 0;
    [self resetDamageHistory];
    _forceFullFrameCopy = YES;

    [_lock lock];
    CVPixelBufferRef staleBuffer = _latestPixelBuffer;
  CEFAcceleratedFrameLease *staleLease = _latestFrameLease;
  const BOOL staleWasLeased = _latestPixelBufferIsLeased;
    _latestPixelBuffer = NULL;
  _latestFrameLease = nil;
  _latestPixelBufferIsLeased = NO;
    [_lock unlock];
  [staleLease releaseFrame];
    // Quarantine (not release): this is exactly the buffer the engine most
    // likely still holds a borrowed texture view of across the resize.
    if (staleBuffer) {
    if (staleWasLeased) {
      CVBufferRelease(staleBuffer);
    } else {
        [self quarantineBuffer:staleBuffer];
    }
    }
}

- (NSDictionary<NSString*, id>*)performanceStats {
    [_lock lock];
    const NSUInteger copiedFrameCount =
        _fullFrameCopies + _partialCopies;
    const double averageDamageCoverage =
        copiedFrameCount == 0
            ? 0.0
            : _damageCoverageSum / (double)copiedFrameCount;
    NSDictionary<NSString*, id>* stats = @{
        @"backend": _backend ?: @"osrTexture",
        @"frameCount": @(_updateCount),
        @"acceleratedFrameCount": @(_acceleratedFrameCount),
        @"cpuFrameCount": @(_cpuFrameCount),
        @"textureReadCount": @(_textureReadCount),
        @"uniqueTextureReadCount": @(_uniqueTextureReadCount),
        @"textureReadAttemptCount": @(_textureReadAttemptCount),
        @"droppedFrameCount": @(_droppedFrameCount),
        @"coalescedFrameCount": @(_coalescedFrameCount),
    @"zeroCopyFrameCount" : @(_zeroCopyFrameCount),
    @"leasedAsyncBlitFrameCount" : @(_leasedAsyncBlitFrameCount),
    @"staleAsyncLeaseDropCount" : @(_staleAsyncLeaseDropCount),
    @"frameLeaseFallbackCount" : @(_frameLeaseFallbackCount),
    @"frameTransferMode" : _lastFrameTransferMode ?: @"copied",
    @"requestedFrameTransferMode" : _requestedFrameLeaseMode ?: @"copied",
    @"frameLeaseApiAvailable" :
        @(CEFAcceleratedFrameLeaseApiAvailable() ? 1 : 0),
    @"gpuCompletionApiObserved" : @(_gpuCompletionApiObserved ? 1 : 0),
        @"width": @(_width),
        @"height": @(_height),
        @"totalCopyDurationMicros": @(_totalCopyDurationMicros),
        @"maxCopyDurationMicros": @(_maxCopyDurationMicros),
        @"lastCopyDurationMicros": @(_lastCopyDurationMicros),
        @"copiedBytes": @(_copiedBytes),
        @"fullFrameCopies": @(_fullFrameCopies),
        @"partialCopies": @(_partialCopies),
        @"averageDamageCoverage": @(averageDamageCoverage),
        @"targetFps": @(_targetFps),
        @"effectiveScale": @(_effectiveScale),
        @"popupVisible": @(_popupVisible ? 1 : 0),
        // IOSurface quarantine (diagonal-shear fix) — depth is how many retired
        // buffers/pools are currently held past the engine's composition read;
        // forcedReleases > 0 means the window is starving the pool (should be 0).
        @"quarantineDepth": @((NSUInteger)_quarantinedBuffers.size()),
        @"quarantinePoolsHeld": @((NSUInteger)_quarantinedPools.size()),
        @"quarantineReleasedTotal": @(_quarantineReleasedTotal),
        @"quarantineForcedReleases": @(_quarantineForcedReleases),
        // Source-write fence (tearing fix): cost of waiting out the GPU
        // process's in-flight write to the delivered IOSurface.
        @"sourceFenceLastMicros": @(_sourceFenceLastMicros),
        @"sourceFenceMaxMicros": @(_sourceFenceMaxMicros),
        @"sourceFenceFailures": @(_sourceFenceFailures),
        // CEF_SOURCE_TOUCH: cost of the full linear CPU read pre-blit.
        @"sourceTouchLastMicros": @(_sourceTouchLastMicros),
        @"sourceTouchMaxMicros": @(_sourceTouchMaxMicros),
        @"partialSourceDrops": @(_partialSourceDrops),
        @"lastError": _lastError ?: @"",
    };
    [_lock unlock];
    return stats;
}

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
    [_lock lock];
  _textureReadAttemptCount += 1;
  // A direct frame must never escape without its GPU-completion callback.
  // This path remains the stock-engine compatibility fallback; direct lease
  // admission is enabled only after the custom method below is observed.
  CVPixelBufferRef buffer = _latestPixelBuffer && !_latestPixelBufferIsLeased
                                ? CVBufferRetain(_latestPixelBuffer)
                                : NULL;
  if (buffer) {
    _textureReadCount += 1;
    if (_lastTextureReadUpdateCount != _updateCount) {
      _lastTextureReadUpdateCount = _updateCount;
      _uniqueTextureReadCount += 1;
    }
  }
  [_lock unlock];
  return buffer;
}

- (CVPixelBufferRef _Nullable)copyPixelBufferWithGpuCompletionCallback:
    (CefOsrGpuCompletionCallback _Nullable __autoreleasing *_Nullable)callback {
  if (callback) {
    *callback = nil;
  }
  [_lock lock];
  _gpuCompletionApiObserved = YES;
  _textureReadAttemptCount += 1;
  if ((_latestFrameLease && !callback) ||
      (_latestPixelBufferIsLeased && !_latestFrameLease)) {
    // A direct IOSurface may be handed to the engine only once. After the
    // lease is transferred, duplicate texture reads reuse Flutter's
    // existing tracked image rather than creating an untracked wrapper.
    [_lock unlock];
    return NULL;
  }
    CVPixelBufferRef buffer = _latestPixelBuffer ? CVBufferRetain(_latestPixelBuffer) : NULL;
  CEFAcceleratedFrameLease *lease = _latestFrameLease;
  _latestFrameLease = nil;
    if (buffer) {
        _textureReadCount += 1;
        if (_lastTextureReadUpdateCount != _updateCount) {
          _lastTextureReadUpdateCount = _updateCount;
          _uniqueTextureReadCount += 1;
        }
    }
    [_lock unlock];

  if (lease && callback) {
    *callback = [^{
      [lease releaseFrame];
    } copy];
  }
    return buffer;
}

- (void)onTextureUnregistered:(NSObject<FlutterTexture>*)texture {
    [_lock lock];
    CVPixelBufferRef buffer = _latestPixelBuffer;
  CEFAcceleratedFrameLease *lease = _latestFrameLease;
  _acceptingFrames = NO;
  _surfaceGeneration += 1;
    _latestPixelBuffer = NULL;
  _latestFrameLease = nil;
  _latestPixelBufferIsLeased = NO;
    [_lock unlock];
  [lease releaseFrame];
    if (buffer) {
        CVBufferRelease(buffer);
    }
    [self flushQuarantine];
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
}

@end

static BOOL ShouldLogFrameSync(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_FRAME_DEBUG");
        if (!value || value[0] == '\0') {
            enabled = NO;
            return;
        }
        // Treat "0" as off; anything else as on.
        enabled = (strcmp(value, "0") != 0);
    });
    return enabled;
}

static BOOL ShouldLogWindowTracking(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_WINDOW_DEBUG");
        if (!value || value[0] == '\0') {
            enabled = ShouldLogFrameSync();
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
            enabled = ShouldLogWindowTracking();
            return;
        }
        enabled = (strcmp(value, "0") != 0);
    });
    return enabled;
}

static NSString* DefaultCefCachePath(void) {
    NSString* tmp = NSTemporaryDirectory();
    NSString* bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"webview_cef";
    const int pid = [[NSProcessInfo processInfo] processIdentifier];
    return [tmp stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cef_cache_%@_%d", bundleId, pid]];
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

static const NSTimeInterval kCreateBrowserWindowRetryIntervalSeconds = 0.05;
static const NSInteger kCreateBrowserWindowRetryLimit = 40;
static const NSUInteger kPresentationMetricsEmitInterval = 25;

static BOOL ViewLooksLikeFlutterHost(NSView* view) {
    if (!view) return NO;
    NSString* className = NSStringFromClass([view class]);
    return [className containsString:@"FlutterView"];
}

static NSView* FindFlutterHostViewInTree(NSView* rootView) {
    if (!rootView) return nil;
    if (ViewLooksLikeFlutterHost(rootView)) {
        return rootView;
    }
    for (NSView* subview in rootView.subviews) {
        NSView* match = FindFlutterHostViewInTree(subview);
        if (match) {
            return match;
        }
    }
    return nil;
}

static NSString* StringOrNil(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) {
        NSString* trimmed = [(NSString*)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return trimmed.length > 0 ? trimmed : nil;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString* trimmed = [[value stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return trimmed.length > 0 ? trimmed : nil;
    }
    return nil;
}

static NSInteger IntegerOrDefault(id value, NSInteger fallback) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber*)value integerValue];
    }
    NSString* stringValue = StringOrNil(value);
    if (!stringValue) return fallback;
    return [stringValue integerValue];
}

static BOOL BoolOrDefault(id value, BOOL fallback) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber*)value boolValue];
    }
    NSString* stringValue = [[StringOrNil(value) lowercaseString] copy];
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

static NSString* NormalizeRenderBackendName(id value) {
    NSString* backend = StringOrNil(value) ?: @"nativeView";
    if ([backend isEqualToString:@"osrTexture"] ||
        [backend isEqualToString:@"acceleratedOsrTexture"]) {
        return backend;
    }
    return @"nativeView";
}

static double EffectiveOsrTextureScale(double requestedScale, NSView* view) {
    if (requestedScale > 0 && isfinite(requestedScale)) {
        return MAX(1.0, requestedScale);
    }
    NSScreen* screen = view.window.screen ?: NSScreen.mainScreen;
    return MAX(1.0, screen ? screen.backingScaleFactor : 1.0);
}

static NSArray<NSString*>* StringArrayOrEmpty(id value) {
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (id item in (NSArray*)value) {
        NSString* stringValue = StringOrNil(item);
        if (stringValue.length > 0) {
            [out addObject:stringValue];
        }
    }
    return [out copy];
}

static NSDictionary<NSString*, id>* DictOrEmpty(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) return @{};
    return (NSDictionary*)value;
}

static FlutterError* FlutterErrorFromNSError(NSError* error, NSString* fallbackCode) {
    NSDictionary* userInfo = error.userInfo ?: @{};
    NSString* code = [userInfo[@"flutterCode"] isKindOfClass:[NSString class]]
        ? (NSString*)userInfo[@"flutterCode"]
        : fallbackCode;
    return [FlutterError errorWithCode:code ?: @"NATIVE_ERROR"
                               message:error.localizedDescription ?: @"Native operation failed"
                               details:userInfo[@"details"]];
}

// Flutter provides geometry in logical pixels using a top-left origin (y grows down).
// AppKit NSView frames are expressed in the superview's coordinate system, which may be
// flipped (top-left) or non-flipped (bottom-left). Convert Flutter rects into the
// host NSView coordinate space where we attach the native container.
static NSRect ConvertFlutterRectToHostRect(NSView* flutterView,
                                          NSView* hostView,
                                          NSRect flutterTopLeftRect,
                                          CGFloat flutterViewHeightOverride) {
    if (!flutterView) {
        return flutterTopLeftRect;
    }

    // First, express the rect in the flutterView coordinate system.
    NSRect rectInFlutterView = flutterTopLeftRect;
    if (![flutterView isFlipped]) {
        CGFloat boundsHeight = flutterView.bounds.size.height;
        if (flutterViewHeightOverride > 0) {
            // Some callers may provide a viewHeight from a nested layout root
            // instead of the real Flutter NSView bounds height. Using that
            // stale/partial value causes visible Y drift. Prefer native bounds
            // unless the override closely matches.
            const CGFloat delta = fabs(flutterViewHeightOverride - boundsHeight);
            if (delta <= 2.0) {
                boundsHeight = flutterViewHeightOverride;
            } else if (ShouldLogFrameSync()) {
                NSLog(@"FlutterCefBrowserPlugin: ignoring viewHeight override %.2f "
              @"(native bounds %.2f)",
                      flutterViewHeightOverride,
                      boundsHeight);
            }
        }
        rectInFlutterView.origin.y = boundsHeight - flutterTopLeftRect.origin.y - flutterTopLeftRect.size.height;
    }

    if (!hostView || hostView == flutterView) {
        return rectInFlutterView;
    }

    // Then convert to the hostView coordinate system (handles flipped/non-flipped and origins).
    return [flutterView convertRect:rectInFlutterView toView:hostView];
}

static void startMessageLoop(void) {
    // CEF's OnScheduleMessagePumpWork handles message loop pumping
    // Just log that we're ready
    NSLog(@"FlutterCefBrowserPlugin: CEF message loop managed by "
        @"OnScheduleMessagePumpWork");
}

static int NextPluginInstanceId(void) {
    static std::atomic<int> nextId{1};
    const int id = nextId.fetch_add(1);
    // Keep IDs positive when encoded into a signed 32-bit browserId (see Dart side composition).
    if (id > 0x7FFF) {
        return 1;
    }
    return id;
}

@class FlutterCefBrowserPlugin;

@interface CEFWindowDelegateProxy : NSObject <NSWindowDelegate>
@property (nonatomic, weak) FlutterCefBrowserPlugin* plugin;
@property (nonatomic, weak) id<NSWindowDelegate> originalDelegate;
@end

@interface FlutterCefBrowserPlugin (WindowCloseInterceptor)
- (BOOL)_handleWindowShouldClose:(NSWindow*)window;
@end

@implementation CEFWindowDelegateProxy

- (BOOL)windowShouldClose:(id)sender {
    NSWindow* window = [sender isKindOfClass:[NSWindow class]] ? (NSWindow*)sender : nil;
    FlutterCefBrowserPlugin* plugin = self.plugin;
    if (plugin && window) {
        return [plugin _handleWindowShouldClose:window];
    }

    id<NSWindowDelegate> original = self.originalDelegate;
    if (original && [original respondsToSelector:@selector(windowShouldClose:)]) {
        return [original windowShouldClose:sender];
    }
    return YES;
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return self.originalDelegate;
}

- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(windowShouldClose:)) {
        return YES;
    }
    id<NSWindowDelegate> original = self.originalDelegate;
    return [super respondsToSelector:selector] || (original && [original respondsToSelector:selector]);
}

@end

@implementation FlutterCefBrowserPlugin {
    FlutterMethodChannel* _methodChannel;
    FlutterEventChannel* _browserEventChannel;
    FlutterEventChannel* _downloadEventChannel;
    FlutterEventChannel* _consoleEventChannel;
    FlutterEventChannel* _networkEventChannel;
    NSObject<FlutterTextureRegistry>* _textureRegistry;

    FlutterEventSink _browserEventSink;
    FlutterEventSink _downloadEventSink;
    FlutterEventSink _consoleEventSink;
	    FlutterEventSink _networkEventSink;

		std::map<int, NSView*> _browserViews;
        std::map<int, NSView*> _browserHostViews;
		std::map<int, NSRect> _lastRequestedFrames;
        std::map<int, NSString*> _renderBackendsByBrowserId;
        NSMutableDictionary<NSNumber*, CefOsrTexture*>* _osrTexturesByBrowserId;
        NSMutableDictionary<NSNumber*, NSNumber*>* _osrTextureIdsByBrowserId;
	uint64_t _nativeFrameReapplyGeneration;
	NSUInteger _nativeReapplyScheduledCount;
	NSUInteger _nativeReapplyExecutedCount;
	NSUInteger _setViewFrameCount;
	NSUInteger _setVisibleCount;
	NSUInteger _promoteContainerCount;
	NSUInteger _presentationMetricsDirtyEvents;
	NSMutableDictionary<NSString*, NSNumber*>* _nativeReapplyReasonCounts;

	NSView* _flutterView;  // Store the Flutter view from registrar
    __weak NSViewController* _flutterViewController;

    NSMutableDictionary<NSNumber*, NSDictionary*>* _downloadMetaById;
    NSMutableDictionary<NSNumber*, NSString*>* _createRequestIdsByBrowserId;
    NSMutableDictionary<NSNumber*, NSDate*>* _createStartedAtByBrowserId;
    NSMutableDictionary<NSNumber*, NSNumber*>* _browserLifecycleTokensByBrowserId;
    NSMutableDictionary<NSNumber*, NSNumber*>* _requestedVisibilityByBrowserId;
    NSMutableDictionary<NSNumber*, NSNumber*>* _appliedVisibilityByBrowserId;
    NSUInteger _nextBrowserLifecycleToken;

	    int _instanceId;

			    NSMutableSet<NSNumber*>* _ownedBrowserIds;
			    NSMutableSet<NSNumber*>* _focusedBrowserIds;
                NSNumber* _lastFocusedBrowserId;
			    NSMutableSet<NSNumber*>* _programmaticBrowserCloseIds;

		    BOOL _trackingWindowEvents;
		    BOOL _frameSyncRequestScheduled;
		    BOOL _isWindowClosing;
			    id _windowDidResizeObserver;
			    id _windowDidEndLiveResizeObserver;
			    id _windowDidMoveObserver;
			    id _windowDidChangeBackingObserver;
			    id _windowDidChangeOcclusionStateObserver;
                id _windowDidBecomeKeyObserver;
                id _windowDidResignKeyObserver;
                id _windowDidBecomeMainObserver;
                id _windowDidResignMainObserver;
                id _windowDidMiniaturizeObserver;
                id _windowDidDeminiaturizeObserver;
			    id _workspaceActiveSpaceDidChangeObserver;
			    id _appDidBecomeActiveObserver;
			    id _appDidResignActiveObserver;
				    id _windowWillCloseObserver;
			    id _flutterViewFrameObserver;
			    id _flutterViewBoundsObserver;
			    __weak NSWindow* _trackedWindow;
			    __weak id<NSWindowDelegate> _originalWindowDelegate;
			    CEFWindowDelegateProxy* _windowDelegateProxy;
			    NSTimer* _windowCloseRetryTimer;
				    BOOL _windowCloseRequested;
            NSMutableDictionary<NSString*, id>* _windowCloseTransaction;
            NSUInteger _nextWindowCloseTransactionId;
            NSInteger _gracefulCloseTimeoutMs;
            BOOL _appIsActive;
            BOOL _windowOcclusionVisible;
            BOOL _windowKeyOrMain;
            BOOL _windowCanPresentBrowserViews;
            BOOL _presentationReconcileInProgress;
	}

- (instancetype)init {
    self = [super init];
    if (self) {
        _downloadMetaById = [NSMutableDictionary dictionary];
        _createRequestIdsByBrowserId = [NSMutableDictionary dictionary];
        _createStartedAtByBrowserId = [NSMutableDictionary dictionary];
        _browserLifecycleTokensByBrowserId = [NSMutableDictionary dictionary];
        _requestedVisibilityByBrowserId = [NSMutableDictionary dictionary];
        _appliedVisibilityByBrowserId = [NSMutableDictionary dictionary];
        _osrTexturesByBrowserId = [NSMutableDictionary dictionary];
        _osrTextureIdsByBrowserId = [NSMutableDictionary dictionary];
        _nativeReapplyReasonCounts = [NSMutableDictionary dictionary];
        _instanceId = NextPluginInstanceId();
	        _ownedBrowserIds = [NSMutableSet set];
	        _focusedBrowserIds = [NSMutableSet set];
            _lastFocusedBrowserId = nil;
	        _programmaticBrowserCloseIds = [NSMutableSet set];
        _trackingWindowEvents = NO;
        _frameSyncRequestScheduled = NO;
        _isWindowClosing = NO;
        _windowCloseRequested = NO;
	        _windowCloseTransaction = nil;
	        _nextWindowCloseTransactionId = 1;
	        _gracefulCloseTimeoutMs = 1200;
		        _appIsActive = NSApp ? NSApp.isActive : YES;
		        _windowOcclusionVisible = YES;
                _windowKeyOrMain = YES;
		        _windowCanPresentBrowserViews = YES;
                _presentationReconcileInProgress = NO;
	        _nativeFrameReapplyGeneration = 0;
        _nativeReapplyScheduledCount = 0;
        _nativeReapplyExecutedCount = 0;
        _setViewFrameCount = 0;
        _setVisibleCount = 0;
        _promoteContainerCount = 0;
	        _presentationMetricsDirtyEvents = 0;
            _nextBrowserLifecycleToken = 0;
            [FlutterCefBrowserPluginInstances() addObject:self];
	    }
	    return self;
	}

- (BOOL)hasFocusedBrowser {
    return _focusedBrowserIds.count > 0;
}

- (BOOL)isOsrBrowserId:(int)browserId {
    auto it = _renderBackendsByBrowserId.find(browserId);
    return it != _renderBackendsByBrowserId.end() &&
        ([it->second isEqualToString:@"osrTexture"] ||
         [it->second isEqualToString:@"acceleratedOsrTexture"]);
}

- (void)releaseOsrTextureForBrowserNumber:(NSNumber*)browserNum {
    if (!browserNum) return;
    NSNumber* textureId = _osrTextureIdsByBrowserId[browserNum];
    if (textureId != nil && _textureRegistry) {
        [_textureRegistry unregisterTexture:textureId.longLongValue];
    }
    [_osrTextureIdsByBrowserId removeObjectForKey:browserNum];
    [_osrTexturesByBrowserId removeObjectForKey:browserNum];
}

- (void)markBrowserNumber:(NSNumber*)browserNum focused:(BOOL)focused {
    if (!browserNum) return;
    if (focused) {
        [_focusedBrowserIds addObject:browserNum];
        _lastFocusedBrowserId = browserNum;
    } else {
        [_focusedBrowserIds removeObject:browserNum];
        if ([_lastFocusedBrowserId isEqualToNumber:browserNum]) {
            _lastFocusedBrowserId = nil;
        }
    }
    [self syncGlobalBrowserFocusFlag];
}

- (NSArray<NSNumber*>*)focusedBrowserCandidates {
    NSMutableArray<NSNumber*>* candidates = [NSMutableArray array];
    if (_lastFocusedBrowserId && [_focusedBrowserIds containsObject:_lastFocusedBrowserId]) {
        [candidates addObject:_lastFocusedBrowserId];
    }
    for (NSNumber* browserNum in _focusedBrowserIds) {
        if (_lastFocusedBrowserId && [browserNum isEqualToNumber:_lastFocusedBrowserId]) {
            continue;
        }
        [candidates addObject:browserNum];
    }
    return candidates;
}

- (BOOL)performFocusedBrowserCommand:(NSString*)command inWindow:(NSWindow*)window {
    if (![NSThread isMainThread]) {
        __block BOOL handled = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            handled = [self performFocusedBrowserCommand:command inWindow:window];
        });
        return handled;
    }
    if (command.length == 0 || !window) {
        return NO;
    }

    for (NSNumber* browserNum in [self focusedBrowserCandidates]) {
        const int browserId = browserNum.intValue;
        if (![_ownedBrowserIds containsObject:browserNum] ||
            [_programmaticBrowserCloseIds containsObject:browserNum]) {
            continue;
        }
        auto hostIt = _browserHostViews.find(browserId);
        NSView* ownerHostView = (hostIt != _browserHostViews.end()) ? hostIt->second : nil;
        if (!ownerHostView || ownerHostView.window != window) {
            continue;
        }
        if (![[CEFBridge sharedInstance] performBrowserCommand:command browserId:browserId]) {
            continue;
        }
        return YES;
    }
    return NO;
}

- (BOOL)initializeBridgeWithCachePath:(NSString*)cachePath
                        rootCachePath:(NSString*)rootCachePath
                            userAgent:(NSString*)userAgent
                        chromeRuntime:(BOOL)chromeRuntime
                       extensionPaths:(NSArray*)extensionPaths
                           cefProfile:(NSString*)cefProfile
                      profileSwitches:(NSDictionary*)profileSwitches
                        extraSwitches:(NSDictionary*)extraSwitches
                       removeSwitches:(NSArray*)removeSwitches
                          closePolicy:(NSString*)closePolicy
               gracefulCloseTimeoutMs:(NSInteger)gracefulCloseTimeoutMs
                      messagePumpMode:(NSString*)messagePumpMode
                       maxPumpDelayMs:(NSInteger)maxPumpDelayMs
          enableMessagePumpFallbackTimer:(BOOL)enableMessagePumpFallbackTimer
          enableWindowlessRendering:(BOOL)enableWindowlessRendering
                  deterministicCreate:(BOOL)deterministicCreate {
    CEFBridge* bridge = [CEFBridge sharedInstance];
    SEL selector = NSSelectorFromString(
      @"initializeWithCachePath:rootCachePath:userAgent:chromeRuntime:"
      @"extensionPaths:cefProfile:profileSwitches:extraSwitches:removeSwitches:"
      @"closePolicy:gracefulCloseTimeoutMs:messagePumpMode:maxPumpDelayMs:"
      @"enableMessagePumpFallbackTimer:enableWindowlessRendering:"
      @"deterministicCreate:");
    if ([bridge respondsToSelector:selector]) {
        NSMethodSignature* signature = [bridge methodSignatureForSelector:selector];
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setSelector:selector];
        [invocation setTarget:bridge];
        [invocation setArgument:&cachePath atIndex:2];
        [invocation setArgument:&rootCachePath atIndex:3];
        [invocation setArgument:&userAgent atIndex:4];
        [invocation setArgument:&chromeRuntime atIndex:5];
        [invocation setArgument:&extensionPaths atIndex:6];
        [invocation setArgument:&cefProfile atIndex:7];
        [invocation setArgument:&profileSwitches atIndex:8];
        [invocation setArgument:&extraSwitches atIndex:9];
        [invocation setArgument:&removeSwitches atIndex:10];
        [invocation setArgument:&closePolicy atIndex:11];
        [invocation setArgument:&gracefulCloseTimeoutMs atIndex:12];
        [invocation setArgument:&messagePumpMode atIndex:13];
        [invocation setArgument:&maxPumpDelayMs atIndex:14];
        [invocation setArgument:&enableMessagePumpFallbackTimer atIndex:15];
        [invocation setArgument:&enableWindowlessRendering atIndex:16];
        [invocation setArgument:&deterministicCreate atIndex:17];
        [invocation invoke];
        BOOL success = NO;
        [invocation getReturnValue:&success];
        return success;
    }

    return [bridge initializeWithCachePath:cachePath
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
               enableMessagePumpFallbackTimer:enableMessagePumpFallbackTimer];
}

- (NSDictionary*)runtimeConfigFromMethodArguments:(NSDictionary*)args {
    id rawConfig = args[@"config"];
    NSDictionary* config = [rawConfig isKindOfClass:[NSDictionary class]]
        ? (NSDictionary*)rawConfig
        : (args ?: @{});
    id (^valueForKey)(NSString*) = ^id(NSString* key) {
        id value = config[key];
        if (value && value != [NSNull null]) {
            return value;
        }
        value = args[key];
        if (value && value != [NSNull null]) {
            return value;
        }
        return nil;
    };

    const char* requireHelperEnv = getenv("CEF_REQUIRE_HELPER");
    const char* useMockKeychainEnv = getenv("CEF_USE_MOCK_KEYCHAIN");
    NSString* cachePath = StringOrNil(valueForKey(@"cachePath")) ?: DefaultCefCachePath();
    NSString* rootCachePath = StringOrNil(valueForKey(@"rootCachePath"));
    if (rootCachePath.length == 0 && cachePath.length > 0) {
        rootCachePath = [cachePath stringByDeletingLastPathComponent];
    }
    return @{
        @"cachePath": cachePath,
        @"rootCachePath": rootCachePath ?: @"",
        @"userAgent": StringOrNil(valueForKey(@"userAgent")) ?: [NSNull null],
        @"chromeRuntime": @(BoolOrDefault(valueForKey(@"chromeRuntime"), NO)),
        @"extensionPaths": StringArrayOrEmpty(valueForKey(@"extensionPaths")),
        @"cefProfile": StringOrNil(valueForKey(@"cefProfile")) ?: @"prod-safe",
        @"profileSwitches": DictOrEmpty(valueForKey(@"profileSwitches")),
        @"extraSwitches": DictOrEmpty(valueForKey(@"extraSwitches")),
        @"removeSwitches": StringArrayOrEmpty(valueForKey(@"removeSwitches")),
        @"closePolicy": StringOrNil(valueForKey(@"closePolicy")) ?: @"graceful_then_force",
        @"gracefulCloseTimeoutMs": @(MAX(1, IntegerOrDefault(valueForKey(@"gracefulCloseTimeoutMs"), 1200))),
        @"messagePumpMode": StringOrNil(valueForKey(@"messagePumpMode")) ?: @"cef_sample_compatible",
        @"maxPumpDelayMs": @(MAX(1, IntegerOrDefault(valueForKey(@"maxPumpDelayMs"), 33))),
        @"enableMessagePumpFallbackTimer": @(BoolOrDefault(valueForKey(@"enableMessagePumpFallbackTimer"), YES)),
        @"enableWindowlessRendering": @(BoolOrDefault(valueForKey(@"enableWindowlessRendering"), NO)),
        @"deterministicCreate": @(BoolOrDefault(valueForKey(@"deterministicCreate"), YES)),
        @"deterministicCreateTimeoutMs": @(MAX(1, IntegerOrDefault(valueForKey(@"deterministicCreateTimeoutMs"), 5000))),
        @"requireHelper": @(BoolOrDefault(valueForKey(@"requireHelper"), !requireHelperEnv || strcmp(requireHelperEnv, "0") != 0)),
        @"useMockKeychain": @(BoolOrDefault(
            useMockKeychainEnv
                ? [NSString stringWithUTF8String:useMockKeychainEnv]
                : nil,
            BoolOrDefault(valueForKey(@"useMockKeychain"), NO))),
        @"remoteDebuggingPort": @(MAX(0, IntegerOrDefault(valueForKey(@"remoteDebuggingPort"), 0))),
        @"logFilePath": StringOrNil(valueForKey(@"logFilePath")) ?: @"",
        @"crashDumpsPath": StringOrNil(valueForKey(@"crashDumpsPath")) ?: @"",
        @"uncaughtExceptionStackSize": @(MAX(0, IntegerOrDefault(valueForKey(@"uncaughtExceptionStackSize"), 10))),
        @"launchMode": StringOrNil(valueForKey(@"launchMode")) ?: @"legacy",
    };
}

- (NSDictionary*)prepareFilesystemForConfig:(NSDictionary*)config {
    NSString* cachePath = StringOrNil(config[@"cachePath"]);
    NSString* rootCachePath = StringOrNil(config[@"rootCachePath"]);
    if (cachePath.length == 0) {
        return @{
            @"success": @NO,
            @"failureCode": @"cache_path_empty",
            @"failureStage": @"prepare_filesystem",
            @"message": @"CEF cachePath is empty",
        };
    }
    if (rootCachePath.length == 0) {
        return @{
            @"success": @NO,
            @"failureCode": @"root_cache_path_empty",
            @"failureStage": @"prepare_filesystem",
            @"message": @"CEF rootCachePath is empty",
        };
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSMutableOrderedSet<NSString*>* paths = [NSMutableOrderedSet orderedSet];
    [paths addObject:rootCachePath];
    [paths addObject:cachePath];
    NSString* logFilePath = StringOrNil(config[@"logFilePath"]);
    if (logFilePath.length > 0) {
        [paths addObject:[logFilePath stringByDeletingLastPathComponent]];
    }
    NSString* crashDumpsPath = StringOrNil(config[@"crashDumpsPath"]);
    if (crashDumpsPath.length > 0) {
        [paths addObject:crashDumpsPath];
    }

    for (NSString* path in paths) {
        NSError* error = nil;
        if (![fileManager createDirectoryAtPath:path
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&error]) {
            return @{
                @"success": @NO,
                @"failureCode": @"cache_path_prepare_failed",
                @"failureStage": @"prepare_filesystem",
                @"message": error.localizedDescription ?: @"Failed to prepare CEF cache directories",
                @"details": @{
                    @"path": path,
                },
            };
        }
    }

    return @{@"success": @YES};
}

- (NSDictionary*)runBridgePreflightWithConfig:(NSDictionary*)config {
    return [[CEFBridge sharedInstance] runPreflightWithConfig:config];
}

- (NSDictionary*)initializeBridgeWithConfig:(NSDictionary*)config {
    return [[CEFBridge sharedInstance] initializeWithConfig:config];
}

- (void)emitLifecycleDiagnostic:(NSString*)type
                      browserId:(NSNumber*)browserId
                        details:(NSDictionary<NSString*, id>*)details {
    if (!_methodChannel || type.length == 0) {
        return;
    }

    NSMutableDictionary<NSString*, id>* payload = [NSMutableDictionary dictionary];
    payload[@"type"] = type;
    if (browserId != nil) {
        payload[@"browserId"] = browserId;
    }
    if (details.count > 0) {
        [payload addEntriesFromDictionary:details];
    }
    [_methodChannel invokeMethod:@"cefLifecycleDiagnostic" arguments:[payload copy]];
}

- (NSDictionary*)hideStaleBrowsersKeepingBrowserIds:(NSSet<NSNumber*>*)keepVisibleBrowserIds
                                             reason:(NSString*)reason {
    if (![NSThread isMainThread]) {
        __block NSDictionary* syncResult = @{};
        dispatch_sync(dispatch_get_main_queue(), ^{
            syncResult = [self hideStaleBrowsersKeepingBrowserIds:keepVisibleBrowserIds
                                                           reason:reason];
        });
        return syncResult;
    }

    NSMutableArray<NSNumber*>* hiddenBrowserIds = [NSMutableArray array];
    NSMutableArray<NSNumber*>* keptBrowserIds = [NSMutableArray array];
    NSMutableArray<NSNumber*>* skippedBrowserIds = [NSMutableArray array];
    NSArray<NSNumber*>* browserIds = [_ownedBrowserIds allObjects];
    if (browserIds.count == 0) {
        return @{
            @"reason": reason ?: @"",
            @"hiddenBrowserIds": @[],
            @"keptBrowserIds": @[],
            @"skippedBrowserIds": @[],
            @"instanceId": @(_instanceId),
            @"ownedBrowserCount": @0,
        };
    }

    for (NSNumber* browserNum in browserIds) {
        if (!browserNum) continue;
        const int browserId = browserNum.intValue;
        if ([keepVisibleBrowserIds containsObject:browserNum]) {
            [keptBrowserIds addObject:browserNum];
            continue;
        }
        if ([_programmaticBrowserCloseIds containsObject:browserNum]) {
            [skippedBrowserIds addObject:browserNum];
            continue;
        }

        _requestedVisibilityByBrowserId[browserNum] = @NO;
        [self markBrowserNumber:browserNum focused:NO];

        auto viewIt = _browserViews.find(browserId);
        if (viewIt != _browserViews.end() && viewIt->second) {
            [self applyEffectiveVisibilityForBrowserId:browserId
                                            browserNum:browserNum
                                         containerView:viewIt->second
                                            canPresent:NO
                                                reason:reason ?: @"hideStaleBrowsers"];
        } else {
            [self recordSetVisibleMetric];
            [[CEFBridge sharedInstance] setVisible:browserId visible:NO];
        }
        [hiddenBrowserIds addObject:browserNum];
    }

    NSDictionary<NSString*, id>* details = @{
        @"reason": reason ?: @"",
        @"hiddenBrowserIds": [hiddenBrowserIds copy],
        @"keptBrowserIds": [keptBrowserIds copy],
        @"skippedBrowserIds": [skippedBrowserIds copy],
        @"instanceId": @(_instanceId),
        @"ownedBrowserCount": @(_ownedBrowserIds.count),
    };
    [self emitLifecycleDiagnostic:@"cef_hide_stale_browsers"
                        browserId:nil
                          details:details];
    return details;
}

+ (NSDictionary*)hideStaleBrowsersAcrossInstancesKeepingBrowserIds:(NSSet<NSNumber*>*)keepVisibleBrowserIds
                                                            reason:(NSString*)reason {
    if (![NSThread isMainThread]) {
        __block NSDictionary* syncResult = @{};
        dispatch_sync(dispatch_get_main_queue(), ^{
            syncResult = [FlutterCefBrowserPlugin
                hideStaleBrowsersAcrossInstancesKeepingBrowserIds:keepVisibleBrowserIds
                                                           reason:reason];
        });
        return syncResult;
    }

    NSMutableArray<NSNumber*>* hiddenBrowserIds = [NSMutableArray array];
    NSMutableArray<NSNumber*>* keptBrowserIds = [NSMutableArray array];
    NSMutableArray<NSNumber*>* skippedBrowserIds = [NSMutableArray array];
    NSInteger instanceCount = 0;

    for (FlutterCefBrowserPlugin* instance in FlutterCefBrowserPluginInstances()) {
        if (!instance) continue;
        instanceCount += 1;
        NSDictionary* result = [instance hideStaleBrowsersKeepingBrowserIds:keepVisibleBrowserIds
                                                                     reason:reason];
        NSArray* hidden = [result[@"hiddenBrowserIds"] isKindOfClass:[NSArray class]]
            ? result[@"hiddenBrowserIds"]
            : @[];
        NSArray* kept = [result[@"keptBrowserIds"] isKindOfClass:[NSArray class]]
            ? result[@"keptBrowserIds"]
            : @[];
        NSArray* skipped = [result[@"skippedBrowserIds"] isKindOfClass:[NSArray class]]
            ? result[@"skippedBrowserIds"]
            : @[];
        [hiddenBrowserIds addObjectsFromArray:hidden];
        [keptBrowserIds addObjectsFromArray:kept];
        [skippedBrowserIds addObjectsFromArray:skipped];
    }

    return @{
        @"hiddenBrowserIds": [hiddenBrowserIds copy],
        @"keptBrowserIds": [keptBrowserIds copy],
        @"skippedBrowserIds": [skippedBrowserIds copy],
        @"instanceCount": @(instanceCount),
    };
}

- (void)emitPresentationMetricsIfNeededWithTrigger:(NSString*)trigger
                                            reason:(NSString*)reason
                                             force:(BOOL)force {
    if (!force && _presentationMetricsDirtyEvents < kPresentationMetricsEmitInterval) {
        return;
    }
    _presentationMetricsDirtyEvents = 0;

    NSDictionary<NSString*, NSNumber*>* reasonCounts = [_nativeReapplyReasonCounts copy] ?: @{};
    NSDictionary<NSString*, id>* details = @{
        @"trigger": trigger ?: @"",
        @"reason": reason ?: @"",
        @"nativeReapplyScheduled": @(_nativeReapplyScheduledCount),
        @"nativeReapplyExecuted": @(_nativeReapplyExecutedCount),
        @"nativeReapplyReasonCounts": reasonCounts,
        @"setViewFrameCount": @(_setViewFrameCount),
        @"setVisibleCount": @(_setVisibleCount),
        @"promoteContainerCount": @(_promoteContainerCount),
    };
    [self emitLifecycleDiagnostic:@"cef_presentation_metrics"
                        browserId:nil
                          details:details];

    if (ShouldLogReliabilityDebug()) {
        NSLog(@"FlutterCefBrowserPlugin: presentation metrics trigger=%@ reason=%@ "
          @"reapplyScheduled=%lu reapplyExecuted=%lu setViewFrame=%lu "
          @"setVisible=%lu promoteContainer=%lu reasonCounts=%@",
              trigger ?: @"",
              reason ?: @"",
              (unsigned long)_nativeReapplyScheduledCount,
              (unsigned long)_nativeReapplyExecutedCount,
              (unsigned long)_setViewFrameCount,
              (unsigned long)_setVisibleCount,
              (unsigned long)_promoteContainerCount,
              reasonCounts);
    }
}

- (void)recordNativeReapplyScheduledWithReason:(NSString*)reason {
    _nativeReapplyScheduledCount += 1;
    NSString* key = reason.length > 0 ? reason : @"unknown";
    NSNumber* existingCount = _nativeReapplyReasonCounts[key];
    _nativeReapplyReasonCounts[key] = @(existingCount.unsignedIntegerValue + 1);
    _presentationMetricsDirtyEvents += 1;
    [self emitPresentationMetricsIfNeededWithTrigger:@"nativeReapplyScheduled"
                                              reason:key
                                               force:NO];
}

- (void)recordNativeReapplyExecutedWithReason:(NSString*)reason {
    _nativeReapplyExecutedCount += 1;
    _presentationMetricsDirtyEvents += 1;
    [self emitPresentationMetricsIfNeededWithTrigger:@"nativeReapplyExecuted"
                                              reason:reason
                                               force:NO];
}

- (void)recordSetViewFrameMetric {
    _setViewFrameCount += 1;
    _presentationMetricsDirtyEvents += 1;
    [self emitPresentationMetricsIfNeededWithTrigger:@"setViewFrame"
                                              reason:nil
                                               force:NO];
}

- (void)recordSetVisibleMetric {
    _setVisibleCount += 1;
    _presentationMetricsDirtyEvents += 1;
    [self emitPresentationMetricsIfNeededWithTrigger:@"setVisible"
                                              reason:nil
                                               force:NO];
}

- (void)recordPromoteContainerMetric {
    _promoteContainerCount += 1;
    _presentationMetricsDirtyEvents += 1;
    [self emitPresentationMetricsIfNeededWithTrigger:@"promoteContainer"
                                              reason:nil
                                               force:NO];
}

- (void)removeWindowTrackingObservers {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    NSNotificationCenter* workspaceNotificationCenter = [[NSWorkspace sharedWorkspace] notificationCenter];

    if (_windowDidResizeObserver) {
        [nc removeObserver:_windowDidResizeObserver];
        _windowDidResizeObserver = nil;
    }
    if (_windowDidEndLiveResizeObserver) {
        [nc removeObserver:_windowDidEndLiveResizeObserver];
        _windowDidEndLiveResizeObserver = nil;
    }
    if (_windowDidMoveObserver) {
        [nc removeObserver:_windowDidMoveObserver];
        _windowDidMoveObserver = nil;
    }
    if (_windowDidChangeBackingObserver) {
        [nc removeObserver:_windowDidChangeBackingObserver];
        _windowDidChangeBackingObserver = nil;
    }
    if (_windowDidChangeOcclusionStateObserver) {
        [nc removeObserver:_windowDidChangeOcclusionStateObserver];
        _windowDidChangeOcclusionStateObserver = nil;
    }
    if (_windowDidBecomeKeyObserver) {
        [nc removeObserver:_windowDidBecomeKeyObserver];
        _windowDidBecomeKeyObserver = nil;
    }
    if (_windowDidResignKeyObserver) {
        [nc removeObserver:_windowDidResignKeyObserver];
        _windowDidResignKeyObserver = nil;
    }
    if (_windowDidBecomeMainObserver) {
        [nc removeObserver:_windowDidBecomeMainObserver];
        _windowDidBecomeMainObserver = nil;
    }
    if (_windowDidResignMainObserver) {
        [nc removeObserver:_windowDidResignMainObserver];
        _windowDidResignMainObserver = nil;
    }
    if (_windowDidMiniaturizeObserver) {
        [nc removeObserver:_windowDidMiniaturizeObserver];
        _windowDidMiniaturizeObserver = nil;
    }
    if (_windowDidDeminiaturizeObserver) {
        [nc removeObserver:_windowDidDeminiaturizeObserver];
        _windowDidDeminiaturizeObserver = nil;
    }
    if (_workspaceActiveSpaceDidChangeObserver) {
        [workspaceNotificationCenter removeObserver:_workspaceActiveSpaceDidChangeObserver];
        _workspaceActiveSpaceDidChangeObserver = nil;
    }
    if (_appDidBecomeActiveObserver) {
        [nc removeObserver:_appDidBecomeActiveObserver];
        _appDidBecomeActiveObserver = nil;
    }
    if (_appDidResignActiveObserver) {
        [nc removeObserver:_appDidResignActiveObserver];
        _appDidResignActiveObserver = nil;
    }
    if (_windowWillCloseObserver) {
        [nc removeObserver:_windowWillCloseObserver];
        _windowWillCloseObserver = nil;
    }
    if (_flutterViewFrameObserver) {
        [nc removeObserver:_flutterViewFrameObserver];
        _flutterViewFrameObserver = nil;
    }
    if (_flutterViewBoundsObserver) {
        [nc removeObserver:_flutterViewBoundsObserver];
        _flutterViewBoundsObserver = nil;
    }
    _trackingWindowEvents = NO;
}

- (NSWindow*)trackedPresentationWindow {
    return _trackedWindow ?: (_flutterView ? _flutterView.window : nil);
}

- (BOOL)windowCanPresentBrowserViewsForWindow:(NSWindow*)window
                                    appActive:(BOOL*)appActiveOut
                                windowVisible:(BOOL*)windowVisibleOut
                           windowMiniaturized:(BOOL*)windowMiniaturizedOut
                       windowOcclusionVisible:(BOOL*)windowOcclusionVisibleOut
                                windowKeyOrMain:(BOOL*)windowKeyOrMainOut {
    BOOL appActive = NSApp ? NSApp.isActive : YES;
    BOOL windowVisible = NO;
    BOOL windowMiniaturized = NO;
    BOOL windowOcclusionVisible = NO;
    BOOL windowKeyOrMain = NO;
    if (window) {
        windowVisible = window.isVisible;
        windowMiniaturized = window.isMiniaturized;
        windowOcclusionVisible = (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
        windowKeyOrMain = window.isKeyWindow || window.isMainWindow;
    }
    if (appActiveOut) {
        *appActiveOut = appActive;
    }
    if (windowVisibleOut) {
        *windowVisibleOut = windowVisible;
    }
    if (windowMiniaturizedOut) {
        *windowMiniaturizedOut = windowMiniaturized;
    }
    if (windowOcclusionVisibleOut) {
        *windowOcclusionVisibleOut = windowOcclusionVisible;
    }
    if (windowKeyOrMainOut) {
        *windowKeyOrMainOut = windowKeyOrMain;
    }
    // Keep key/main, app-active, and occlusion as diagnostics only. Native
    // Chromium surfaces such as passkey/security-key dialogs can temporarily
    // become key windows or perturb occlusion while still being part of the
    // current browser interaction. Hiding or re-showing the browser view during
    // those AppKit notifications can recursively trigger Chromium modal
    // show/hide and crash AppKit's subview enumeration.
    return window && windowVisible && !windowMiniaturized;
}

- (BOOL)currentWindowCanPresentBrowserViews {
    return [self windowCanPresentBrowserViewsForWindow:[self trackedPresentationWindow]
                                            appActive:nil
                                         windowVisible:nil
                                    windowMiniaturized:nil
                                windowOcclusionVisible:nil
                                      windowKeyOrMain:nil];
}

- (NSNumber*)requestedVisibilityForBrowserNumber:(NSNumber*)browserNum {
    NSNumber* requestedVisible = _requestedVisibilityByBrowserId[browserNum];
    if (requestedVisible == nil) {
        requestedVisible = @YES;
        _requestedVisibilityByBrowserId[browserNum] = requestedVisible;
    }
    return requestedVisible;
}

- (NSNumber*)advanceLifecycleTokenForBrowserNumber:(NSNumber*)browserNum {
    if (!browserNum) return nil;
    _nextBrowserLifecycleToken += 1;
    if (_nextBrowserLifecycleToken == 0) {
        _nextBrowserLifecycleToken = 1;
    }
    NSNumber* token = @(_nextBrowserLifecycleToken);
    _browserLifecycleTokensByBrowserId[browserNum] = token;
    return token;
}

- (void)invalidateLifecycleTokenForBrowserNumber:(NSNumber*)browserNum {
    if (!browserNum) return;
    [_browserLifecycleTokensByBrowserId removeObjectForKey:browserNum];
    _nativeFrameReapplyGeneration += 1;
}

- (BOOL)isCreateLifecycleCurrentForBrowserId:(int)browserId
                                       token:(NSNumber*)token {
    if (!token) return NO;
    NSNumber* browserNum = @(browserId);
    if ([_programmaticBrowserCloseIds containsObject:browserNum]) {
        return NO;
    }
    NSNumber* currentToken = _browserLifecycleTokensByBrowserId[browserNum];
    return currentToken && [currentToken isEqualToNumber:token];
}

- (BOOL)isOwnedBrowserCurrentForBrowserId:(int)browserId
                                    token:(NSNumber*)token {
    NSNumber* browserNum = @(browserId);
    if (![_ownedBrowserIds containsObject:browserNum] ||
        [_programmaticBrowserCloseIds containsObject:browserNum]) {
        return NO;
    }
    if (!token) {
        return _browserLifecycleTokensByBrowserId[browserNum] != nil;
    }
    NSNumber* currentToken = _browserLifecycleTokensByBrowserId[browserNum];
    return currentToken && [currentToken isEqualToNumber:token];
}

- (BOOL)applyEffectiveVisibilityForBrowserId:(int)browserId
                                  browserNum:(NSNumber*)browserNum
                               containerView:(NSView*)containerView
                                  canPresent:(BOOL)canPresent
                                      reason:(NSString*)reason {
    NSNumber* requestedVisible = [self requestedVisibilityForBrowserNumber:browserNum];
    const BOOL effectiveVisible = requestedVisible.boolValue && canPresent;
    if (!effectiveVisible && [_focusedBrowserIds containsObject:browserNum]) {
        [self markBrowserNumber:browserNum focused:NO];
        [[CEFBridge sharedInstance] setFocus:browserId focused:NO];
    }
    // Only explicit browser visibility requests should hide the native
    // container. Transient presentation changes from Chromium-owned modal
    // windows, including WebAuthn/Touch ID sheets, must not flip NSView.hidden.
    const BOOL shouldHide = !requestedVisible.boolValue;
    if (containerView.hidden != shouldHide) {
        containerView.hidden = shouldHide;
    }
    NSNumber* appliedVisible = _appliedVisibilityByBrowserId[browserNum];
    if (appliedVisible && appliedVisible.boolValue == effectiveVisible) {
        return NO;
    }
    _appliedVisibilityByBrowserId[browserNum] = @(effectiveVisible);
    [self recordSetVisibleMetric];
    [[CEFBridge sharedInstance] setVisible:browserId visible:effectiveVisible];

    if (ShouldLogWindowTracking()) {
        NSLog(@"FlutterCefBrowserPlugin: applyEffectiveVisibility browserId=%d "
          @"reason=%@ requestedVisible=%@ effectiveVisible=%@ canPresent=%@",
              browserId,
              reason ?: @"(null)",
              requestedVisible.boolValue ? @"YES" : @"NO",
              effectiveVisible ? @"YES" : @"NO",
              canPresent ? @"YES" : @"NO");
    }

    return effectiveVisible;
}

- (void)reconcileWindowPresentationState:(NSString*)reason
                             forceRepair:(BOOL)forceRepair {
    if (_isWindowClosing) return;
    if (_presentationReconcileInProgress) {
        if (ShouldLogWindowTracking()) {
            NSLog(@"FlutterCefBrowserPlugin: skip nested "
            @"reconcileWindowPresentationState reason=%@",
                  reason ?: @"(null)");
        }
        return;
    }

    _presentationReconcileInProgress = YES;
    @try {
    NSWindow* window = [self trackedPresentationWindow];
    BOOL appIsActive = YES;
    BOOL windowVisible = YES;
    BOOL windowMiniaturized = NO;
    BOOL windowOcclusionVisible = YES;
    BOOL windowKeyOrMain = YES;
    const BOOL canPresent =
        [self windowCanPresentBrowserViewsForWindow:window
                                          appActive:&appIsActive
                                      windowVisible:&windowVisible
                                 windowMiniaturized:&windowMiniaturized
                             windowOcclusionVisible:&windowOcclusionVisible
                                    windowKeyOrMain:&windowKeyOrMain];
    const BOOL presentationChanged = (canPresent != _windowCanPresentBrowserViews);
    const BOOL stateChanged =
        forceRepair ||
        presentationChanged ||
        appIsActive != _appIsActive ||
        windowOcclusionVisible != _windowOcclusionVisible ||
        windowKeyOrMain != _windowKeyOrMain;

    _appIsActive = appIsActive;
    _windowOcclusionVisible = windowOcclusionVisible;
    _windowKeyOrMain = windowKeyOrMain;
    _windowCanPresentBrowserViews = canPresent;

    if (stateChanged) {
        NSDictionary<NSString*, id>* details = @{
            @"reason": reason ?: @"",
            @"appActive": @(appIsActive),
            @"windowVisible": @(windowVisible),
            @"windowMiniaturized": @(windowMiniaturized),
            @"windowOcclusionVisible": @(windowOcclusionVisible),
            @"windowKeyOrMain": @(windowKeyOrMain),
            @"canPresent": @(canPresent),
            @"ownedBrowserCount": @(_ownedBrowserIds.count),
            @"windowFrame": window ? NSStringFromRect(window.frame) : @"",
        };
        [self emitLifecycleDiagnostic:@"cef_window_presentation_state"
                            browserId:nil
                              details:details];

        if (ShouldLogWindowTracking()) {
            NSLog(@"FlutterCefBrowserPlugin: reconcileWindowPresentationState "
              @"reason=%@ appActive=%@ windowVisible=%@ windowMiniaturized=%@ "
              @"windowOcclusionVisible=%@ windowKeyOrMain=%@ canPresent=%@ "
              @"ownedBrowsers=%lu",
                  reason ?: @"(null)",
                  appIsActive ? @"YES" : @"NO",
                  windowVisible ? @"YES" : @"NO",
                  windowMiniaturized ? @"YES" : @"NO",
                  windowOcclusionVisible ? @"YES" : @"NO",
                  windowKeyOrMain ? @"YES" : @"NO",
                  canPresent ? @"YES" : @"NO",
                  (unsigned long)_ownedBrowserIds.count);
        }
    }

    if (!presentationChanged && !forceRepair) {
        return;
    }
    if (_browserViews.empty()) {
        return;
    }

    NSArray<NSNumber*>* browserIds = [_ownedBrowserIds allObjects];
    for (NSNumber* browserNum in browserIds) {
        if ([_programmaticBrowserCloseIds containsObject:browserNum]) {
            continue;
        }
        [self reapplyBrowserPresentationForBrowserId:browserNum.intValue
                                              reason:reason];
    }

    if (canPresent) {
        [self scheduleFlutterFrameSyncRequest:reason];
    }
    } @finally {
        _presentationReconcileInProgress = NO;
    }
}

- (void)scheduleWindowPresentationStateReconcile:(NSString*)reason
                                           delay:(NSTimeInterval)delay {
    if (_isWindowClosing) return;
    __weak FlutterCefBrowserPlugin* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FlutterCefBrowserPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf reconcileWindowPresentationState:reason forceRepair:NO];
    });
}

- (void)markWindowCloseTransactionBrowserClosed:(int)browserId {
    NSMutableDictionary<NSString*, id>* transaction = _windowCloseTransaction;
    if (transaction == nil) return;

    NSMutableDictionary<NSNumber*, NSMutableDictionary*>* participants =
        transaction[@"participants"];
    NSMutableDictionary* participant = participants[@(browserId)];
    if (![participant isKindOfClass:[NSMutableDictionary class]]) return;
    if (participant[@"closedAt"] == nil) {
        participant[@"closedAt"] = CurrentISO8601Timestamp();
    }

    [self emitLifecycleDiagnostic:@"cef_browser_close_completed"
                        browserId:@(browserId)
                          details:@{
                              @"transactionId": transaction[@"transactionId"] ?: @"",
                              @"phase": transaction[@"phase"] ?: @"waiting_ready",
                          }];
}

- (void)finishWindowCloseForWindow:(NSWindow*)window
                             phase:(NSString*)phase
                     transactionId:(NSString*)transactionId
                           details:(NSDictionary<NSString*, id>*)details {
    if (_windowCloseRetryTimer) {
        [_windowCloseRetryTimer invalidate];
        _windowCloseRetryTimer = nil;
    }
    _windowCloseTransaction = nil;
    _windowCloseRequested = NO;
    _isWindowClosing = YES;

    NSMutableDictionary<NSString*, id>* payload = [NSMutableDictionary dictionary];
    if (transactionId.length > 0) {
        payload[@"transactionId"] = transactionId;
    }
    if (phase.length > 0) {
        payload[@"phase"] = phase;
    }
    if (details.count > 0) {
        [payload addEntriesFromDictionary:details];
    }
    [self emitLifecycleDiagnostic:@"cef_window_close_host_closing"
                        browserId:nil
                          details:[payload copy]];

    [window close];
}

- (void)startWindowCloseTransactionIfNeeded {
    if (_windowCloseTransaction != nil) return;

    NSMutableDictionary<NSNumber*, NSMutableDictionary*>* participants =
        [NSMutableDictionary dictionary];
    NSString* transactionId = [NSString stringWithFormat:@"window_close_%lu",
                               (unsigned long)_nextWindowCloseTransactionId++];
    NSString* nowIso = CurrentISO8601Timestamp();
    NSDate* now = [NSDate date];
    // Keep window-close budgets tight: the previous floors (0.5s soft / 2s hard
    // plus gracefulCloseTimeoutMs padding) made Cmd-Q feel multi-second laggy
    // even when browsers were force-closed. Cap hard at ~1s.
    NSTimeInterval softDelaySeconds =
        MAX(0.15, MIN(0.6, (_gracefulCloseTimeoutMs) / 1000.0));
    NSTimeInterval hardDelaySeconds =
        MAX(0.4, MIN(1.0, (_gracefulCloseTimeoutMs + 300) / 1000.0));

    for (NSNumber* browserNum in _ownedBrowserIds) {
        participants[browserNum] = [@{
            @"browserId": browserNum,
            @"closeRequestedAt": nowIso,
            @"forceEscalated": @NO,
        } mutableCopy];
    }

    _windowCloseTransaction = [@{
        @"transactionId": transactionId,
        @"startedAt": nowIso,
        @"phase": @"requested",
        @"softDeadlineAt": [now dateByAddingTimeInterval:softDelaySeconds],
        @"hardDeadlineAt": [now dateByAddingTimeInterval:hardDelaySeconds],
        @"participants": participants,
        @"lastOutstandingCount": @(participants.count),
        @"forceEscalated": @NO,
    } mutableCopy];

    [self emitLifecycleDiagnostic:@"cef_window_close_transaction_started"
                        browserId:nil
                          details:@{
                              @"transactionId": transactionId,
                              @"phase": @"requested",
                              @"participantCount": @(participants.count),
                          }];
}

- (void)scheduleWindowCloseRetryIfNeededForWindow:(NSWindow*)window {
    if (_windowCloseRetryTimer || window == nil) return;

    __weak FlutterCefBrowserPlugin* weakSelf = self;
    __weak NSWindow* weakWindow = window;
    _windowCloseRetryTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                             repeats:YES
                                                               block:^(__unused NSTimer* timer) {
        FlutterCefBrowserPlugin* strongSelf = weakSelf;
        NSWindow* strongWindow = weakWindow;
        if (!strongSelf || !strongWindow) {
            [timer invalidate];
            return;
        }
        if (strongSelf->_isWindowClosing) {
            [timer invalidate];
            strongSelf->_windowCloseRetryTimer = nil;
            return;
        }
        [strongSelf pollWindowCloseTransactionForWindow:strongWindow];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_windowCloseRetryTimer
                              forMode:NSRunLoopCommonModes];
}

- (void)pollWindowCloseTransactionForWindow:(NSWindow*)window {
    NSMutableDictionary<NSString*, id>* transaction = _windowCloseTransaction;
    if (transaction == nil || window == nil) return;

    NSMutableDictionary<NSNumber*, NSMutableDictionary*>* participants =
        transaction[@"participants"];
    NSDate* now = [NSDate date];
    BOOL forceEscalated = [transaction[@"forceEscalated"] boolValue];
    NSUInteger outstandingCount = 0;
    BOOL allReady = YES;

    for (NSNumber* browserNum in participants.allKeys) {
        const int browserId = browserNum.intValue;
        NSMutableDictionary* participant = participants[browserNum];
        if (![_ownedBrowserIds containsObject:browserNum]) {
          if (participant[@"closedAt"] == nil) {
            participant[@"closedAt"] = CurrentISO8601Timestamp();
          }
          continue;
        }

        const BOOL ready =
            [[CEFBridge sharedInstance] isBrowserReadyToBeClosed:browserId];
        if (ready) {
          if (participant[@"readyObservedAt"] == nil) {
            participant[@"readyObservedAt"] = CurrentISO8601Timestamp();
          }
          continue;
        }

        allReady = NO;
        outstandingCount += 1;
        [[CEFBridge sharedInstance] closeBrowser:browserId
                                           force:forceEscalated];
      }

    NSString* previousPhase = transaction[@"phase"] ?: @"requested";
    NSString* nextPhase = forceEscalated ? @"escalating_force" : @"waiting_ready";

    if (!forceEscalated &&
        [now compare:transaction[@"softDeadlineAt"]] != NSOrderedAscending) {
      transaction[@"forceEscalated"] = @YES;
      nextPhase = @"escalating_force";
      for (NSNumber* browserNum in participants.allKeys) {
        if (![_ownedBrowserIds containsObject:browserNum]) continue;
        NSMutableDictionary* participant = participants[browserNum];
        if ([participant[@"forceEscalated"] boolValue]) continue;
        participant[@"forceEscalated"] = @YES;
        participant[@"forceEscalatedAt"] = CurrentISO8601Timestamp();
        [[CEFBridge sharedInstance] closeBrowser:browserNum.intValue force:YES];
        [self emitLifecycleDiagnostic:@"cef_browser_close_escalated"
                            browserId:browserNum
                              details:@{
                                  @"transactionId": transaction[@"transactionId"] ?: @"",
                              }];
      }
    }

    transaction[@"phase"] = nextPhase;
    NSNumber* lastOutstandingCount = transaction[@"lastOutstandingCount"];
    if (lastOutstandingCount == nil ||
        lastOutstandingCount.unsignedIntegerValue != outstandingCount ||
        ![previousPhase isEqualToString:nextPhase]) {
      transaction[@"lastOutstandingCount"] = @(outstandingCount);
      [self emitLifecycleDiagnostic:@"cef_window_close_transaction_progress"
                          browserId:nil
                            details:@{
                                @"transactionId": transaction[@"transactionId"] ?: @"",
                                @"phase": nextPhase,
                                @"outstandingBrowserCount": @(outstandingCount),
                            }];
    }

    if (allReady) {
      if (_ownedBrowserIds.count == 0) {
        transaction[@"phase"] = @"completed";
        NSDictionary* completionDetails = @{
          @"transactionId": transaction[@"transactionId"] ?: @"",
          @"phase": @"completed",
        };
        [self emitLifecycleDiagnostic:@"cef_window_close_transaction_completed"
                            browserId:nil
                              details:completionDetails];
        [self finishWindowCloseForWindow:window
                                   phase:@"completed"
                           transactionId:transaction[@"transactionId"] ?: @""
                                 details:completionDetails];
        return;
      }

      nextPhase = @"awaiting_browser_closed";
    }

    if ([now compare:transaction[@"hardDeadlineAt"]] != NSOrderedAscending) {
      transaction[@"phase"] = @"timed_out";
      NSDictionary* timeoutDetails = @{
        @"transactionId": transaction[@"transactionId"] ?: @"",
        @"phase": @"timed_out",
        @"outstandingBrowserCount": @(outstandingCount),
      };
      [self emitLifecycleDiagnostic:@"cef_window_close_transaction_timed_out"
                          browserId:nil
                            details:timeoutDetails];
      [self finishWindowCloseForWindow:window
                                 phase:@"timed_out"
                         transactionId:transaction[@"transactionId"] ?: @""
                               details:timeoutDetails];
    }
}

- (BOOL)createBrowserWithBridgeForBrowserId:(int)browserId
                                        url:(NSString*)url
                                 incognito:(BOOL)incognito
                                 parentView:(NSView*)parentView
                                      frame:(NSRect)frame
                            createRequestId:(NSString*)createRequestId
                              renderBackend:(NSString*)renderBackend
                          deviceScaleFactor:(CGFloat)deviceScaleFactor {
    CEFBridge* bridge = [CEFBridge sharedInstance];
    SEL selector = NSSelectorFromString(
      @"createBrowserWithId:url:incognito:parentView:frame:createRequestId:"
      @"renderBackend:deviceScaleFactor:");
    if ([bridge respondsToSelector:selector]) {
        NSMethodSignature* signature = [bridge methodSignatureForSelector:selector];
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setSelector:selector];
        [invocation setTarget:bridge];
        [invocation setArgument:&browserId atIndex:2];
        [invocation setArgument:&url atIndex:3];
        [invocation setArgument:&incognito atIndex:4];
        [invocation setArgument:&parentView atIndex:5];
        [invocation setArgument:&frame atIndex:6];
        [invocation setArgument:&createRequestId atIndex:7];
        [invocation setArgument:&renderBackend atIndex:8];
        [invocation setArgument:&deviceScaleFactor atIndex:9];
        [invocation invoke];
        BOOL success = NO;
        [invocation getReturnValue:&success];
        return success;
    }

    SEL legacySelector = NSSelectorFromString(@"createBrowserWithId:url:incognito:parentView:"
                           @"frame:createRequestId:renderBackend:");
    if ([bridge respondsToSelector:legacySelector]) {
        NSMethodSignature* signature = [bridge methodSignatureForSelector:legacySelector];
        NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setSelector:legacySelector];
        [invocation setTarget:bridge];
        [invocation setArgument:&browserId atIndex:2];
        [invocation setArgument:&url atIndex:3];
        [invocation setArgument:&incognito atIndex:4];
        [invocation setArgument:&parentView atIndex:5];
        [invocation setArgument:&frame atIndex:6];
        [invocation setArgument:&createRequestId atIndex:7];
        [invocation setArgument:&renderBackend atIndex:8];
        [invocation invoke];
        BOOL success = NO;
        [invocation getReturnValue:&success];
        return success;
    }

    return [bridge createBrowserWithId:browserId
                                   url:url
                            incognito:incognito
                            parentView:parentView
                                 frame:frame];
}

- (void)emitBrowserCreateFailedForBrowserId:(int)browserId
                            createRequestId:(nullable NSString*)createRequestId
                                     reason:(NSString*)reason {
    if (_browserEventSink) {
        NSMutableDictionary* payload = [@{
            @"type": @"browserCreateFailed",
            @"browserId": @(browserId),
            @"reason": reason ?: @"unknown",
        } mutableCopy];
        if (createRequestId.length > 0) {
            payload[@"createRequestId"] = createRequestId;
        }
        _browserEventSink(payload);
    }
}

- (NSView*)resolvedFlutterHostView {
    NSView* flutterView = _flutterView;
    if (flutterView.window) {
        return flutterView;
    }

    NSMutableOrderedSet<NSView*>* candidateRootViews = [NSMutableOrderedSet orderedSet];
    if (_flutterViewController.view) {
        [candidateRootViews addObject:_flutterViewController.view];
    }
    if (_trackedWindow.contentView) {
        [candidateRootViews addObject:_trackedWindow.contentView];
    }

    NSMutableOrderedSet<NSWindow*>* candidateWindows = [NSMutableOrderedSet orderedSet];
    if (_trackedWindow) {
        [candidateWindows addObject:_trackedWindow];
    }

    NSApplication* app = [NSApplication sharedApplication];
    if (app.mainWindow) {
        [candidateWindows addObject:app.mainWindow];
    }
    if (app.keyWindow) {
        [candidateWindows addObject:app.keyWindow];
    }
    for (NSWindow* window in app.orderedWindows) {
        if (window) {
            [candidateWindows addObject:window];
        }
    }

    for (NSWindow* window in candidateWindows) {
        if (window.contentView) {
            [candidateRootViews addObject:window.contentView];
        }
    }

    for (NSView* rootView in candidateRootViews) {
        NSView* hostView = FindFlutterHostViewInTree(rootView);
        if (hostView && hostView.window) {
            _flutterView = hostView;
            return hostView;
        }
    }

    return nil;
}

- (void)promoteBrowserContainerToFrontIfNeeded:(NSView*)containerView
                                      hostView:(NSView*)hostView {
    if (!containerView || !hostView) return;
    if (containerView.superview == hostView && hostView.subviews.lastObject == containerView) {
        return;
    }
    if (containerView.superview != hostView) {
        [containerView removeFromSuperview];
    }
    [hostView addSubview:containerView positioned:NSWindowAbove relativeTo:nil];
    [self recordPromoteContainerMetric];
}

- (void)reapplyBrowserPresentationForBrowserId:(int)browserId
                                        reason:(NSString*)reason {
    // Fast Flutter layout churn can leave the browser child view with stale
    // ordering, frame, or visibility. Replay the last requested presentation
    // state whenever the native view is known to exist.
    if (_isWindowClosing) return;

    NSNumber* browserNum = @(browserId);
    if (![_ownedBrowserIds containsObject:browserNum] ||
        [_programmaticBrowserCloseIds containsObject:browserNum] ||
        ![self isOwnedBrowserCurrentForBrowserId:browserId token:nil]) {
        return;
    }
    if ([self isOsrBrowserId:browserId]) {
        return;
    }

    auto viewIt = _browserViews.find(browserId);
    if (viewIt == _browserViews.end() || !viewIt->second) return;

	NSView* containerView = viewIt->second;
    auto hostIt = _browserHostViews.find(browserId);
    NSView* ownerHostView = (hostIt != _browserHostViews.end()) ? hostIt->second : nil;
    if (ownerHostView && containerView.superview && containerView.superview != ownerHostView) {
        if (ShouldLogWindowTracking()) {
            NSLog(
          @"FlutterCefBrowserPlugin: removing browser container from non-owner "
          @"host browserId=%d reason=%@ oldSuperview=%@ ownerHost=%@",
                  browserId,
                  reason ?: @"(null)",
                  containerView.superview,
                  ownerHostView);
        }
        [containerView removeFromSuperviewWithoutNeedingDisplay];
    }
	NSView* hostView = containerView.superview ?: ownerHostView;
	const BOOL canPresent = [self currentWindowCanPresentBrowserViews] &&
        ownerHostView &&
        ownerHostView.window == [self trackedPresentationWindow];
	NSNumber* requestedVisible = [self requestedVisibilityForBrowserNumber:browserNum];
	const BOOL effectiveVisible = requestedVisible.boolValue && canPresent;

	if (effectiveVisible && hostView) {
        [self promoteBrowserContainerToFrontIfNeeded:containerView hostView:hostView];
    }

    auto frameIt = _lastRequestedFrames.find(browserId);
    if (frameIt != _lastRequestedFrames.end()) {
        const NSRect frame = frameIt->second;
        RunWithoutImplicitLayerActions(^{
            containerView.autoresizingMask = NSViewNotSizable;
            containerView.translatesAutoresizingMaskIntoConstraints = YES;
            [containerView setFrame:frame];
            if (containerView.wantsLayer) {
                containerView.layer.masksToBounds = YES;
            }
        });
        [self recordSetViewFrameMetric];
        [[CEFBridge sharedInstance] setViewFrame:browserId frame:frame];
    }

    [self applyEffectiveVisibilityForBrowserId:browserId
                                    browserNum:browserNum
                                 containerView:containerView
                                    canPresent:canPresent
                                        reason:reason];

    if (ShouldLogWindowTracking()) {
        NSLog(@"FlutterCefBrowserPlugin: reapplyBrowserPresentation browserId=%d "
          @"reason=%@ requestedVisible=%@ effectiveVisible=%@ canPresent=%@ "
          @"frame=%@ hostView=%@",
              browserId,
              reason ?: @"(null)",
              requestedVisible.boolValue ? @"YES" : @"NO",
              effectiveVisible ? @"YES" : @"NO",
              canPresent ? @"YES" : @"NO",
              frameIt != _lastRequestedFrames.end() ? NSStringFromRect(frameIt->second) : @"(none)",
              hostView);
    }
}

- (BOOL)isPendingCreateCancelledForBrowserId:(int)browserId {
    NSNumber* browserNum = @(browserId);
    return [_programmaticBrowserCloseIds containsObject:browserNum] &&
        ![_ownedBrowserIds containsObject:browserNum];
}

- (void)attemptCreateBrowserForBrowserId:(int)browserId
                                     url:(NSString*)url
                              incognito:(BOOL)incognito
                                      x:(double)x
                                      y:(double)y
                                  width:(double)width
                                 height:(double)height
	                             viewHeight:(double)viewHeight
	                        createRequestId:(nullable NSString*)createRequestId
	                          renderBackend:(NSString*)renderBackend
	                          lifecycleToken:(NSNumber*)lifecycleToken
	                          deviceScaleFactor:(CGFloat)deviceScaleFactor
	                                attempt:(NSInteger)attempt
	                                 result:(FlutterResult)result {
    NSNumber* browserNum = @(browserId);
    NSString* normalizedRenderBackend = NormalizeRenderBackendName(renderBackend);
    const BOOL useOsrTexture =
        ![normalizedRenderBackend isEqualToString:@"nativeView"];
    if (![self isCreateLifecycleCurrentForBrowserId:browserId token:lifecycleToken]) {
        if (ShouldLogReliabilityDebug()) {
            NSLog(@"FlutterCefBrowserPlugin: stale create ignored for browserId=%d "
            @"requestId=%@ token=%@",
                  browserId,
                  createRequestId ?: @"<none>",
                  lifecycleToken ?: @"<none>");
        }
        [_createStartedAtByBrowserId removeObjectForKey:browserNum];
        [_createRequestIdsByBrowserId removeObjectForKey:browserNum];
        if (![_ownedBrowserIds containsObject:browserNum]) {
            [_programmaticBrowserCloseIds removeObject:browserNum];
        }
        [self emitBrowserCreateFailedForBrowserId:browserId
                                  createRequestId:createRequestId
                                           reason:@"create lifecycle token is stale"];
        result(@NO);
        return;
    }
    if ([self isPendingCreateCancelledForBrowserId:browserId]) {
        if (ShouldLogReliabilityDebug()) {
            NSLog(@"FlutterCefBrowserPlugin: cancelled deferred create for "
            @"browserId=%d requestId=%@",
                  browserId,
                  createRequestId ?: @"<none>");
        }
        [_createStartedAtByBrowserId removeObjectForKey:browserNum];
        [_createRequestIdsByBrowserId removeObjectForKey:browserNum];
        [_programmaticBrowserCloseIds removeObject:browserNum];
        [self emitBrowserCreateFailedForBrowserId:browserId
                                  createRequestId:createRequestId
                                           reason:@"create cancelled before host "
                                              @"view was ready"];
        result(@NO);
        return;
    }

    NSView* flutterView = [self resolvedFlutterHostView];
    if (!flutterView || !flutterView.window) {
        if (attempt < kCreateBrowserWindowRetryLimit) {
            if (ShouldLogReliabilityDebug() && attempt == 0) {
                NSLog(@"FlutterCefBrowserPlugin: deferring createBrowser until flutter "
              @"host view is attached to a window");
            }
            __weak FlutterCefBrowserPlugin* weakSelf = self;
            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(kCreateBrowserWindowRetryIntervalSeconds * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    FlutterCefBrowserPlugin* strongSelf = weakSelf;
                    if (!strongSelf) {
                        result([FlutterError errorWithCode:@"NO_WINDOW"
                                                   message:@"CEF plugin unavailable before browser host "
                                @"view was attached"
                                                   details:nil]);
                        return;
                    }
                    [strongSelf attemptCreateBrowserForBrowserId:browserId
                                                             url:url
                                                      incognito:incognito
                                                              x:x
                                                              y:y
                                                          width:width
                                                         height:height
                                                     viewHeight:viewHeight
                                                createRequestId:createRequestId
	                                                  renderBackend:renderBackend
	                                                 lifecycleToken:lifecycleToken
	                                             deviceScaleFactor:deviceScaleFactor
	                                                        attempt:attempt + 1
	                                                         result:result];
                });
            return;
        }

        NSLog(@"FlutterCefBrowserPlugin: ERROR - No flutter view available after "
          @"%ld attempts",
              (long)(attempt + 1));
        [_createStartedAtByBrowserId removeObjectForKey:browserNum];
        if ([self isCreateLifecycleCurrentForBrowserId:browserId token:lifecycleToken]) {
            [self invalidateLifecycleTokenForBrowserNumber:browserNum];
        }
        [self emitBrowserCreateFailedForBrowserId:browserId
                                  createRequestId:createRequestId
                                           reason:@"no main window available"];
        result([FlutterError errorWithCode:@"NO_WINDOW"
                                   message:@"Flutter host view was not attached to a window"
                                   details:@{
                                       @"attempts": @(attempt + 1),
                                   }]);
        return;
    }

    _flutterView = flutterView;
    NSLog(@"FlutterCefBrowserPlugin: flutterView = %@, superview = %@", flutterView, flutterView.superview);

    [self startTrackingWindowEventsIfNeeded];
    if (![self isCreateLifecycleCurrentForBrowserId:browserId token:lifecycleToken]) {
        [_createStartedAtByBrowserId removeObjectForKey:browserNum];
        [_createRequestIdsByBrowserId removeObjectForKey:browserNum];
        result(@NO);
        return;
    }

    // Anchor native containers directly in FlutterView coordinates. Using a
    // wrapper/sibling host can introduce coordinate drift in complex shells.
    NSView* hostView = flutterView;
    NSRect frame = ConvertFlutterRectToHostRect(
        flutterView,
        hostView,
        NSMakeRect(x, y, width, height),
        viewHeight);
    NSView* containerView = useOsrTexture
        ? [[CefOsrContainerView alloc] initWithFrame:frame]
        : [[NSView alloc] initWithFrame:frame];
    // We drive the container frame explicitly from Flutter layout. Avoid implicit resizing
    // that can temporarily expand and cover other Flutter UI during abrupt window snaps.
    containerView.autoresizingMask = NSViewNotSizable;
    containerView.translatesAutoresizingMaskIntoConstraints = YES;
    containerView.wantsLayer = YES;
    containerView.layer.masksToBounds = YES;
    containerView.autoresizesSubviews = YES;
    containerView.identifier = @"cef_browser_container";
    containerView.layer.backgroundColor = NSColor.clearColor.CGColor;

    NSNumber* textureIdNumber = nil;
    if (useOsrTexture) {
        if (!_textureRegistry) {
            [_createStartedAtByBrowserId removeObjectForKey:browserNum];
            [self emitBrowserCreateFailedForBrowserId:browserId
                                      createRequestId:createRequestId
                                               reason:@"texture registry unavailable "
                                                @"for osrTexture backend"];
            result([FlutterError errorWithCode:@"NO_TEXTURE_REGISTRY"
                                       message:@"Flutter texture registry is unavailable"
                                       details:nil]);
            return;
        }
        CefOsrTexture* texture = [[CefOsrTexture alloc]
            initWithRegistry:_textureRegistry
                     backend:normalizedRenderBackend];
        int64_t textureId = [_textureRegistry registerTexture:texture];
        if (textureId == 0) {
            [_createStartedAtByBrowserId removeObjectForKey:browserNum];
            [self emitBrowserCreateFailedForBrowserId:browserId
                                      createRequestId:createRequestId
                                               reason:@"texture registration failed"];
            result([FlutterError errorWithCode:@"TEXTURE_REGISTRATION_FAILED"
                                       message:@"Failed to register OSR texture"
                                       details:nil]);
            return;
        }
        [texture setTextureId:textureId];
        [texture setRequestedViewWidth:(int)ceil(MAX(1.0, frame.size.width))
                                height:(int)ceil(MAX(1.0, frame.size.height))
                        effectiveScale:EffectiveOsrTextureScale(
                            deviceScaleFactor, containerView)];
        textureIdNumber = @(textureId);
        _osrTexturesByBrowserId[browserNum] = texture;
        _osrTextureIdsByBrowserId[browserNum] = textureIdNumber;
        // Windowless CEF on macOS still expects its parent handle to be backed
        // by a real NSWindow. Keep the host view transparent and behind
        // Flutter so Flutter owns presentation, but do not mark it hidden:
        // hidden NSViews can prevent CEF from starting OSR paints.
        containerView.hidden = NO;
        containerView.layer.opacity = 0.0;
        NSLog(@"FlutterCefBrowserPlugin: Adding transparent OSR container as "
          @"subview of flutterView BEFORE browser creation");
        [hostView addSubview:containerView positioned:NSWindowBelow relativeTo:nil];
    } else {
        // IMPORTANT: Add containerView to window hierarchy BEFORE creating browser.
        // CEF requires the parent view to be in a window for SetAsChild to work.
        NSLog(@"FlutterCefBrowserPlugin: Adding container as subview of "
          @"flutterView BEFORE browser creation");
        [hostView addSubview:containerView positioned:NSWindowAbove relativeTo:nil];
    }
	    _browserViews[browserId] = containerView;
        _browserHostViews[browserId] = hostView;
	    _lastRequestedFrames[browserId] = frame;
        _renderBackendsByBrowserId[browserId] = normalizedRenderBackend;
    [_ownedBrowserIds addObject:browserNum];
    const BOOL canPresent = [self currentWindowCanPresentBrowserViews];
    NSNumber* requestedVisible = [self requestedVisibilityForBrowserNumber:browserNum];
    containerView.hidden = useOsrTexture ? NO : !(requestedVisible.boolValue && canPresent);
    if (createRequestId.length > 0) {
        _createRequestIdsByBrowserId[browserNum] = createRequestId;
    } else {
        [_createRequestIdsByBrowserId removeObjectForKey:browserNum];
    }

    BOOL success = [self createBrowserWithBridgeForBrowserId:browserId
                                                         url:url
                                                  incognito:incognito
                                                  parentView:containerView
                                                       frame:containerView.bounds
	                                             createRequestId:createRequestId
	                                               renderBackend:normalizedRenderBackend
	                                           deviceScaleFactor:deviceScaleFactor];
    NSLog(@"FlutterCefBrowserPlugin: createBrowserWithId result = %@", success ? @"YES" : @"NO");

    if (success) {
        NSLog(@"FlutterCefBrowserPlugin: Browser creation initiated successfully");
        NSLog(@"FlutterCefBrowserPlugin: === VIEW HIERARCHY ===");
        NSLog(@"FlutterCefBrowserPlugin: containerView = %@, frame = %@", containerView, NSStringFromRect(containerView.frame));
        NSLog(@"FlutterCefBrowserPlugin: containerView.subviews = %@", containerView.subviews);
        NSLog(@"FlutterCefBrowserPlugin: containerView.superview = %@", containerView.superview);
        NSLog(@"FlutterCefBrowserPlugin: containerView.window = %@", containerView.window);
        NSLog(@"FlutterCefBrowserPlugin: === END VIEW HIERARCHY ===");
    } else {
        NSLog(@"FlutterCefBrowserPlugin: Browser creation failed, cleaning up");
	        [containerView removeFromSuperview];
        _browserViews.erase(browserId);
            _browserHostViews.erase(browserId);
	        _lastRequestedFrames.erase(browserId);
            _renderBackendsByBrowserId.erase(browserId);
        [_ownedBrowserIds removeObject:browserNum];
        [self markBrowserNumber:browserNum focused:NO];
        [_programmaticBrowserCloseIds removeObject:browserNum];
        [_createStartedAtByBrowserId removeObjectForKey:browserNum];
        [_requestedVisibilityByBrowserId removeObjectForKey:browserNum];
        [_appliedVisibilityByBrowserId removeObjectForKey:browserNum];
        [self releaseOsrTextureForBrowserNumber:browserNum];
        [self invalidateLifecycleTokenForBrowserNumber:browserNum];
        [self emitBrowserCreateFailedForBrowserId:browserId
                                  createRequestId:createRequestId
                                           reason:@"createBrowserWithId returned false"];
        [_createRequestIdsByBrowserId removeObjectForKey:browserNum];
    }

    if (success && useOsrTexture) {
        result(@{
            @"success": @YES,
            @"renderBackend": normalizedRenderBackend,
            @"textureId": textureIdNumber ?: @0,
        });
    } else {
        result(@(success));
    }
    if (!useOsrTexture) {
        [self scheduleNativeFrameReapply:@"createBrowser"];
    }
}

- (void)scheduleNativeFrameReapply:(NSString*)reason {
    if (_isWindowClosing) return;
    if (_browserViews.empty()) return;

    [self recordNativeReapplyScheduledWithReason:reason];
    _nativeFrameReapplyGeneration += 1;
    const uint64_t generation = _nativeFrameReapplyGeneration;
    NSDictionary<NSNumber*, NSNumber*>* lifecycleTokenSnapshot =
        [_browserLifecycleTokensByBrowserId copy] ?: @{};
    const NSTimeInterval delaySeconds = 0.20;

    __weak FlutterCefBrowserPlugin* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FlutterCefBrowserPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf->_nativeFrameReapplyGeneration) return;

        if (ShouldLogWindowTracking()) {
            NSLog(@"FlutterCefBrowserPlugin: trailing native reapply reason=%@ "
                @"instanceId=%d browsers=%lu",
                  reason ?: @"(null)",
                  strongSelf->_instanceId,
                  (unsigned long)strongSelf->_browserViews.size());
        }
        [strongSelf recordNativeReapplyExecutedWithReason:reason];

        for (const auto& pair : strongSelf->_lastRequestedFrames) {
            const int browserId = pair.first;
            const NSRect frame = pair.second;
            NSNumber* browserNum = @(browserId);
            NSNumber* expectedToken = lifecycleTokenSnapshot[browserNum];
            if (![strongSelf->_ownedBrowserIds containsObject:browserNum] ||
                [strongSelf->_programmaticBrowserCloseIds containsObject:browserNum] ||
                ![strongSelf isOwnedBrowserCurrentForBrowserId:browserId token:expectedToken]) {
                continue;
            }
            if ([strongSelf isOsrBrowserId:browserId]) {
                continue;
            }

	            auto viewIt = strongSelf->_browserViews.find(browserId);
	            if (viewIt == strongSelf->_browserViews.end() || !viewIt->second) continue;
                auto hostIt = strongSelf->_browserHostViews.find(browserId);
                NSView* ownerHostView =
                    (hostIt != strongSelf->_browserHostViews.end()) ? hostIt->second : nil;
                const BOOL canPresent =
                    [strongSelf currentWindowCanPresentBrowserViews] &&
                    ownerHostView &&
                    ownerHostView.window == [strongSelf trackedPresentationWindow];
                if (ownerHostView &&
                    viewIt->second.superview &&
                    viewIt->second.superview != ownerHostView) {
                    [viewIt->second removeFromSuperviewWithoutNeedingDisplay];
                }
                if (canPresent && ownerHostView) {
                    [strongSelf promoteBrowserContainerToFrontIfNeeded:viewIt->second
                                                               hostView:ownerHostView];
                }
	            [strongSelf recordSetViewFrameMetric];
	            [[CEFBridge sharedInstance] setViewFrame:browserId frame:frame];
            [strongSelf applyEffectiveVisibilityForBrowserId:browserId
                                                  browserNum:browserNum
                                               containerView:viewIt->second
                                                  canPresent:canPresent
                                                      reason:reason];
        }
    });
}

- (void)dealloc {
    [FlutterCefBrowserPluginInstances() removeObject:self];
    SyncGlobalCefBrowserFocusFlag();

    [self emitPresentationMetricsIfNeededWithTrigger:@"dealloc"
                                              reason:nil
                                               force:YES];
    // Best-effort cleanup in case the engine is torn down without explicit closeBrowser calls.
    [self cleanupOwnedBrowsers:@"dealloc"];

    [self removeWindowTrackingObservers];
}

- (void)cleanupOwnedBrowsers:(NSString*)reason {
    if (![NSThread isMainThread]) {
        __weak FlutterCefBrowserPlugin* weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf cleanupOwnedBrowsers:reason];
        });
        return;
    }

    _isWindowClosing = YES;
    _methodChannel = nil;

    // Cancel any pending trailing re-apply.
    _nativeFrameReapplyGeneration += 1;

    // Stop listening for window/view events immediately so we don't try to
    // message a torn-down Flutter engine during shutdown.
    [self removeWindowTrackingObservers];

    if (_windowCloseRetryTimer) {
        [_windowCloseRetryTimer invalidate];
        _windowCloseRetryTimer = nil;
    }
    _windowCloseTransaction = nil;

    NSWindow* windowForCleanup = _trackedWindow ?: (_flutterView ? _flutterView.window : nil);

	    // Restore the previous window delegate if we installed a proxy.
	    if (_trackedWindow && _windowDelegateProxy && _trackedWindow.delegate == _windowDelegateProxy) {
	        _trackedWindow.delegate = _originalWindowDelegate;
	    }
	    _windowDelegateProxy = nil;
	    _originalWindowDelegate = nil;
	    _trackedWindow = nil;

	    NSLog(@"FlutterCefBrowserPlugin: cleanupOwnedBrowsers reason=%@ "
        @"instanceId=%d count=%lu",
	          reason ?: @"(null)",
	          _instanceId,
          (unsigned long)_ownedBrowserIds.count);

	    if (_ownedBrowserIds.count > 0) {
	        NSArray<NSNumber*>* ids = [_ownedBrowserIds allObjects];
	        for (NSNumber* browserNum in ids) {
		            const int browserId = browserNum.intValue;
		            _lastRequestedFrames.erase(browserId);
                    _browserHostViews.erase(browserId);
	                auto viewIt = _browserViews.find(browserId);
                if (viewIt != _browserViews.end() && viewIt->second) {
                    [viewIt->second removeFromSuperview];
                    _browserViews.erase(viewIt);
                }

	            // Close browser (also closes docked DevTools, if any).
	            [[CEFBridge sharedInstance] closeBrowser:browserId];
	        }

	        // Clear tracked IDs so we don't attempt to close twice after teardown.
	        [_ownedBrowserIds removeAllObjects];
	    }
        [_focusedBrowserIds removeAllObjects];
        _lastFocusedBrowserId = nil;
        [self syncGlobalBrowserFocusFlag];
        [_programmaticBrowserCloseIds removeAllObjects];
        [_createRequestIdsByBrowserId removeAllObjects];
        [_browserLifecycleTokensByBrowserId removeAllObjects];
        [_requestedVisibilityByBrowserId removeAllObjects];
        [_appliedVisibilityByBrowserId removeAllObjects];

	    // Fallback: ensure any browser views still attached to this window are closed
	    // even if Dart teardown raced ahead of the native close handshake.
	    if (windowForCleanup) {
	        [[CEFBridge sharedInstance] closeBrowsersInWindow:windowForCleanup reason:reason];
	    }
	}

- (void)scheduleFlutterFrameSyncRequest:(NSString*)reason {
    if (_isWindowClosing) return;
    if (_frameSyncRequestScheduled) return;
    if (!_methodChannel) return;
    if (_browserViews.empty()) return;

    _frameSyncRequestScheduled = YES;
    __weak FlutterCefBrowserPlugin* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        FlutterCefBrowserPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;

        strongSelf->_frameSyncRequestScheduled = NO;
        if (ShouldLogWindowTracking()) {
            NSWindow* window = strongSelf->_flutterView.window;
            NSLog(@"FlutterCefBrowserPlugin: requestFrameSync reason=%@ "
            @"instanceId=%d window=%@ window.frame=%@ flutterView.bounds=%@",
                  reason ?: @"(null)",
                  strongSelf->_instanceId,
                  window,
                  window ? NSStringFromRect(window.frame) : @"(null)",
                  strongSelf->_flutterView ? NSStringFromRect(strongSelf->_flutterView.bounds) : @"(null)");
        }
        [strongSelf->_methodChannel invokeMethod:@"requestFrameSync"
                                       arguments:@{
                                           @"reason": reason ?: @"unknown",
                                           @"instanceId": @(strongSelf->_instanceId),
                                       }];

        // Keep native-side repair for settled resize/backing changes. During
        // ordinary move/resize churn, Dart frame sync already applies the
        // latest geometry; replaying the native frame again can visibly blank
        // Chromium's child view.
        if ([reason isEqualToString:@"NSWindowDidEndLiveResize"] ||
            [reason isEqualToString:@"NSWindowDidChangeBackingProperties"]) {
            [strongSelf scheduleNativeFrameReapply:reason];
        }
    });
	}

		- (BOOL)_handleWindowShouldClose:(NSWindow*)window {
		    if (ShouldLogWindowTracking()) {
		        NSLog(@"FlutterCefBrowserPlugin: windowShouldClose instanceId=%d "
          @"ownedBrowsers=%lu window=%@",
		              _instanceId,
		              (unsigned long)_ownedBrowserIds.count,
		              window);
		    }

    if (_isWindowClosing) {
        return YES;
    }

    // Close requests can be emitted by CEF internals while a tab/browser is
    // being programmatically closed. Block them so tab close does not cascade
    // into host-window close.
    if (_programmaticBrowserCloseIds.count > 0 &&
        !_windowCloseRequested) {
        if (ShouldLogWindowTracking()) {
            NSLog(@"FlutterCefBrowserPlugin: suppress synthetic windowShouldClose "
            @"during programmatic browser close (instanceId=%d "
            @"pendingProgrammatic=%lu)",
                  _instanceId,
                  (unsigned long)_programmaticBrowserCloseIds.count);
        }
        return NO;
    }

	    if (_ownedBrowserIds.count == 0) {
            if (_windowCloseRetryTimer) {
                [_windowCloseRetryTimer invalidate];
                _windowCloseRetryTimer = nil;
            }
            _windowCloseTransaction = nil;
            _windowCloseRequested = NO;
	        if (_originalWindowDelegate && [_originalWindowDelegate respondsToSelector:@selector(windowShouldClose:)]) {
	            return [_originalWindowDelegate windowShouldClose:window];
	        }
	        return YES;
	    }

        if (!_windowCloseRequested) {
            _windowCloseRequested = YES;
            [self startWindowCloseTransactionIfNeeded];
            for (NSNumber* browserNum in _ownedBrowserIds) {
                [[CEFBridge sharedInstance] closeBrowser:browserNum.intValue];
            }
            [self scheduleWindowCloseRetryIfNeededForWindow:window];
            return NO;
        }

        [self scheduleWindowCloseRetryIfNeededForWindow:window];
        [self pollWindowCloseTransactionForWindow:window];
        return NO;
	}

- (void)startTrackingWindowEventsIfNeeded {
	    if (_trackingWindowEvents) return;
	    if (!_flutterView) return;

	    NSWindow* window = _flutterView.window;
	    if (!window) return;

	    _trackingWindowEvents = YES;
	    _trackedWindow = window;

	    // Intercept window close so we can initiate CEF close while the window is
	    // still alive. Closing the window first and then calling CloseBrowser
	    // leaves Alloy-style browsers stuck between DoClose and OnBeforeClose.
	    if (!_windowDelegateProxy) {
	        id<NSWindowDelegate> currentDelegate = window.delegate;
	        _originalWindowDelegate = currentDelegate;

	        _windowDelegateProxy = [[CEFWindowDelegateProxy alloc] init];
	        _windowDelegateProxy.plugin = self;
	        _windowDelegateProxy.originalDelegate = currentDelegate;
	        window.delegate = _windowDelegateProxy;
	    }

	    _flutterView.postsFrameChangedNotifications = YES;
	    _flutterView.postsBoundsChangedNotifications = YES;

    __weak FlutterCefBrowserPlugin* weakSelf = self;
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];

    _windowDidResizeObserver =
        [nc addObserverForName:NSWindowDidResizeNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf scheduleFlutterFrameSyncRequest:@"NSWindowDidResize"];
                    }];

    _windowDidEndLiveResizeObserver =
        [nc addObserverForName:NSWindowDidEndLiveResizeNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf scheduleFlutterFrameSyncRequest:@"NSWindowDidEndLiveResize"];
                    }];

    _windowDidMoveObserver =
        [nc addObserverForName:NSWindowDidMoveNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf scheduleFlutterFrameSyncRequest:@"NSWindowDidMove"];
                    }];

    _windowDidChangeBackingObserver =
        [nc addObserverForName:NSWindowDidChangeBackingPropertiesNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf scheduleFlutterFrameSyncRequest:@"NSWindowDidChangeBackingProperties"];
                    }];

    _windowDidChangeOcclusionStateObserver =
        [nc addObserverForName:NSWindowDidChangeOcclusionStateNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        NSWindow* occlusionWindow = (NSWindow*)note.object;
                        const BOOL occlusionVisible =
                            (occlusionWindow.occlusionState & NSWindowOcclusionStateVisible) != 0;
                        [[CEFBridge sharedInstance] setWindowOccluded:!occlusionVisible];
                        [strongSelf reconcileWindowPresentationState:@"NSWindowDidChangeOcclusionState"
	                                                         forceRepair:NO];
                    }];

    _windowDidBecomeKeyObserver =
        [nc addObserverForName:NSWindowDidBecomeKeyNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSWindowDidBecomeKey"
                                                         forceRepair:NO];
                    }];

    _windowDidResignKeyObserver =
        [nc addObserverForName:NSWindowDidResignKeyNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSWindowDidResignKey"
                                                         forceRepair:NO];
                    }];

    _windowDidBecomeMainObserver =
        [nc addObserverForName:NSWindowDidBecomeMainNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSWindowDidBecomeMain"
                                                         forceRepair:NO];
                    }];

    _windowDidResignMainObserver =
        [nc addObserverForName:NSWindowDidResignMainNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSWindowDidResignMain"
                                                         forceRepair:NO];
                    }];

    _windowDidMiniaturizeObserver =
        [nc addObserverForName:NSWindowDidMiniaturizeNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSWindowDidMiniaturize"
                                                         forceRepair:NO];
                    }];

    _windowDidDeminiaturizeObserver =
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSWindowDidDeminiaturize"
                                                         forceRepair:NO];
                        [strongSelf scheduleWindowPresentationStateReconcile:@"NSWindowDidDeminiaturize.trailing"
                                                                     delay:0.20];
                    }];

    _workspaceActiveSpaceDidChangeObserver =
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSWorkspaceActiveSpaceDidChange"
                                                         forceRepair:NO];
                        [strongSelf scheduleWindowPresentationStateReconcile:@"NSWorkspaceActiveSpaceDidChange.trailing"
                                                                     delay:0.20];
                    }];

    _appDidBecomeActiveObserver =
        [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSApplicationDidBecomeActive"
                                                         forceRepair:NO];
                    }];

    _appDidResignActiveObserver =
        [nc addObserverForName:NSApplicationDidResignActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf reconcileWindowPresentationState:@"NSApplicationDidResignActive"
                                                         forceRepair:NO];
                    }];

    _windowWillCloseObserver =
        [nc addObserverForName:NSWindowWillCloseNotification
                        object:window
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf cleanupOwnedBrowsers:@"NSWindowWillClose"];
                    }];

    _flutterViewFrameObserver =
        [nc addObserverForName:NSViewFrameDidChangeNotification
                        object:_flutterView
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf scheduleFlutterFrameSyncRequest:@"NSViewFrameDidChange(FlutterView)"];
                    }];

    _flutterViewBoundsObserver =
        [nc addObserverForName:NSViewBoundsDidChangeNotification
                        object:_flutterView
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification* note) {
                        FlutterCefBrowserPlugin* strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf scheduleFlutterFrameSyncRequest:@"NSViewBoundsDidChange(FlutterView)"];
                    }];

    if (ShouldLogWindowTracking()) {
        NSLog(@"FlutterCefBrowserPlugin: Window tracking enabled instanceId=%d "
          @"window=%@ window.frame=%@ flutterView=%@ flutterView.bounds=%@",
              _instanceId,
              window,
              NSStringFromRect(window.frame),
              _flutterView,
              NSStringFromRect(_flutterView.bounds));
    }

    [self reconcileWindowPresentationState:@"startTrackingWindowEvents"
                               forceRepair:YES];
}

- (void)syncGlobalBrowserFocusFlag {
    SyncGlobalCefBrowserFocusFlag();
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterCefBrowserPlugin* instance = [[FlutterCefBrowserPlugin alloc] init];

    // Method channel
    FlutterMethodChannel* methodChannel = [FlutterMethodChannel
        methodChannelWithName:@"com.example/cef_browser"
              binaryMessenger:[registrar messenger]];
    [registrar addMethodCallDelegate:instance channel:methodChannel];
    instance->_methodChannel = methodChannel;

    // Event channels
    instance->_browserEventChannel = [FlutterEventChannel
        eventChannelWithName:@"com.example/cef_browser/browser_events"
             binaryMessenger:[registrar messenger]];
    [instance->_browserEventChannel setStreamHandler:instance];

    instance->_downloadEventChannel = [FlutterEventChannel
        eventChannelWithName:@"com.example/cef_browser/downloads"
             binaryMessenger:[registrar messenger]];
    [instance->_downloadEventChannel setStreamHandler:instance];

    instance->_consoleEventChannel = [FlutterEventChannel
        eventChannelWithName:@"com.example/cef_browser/console"
             binaryMessenger:[registrar messenger]];
    [instance->_consoleEventChannel setStreamHandler:instance];

    instance->_networkEventChannel = [FlutterEventChannel
        eventChannelWithName:@"com.example/cef_browser/network"
             binaryMessenger:[registrar messenger]];
    [instance->_networkEventChannel setStreamHandler:instance];

    // Set delegate
    [CEFBridge sharedInstance].delegate = instance;

    // Store the Flutter view from registrar
    instance->_flutterView = registrar.view;
    instance->_flutterViewController = registrar.viewController;
    instance->_textureRegistry = registrar.textures;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSDictionary* args = call.arguments;

    if ([@"runPreflight" isEqualToString:call.method]) {
        NSDictionary* config = [self runtimeConfigFromMethodArguments:args ?: @{}];
        dispatch_async(dispatch_get_main_queue(), ^{
            result([self runBridgePreflightWithConfig:config]);
        });
        return;
    }
    if ([@"initialize" isEqualToString:call.method]) {
        NSDictionary* config = [self runtimeConfigFromMethodArguments:args ?: @{}];
        _gracefulCloseTimeoutMs = MAX(
            1,
            IntegerOrDefault(config[@"gracefulCloseTimeoutMs"], 1200));
        if (ShouldLogReliabilityDebug()) {
            NSLog(@"FlutterCefBrowserPlugin: initialize config=%@", config);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                NSDictionary* preflightReport = [self runBridgePreflightWithConfig:config];
                NSArray* failures = [preflightReport[@"failures"] isKindOfClass:[NSArray class]]
                    ? (NSArray*)preflightReport[@"failures"]
                    : @[];
                if (failures.count > 0) {
                    NSDictionary* firstFailure = [failures.firstObject isKindOfClass:[NSDictionary class]]
                        ? (NSDictionary*)failures.firstObject
                        : @{};
                    result(@{
                        @"success": @NO,
                        @"failureCode": StringOrNil(firstFailure[@"code"]) ?: @"preflight_failed",
                        @"failureStage": @"preflight",
                        @"message": StringOrNil(firstFailure[@"message"]) ?: @"CEF preflight failed",
                        @"preflightReport": preflightReport,
                    });
                    return;
                }

                NSDictionary* filesystemResult = [self prepareFilesystemForConfig:config];
                if (!BoolOrDefault(filesystemResult[@"success"], NO)) {
                    NSMutableDictionary* output = [filesystemResult mutableCopy];
                    output[@"preflightReport"] = preflightReport;
                    result([output copy]);
                    return;
                }

                NSDictionary* initializeResult = [self initializeBridgeWithConfig:config];
                if (BoolOrDefault(initializeResult[@"success"], NO)) {
                    startMessageLoop();
                }

                if (![initializeResult[@"preflightReport"] isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary* output = [initializeResult mutableCopy];
                    output[@"preflightReport"] = preflightReport;
                    initializeResult = [output copy];
                }
                result(initializeResult);
            });
        });
        return;
    }
    else if ([@"getInstanceId" isEqualToString:call.method]) {
        result(@(_instanceId));
    }
    else if ([@"closeAllBrowsersImmediately" isEqualToString:call.method]) {
        // App-quit / emergency path: force-close every browser so
        // windowShouldClose is not blocked waiting for unload handlers.
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleMethodCall:call result:result];
            });
            return;
        }
        [[CEFBridge sharedInstance] closeAllBrowsersImmediately];
        // Drop local ownership so window close can proceed immediately if
        // OnBeforeClose is delayed past process exit.
        [_ownedBrowserIds removeAllObjects];
        [_programmaticBrowserCloseIds removeAllObjects];
        if (_windowCloseRetryTimer) {
            [_windowCloseRetryTimer invalidate];
            _windowCloseRetryTimer = nil;
        }
        _windowCloseTransaction = nil;
        _windowCloseRequested = NO;
        result(nil);
    }
    else if ([@"shutdown" isEqualToString:call.method]) {
        // Prefer force-close first so shutdown is not gated on graceful unload.
        [[CEFBridge sharedInstance] closeAllBrowsersImmediately];
        [[CEFBridge sharedInstance] shutdown];
        result(nil);
    }
    else if ([@"createBrowser" isEqualToString:call.method]) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleMethodCall:call result:result];
            });
            return;
        }

        int browserId = GetBrowserId(args);
        NSString* createRequestId = ([args[@"createRequestId"] isKindOfClass:[NSString class]] &&
                                     [args[@"createRequestId"] length] > 0)
            ? (NSString*)args[@"createRequestId"]
            : nil;
        NSString* url = args[@"url"];
        NSString* renderBackend = NormalizeRenderBackendName(args[@"renderBackend"]);
        BOOL incognito = args[@"incognito"] ? [args[@"incognito"] boolValue] : NO;
        double x = [args[@"x"] doubleValue];
        double y = [args[@"y"] doubleValue];
	        double width = [args[@"width"] doubleValue];
	        double height = [args[@"height"] doubleValue];

	        const double viewHeight = [args[@"viewHeight"] doubleValue];
	        const double deviceScaleFactor = [args[@"deviceScaleFactor"] doubleValue];
	        if (ShouldLogFrameSync()) {
	            NSLog(@"FlutterCefBrowserPlugin: createBrowser called - id: %d, url: %@, "
            @"frame: (%.2f, %.2f, %.2f, %.2f), viewHeight: %.2f, dpr: %.2f",
	                  browserId, url, x, y, width, height, viewHeight, deviceScaleFactor);
        } else {
            NSLog(@"FlutterCefBrowserPlugin: createBrowser called - id: %d, url: %@, "
            @"incognito: %@, frame: (%.0f, %.0f, %.0f, %.0f)",
                  browserId, url, incognito ? @"YES" : @"NO", x, y, width, height);
        }
        NSNumber* browserNum = @(browserId);
        NSNumber* lifecycleToken = [self advanceLifecycleTokenForBrowserNumber:browserNum];
        [_programmaticBrowserCloseIds removeObject:browserNum];
        _createStartedAtByBrowserId[browserNum] = [NSDate date];
        [self attemptCreateBrowserForBrowserId:browserId
                                           url:url
                                    incognito:incognito
                                            x:x
                                            y:y
                                        width:width
                                       height:height
                                   viewHeight:viewHeight
                              createRequestId:createRequestId
	                                renderBackend:renderBackend
	                                lifecycleToken:lifecycleToken
	                            deviceScaleFactor:deviceScaleFactor
	                                      attempt:0
	                                       result:result];
  } else if ([@"setOsrFrameTransferMode" isEqualToString:call.method]) {
    const int browserId = GetBrowserId(args);
    CefOsrTexture *texture = _osrTexturesByBrowserId[@(browserId)];
    NSString *mode = [args[@"mode"] isKindOfClass:[NSString class]]
                         ? args[@"mode"]
                         : @"copied";
    NSString *selectedMode =
        texture ? [texture setFrameLeaseMode:mode] : @"copied";
    [[CEFBridge sharedInstance]
        setAcceleratedFrameLeaseEnabled:browserId
                                enabled:![selectedMode
                                            isEqualToString:@"copied"]];
    result(selectedMode);
    }
    else if ([@"getOsrPerformanceStats" isEqualToString:call.method]) {
        const int browserId = GetBrowserId(args);
        CefOsrTexture* texture = _osrTexturesByBrowserId[@(browserId)];
        result(texture ? [texture performanceStats] : @{
            @"backend": @"nativeView",
            @"frameCount": @0,
        });
    }
	    else if ([@"closeBrowser" isEqualToString:call.method]) {
	        int browserId = GetBrowserId(args);
            BOOL force = NO;
            id forceArg = args[@"force"];
            if (forceArg && forceArg != [NSNull null] && [forceArg respondsToSelector:@selector(boolValue)]) {
                force = [forceArg boolValue];
            }
            NSNumber* browserNum = @(browserId);
            [_programmaticBrowserCloseIds addObject:browserNum];
            [self invalidateLifecycleTokenForBrowserNumber:browserNum];
            [self markBrowserNumber:browserNum focused:NO];
            _lastRequestedFrames.erase(browserId);
            [_createStartedAtByBrowserId removeObjectForKey:browserNum];
            [_requestedVisibilityByBrowserId removeObjectForKey:browserNum];
            [_appliedVisibilityByBrowserId removeObjectForKey:browserNum];
            [[CEFBridge sharedInstance] setFocus:browserId focused:NO];
            [[CEFBridge sharedInstance] setVisible:browserId visible:NO];

            // Hide/remove immediately so a closing tab never leaves a frozen
            // native view overlay while CEF finishes asynchronous teardown.
	            auto viewIt = _browserViews.find(browserId);
            if (viewIt != _browserViews.end() && viewIt->second) {
                [viewIt->second removeFromSuperview];
                _browserViews.erase(viewIt);
            }
            _browserHostViews.erase(browserId);
            _renderBackendsByBrowserId.erase(browserId);
            [self releaseOsrTextureForBrowserNumber:browserNum];
            [_createRequestIdsByBrowserId removeObjectForKey:browserNum];

	        [[CEFBridge sharedInstance] closeBrowser:browserId force:force];
	        result(nil);
	    }
    else if ([@"loadUrl" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* url = args[@"url"];
        [[CEFBridge sharedInstance] loadUrl:browserId url:url];
        result(nil);
    }
    else if ([@"reload" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        BOOL ignoreCache = [args[@"ignoreCache"] boolValue];
        [[CEFBridge sharedInstance] reload:browserId ignoreCache:ignoreCache];
        result(nil);
    }
    else if ([@"stop" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] stop:browserId];
        result(nil);
    }
    else if ([@"goBack" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] goBack:browserId];
        result(nil);
    }
    else if ([@"goForward" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] goForward:browserId];
        result(nil);
    }
    else if ([@"executeJavaScript" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* code = args[@"code"];
        [[CEFBridge sharedInstance] executeJavaScript:browserId code:code completion:^(NSError* error) {
            if (error) {
                result(FlutterErrorFromNSError(error, @"JS_ERROR"));
            } else {
                result(nil);
            }
        }];
    }
    else if ([@"evaluateJavaScript" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* expression = args[@"expression"];
        [[CEFBridge sharedInstance] evaluateJavaScript:browserId expression:expression completion:^(NSString* jsResult, NSError* error) {
            if (error) {
                result(FlutterErrorFromNSError(error, @"JS_EVAL_ERROR"));
            } else {
                result(jsResult);
            }
        }];
    }
    else if ([@"captureViewportScreenshot" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* format = [args[@"format"] isKindOfClass:[NSString class]]
            ? (NSString*)args[@"format"]
            : @"png";
        NSInteger quality = [args[@"quality"] respondsToSelector:@selector(integerValue)]
            ? [args[@"quality"] integerValue]
            : 85;
        [[CEFBridge sharedInstance] captureViewportScreenshot:browserId
                                                      format:format
                                                     quality:quality
                                                  completion:^(NSString* data, NSError* error) {
            if (error) {
                result(FlutterErrorFromNSError(error, @"SCREENSHOT_ERROR"));
            } else {
                result(data);
            }
        }];
    }
    else if ([@"dispatchInput" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* method = [args[@"method"] isKindOfClass:[NSString class]] ? args[@"method"] : nil;
        NSDictionary* params = [args[@"params"] isKindOfClass:[NSDictionary class]] ? args[@"params"] : nil;
        if (!method || !params) {
            result([FlutterError errorWithCode:@"INPUT_INVALID" message:@"Invalid input command" details:nil]);
            return;
        }
        [[CEFBridge sharedInstance] dispatchInput:browserId method:method params:params completion:^(NSError* error) {
            result(error ? FlutterErrorFromNSError(error, @"INPUT_ERROR") : nil);
        }];
    }
    else if ([@"performEditCommand" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* command = [args[@"command"] isKindOfClass:[NSString class]]
            ? (NSString*)args[@"command"]
            : @"";
        result(@([[CEFBridge sharedInstance] performEditCommand:command browserId:browserId]));
    }
    else if ([@"hideStaleBrowsers" isEqualToString:call.method]) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleMethodCall:call result:result];
            });
            return;
        }

        NSMutableSet<NSNumber*>* keepVisibleBrowserIds = [NSMutableSet set];
        NSArray* rawKeepIds = [args[@"keepVisibleBrowserIds"] isKindOfClass:[NSArray class]]
            ? (NSArray*)args[@"keepVisibleBrowserIds"]
            : @[];
        for (id value in rawKeepIds) {
            if ([value respondsToSelector:@selector(intValue)]) {
                [keepVisibleBrowserIds addObject:@([value intValue])];
            }
        }
        NSString* reason = [args[@"reason"] isKindOfClass:[NSString class]]
            ? (NSString*)args[@"reason"]
            : @"hideStaleBrowsers";
        result([FlutterCefBrowserPlugin
            hideStaleBrowsersAcrossInstancesKeepingBrowserIds:keepVisibleBrowserIds
                                                       reason:reason]);
    }
    else if ([@"setFocus" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        BOOL focused = [args[@"focused"] boolValue];
        NSNumber* browserNum = @(browserId);
        if (![_ownedBrowserIds containsObject:browserNum] ||
            [_programmaticBrowserCloseIds containsObject:browserNum]) {
            [self markBrowserNumber:browserNum focused:NO];
            result(nil);
            return;
        }
        auto focusHostIt = _browserHostViews.find(browserId);
        NSView* focusOwnerHostView =
            (focusHostIt != _browserHostViews.end()) ? focusHostIt->second : nil;
        const BOOL focusOwnerCanPresent =
            [self currentWindowCanPresentBrowserViews] &&
            focusOwnerHostView &&
            focusOwnerHostView.window == [self trackedPresentationWindow];
        if (focused && ![self isOsrBrowserId:browserId] && !focusOwnerCanPresent) {
            [self markBrowserNumber:browserNum focused:NO];
            [[CEFBridge sharedInstance] setFocus:browserId focused:NO];
            result(nil);
            return;
        }
        NSNumber* requestedVisible = _requestedVisibilityByBrowserId[browserNum];
        if (focused && requestedVisible != nil && !requestedVisible.boolValue) {
            [self markBrowserNumber:browserNum focused:NO];
            [[CEFBridge sharedInstance] setFocus:browserId focused:NO];
            result(nil);
            return;
        }
        [self markBrowserNumber:browserNum focused:focused];
        [[CEFBridge sharedInstance] setFocus:browserId focused:focused];
        result(nil);
    }
	    else if ([@"setVisible" isEqualToString:call.method]) {
	        if (![NSThread isMainThread]) {
	            dispatch_async(dispatch_get_main_queue(), ^{
	                [self handleMethodCall:call result:result];
	            });
	            return;
	        }

	        int browserId = GetBrowserId(args);
            NSNumber* browserNum = @(browserId);
            if (![_ownedBrowserIds containsObject:browserNum] ||
                [_programmaticBrowserCloseIds containsObject:browserNum]) {
                [_requestedVisibilityByBrowserId removeObjectForKey:browserNum];
                [_appliedVisibilityByBrowserId removeObjectForKey:browserNum];
                result(nil);
                return;
            }
	    BOOL visible = args[@"visible"] ? [args[@"visible"] boolValue] : YES;
	    _requestedVisibilityByBrowserId[browserNum] = @(visible);
            if ([self isOsrBrowserId:browserId]) {
                if (!visible) {
                    [self markBrowserNumber:browserNum focused:NO];
                }
                [self recordSetVisibleMetric];
                [[CEFBridge sharedInstance] setVisible:browserId visible:visible];
                result(nil);
                return;
            }
            const BOOL canPresent = [self currentWindowCanPresentBrowserViews];
            auto viewIt = _browserViews.find(browserId);
            if (viewIt != _browserViews.end() && viewIt->second) {
                auto hostIt = _browserHostViews.find(browserId);
                NSView* ownerHostView = (hostIt != _browserHostViews.end()) ? hostIt->second : nil;
                const BOOL ownerCanPresent =
                    canPresent &&
                    ownerHostView &&
                    ownerHostView.window == [self trackedPresentationWindow];
                if (ownerHostView &&
                    viewIt->second.superview &&
                    viewIt->second.superview != ownerHostView) {
                    [viewIt->second removeFromSuperviewWithoutNeedingDisplay];
                }
                if (visible && ownerCanPresent && ownerHostView) {
                    [self promoteBrowserContainerToFrontIfNeeded:viewIt->second hostView:ownerHostView];
                }
                [self applyEffectiveVisibilityForBrowserId:browserId
                                                browserNum:browserNum
                                                containerView:viewIt->second
                                                canPresent:ownerCanPresent
                                                    reason:@"setVisible"];
            } else {
                [self recordSetVisibleMetric];
                [[CEFBridge sharedInstance] setVisible:browserId visible:NO];
		            }
            // Routine visibility updates apply immediately. Keep trailing native
            // reapply reserved for create/onCreated and explicit drift/recovery paths.
	        result(nil);
	    }
    else if ([@"sendMouseMove" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] sendMouseMove:browserId
                                                x:[args[@"x"] doubleValue]
                                                y:[args[@"y"] doubleValue]
                                        modifiers:IntegerOrDefault(args[@"modifiers"], 0)
                                       mouseLeave:BoolOrDefault(args[@"mouseLeave"], NO)];
        result(nil);
    }
    else if ([@"findInPage" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] findInPage:browserId
                                        query:StringOrNil(args[@"query"]) ?: @""
                                      forward:BoolOrDefault(args[@"forward"], YES)
                                     findNext:BoolOrDefault(args[@"findNext"], NO)
                                    matchCase:BoolOrDefault(args[@"matchCase"], NO)];
        result(nil);
    }
    else if ([@"stopFinding" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] stopFinding:browserId
                                clearSelection:BoolOrDefault(args[@"clearSelection"], YES)];
        result(nil);
    }
    else if ([@"sendMouseClick" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] sendMouseClick:browserId
                                                 x:[args[@"x"] doubleValue]
                                                 y:[args[@"y"] doubleValue]
                                            button:StringOrNil(args[@"button"]) ?: @"left"
                                           mouseUp:BoolOrDefault(args[@"mouseUp"], NO)
                                        clickCount:MAX(1, IntegerOrDefault(args[@"clickCount"], 1))
                                         modifiers:IntegerOrDefault(args[@"modifiers"], 0)];
        result(nil);
    }
    else if ([@"sendMouseWheel" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] sendMouseWheel:browserId
                                                 x:[args[@"x"] doubleValue]
                                                 y:[args[@"y"] doubleValue]
                                            deltaX:IntegerOrDefault(args[@"deltaX"], 0)
                                            deltaY:IntegerOrDefault(args[@"deltaY"], 0)
                                         modifiers:IntegerOrDefault(args[@"modifiers"], 0)];
        result(nil);
    }
    else if ([@"pinchZoom" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] pinchZoom:browserId
                                        scale:[args[@"scale"] doubleValue]
                                            x:[args[@"x"] doubleValue]
                                            y:[args[@"y"] doubleValue]];
        result(nil);
    }
    else if ([@"sendKeyEvent" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] sendKeyEvent:browserId
                                            type:StringOrNil(args[@"type"]) ?: @"rawKeyDown"
                                  windowsKeyCode:IntegerOrDefault(args[@"windowsKeyCode"], 0)
                                   nativeKeyCode:IntegerOrDefault(args[@"nativeKeyCode"], 0)
                                       character:IntegerOrDefault(args[@"character"], 0)
                             unmodifiedCharacter:IntegerOrDefault(args[@"unmodifiedCharacter"], 0)
                                       modifiers:IntegerOrDefault(args[@"modifiers"], 0)
                                     isSystemKey:BoolOrDefault(args[@"isSystemKey"], NO)];
        result(nil);
    }
    else if ([@"imeSetComposition" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        if ([self isOsrBrowserId:browserId]) {
            NSString* text = [args[@"text"] isKindOfClass:[NSString class]]
                ? (NSString*)args[@"text"] : @"";
            [[CEFBridge sharedInstance] imeSetComposition:browserId
                                                     text:text
                                                 selStart:IntegerOrDefault(args[@"selStart"], 0)
                                                   selEnd:IntegerOrDefault(args[@"selEnd"], 0)];
        }
        result(nil);
    }
    else if ([@"imeCommitText" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        if ([self isOsrBrowserId:browserId]) {
            NSString* text = [args[@"text"] isKindOfClass:[NSString class]]
                ? (NSString*)args[@"text"] : @"";
            [[CEFBridge sharedInstance] imeCommitText:browserId text:text];
        }
        result(nil);
    }
    else if ([@"imeFinishComposing" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        if ([self isOsrBrowserId:browserId]) {
            [[CEFBridge sharedInstance]
                imeFinishComposing:browserId
                     keepSelection:BoolOrDefault(args[@"keepSelection"], NO)];
        }
        result(nil);
    }
    else if ([@"imeCancelComposition" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        if ([self isOsrBrowserId:browserId]) {
            [[CEFBridge sharedInstance] imeCancelComposition:browserId];
        }
        result(nil);
    }
    else if ([@"setZoomLevel" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        const double level = [args[@"level"] doubleValue];
        if ([self isOsrBrowserId:browserId] && isfinite(level)) {
            [[CEFBridge sharedInstance] setZoomLevel:browserId level:level];
        }
        result(nil);
    }
    else if ([@"resolveJsDialog" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        if ([self isOsrBrowserId:browserId]) {
            NSString* userInput = [args[@"userInput"] isKindOfClass:[NSString class]]
                ? (NSString*)args[@"userInput"] : nil;
            [[CEFBridge sharedInstance]
                resolveJsDialog:browserId
                      callbackId:(int)IntegerOrDefault(args[@"callbackId"], -1)
                          success:BoolOrDefault(args[@"success"], NO)
                        userInput:userInput];
        }
        result(nil);
    }
    else if ([@"resolvePermissionPrompt" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* promptId = [args[@"promptId"] isKindOfClass:[NSString class]]
            ? (NSString*)args[@"promptId"] : @"";
        if ([_ownedBrowserIds containsObject:@(browserId)] && promptId.length > 0) {
            [[CEFBridge sharedInstance]
                resolvePermissionPrompt:browserId
                                 promptId:promptId
                                    allow:BoolOrDefault(args[@"allow"], NO)];
        }
        result(nil);
    }
    else if ([@"resolveContextMenu" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance]
            resolveContextMenu:browserId
                         menuId:(int)IntegerOrDefault(args[@"menuId"], -1)
                      commandId:(int)IntegerOrDefault(args[@"commandId"], -1)];
        result(nil);
    }
    else if ([@"cancelContextMenu" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance]
            cancelContextMenu:browserId
                        menuId:(int)IntegerOrDefault(args[@"menuId"], -1)];
        result(nil);
    }
    else if ([@"setFramePacing" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        const int targetFps = (int)IntegerOrDefault(args[@"targetFps"], 60);
        const BOOL visible = BoolOrDefault(args[@"visible"], YES);
        const BOOL backgroundActivityExempt =
            BoolOrDefault(args[@"backgroundActivityExempt"], NO);
        [[CEFBridge sharedInstance] setFramePacing:browserId
                                          targetFps:targetFps
                                            visible:visible
                           backgroundActivityExempt:backgroundActivityExempt];
        [_osrTexturesByBrowserId[@(browserId)] setTargetFps:targetFps];
        result(nil);
    }
    else if ([@"openDevTools" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        if (![self isOsrBrowserId:browserId]) {
            // nativeView backend keeps the legacy child-view/dock path.
            NSString* position = StringOrNil(args[@"dock"]) ?: @"right";
            [[CEFBridge sharedInstance] showDevTools:browserId docked:YES position:position];
            result(@{@"legacy": @YES});
            return;
        }
        if (!_textureRegistry || !_flutterView) {
            result([FlutterError errorWithCode:@"NO_TEXTURE_REGISTRY"
                                       message:@"Texture registry or host view unavailable"
                                       details:nil]);
            return;
        }
        const int existingDevToolsId =
            [[CEFBridge sharedInstance] devToolsFlutterBrowserIdForOwner:browserId];
        if (existingDevToolsId >= 0) {
            NSNumber* existingTexture = _osrTextureIdsByBrowserId[@(existingDevToolsId)];
            result(@{
                @"devToolsBrowserId": @(existingDevToolsId),
                @"textureId": existingTexture ?: @0,
                @"renderBackend": _renderBackendsByBrowserId.count(existingDevToolsId)
                    ? _renderBackendsByBrowserId[existingDevToolsId]
                    : @"osrTexture",
            });
            return;
        }

        NSString* backend = _renderBackendsByBrowserId.count(browserId)
            ? _renderBackendsByBrowserId[browserId]
            : @"osrTexture";
        const int devToolsBrowserId =
            [[CEFBridge sharedInstance] allocateDevToolsFlutterBrowserId];
        CefOsrTexture* texture =
            [[CefOsrTexture alloc] initWithRegistry:_textureRegistry backend:backend];
        int64_t textureId = [_textureRegistry registerTexture:texture];
        if (textureId == 0) {
            result([FlutterError errorWithCode:@"TEXTURE_REGISTRATION_FAILED"
                                       message:@"Failed to register DevTools texture"
                                       details:nil]);
            return;
        }
        [texture setTextureId:textureId];
        NSNumber* devToolsNum = @(devToolsBrowserId);
        _osrTexturesByBrowserId[devToolsNum] = texture;
        _osrTextureIdsByBrowserId[devToolsNum] = @(textureId);

        // Zero-sized until the pane's first frame sync so it can never sit
        // in the window's hit-test path over live UI.
        NSView* containerView = [[CefOsrContainerView alloc] initWithFrame:NSZeroRect];
        containerView.autoresizingMask = NSViewNotSizable;
        containerView.translatesAutoresizingMaskIntoConstraints = YES;
        containerView.wantsLayer = YES;
        containerView.layer.masksToBounds = YES;
        containerView.identifier = @"cef_devtools_container";
        containerView.layer.backgroundColor = NSColor.clearColor.CGColor;
        containerView.hidden = NO;
        containerView.layer.opacity = 0.0;
        [_flutterView addSubview:containerView positioned:NSWindowBelow relativeTo:nil];

        _browserViews[devToolsBrowserId] = containerView;
        _browserHostViews[devToolsBrowserId] = _flutterView;
        _renderBackendsByBrowserId[devToolsBrowserId] = backend;
        [_ownedBrowserIds addObject:devToolsNum];

        const int inspectX = args[@"inspectX"] != nil && args[@"inspectX"] != [NSNull null]
            ? (int)IntegerOrDefault(args[@"inspectX"], -1) : -1;
        const int inspectY = args[@"inspectY"] != nil && args[@"inspectY"] != [NSNull null]
            ? (int)IntegerOrDefault(args[@"inspectY"], -1) : -1;
        const BOOL ok = [[CEFBridge sharedInstance]
            openWindowlessDevToolsForBrowserId:browserId
                             devToolsBrowserId:devToolsBrowserId
                                    parentView:containerView
                                         frame:NSMakeRect(0, 0, 800, 600)
                                 renderBackend:backend
                                      inspectX:inspectX
                                      inspectY:inspectY];
        if (!ok) {
            [containerView removeFromSuperview];
            _browserViews.erase(devToolsBrowserId);
            _browserHostViews.erase(devToolsBrowserId);
            _renderBackendsByBrowserId.erase(devToolsBrowserId);
            [_ownedBrowserIds removeObject:devToolsNum];
            [self releaseOsrTextureForBrowserNumber:devToolsNum];
            result([FlutterError errorWithCode:@"DEVTOOLS_OPEN_FAILED"
                                       message:@"Windowless DevTools creation failed"
                                       details:nil]);
            return;
        }
        result(@{
            @"devToolsBrowserId": devToolsNum,
            @"textureId": @(textureId),
            @"renderBackend": backend,
        });
    }
    else if ([@"closeDevTools" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        if ([self isOsrBrowserId:browserId]) {
            [[CEFBridge sharedInstance] closeWindowlessDevToolsForBrowserId:browserId];
        } else {
            [[CEFBridge sharedInstance] hideDevTools:browserId];
        }
        result(nil);
    }
    else if ([@"showDevTools" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        BOOL docked = args[@"docked"] ? [args[@"docked"] boolValue] : YES;
        NSString* position = args[@"position"] ?: @"bottom";
        [[CEFBridge sharedInstance] showDevTools:browserId docked:docked position:position];
        result(nil);
    }
    else if ([@"hideDevTools" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] hideDevTools:browserId];
        result(nil);
    }
    else if ([@"setColorScheme" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        id schemeObj = args[@"scheme"];
        NSString* scheme = (schemeObj && schemeObj != [NSNull null] && [schemeObj isKindOfClass:[NSString class]])
            ? (NSString*)schemeObj
            : nil;
        [[CEFBridge sharedInstance] setPreferredColorScheme:browserId scheme:scheme];
        result(nil);
    }
    else if ([@"enableNetworkLogging" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] enableNetworkLogging:browserId];
        result(nil);
    }
    else if ([@"enableConsoleLogging" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] enableConsoleLogging:browserId];
        result(nil);
    }
    else if ([@"getResponseBody" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* requestId = args[@"requestId"];
        [[CEFBridge sharedInstance] getResponseBody:browserId requestId:requestId completion:^(NSString* body, BOOL base64Encoded) {
            result(@{
                @"body": body ?: @"",
                @"base64Encoded": @(base64Encoded)
            });
        }];
    }
    else if ([@"clearCookies" isEqualToString:call.method]) {
        BOOL incognito = args[@"incognito"] ? [args[@"incognito"] boolValue] : NO;
        [[CEFBridge sharedInstance] clearCookies:incognito];
        result(nil);
    }
    else if ([@"getCookies" isEqualToString:call.method]) {
        NSString* url = args[@"url"];
        BOOL incognito = args[@"incognito"] ? [args[@"incognito"] boolValue] : NO;
        [[CEFBridge sharedInstance] getCookiesForUrl:url incognito:incognito completion:^(NSArray<NSDictionary*>* cookies) {
            result(cookies);
        }];
    }
    else if ([@"pauseDownload" isEqualToString:call.method]) {
        uint32_t downloadId = [args[@"downloadId"] unsignedIntValue];
        [[CEFBridge sharedInstance] pauseDownload:downloadId];
        result(nil);
    }
    else if ([@"resumeDownload" isEqualToString:call.method]) {
        uint32_t downloadId = [args[@"downloadId"] unsignedIntValue];
        [[CEFBridge sharedInstance] resumeDownload:downloadId];
        result(nil);
    }
    else if ([@"cancelDownload" isEqualToString:call.method]) {
        uint32_t downloadId = [args[@"downloadId"] unsignedIntValue];
        [[CEFBridge sharedInstance] cancelDownload:downloadId];
        result(nil);
    }
    else if ([@"print" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        [[CEFBridge sharedInstance] print:browserId];
        result(nil);
    }
    else if ([@"printToPdf" isEqualToString:call.method]) {
        int browserId = GetBrowserId(args);
        NSString* path = args[@"path"];
        [[CEFBridge sharedInstance] printToPdf:browserId path:path completion:^(BOOL success) {
            result(@(success));
        }];
    }
    else if ([@"provideAuthCredentials" isEqualToString:call.method]) {
        NSString* username = args[@"username"];
        NSString* password = args[@"password"];
        [[CEFBridge sharedInstance] provideAuthCredentials:username password:password];
        result(nil);
    }
    else if ([@"cancelAuth" isEqualToString:call.method]) {
        [[CEFBridge sharedInstance] cancelAuth];
        result(nil);
    }
    else if ([@"setViewFrame" isEqualToString:call.method] ||
             [@"setBrowserFrame" isEqualToString:call.method]) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleMethodCall:call result:result];
            });
            return;
        }

        int browserId = GetBrowserId(args);
        double x = [args[@"x"] doubleValue];
	        double y = [args[@"y"] doubleValue];
	        double width = [args[@"width"] doubleValue];
	        double height = [args[@"height"] doubleValue];
	        const double deviceScaleFactor = [args[@"deviceScaleFactor"] doubleValue];

        if (!isfinite(x) || !isfinite(y) ||
            !isfinite(width) || !isfinite(height) ||
            width < 1.0 || height < 1.0) {
            if (ShouldLogFrameSync()) {
                NSLog(@"FlutterCefBrowserPlugin: skip invalid setViewFrame id=%d "
              @"input=(%.2f,%.2f %.2fx%.2f)",
                      browserId,
                      x,
                      y,
                      width,
                      height);
            }
            result(nil);
            return;
        }

		        auto it = _browserViews.find(browserId);
	        if (it != _browserViews.end() && it->second) {
	            auto hostIt = _browserHostViews.find(browserId);
	            NSView* ownerHostView =
	                (hostIt != _browserHostViews.end()) ? hostIt->second : nil;
                if ([self isOsrBrowserId:browserId]) {
                    NSView* sourceView = ownerHostView ?: _flutterView;
                    const double viewHeight = [args[@"viewHeight"] doubleValue];
                    NSRect frame = sourceView
                        ? ConvertFlutterRectToHostRect(
                              sourceView,
                              sourceView,
                              NSMakeRect(x, y, width, height),
                              viewHeight)
                        : NSMakeRect(x, y, width, height);
	                    _lastRequestedFrames[browserId] = frame;
	                    CefOsrTexture* texture =
	                        _osrTexturesByBrowserId[@(browserId)];
	                    [texture setRequestedViewWidth:
	                                 (int)ceil(MAX(1.0, frame.size.width))
	                                             height:
	                                 (int)ceil(MAX(1.0, frame.size.height))
	                                     effectiveScale:
	                                 EffectiveOsrTextureScale(
	                                     deviceScaleFactor, sourceView)];
	                    [self recordSetViewFrameMetric];
	                    [[CEFBridge sharedInstance] setViewFrame:browserId
	                                                       frame:frame
	                                           deviceScaleFactor:deviceScaleFactor];
	                    result(nil);
	                    return;
                }
	            if (!ownerHostView || !ownerHostView.window) {
	                result(nil);
	                return;
	            }
                NSView* containerView = it->second;
	            NSView* flutterView = ownerHostView;
	            _flutterView = ownerHostView;
	            [self startTrackingWindowEventsIfNeeded];

	            NSView* hostView = ownerHostView;
	            if (containerView.superview && containerView.superview != ownerHostView) {
	                [containerView removeFromSuperviewWithoutNeedingDisplay];
	            }
	            NSView* sourceView = flutterView;
	            const double viewHeight = [args[@"viewHeight"] doubleValue];
	            NSRect frame = ConvertFlutterRectToHostRect(
	                sourceView,
	                hostView,
	                NSMakeRect(x, y, width, height),
	                viewHeight);
            if (ShouldLogFrameSync()) {
                NSLog(@"FlutterCefBrowserPlugin: setViewFrame id=%d input=(%.2f,%.2f "
              @"%.2fx%.2f) viewHeight=%.2f flutterView.bounds=%@ hostView=%@ "
              @"converted=%@",
                      browserId, x, y, width, height,
                      viewHeight,
                      sourceView ? NSStringFromRect(sourceView.bounds) : @"(null)",
	                      hostView,
	                      NSStringFromRect(frame));
            }
            auto previousFrameIt = _lastRequestedFrames.find(browserId);
            const BOOL frameChanged =
                previousFrameIt == _lastRequestedFrames.end() ||
                !RectsApproximatelyEqual(previousFrameIt->second, frame);
            const BOOL needsAttach = containerView.superview == nil;
            const BOOL needsContainerFrame =
                !RectsApproximatelyEqual(containerView.frame, frame);
			            _lastRequestedFrames[browserId] = frame;
            if (!frameChanged && !needsAttach && !needsContainerFrame) {
                result(nil);
                return;
            }
	                RunWithoutImplicitLayerActions(^{
		            containerView.autoresizingMask = NSViewNotSizable;
		            containerView.translatesAutoresizingMaskIntoConstraints = YES;
		            [containerView setFrame:frame];
		            if (containerView.wantsLayer) {
		                containerView.layer.masksToBounds = YES;
		            }
                });
                    if ([self currentWindowCanPresentBrowserViews] &&
                        ownerHostView.window == [self trackedPresentationWindow] &&
                        needsAttach) {
                        [self promoteBrowserContainerToFrontIfNeeded:containerView hostView:hostView];
                    }
            [self recordSetViewFrameMetric];
	            [[CEFBridge sharedInstance] setViewFrame:browserId
	                                               frame:frame
	                                   deviceScaleFactor:deviceScaleFactor];
            // Routine frame updates apply immediately. Keep trailing native
            // reapply reserved for create/onCreated and explicit drift/recovery paths.
            result(nil);
            return;
        }
        result(nil);
    }
    else {
        result(FlutterMethodNotImplemented);
    }
}

#pragma mark - FlutterStreamHandler

- (FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    NSString* streamKey = EventStreamKeyFromArguments(arguments);
    if ([streamKey isEqualToString:@"browser_events"]) {
        _browserEventSink = events;
        return nil;
    }
    if ([streamKey isEqualToString:@"downloads"]) {
        _downloadEventSink = events;
        return nil;
    }
    if ([streamKey isEqualToString:@"console"]) {
        _consoleEventSink = events;
        return nil;
    }
    if ([streamKey isEqualToString:@"network"]) {
        _networkEventSink = events;
        return nil;
    }

    // Backward-compatible fallback for clients that did not pass a stream key.
    if (!_browserEventSink) {
        _browserEventSink = events;
    } else if (!_downloadEventSink) {
        _downloadEventSink = events;
    } else if (!_consoleEventSink) {
        _consoleEventSink = events;
    } else {
        _networkEventSink = events;
    }
    return nil;
}

- (FlutterError*)onCancelWithArguments:(id)arguments {
    NSString* streamKey = EventStreamKeyFromArguments(arguments);
    if ([streamKey isEqualToString:@"browser_events"]) {
        _browserEventSink = nil;
        return nil;
    }
    if ([streamKey isEqualToString:@"downloads"]) {
        _downloadEventSink = nil;
        return nil;
    }
    if ([streamKey isEqualToString:@"console"]) {
        _consoleEventSink = nil;
        return nil;
    }
    if ([streamKey isEqualToString:@"network"]) {
        _networkEventSink = nil;
        return nil;
    }

    // Backward-compatible fallback.
    _browserEventSink = nil;
    _downloadEventSink = nil;
    _consoleEventSink = nil;
    _networkEventSink = nil;
    return nil;
}

#pragma mark - CEFBridgeDelegate

- (void)onBrowserCreated:(int)browserId {
    NSNumber* browserNum = @(browserId);
    if (![_ownedBrowserIds containsObject:browserNum]) return;
    if (![self isOwnedBrowserCurrentForBrowserId:browserId token:nil]) {
        if (ShouldLogReliabilityDebug()) {
            NSLog(@"FlutterCefBrowserPlugin: ignoring stale browserCreated "
            @"browserId=%d", browserId);
        }
        [[CEFBridge sharedInstance] setFocus:browserId focused:NO];
        [[CEFBridge sharedInstance] setVisible:browserId visible:NO];
        return;
    }
    NSDate* startedAt = _createStartedAtByBrowserId[browserNum];
    if (ShouldLogReliabilityDebug() && startedAt) {
        NSLog(@"FlutterCefBrowserPlugin: browserCreated browserId=%d "
          @"createLatencyMs=%.1f requestId=%@",
              browserId,
              [[NSDate date] timeIntervalSinceDate:startedAt] * 1000.0,
	              _createRequestIdsByBrowserId[browserNum] ?: @"<none>");
    }
    [_createStartedAtByBrowserId removeObjectForKey:browserNum];
    // The browser child view may attach after the last Dart-side frame/visible
    // update. Replaying presentation here closes that race.
    if (![self isOsrBrowserId:browserId]) {
        [self reapplyBrowserPresentationForBrowserId:browserId reason:@"onBrowserCreated"];
        [self scheduleNativeFrameReapply:@"onBrowserCreated"];
    }
    if (_browserEventSink) {
        NSMutableDictionary* payload = [@{
            @"type": @"browserCreated",
            @"browserId": @(browserId)
        } mutableCopy];
        NSString* createRequestId = _createRequestIdsByBrowserId[browserNum];
        if (createRequestId.length > 0) {
            payload[@"createRequestId"] = createRequestId;
        }
        _browserEventSink(payload);
    }
}

- (void)onBrowserClosed:(int)browserId {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;

    // Ensure native view cleanup if the browser closed without an explicit closeBrowser call.
    auto it = _browserViews.find(browserId);
    if (it != _browserViews.end() && it->second) {
        [it->second removeFromSuperview];
        _browserViews.erase(it);
	    }
	    _lastRequestedFrames.erase(browserId);
        _browserHostViews.erase(browserId);
	    NSNumber* browserNum = @(browserId);
    [_ownedBrowserIds removeObject:browserNum];
    [self markBrowserNumber:browserNum focused:NO];
    [_programmaticBrowserCloseIds removeObject:browserNum];
    [_createRequestIdsByBrowserId removeObjectForKey:browserNum];
    [_createStartedAtByBrowserId removeObjectForKey:browserNum];
    [_browserLifecycleTokensByBrowserId removeObjectForKey:browserNum];
    [_requestedVisibilityByBrowserId removeObjectForKey:browserNum];
    [_appliedVisibilityByBrowserId removeObjectForKey:browserNum];
    _renderBackendsByBrowserId.erase(browserId);
    [self releaseOsrTextureForBrowserNumber:browserNum];
    [self markWindowCloseTransactionBrowserClosed:browserId];

    if (_windowCloseRequested && _ownedBrowserIds.count == 0) {
        NSString* transactionId = [_windowCloseTransaction[@"transactionId"] isKindOfClass:[NSString class]]
            ? (NSString*)_windowCloseTransaction[@"transactionId"]
            : @"";
        NSDictionary* completionDetails = @{
            @"transactionId": transactionId,
            @"phase": @"completed",
        };
        [self emitLifecycleDiagnostic:@"cef_window_close_transaction_completed"
                            browserId:nil
                              details:completionDetails];
        NSWindow* window = _trackedWindow ?: (_flutterView ? _flutterView.window : nil);
        if (window != nil) {
            [self finishWindowCloseForWindow:window
                                       phase:@"completed"
                               transactionId:transactionId
                                     details:completionDetails];
        } else {
            if (_windowCloseRetryTimer) {
                [_windowCloseRetryTimer invalidate];
                _windowCloseRetryTimer = nil;
            }
            _windowCloseTransaction = nil;
            _windowCloseRequested = NO;
        }
    }

    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"browserClosed",
            @"browserId": @(browserId)
        });
    }
}

- (void)onLifecycleDiagnostic:(NSDictionary *)diagnostic {
    if (![diagnostic isKindOfClass:[NSDictionary class]]) return;
    NSString* type = [diagnostic[@"type"] isKindOfClass:[NSString class]]
        ? (NSString*)diagnostic[@"type"]
        : nil;
    if (type.length == 0) return;
    [self emitLifecycleDiagnostic:type
                        browserId:[diagnostic[@"browserId"] isKindOfClass:[NSNumber class]]
                            ? (NSNumber*)diagnostic[@"browserId"]
                            : nil
                          details:diagnostic];
}

- (void)onOsrPaintForBrowserId:(int)browserId
                           type:(int)type
                         buffer:(const void *)buffer
                          width:(int)width
                         height:(int)height
                     dirtyRect:(CGRect)dirtyRect {
    if (![self isOsrBrowserId:browserId]) {
        return;
    }
    CefOsrTexture* texture = _osrTexturesByBrowserId[@(browserId)];
    if (!texture) {
        return;
    }
    if (type == kCefPaintElementPopup) {
        if (ShouldLogPopupDebug()) {
            NSLog(@"FlutterCefBrowserPlugin: PET_POPUP OnPaint browserId=%d "
            @"size=%dx%d dirtyRect=%@",
                  browserId, width, height, NSStringFromRect(dirtyRect));
        }
        [texture updatePopupBGRAWithBuffer:buffer width:width height:height];
        return;
    }
    const NSUInteger previousCount = [texture updateCount];
    [texture updateBGRAWithBuffer:buffer width:width height:height dirtyRect:dirtyRect];
    const NSUInteger nextCount = [texture updateCount];
    if (previousCount == 0 || nextCount <= 3 || nextCount == 10 || nextCount == 30 || nextCount == 60) {
        NSNumber* textureId = _osrTextureIdsByBrowserId[@(browserId)];
        NSLog(@"FlutterCefBrowserPlugin: onOsrPaint browserId=%d textureId=%@ "
          @"type=%d size=%dx%d count=%lu",
              browserId,
              textureId ?: @0,
              type,
              width,
              height,
              (unsigned long)nextCount);
    }
}

- (void)onAcceleratedOsrPaintForBrowserId:(int)browserId
                                      type:(int)type
                                 ioSurface:(void *)ioSurface
                                    format:(int)format
                                dirtyRect:(CGRect)dirtyRect
                                     extra:(NSDictionary *)extra {
    auto backendIt = _renderBackendsByBrowserId.find(browserId);
    if (backendIt == _renderBackendsByBrowserId.end() ||
        ![backendIt->second isEqualToString:@"acceleratedOsrTexture"]) {
        return;
    }

    CefOsrTexture* texture = _osrTexturesByBrowserId[@(browserId)];
    if (!texture) return;

    if (type == kCefPaintElementPopup) {
        if (ShouldLogPopupDebug()) {
            IOSurfaceRef surface = (IOSurfaceRef)ioSurface;
            NSLog(@"FlutterCefBrowserPlugin: PET_POPUP OnAcceleratedPaint "
            @"browserId=%d size=%zux%zu format=%d dirtyRect=%@",
                  browserId,
                  surface ? IOSurfaceGetWidth(surface) : 0,
                  surface ? IOSurfaceGetHeight(surface) : 0,
                  format,
                  NSStringFromRect(dirtyRect));
        }
        [texture updatePopupWithIOSurface:(IOSurfaceRef)ioSurface format:format];
        return;
    }
    [texture updateWithIOSurface:(IOSurfaceRef)ioSurface
                          format:format
                       dirtyRect:dirtyRect
                           extra:extra];
}

- (BOOL)onLeasedAcceleratedOsrFrameForBrowserId:(int)browserId
                                           type:(int)type
                                      ioSurface:(void *)ioSurface
                                         format:(int)format
                                      dirtyRect:(CGRect)dirtyRect
                                          extra:(NSDictionary *)extra
                                          lease:(CEFAcceleratedFrameLease *)
                                                    lease {
  auto backendIt = _renderBackendsByBrowserId.find(browserId);
  if (type != kCefPaintElementView ||
      backendIt == _renderBackendsByBrowserId.end() ||
      ![backendIt->second isEqualToString:@"acceleratedOsrTexture"]) {
    return NO;
  }
  CefOsrTexture *texture = _osrTexturesByBrowserId[@(browserId)];
  if (!texture) {
    return NO;
  }
  return [texture updateWithLeasedIOSurface:(IOSurfaceRef)ioSurface
                                     format:format
                                  dirtyRect:dirtyRect
                                      extra:extra
                                      lease:lease];
}

- (void)onDevToolsClosedForBrowserId:(int)ownerBrowserId
                   devToolsBrowserId:(int)devToolsBrowserId {
    [self emitParityEventType:@"devToolsClosed"
                    browserId:ownerBrowserId
                      payload:@{@"devToolsBrowserId": @(devToolsBrowserId)}];
}

- (void)onInspectElementRequestedForBrowserId:(int)browserId x:(int)x y:(int)y {
    [self emitParityEventType:@"inspectElementRequested"
                    browserId:browserId
                      payload:@{@"x": @(x), @"y": @(y)}];
}

- (void)onContextMenuForBrowserId:(int)browserId
                           menuId:(int)menuId
                                 x:(int)x
                                 y:(int)y
                             items:(NSArray<NSDictionary<NSString*, id>*>*)items {
    [self emitParityEventType:@"contextMenu"
                    browserId:browserId
                      payload:@{
                          @"menuId": @(menuId),
                          @"x": @(x),
                          @"y": @(y),
                          @"items": items ?: @[],
                      }];
}

- (void)onTooltipForBrowserId:(int)browserId text:(NSString*)text {
    [self emitParityEventType:@"tooltip"
                    browserId:browserId
                      payload:@{@"text": text ?: @""}];
}

- (void)onJsDialogForBrowserId:(int)browserId
                    callbackId:(int)callbackId
                           kind:(NSString*)kind
                        message:(NSString*)message
                  defaultPrompt:(NSString*)defaultPrompt {
    [self emitParityEventType:@"jsDialog"
                    browserId:browserId
                      payload:@{
                          @"callbackId": @(callbackId),
                          @"kind": kind ?: @"alert",
                          @"message": message ?: @"",
                          @"defaultPrompt": defaultPrompt ?: @"",
                      }];
}

- (void)onPermissionPromptForBrowserId:(int)browserId
                              promptId:(NSString*)promptId
                                 origin:(NSString*)origin
                            permissions:(NSArray<NSString*>*)permissions {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    [self emitParityEventType:@"sitePermissionRequest"
                    browserId:browserId
                      payload:@{
                          @"promptId": promptId ?: @"",
                          @"origin": origin ?: @"",
                          @"permissions": permissions ?: @[],
                      }];
}

- (void)onFullscreenModeChangeForBrowserId:(int)browserId
                                  fullscreen:(BOOL)fullscreen {
    [self emitParityEventType:@"fullscreenModeChange"
                    browserId:browserId
                      payload:@{@"fullscreen": @(fullscreen)}];
}

- (void)onImeCompositionRangeChangedForBrowserId:(int)browserId
                                         caretRect:(CGRect)caretRect {
    [self emitParityEventType:@"imeCompositionRangeChanged"
                    browserId:browserId
                      payload:@{
                          @"caretX": @(caretRect.origin.x),
                          @"caretY": @(caretRect.origin.y),
                          @"caretW": @(caretRect.size.width),
                          @"caretH": @(caretRect.size.height),
                      }];
}

- (void)onTextInputStateChangedForBrowserId:(int)browserId
                                    editable:(BOOL)editable {
    [self emitParityEventType:@"textInputStateChanged"
                    browserId:browserId
                      payload:@{@"editable": @(editable)}];
}

- (void)onOsrPopupShowForBrowserId:(int)browserId show:(BOOL)show {
    if (![self isOsrBrowserId:browserId]) return;
    [_osrTexturesByBrowserId[@(browserId)] setPopupVisible:show];
}

- (void)onOsrPopupSizeForBrowserId:(int)browserId rect:(CGRect)rect {
    if (![self isOsrBrowserId:browserId]) return;
    [_osrTexturesByBrowserId[@(browserId)] setPopupRectDips:rect];
}

// Single dispatch point for browser-parity events (tooltips, JS dialogs,
// fullscreen, IME geometry, DevTools lifecycle, drag notifications). Type
// names must match CefParityEventType on the Dart side.
- (void)emitParityEventType:(NSString*)type
                  browserId:(int)browserId
                    payload:(NSDictionary<NSString*, id>* _Nullable)payload {
    if (![NSThread isMainThread]) {
        __weak FlutterCefBrowserPlugin* weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf emitParityEventType:type browserId:browserId payload:payload];
        });
        return;
    }
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (!_browserEventSink) return;

    NSMutableDictionary<NSString*, id>* event =
        [NSMutableDictionary dictionaryWithDictionary:payload ?: @{}];
    event[@"type"] = type;
    event[@"browserId"] = @(browserId);
    _browserEventSink(event);
}

- (void)onTitleChanged:(int)browserId title:(NSString *)title {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"titleChanged",
            @"browserId": @(browserId),
            @"title": title ?: @""
        });
    }
}

- (void)onUrlChanged:(int)browserId url:(NSString *)url {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"urlChanged",
            @"browserId": @(browserId),
            @"url": url ?: @""
        });
    }
}

- (void)onLoadEnd:(int)browserId url:(NSString *)url {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"loadEnd",
            @"browserId": @(browserId),
            @"url": url ?: @""
        });
    }
}

- (void)onStatusMessage:(int)browserId text:(NSString *)text {
    [self emitParityEventType:@"statusMessage"
                    browserId:browserId
                      payload:@{@"text": text ?: @""}];
}

- (void)onAudioStateChanged:(int)browserId audible:(BOOL)audible {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"audioStateChanged",
            @"browserId": @(browserId),
            @"audible": @(audible)
        });
    }
}

- (void)onZoomChanged:(int)browserId level:(double)level reset:(BOOL)reset {
    [self emitParityEventType:@"zoomChanged"
                    browserId:browserId
                      payload:@{
                          @"level": @(level),
                          @"reset": @(reset),
                      }];
}

- (void)onLoadingStateChanged:(int)browserId
                    isLoading:(BOOL)isLoading
                    canGoBack:(BOOL)canGoBack
                 canGoForward:(BOOL)canGoForward {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"loadingStateChanged",
            @"browserId": @(browserId),
            @"isLoading": @(isLoading),
            @"canGoBack": @(canGoBack),
            @"canGoForward": @(canGoForward)
        });
    }
}

- (void)onFindResult:(int)browserId
          identifier:(int)identifier
               count:(int)count
  activeMatchOrdinal:(int)activeMatchOrdinal
         finalUpdate:(BOOL)finalUpdate {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"findResult",
            @"browserId": @(browserId),
            @"identifier": @(identifier),
            @"count": @(count),
            @"activeMatchOrdinal": @(activeMatchOrdinal),
            @"finalUpdate": @(finalUpdate)
        });
    }
}

- (void)onSwipeNavigationForBrowserId:(int)browserId
                            direction:(NSString *)direction
                             progress:(double)progress
                                phase:(NSString *)phase
                            committed:(BOOL)committed {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"swipeNavigation",
            @"browserId": @(browserId),
            @"direction": direction ?: @"back",
            @"progress": @(progress),
            @"phase": phase ?: @"updated",
            @"committed": @(committed)
        });
    }
}

- (void)onLoadError:(int)browserId
          errorCode:(int)errorCode
          errorText:(NSString *)errorText
                url:(NSString *)url {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"loadError",
            @"browserId": @(browserId),
            @"errorCode": @(errorCode),
            @"errorText": errorText ?: @"",
            @"url": url ?: @""
        });
    }
}

- (void)onLoadProgress:(int)browserId progress:(double)progress {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"loadProgress",
            @"browserId": @(browserId),
            @"progress": @(progress)
        });
    }
}

- (void)onPopupRequested:(int)browserId details:(NSDictionary *)details {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        NSMutableDictionary* event = details ? [details mutableCopy] : [NSMutableDictionary dictionary];
        event[@"type"] = @"popupRequested";
        event[@"browserId"] = @(browserId);
        _browserEventSink(event);
    }
}

- (void)onFaviconChanged:(int)browserId urls:(NSArray<NSString *> *)urls {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"faviconChanged",
            @"browserId": @(browserId),
            @"urls": urls ?: @[]
        });
    }
}

- (void)onDownloadStarted:(uint32_t)downloadId
                browserId:(int)browserId
                      url:(NSString *)url
                 filename:(NSString *)filename
                 mimeType:(NSString *)mimeType
               totalBytes:(int64_t)totalBytes
                  fullPath:(NSString *)fullPath {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    _downloadMetaById[@(downloadId)] = @{
        @"browserId": @(browserId),
        @"url": url ?: @"",
        @"filename": filename ?: @"",
        @"mimeType": mimeType ?: @"",
        @"totalBytes": @(totalBytes),
        @"fullPath": fullPath ?: @"",
    };
    if (_downloadEventSink) {
        _downloadEventSink(@{
            @"type": @"started",
            @"downloadId": @(downloadId),
            @"browserId": @(browserId),
            @"url": url ?: @"",
            @"filename": filename ?: @"",
            @"mimeType": mimeType ?: @"",
            @"totalBytes": @(totalBytes),
            @"receivedBytes": @(0),
            @"percentComplete": @(0),
            @"speed": @(0),
            @"fullPath": fullPath ?: @"",
        });
    }
}

- (void)onDownloadProgress:(uint32_t)downloadId
             receivedBytes:(int64_t)receivedBytes
                totalBytes:(int64_t)totalBytes
                     speed:(int64_t)speed
           percentComplete:(int)percent {
    if (_downloadEventSink) {
        NSDictionary* meta = _downloadMetaById[@(downloadId)];
        if (!meta) return;
        NSNumber* browserId = meta[@"browserId"] ?: @(0);
        NSString* url = meta[@"url"] ?: @"";
        NSString* filename = meta[@"filename"] ?: @"";
        NSString* mimeType = meta[@"mimeType"] ?: @"";
        NSString* fullPath = meta[@"fullPath"] ?: @"";
        _downloadEventSink(@{
            @"type": @"progress",
            @"downloadId": @(downloadId),
            @"browserId": browserId,
            @"url": url,
            @"filename": filename,
            @"mimeType": mimeType,
            @"receivedBytes": @(receivedBytes),
            @"totalBytes": @(totalBytes),
            @"speed": @(speed),
            @"percentComplete": @(percent),
            @"fullPath": fullPath,
        });
    }
}

- (void)onDownloadComplete:(uint32_t)downloadId path:(NSString *)path {
    if (_downloadEventSink) {
        NSDictionary* meta = _downloadMetaById[@(downloadId)];
        if (!meta) return;
        NSNumber* browserId = meta[@"browserId"] ?: @(0);
        NSString* url = meta[@"url"] ?: @"";
        NSString* filename = meta[@"filename"] ?: @"";
        NSString* mimeType = meta[@"mimeType"] ?: @"";
        NSNumber* totalBytes = meta[@"totalBytes"] ?: @(0);
        _downloadEventSink(@{
            @"type": @"completed",
            @"downloadId": @(downloadId),
            @"browserId": browserId,
            @"url": url,
            @"filename": filename,
            @"mimeType": mimeType,
            @"totalBytes": totalBytes,
            @"receivedBytes": totalBytes,
            @"percentComplete": @(100),
            @"speed": @(0),
            @"fullPath": path ?: @"",
        });
        [_downloadMetaById removeObjectForKey:@(downloadId)];
    }
}

- (void)onDownloadCancelled:(uint32_t)downloadId {
    if (_downloadEventSink) {
        NSDictionary* meta = _downloadMetaById[@(downloadId)];
        if (!meta) return;
        NSNumber* browserId = meta[@"browserId"] ?: @(0);
        NSString* url = meta[@"url"] ?: @"";
        NSString* filename = meta[@"filename"] ?: @"";
        NSString* mimeType = meta[@"mimeType"] ?: @"";
        NSNumber* totalBytes = meta[@"totalBytes"] ?: @(0);
        NSString* fullPath = meta[@"fullPath"] ?: @"";
        _downloadEventSink(@{
            @"type": @"cancelled",
            @"downloadId": @(downloadId),
            @"browserId": browserId,
            @"url": url,
            @"filename": filename,
            @"mimeType": mimeType,
            @"totalBytes": totalBytes,
            @"receivedBytes": @(0),
            @"percentComplete": @(0),
            @"speed": @(0),
            @"fullPath": fullPath,
        });
        [_downloadMetaById removeObjectForKey:@(downloadId)];
    }
}

- (void)onDownloadFailed:(uint32_t)downloadId errorMessage:(NSString *)error {
    if (_downloadEventSink) {
        NSDictionary* meta = _downloadMetaById[@(downloadId)];
        if (!meta) return;
        NSNumber* browserId = meta[@"browserId"] ?: @(0);
        NSString* url = meta[@"url"] ?: @"";
        NSString* filename = meta[@"filename"] ?: @"";
        NSString* mimeType = meta[@"mimeType"] ?: @"";
        NSNumber* totalBytes = meta[@"totalBytes"] ?: @(0);
        NSString* fullPath = meta[@"fullPath"] ?: @"";
        _downloadEventSink(@{
            @"type": @"failed",
            @"downloadId": @(downloadId),
            @"browserId": browserId,
            @"url": url,
            @"filename": filename,
            @"mimeType": mimeType,
            @"totalBytes": totalBytes,
            @"receivedBytes": @(0),
            @"percentComplete": @(0),
            @"speed": @(0),
            @"fullPath": fullPath,
            @"errorMessage": error ?: @""
        });
        [_downloadMetaById removeObjectForKey:@(downloadId)];
    }
}

- (void)onConsoleMessage:(int)browserId
                   level:(int)level
                 message:(NSString *)message
                  source:(NSString *)source
                    line:(int)line {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_consoleEventSink) {
        NSString* levelStr = ConsoleLevelToString(level);
        double ts = [[NSDate date] timeIntervalSince1970];
        _consoleEventSink(@{
            @"browserId": @(browserId),
            @"level": levelStr,
            @"message": message ?: @"",
            @"source": source ?: @"",
            @"line": @(line),
            @"timestamp": @(ts),
        });
    }
}

- (void)onNetworkEvent:(int)browserId data:(NSDictionary *)data {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_networkEventSink) {
        NSMutableDictionary* eventData = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
        eventData[@"browserId"] = @(browserId);
        _networkEventSink(eventData);
    }
}

- (void)onAuthRequired:(int)browserId
               isProxy:(BOOL)isProxy
                  host:(NSString *)host
                 realm:(NSString *)realm {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"authRequired",
            @"browserId": @(browserId),
            @"isProxy": @(isProxy),
            @"host": host ?: @"",
            @"realm": realm ?: @""
        });
    }
}

- (void)onFocusChanged:(int)browserId focused:(BOOL)focused {
    if (![_ownedBrowserIds containsObject:@(browserId)]) return;
    NSNumber* browserNum = @(browserId);
    [self markBrowserNumber:browserNum focused:focused];
    if (_browserEventSink) {
        _browserEventSink(@{
            @"type": @"focusChanged",
            @"browserId": @(browserId),
            @"focused": @(focused)
        });
    }
}

@end
