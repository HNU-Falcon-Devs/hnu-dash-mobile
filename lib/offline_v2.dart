import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'offline_capture.dart';

const _maxSafeInteger = 9007199254740991;
final _bootPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

Map<String, dynamic> v2Object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    throw const FormatException('Invalid successor response.');
  }
  return Map<String, dynamic>.from(raw);
}

void v2Policy(Map<String, dynamic> value) {
  if (value['policy_version'] is! int || value['policy_version'] != 2) {
    throw const FormatException('Unexpected attendance policy.');
  }
}

int v2Count(Object? raw) {
  if (raw is! int || raw < 0 || raw > _maxSafeInteger) {
    throw const FormatException('Invalid successor count.');
  }
  return raw;
}

bool v2Bool(Object? raw) {
  if (raw is! bool) throw const FormatException('Invalid successor flag.');
  return raw;
}

String v2Text(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) {
    throw const FormatException('Invalid successor text.');
  }
  return raw;
}

int? _elapsed(Object? value) =>
    value is int && value.abs() <= _maxSafeInteger ? value : null;

String? _boot(Object? value) =>
    value is String && _bootPattern.hasMatch(value) ? value : null;

/// Client observations, not authenticated device time or attestation.
class V2Observation {
  V2Observation({int? elapsedMs, String? boot, String? wallAt})
    : elapsedMs = _elapsed(elapsedMs),
      boot = _boot(boot),
      wallAt = wallAt == null ? null : _validWall(wallAt);

  final int? elapsedMs;
  final String? boot, wallAt;

  static String? _validWall(String value) {
    try {
      offlineInstant(value);
      return value;
    } on FormatException {
      return null;
    }
  }

  factory V2Observation.fromJson(Object? raw) {
    final value = v2Object(raw, {'elapsed_ms', 'boot', 'wall_at'});
    if ((value['elapsed_ms'] != null && _elapsed(value['elapsed_ms']) == null) ||
        (value['boot'] != null && _boot(value['boot']) == null)) {
      throw const FormatException('Invalid stored clock observation.');
    }
    if (value['wall_at'] != null) offlineInstant(value['wall_at']);
    return V2Observation(
      elapsedMs: value['elapsed_ms'] as int?,
      boot: value['boot'] as String?,
      wallAt: value['wall_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'elapsed_ms': elapsedMs,
    'boot': boot,
    'wall_at': wallAt,
  };
}

typedef V2Clock = Future<V2Observation> Function();

/// API 24+ BOOT_COUNT is best-effort; elapsedRealtime includes deep sleep.
/// A platform failure records wall observation only, never a fake anchor.
Future<V2Observation> observeAndroidClock() async {
  final fallback = DateTime.now().toUtc().toIso8601String();
  try {
    final raw = await const MethodChannel(
      'dev.hnudash.mobile/clock_evidence',
    ).invokeMapMethod<String, dynamic>('observe');
    final wall = raw?['wall_ms'];
    if (wall is! int) return V2Observation(wallAt: fallback);
    return V2Observation(
      elapsedMs: _elapsed(raw?['elapsed_ms']),
      boot: _boot(raw?['boot']),
      wallAt: DateTime.fromMillisecondsSinceEpoch(
        wall,
        isUtc: true,
      ).toIso8601String(),
    );
  } catch (_) {
    return V2Observation(wallAt: fallback);
  }
}

/// The only source of this context is an explicit test/harness fixture.
class V2Scope {
  V2Scope({
    required this.eventId,
    required this.assignmentId,
    required this.organizationId,
    required List<OfflineCheckpoint> checkpoints,
  }) : checkpoints = List.unmodifiable(checkpoints) {
    offlineUuid(eventId);
    offlineUuid(assignmentId);
    offlineUuid(organizationId);
    if (checkpoints.isEmpty ||
        checkpoints.map((c) => c.id).toSet().length != checkpoints.length) {
      throw const FormatException('Invalid fixture checkpoints.');
    }
  }

  final String eventId, assignmentId, organizationId;
  final List<OfflineCheckpoint> checkpoints;

  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    'assignment_id': assignmentId,
    'organization_id': organizationId,
    'checkpoints': checkpoints.map((c) => c.toJson()).toList(),
  };

  factory V2Scope.fromJson(Object? raw) {
    final value = v2Object(raw, {
      'event_id',
      'assignment_id',
      'organization_id',
      'checkpoints',
    });
    return V2Scope(
      eventId: offlineUuid(value['event_id']),
      assignmentId: offlineUuid(value['assignment_id']),
      organizationId: offlineUuid(value['organization_id']),
      checkpoints: (value['checkpoints'] as List)
          .map(OfflineCheckpoint.parse)
          .toList(),
    );
  }
}

class V2Preparation {
  V2Preparation._(this.receipt, this.checkpoints, this.issued);

