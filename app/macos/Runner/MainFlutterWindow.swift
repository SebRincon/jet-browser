import Cocoa
import FlutterMacOS

/// Cmd+L / Cmd+T / Cmd+R never reach Flutter once the CEF view is first
/// responder. Handle the exact chords on this key window and forward them once.
class MainFlutterWindow: NSWindow {
  private var flutterViewController: FlutterViewController?
  private var shortcutChannel: FlutterMethodChannel?
  private var keyMonitor: Any?
  private var forwardedShortcut: (TimeInterval, UInt16)?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.flutterViewController = flutterViewController
    contentViewController = flutterViewController
    setContentSize(NSSize(width: 1400, height: 940))
    minSize = NSSize(width: 980, height: 780)
    title = "Jet Browser"
    center()
    RegisterGeneratedPlugins(registry: flutterViewController)
    shortcutChannel = FlutterMethodChannel(
      name: "jet_browser/shell_shortcuts",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    super.awakeFromNib()
    installKeyMonitor()
  }

  override func becomeKey() {
    super.becomeKey()
    // Re-register last so this monitor runs before a CEF local monitor.
    installKeyMonitor()
  }

  override func resignKey() {
    removeKeyMonitor()
    super.resignKey()
  }

  override func close() {
    removeKeyMonitor()
    shortcutChannel = nil
    flutterViewController = nil
    super.close()
  }

  /// Command-key events are offered to the key window before the CEF view's
  /// keyDown / OnPreKeyEvent. Returning true keeps the chord out of Chromium.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if consumeShellShortcut(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  private func installKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.consumeShellShortcut(event) else { return event }
      return nil
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
  }

  /// Returns true when [event] is an exact shell chord and has been forwarded.
  private func consumeShellShortcut(_ event: NSEvent) -> Bool {
    guard event.window === self, isKeyWindow, NSApp.isActive else { return false }
    guard event.type == .keyDown, !event.isARepeat else { return false }
    let flags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    guard flags == .command else { return false }
    guard let raw = event.charactersIgnoringModifiers?.lowercased(), raw.count == 1 else {
      return false
    }
    if forwardedShortcut?.0 == event.timestamp && forwardedShortcut?.1 == event.keyCode {
      return true
    }
    let action: String
    switch raw {
    case "l":
      action = "selectAddress"
      focusFlutter()
    case "t":
      action = "newTab"
    case "r":
      action = "reload"
    default:
      return false
    }
    forwardedShortcut = (event.timestamp, event.keyCode)
    shortcutChannel?.invokeMethod("shortcut", arguments: action)
    if action == "selectAddress" {
      DispatchQueue.main.async { [weak self] in self?.focusFlutter() }
    }
    return true
  }

  private func focusFlutter() {
    guard let view = flutterViewController?.view else { return }
    makeFirstResponder(view)
  }
}
