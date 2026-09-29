//
//  CEFClientImpl.mm
//  flutter_cef_browser
//
//  CEF Client implementation
//

#import "CEFClientImpl.h"
#import "CEFBridge.h"
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <algorithm>
#include <atomic>
#include <climits>
#include <mutex>
#include "include/views/cef_display.h"
#include "include/wrapper/cef_helpers.h"

namespace {

bool ShouldLogPopupDebug() {
    static bool enabled = false;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_POPUP_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

bool ShouldLogResizeDebug() {
    static bool enabled = false;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_RESIZE_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

#if defined(CEF_ACCELERATED_FRAME_LEASE_API)
bool ShouldUseAcceleratedFrameLease() {
    static bool enabled = false;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_OSR_FRAME_LEASE");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}
#endif

NSString* NSStringOrEmptyFromCefString(const CefString& value) {
    const std::string text = value.ToString();
    NSString* string = [NSString stringWithUTF8String:text.c_str()];
    return string ?: @"";
}

void AddAllowedContentType(NSMutableArray<UTType*>* types,
                           NSMutableSet<NSString*>* identifiers,
                           UTType* type) {
    if (!type || [identifiers containsObject:type.identifier]) {
        return;
    }
    [identifiers addObject:type.identifier];
    [types addObject:type];
}

NSArray<UTType*>* AllowedContentTypes(
    const std::vector<CefString>& accept_filters,
    const std::vector<CefString>& accept_extensions) {
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    NSMutableSet<NSString*>* identifiers = [NSMutableSet set];

    for (const CefString& value : accept_extensions) {
        NSString* extensions = NSStringOrEmptyFromCefString(value);
        for (NSString* rawExtension in [extensions componentsSeparatedByString:@";"]) {
            NSString* extension = [rawExtension stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@". "]];
            if (extension.length > 0) {
                AddAllowedContentType(types, identifiers,
                    [UTType typeWithFilenameExtension:extension]);
            }
        }
    }

    for (const CefString& value : accept_filters) {
        NSString* filter = [NSStringOrEmptyFromCefString(value) lowercaseString];
        if ([filter hasPrefix:@"."] && filter.length > 1) {
            AddAllowedContentType(types, identifiers,
                [UTType typeWithFilenameExtension:[filter substringFromIndex:1]]);
        } else if ([filter isEqualToString:@"image/*"]) {
            AddAllowedContentType(types, identifiers, UTTypeImage);
        } else if ([filter isEqualToString:@"audio/*"]) {
            AddAllowedContentType(types, identifiers, UTTypeAudio);
        } else if ([filter isEqualToString:@"video/*"]) {
            AddAllowedContentType(types, identifiers, UTTypeMovie);
        } else if ([filter isEqualToString:@"text/*"]) {
            AddAllowedContentType(types, identifiers, UTTypeText);
        } else if ([filter containsString:@"/"] && ![filter hasSuffix:@"/*"]) {
            AddAllowedContentType(types, identifiers,
                [UTType typeWithMIMEType:filter]);
        }
    }
    return types;
}

void AddPermissionName(NSMutableArray<NSString*>* names, BOOL enabled, NSString* name) {
    if (enabled) {
        [names addObject:name];
    }
}

NSString* JoinedPermissionNames(NSArray<NSString*>* names) {
    if (names.count == 0) {
        return @"browser permissions";
    }
    if (names.count == 1) {
        return names.firstObject;
    }
    if (names.count == 2) {
        return [NSString stringWithFormat:@"%@ and %@", names[0], names[1]];
    }

    NSMutableArray<NSString*>* prefix = [names mutableCopy];
    NSString* last = prefix.lastObject;
    [prefix removeLastObject];
    return [NSString stringWithFormat:@"%@, and %@",
                                      [prefix componentsJoinedByString:@", "],
                                      last];
}

NSString* MediaPermissionDescription(uint32_t permissions) {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    AddPermissionName(names, (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0, @"microphone");
    AddPermissionName(names, (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0, @"camera");
    AddPermissionName(names, (permissions & CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE) != 0, @"desktop audio");
    AddPermissionName(names, (permissions & CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE) != 0, @"screen capture");
    return JoinedPermissionNames(names);
}

NSArray<NSString*>* MediaPermissionKinds(uint32_t permissions) {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    AddPermissionName(names, (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0, @"microphone");
    AddPermissionName(names, (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0, @"camera");
    AddPermissionName(names, (permissions & CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE) != 0, @"desktopAudio");
    AddPermissionName(names, (permissions & CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE) != 0, @"screenCapture");
    const uint32_t knownPermissions =
        CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE |
        CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE |
        CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE |
        CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE;
    AddPermissionName(names, (permissions & ~knownPermissions) != 0, @"unknown");
    return names;
}

NSArray<NSString*>* BrowserPermissionKinds(uint32_t permissions) {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    AddPermissionName(names, (permissions & CEF_PERMISSION_TYPE_CAMERA_STREAM) != 0, @"camera");
    AddPermissionName(names, (permissions & CEF_PERMISSION_TYPE_MIC_STREAM) != 0, @"microphone");
    AddPermissionName(names, (permissions & CEF_PERMISSION_TYPE_GEOLOCATION) != 0, @"location");
    AddPermissionName(names, (permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) != 0, @"notifications");
    AddPermissionName(names, (permissions & CEF_PERMISSION_TYPE_CLIPBOARD) != 0, @"clipboard");
    const uint32_t knownPermissions =
        CEF_PERMISSION_TYPE_CAMERA_STREAM |
        CEF_PERMISSION_TYPE_MIC_STREAM |
        CEF_PERMISSION_TYPE_GEOLOCATION |
        CEF_PERMISSION_TYPE_NOTIFICATIONS |
        CEF_PERMISSION_TYPE_CLIPBOARD;
    AddPermissionName(names, (permissions & ~knownPermissions) != 0, @"unknown");
    return names;
}

static NSString* WindowOpenDispositionName(
    CefLifeSpanHandler::WindowOpenDisposition disposition) {
    switch (disposition) {
        case CEF_WOD_CURRENT_TAB:
            return @"currentTab";
        case CEF_WOD_SINGLETON_TAB:
            return @"singletonTab";
        case CEF_WOD_NEW_FOREGROUND_TAB:
            return @"newForegroundTab";
        case CEF_WOD_NEW_BACKGROUND_TAB:
            return @"newBackgroundTab";
        case CEF_WOD_NEW_POPUP:
            return @"newPopup";
        case CEF_WOD_NEW_WINDOW:
            return @"newWindow";
        case CEF_WOD_SAVE_TO_DISK:
            return @"saveToDisk";
        case CEF_WOD_OFF_THE_RECORD:
            return @"offTheRecord";
        case CEF_WOD_IGNORE_ACTION:
            return @"ignoreAction";
        case CEF_WOD_SWITCH_TO_TAB:
            return @"switchToTab";
        case CEF_WOD_NEW_PICTURE_IN_PICTURE:
            return @"newPictureInPicture";
        case CEF_WOD_UNKNOWN:
        default:
            return @"unknown";
    }
}

static NSDictionary* EmptyPopupFeatureDetails() {
    return @{
        @"x": @(0),
        @"xSet": @(NO),
        @"y": @(0),
        @"ySet": @(NO),
        @"width": @(0),
        @"widthSet": @(NO),
        @"height": @(0),
        @"heightSet": @(NO),
        @"isPopup": @(NO),
    };
}

static NSDictionary* PopupFeatureDetails(const CefPopupFeatures& popupFeatures) {
    return @{
        @"x": @(popupFeatures.x),
        @"xSet": @(popupFeatures.xSet != 0),
        @"y": @(popupFeatures.y),
        @"ySet": @(popupFeatures.ySet != 0),
        @"width": @(popupFeatures.width),
        @"widthSet": @(popupFeatures.widthSet != 0),
        @"height": @(popupFeatures.height),
        @"heightSet": @(popupFeatures.heightSet != 0),
        @"isPopup": @(popupFeatures.isPopup != 0),
    };
}

static NSRect ProposedPopupFrame(const CefPopupFeatures& popupFeatures) {
    const CGFloat width = popupFeatures.widthSet != 0
        ? MAX(320, popupFeatures.width)
        : 520;
    const CGFloat height = popupFeatures.heightSet != 0
        ? MAX(240, popupFeatures.height)
        : 640;
    const CGFloat x = popupFeatures.xSet != 0 ? popupFeatures.x : 0;
    const CGFloat y = popupFeatures.ySet != 0 ? popupFeatures.y : 0;
    return NSMakeRect(x, y, width, height);
}

}  // namespace

CEFClientImpl::CEFClientImpl(id<CEFClientDelegate> delegate)
    : delegate_(delegate) {
}

CEFClientImpl::~CEFClientImpl() {
    browsers_.clear();
    osrViewStates_.clear();
    osrPopupVisible_.clear();
    pendingOsrViewStates_.clear();
    downloadCallbacks_.clear();
    downloadTargetPaths_.clear();
    jsDialogCallbacks_.clear();
    mediaPermissionCallbacks_.clear();
    browserPermissionCallbacks_.clear();
}

// Browser management

CefRefPtr<CefBrowser> CEFClientImpl::GetBrowser(int browserId) {
    auto it = browsers_.find(browserId);
    if (it != browsers_.end()) {
        return it->second;
    }
    return nullptr;
}

void CEFClientImpl::StoreBrowser(int browserId, CefRefPtr<CefBrowser> browser) {
    browsers_[browserId] = browser;
#if defined(CEF_ACCELERATED_FRAME_LEASE_API)
    if (ShouldUseAcceleratedFrameLease()) {
        acceleratedFrameLeaseEnabled_[browserId] = true;
    }
#endif
}

void CEFClientImpl::RemoveBrowser(int browserId) {
    browsers_.erase(browserId);
    osrViewStates_.erase(browserId);
    osrPopupVisible_.erase(browserId);
    acceleratedFrameLeaseEnabled_.erase(browserId);
    ClearJsDialogCallbacks(browserId);
    ClearPermissionCallbacks(browserId);
}

bool CEFClientImpl::IsOsrBrowser(int browserId) const {
    return osrViewStates_.find(browserId) != osrViewStates_.end();
}

void CEFClientImpl::SetAcceleratedFrameLeaseEnabled(int browserId,
                                                    bool enabled) {
    if (enabled) {
        acceleratedFrameLeaseEnabled_[browserId] = true;
    } else {
        acceleratedFrameLeaseEnabled_.erase(browserId);
    }
}

void CEFClientImpl::QueuePendingOsrViewSize(int width, int height, float scaleFactor) {
    OsrViewState state;
    state.width = std::max(1, width);
    state.height = std::max(1, height);
    state.scaleFactor = std::max(1.0f, scaleFactor);
    pendingOsrViewStates_.push_back(state);
}

void CEFClientImpl::DiscardPendingOsrViewSize() {
    if (!pendingOsrViewStates_.empty()) {
        pendingOsrViewStates_.pop_back();
    }
}

void CEFClientImpl::SetOsrViewSize(int browserId, int width, int height, float scaleFactor) {
    OsrViewState state;
    state.width = std::max(1, width);
    state.height = std::max(1, height);
    state.scaleFactor = std::max(1.0f, scaleFactor);
    osrViewStates_[browserId] = state;
}

void CEFClientImpl::RemoveOsrViewSize(int browserId) {
    osrViewStates_.erase(browserId);
    osrPopupVisible_.erase(browserId);
}

// CefLifeSpanHandler

bool CEFClientImpl::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
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
    bool* no_javascript_access) {

    int browserId = browser->GetIdentifier();
    NSString* url = [NSString stringWithUTF8String:target_url.ToString().c_str()];
    NSString* targetFrameName =
        [NSString stringWithUTF8String:target_frame_name.ToString().c_str()];
    NSDictionary* popupFeatureDetails = PopupFeatureDetails(popupFeatures);
    NSDictionary* details = @{
        @"source": @"beforePopup",
        @"targetUrl": url ?: @"",
        @"url": url ?: @"",
        @"targetFrameName": targetFrameName ?: @"",
        @"popupId": @(popup_id),
        @"targetDisposition": @((int)target_disposition),
        @"targetDispositionName": WindowOpenDispositionName(target_disposition),
        @"userGesture": @(user_gesture),
        @"popupFeatures": popupFeatureDetails,
    };

    NSView* managedPopupView = [delegate_ onBeforePopup:browserId
                                                details:details
                                          proposedFrame:ProposedPopupFrame(popupFeatures)];
    if (managedPopupView) {
        NSRect bounds = managedPopupView.bounds;
        windowInfo.SetAsChild((__bridge void*)managedPopupView,
                              CefRect(0, 0, bounds.size.width, bounds.size.height));
        if (no_javascript_access) {
            *no_javascript_access = false;
        }
        return false;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onPopupRequested:browserId details:details];
    });

    // Cancel default popup - Flutter creates new browser instance
    return true;
}

void CEFClientImpl::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();

    int browserId = browser->GetIdentifier();
    browsers_[browserId] = browser;
    if (!pendingOsrViewStates_.empty()) {
        osrViewStates_[browserId] = pendingOsrViewStates_.front();
        pendingOsrViewStates_.pop_front();
    }

    NSLog(@"CEFClientImpl: OnAfterCreated - browserId: %d, total browsers: %zu", browserId, browsers_.size());

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onBrowserCreated:browserId];
    });
}

