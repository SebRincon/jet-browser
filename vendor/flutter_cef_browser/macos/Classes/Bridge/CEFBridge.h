//
//  CEFBridge.h
//  flutter_cef_browser
//
//  Objective-C interface for CEF functionality
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Opaque, idempotent ownership token for one CEF accelerated OSR frame.
///
/// The frame's IOSurface remains valid until this object is released or
/// `releaseFrame` is called. This is populated only by the experimental custom
/// CEF frame-lease API.
@interface CEFAcceleratedFrameLease : NSObject {
 @private
  void* _state;
}
@property(nonatomic, readonly) uint64_t frameId;
- (void)releaseFrame;
@end

/// Returns whether the linked CEF headers and implementation expose the
/// experimental accelerated-frame lease contract.
FOUNDATION_EXPORT BOOL CEFAcceleratedFrameLeaseApiAvailable(void);

/// Delegate protocol for browser events
@protocol CEFBridgeDelegate <NSObject>

// Browser lifecycle
- (void)onBrowserCreated:(int)browserId;
- (void)onBrowserClosed:(int)browserId;

// Navigation events
- (void)onTitleChanged:(int)browserId title:(NSString *)title;
- (void)onUrlChanged:(int)browserId url:(NSString *)url;
- (void)onLoadEnd:(int)browserId url:(NSString *)url;
- (void)onStatusMessage:(int)browserId text:(NSString *)text;
- (void)onAudioStateChanged:(int)browserId audible:(BOOL)audible;
- (void)onZoomChanged:(int)browserId level:(double)level reset:(BOOL)reset;
- (void)onLoadingStateChanged:(int)browserId
                    isLoading:(BOOL)isLoading
                    canGoBack:(BOOL)canGoBack
                 canGoForward:(BOOL)canGoForward;
- (void)onLoadError:(int)browserId
          errorCode:(int)errorCode
          errorText:(NSString *)errorText
                url:(NSString *)url;
- (void)onLoadProgress:(int)browserId progress:(double)progress;
- (void)onFindResult:(int)browserId
          identifier:(int)identifier
               count:(int)count
  activeMatchOrdinal:(int)activeMatchOrdinal
         finalUpdate:(BOOL)finalUpdate;

// Popup handling
- (void)onPopupRequested:(int)browserId details:(NSDictionary *)details;

// Favicon
- (void)onFaviconChanged:(int)browserId urls:(NSArray<NSString *> *)urls;

// Download events
- (void)onDownloadStarted:(uint32_t)downloadId
                browserId:(int)browserId
                      url:(NSString *)url
                 filename:(NSString *)filename
                 mimeType:(NSString *)mimeType
               totalBytes:(int64_t)totalBytes
                  fullPath:(NSString *)fullPath;

- (void)onDownloadProgress:(uint32_t)downloadId
             receivedBytes:(int64_t)receivedBytes
                totalBytes:(int64_t)totalBytes
                     speed:(int64_t)speed
           percentComplete:(int)percent;

- (void)onDownloadComplete:(uint32_t)downloadId path:(NSString *)path;
- (void)onDownloadCancelled:(uint32_t)downloadId;
- (void)onDownloadFailed:(uint32_t)downloadId errorMessage:(NSString *)error;

// Console logging
- (void)onConsoleMessage:(int)browserId
                   level:(int)level
                 message:(NSString *)message
                  source:(NSString *)source
                    line:(int)line;

// Network logging (CDP)
- (void)onNetworkEvent:(int)browserId data:(NSDictionary *)data;

// Authentication
- (void)onAuthRequired:(int)browserId
               isProxy:(BOOL)isProxy
                  host:(NSString *)host
                 realm:(NSString *)realm;

// Focus
- (void)onFocusChanged:(int)browserId focused:(BOOL)focused;

@optional
- (void)onLifecycleDiagnostic:(NSDictionary *)diagnostic;
- (void)onOsrPaintForBrowserId:(int)browserId
                           type:(int)type
                         buffer:(const void *)buffer
                          width:(int)width
                         height:(int)height
                      dirtyRect:(CGRect)dirtyRect;
- (void)onAcceleratedOsrPaintForBrowserId:(int)browserId
                                      type:(int)type
                                 ioSurface:(void *)ioSurface
                                    format:(int)format
                                 dirtyRect:(CGRect)dirtyRect
                                     extra:(NSDictionary *)extra;
- (BOOL)onLeasedAcceleratedOsrFrameForBrowserId:(int)browserId
                                            type:(int)type
                                       ioSurface:(void *)ioSurface
                                          format:(int)format
                                       dirtyRect:(CGRect)dirtyRect
                                           extra:(NSDictionary *)extra
                                           lease:(CEFAcceleratedFrameLease *)lease;
