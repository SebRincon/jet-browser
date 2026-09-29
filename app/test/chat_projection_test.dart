import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/chat_projection.dart';

Map<String, dynamic> msg(String id, String role, num time,
        {String? turn, String? text}) =>
    {
      'id': id,
      'role': role,
      'text': text ?? id,
      'created_at': time,
      if (turn != null) 'turn_id': turn
    };
Map<String, dynamic> task(String id, num time,
        {String? turn, String status = 'done'}) =>
    {
      'id': id,
      'created_at': time,
      'status': status,
      if (turn != null) 'turn_id': turn
    };

void main() {
  test('collection progress updates one card in its original turn', () {
    Map<String, dynamic> state(int count) => {
          'messages': [
            {
              'id': 'u',
              'role': 'user',
              'text': 'Collect this site',
              'turn_id': 't',
              'created_at': 1
            }
          ],
          'collections': [
            {
              'id': 'c',
              'turn_id': 't',
              'created_at': 2,
              'status': 'running',
              'counters': {'pages': count}
            }
          ],
        };
    final first = ChatProjection.fromState(state(1));
    final next = ChatProjection.fromState(state(2));
    expect(next.turns.single.activities.single['event_type'], 'collection');
    expect(next.turns.single.id, first.turns.single.id);
    expect(next.contentVersion, isNot(first.contentVersion));
  });

  test('explicit turn identity beats late timestamps and early tool arrival',
      () {
    final p = ChatProjection.fromState({
      'messages': [
        msg('u1', 'user', 1, turn: 'a'),
        msg('u2', 'user', 3, turn: 'b'),
        msg('a1', 'assistant', 8, turn: 'a')
      ],
      'task_history': [task('early', 0, turn: 'b'), task('late', 9, turn: 'a')]
    });
    expect(p.turns.map((t) => t.id), ['u1', 'u2']);
    expect(p.turns[0].responses.single['id'], 'a1');
    expect(p.turns[0].activities.single['id'], 'late');
    expect(p.turns[1].activities.single['id'], 'early');
    expect(p.liveTurnId, 'u2');
  });
  test(
      'orphan explicit event cannot join another user and does not change legacy fallback',
      () {
    final p = ChatProjection.fromState({
      'messages': [
        msg('u', 'user', 1, turn: 'a'),
        msg('orphan', 'assistant', 2, turn: 'missing'),
        msg('legacy', 'assistant', 3)
      ]
    });
    expect(p.turns.length, 2);
    expect(p.turns.first.responses.single['id'], 'legacy');
    expect(p.turns.last.id, 'turn:missing');
    expect(p.liveTurnId, 'u');
  });
  test('active task replaces history once; raw state is not mutated', () {
    final old = task('task', 2, status: 'running');
    final active = task('task', 2, status: 'done');
    final p = ChatProjection.fromState({
      'messages': [msg('u', 'user', 1)],
      'task_history': [old, old],
      'task': active
    });
    expect(p.turns.single.activities.length, 1);
    expect(p.turns.single.activities.single['status'], 'done');
    expect(active.containsKey('event_type'), false);
  });
  test('duplicate messages render once and equal timestamps are deterministic',
      () {
    final u = msg('u', 'user', 1, turn: 'a');
    final p = ChatProjection.fromState({
      'messages': [msg('a', 'assistant', 1, turn: 'a'), u, u],
      'routes': [
        {'id': 'route', 'created_at': 1, 'turn_id': 'a'}
      ]
    });
    expect(p.turns.length, 1);
    expect(p.turns.single.userText, 'u');
    expect(p.turns.single.responses.length, 1);
  });
  test('same-length streaming replacement changes content version, keys stable',
      () {
    final a = ChatProjection.fromState({
      'messages': [msg('u', 'user', 1), msg('a', 'assistant', 2, text: 'first')]
    });
    final b = ChatProjection.fromState({
      'messages': [msg('u', 'user', 1), msg('a', 'assistant', 2, text: 'other')]
    });
    expect(a.contentVersion, isNot(b.contentVersion));
    expect(a.turns.single.id, b.turns.single.id);
  });
  test('legacy events group chronologically and malformed entries are ignored',
      () {
    final p = ChatProjection.fromState({
      'messages': [
        null,
        'bad',
        msg('u1', 'user', 1),
        msg('a1', 'assistant', 2),
        msg('u2', 'user', 3)
      ],
      'routes': [
        {'id': 'r', 'created_at': 4}
      ]
    });
    expect(p.turns.length, 2);
    expect(p.turns.first.responses.single['id'], 'a1');
    expect(p.turns.last.activities.single['id'], 'r');
  });
}
