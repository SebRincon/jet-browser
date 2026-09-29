// Adapted from vten lib/widgets/vten/features/chat/widgets/prompt_input.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: the input card, 13px field, stop square, and footer row are
// kept. Attachments, slash commands, modes, pinpoint, priming, and cloud send
// are omitted. Enter sends and Shift+Enter inserts a newline. Meta/Ctrl+Enter
// still sends. Enter is ignored during an IME composition. The focus ring
// listens on the host FocusNode. The source handler only special-cases
// Meta/Ctrl+Enter.

import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class _SendIntent extends Intent {
  const _SendIntent();
}

class _SendAction extends Action<_SendIntent> {
  _SendAction({required this.allow, required this.send});

  final bool Function() allow;
  final VoidCallback send;

  @override
  bool consumesKey(_SendIntent intent) => allow();

  @override
  Object? invoke(_SendIntent intent) {
    if (allow()) send();
    return null;
  }
}

class EnhancedPromptInput extends StatefulWidget {
  const EnhancedPromptInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onStop,
    this.onTap,
    this.busy = false,
    this.cancelling = false,
    this.enabled = true,
    this.footer,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback? onTap;
  final bool busy;
  final bool cancelling;
  final bool enabled;
  final Widget? footer;

  @override
  State<EnhancedPromptInput> createState() => _EnhancedPromptInputState();
}

class _EnhancedPromptInputState extends State<EnhancedPromptInput> {
  bool get _imeComposing {
    final range = widget.controller.value.composing;
    return range.isValid && !range.isCollapsed;
  }

  void _send() {
    if (_imeComposing) return;
    if (widget.busy || widget.cancelling || !widget.enabled) return;
    if (widget.controller.text.trim().isEmpty) return;
    widget.onSend();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed || _imeComposing) {
      return KeyEventResult.ignored;
    }
    _send();
    return KeyEventResult.handled;
  }

  void _bindFocus(FocusNode node) {
    node.addListener(_changed);
    node.onKeyEvent = _onKey;
  }

  void _unbindFocus(FocusNode node) {
    node.removeListener(_changed);
    if (node.onKeyEvent == _onKey) node.onKeyEvent = null;
  }

  @override
  void initState() {
    super.initState();
    _bindFocus(widget.focusNode);
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant EnhancedPromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _unbindFocus(oldWidget.focusNode);
      _bindFocus(widget.focusNode);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _unbindFocus(widget.focusNode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final focused = widget.focusNode.hasFocus;
    final canSend = widget.enabled &&
        !widget.busy &&
        !widget.cancelling &&
        widget.controller.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.input,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: focused ? theme.colorScheme.ring : theme.colorScheme.border,
              width: focused ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
                    SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        _SendIntent(),
                    SingleActivator(LogicalKeyboardKey.enter, control: true):
                        _SendIntent(),
                  },
                  child: Actions(
                    actions: {
                      _SendIntent: _SendAction(
                        allow: () => !_imeComposing,
                        send: _send,
                      ),
                    },
                    child: material.TextField(
                      key: const ValueKey('chat-composer'),
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      enabled: widget.enabled && !widget.cancelling,
                      onTap: widget.onTap,
                      minLines: 1,
                      maxLines: 10,
                      keyboardType: material.TextInputType.multiline,
                      style: material.TextStyle(
                        color: theme.colorScheme.foreground,
                        fontSize: 13,
                        height: 1.5,
                      ),
                      cursorColor: theme.colorScheme.foreground,
                      decoration: material.InputDecoration(
                        border: material.InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        hintText: widget.cancelling
                            ? 'Cancelling...'
                            : 'Enter prompt...',
                        hintStyle: material.TextStyle(
                          color: theme.colorScheme.mutedForeground,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                child: widget.busy
                    ? Semantics(
                        button: true,
                        label: 'Stop',
                        child: DestructiveButton(
                          key: const ValueKey('chat-stop'),
                          size: ButtonSize.small,
                          onPressed: widget.cancelling || !widget.enabled
                              ? null
                              : widget.onStop,
                          child: widget.cancelling
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(),
                                )
                              : const Icon(LucideIcons.square, size: 16),
                        ),
                      )
                    : PrimaryButton(
                        key: const ValueKey('chat-send'),
                        size: ButtonSize.small,
                        onPressed: canSend ? _send : null,
                        child: const Text('Send'),
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (widget.footer != null)
          Align(alignment: Alignment.centerLeft, child: widget.footer!),
      ],
    );
  }
}