bool CEFClientImpl::DoClose(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    NSLog(@"CEFClientImpl: DoClose - browserId: %d", browserId);
    // Return false to allow default close behavior
    return false;
}

void CEFClientImpl::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();

    int browserId = browser->GetIdentifier();
    ClearJsDialogCallbacks(browserId);
    browsers_.erase(browserId);
    osrViewStates_.erase(browserId);
    osrPopupVisible_.erase(browserId);

    NSLog(@"CEFClientImpl: OnBeforeClose - browserId: %d, remaining browsers: %zu", browserId, browsers_.size());

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onBrowserClosed:browserId];
    });
}

// CefDisplayHandler

void CEFClientImpl::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
    int browserId = browser->GetIdentifier();
    NSString* titleStr = [NSString stringWithUTF8String:title.ToString().c_str()];

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onTitleChanged:browserId title:titleStr];
    });
}

void CEFClientImpl::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    const CefString& url) {
    if (!frame->IsMain()) return;

    int browserId = browser->GetIdentifier();
    NSString* urlStr = [NSString stringWithUTF8String:url.ToString().c_str()];

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onUrlChanged:browserId url:urlStr];
    });
}

void CEFClientImpl::OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                                       const std::vector<CefString>& icon_urls) {
    int browserId = browser->GetIdentifier();
    NSMutableArray* urls = [NSMutableArray arrayWithCapacity:icon_urls.size()];

    for (const auto& url : icon_urls) {
        [urls addObject:[NSString stringWithUTF8String:url.ToString().c_str()]];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onFaviconChanged:browserId urls:urls];
    });
}

