/// High-performance native CEF browser integration for Flutter macOS.
///
/// This library provides a native CEF (Chromium Embedded Framework) browser
/// with direct GPU rendering, offering Chrome-level performance in Flutter apps.
library flutter_cef_browser;

// Main API
export 'src/cef_manager.dart';
export 'src/cef_browser_controller.dart';
export 'src/automation/cef_browser_automation.dart';

// Models
export 'src/models/browser_state.dart';
export 'src/models/download_item.dart';
export 'src/models/console_entry.dart';
export 'src/models/network_request.dart';
export 'src/models/cef_runtime_contract.dart';
export 'src/models/cef_render_backend.dart';
export 'src/models/cef_osr_frame_transfer_mode.dart';
export 'src/models/cef_osr_performance_stats.dart';
export 'src/models/cef_parity_event.dart';
