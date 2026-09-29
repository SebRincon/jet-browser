import 'package:flutter/foundation.dart';

enum CefRuntimeIssueSeverity { warning, failure }

class CefRuntimeIssue {
  const CefRuntimeIssue({
    required this.code,
    required this.severity,
    required this.message,
    this.details = const <String, dynamic>{},
  });

  final String code;
  final CefRuntimeIssueSeverity severity;
  final String message;
  final Map<String, dynamic> details;

  bool get isFailure => severity == CefRuntimeIssueSeverity.failure;
  bool get isWarning => severity == CefRuntimeIssueSeverity.warning;

  Map<String, Object?> toMap() => <String, Object?>{
        'code': code,
        'severity': severity.name,
        'message': message,
        'details': details,
      };

  factory CefRuntimeIssue.fromMap(Map<dynamic, dynamic> map) {
    final severityName = map['severity'] as String? ?? 'warning';
    return CefRuntimeIssue(
      code: map['code'] as String? ?? 'unknown_issue',
      severity: severityName == CefRuntimeIssueSeverity.failure.name
          ? CefRuntimeIssueSeverity.failure
          : CefRuntimeIssueSeverity.warning,
      message: map['message'] as String? ?? '',
      details: _stringKeyedMap(map['details']),
    );
  }
}

@immutable
class CefRuntimeConfig {
  const CefRuntimeConfig({
    required this.cachePath,
    required this.rootCachePath,
    required this.chromeRuntime,
    required this.extensionPaths,
    required this.cefProfile,
    required this.profileSwitches,
    required this.extraSwitches,
    required this.removeSwitches,
    required this.closePolicy,
    required this.gracefulCloseTimeoutMs,
    required this.messagePumpMode,
    required this.maxPumpDelayMs,
    required this.enableMessagePumpFallbackTimer,
    required this.deterministicCreate,
    required this.deterministicCreateTimeoutMs,
    required this.requireHelper,
    required this.useMockKeychain,
    this.enableWindowlessRendering = false,
    required this.launchMode,
    required this.remoteDebuggingPort,
    required this.logFilePath,
    required this.crashDumpsPath,
    required this.uncaughtExceptionStackSize,
    this.userAgent,
  });

  final String cachePath;
  final String rootCachePath;
  final String? userAgent;
  final bool chromeRuntime;
  final List<String> extensionPaths;
  final String cefProfile;
  final Map<String, String?> profileSwitches;
  final Map<String, String?> extraSwitches;
  final List<String> removeSwitches;
  final String closePolicy;
  final int gracefulCloseTimeoutMs;
  final String messagePumpMode;
  final int maxPumpDelayMs;
  final bool enableMessagePumpFallbackTimer;
  final bool deterministicCreate;
  final int deterministicCreateTimeoutMs;
  final bool requireHelper;
  final bool useMockKeychain;
  final bool enableWindowlessRendering;
  final String launchMode;
  final int remoteDebuggingPort;
  final String logFilePath;
  final String crashDumpsPath;
  final int uncaughtExceptionStackSize;

  Map<String, Object?> toMap() => <String, Object?>{
        'cachePath': cachePath,
        'rootCachePath': rootCachePath,
        if (userAgent != null && userAgent!.isNotEmpty) 'userAgent': userAgent,
        'chromeRuntime': chromeRuntime,
        'extensionPaths': extensionPaths,
        'cefProfile': cefProfile,
        'profileSwitches': profileSwitches,
        'extraSwitches': extraSwitches,
        'removeSwitches': removeSwitches,
        'closePolicy': closePolicy,
        'gracefulCloseTimeoutMs': gracefulCloseTimeoutMs,
        'messagePumpMode': messagePumpMode,
        'maxPumpDelayMs': maxPumpDelayMs,
        'enableMessagePumpFallbackTimer': enableMessagePumpFallbackTimer,
        'deterministicCreate': deterministicCreate,
        'deterministicCreateTimeoutMs': deterministicCreateTimeoutMs,
        'requireHelper': requireHelper,
        'useMockKeychain': useMockKeychain,
        'enableWindowlessRendering': enableWindowlessRendering,
        'launchMode': launchMode,
        'remoteDebuggingPort': remoteDebuggingPort,
        'logFilePath': logFilePath,
        'crashDumpsPath': crashDumpsPath,
        'uncaughtExceptionStackSize': uncaughtExceptionStackSize,
      };

  factory CefRuntimeConfig.fromMap(Map<dynamic, dynamic> map) {
    return CefRuntimeConfig(
      cachePath: map['cachePath'] as String? ?? '',
      rootCachePath: map['rootCachePath'] as String? ?? '',
      userAgent: map['userAgent'] as String?,
      chromeRuntime: map['chromeRuntime'] as bool? ?? false,
      extensionPaths: _stringList(map['extensionPaths']),
      cefProfile: map['cefProfile'] as String? ?? 'prod-safe',
      profileSwitches: _nullableStringMap(map['profileSwitches']),
      extraSwitches: _nullableStringMap(map['extraSwitches']),
      removeSwitches: _stringList(map['removeSwitches']),
      closePolicy: map['closePolicy'] as String? ?? 'graceful_then_force',
      gracefulCloseTimeoutMs:
          (map['gracefulCloseTimeoutMs'] as num?)?.toInt() ?? 1200,
      messagePumpMode:
          map['messagePumpMode'] as String? ?? 'cef_sample_compatible',
      maxPumpDelayMs: (map['maxPumpDelayMs'] as num?)?.toInt() ?? 33,
      enableMessagePumpFallbackTimer:
          map['enableMessagePumpFallbackTimer'] as bool? ?? true,
      deterministicCreate: map['deterministicCreate'] as bool? ?? false,
      deterministicCreateTimeoutMs:
          (map['deterministicCreateTimeoutMs'] as num?)?.toInt() ?? 5000,
      requireHelper: map['requireHelper'] as bool? ?? true,
      useMockKeychain: map['useMockKeychain'] as bool? ?? false,
      enableWindowlessRendering:
          map['enableWindowlessRendering'] as bool? ?? false,
      launchMode: map['launchMode'] as String? ?? 'unknown',
      remoteDebuggingPort: (map['remoteDebuggingPort'] as num?)?.toInt() ?? 0,
      logFilePath: map['logFilePath'] as String? ?? '',
      crashDumpsPath: map['crashDumpsPath'] as String? ?? '',
      uncaughtExceptionStackSize:
          (map['uncaughtExceptionStackSize'] as num?)?.toInt() ?? 10,
    );
  }
}