void CEFClientImpl::OnStatusMessage(CefRefPtr<CefBrowser> browser,
                                    const CefString& value) {
    CEF_REQUIRE_UI_THREAD();
    if (!browser) return;
    [delegate_ onStatusMessage:browser->GetIdentifier()
                           text:NSStringOrEmptyFromCefString(value)];
}

bool CEFClientImpl::OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                                     cef_log_severity_t level,
                                     const CefString& message,
                                     const CefString& source,
                                     int line) {
    int browserId = browser->GetIdentifier();
    NSString* messageStr = [NSString stringWithUTF8String:message.ToString().c_str()];
    NSString* sourceStr = [NSString stringWithUTF8String:source.ToString().c_str()];

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onConsoleMessage:browserId level:(int)level message:messageStr source:sourceStr line:line];
    });

    return false; // Don't suppress default console output
}

bool CEFClientImpl::OnTooltip(CefRefPtr<CefBrowser> browser, CefString& text) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (!IsOsrBrowser(browserId)) {
        return false;
    }
    [delegate_ onTooltipForCefBrowserId:browserId
                                    text:NSStringOrEmptyFromCefString(text)];
    return true;
}

void CEFClientImpl::OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                                           bool fullscreen) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (!IsOsrBrowser(browserId)) {
        return;
    }
    [delegate_ onFullscreenModeChangeForCefBrowserId:browserId
                                           fullscreen:fullscreen ? YES : NO];
}

// CefLoadHandler

void CEFClientImpl::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                         bool isLoading,
                                         bool canGoBack,
                                         bool canGoForward) {
    int browserId = browser->GetIdentifier();

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onLoadingStateChanged:browserId
                               isLoading:isLoading
                               canGoBack:canGoBack
                            canGoForward:canGoForward];
    });
}

void CEFClientImpl::OnFindResult(CefRefPtr<CefBrowser> browser,
                                 int identifier,
                                 int count,
                                 const CefRect& selectionRect,
                                 int activeMatchOrdinal,
                                 bool finalUpdate) {
    CEF_REQUIRE_UI_THREAD();
    if (!browser) return;
    [delegate_ onFindResult:browser->GetIdentifier()
                 identifier:identifier
                      count:count
         activeMatchOrdinal:activeMatchOrdinal
                finalUpdate:finalUpdate];
}

void CEFClientImpl::OnLoadStart(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                TransitionType transition_type) {
    // Could track navigation type here
}

void CEFClientImpl::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              int httpStatusCode) {
    if (!frame->IsMain()) return;

    int browserId = browser->GetIdentifier();
    NSString* url = NSStringOrEmptyFromCefString(frame->GetURL());

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onLoadProgress:browserId progress:1.0];
        [delegate_ onLoadEnd:browserId url:url];
    });
}

void CEFClientImpl::OnLoadError(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                ErrorCode errorCode,
                                const CefString& errorText,
                                const CefString& failedUrl) {
    if (!frame->IsMain()) return;

    // Ignore aborted loads (e.g., navigating away before load completes)
    if (errorCode == ERR_ABORTED) return;

    int browserId = browser->GetIdentifier();
    NSString* errorStr = [NSString stringWithUTF8String:errorText.ToString().c_str()];
    NSString* urlStr = [NSString stringWithUTF8String:failedUrl.ToString().c_str()];

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onLoadError:browserId errorCode:(int)errorCode errorText:errorStr url:urlStr];
    });
}

// CefDownloadHandler

bool CEFClientImpl::CanDownload(CefRefPtr<CefBrowser> browser,
                                const CefString& url,
                                const CefString& request_method) {
    return true; // Allow all downloads
}

bool CEFClientImpl::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString& suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {

    int browserId = browser->GetIdentifier();
    uint32_t downloadId = download_item->GetId();

    NSString* suggestedFilename = [NSString stringWithUTF8String:suggested_name.ToString().c_str()];
    NSString* filename = suggestedFilename.lastPathComponent;
    if (filename.length == 0 || [filename isEqualToString:@"."] || [filename isEqualToString:@".."]) {
        filename = @"download";
    }
    NSString* url = [NSString stringWithUTF8String:download_item->GetURL().ToString().c_str()];
    NSString* mimeType = [NSString stringWithUTF8String:download_item->GetMimeType().ToString().c_str()];
    int64_t totalBytes = download_item->GetTotalBytes();

    NSString* downloadsPath = [NSSearchPathForDirectoriesInDomains(
        NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    NSString* extension = filename.pathExtension;
    NSString* stem = extension.length == 0 ? filename : filename.stringByDeletingPathExtension;
    NSString* fullPath = [downloadsPath stringByAppendingPathComponent:filename];
    NSFileManager* fileManager = NSFileManager.defaultManager;
    NSInteger suffix = 0;
    while (true) {
        const std::string candidate([fullPath UTF8String]);
        bool reserved = false;
        for (const auto& entry : downloadTargetPaths_) {
            if (entry.second == candidate) {
                reserved = true;
                break;
            }
        }
        if (![fileManager fileExistsAtPath:fullPath] && !reserved) {
            downloadTargetPaths_[downloadId] = candidate;
            break;
        }
        suffix += 1;
        NSString* nextFilename = extension.length == 0
            ? [NSString stringWithFormat:@"%@ (%ld)", stem, (long)suffix]
            : [NSString stringWithFormat:@"%@ (%ld).%@", stem, (long)suffix, extension];
        fullPath = [downloadsPath stringByAppendingPathComponent:nextFilename];
    }
    filename = fullPath.lastPathComponent;

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onDownloadStarted:downloadId
                           browserId:browserId
                                 url:url
                            filename:filename
                            mimeType:mimeType
                          totalBytes:totalBytes
                             fullPath:fullPath];
    });

    callback->Continue([fullPath UTF8String], false); // false = don't show dialog

    return true;
}

void CEFClientImpl::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {

    uint32_t downloadId = download_item->GetId();

    // Store callback for pause/resume/cancel control
    downloadCallbacks_[downloadId] = callback;

    if (download_item->IsComplete()) {
        NSString* path = [NSString stringWithUTF8String:
            download_item->GetFullPath().ToString().c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate_ onDownloadComplete:downloadId path:path];
        });
        downloadCallbacks_.erase(downloadId);
        downloadTargetPaths_.erase(downloadId);
    } else if (download_item->IsCanceled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate_ onDownloadCancelled:downloadId];
        });
        downloadCallbacks_.erase(downloadId);
        downloadTargetPaths_.erase(downloadId);
    } else if (download_item->IsInProgress()) {
        int64_t received = download_item->GetReceivedBytes();
        int64_t total = download_item->GetTotalBytes();
        int64_t speed = download_item->GetCurrentSpeed();
        int percent = download_item->GetPercentComplete();

        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate_ onDownloadProgress:downloadId
                            receivedBytes:received
                               totalBytes:total
                                    speed:speed
                          percentComplete:percent];
        });
    }
}

