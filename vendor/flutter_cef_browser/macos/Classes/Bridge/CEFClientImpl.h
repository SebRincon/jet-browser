//
//  CEFClientImpl.h
//  flutter_cef_browser
//
//  CEF Client implementation with all handlers
//

#ifndef CEFClientImpl_h
#define CEFClientImpl_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_render_handler.h"
#include <deque>
#include <map>
#include <string>

@class CEFAcceleratedFrameLease;

@protocol CEFClientDelegate <NSObject>

// Lifecycle
- (void)onBrowserCreated:(int)browserId;
- (void)onBrowserClosed:(int)browserId;

// Display
- (void)onTitleChanged:(int)browserId title:(NSString *)title;
- (void)onUrlChanged:(int)browserId url:(NSString *)url;
- (void)onFaviconChanged:(int)browserId urls:(NSArray<NSString *> *)urls;
- (void)onStatusMessage:(int)browserId text:(NSString *)text;
- (void)onAudioStateChanged:(int)browserId audible:(BOOL)audible;

// Loading
- (void)onLoadingStateChanged:(int)browserId
                    isLoading:(BOOL)isLoading
                    canGoBack:(BOOL)canGoBack
                 canGoForward:(BOOL)canGoForward;
- (void)onFindResult:(int)browserId
          identifier:(int)identifier
               count:(int)count
  activeMatchOrdinal:(int)activeMatchOrdinal
         finalUpdate:(BOOL)finalUpdate;
- (void)onLoadError:(int)browserId
          errorCode:(int)errorCode
          errorText:(NSString *)errorText
                url:(NSString *)url;
- (void)onLoadProgress:(int)browserId progress:(double)progress;
- (void)onLoadEnd:(int)browserId url:(NSString *)url;

// Popup
- (nullable NSView *)onBeforePopup:(int)browserId
                           details:(NSDictionary *)details
                     proposedFrame:(NSRect)proposedFrame;
- (void)onPopupRequested:(int)browserId details:(NSDictionary *)details;

// Downloads
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

// Auth
- (void)onAuthRequired:(int)browserId
               isProxy:(BOOL)isProxy
                  host:(NSString *)host
                 realm:(NSString *)realm;

// Console
- (void)onConsoleMessage:(int)browserId
                   level:(int)level
                 message:(NSString *)message
                  source:(NSString *)source
                    line:(int)line;

// Focus
- (void)onFocusChanged:(int)browserId focused:(BOOL)focused;

// Cursor (OSR). Return YES when the embedder applied/stored the cursor.
- (BOOL)onCursorChangeForCefBrowserId:(int)browserId
                                cursor:(nullable NSCursor*)cursor
                                  type:(NSInteger)type;

// Off-screen rendering. The dirty rect is the pixel-space union of CEF's
// damage list for this frame; a zero rect means "unknown, treat as full".
- (void)onOsrPaintForCefBrowserId:(int)browserId
                              type:(int)type
                            buffer:(const void *)buffer
                             width:(int)width
                            height:(int)height
                        dirtyRect:(CGRect)dirtyRect;
// |extra| carries the viz capture-delivery metadata (coded/visible/content
// rects, capture counter) so the embedder can detect stale pool buffers that
// were delivered without a completed blit (known CEF OSR issue; see the
// diagonal-shear investigation).
- (void)onAcceleratedOsrPaintForCefBrowserId:(int)browserId
                                         type:(int)type
                                    ioSurface:(void *)ioSurface
                                       format:(int)format
                                    dirtyRect:(CGRect)dirtyRect
                                        extra:(NSDictionary *)extra;
#if defined(CEF_ACCELERATED_FRAME_LEASE_API)
- (BOOL)onLeasedAcceleratedOsrFrameForCefBrowserId:(int)browserId
                                               type:(int)type
                                          ioSurface:(void *)ioSurface
                                             format:(int)format
                                          dirtyRect:(CGRect)dirtyRect
                                              extra:(NSDictionary *)extra
                                              lease:(CEFAcceleratedFrameLease *)lease;
#endif
- (BOOL)getOsrScreenPointForCefBrowserId:(int)browserId
                                   viewX:(int)viewX
                                   viewY:(int)viewY
                                 screenX:(int*)screenX
                                 screenY:(int*)screenY;
