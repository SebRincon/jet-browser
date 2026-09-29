/// Represents the current state of a browser instance
class BrowserState {
  final int browserId;
  final String url;
  final String title;
  final bool isLoading;
  final bool canGoBack;
  final bool canGoForward;
  final double loadProgress;
  final List<String> faviconUrls;
  final int findMatchCount;
  final int findActiveMatchOrdinal;
  final bool isAudible;

  const BrowserState({
    required this.browserId,
    this.url = '',
    this.title = '',
    this.isLoading = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.loadProgress = 0.0,
    this.faviconUrls = const [],
    this.findMatchCount = 0,
    this.findActiveMatchOrdinal = 0,
    this.isAudible = false,
  });

  BrowserState copyWith({
    int? browserId,
    String? url,
    String? title,
    bool? isLoading,
    bool? canGoBack,
    bool? canGoForward,
    double? loadProgress,
    List<String>? faviconUrls,
    int? findMatchCount,
    int? findActiveMatchOrdinal,
    bool? isAudible,
  }) {
    return BrowserState(
      browserId: browserId ?? this.browserId,
      url: url ?? this.url,
      title: title ?? this.title,
      isLoading: isLoading ?? this.isLoading,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      loadProgress: loadProgress ?? this.loadProgress,
      faviconUrls: faviconUrls ?? this.faviconUrls,
      findMatchCount: findMatchCount ?? this.findMatchCount,
      findActiveMatchOrdinal:
          findActiveMatchOrdinal ?? this.findActiveMatchOrdinal,
      isAudible: isAudible ?? this.isAudible,
    );
  }

  factory BrowserState.fromMap(Map<String, dynamic> map) {
    return BrowserState(
      browserId: map['browserId'] as int,
      url: map['url'] as String? ?? '',
      title: map['title'] as String? ?? '',
      isLoading: map['isLoading'] as bool? ?? false,
      canGoBack: map['canGoBack'] as bool? ?? false,
      canGoForward: map['canGoForward'] as bool? ?? false,
      loadProgress: (map['loadProgress'] as num?)?.toDouble() ?? 0.0,
      faviconUrls: (map['faviconUrls'] as List?)?.cast<String>() ?? [],
      findMatchCount: map['findMatchCount'] as int? ?? 0,
      findActiveMatchOrdinal: map['findActiveMatchOrdinal'] as int? ?? 0,
      isAudible: map['isAudible'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    return 'BrowserState(id: $browserId, url: $url, title: $title, loading: $isLoading)';
  }
}

/// Represents a load error
class LoadError {
  final int browserId;
  final int errorCode;
  final String errorText;
  final String failedUrl;

  const LoadError({
    required this.browserId,
    required this.errorCode,
    required this.errorText,
    required this.failedUrl,
  });

  factory LoadError.fromMap(Map<String, dynamic> map) {
    return LoadError(
      browserId: map['browserId'] as int,
      errorCode: map['errorCode'] as int,
      errorText: map['errorText'] as String? ?? '',
      failedUrl: map['url'] as String? ?? '',
    );
  }
}