  final Map<String, dynamic> receipt;
  final List<OfflineCheckpoint> checkpoints;
  final DateTime issued;

  String get id => receipt['preparation_id'] as String;
  String get owner => receipt['staff_user_id'] as String;
  String get eventId => receipt['event_id'] as String;
  String get requestId => receipt['request_id'] as String;
  bool get replayed => receipt['replayed'] as bool;

  factory V2Preparation.parse(
    Object? raw,
    V2Scope scope,
    String owner,
    String request,
  ) {
    final value = v2Object(raw, {
      'policy_version',
      'preparation_id',
      'request_id',
      'event_id',
      'organization_id',
      'assignment_id',
      'staff_user_id',
      'issued_at',
      'assignment_assigned_at',
      'roster_frozen_at',
      'event_title',
      'event_starts_at',
      'event_ends_at',
      'prepared_event_state',
      'checkpoints',
      'replayed',
    });
    v2Policy(value);
    offlineUuid(value['preparation_id']);
    final issued = offlineInstant(value['issued_at']);
    final starts = offlineInstant(value['event_starts_at']);
    final ends = offlineInstant(value['event_ends_at']);
    v2Text(value['event_title']);
    v2Bool(value['replayed']);
    if (offlineUuid(value['request_id']) != request ||
        offlineUuid(value['event_id']) != scope.eventId ||
        offlineUuid(value['assignment_id']) != scope.assignmentId ||
        offlineUuid(value['organization_id']) != scope.organizationId ||
        offlineUuid(value['staff_user_id']) != owner ||
        !['DRAFT', 'OPEN'].contains(value['prepared_event_state']) ||
        !starts.isBefore(ends) ||
        offlineInstant(value['assignment_assigned_at']).isAfter(issued) ||
        offlineInstant(value['roster_frozen_at']).isAfter(issued) ||
        value['checkpoints'] is! List) {
      throw const FormatException('Successor preparation scope mismatch.');
    }
    final checkpoints = (value['checkpoints'] as List)
        .map((raw) {
          return OfflineCheckpoint.parse(
            v2Object(raw, {'id', 'label', 'direction', 'opens_at', 'closes_at'}),
          );
        })
        .toList();
    final expected = {for (final c in scope.checkpoints) c.id: c};
    if (checkpoints.length != expected.length ||
        checkpoints.map((c) => c.id).toSet().length != expected.length ||
        checkpoints.any((c) {
          final match = expected[c.id];
          return match == null ||
              c.label != match.label ||
              c.direction != match.direction ||
              c.opens != match.opens ||
              c.closes != match.closes ||
              c.opens.isBefore(starts) ||
              c.closes.isAfter(ends);
        })) {
      throw const FormatException('Successor checkpoint scope mismatch.');
    }
    value['checkpoints'] = List.unmodifiable(
      (value['checkpoints'] as List).map((c) => Map.unmodifiable(c as Map)),
    );
    return V2Preparation._(
      Map.unmodifiable(value),
      List.unmodifiable(checkpoints),
      issued,
    );
  }
}

class V2Anchor {
  const V2Anchor(this.request, this.response, this.provenance);

  final V2Observation request;
  final V2Observation? response;
  final String provenance;