- (void)onOsrPopupShowForBrowserId:(int)browserId show:(BOOL)show;
- (void)onOsrPopupSizeForBrowserId:(int)browserId rect:(CGRect)rect;
- (void)onDevToolsClosedForBrowserId:(int)ownerBrowserId
                   devToolsBrowserId:(int)devToolsBrowserId;
- (void)onInspectElementRequestedForBrowserId:(int)browserId x:(int)x y:(int)y;
- (void)onDevToolsShortcutForBrowserId:(int)browserId;
- (void)onContextMenuForBrowserId:(int)browserId
                           menuId:(int)menuId
                                 x:(int)x
                                 y:(int)y
                             items:(NSArray<NSDictionary<NSString*, id>*>*)items;
- (void)onTooltipForBrowserId:(int)browserId text:(NSString *)text;
- (void)onJsDialogForBrowserId:(int)browserId
                    callbackId:(int)callbackId
                           kind:(NSString *)kind
                        message:(NSString *)message
                  defaultPrompt:(NSString *)defaultPrompt;
- (void)onPermissionPromptForBrowserId:(int)browserId
                              promptId:(NSString *)promptId
                                 origin:(NSString *)origin
                            permissions:(NSArray<NSString *> *)permissions;
- (void)onFullscreenModeChangeForBrowserId:(int)browserId fullscreen:(BOOL)fullscreen;
- (void)onImeCompositionRangeChangedForBrowserId:(int)browserId caretRect:(CGRect)caretRect;
- (void)onTextInputStateChangedForBrowserId:(int)browserId editable:(BOOL)editable;
- (void)onSwipeNavigationForBrowserId:(int)browserId
                            direction:(NSString *)direction
                             progress:(double)progress
                                phase:(NSString *)phase
                            committed:(BOOL)committed;

@end

/// Main CEF bridge interface
@interface CEFBridge : NSObject

/// Shared instance
+ (instancetype)sharedInstance;

/// Delegate for receiving events
@property (nonatomic, weak, nullable) id<CEFBridgeDelegate> delegate;

/// Run a side-effect-free startup preflight using the canonical runtime config.
- (NSDictionary<NSString*, id>*)runPreflightWithConfig:(NSDictionary<NSString*, id>*)config;

/// Initialize CEF using the canonical runtime config and return a structured result.
- (NSDictionary<NSString*, id>*)initializeWithConfig:(NSDictionary<NSString*, id>*)config;

/// Initialize CEF with settings
- (BOOL)initializeWithCachePath:(NSString *)cachePath
                  rootCachePath:(nullable NSString *)rootCachePath
                      userAgent:(nullable NSString *)userAgent
                  chromeRuntime:(BOOL)chromeRuntime
                 extensionPaths:(nullable NSArray<NSString *> *)extensionPaths
                     cefProfile:(nullable NSString *)cefProfile
                profileSwitches:(nullable NSDictionary<NSString *, id> *)profileSwitches
                  extraSwitches:(nullable NSDictionary<NSString *, id> *)extraSwitches
                 removeSwitches:(nullable NSArray<NSString *> *)removeSwitches
                    closePolicy:(nullable NSString *)closePolicy
         gracefulCloseTimeoutMs:(NSInteger)gracefulCloseTimeoutMs
                messagePumpMode:(nullable NSString *)messagePumpMode
                 maxPumpDelayMs:(NSInteger)maxPumpDelayMs
enableMessagePumpFallbackTimer:(BOOL)enableMessagePumpFallbackTimer;

/// Initialize CEF with deterministic browser-create mapping enabled/disabled.
- (BOOL)initializeWithCachePath:(NSString *)cachePath
                  rootCachePath:(nullable NSString *)rootCachePath
                      userAgent:(nullable NSString *)userAgent
                  chromeRuntime:(BOOL)chromeRuntime
                 extensionPaths:(nullable NSArray<NSString *> *)extensionPaths
                     cefProfile:(nullable NSString *)cefProfile
                profileSwitches:(nullable NSDictionary<NSString *, id> *)profileSwitches
                  extraSwitches:(nullable NSDictionary<NSString *, id> *)extraSwitches
                 removeSwitches:(nullable NSArray<NSString *> *)removeSwitches
                    closePolicy:(nullable NSString *)closePolicy
         gracefulCloseTimeoutMs:(NSInteger)gracefulCloseTimeoutMs
                messagePumpMode:(nullable NSString *)messagePumpMode
                 maxPumpDelayMs:(NSInteger)maxPumpDelayMs
enableMessagePumpFallbackTimer:(BOOL)enableMessagePumpFallbackTimer
      enableWindowlessRendering:(BOOL)enableWindowlessRendering
            deterministicCreate:(BOOL)deterministicCreate;

/// Shutdown CEF
- (void)shutdown;

