import 'dart:convert';
import 'package:flutter_cef_browser/flutter_cef_browser.dart';

/// Private authenticated sidecar requests mapped to the exact in-process CEF tab.
/// Input preserves Chromium protocol coordinates, key commands and ordering.
/// There is no remote debugging listener or unrestricted protocol passthrough.
class NativeBridge {
  Future<Map<String, dynamic>> execute(CefBrowserController browser,
      String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'Runtime.evaluate':
        final expression = params['expression'] as String;
        final encoded = await browser.evaluateJavaScript(
          '(async () => { const value = await ($expression); '
          'return JSON.stringify(value === undefined ? {type: "undefined"} '
          ': {type: typeof value, value}); })()',
        );
        if (encoded == null) {
          throw StateError('Evaluation returned no envelope');
        }
        return {'result': jsonDecode(encoded)};
      case 'Page.captureScreenshot':
        return {
          'data': await browser.captureViewportScreenshot(
            format: params['format'] as String? ?? 'jpeg',
            quality: params['quality'] as int? ?? 85,
          )
        };
      case 'Page.navigate':
        await browser.loadUrl(params['url'] as String);
      case 'Input.insertText' ||
            'Input.dispatchMouseEvent' ||
            'Input.dispatchKeyEvent':
        await browser.dispatchInput(method, params);
      default:
        throw UnsupportedError('Unsupported native command: $method');
    }
    return {};
  }
}
