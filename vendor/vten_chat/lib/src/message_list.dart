// Adapted from vten lib/widgets/vten/features/chat/widgets/message_list.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: groups are host widgets. Codex review, compaction, and the
// debug crosshair are omitted. Scroll offsets stay per session. Follow uses
// jumpTo so a growing stream does not leave a catch-up animation; Latest
// still animates to the reverse-list origin. Pinned-prompt geometry follows
// the source: the mounted group spanning the viewport top, only after its
// user row has left the top, and a tap scrolls that row back under the padding.

import 'package:flutter/scheduler.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class MessageListGroup {
  const MessageListGroup({
    required this.id,
    required this.child,
    this.userRow,
    this.pinText,
  });

  final String id;
  final Widget child;

  /// User bubble measured for the pinned prompt. Null when the group has none.
  final Widget? userRow;

  /// First line of [userRow], shown in the overlay.
  final String? pinText;
}

class MessageList extends StatefulWidget {
  const MessageList({
    super.key,
    required this.sessionId,
    required this.groups,
    required this.contentVersion,
  });

  static const scrollViewKey = ValueKey('vten-message-list-scroll-view');
  static const scrollToBottomButtonKey = ValueKey('jump-to-latest');
  static const pinnedPromptKey = ValueKey('vten-message-list-pinned-prompt');
  static const double contentColumnMaxWidth = 672;
  static const double _pinnedSpanThreshold = 48;

