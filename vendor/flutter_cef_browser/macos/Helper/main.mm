// Helper process entry point for CEF multi-process mode on macOS.
//
// This executable is launched by CEF as the browser subprocess (renderer/gpu/utility).
// It must call CefExecuteProcess() and exit with the returned code.

#import <Cocoa/Cocoa.h>

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  @autoreleasepool {
    // Load the CEF framework from the main app bundle.
    CefScopedLibraryLoader library_loader;
    if (!library_loader.LoadInHelper()) {
      NSLog(@"flutter_cef_browser Helper: Failed to load CEF library");
      return 1;
    }

    CefMainArgs main_args(argc, argv);
    const int exit_code = CefExecuteProcess(main_args, nullptr, nullptr);
    return exit_code;
  }
}

