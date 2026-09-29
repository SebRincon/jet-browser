//
//  CefDragParticipantView.mm
//  flutter_cef_browser
//

#import "CefDragParticipantView.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static BOOL ShouldLogDragDebug(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char* value = getenv("CEF_DRAG_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

@implementation CefDragParticipantView {
    __weak id<CefDragParticipantViewDelegate> _delegate;
    BOOL _sessionActive;
    NSArray<NSPasteboardType>* _offeredPasteboardTypes;
}

- (instancetype)initWithBrowserId:(int)browserId
                         delegate:(id<CefDragParticipantViewDelegate>)delegate {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _browserId = browserId;
        _delegate = delegate;
        _sessionActive = NO;
        _offeredPasteboardTypes = @[];
        _sourceOperationMask = NSDragOperationEvery;
        _currentCefOperation = NSDragOperationCopy;
        self.wantsLayer = NO;
        [self registerForDraggedTypes:@[
            NSPasteboardTypeFileURL,
            NSPasteboardTypeURL,
            NSPasteboardTypeString,
            NSPasteboardTypeHTML,
            NSPasteboardTypeTIFF,
            NSPasteboardTypePNG,
            NSPasteboardTypeRTF,
        ]];
    }
    return self;
}

- (BOOL)hasActiveSession {
    return _sessionActive;
}

// Frames arrive in the Flutter view's flipped (top-left) coordinate space;
// keeping this view flipped makes browser-view and local coordinates match
// with no conversion.
- (BOOL)isFlipped {
    return YES;
}

// Completely transparent to regular mouse hit-testing. Being the hit-test
// target and bubbling events up the responder chain crashed the host: the
// IDE's custom window event routing re-entered Flutter's scroll pipeline and
// tripped an engine NSAssert (see spec 016 research D5). Dragging-destination
// tracking does not use this override — AppKit walks views registered via
// registerForDraggedTypes by geometry — so inbound drops still arrive.
- (NSView*)hitTest:(NSPoint)point {
    return nil;
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return NO;
}

- (BOOL)beginDragSessionWithItems:(NSArray<NSDraggingItem*>*)items
                            event:(NSEvent*)event {
    if (_sessionActive || items.count == 0 || !event) {
        return NO;
    }
    NSDraggingSession* session = [self beginDraggingSessionWithItems:items
                                                               event:event
                                                              source:self];
    if (!session) {
        return NO;
    }
    session.animatesToStartingPositionsOnCancelOrFail = YES;
    _offeredPasteboardTypes = session.draggingPasteboard.types ?: @[];
    _sessionActive = YES;
    if (ShouldLogDragDebug()) {
        NSLog(@"CEFDrag: session started browserId=%d sourceMask=0x%lx types=%@",
              _browserId, (unsigned long)_sourceOperationMask,
              _offeredPasteboardTypes);
    }
    return YES;
}

- (void)abandonSession {
    _sessionActive = NO;
}

#pragma mark - NSDraggingSource

- (NSDragOperation)draggingSession:(NSDraggingSession*)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    NSDragOperation operationMask = _sourceOperationMask;
    if (context == NSDraggingContextOutsideApplication) {
        // Cross-app drags are copies/links; never let another app "move"
        // content out of the page.
        operationMask &=
            (NSDragOperationCopy | NSDragOperationLink | NSDragOperationGeneric);
    }
    if (ShouldLogDragDebug()) {
        NSLog(@"CEFDrag: session source mask browserId=%d context=%ld configured=0x%lx returned=0x%lx types=%@",
              _browserId, (long)context, (unsigned long)_sourceOperationMask,
              (unsigned long)operationMask, session.draggingPasteboard.types);
    }
    return operationMask;
}

- (void)draggingSession:(NSDraggingSession*)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    _sessionActive = NO;
    [_delegate dragParticipantSessionEndedAtScreenPoint:screenPoint
                                              operation:operation
                                              browserId:_browserId];
}

#pragma mark - NSDraggingDestination

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    id<CefDragParticipantViewDelegate> delegate = _delegate;
    if (!delegate) return NSDragOperationNone;
    return [delegate dragParticipantEntered:sender browserId:_browserId];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    id<CefDragParticipantViewDelegate> delegate = _delegate;
    if (!delegate) return NSDragOperationNone;
    return [delegate dragParticipantUpdated:sender browserId:_browserId];
}

- (void)draggingExited:(nullable id<NSDraggingInfo>)sender {
    [_delegate dragParticipantExited:sender browserId:_browserId];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    id<CefDragParticipantViewDelegate> delegate = _delegate;
    if (!delegate) return NO;
    return [delegate dragParticipantPerformDrop:sender browserId:_browserId];
}

#pragma mark - NSFilePromiseProviderDelegate

- (NSString*)filePromiseProvider:(NSFilePromiseProvider*)filePromiseProvider
                 fileNameForType:(NSString*)fileType {
    return self.promiseFileName.length > 0 ? self.promiseFileName : @"download";
}

- (void)filePromiseProvider:(NSFilePromiseProvider*)filePromiseProvider
          writePromiseToURL:(NSURL*)url
          completionHandler:(void (^)(NSError* _Nullable))completionHandler {
    id<CefDragParticipantViewDelegate> delegate = _delegate;
    if (!delegate) {
        completionHandler([NSError errorWithDomain:NSCocoaErrorDomain
                                              code:NSFileWriteUnknownError
                                          userInfo:nil]);
        return;
    }
    [delegate dragParticipantWriteFilePromiseToURL:url
                                         browserId:_browserId
                                 completionHandler:completionHandler];
}

@end