  factory V2Anchor.fromJson(Object? raw) {
    final value = v2Object(raw, {'request', 'response', 'provenance'});
    final provenance = value['provenance'];
    if (!['original', 'replayed', 'missing', 'unknown'].contains(provenance)) {
      throw const FormatException('Invalid anchor provenance.');
    }
    if ((provenance == 'original') != (value['response'] != null)) {
      throw const FormatException('Invalid original response observation.');
    }
    return V2Anchor(
      V2Observation.fromJson(value['request']),
      value['response'] == null
          ? null
          : V2Observation.fromJson(value['response']),
      provenance as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'request': request.toJson(),
    'response': response?.toJson(),
    'provenance': provenance,
  };

  /// Use B2's bounds for an advisory anomaly only. Backend alone adjudicates.
  Map<String, dynamic> evidence(
    DateTime issued,
    V2Observation qr,
    V2Observation confirmation,
  ) {
    final r = request.elapsedMs;
    final s = response?.elapsedMs;
    final q = qr.elapsedMs;
    final c = confirmation.elapsedMs;
    final marker = request.boot;
    final boot = qr.boot;
    var anomaly = 'none';
    if (marker != null &&
        ((boot != null && marker != boot) ||
            (confirmation.boot != null && marker != confirmation.boot) ||
            (response?.boot != null && marker != response?.boot))) {
      anomaly = 'reboot';
    } else if (provenance != 'original' ||
        r == null ||
        s == null ||
        q == null ||
        c == null ||
        marker == null ||
        boot == null ||
        confirmation.boot == null ||
        response?.boot == null ||
        qr.wallAt == null ||
        confirmation.wallAt == null) {
      anomaly = 'missing';
    } else if (r < 0 ||
        s < r ||
        q < s ||
        c < q ||
        s - r > 5000 ||
        c - q > 30000) {
      anomaly = 'inconsistent';
    } else {
      try {
        final qw = offlineInstant(qr.wallAt!);
        final cw = offlineInstant(confirmation.wallAt!);
        int epsilon(int x) => 2000000 + ((x - r + 9) ~/ 10);
        bool consistent(DateTime wall, int x) {
          final delta = wall.difference(issued).inMicroseconds;
          return delta >= (x - s) * 1000 - epsilon(x) &&
              delta <= (x - r) * 1000 + epsilon(x);
        }

        // Bound arithmetic conservatively for extreme client telemetry.
        if (math.max(q - r, c - r) > _maxSafeInteger ~/ 2000 ||
            !consistent(qw, q) ||
            !consistent(cw, c) ||
            (cw.difference(qw).inMicroseconds - (c - q) * 1000).abs() >
                epsilon(c)) {
          anomaly = 'clock_jump';
        }
      } catch (_) {
        anomaly = 'other';
      }
    }
    return {
      'anchor_request_elapsed_ms': r,
      'anchor_response_elapsed_ms': s,
      'qr_elapsed_ms': q,
      'confirmation_elapsed_ms': c,
      'qr_wall_at': qr.wallAt,
      'confirmation_wall_at': confirmation.wallAt,
      'anchor_boot_marker': marker,
      'capture_boot_marker': boot,
      'anchor_provenance': provenance,
      'anomaly': anomaly,
    };
  }
}

enum V2Warning { early, late, unknown }

/// A suppression is only for the current consecutive category/checkpoint
/// within one collection segment; an in-window observation resets it.
class V2Warnings {
  String? _checkpoint;
  V2Warning? _category;
  bool _acknowledged = false;

  V2Warning? observe(OfflineCheckpoint checkpoint, V2Observation qr) {
    final wall = qr.wallAt == null ? null : offlineInstant(qr.wallAt);
    final category = wall == null
        ? V2Warning.unknown
        : wall.isBefore(checkpoint.opens)
        ? V2Warning.early
        : !wall.isBefore(checkpoint.closes)
        ? V2Warning.late
        : null;
    if (_checkpoint != checkpoint.id || _category != category) {
      _checkpoint = checkpoint.id;
      _category = category;
      _acknowledged = false;
    }
    return _acknowledged ? null : category;
  }

  void acknowledge() => _acknowledged = true;

  void reset() {
    _checkpoint = null;
    _category = null;
    _acknowledged = false;
  }
}

const v2Dispositions = {'completed', 'missing', 'lost', 'revoked', 'undrained'};

class V2Status {
  const V2Status(this.state, this.sealed, this.count, this.disposition);

  final String state;
  final bool sealed;
  final int count;
  final String? disposition;

  bool get permitsCapture =>
      ['DRAFT', 'OPEN'].contains(state) && !sealed && disposition == null;
  bool get permitsNewUpload =>
      state == 'SYNCING' && !sealed && disposition == null;