- (BOOL)getOsrRootScreenRectForCefBrowserId:(int)browserId
                                          x:(int*)x
                                          y:(int*)y
                                      width:(int*)width
                                     height:(int*)height;
// Popup widget (select/autocomplete) surface lifecycle; rect is in view
// coordinates (DIPs).
- (void)onOsrPopupShowForCefBrowserId:(int)browserId show:(BOOL)show;
- (void)onOsrPopupSizeForCefBrowserId:(int)browserId rect:(CGRect)rect;
// Drag and drop (OSR). Returns YES when a native drag session was started.
- (BOOL)onOsrStartDraggingForCefBrowserId:(int)browserId
                                 dragData:(CefRefPtr<CefDragData>)dragData
                               allowedOps:(int)allowedOps
                                        x:(int)x
                                        y:(int)y;
- (void)onOsrUpdateDragCursorForCefBrowserId:(int)browserId
                                   operation:(int)operation;
// Context menu (OSR): forward Chromium's menu model to Flutter. Returns YES
// when the callback is retained for asynchronous resolve/cancel.
- (BOOL)onOsrRunContextMenuForCefBrowserId:(int)browserId
                                    params:(CefRefPtr<CefContextMenuParams>)params
                                     model:(CefRefPtr<CefMenuModel>)model
                                  callback:(CefRefPtr<CefRunContextMenuCallback>)callback;
- (void)onInspectElementRequestedForCefBrowserId:(int)browserId
                                               x:(int)x
                                               y:(int)y;
- (void)onDevToolsShortcutForCefBrowserId:(int)browserId;
- (void)onTooltipForCefBrowserId:(int)browserId text:(NSString *)text;
- (void)onJsDialogForCefBrowserId:(int)browserId
                       callbackId:(int)callbackId
                              kind:(NSString *)kind
                           message:(NSString *)message
                     defaultPrompt:(NSString *)defaultPrompt;
- (void)onPermissionPromptForCefBrowserId:(int)browserId
                                  promptId:(NSString *)promptId
                                     origin:(NSString *)origin
                                permissions:(NSArray<NSString *> *)permissions;
- (void)onFullscreenModeChangeForCefBrowserId:(int)browserId fullscreen:(BOOL)fullscreen;
- (void)onImeCompositionRangeChangedForCefBrowserId:(int)browserId caretRect:(CGRect)caretRect;
- (void)onTextInputStateChangedForCefBrowserId:(int)browserId editable:(BOOL)editable;
- (void)onResetDialogStateForCefBrowserId:(int)browserId;

@end