void CEFClientImpl::PauseDownload(uint32_t downloadId) {
    auto it = downloadCallbacks_.find(downloadId);
    if (it != downloadCallbacks_.end()) {
        it->second->Pause();
    }
}

void CEFClientImpl::ResumeDownload(uint32_t downloadId) {
    auto it = downloadCallbacks_.find(downloadId);
    if (it != downloadCallbacks_.end()) {
        it->second->Resume();
    }
}

void CEFClientImpl::CancelDownload(uint32_t downloadId) {
    auto it = downloadCallbacks_.find(downloadId);
    if (it != downloadCallbacks_.end()) {
        it->second->Cancel();
        downloadCallbacks_.erase(it);
    }
}

// CefRequestHandler

bool CEFClientImpl::OnOpenURLFromTab(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& target_url,
    WindowOpenDisposition target_disposition,
    bool user_gesture) {

    if (target_disposition == CEF_WOD_CURRENT_TAB) {
        return false;
    }

    int browserId = browser->GetIdentifier();
    NSString* url = [NSString stringWithUTF8String:target_url.ToString().c_str()];
    NSDictionary* details = @{
        @"source": @"openUrlFromTab",
        @"targetUrl": url ?: @"",
        @"url": url ?: @"",
        @"targetFrameName": @"",
        @"targetDisposition": @((int)target_disposition),
        @"targetDispositionName": WindowOpenDispositionName(target_disposition),
        @"userGesture": @(user_gesture),
        @"popupFeatures": EmptyPopupFeatureDetails(),
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onPopupRequested:browserId details:details];
    });

    // New-tab/window intents are routed through Flutter so
    // foreground/background tab behavior matches Chromium.
    return true;
}

bool CEFClientImpl::GetAuthCredentials(
    CefRefPtr<CefBrowser> browser,
    const CefString& origin_url,
    bool isProxy,
    const CefString& host,
    int port,
    const CefString& realm,
    const CefString& scheme,
    CefRefPtr<CefAuthCallback> callback) {

    pendingAuthCallback_ = callback;

    int browserId = browser->GetIdentifier();
    NSString* hostStr = [NSString stringWithUTF8String:host.ToString().c_str()];
    NSString* realmStr = [NSString stringWithUTF8String:realm.ToString().c_str()];

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onAuthRequired:browserId isProxy:isProxy host:hostStr realm:realmStr];
    });

    return true; // We handle it asynchronously
}

void CEFClientImpl::ProvideAuthCredentials(const std::string& username,
                                           const std::string& password) {
    if (pendingAuthCallback_) {
        pendingAuthCallback_->Continue(username, password);
        pendingAuthCallback_ = nullptr;
    }
}

void CEFClientImpl::CancelAuth() {
    if (pendingAuthCallback_) {
        pendingAuthCallback_->Cancel();
        pendingAuthCallback_ = nullptr;
    }
}

// CefFocusHandler

void CEFClientImpl::OnGotFocus(CefRefPtr<CefBrowser> browser) {
    int browserId = browser->GetIdentifier();

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onFocusChanged:browserId focused:YES];
    });
}

bool CEFClientImpl::OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) {
    // Return true to prevent automatic focus
    return blockFocus_;
}

void CEFClientImpl::OnTakeFocus(CefRefPtr<CefBrowser> browser, bool next) {
    int browserId = browser->GetIdentifier();

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate_ onFocusChanged:browserId focused:NO];
    });
}

// CefKeyboardHandler

bool CEFClientImpl::OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                                  const CefKeyEvent& event,
                                  CefEventHandle os_event,
                                  bool* is_keyboard_shortcut) {
    // Prevent Cmd+W from closing the host NSWindow when CEF has focus.
    // IDE shells usually map Cmd+W to "close tab", not "close app window".
    // If the host wants Cmd+W semantics it can implement them in Flutter.
    const bool keyDown = event.type == KEYEVENT_KEYDOWN || event.type == KEYEVENT_RAWKEYDOWN;
    const bool commandDown = (event.modifiers & EVENTFLAG_COMMAND_DOWN) != 0;
    const bool altDown = (event.modifiers & EVENTFLAG_ALT_DOWN) != 0;
    const int keyCode = event.windows_key_code;
    if (keyDown && commandDown) {
        const bool isW = keyCode == 'W' || keyCode == 'w';
        if (isW) {
            if (is_keyboard_shortcut) {
                *is_keyboard_shortcut = true;
            }
            return true;
        }
    }

    // DevTools shortcuts (F12, Cmd+Opt+I / J / C) would otherwise let Chromium
    // open DevTools in its own OS window. Route them to the host so it toggles
    // the docked, in-process DevTools pane instead (Chrome-like). Suppress the
    // event so CEF's default DevTools window never opens.
    if (keyDown) {
        const bool isF12 = keyCode == 0x7B;  // VK_F12
        const bool isDevToolsChord = commandDown && altDown &&
            (keyCode == 'I' || keyCode == 'J' || keyCode == 'C');
        if (isF12 || isDevToolsChord) {
            const int browserId = browser ? browser->GetIdentifier() : -1;
            [delegate_ onDevToolsShortcutForCefBrowserId:browserId];
            if (is_keyboard_shortcut) {
                *is_keyboard_shortcut = true;
            }
            return true;
        }
    }

    return false;
}

bool CEFClientImpl::OnCursorChange(
    CefRefPtr<CefBrowser> browser,
    CefCursorHandle cursor,
    cef_cursor_type_t type,
    const CefCursorInfo& custom_cursor_info) {
    CEF_REQUIRE_UI_THREAD();

    // CEF 147's CefRenderWidgetHostViewOSR::LockPointer and
    // ChangePointerLock unconditionally return kPermissionDenied, and its
    // UnlockPointer implementation is empty. No windowless embedder callback
    // exists for cursor capture/relative deltas in this pinned bundle.

    NSCursor* nativeCursor = cursor ? (__bridge NSCursor*)cursor : nil;
    const int browserId = browser ? browser->GetIdentifier() : -1;
    return [delegate_ onCursorChangeForCefBrowserId:browserId
                                             cursor:nativeCursor
                                               type:(NSInteger)type] == YES;
}

// CefContextMenuHandler

namespace {
// User-defined command appended to every page context menu.
const int kCefInspectElementCommandId = MENU_ID_USER_FIRST;
}  // namespace

void CEFClientImpl::OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        CefRefPtr<CefContextMenuParams> params,
                                        CefRefPtr<CefMenuModel> model) {
    CEF_REQUIRE_UI_THREAD();
    if (model->GetCount() > 0) {
        model->AddSeparator();
    }
    model->AddItem(kCefInspectElementCommandId, "Inspect Element");
}

