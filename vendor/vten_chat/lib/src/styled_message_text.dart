import 'package:flutter/foundation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

bool messageDebug = false;

class StyledMessageText extends StatelessWidget {
  final String text;
  final TextStyle? baseStyle;
  final Set<String>?
  validAttachmentKeys; // Optional: if provided, only style these specific attachments

  const StyledMessageText({
    super.key,
    required this.text,
    this.baseStyle,
    this.validAttachmentKeys,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultStyle =
        baseStyle ??
        TextStyle(color: theme.colorScheme.foreground, fontSize: 14);

    if (messageDebug) {
      debugPrint('=== StyledMessageText DEBUG START ===');
      debugPrint('Input text: "$text"');
      debugPrint('validAttachmentKeys: $validAttachmentKeys');
    }

    // This finds @mentions and /commands more precisely
    final List<InlineSpan> spans = [];

    // If we have valid attachment keys, find their exact positions in the text
    final List<RegExpMatch> allMatches = [];

    if (validAttachmentKeys != null && validAttachmentKeys!.isNotEmpty) {
      // Look for exact matches of known attachment keys
      for (final key in validAttachmentKeys!) {
        // Escape special regex characters in the key
        final escapedKey = RegExp.escape(key);
        final keyPattern = RegExp(escapedKey);
        allMatches.addAll(keyPattern.allMatches(text));
      }
      if (messageDebug) {
        debugPrint('Found ${allMatches.length} exact attachment matches');
      }
    }
    // If no valid attachment keys, don't style anything
    // This prevents random text like @testshit from being styled

    // Sort matches by position
    allMatches.sort((a, b) => a.start.compareTo(b.start));

    int lastIndex = 0;
    for (final match in allMatches) {
      // Add text before the match
      if (match.start > lastIndex) {
        spans.add(
          TextSpan(
            text: text.substring(lastIndex, match.start),
            style: defaultStyle,
          ),
        );
      }

      // Add the attachment as styled text
      final attachmentText = match.group(0)!;
      if (messageDebug) {
        debugPrint(
          'Processing match: "$attachmentText" at position ${match.start}-${match.end}',
        );
      }

      if (messageDebug) {
        // We only process real attachments now, so always style them
        debugPrint('  Styling attachment: "$attachmentText"');
      }

      spans.add(
        TextSpan(
          text: attachmentText,
          style: defaultStyle.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      );

      lastIndex = match.end;
    }

    // Add remaining text after the last match
    if (lastIndex < text.length) {
      spans.add(TextSpan(text: text.substring(lastIndex), style: defaultStyle));
    }
    if (messageDebug) {
      debugPrint('Total spans created: ${spans.length}');
      debugPrint('=== StyledMessageText DEBUG END ===');
    }

    // If no attachments were found, just return a simple Text widget.
    if (spans.isEmpty) {
      return SelectableText(text, style: defaultStyle);
    }

    return SelectableText.rich(TextSpan(children: spans));
  }
}