class CEFClientImpl : public CefClient,
                      public CefLifeSpanHandler,
                      public CefDisplayHandler,
                      public CefDownloadHandler,
                      public CefRequestHandler,
                      public CefLoadHandler,
                      public CefFocusHandler,
                      public CefFindHandler,
                      public CefKeyboardHandler,
                      public CefContextMenuHandler,
                      public CefDialogHandler,
                      public CefJSDialogHandler,
                      public CefPermissionHandler,
                      public CefRenderHandler {
public:
    explicit CEFClientImpl(id<CEFClientDelegate> delegate);
    virtual ~CEFClientImpl();

    // CefClient interface
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }

    // CefLifeSpanHandler
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
                      bool* no_javascript_access) override;
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
    bool DoClose(CefRefPtr<CefBrowser> browser) override;
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

    // CefDisplayHandler
    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& url) override;
    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                           const std::vector<CefString>& icon_urls) override;
    void OnStatusMessage(CefRefPtr<CefBrowser> browser,
                         const CefString& value) override;
    bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                         cef_log_severity_t level,
                         const CefString& message,
                         const CefString& source,
                         int line) override;

    bool OnCursorChange(CefRefPtr<CefBrowser> browser,
                        CefCursorHandle cursor,
                        cef_cursor_type_t type,
                        const CefCursorInfo& custom_cursor_info) override;
    bool OnTooltip(CefRefPtr<CefBrowser> browser, CefString& text) override;
    void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                                bool fullscreen) override;

    // CefLoadHandler
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                             bool isLoading,
                             bool canGoBack,
                             bool canGoForward) override;
    void OnLoadStart(CefRefPtr<CefBrowser> browser,
                    CefRefPtr<CefFrame> frame,
                    TransitionType transition_type) override;
    void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                  CefRefPtr<CefFrame> frame,
                  int httpStatusCode) override;
    void OnLoadError(CefRefPtr<CefBrowser> browser,
                    CefRefPtr<CefFrame> frame,
                    ErrorCode errorCode,
                    const CefString& errorText,
                    const CefString& failedUrl) override;

    // CefFindHandler
    void OnFindResult(CefRefPtr<CefBrowser> browser,
                      int identifier,
                      int count,
                      const CefRect& selectionRect,
                      int activeMatchOrdinal,
                      bool finalUpdate) override;

    // CefDownloadHandler
    bool CanDownload(CefRefPtr<CefBrowser> browser,
                    const CefString& url,
                    const CefString& request_method) override;
    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         const CefString& suggested_name,
                         CefRefPtr<CefBeforeDownloadCallback> callback) override;
    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefDownloadItem> download_item,
                          CefRefPtr<CefDownloadItemCallback> callback) override;

    // CefRequestHandler
    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          const CefString& target_url,
                          WindowOpenDisposition target_disposition,
                          bool user_gesture) override;
    bool GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                           const CefString& origin_url,
                           bool isProxy,
                           const CefString& host,
                           int port,
                           const CefString& realm,
                           const CefString& scheme,
                           CefRefPtr<CefAuthCallback> callback) override;

    // CefFocusHandler
    void OnGotFocus(CefRefPtr<CefBrowser> browser) override;
    bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override;
    void OnTakeFocus(CefRefPtr<CefBrowser> browser, bool next) override;

    // CefKeyboardHandler
    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                      const CefKeyEvent& event,
                      CefEventHandle os_event,
                      bool* is_keyboard_shortcut) override;

    // CefContextMenuHandler
    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            CefRefPtr<CefMenuModel> model) override;
    bool RunContextMenu(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefContextMenuParams> params,
                        CefRefPtr<CefMenuModel> model,
                        CefRefPtr<CefRunContextMenuCallback> callback) override;
    bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefContextMenuParams> params,
                              int command_id,
                              EventFlags event_flags) override;

    // CefDialogHandler
    bool OnFileDialog(CefRefPtr<CefBrowser> browser,
                      FileDialogMode mode,
                      const CefString& title,
                      const CefString& default_file_path,
                      const std::vector<CefString>& accept_filters,
                      const std::vector<CefString>& accept_extensions,
                      const std::vector<CefString>& accept_descriptions,
                      CefRefPtr<CefFileDialogCallback> callback) override;

    // CefJSDialogHandler
    bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                    const CefString& origin_url,
                    JSDialogType dialog_type,
                    const CefString& message_text,
                    const CefString& default_prompt_text,
                    CefRefPtr<CefJSDialogCallback> callback,
                    bool& suppress_message) override;
    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                              const CefString& message_text,
                              bool is_reload,
                              CefRefPtr<CefJSDialogCallback> callback) override;
    void OnResetDialogState(CefRefPtr<CefBrowser> browser) override;

    // CefPermissionHandler
    bool OnRequestMediaAccessPermission(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        const CefString& requesting_origin,
        uint32_t requested_permissions,
        CefRefPtr<CefMediaAccessCallback> callback) override;
    bool OnShowPermissionPrompt(
        CefRefPtr<CefBrowser> browser,
        uint64_t prompt_id,
        const CefString& requesting_origin,
        uint32_t requested_permissions,
        CefRefPtr<CefPermissionPromptCallback> callback) override;
    void OnDismissPermissionPrompt(
        CefRefPtr<CefBrowser> browser,
        uint64_t prompt_id,
        cef_permission_request_result_t result) override;

    // CefRenderHandler
    bool GetRootScreenRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
    void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
    bool GetScreenPoint(CefRefPtr<CefBrowser> browser,
                        int viewX,
                        int viewY,
                        int& screenX,
                        int& screenY) override;
    bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& screen_info) override;
    void OnPaint(CefRefPtr<CefBrowser> browser,
                 PaintElementType type,
                 const RectList& dirtyRects,
                 const void* buffer,
                 int width,
                 int height) override;
    void OnAcceleratedPaint(
        CefRefPtr<CefBrowser> browser,
        PaintElementType type,
        const RectList& dirtyRects,
        const CefAcceleratedPaintInfo& info) override;
