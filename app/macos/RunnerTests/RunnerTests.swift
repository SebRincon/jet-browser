import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {

  func testOsrContainerDoesNotInterceptFlutterTextureClicks() throws {
    let containerClass = try XCTUnwrap(
      NSClassFromString("CefOsrContainerView") as? NSView.Type
    )
    let container = containerClass.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

    XCTAssertNil(container.hitTest(NSPoint(x: 50, y: 50)))
  }

}