/// Close all browsers immediately (for app quit)
- (void)closeAllBrowsersImmediately;

/// Returns true if the browser is ready to be closed (CEF close handshake completed).
- (BOOL)isBrowserReadyToBeClosed:(int)browserId;

/// Create a browser in the given parent view
- (BOOL)createBrowserWithId:(int)browserId
                        url:(NSString *)url
                 incognito:(BOOL)incognito
                 parentView:(NSView *)parentView
                      frame:(NSRect)frame;

/// Create a browser while carrying a caller-supplied create request identifier.
- (BOOL)createBrowserWithId:(int)browserId
                        url:(NSString *)url
                 incognito:(BOOL)incognito
                 parentView:(NSView *)parentView
                      frame:(NSRect)frame
            createRequestId:(nullable NSString *)createRequestId
              renderBackend:(nullable NSString *)renderBackend;

/// Create a browser with an explicit Flutter device scale factor for OSR.
- (BOOL)createBrowserWithId:(int)browserId
                        url:(NSString *)url
                 incognito:(BOOL)incognito
                 parentView:(NSView *)parentView
                      frame:(NSRect)frame
            createRequestId:(nullable NSString *)createRequestId
              renderBackend:(nullable NSString *)renderBackend
          deviceScaleFactor:(CGFloat)deviceScaleFactor;

/// Close a browser
- (void)closeBrowser:(int)browserId;

/// Close a browser, optionally forcing immediate close.
///
/// `force=YES` bypasses unload handlers (`CloseBrowser(true)`) and is safer for
/// tabbed embedded child-browser lifecycles where host-window closure must not
/// be triggered by a tab close request.
- (void)closeBrowser:(int)browserId force:(BOOL)force;

/// Close any browsers whose container view is attached to the given window.
/// Useful for multi-window teardown when Dart/Flutter channels are already gone.
- (void)closeBrowsersInWindow:(NSWindow *)window reason:(nullable NSString *)reason;

/// Get browser view for ID
- (nullable NSView *)browserViewForId:(int)browserId;

// Navigation

- (void)loadUrl:(int)browserId url:(NSString *)url;
- (void)reload:(int)browserId ignoreCache:(BOOL)ignoreCache;
- (void)stop:(int)browserId;
- (void)goBack:(int)browserId;
- (void)goForward:(int)browserId;
- (void)findInPage:(int)browserId
             query:(NSString *)query
           forward:(BOOL)forward
          findNext:(BOOL)findNext
         matchCase:(BOOL)matchCase;
- (void)stopFinding:(int)browserId clearSelection:(BOOL)clearSelection;

// JavaScript

- (void)executeJavaScript:(int)browserId
                     code:(NSString *)code
               completion:(nullable void(^)(NSError * _Nullable error))completion;

- (void)evaluateJavaScript:(int)browserId
                 expression:(NSString *)expression
                 completion:(void(^)(NSString * _Nullable result, NSError * _Nullable error))completion;

- (void)captureViewportScreenshot:(int)browserId
                           format:(NSString *)format
                          quality:(NSInteger)quality
                       completion:(void(^)(NSString * _Nullable data, NSError * _Nullable error))completion;

- (void)dispatchInput:(int)browserId
                   method:(NSString *)method
                   params:(NSDictionary *)params
               completion:(void(^)(NSError * _Nullable error))completion;

// Editing

- (BOOL)performEditCommand:(NSString *)command browserId:(int)browserId;
- (BOOL)performBrowserCommand:(NSString *)command browserId:(int)browserId;

// Focus

- (void)setFocus:(int)browserId focused:(BOOL)focused;
- (void)setVisible:(int)browserId visible:(BOOL)visible;

/// Enables or disables experimental accelerated-frame lease offers for one
/// windowless browser. Safe to call before the asynchronous CEF id is mapped.
- (void)setAcceleratedFrameLeaseEnabled:(int)browserId enabled:(BOOL)enabled;

// Off-screen rendering input
- (void)sendMouseMove:(int)browserId
                    x:(CGFloat)x
                    y:(CGFloat)y
            modifiers:(NSInteger)modifiers
           mouseLeave:(BOOL)mouseLeave;
- (void)sendMouseClick:(int)browserId
                     x:(CGFloat)x
                     y:(CGFloat)y
                button:(NSString *)button
               mouseUp:(BOOL)mouseUp
            clickCount:(NSInteger)clickCount
             modifiers:(NSInteger)modifiers;
- (void)sendMouseWheel:(int)browserId
                     x:(CGFloat)x
                     y:(CGFloat)y
                deltaX:(NSInteger)deltaX
                deltaY:(NSInteger)deltaY
             modifiers:(NSInteger)modifiers;