class CefRuntimePreflightReport {
  const CefRuntimePreflightReport({
    required this.status,
    required this.source,
    required this.capturedAt,
    required this.config,
    required this.warnings,
    required this.failures,
    this.native = const <String, dynamic>{},
  });

  final String status;
  final String source;
  final DateTime capturedAt;
  final CefRuntimeConfig? config;
  final List<CefRuntimeIssue> warnings;
  final List<CefRuntimeIssue> failures;
  final Map<String, dynamic> native;

  bool get hasFailures => failures.isNotEmpty;

  List<CefRuntimeIssue> get issues =>
      List<CefRuntimeIssue>.unmodifiable(<CefRuntimeIssue>[
        ...warnings,
        ...failures,
      ]);

  Map<String, Object?> toMap() => <String, Object?>{
        'status': status,
        'source': source,
        'capturedAt': capturedAt.toIso8601String(),
        if (config != null) 'config': config!.toMap(),
        'warnings': warnings.map((issue) => issue.toMap()).toList(),
        'failures': failures.map((issue) => issue.toMap()).toList(),
        'native': native,
      };

  factory CefRuntimePreflightReport.fromMap(Map<dynamic, dynamic> map) {
    final rawWarnings = map['warnings'] as List? ?? const <Object?>[];
    final rawFailures = map['failures'] as List? ?? const <Object?>[];
    final rawConfig = map['config'];
    final capturedAtRaw = map['capturedAt'] as String?;
    return CefRuntimePreflightReport(
      status: map['status'] as String? ?? 'unknown',
      source: map['source'] as String? ?? 'unknown',
      capturedAt: DateTime.tryParse(capturedAtRaw ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      config: rawConfig is Map ? CefRuntimeConfig.fromMap(rawConfig) : null,
      warnings: rawWarnings
          .whereType<Map>()
          .map(CefRuntimeIssue.fromMap)
          .toList(growable: false),
      failures: rawFailures
          .whereType<Map>()
          .map(CefRuntimeIssue.fromMap)
          .toList(growable: false),
      native: _stringKeyedMap(map['native']),
    );
  }

  static CefRuntimePreflightReport empty({
    required String source,
    CefRuntimeConfig? config,
  }) {
    return CefRuntimePreflightReport(
      status: 'ok',
      source: source,
      capturedAt: DateTime.now(),
      config: config,
      warnings: const <CefRuntimeIssue>[],
      failures: const <CefRuntimeIssue>[],
    );
  }
}

class CefInitializeResult {
  const CefInitializeResult({
    required this.success,
    this.failureCode,
    this.failureStage,
    this.message,
    this.preflightReport,
    this.details = const <String, dynamic>{},
  });

  final bool success;
  final String? failureCode;
  final String? failureStage;
  final String? message;
  final CefRuntimePreflightReport? preflightReport;
  final Map<String, dynamic> details;

  factory CefInitializeResult.fromMethodChannelResult(Object? value) {
    if (value is Map) {
      return CefInitializeResult.fromMap(value);
    }
    if (value is bool) {
      return value
          ? const CefInitializeResult(success: true)
          : const CefInitializeResult(
              success: false,
              failureCode: 'initialize_returned_false',
              failureStage: 'method_channel',
            );
    }
    return const CefInitializeResult(
      success: false,
      failureCode: 'initialize_result_unavailable',
      failureStage: 'method_channel',
    );
  }

  factory CefInitializeResult.fromMap(Map<dynamic, dynamic> map) {
    final rawReport = map['preflightReport'];
    return CefInitializeResult(
      success: map['success'] as bool? ?? false,
      failureCode: map['failureCode'] as String?,
      failureStage: map['failureStage'] as String?,
      message: map['message'] as String?,
      preflightReport: rawReport is Map
          ? CefRuntimePreflightReport.fromMap(rawReport)
          : null,
      details: _stringKeyedMap(map['details']),
    );
  }
}

typedef CefPreflightIssueSeverity = CefRuntimeIssueSeverity;
typedef CefPreflightIssue = CefRuntimeIssue;
typedef CefPreflightReport = CefRuntimePreflightReport;

Map<String, dynamic> _stringKeyedMap(Object? value) {
  if (value is! Map) {
    return const <String, dynamic>{};
  }
  return value.map(
    (key, entryValue) => MapEntry(key.toString(), entryValue),
  );
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .map((entry) => entry?.toString() ?? '')
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
}

Map<String, String?> _nullableStringMap(Object? value) {
  if (value is! Map) {
    return const <String, String?>{};
  }
  return value.map((key, entryValue) {
    final normalizedValue = entryValue?.toString();
    return MapEntry(key.toString(), normalizedValue);
  });
}