#if defined(CEF_ACCELERATED_FRAME_LEASE_API)
    bool OnAcceleratedFrame(
        CefRefPtr<CefBrowser> browser,
        PaintElementType type,
        const RectList& dirtyRects,
        const CefAcceleratedPaintInfo& info,
        CefRefPtr<CefAcceleratedFrame> frame) override;
#endif
    void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override;
    void OnPopupSize(CefRefPtr<CefBrowser> browser,
                     const CefRect& rect) override;
    bool StartDragging(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefDragData> drag_data,
                       CefRenderHandler::DragOperationsMask allowed_ops,
                       int x,
                       int y) override;
    void UpdateDragCursor(CefRefPtr<CefBrowser> browser,
                          CefRenderHandler::DragOperation operation) override;
    void OnImeCompositionRangeChanged(CefRefPtr<CefBrowser> browser,
                                      const CefRange& selected_range,
                                      const RectList& character_bounds) override;
    void OnVirtualKeyboardRequested(CefRefPtr<CefBrowser> browser,
                                    TextInputMode input_mode) override;

    // Browser management
    CefRefPtr<CefBrowser> GetBrowser(int browserId);
    void StoreBrowser(int browserId, CefRefPtr<CefBrowser> browser);
    void RemoveBrowser(int browserId);

    // Download control
    void PauseDownload(uint32_t downloadId);
    void ResumeDownload(uint32_t downloadId);
    void CancelDownload(uint32_t downloadId);

    // Auth control
    void ProvideAuthCredentials(const std::string& username, const std::string& password);
    void CancelAuth();

    // Off-screen rendering control
    void QueuePendingOsrViewSize(int width, int height, float scaleFactor);
    void DiscardPendingOsrViewSize();
    void SetOsrViewSize(int browserId, int width, int height, float scaleFactor);
    void RemoveOsrViewSize(int browserId);
    void SetAcceleratedFrameLeaseEnabled(int browserId, bool enabled);
    void ResolveJsDialog(int browserId,
                         int callbackId,
                         bool success,
                         const std::string& userInput);
    void ResolvePermissionPrompt(int browserId,
                                 const std::string& promptId,
                                 bool allow);

private:
    struct OsrViewState {
        int width = 1;
        int height = 1;
        float scaleFactor = 1.0f;
    };

    struct PendingJsDialog {
        int browserId = -1;
        CefRefPtr<CefJSDialogCallback> callback;
    };

    struct PendingMediaPermission {
        int browserId = -1;
        uint32_t requestedPermissions = 0;
        CefRefPtr<CefMediaAccessCallback> callback;
    };

    struct PendingBrowserPermission {
        int browserId = -1;
        uint64_t cefPromptId = 0;
        CefRefPtr<CefPermissionPromptCallback> callback;
    };

    bool IsOsrBrowser(int browserId) const;
    int RetainJsDialogCallback(int browserId,
                               CefRefPtr<CefJSDialogCallback> callback);
    void ClearJsDialogCallbacks(int browserId);
    void ClearPermissionCallbacks(int browserId);

    __weak id<CEFClientDelegate> delegate_;
    std::map<int, CefRefPtr<CefBrowser>> browsers_;
    std::map<int, OsrViewState> osrViewStates_;
    std::map<int, bool> acceleratedFrameLeaseEnabled_;
    std::map<int, bool> osrPopupVisible_;
    std::deque<OsrViewState> pendingOsrViewStates_;
    std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> downloadCallbacks_;
    std::map<uint32_t, std::string> downloadTargetPaths_;
    CefRefPtr<CefAuthCallback> pendingAuthCallback_;
    std::map<std::string, PendingMediaPermission> mediaPermissionCallbacks_;
    std::map<std::string, PendingBrowserPermission> browserPermissionCallbacks_;
    std::map<int, PendingJsDialog> jsDialogCallbacks_;
    int nextJsDialogCallbackId_ = 1;
    uint64_t nextMediaPermissionPromptId_ = 1;
    bool blockFocus_ = false;

    IMPLEMENT_REFCOUNTING(CEFClientImpl);
    DISALLOW_COPY_AND_ASSIGN(CEFClientImpl);
};

#endif /* CEFClientImpl_h */