  final String? sessionId;
  final List<MessageListGroup> groups;
  final String contentVersion;

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, double> _positions = {};
  final Map<String, bool> _autoBySession = {};
  final Map<String, GlobalKey> _groupGeometryKeys = {};
  final Map<String, GlobalKey> _userRowKeys = {};
  bool _isAtBottom = true;
  bool _hasScrollableContent = false;
  bool _shouldAutoScroll = true;
  bool _programmatic = false;
  bool _pinCheckScheduled = false;
  String? _sessionId;
  int _motionEpoch = 0;
  ({String groupId, String text})? _pinned;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _remember(oldWidget.sessionId);
      _sessionId = widget.sessionId;
      final captured = widget.sessionId;
      final epoch = ++_motionEpoch;
      final remembered = captured == null ? null : _positions[captured];
      final auto = captured == null
          ? true
          : (_autoBySession[captured] ?? remembered == null);
      _shouldAutoScroll = auto;
      if (_scrollController.hasClients &&
          _scrollController.position.isScrollingNotifier.value) {
        _scrollController.jumpTo(_scrollController.position.pixels);
      }
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        if (epoch != _motionEpoch || widget.sessionId != captured) return;
        final target = remembered ?? 0.0;
        final clamped =
            target.clamp(0.0, _scrollController.position.maxScrollExtent);
        _programmatic = true;
        _scrollController.jumpTo(clamped);
        _programmatic = false;
        final atBottom = clamped <= 56;
        setState(() {
          _isAtBottom = atBottom;
          _shouldAutoScroll = atBottom || auto;
          _pinned = null;
        });
        if (captured != null) _autoBySession[captured] = _shouldAutoScroll;
        _schedulePinnedPromptCheck();
      });
    } else if (oldWidget.contentVersion != widget.contentVersion &&
        _shouldAutoScroll) {
      final captured = widget.sessionId;
      final version = widget.contentVersion;
      final epoch = ++_motionEpoch;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        if (epoch != _motionEpoch || widget.sessionId != captured) return;
        if (widget.contentVersion != version || !_shouldAutoScroll) return;
        if (_scrollController.position.pixels <= 1) return;
        _programmatic = true;
        _scrollController.jumpTo(0);
        _programmatic = false;
      });
    }
  }

  void _remember(String? sessionId) {
    if (sessionId == null || !_scrollController.hasClients) return;
    _positions[sessionId] = _scrollController.position.pixels;
    _autoBySession[sessionId] = _shouldAutoScroll;
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final atBottom = _scrollController.position.pixels <= 56;
    final session = _sessionId;
    if (session != null) {
      _positions[session] = _scrollController.position.pixels;
    }
    if (!_programmatic && !atBottom) {
      _shouldAutoScroll = false;
      if (session != null) _autoBySession[session] = false;
    } else if (atBottom) {
      _shouldAutoScroll = true;
      if (session != null) _autoBySession[session] = true;
    }
    if (atBottom != _isAtBottom && mounted) {
      setState(() => _isAtBottom = atBottom);
    }
    _checkScrollable();
    _schedulePinnedPromptCheck();
  }

  void _checkScrollable() {
    if (!_scrollController.hasClients) return;
    final has = _scrollController.position.maxScrollExtent > 0;
    if (has != _hasScrollableContent && mounted) {
      setState(() => _hasScrollableContent = has);
    }
  }

  Future<void> _scrollToBottom() async {
    if (!_scrollController.hasClients) return;
    final captured = widget.sessionId;
    final epoch = ++_motionEpoch;
    _programmatic = true;
    _shouldAutoScroll = true;
    final distance = _scrollController.position.pixels.abs();
    final duration = Duration(
      milliseconds: (420 + distance * 0.08).clamp(420, 680).round(),
    );
    await _scrollController.animateTo(
      0,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
    if (!mounted || epoch != _motionEpoch || widget.sessionId != captured) {
      return;
    }
    setState(() {
      _isAtBottom = true;
      _programmatic = false;
    });
  }

  void _schedulePinnedPromptCheck() {
    if (_pinCheckScheduled) return;
    _pinCheckScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pinCheckScheduled = false;
      if (!mounted) return;
      final next = _computePinnedPrompt();
      final current = _pinned;
      if (next?.groupId == current?.groupId && next?.text == current?.text) {
        return;
      }
      setState(() => _pinned = next);
    });
  }

  /// Pure geometry: pin the prompt of whichever group spans the top edge of
  /// the viewport once that group's real user-message row has scrolled off
  /// above the edge. Only mounted groups are measured.
  ({String groupId, String text})? _computePinnedPrompt() {
    if (!_scrollController.hasClients || !_hasScrollableContent) return null;
    final listRenderObject = context.findRenderObject();
    if (listRenderObject is! RenderBox || !listRenderObject.hasSize) {
      return null;
    }
    String? spanningGroupId;
    for (final entry in _groupGeometryKeys.entries) {
      final groupContext = entry.value.currentContext;
      if (groupContext == null) continue;
      final box = groupContext.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: listRenderObject).dy;
      final bottom = top + box.size.height;
      if (top <= 0.5 && bottom > MessageList._pinnedSpanThreshold) {
        spanningGroupId = entry.key;
        break;
      }
    }
    if (spanningGroupId == null) return null;
    final text = _pinTextFor(spanningGroupId);
    if (text == null) return null;
    final rowContext = _userRowKeys[spanningGroupId]?.currentContext;
    final rowBox = rowContext?.findRenderObject();
    if (rowBox is! RenderBox || !rowBox.attached || !rowBox.hasSize) {
      return null;
    }
    final rowBottom =
        rowBox.localToGlobal(Offset.zero, ancestor: listRenderObject).dy +
            rowBox.size.height;
    if (rowBottom > 0.5) return null;
    return (groupId: spanningGroupId, text: text);
  }

  String? _pinTextFor(String groupId) {
    for (final group in widget.groups) {
      if (group.id != groupId) continue;
      final text = group.pinText?.trim();
      if (text == null || text.isEmpty || group.userRow == null) return null;
      return text;
    }
    return null;
  }

  /// Tap on the pinned bubble: animate so the group's real user message lands
  /// just below the top edge (mirrors the list's 8px content padding).
  void _scrollToPinnedPrompt(String groupId) {
    if (!_scrollController.hasClients) return;
    final captured = widget.sessionId;
    final epoch = ++_motionEpoch;
    final listRenderObject = context.findRenderObject();
    final rowContext = _userRowKeys[groupId]?.currentContext;
    final rowBox = rowContext?.findRenderObject();
    if (listRenderObject is! RenderBox ||
        rowBox is! RenderBox ||
        !rowBox.attached ||
        !rowBox.hasSize) {
      return;
    }
    final rowTop =
        rowBox.localToGlobal(Offset.zero, ancestor: listRenderObject).dy;
    final padding = 8.0 * Theme.of(context).scaling;
    final target = (_scrollController.position.pixels + (padding - rowTop))
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _programmatic = true;
    _scrollController
        .animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
        )
        .whenComplete(() {
      if (!mounted || epoch != _motionEpoch || widget.sessionId != captured) {
        return;
      }
      _programmatic = false;
      _schedulePinnedPromptCheck();
    });
  }

  void _syncGeometryKeys(Set<String> ids) {
    _groupGeometryKeys.removeWhere((id, _) => !ids.contains(id));
    _userRowKeys.removeWhere((id, _) => !ids.contains(id));
    for (final id in ids) {
      _groupGeometryKeys.putIfAbsent(id, GlobalKey.new);
      _userRowKeys.putIfAbsent(id, GlobalKey.new);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reversed = widget.groups.reversed.toList(growable: false);
    _syncGeometryKeys(widget.groups.map((group) => group.id).toSet());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkScrollable();
      _schedulePinnedPromptCheck();
    });
    final list = ListView.separated(
      key: MessageList.scrollViewKey,
      reverse: true,
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.all(8.0 * theme.scaling),
      itemCount: reversed.length,
      shrinkWrap: !_hasScrollableContent,
      cacheExtent: 1000,
      findItemIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final index = reversed.indexWhere((group) => group.id == key.value);
        if (index < 0) return null;
        return index;
      },
      separatorBuilder: (context, index) => Gap(8 * theme.scaling),
      itemBuilder: (context, index) {
        final group = reversed[index];
        return KeyedSubtree(
          key: ValueKey<String>(group.id),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: MessageList.contentColumnMaxWidth,
              ),
              child: Column(
                key: _groupGeometryKeys[group.id],
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (group.userRow != null)
                    KeyedSubtree(
                      key: _userRowKeys[group.id],
                      child: group.userRow!,
                    ),
                  if (group.userRow != null) const SizedBox(height: 8),
                  group.child,
                ],
              ),
            ),
          ),
        );
      },
    );
    final bare = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: list,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: _hasScrollableContent
              ? bare
              : Align(alignment: Alignment.topCenter, child: bare),
        ),
        Positioned(
          top: 8.0 * theme.scaling,
          left: 0,
          right: 0,
          child: _PinnedPromptOverlay(
            text: _pinned?.text,
            onTap: _pinned == null
                ? null
                : () => _scrollToPinnedPrompt(_pinned!.groupId),
          ),
        ),
        if (_hasScrollableContent && !_isAtBottom)
          Positioned(
            right: 16 * theme.scaling,
            bottom: 16 * theme.scaling,
            child: _ScrollToBottomButton(
              key: MessageList.scrollToBottomButtonKey,
              onPressed: _scrollToBottom,
            ),
          ),
      ],
    );
  }
}