bool CEFClientImpl::RunContextMenu(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefContextMenuParams> params,
                                   CefRefPtr<CefMenuModel> model,
                                   CefRefPtr<CefRunContextMenuCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    // Windowless browsers have no default menu runner; the bridge forwards the
    // Chromium model to Flutter. Returns NO for native-view browsers so their
    // default runner keeps working.
    return [delegate_ onOsrRunContextMenuForCefBrowserId:browserId
                                                   params:params
                                                    model:model
                                                 callback:callback] == YES;
}

bool CEFClientImpl::OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         CefRefPtr<CefContextMenuParams> params,
                                         int command_id,
                                         EventFlags event_flags) {
    CEF_REQUIRE_UI_THREAD();
    if (command_id == kCefInspectElementCommandId) {
        const int browserId = browser ? browser->GetIdentifier() : -1;
        [delegate_ onInspectElementRequestedForCefBrowserId:browserId
                                                          x:params->GetXCoord()
                                                          y:params->GetYCoord()];
        return true;
    }
    return false;
}

// CefDialogHandler

bool CEFClientImpl::OnFileDialog(
    CefRefPtr<CefBrowser> browser,
    FileDialogMode mode,
    const CefString& title,
    const CefString& default_file_path,
    const std::vector<CefString>& accept_filters,
    const std::vector<CefString>& accept_extensions,
    const std::vector<CefString>& accept_descriptions,
    CefRefPtr<CefFileDialogCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (!IsOsrBrowser(browserId) || !callback) {
        return false;
    }

    NSString* dialogTitle = NSStringOrEmptyFromCefString(title);
    NSString* defaultPath = NSStringOrEmptyFromCefString(default_file_path);
    NSArray<UTType*>* allowedTypes = AllowedContentTypes(
        accept_filters, accept_extensions);
    CefRefPtr<CefFileDialogCallback> retainedCallback = callback;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSSavePanel* panel = nil;
        if (mode == FILE_DIALOG_SAVE) {
            panel = [NSSavePanel savePanel];
        } else {
            NSOpenPanel* openPanel = [NSOpenPanel openPanel];
            openPanel.allowsMultipleSelection = mode == FILE_DIALOG_OPEN_MULTIPLE;
            openPanel.canChooseDirectories = mode == FILE_DIALOG_OPEN_FOLDER;
            openPanel.canChooseFiles = mode != FILE_DIALOG_OPEN_FOLDER;
            panel = openPanel;
        }
        if (dialogTitle.length > 0) {
            panel.title = dialogTitle;
        }
        panel.canCreateDirectories = YES;
        if (allowedTypes.count > 0) {
            panel.allowedContentTypes = allowedTypes;
        }
        if (defaultPath.length > 0) {
            BOOL isDirectory = NO;
            [[NSFileManager defaultManager] fileExistsAtPath:defaultPath
                                                isDirectory:&isDirectory];
            NSString* directory = isDirectory
                ? defaultPath
                : [defaultPath stringByDeletingLastPathComponent];
            if (directory.length > 0) {
                panel.directoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
            }
            if (mode == FILE_DIALOG_SAVE && !isDirectory) {
                panel.nameFieldStringValue = defaultPath.lastPathComponent;
            }
        }

        void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
            if (response != NSModalResponseOK) {
                retainedCallback->Cancel();
                return;
            }
            std::vector<CefString> paths;
            if ([panel isKindOfClass:[NSOpenPanel class]]) {
                for (NSURL* url in ((NSOpenPanel*)panel).URLs) {
                    paths.push_back(url.path.UTF8String ?: "");
                }
            } else if (panel.URL) {
                paths.push_back(panel.URL.path.UTF8String ?: "");
            }
            if (paths.empty()) {
                retainedCallback->Cancel();
            } else {
                retainedCallback->Continue(paths);
            }
        };
        NSWindow* window = NSApp.keyWindow ?: NSApp.mainWindow;
        if (window) {
            [panel beginSheetModalForWindow:window completionHandler:completion];
        } else {
            [panel beginWithCompletionHandler:completion];
        }
    });
    return true;
}

// CefJSDialogHandler

int CEFClientImpl::RetainJsDialogCallback(
    int browserId,
    CefRefPtr<CefJSDialogCallback> callback) {
    int callbackId = nextJsDialogCallbackId_;
    nextJsDialogCallbackId_ = callbackId == INT_MAX ? 1 : callbackId + 1;
    while (jsDialogCallbacks_.find(callbackId) != jsDialogCallbacks_.end()) {
        callbackId = nextJsDialogCallbackId_;
        nextJsDialogCallbackId_ = callbackId == INT_MAX ? 1 : callbackId + 1;
    }
    jsDialogCallbacks_[callbackId] = PendingJsDialog{browserId, callback};
    return callbackId;
}

void CEFClientImpl::ClearJsDialogCallbacks(int browserId) {
    for (auto it = jsDialogCallbacks_.begin(); it != jsDialogCallbacks_.end();) {
        if (it->second.browserId == browserId) {
            it = jsDialogCallbacks_.erase(it);
        } else {
            ++it;
        }
    }
}

void CEFClientImpl::ResolveJsDialog(int browserId,
                                    int callbackId,
                                    bool success,
                                    const std::string& userInput) {
    CEF_REQUIRE_UI_THREAD();
    auto it = jsDialogCallbacks_.find(callbackId);
    if (it == jsDialogCallbacks_.end() || it->second.browserId != browserId) {
        return;
    }
    CefRefPtr<CefJSDialogCallback> callback = it->second.callback;
    jsDialogCallbacks_.erase(it);
    if (callback) {
        callback->Continue(success, userInput);
    }
}

void CEFClientImpl::ClearPermissionCallbacks(int browserId) {
    for (auto it = mediaPermissionCallbacks_.begin();
         it != mediaPermissionCallbacks_.end();) {
        if (it->second.browserId == browserId) {
            it = mediaPermissionCallbacks_.erase(it);
        } else {
            ++it;
        }
    }
    for (auto it = browserPermissionCallbacks_.begin();
         it != browserPermissionCallbacks_.end();) {
        if (it->second.browserId == browserId) {
            it = browserPermissionCallbacks_.erase(it);
        } else {
            ++it;
        }
    }
}

void CEFClientImpl::ResolvePermissionPrompt(int browserId,
                                            const std::string& promptId,
                                            bool allow) {
    CEF_REQUIRE_UI_THREAD();
    auto mediaIt = mediaPermissionCallbacks_.find(promptId);
    if (mediaIt != mediaPermissionCallbacks_.end()) {
        if (mediaIt->second.browserId != browserId) return;
        PendingMediaPermission pending = mediaIt->second;
        mediaPermissionCallbacks_.erase(mediaIt);
        if (pending.callback) {
            if (allow) {
                pending.callback->Continue(pending.requestedPermissions);
            } else {
                pending.callback->Cancel();
            }
        }
        return;
    }

    auto browserIt = browserPermissionCallbacks_.find(promptId);
    if (browserIt == browserPermissionCallbacks_.end() ||
        browserIt->second.browserId != browserId) {
        return;
    }
    CefRefPtr<CefPermissionPromptCallback> callback = browserIt->second.callback;
    browserPermissionCallbacks_.erase(browserIt);
    if (callback) {
        callback->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT
                                 : CEF_PERMISSION_RESULT_DENY);
    }
}

