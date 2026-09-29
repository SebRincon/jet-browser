/// Network request type
enum NetworkEventType {
  requestWillBeSent,
  responseReceived,
  loadingFinished,
  loadingFailed,
}

/// Request timing information
class RequestTiming {
  final double dnsStart;
  final double dnsEnd;
  final double connectStart;
  final double connectEnd;
  final double sslStart;
  final double sslEnd;
  final double sendStart;
  final double sendEnd;
  final double receiveHeadersEnd;

  const RequestTiming({
    this.dnsStart = -1,
    this.dnsEnd = -1,
    this.connectStart = -1,
    this.connectEnd = -1,
    this.sslStart = -1,
    this.sslEnd = -1,
    this.sendStart = -1,
    this.sendEnd = -1,
    this.receiveHeadersEnd = -1,
  });

  factory RequestTiming.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const RequestTiming();
    return RequestTiming(
      dnsStart: (map['dnsStart'] as num?)?.toDouble() ?? -1,
      dnsEnd: (map['dnsEnd'] as num?)?.toDouble() ?? -1,
      connectStart: (map['connectStart'] as num?)?.toDouble() ?? -1,
      connectEnd: (map['connectEnd'] as num?)?.toDouble() ?? -1,
      sslStart: (map['sslStart'] as num?)?.toDouble() ?? -1,
      sslEnd: (map['sslEnd'] as num?)?.toDouble() ?? -1,
      sendStart: (map['sendStart'] as num?)?.toDouble() ?? -1,
      sendEnd: (map['sendEnd'] as num?)?.toDouble() ?? -1,
      receiveHeadersEnd: (map['receiveHeadersEnd'] as num?)?.toDouble() ?? -1,
    );
  }

  /// Total duration in milliseconds
  double get totalDuration {
    if (receiveHeadersEnd < 0 || dnsStart < 0) return -1;
    return receiveHeadersEnd - dnsStart;
  }
}

/// Represents a network request/response
class NetworkRequest {
  final int browserId;
  final NetworkEventType type;
  final String requestId;
  final String url;
  final String method;
  final String resourceType;
  final double timestamp;

  // Request fields
  final Map<String, String>? requestHeaders;

  // Response fields
  final int? status;
  final String? statusText;
  final String? mimeType;
  final Map<String, String>? headers;
  final RequestTiming? timing;

  // Error fields
  final String? errorText;
  final bool? canceled;

  // Size info
  final int? encodedDataLength;

  const NetworkRequest({
    required this.browserId,
    required this.type,
    required this.requestId,
    required this.url,
    this.method = 'GET',
    this.resourceType = 'Other',
    required this.timestamp,
    this.requestHeaders,
    this.status,
    this.statusText,
    this.mimeType,
    this.headers,
    this.timing,
    this.errorText,
    this.canceled,
    this.encodedDataLength,
  });

  factory NetworkRequest.fromMap(Map<String, dynamic> map) {
    final typeStr = map['type'] as String? ?? 'requestWillBeSent';
    NetworkEventType type;
    switch (typeStr) {
      case 'requestWillBeSent':
        type = NetworkEventType.requestWillBeSent;
        break;
      case 'responseReceived':
        type = NetworkEventType.responseReceived;
        break;
      case 'loadingFinished':
        type = NetworkEventType.loadingFinished;
        break;
      case 'loadingFailed':
        type = NetworkEventType.loadingFailed;
        break;
      default:
        type = NetworkEventType.requestWillBeSent;
    }

    return NetworkRequest(
      browserId: map['browserId'] as int,
      type: type,
      requestId: map['requestId'] as String,
      url: map['url'] as String? ?? '',
      method: map['method'] as String? ?? 'GET',
      resourceType: map['resourceType'] as String? ?? 'Other',
      timestamp: (map['timestamp'] as num?)?.toDouble() ?? 0.0,
      requestHeaders: map['requestHeaders'] is Map
          ? (map['requestHeaders'] as Map).cast<String, String>()
          : null,
      status: map['status'] as int?,
      statusText: map['statusText'] as String?,
      mimeType: map['mimeType'] as String?,
      headers: map['headers'] is Map
          ? (map['headers'] as Map).cast<String, String>()
          : null,
      timing: map['timing'] is Map
          ? RequestTiming.fromMap(
              Map<String, dynamic>.from(map['timing'] as Map))
          : null,
      errorText: map['errorText'] as String?,
      canceled: map['canceled'] as bool?,
      encodedDataLength: map['encodedDataLength'] as int?,
    );
  }

  DateTime get dateTime {
    return DateTime.fromMillisecondsSinceEpoch((timestamp * 1000).toInt());
  }

  /// Get status code color category
  String get statusCategory {
    if (status == null) return 'pending';
    if (status! >= 200 && status! < 300) return 'success';
    if (status! >= 300 && status! < 400) return 'redirect';
    if (status! >= 400 && status! < 500) return 'clientError';
    if (status! >= 500) return 'serverError';
    return 'other';
  }

  @override
  String toString() {
    return 'NetworkRequest($method $url, status: $status)';
  }
}
