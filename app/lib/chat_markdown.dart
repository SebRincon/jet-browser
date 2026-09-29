import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:markdown_widget/markdown_widget.dart' as md;
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Vten's markdown_widget renderer pattern, with Jet's own Shadcn surfaces.
/// Links are handed to the app-owned browser; the package's external launcher
/// is never used. Markdown cannot run code or silently fetch inline images.
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown({super.key, required this.text, required this.onOpenLink});
  final String text;
  final ValueChanged<String> onOpenLink;

  void _open(String href) {
    final uri = Uri.tryParse(href);
    if (uri != null &&
        ['https', 'http'].contains(uri.scheme) &&
        uri.host.isNotEmpty) {
      onOpenLink(uri.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final body = TextStyle(
        fontFamily: 'GeistSans',
        package: 'shadcn_flutter',
        fontSize: 14,
        height: 1.5,
        color: colors.foreground);
    final headingLarge =
        body.copyWith(fontSize: 16, height: 1.4, fontWeight: FontWeight.w600);
    final headingSmall = headingLarge.copyWith(fontSize: 14);
    final config = md.MarkdownConfig(configs: [
      md.PConfig(textStyle: body),
      md.H1Config(style: headingLarge),
      md.H2Config(style: headingLarge),
      md.H3Config(style: headingSmall),
      md.H4Config(style: headingSmall),
      md.H5Config(style: headingSmall),
      md.H6Config(style: headingSmall),
      const md.ListConfig(marginLeft: 24, marginBottom: 5),
      md.LinkConfig(
          style: const TextStyle(
              color: Color(0xFF60A5FA),
              decoration: TextDecoration.underline,
              decorationColor: Color(0xFF60A5FA)),
          onTap: _open),
      md.CodeConfig(
          style: TextStyle(
              fontFamily: 'GeistMono',
              package: 'shadcn_flutter',
              fontSize: 13,
              color: colors.primary,
              backgroundColor: colors.background)),
      md.PreConfig(
          builder: (code, language) => ChatCodeBlock(
              code: code, language: language, key: ValueKey(code))),
      md.BlockquoteConfig(
          sideColor: colors.primary,
          textColor: colors.mutedForeground,
          sideWith: 3,
          padding: const EdgeInsets.fromLTRB(16, 4, 0, 4)),
      md.HrConfig(height: 1, color: colors.border),
      md.TableConfig(
          border: TableBorder.all(color: colors.border),
          headerRowDecoration: BoxDecoration(color: colors.muted),
          headerStyle: body.copyWith(fontWeight: FontWeight.w600),
          bodyStyle: body,
          headPadding: const EdgeInsets.all(10),
          bodyPadding: const EdgeInsets.all(10),
          wrapper: (table) => SingleChildScrollView(
              scrollDirection: Axis.horizontal, child: table)),
      md.ImgConfig(
          builder: (url, attributes) => OutlineButton(
              size: ButtonSize.small,
              leading: const Icon(LucideIcons.image, size: 16),
              onPressed: () => _open(url),
              child: Text(attributes['alt']?.isNotEmpty == true
                  ? attributes['alt']!
                  : 'Open image'))),
    ]);
    return SelectionArea(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children:
                md.MarkdownGenerator().buildWidgets(text, config: config)));
  }
}

class ChatCodeBlock extends StatefulWidget {
  const ChatCodeBlock({super.key, required this.code, required this.language});
  final String code;
  final String language;
  @override
  State<ChatCodeBlock> createState() => _ChatCodeBlockState();
}

class _ChatCodeBlockState extends State<ChatCodeBlock> {
  bool copied = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = TextStyle(
        fontFamily: 'GeistMono',
        package: 'shadcn_flutter',
        fontSize: 13,
        height: 1.6);
    // Unknown fence languages still render safely as plain, selectable code.
    List<InlineSpan> spans;
    try {
      spans = md.highLightSpans(widget.code,
          language: widget.language,
          textStyle: style,
          styleNotMatched: TextStyle(color: colors.foreground),
          theme: {
            'keyword': TextStyle(color: colors.primary),
            'string': const TextStyle(color: Color(0xffe9ce97)),
            'number': const TextStyle(color: Color(0xffb9cfff)),
            'comment': TextStyle(color: colors.mutedForeground),
            'built_in': const TextStyle(color: Color(0xffb9cfff)),
          });
    } catch (_) {
      spans = [TextSpan(text: widget.code.trimRight())];
    }
    return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 5, bottom: 13),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: colors.muted.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
              padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
              decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.border))),
              child: Row(children: [
                Text(widget.language.isEmpty ? 'Code' : widget.language,
                    style:
                        TextStyle(fontSize: 12, color: colors.mutedForeground)),
                const Spacer(),
                GhostButton(
                    size: ButtonSize.small,
                    leading: Icon(copied ? LucideIcons.check : LucideIcons.copy,
                        size: 14),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: widget.code));
                      if (mounted) setState(() => copied = true);
                    },
                    child: Text(copied ? 'Copied' : 'Copy',
                        style: const TextStyle(fontSize: 12))),
              ])),
          Padding(
              padding: const EdgeInsets.all(14),
              child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text.rich(TextSpan(
                      style: style.copyWith(color: colors.foreground),
                      children: spans)))),
        ]));
  }
}