bool CEFClientImpl::OnJSDialog(
    CefRefPtr<CefBrowser> browser,
    const CefString& origin_url,
    JSDialogType dialog_type,
    const CefString& message_text,
    const CefString& default_prompt_text,
    CefRefPtr<CefJSDialogCallback> callback,
    bool& suppress_message) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (!IsOsrBrowser(browserId) || !callback) {
        return false;
    }

    NSString* kind = @"alert";
    if (dialog_type == JSDIALOGTYPE_CONFIRM) {
        kind = @"confirm";
    } else if (dialog_type == JSDIALOGTYPE_PROMPT) {
        kind = @"prompt";
    }
    suppress_message = false;
    const int callbackId = RetainJsDialogCallback(browserId, callback);
    [delegate_ onJsDialogForCefBrowserId:browserId
                              callbackId:callbackId
                                     kind:kind
                                  message:NSStringOrEmptyFromCefString(message_text)
                            defaultPrompt:NSStringOrEmptyFromCefString(default_prompt_text)];
    return true;
}

bool CEFClientImpl::OnBeforeUnloadDialog(
    CefRefPtr<CefBrowser> browser,
    const CefString& message_text,
    bool is_reload,
    CefRefPtr<CefJSDialogCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (!IsOsrBrowser(browserId) || !callback) {
        return false;
    }
    const int callbackId = RetainJsDialogCallback(browserId, callback);
    [delegate_ onJsDialogForCefBrowserId:browserId
                              callbackId:callbackId
                                     kind:@"beforeUnload"
                                  message:NSStringOrEmptyFromCefString(message_text)
                            defaultPrompt:@""];
    return true;
}

void CEFClientImpl::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    ClearJsDialogCallbacks(browserId);
    [delegate_ onResetDialogStateForCefBrowserId:browserId];
}

// CefPermissionHandler

bool CEFClientImpl::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (browserId < 0 || !callback || requested_permissions == 0) return false;
    const std::string promptId =
        "media:" + std::to_string(browserId) + ":" +
        std::to_string(nextMediaPermissionPromptId_++);
    mediaPermissionCallbacks_[promptId] = PendingMediaPermission{
        browserId,
        requested_permissions,
        callback,
    };
    [delegate_ onPermissionPromptForCefBrowserId:browserId
                                       promptId:[NSString stringWithUTF8String:promptId.c_str()]
                                          origin:NSStringOrEmptyFromCefString(requesting_origin)
                                     permissions:MediaPermissionKinds(requested_permissions)];
    return true;
}

bool CEFClientImpl::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (browserId < 0 || !callback || requested_permissions == 0) return false;
    const std::string promptId =
        "permission:" + std::to_string(browserId) + ":" +
        std::to_string(prompt_id);
    browserPermissionCallbacks_[promptId] = PendingBrowserPermission{
        browserId,
        prompt_id,
        callback,
    };
    [delegate_ onPermissionPromptForCefBrowserId:browserId
                                       promptId:[NSString stringWithUTF8String:promptId.c_str()]
                                          origin:NSStringOrEmptyFromCefString(requesting_origin)
                                     permissions:BrowserPermissionKinds(requested_permissions)];
    return true;
}

void CEFClientImpl::OnDismissPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    cef_permission_request_result_t result) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    const std::string dartPromptId =
        "permission:" + std::to_string(browserId) + ":" +
        std::to_string(prompt_id);
    browserPermissionCallbacks_.erase(dartPromptId);
}

// CefRenderHandler

bool CEFClientImpl::GetRootScreenRect(CefRefPtr<CefBrowser> browser,
                                      CefRect& rect) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    int x = 0, y = 0, width = 0, height = 0;
    if ([delegate_ getOsrRootScreenRectForCefBrowserId:browserId
                                                     x:&x
                                                     y:&y
                                                 width:&width
                                                height:&height] != YES) {
        return false;
    }
    rect = CefRect(x, y, std::max(1, width), std::max(1, height));
    return true;
}

void CEFClientImpl::GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) {
    CEF_REQUIRE_UI_THREAD();

    const int browserId = browser ? browser->GetIdentifier() : -1;
    auto stateIt = osrViewStates_.find(browserId);
    OsrViewState state;
    if (stateIt != osrViewStates_.end()) {
        state = stateIt->second;
    } else if (!pendingOsrViewStates_.empty()) {
        state = pendingOsrViewStates_.front();
    } else {
        state.width = 800;
        state.height = 600;
        state.scaleFactor = 1.0f;
    }

    rect = CefRect(0, 0, std::max(1, state.width), std::max(1, state.height));
}

bool CEFClientImpl::GetScreenPoint(CefRefPtr<CefBrowser> browser,
                                   int viewX,
                                   int viewY,
                                   int& screenX,
                                   int& screenY) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    return [delegate_ getOsrScreenPointForCefBrowserId:browserId
                                                viewX:viewX
                                                viewY:viewY
                                              screenX:&screenX
                                              screenY:&screenY] == YES;
}

bool CEFClientImpl::GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& screen_info) {
    CEF_REQUIRE_UI_THREAD();

    const int browserId = browser ? browser->GetIdentifier() : -1;
    auto stateIt = osrViewStates_.find(browserId);
    OsrViewState state;
    if (stateIt != osrViewStates_.end()) {
        state = stateIt->second;
    } else if (!pendingOsrViewStates_.empty()) {
        // CEF can ask for screen info before OnAfterCreated maps the CEF browser
        // id back to our Flutter browser id. Use the queued create-time state so
        // the first OSR paint is Retina-scaled instead of being painted at 1x and
        // stretched by Flutter.
        state = pendingOsrViewStates_.front();
    } else {
        state.width = 800;
        state.height = 600;
        state.scaleFactor = 1.0f;
    }

    screen_info.device_scale_factor = std::max(1.0f, state.scaleFactor);
    CefRect rootRect;
    if (GetRootScreenRect(browser, rootRect)) {
        CefRefPtr<CefDisplay> display =
            CefDisplay::GetDisplayMatchingBounds(rootRect, false);
        if (display) {
            screen_info.rect = display->GetBounds();
            screen_info.available_rect = display->GetWorkArea();
        }
    }
    if (screen_info.rect.width <= 0 || screen_info.rect.height <= 0) {
        screen_info.rect = CefRect(0, 0,
                                   std::max(1, state.width),
                                   std::max(1, state.height));
    }
    if (screen_info.available_rect.width <= 0 ||
        screen_info.available_rect.height <= 0) {
        screen_info.available_rect = screen_info.rect;
    }
    if (ShouldLogPopupDebug()) {
        NSLog(@"CEFClientImpl: GetScreenInfo browserId=%d scale=%.3f screen=(%d,%d %dx%d) available=(%d,%d %dx%d)",
              browserId,
              screen_info.device_scale_factor,
              screen_info.rect.x, screen_info.rect.y,
              screen_info.rect.width, screen_info.rect.height,
              screen_info.available_rect.x, screen_info.available_rect.y,
              screen_info.available_rect.width,
              screen_info.available_rect.height);
    }
    return true;
}