class _PinnedPromptOverlay extends StatelessWidget {
  const _PinnedPromptOverlay({required this.text, required this.onTap});

  final String? text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (text == null) {
      return const SizedBox.shrink(key: ValueKey('pinned-prompt-none'));
    }
    final bubbleColor = Color.alphaBlend(
      theme.colorScheme.input.scaleAlpha(0.3),
      theme.colorScheme.background,
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 8.0 * theme.scaling),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: MessageList.contentColumnMaxWidth,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Container(
                  key: MessageList.pinnedPromptKey,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    border: Border.all(color: theme.colorScheme.border),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.background,
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Text(
                    text!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.colorScheme.foreground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScrollToBottomButton extends StatefulWidget {
  const _ScrollToBottomButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<_ScrollToBottomButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = Semantics(
      button: true,
      label: 'Latest',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedScale(
            scale: _pressed ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _hovered
                    ? theme.colorScheme.accent
                    : theme.colorScheme.background,
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.border),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.background.withValues(alpha: 0.1),
                    blurRadius: 6,
                    spreadRadius: -1,
                    offset: const Offset(0, 4),
                  ),
                  BoxShadow(
                    color: theme.colorScheme.background.withValues(alpha: 0.1),
                    blurRadius: 4,
                    spreadRadius: -2,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                LucideIcons.chevronDown,
                size: 16,
                color: theme.colorScheme.foreground,
              ),
            ),
          ),
        ),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
        ),
      ),
      child: button,
    );
  }
}
