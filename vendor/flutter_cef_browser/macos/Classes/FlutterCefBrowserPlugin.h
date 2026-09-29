//
//  FlutterCefBrowserPlugin.h
//  flutter_cef_browser
//
//  Plugin entry point for Flutter
//

#import <Foundation/Foundation.h>
#import <FlutterMacOS/FlutterMacOS.h>

@class NSWindow;

@interface FlutterCefBrowserPlugin : NSObject<FlutterPlugin, FlutterStreamHandler>
@end

/// Returns YES when any CEF browser instance currently has keyboard focus.
/// Call from the host NSWindow to decide whether editing shortcuts (Cmd+C/V/X)
/// should bypass the Flutter shortcut router and propagate to CEF.
FOUNDATION_EXPORT BOOL FlutterCefBrowserPlugin_isCefBrowserFocused(void);

/// Performs a focused CEF edit command (`copy`, `paste`, `cut`, `selectAll`,
/// `undo`, `redo`) for a browser owned by `window`.
///
/// This gives host NSWindow subclasses a deterministic route for standard edit
/// shortcuts without relying on AppKit first-responder delivery to Chromium.
FOUNDATION_EXPORT BOOL FlutterCefBrowserPlugin_performFocusedBrowserEditCommand(
    NSString* command,
    NSWindow* window);

/// Performs a focused CEF browser command (`copy`, `zoomIn`, `scrollToTop`,
/// and related commands) for a browser owned by `window`.
FOUNDATION_EXPORT BOOL FlutterCefBrowserPlugin_performFocusedBrowserCommand(
    NSString* command,
    NSWindow* window);