namespace {

// Pixel-space union of CEF's per-frame damage list. Zero-sized result means
// "unknown damage" and consumers must fall back to a full-frame copy.
CGRect UnionOfDirtyRects(const CefRenderHandler::RectList& dirtyRects) {
    bool hasRect = false;
    int minX = 0, minY = 0, maxX = 0, maxY = 0;
    for (const CefRect& rect : dirtyRects) {
        if (rect.width <= 0 || rect.height <= 0) {
            continue;
        }
        if (!hasRect) {
            minX = rect.x;
            minY = rect.y;
            maxX = rect.x + rect.width;
            maxY = rect.y + rect.height;
            hasRect = true;
        } else {
            minX = std::min(minX, rect.x);
            minY = std::min(minY, rect.y);
            maxX = std::max(maxX, rect.x + rect.width);
            maxY = std::max(maxY, rect.y + rect.height);
        }
    }
    if (!hasRect) {
        return CGRectZero;
    }
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

NSMutableDictionary* AcceleratedPaintExtra(
    const CefAcceleratedPaintInfo& info,
    IOSurfaceRef surface) {
    NSMutableDictionary* extra =
        [NSMutableDictionary dictionaryWithCapacity:20];
    if (surface) {
        extra[@"surfaceId"] = @(IOSurfaceGetID(surface));
        extra[@"surfaceSeed"] = @(IOSurfaceGetSeed(surface));
        extra[@"surfaceBPR"] = @(IOSurfaceGetBytesPerRow(surface));
        extra[@"surfaceInUse"] = @(IOSurfaceIsInUse(surface) ? 1 : 0);
        extra[@"surfaceUseCount"] = @(IOSurfaceGetUseCount(surface));
    }
    extra[@"codedW"] = @(info.extra.coded_size.width);
    extra[@"codedH"] = @(info.extra.coded_size.height);
    extra[@"visX"] = @(info.extra.visible_rect.x);
    extra[@"visY"] = @(info.extra.visible_rect.y);
    extra[@"visW"] = @(info.extra.visible_rect.width);
    extra[@"visH"] = @(info.extra.visible_rect.height);
    extra[@"contentX"] = @(info.extra.content_rect.x);
    extra[@"contentY"] = @(info.extra.content_rect.y);
    extra[@"contentW"] = @(info.extra.content_rect.width);
    extra[@"contentH"] = @(info.extra.content_rect.height);
    extra[@"tsUs"] = @(info.extra.timestamp);
    if (info.extra.has_capture_counter) {
        extra[@"captureCounter"] = @(info.extra.capture_counter);
    }
    if (info.extra.has_capture_update_rect) {
        extra[@"updX"] = @(info.extra.capture_update_rect.x);
        extra[@"updY"] = @(info.extra.capture_update_rect.y);
        extra[@"updW"] = @(info.extra.capture_update_rect.width);
        extra[@"updH"] = @(info.extra.capture_update_rect.height);
    }
    if (info.extra.has_source_size) {
        extra[@"srcW"] = @(info.extra.source_size.width);
        extra[@"srcH"] = @(info.extra.source_size.height);
    }
    return extra;
}

}  // namespace

#if defined(CEF_ACCELERATED_FRAME_LEASE_API)
namespace {

struct AcceleratedFrameLeaseState {
    explicit AcceleratedFrameLeaseState(
        CefRefPtr<CefAcceleratedFrame> frame)
        : frame_id(frame ? frame->GetFrameId() : 0), frame(std::move(frame)) {}

    void Release() {
        CefRefPtr<CefAcceleratedFrame> retained;
        {
            std::scoped_lock lock(mutex);
            retained = frame;
            frame = nullptr;
        }
        if (retained) {
            retained->ReleaseFrame();
        }
    }

    void Abandon() {
        CefRefPtr<CefAcceleratedFrame> retained;
        {
            std::scoped_lock lock(mutex);
            retained = frame;
            frame = nullptr;
        }
        // Rejection asks CEF to invoke OnAcceleratedPaint with this same
        // resource. Drop only this wrapper's reference; the producer remains
        // responsible for releasing the frame after the legacy callback.
    }

    const uint64_t frame_id;
    std::mutex mutex;
    CefRefPtr<CefAcceleratedFrame> frame;
};

}  // namespace

@interface CEFAcceleratedFrameLease ()
- (instancetype)initWithFrame:(CefRefPtr<CefAcceleratedFrame>)frame;
- (void)abandonFrame;
@end

@implementation CEFAcceleratedFrameLease

- (instancetype)initWithFrame:(CefRefPtr<CefAcceleratedFrame>)frame {
    self = [super init];
    if (self) {
        _state = new AcceleratedFrameLeaseState(std::move(frame));
    }
    return self;
}

- (uint64_t)frameId {
    auto* state = static_cast<AcceleratedFrameLeaseState*>(_state);
    return state ? state->frame_id : 0;
}

- (void)releaseFrame {
    auto* state = static_cast<AcceleratedFrameLeaseState*>(_state);
    if (state) {
        state->Release();
    }
}

- (void)abandonFrame {
    auto* state = static_cast<AcceleratedFrameLeaseState*>(_state);
    if (state) {
        state->Abandon();
    }
}

- (void)dealloc {
    auto* state = static_cast<AcceleratedFrameLeaseState*>(_state);
    if (state) {
        state->Release();
        delete state;
        _state = nullptr;
    }
}

@end
#else
@implementation CEFAcceleratedFrameLease
- (uint64_t)frameId {
    return 0;
}
- (void)releaseFrame {
}
@end
#endif

BOOL CEFAcceleratedFrameLeaseApiAvailable(void) {
#if defined(CEF_ACCELERATED_FRAME_LEASE_API)
    return YES;
#else
    return NO;
#endif
}

void CEFClientImpl::OnPaint(CefRefPtr<CefBrowser> browser,
                            PaintElementType type,
                            const RectList& dirtyRects,
                            const void* buffer,
                            int width,
                            int height) {
    CEF_REQUIRE_UI_THREAD();
    if (!buffer || width <= 0 || height <= 0) {
        return;
    }

    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (ShouldLogResizeDebug()) {
        auto stateIt = osrViewStates_.find(browserId);
        const OsrViewState* state =
            stateIt != osrViewStates_.end() ? &stateIt->second : nullptr;
        NSLog(@"CEFClientImpl: CEF_RESIZE_DEBUG paint=cpu browserId=%d requested=%dx%d scale=%.3f incoming=%dx%d sourceBytesPerRow=%zu",
              browserId,
              state ? state->width : 0,
              state ? state->height : 0,
              state ? state->scaleFactor : 0.0f,
              width, height, (size_t)width * 4);
    }
    [delegate_ onOsrPaintForCefBrowserId:browserId
                                     type:static_cast<int>(type)
                                   buffer:buffer
                                    width:width
                                   height:height
                                dirtyRect:UnionOfDirtyRects(dirtyRects)];
    if (type == PET_VIEW && osrPopupVisible_[browserId] &&
        browser && browser->GetHost()) {
        // cefclient does the same: popup widgets can otherwise miss their
        // first paint or disappear behind a newer view frame.
        browser->GetHost()->Invalidate(PET_POPUP);
    }
}

void CEFClientImpl::OnAcceleratedPaint(
    CefRefPtr<CefBrowser> browser,
    PaintElementType type,
    const RectList& dirtyRects,
    const CefAcceleratedPaintInfo& info) {
    CEF_REQUIRE_UI_THREAD();
    if (!info.shared_texture_io_surface) {
        return;
    }
    // CEF promises the surface for the callback, but a long-blocked UI thread
    // followed by admission fallback reproduced the producer releasing it
    // between consecutive IOSurface accessors. Pin it across all metadata
    // reads and the synchronous delegate handoff.
    IOSurfaceRef surface = (IOSurfaceRef)info.shared_texture_io_surface;
    CFRetain(surface);

    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (ShouldLogResizeDebug()) {
        auto stateIt = osrViewStates_.find(browserId);
        const OsrViewState* state =
            stateIt != osrViewStates_.end() ? &stateIt->second : nullptr;
        NSLog(@"CEFClientImpl: CEF_RESIZE_DEBUG paint=accelerated browserId=%d requested=%dx%d scale=%.3f incoming=%zux%zu bytesPerRow=%zu coded=%dx%d visible=(%d,%d %dx%d)",
              browserId,
              state ? state->width : 0,
              state ? state->height : 0,
              state ? state->scaleFactor : 0.0f,
              IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface),
              IOSurfaceGetBytesPerRow(surface),
              info.extra.coded_size.width, info.extra.coded_size.height,
              info.extra.visible_rect.x, info.extra.visible_rect.y,
              info.extra.visible_rect.width, info.extra.visible_rect.height);
    }
    NSMutableDictionary* extra = AcceleratedPaintExtra(info, surface);
    [delegate_ onAcceleratedOsrPaintForCefBrowserId:browserId
                                               type:static_cast<int>(type)
                                          ioSurface:surface
                                             format:static_cast<int>(info.format)
                                          dirtyRect:UnionOfDirtyRects(dirtyRects)
                                              extra:extra];
    if (type == PET_VIEW && osrPopupVisible_[browserId] &&
        browser && browser->GetHost()) {
        browser->GetHost()->Invalidate(PET_POPUP);
    }
    CFRelease(surface);
}

