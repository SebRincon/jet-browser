//
//  CefDragParticipantView.h
//  flutter_cef_browser
//
//  Non-rendering AppKit view that gives a windowless (OSR) CEF browser a
//  native drag-and-drop presence: it starts outbound NSDraggingSessions for
//  CEF StartDragging callbacks and forwards inbound dragging-destination
//  events back to CEF. It never handles regular mouse events — unhandled
//  events bubble to the Flutter view through the responder chain.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CefDragParticipantView;

@protocol CefDragParticipantViewDelegate <NSObject>
- (NSDragOperation)dragParticipantEntered:(id<NSDraggingInfo>)info
                                browserId:(int)browserId;
- (NSDragOperation)dragParticipantUpdated:(id<NSDraggingInfo>)info
                                browserId:(int)browserId;
- (void)dragParticipantExited:(nullable id<NSDraggingInfo>)info
                    browserId:(int)browserId;
- (BOOL)dragParticipantPerformDrop:(id<NSDraggingInfo>)info
                         browserId:(int)browserId;
- (void)dragParticipantSessionEndedAtScreenPoint:(NSPoint)screenPoint
                                       operation:(NSDragOperation)operation
                                       browserId:(int)browserId;
// Fulfils an outbound file-promise by writing the dragged file contents.
- (void)dragParticipantWriteFilePromiseToURL:(NSURL*)url
                                   browserId:(int)browserId
                           completionHandler:(void (^)(NSError* _Nullable))handler;
@end

@interface CefDragParticipantView
    : NSView <NSDraggingSource, NSFilePromiseProviderDelegate>

- (instancetype)initWithBrowserId:(int)browserId
                         delegate:(id<CefDragParticipantViewDelegate>)delegate;

@property(nonatomic, readonly) int browserId;
@property(nonatomic, readonly) BOOL hasActiveSession;

/// Pasteboard types offered by the current/most recently ended session.
@property(nonatomic, copy, readonly) NSArray<NSPasteboardType>* offeredPasteboardTypes;

/// Allowed source operations for the in-flight outbound session.
@property(nonatomic, assign) NSDragOperation sourceOperationMask;

/// Operation CEF most recently reported via UpdateDragCursor; returned from
/// draggingUpdated so intra-page drags show the right cursor.
@property(nonatomic, assign) NSDragOperation currentCefOperation;

/// Suggested filename for the current outbound file promise, if any.
@property(nonatomic, copy, nullable) NSString* promiseFileName;

/// Starts an outbound drag session with prepared pasteboard items.
- (BOOL)beginDragSessionWithItems:(NSArray<NSDraggingItem*>*)items
                            event:(NSEvent*)event;

/// Cancels bookkeeping for an in-flight session (browser teardown).
- (void)abandonSession;

@end

NS_ASSUME_NONNULL_END