/// Routes AppKit's precise scroll stream directly into the OSR browser under
/// the pointer. Returns YES when Flutter must not receive the same event.
- (BOOL)handleNativeScrollWheelEvent:(NSEvent *)event;
/// Reapplies the last CEF cursor after Flutter has processed a mouse event.
- (void)applyOsrCursorForEvent:(NSEvent *)event;
- (void)pinchZoom:(int)browserId
             scale:(double)scale
                 x:(double)x
                 y:(double)y;
- (void)sendKeyEvent:(int)browserId
                type:(NSString *)type
      windowsKeyCode:(NSInteger)windowsKeyCode
       nativeKeyCode:(NSInteger)nativeKeyCode
           character:(NSInteger)character
 unmodifiedCharacter:(NSInteger)unmodifiedCharacter
           modifiers:(NSInteger)modifiers
         isSystemKey:(BOOL)isSystemKey;
- (void)imeSetComposition:(int)browserId
                     text:(NSString *)text
                 selStart:(NSInteger)selStart
                   selEnd:(NSInteger)selEnd;
- (void)imeCommitText:(int)browserId text:(NSString *)text;
- (void)imeFinishComposing:(int)browserId keepSelection:(BOOL)keepSelection;
- (void)imeCancelComposition:(int)browserId;
- (void)setZoomLevel:(int)browserId level:(double)level;
- (void)resolveJsDialog:(int)browserId
             callbackId:(int)callbackId
                 success:(BOOL)success
               userInput:(nullable NSString *)userInput;
- (void)resolvePermissionPrompt:(int)browserId
                       promptId:(NSString *)promptId
                          allow:(BOOL)allow;
- (void)resolveContextMenu:(int)browserId menuId:(int)menuId commandId:(int)commandId;
- (void)cancelContextMenu:(int)browserId menuId:(int)menuId;

// View management

- (void)setViewFrame:(int)browserId frame:(NSRect)frame;
- (void)setViewFrame:(int)browserId frame:(NSRect)frame deviceScaleFactor:(CGFloat)deviceScaleFactor;

// Frame pacing for windowless (OSR) browsers. targetFps follows the hosting
// display's refresh rate; visible=NO parks the browser via WasHidden.
- (void)setFramePacing:(int)browserId
              targetFps:(int)targetFps
                visible:(BOOL)visible
backgroundActivityExempt:(BOOL)backgroundActivityExempt;

// Parks/resumes every OSR browser when the host window becomes fully
// occluded or visible again (composes with per-browser visibility intent).
- (void)setWindowOccluded:(BOOL)occluded;

// DevTools

- (void)showDevTools:(int)browserId docked:(BOOL)docked position:(NSString *)position;
- (void)hideDevTools:(int)browserId;

// Windowless DevTools for texture (OSR) browsers (spec 016 US4).
- (int)allocateDevToolsFlutterBrowserId;
- (int)devToolsFlutterBrowserIdForOwner:(int)browserId;
- (int)devToolsOwnerForFlutterBrowserId:(int)browserId;
- (BOOL)openWindowlessDevToolsForBrowserId:(int)browserId
                         devToolsBrowserId:(int)devToolsBrowserId
                                parentView:(NSView *)parentView
                                     frame:(NSRect)frame
                             renderBackend:(NSString *)renderBackend
                                  inspectX:(int)inspectX
                                  inspectY:(int)inspectY;
- (void)closeWindowlessDevToolsForBrowserId:(int)browserId;

// Appearance
- (void)setPreferredColorScheme:(int)browserId scheme:(nullable NSString *)scheme;

// Chrome runtime / extensions
- (BOOL)shouldEnableChromeRuntime;
- (BOOL)remoteDebuggingEnabled;
- (NSArray<NSString *> *)extensionPaths;

// CDP / Logging

- (void)enableNetworkLogging:(int)browserId;
- (void)enableConsoleLogging:(int)browserId;
- (void)getResponseBody:(int)browserId
              requestId:(NSString *)requestId
             completion:(void(^)(NSString * _Nullable body, BOOL base64Encoded))completion;

// Cookies

- (void)clearCookies:(BOOL)incognito;
- (void)getCookiesForUrl:(nullable NSString *)url
             incognito:(BOOL)incognito
              completion:(void(^)(NSArray<NSDictionary *> *cookies))completion;

// Downloads

- (void)pauseDownload:(uint32_t)downloadId;
- (void)resumeDownload:(uint32_t)downloadId;
- (void)cancelDownload:(uint32_t)downloadId;

// Printing

- (void)print:(int)browserId;
- (void)printToPdf:(int)browserId
              path:(NSString *)path
        completion:(void(^)(BOOL success))completion;

// Authentication response

- (void)provideAuthCredentials:(NSString *)username password:(NSString *)password;
- (void)cancelAuth;

// Message loop

- (void)doMessageLoopWork;

@end

NS_ASSUME_NONNULL_END
