import 'package:flutter/material.dart' as material;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:vten_chat/vten_chat.dart';

Widget host(Widget child) {
  final theme = ThemeData(
      colorScheme: vten2026DarkScheme(),
      radius: 0.5,
      typography: const Typography.geist());
  return ShadcnApp(
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      home: Scaffold(child: child));
}

void main() {
  test('2026 dark tokens match the copied workbench map', () {
    final colors = vten2026DarkScheme();
    expect(colors.background, const Color(0xff121314));
    expect(colors.foreground, const Color(0xffbfbfbf));
    expect(colors.sidebar, const Color(0xff191a1b));
    expect(colors.primary, const Color(0xff297aa0));
  });

  testWidgets('session tab is transcript, divider, and an 8px composer',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = material.TextEditingController();
    final focus = material.FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(host(SizedBox(
        width: 720,
        height: 640,
        child: ChatSessionTab(
            messageList: MessageList(
                sessionId: 's',
                contentVersion: '1',
                groups: const [
                  MessageListGroup(id: 'g', child: Text('Hello'))
                ]),
            prompt: EnhancedPromptInput(
                controller: controller,
                focusNode: focus,
                onSend: () {},
                onStop: () {})))));
    await tester.pumpAndSettle();
    expect(find.byType(MessageList), findsOneWidget);
    expect(find.byType(EnhancedPromptInput), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    final padding = tester.widget<Padding>(find.descendant(
        of: find.byType(ChatSessionTab), matching: find.byType(Padding)).first);
    expect(padding.padding, const EdgeInsets.all(8));
    expect(
        tester
            .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
            .any((box) => box.constraints.maxWidth == 672),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact tool row expands and a failure stays visible',
      (tester) async {
    await tester.pumpWidget(host(VtenChatUiConfig(
        data: const VtenChatUiConfigData(
            compactToolCalls: true,
            compactStyle: VtenChatUiCompactStyle.vten),
        child: const SizedBox(
            width: 420,
            child: ToolCallActionWrapper(
                summary: ChatToolSummary(
                    title: 'Browser task failed', detail: 'Tab disappeared'),
                failed: true,
                child: Text('full error'))))));
    await tester.pumpAndSettle();
    expect(find.byType(VcodeCompactToolCallRow), findsOneWidget);
    expect(find.byIcon(LucideIcons.badgeAlert), findsOneWidget);
    expect(find.text('full error'), findsNothing);
    await tester.tap(find.byType(VcodeCompactToolCallRow));
    await tester.pumpAndSettle();
    expect(find.text('full error'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsible steps and the running indicator', (tester) async {
    await tester.pumpWidget(host(const Column(children: [
      TurnActivityIndicator(busy: true),
      CollapsibleStepsWidget(stepsCount: 2, summary: 'read', children: [
        Text('hidden step'),
      ]),
    ])));
    await tester.pump();
    expect(find.byType(DotMatrixLoader), findsOneWidget);
    expect(find.text('hidden step'), findsNothing);
    await tester.tap(find.textContaining('2 steps'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('hidden step'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shift-enter does not send and enter does', (tester) async {
    var sent = 0;
    final controller = material.TextEditingController(text: 'Hi');
    final focus = material.FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(host(EnhancedPromptInput(
        controller: controller,
        focusNode: focus,
        onSend: () => sent++,
        onStop: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-composer')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(sent, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(sent, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus ring updates without a host rebuild and IME enter does not send',
      (tester) async {
    var sent = 0;
    final controller = material.TextEditingController(text: 'ni');
    final focus = material.FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(host(EnhancedPromptInput(
        controller: controller,
        focusNode: focus,
        onSend: () => sent++,
        onStop: () {})));
    await tester.pump();
    double composerBorder() {
      final match = tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer)).where((box) {
        final decoration = box.decoration;
        return decoration is BoxDecoration &&
            decoration.borderRadius == BorderRadius.circular(10);
      });
      final decoration = match.single.decoration! as BoxDecoration;
      return (decoration.border! as Border).top.width;
    }

    focus.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(composerBorder(), 1.5);

    focus.unfocus();
    await tester.pump();
    await tester.pump();
    expect(composerBorder(), 1);

    controller.value = const material.TextEditingValue(
      text: 'nihongo',
      composing: material.TextRange(start: 0, end: 7),
    );
    await tester.pump();
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, 0);
    controller.value = const material.TextEditingValue(
      text: 'nihongo',
      composing: material.TextRange.empty,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an expanded turn keeps its state when a newer turn arrives',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Widget list(List<MessageListGroup> groups) => host(VtenChatUiConfig(
        data: const VtenChatUiConfigData(
            compactToolCalls: true,
            compactStyle: VtenChatUiCompactStyle.vten),
        child: SizedBox(
            width: 420,
            height: 560,
            child: MessageList(
                sessionId: 's',
                contentVersion: groups.map((group) => group.id).join(','),
                groups: groups))));
    const oldTool = MessageListGroup(
        id: 'old',
        child: ToolCallActionWrapper(
            summary: ChatToolSummary(title: 'Old tool'),
            child: Text('old detail')));
    await tester.pumpWidget(list(const [oldTool]));
    await tester.pump();
    await tester.tap(find.textContaining('Old tool', findRichText: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('old detail'), findsOneWidget);
    await tester.pumpWidget(list(const [
      oldTool,
      MessageListGroup(id: 'new', child: Text('newer turn')),
    ]));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('old detail'), findsOneWidget);
    expect(find.text('newer turn'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned prompt follows the turn spanning the top, and tap reveals it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    MessageListGroup group(String id, String prompt) => MessageListGroup(
        id: id,
        pinText: prompt,
        userRow: SizedBox(
            key: ValueKey('$id-user'),
            height: 36,
            child: Text(prompt)),
        child: SizedBox(height: 700, child: Text('$id body')));
    await tester.pumpWidget(host(SizedBox(
        width: 420,
        height: 460,
        child: MessageList(
            sessionId: 's',
            contentVersion: '1',
            groups: [group('old', 'Older prompt'), group('new', 'Newer prompt')]))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(MessageList.pinnedPromptKey), findsOneWidget);
    expect(find.text('Newer prompt'), findsWidgets);
    expect(find.text('Older prompt'), findsNothing);

    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    final listFinder = find.byType(MessageList);
    final oldUser = find.byKey(const ValueKey('old-user'));
    // Bring the older turn into the cache, then place its user row just
    // above the list's top edge so that turn still spans the viewport.
    scroll.position.jumpTo(scroll.position.maxScrollExtent * 0.45);
    await tester.pump();
    expect(oldUser, findsOneWidget);
    final listBox = tester.renderObject<RenderBox>(listFinder);
    final rowBox = tester.renderObject<RenderBox>(oldUser);
    final rowTop = rowBox.localToGlobal(Offset.zero, ancestor: listBox).dy;
    const parkedTop = -40.0;
    scroll.position.jumpTo(
      (scroll.position.pixels + (parkedTop - rowTop)).clamp(
        0.0,
        scroll.position.maxScrollExtent,
      ),
    );
    await tester.pump();
    await tester.pump();
    final parked = tester
        .renderObject<RenderBox>(oldUser)
        .localToGlobal(Offset.zero, ancestor: listBox)
        .dy;
    expect(parked + rowBox.size.height, lessThanOrEqualTo(0.5));
    expect(parked + 744, greaterThan(48));
    final pin = find.byKey(MessageList.pinnedPromptKey);
    expect(pin, findsOneWidget);
    expect(
      tester.widget<Text>(find.descendant(of: pin, matching: find.byType(Text))).data,
      'Older prompt',
    );
    await tester.tap(pin);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final revealed = tester.getTopLeft(oldUser).dy - tester.getTopLeft(listFinder).dy;
    expect(revealed, closeTo(8, 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale session restore does not apply after a rapid switch',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final harness = _SessionHarness();
    await tester.pumpWidget(host(SizedBox(width: 400, height: 360, child: harness)));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 280));
    await tester.pump();
    final midOffset =
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    expect(midOffset, greaterThan(40));

    final state = tester.state<_SessionHarnessState>(find.byType(_SessionHarness));
    state.burstTo('c', 'd');
    await tester.pump();
    final during = state.sample;
    expect(state.burstError, isNull);
    expect(state.session, 'd');
    expect(state.builds, greaterThan(2));
    await tester.pump();
    expect(during, greaterThan(40), reason: 'builds=${state.builds}');
    expect(tester.takeException(), isNull);
  });
}

class _SessionHarness extends StatefulWidget {
  const _SessionHarness();

  @override
  State<_SessionHarness> createState() => _SessionHarnessState();
}

class _SessionHarnessState extends State<_SessionHarness> {
  String session = 'b';
  double? sample;
  int builds = 0;
  Object? burstError;
  bool _burst = false;
  bool _record = false;
  String _next = 'd';

  void burstTo(String first, String second) {
    setState(() {
      sample = null;
      session = first;
      _next = second;
      _burst = true;
      _record = true;
    });
  }

  MessageListGroup _group(String id) => MessageListGroup(
      id: id,
      pinText: id,
      userRow: Text(id),
      child: const SizedBox(height: 900, child: Text('body')));

  @override
  Widget build(BuildContext context) {
    builds++;
    if (_burst) {
      final target = _next;
      _burst = false;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        session = target;
        try {
          final element = context as Element;
          element.markNeedsBuild();
          WidgetsBinding.instance.buildOwner!.buildScope(element);
        } catch (error) {
          burstError = error;
        }
      });
    }
    return Column(children: [
      Expanded(
        child: MessageList(
            sessionId: session,
            contentVersion: session,
            groups: [_group(session)]),
      ),
      Builder(builder: (context) {
        if (_record) {
          final root = this.context as Element;
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (!_record || sample != null) return;
            void visit(Element element) {
              if (sample != null) return;
              if (element is StatefulElement && element.state is ScrollableState) {
                sample = (element.state as ScrollableState).position.pixels;
                _record = false;
                return;
              }
              element.visitChildren(visit);
            }
            root.visitChildren(visit);
          });
        }
        return const SizedBox.shrink();
      }),
    ]);
  }
}
