/// Console log level
enum ConsoleLevel {
  debug,
  info,
  warning,
  error,
}

/// Represents a console log entry from the browser
class ConsoleEntry {
  final int browserId;
  final ConsoleLevel level;
  final String message;
  final String source;
  final int line;
  final double timestamp;

  const ConsoleEntry({
    required this.browserId,
    required this.level,
    required this.message,
    this.source = '',
    this.line = 0,
    required this.timestamp,
  });

  factory ConsoleEntry.fromMap(Map<String, dynamic> map) {
    final levelStr = map['level'] as String? ?? 'info';
    ConsoleLevel level;
    switch (levelStr) {
      case 'debug':
        level = ConsoleLevel.debug;
        break;
      case 'warning':
        level = ConsoleLevel.warning;
        break;
      case 'error':
        level = ConsoleLevel.error;
        break;
      default:
        level = ConsoleLevel.info;
    }

    return ConsoleEntry(
      browserId: map['browserId'] as int,
      level: level,
      message: map['message'] as String? ?? '',
      source: map['source'] as String? ?? '',
      line: map['line'] as int? ?? 0,
      timestamp: (map['timestamp'] as num?)?.toDouble() ?? 0.0,
    );
  }

  DateTime get dateTime {
    return DateTime.fromMillisecondsSinceEpoch((timestamp * 1000).toInt());
  }

  @override
  String toString() {
    return '[$level] $message';
  }
}
