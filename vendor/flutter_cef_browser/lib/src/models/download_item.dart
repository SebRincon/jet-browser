/// Download status enumeration
enum DownloadStatus {
  started,
  inProgress,
  paused,
  completed,
  cancelled,
  failed,
}

/// Represents a download item with progress tracking
class DownloadItem {
  final int downloadId;
  final int browserId;
  final String url;
  final String filename;
  final String mimeType;
  final int totalBytes;
  final int receivedBytes;
  final int percentComplete;
  final int speed; // bytes per second
  final String? fullPath;
  final DownloadStatus status;
  final String? errorMessage;

  /// Alias for downloadId
  int get id => downloadId;

  /// Progress as a fraction (0.0 to 1.0)
  double get progress => totalBytes > 0 ? receivedBytes / totalBytes : 0.0;

  const DownloadItem({
    required this.downloadId,
    required this.browserId,
    required this.url,
    required this.filename,
    this.mimeType = '',
    this.totalBytes = 0,
    this.receivedBytes = 0,
    this.percentComplete = 0,
    this.speed = 0,
    this.fullPath,
    this.status = DownloadStatus.started,
    this.errorMessage,
  });

  DownloadItem copyWith({
    int? downloadId,
    int? browserId,
    String? url,
    String? filename,
    String? mimeType,
    int? totalBytes,
    int? receivedBytes,
    int? percentComplete,
    int? speed,
    String? fullPath,
    DownloadStatus? status,
    String? errorMessage,
  }) {
    return DownloadItem(
      downloadId: downloadId ?? this.downloadId,
      browserId: browserId ?? this.browserId,
      url: url ?? this.url,
      filename: filename ?? this.filename,
      mimeType: mimeType ?? this.mimeType,
      totalBytes: totalBytes ?? this.totalBytes,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      percentComplete: percentComplete ?? this.percentComplete,
      speed: speed ?? this.speed,
      fullPath: fullPath ?? this.fullPath,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  factory DownloadItem.fromMap(Map<String, dynamic> map) {
    final typeStr = map['type'] as String? ?? 'started';
    DownloadStatus status;
    switch (typeStr) {
      case 'started':
        status = DownloadStatus.started;
        break;
      case 'progress':
        status = DownloadStatus.inProgress;
        break;
      case 'completed':
        status = DownloadStatus.completed;
        break;
      case 'cancelled':
        status = DownloadStatus.cancelled;
        break;
      case 'failed':
        status = DownloadStatus.failed;
        break;
      case 'paused':
        status = DownloadStatus.paused;
        break;
      default:
        status = DownloadStatus.started;
    }

    return DownloadItem(
      downloadId: map['downloadId'] as int,
      browserId: map['browserId'] as int,
      url: map['url'] as String? ?? '',
      filename: map['filename'] as String? ?? '',
      mimeType: map['mimeType'] as String? ?? '',
      totalBytes: map['totalBytes'] as int? ?? 0,
      receivedBytes: map['receivedBytes'] as int? ?? 0,
      percentComplete: map['percentComplete'] as int? ?? 0,
      speed: map['speed'] as int? ?? 0,
      fullPath: map['fullPath'] as String?,
      status: status,
      errorMessage: map['errorMessage'] as String?,
    );
  }

  /// Formatted speed string (e.g., "1.5 MB/s")
  String get formattedSpeed {
    if (speed < 1024) {
      return '$speed B/s';
    } else if (speed < 1024 * 1024) {
      return '${(speed / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(speed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
  }

  /// Formatted size string
  String get formattedSize {
    if (totalBytes < 1024) {
      return '$totalBytes B';
    } else if (totalBytes < 1024 * 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    } else if (totalBytes < 1024 * 1024 * 1024) {
      return '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(totalBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  @override
  String toString() {
    return 'DownloadItem(id: $downloadId, filename: $filename, status: $status, progress: $percentComplete%)';
  }
}