#if defined(CEF_ACCELERATED_FRAME_LEASE_API)
bool CEFClientImpl::OnAcceleratedFrame(
    CefRefPtr<CefBrowser> browser,
    PaintElementType type,
    const RectList& dirtyRects,
    const CefAcceleratedPaintInfo& info,
    CefRefPtr<CefAcceleratedFrame> frame) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (acceleratedFrameLeaseEnabled_.find(browserId) ==
            acceleratedFrameLeaseEnabled_.end() ||
        type != PET_VIEW || !frame || !info.shared_texture_io_surface) {
        return false;
    }
    IOSurfaceRef surface = (IOSurfaceRef)info.shared_texture_io_surface;
    CFRetain(surface);

    CEFAcceleratedFrameLease* lease =
        [[CEFAcceleratedFrameLease alloc] initWithFrame:frame];
    NSMutableDictionary* extra = AcceleratedPaintExtra(info, surface);
    extra[@"frameId"] = @(lease.frameId);
    const BOOL accepted =
        [delegate_ onLeasedAcceleratedOsrFrameForCefBrowserId:browserId
                                                         type:static_cast<int>(type)
                                                    ioSurface:surface
                                                       format:static_cast<int>(info.format)
                                                    dirtyRect:UnionOfDirtyRects(dirtyRects)
                                                        extra:extra
                                                        lease:lease];
    if (!accepted) {
        // CEF immediately follows a rejected lease with OnAcceleratedPaint
        // for the same frame. Do not return the IOSurface to the producer
        // before that fallback callback has consumed it.
        [lease abandonFrame];
    }
    CFRelease(surface);
    return accepted == YES;
}
#endif

void CEFClientImpl::OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (ShouldLogPopupDebug()) {
        NSLog(@"CEFClientImpl: OnPopupShow browserId=%d show=%d",
              browserId, show ? 1 : 0);
    }
    if (show) {
        osrPopupVisible_[browserId] = true;
    } else {
        osrPopupVisible_.erase(browserId);
    }
    [delegate_ onOsrPopupShowForCefBrowserId:browserId show:show ? YES : NO];
    if (browser && browser->GetHost()) {
        // Showing a popup disables direct frame leasing because the popup is
        // composited into an embedder-owned view buffer. Force that fallback
        // view frame immediately; hiding also needs a clean base frame.
        browser->GetHost()->Invalidate(PET_VIEW);
    }
}

void CEFClientImpl::OnPopupSize(CefRefPtr<CefBrowser> browser,
                                const CefRect& rect) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (ShouldLogPopupDebug()) {
        NSLog(@"CEFClientImpl: OnPopupSize browserId=%d rect=(%d,%d %dx%d)",
              browserId, rect.x, rect.y, rect.width, rect.height);
    }
    [delegate_ onOsrPopupSizeForCefBrowserId:browserId
                                        rect:CGRectMake(rect.x, rect.y,
                                                        rect.width, rect.height)];
    if (browser && browser->GetHost()) {
        browser->GetHost()->Invalidate(PET_POPUP);
    }
}

bool CEFClientImpl::StartDragging(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefDragData> drag_data,
                                  CefRenderHandler::DragOperationsMask allowed_ops,
                                  int x,
                                  int y) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    return [delegate_ onOsrStartDraggingForCefBrowserId:browserId
                                                dragData:drag_data
                                              allowedOps:static_cast<int>(allowed_ops)
                                                       x:x
                                                       y:y] == YES;
}

void CEFClientImpl::UpdateDragCursor(CefRefPtr<CefBrowser> browser,
                                     CefRenderHandler::DragOperation operation) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    [delegate_ onOsrUpdateDragCursorForCefBrowserId:browserId
                                          operation:static_cast<int>(operation)];
}

void CEFClientImpl::OnImeCompositionRangeChanged(
    CefRefPtr<CefBrowser> browser,
    const CefRange& selected_range,
    const RectList& character_bounds) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (!IsOsrBrowser(browserId)) {
        return;
    }
    (void)selected_range;
    CGRect caretRect = CGRectZero;
    if (!character_bounds.empty()) {
        const CefRect& rect = character_bounds.front();
        caretRect = CGRectMake(rect.x, rect.y, rect.width, rect.height);
    }
    [delegate_ onImeCompositionRangeChangedForCefBrowserId:browserId
                                                  caretRect:caretRect];
}

void CEFClientImpl::OnVirtualKeyboardRequested(
    CefRefPtr<CefBrowser> browser,
    TextInputMode input_mode) {
    CEF_REQUIRE_UI_THREAD();
    const int browserId = browser ? browser->GetIdentifier() : -1;
    if (!IsOsrBrowser(browserId)) {
        return;
    }
    [delegate_ onTextInputStateChangedForCefBrowserId:browserId
                                             editable:input_mode != CEF_TEXT_INPUT_MODE_NONE];
}