  factory V2Status.parse(Object? raw, String preparationId) {
    final value = v2Object(raw, {
      'policy_version',
      'preparation_id',
      'event_state',
      'sync_deadline',
      'sealed',
      'uploaded_count',
      'disposition',
    });
    v2Policy(value);
    final state = value['event_state'];
    final disposition = value['disposition'];
    final sealed = v2Bool(value['sealed']);
    final count = v2Count(value['uploaded_count']);
    if (offlineUuid(value['preparation_id']) != preparationId ||
        !['DRAFT', 'OPEN', 'SYNCING', 'FINALIZED'].contains(state) ||
        (disposition != null && !v2Dispositions.contains(disposition))) {
      throw const FormatException('Invalid successor status.');
    }
    if (['DRAFT', 'OPEN'].contains(state)) {
      if (value['sync_deadline'] != null ||
          sealed ||
          count != 0 ||
          disposition != null) {
        throw const FormatException('Inconsistent successor status.');
      }
    } else {
      offlineInstant(value['sync_deadline']);
      if ((state == 'FINALIZED' && (!sealed || disposition == null)) ||
          (disposition != null && disposition != 'completed' && !sealed)) {
        throw const FormatException('Inconsistent terminal successor status.');
      }
    }
    return V2Status(state as String, sealed, count, disposition as String?);
  }
}

Map<String, dynamic> v2Acknowledgement(
  Object? raw,
  String preparationId,
  String captureId,
) {
  final value = v2Object(raw, {
    'policy_version',
    'capture_id',
    'preparation_id',
    'received_at',
    'status',
    'replayed',
  });
  v2Policy(value);
  if (offlineUuid(value['preparation_id']) != preparationId ||
      offlineUuid(value['capture_id']) != captureId ||
      value['status'] != 'submitted') {
    throw const FormatException('Invalid successor acknowledgement.');
  }
  offlineInstant(value['received_at']);
  v2Bool(value['replayed']);
  return value;
}

Map<String, dynamic> v2Completion(
  Object? raw,
  String preparationId,
  String owner,
  int count,
) {
  final value = v2Object(raw, {
    'policy_version',
    'preparation_id',
    'disposition',
    'uploaded_count',
    'declared_count',
    'reason',
    'accounted_at',
    'accounted_by',
    'replayed',
  });
  v2Policy(value);
  if (offlineUuid(value['preparation_id']) != preparationId ||
      offlineUuid(value['accounted_by']) != owner ||
      value['disposition'] != 'completed' ||
      v2Count(value['uploaded_count']) != count ||
      v2Count(value['declared_count']) != count ||
      value['reason'] != null) {
    throw const FormatException('Invalid successor completion.');
  }
  offlineInstant(value['accounted_at']);
  v2Bool(value['replayed']);
  return value;
}

void validateV2Clock(Object? raw) {
  final clock = v2Object(raw, {
    'anchor_request_elapsed_ms',
    'anchor_response_elapsed_ms',
    'qr_elapsed_ms',
    'confirmation_elapsed_ms',
    'qr_wall_at',
    'confirmation_wall_at',
    'anchor_boot_marker',
    'capture_boot_marker',
    'anchor_provenance',
    'anomaly',
  });
  for (final key in [
    'anchor_request_elapsed_ms',
    'anchor_response_elapsed_ms',
    'qr_elapsed_ms',
    'confirmation_elapsed_ms',
  ]) {
    if (clock[key] != null && _elapsed(clock[key]) == null) {
      throw const FormatException('Invalid elapsed evidence.');
    }
  }
  for (final key in ['qr_wall_at', 'confirmation_wall_at']) {
    if (clock[key] != null) offlineInstant(clock[key]);
  }
  for (final key in ['anchor_boot_marker', 'capture_boot_marker']) {
    if (clock[key] != null && _boot(clock[key]) == null) {
      throw const FormatException('Invalid boot evidence.');
    }
  }
  if (!['original', 'replayed', 'missing', 'unknown'].contains(
        clock['anchor_provenance'],
      ) ||
      !['none', 'missing', 'reboot', 'clock_jump', 'inconsistent', 'other']
          .contains(clock['anomaly'])) {
    throw const FormatException('Invalid clock classification.');
  }
}
