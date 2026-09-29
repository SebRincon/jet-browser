import 'dart:convert';
import 'dart:io';

/// Only this loopback client sees the installation token; pages never receive it.
class SidecarApi {
  SidecarApi(this.token, {this.port = 9148});
  final String token;
  final int port;
  final HttpClient _client = HttpClient();

  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('http://127.0.0.1:$port$path');
    final request = await _client
        .openUrl(body == null ? 'GET' : 'POST', uri)
        .timeout(const Duration(seconds: 5));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 35));
    final text = await utf8.decoder.bind(response).join();
    final data = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    if (response.statusCode >= 400) {
      throw StateError(data is Map
          ? '${data['error'] ?? data['detail'] ?? response.statusCode}'
          : 'Sidecar returned ${response.statusCode}');
    }
    return data is Map ? Map<String, dynamic>.from(data) : {};
  }

  void close() => _client.close(force: true);
}
