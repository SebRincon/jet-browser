class ChatEvent {
  ChatEvent({
    required this.id,
    required this.type,
    required this.data,
    required this.turnId,
    required this.createdAt,
  });

  final String id;
  final String type;
  final Map<String, dynamic> data;
  final String? turnId;
  final double createdAt;
}

class ChatTurn {
  ChatTurn({required this.id, this.userText, this.turnId});

  final String id;
  String? userText;
  String? turnId;
  final List<Map<String, dynamic>> responses = [];
  final List<Map<String, dynamic>> activities = [];
}

class ChatProjection {
  ChatProjection._({
    required this.events,
    required this.turns,
    required this.contentVersion,
    required this.liveTurnId,
  });

  factory ChatProjection.fromState(Map state) {
    final events = _collect(state);
    final grouped = _group(events);
    return ChatProjection._(
      events: events,
      turns: grouped.$1,
      contentVersion: _contentVersion(events),
      liveTurnId: grouped.$2,
    );
  }

  final List<ChatEvent> events;
  final List<ChatTurn> turns;
  final String contentVersion;
  final String? liveTurnId;
}

class _Slot {
  _Slot(this.turn, this.orderAt, this.isUser);
  final ChatTurn turn;
  double orderAt;
  final bool isUser;
}

List<ChatEvent> _collect(Map state) {
  final byKey = <String, ChatEvent>{};

  void take(String source, Object? raw, String type, int index) {
    if (raw is! Map || raw.isEmpty) return;
    final data = <String, dynamic>{};
    raw.forEach((key, value) => data['$key'] = value);
    data['event_type'] = type;
    final id = _asId(data['id']) ?? '$source:$index';
    data['id'] = id;
    byKey['$type\u0000$id'] = ChatEvent(
      id: id,
      type: type,
      data: data,
      turnId: _asId(data['turn_id']),
      createdAt: _createdAt(data['created_at']),
    );
  }

  void takeList(String source, Object? rawList, String type) {
    if (rawList is! List) return;
    for (var i = 0; i < rawList.length; i++) {
      take(source, rawList[i], type, i);
    }
  }

  takeList('message', state['messages'], 'message');
  takeList('route', state['routes'], 'route');
  takeList('task_history', state['task_history'], 'task');
  take('task', state['task'], 'task', 0);
  takeList('collection', state['collections'], 'collection');

  final events = byKey.values.toList();
  events.sort((a, b) {
    final byTime = a.createdAt.compareTo(b.createdAt);
    if (byTime != 0) return byTime;
    if (_isUser(a) != _isUser(b)) return _isUser(a) ? -1 : 1;
    final byType = a.type.compareTo(b.type);
    if (byType != 0) return byType;
    return a.id.compareTo(b.id);
  });
  return events;
}

(List<ChatTurn>, String?) _group(List<ChatEvent> events) {
  final users = <_Slot>[];
  final byTurn = <String, _Slot>{};
  for (final event in events) {
    if (!_isUser(event)) continue;
    final slot = _Slot(
      ChatTurn(
        id: event.id,
        userText: _nonBlank(_text(event.data)),
        turnId: event.turnId,
      ),
      event.createdAt,
      true,
    );
    users.add(slot);
    final turnId = event.turnId;
    if (turnId != null) byTurn[turnId] = slot;
  }

  final userAt = <String, _Slot>{for (final slot in users) slot.turn.id: slot};
  final orphans = <String, _Slot>{};
  _Slot? chrono;
  _Slot? legacy;
  String? liveTurnId;

  for (final event in events) {
    if (_isUser(event)) {
      chrono = userAt[event.id];
      liveTurnId = chrono?.turn.id;
      continue;
    }
    final _Slot slot;
    final turnId = event.turnId;
    if (turnId != null) {
      final indexed = byTurn[turnId];
      if (indexed != null) {
        slot = indexed;
      } else {
        slot = orphans.putIfAbsent(
          turnId,
          () => _Slot(ChatTurn(id: 'turn:$turnId', turnId: turnId),
              event.createdAt, false),
        );
      }
    } else if (chrono != null) {
      slot = chrono;
    } else {
      slot = legacy ??= _Slot(ChatTurn(id: 'legacy'), event.createdAt, false);
    }
    if (!slot.isUser && event.createdAt < slot.orderAt) {
      slot.orderAt = event.createdAt;
    }
    if (event.type == 'message') {
      if (_nonBlank(_text(event.data)) != null) {
        slot.turn.responses.add(event.data);
      }
    } else if (event.type == 'task' ||
        event.type == 'route' ||
        event.type == 'collection') {
      slot.turn.activities.add(event.data);
    }
  }

  final ordered = <_Slot>[
    ...users,
    ...orphans.values,
    if (legacy != null) legacy
  ];
  ordered.sort((a, b) {
    final byTime = a.orderAt.compareTo(b.orderAt);
    if (byTime != 0) return byTime;
    return a.turn.id.compareTo(b.turn.id);
  });
  return ([for (final slot in ordered) slot.turn], liveTurnId);
}

bool _isUser(ChatEvent event) {
  if (event.type != 'message') return false;
  final kind = event.data['role'] ??
      event.data['author'] ??
      event.data['sender'] ??
      event.data['kind'] ??
      event.data['type'];
  return kind is String && kind.toLowerCase() == 'user';
}

String? _text(Map<String, dynamic> data) {
  final value = data['text'] ?? data['content'];
  return value is String ? value : null;
}

String? _nonBlank(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}

String? _asId(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  if (value is num || value is bool) return '$value';
  return null;
}

double _createdAt(Object? value) {
  if (value is num) {
    final number = value.toDouble();
    if (number.isFinite) return number;
  }
  return 0;
}

String _contentVersion(List<ChatEvent> events) {
  final buffer = StringBuffer();
  for (final event in events) {
    buffer
      ..write(_canon(event.id))
      ..write('\u001e')
      ..write(_canon(event.type))
      ..write('\u001e')
      ..write(_canon(event.turnId))
      ..write('\u001e')
      ..write(_canon(event.createdAt))
      ..write('\u001e')
      ..write(_canon(event.data))
      ..write('\u001d');
  }
  return buffer.toString();
}

String _canon(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) {
    if (value is double && !value.isFinite) return 'null';
    final number = value.toDouble();
    if (number == number.truncateToDouble()) {
      return number.truncate().toString();
    }
    return number.toString();
  }
  if (value is String) {
    return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
  }
  if (value is List) return '[${value.map(_canon).join(',')}]';
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    return '{${keys.map((key) {
      Object? nested;
      if (value.containsKey(key)) {
        nested = value[key];
      } else {
        for (final entry in value.entries) {
          if ('${entry.key}' == key) {
            nested = entry.value;
            break;
          }
        }
      }
      return '${_canon(key)}:${_canon(nested)}';
    }).join(',')}}';
  }
  return _canon('$value');
}
