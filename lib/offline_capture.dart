import 'dart:math' as math;

import 'development_scan_policy.dart';

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _instant = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-](\d{2}):(\d{2}))$',
);

String offlineUuid(Object? value) {
  if (value is! String || !_uuid.hasMatch(value)) {
    throw const FormatException('Invalid offline identifier.');
  }
  return value;
}

DateTime offlineInstant(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid offline instant.');
  }
  final match = _instant.firstMatch(value);
  if (match == null) throw const FormatException('Invalid offline instant.');
  int part(int index) => int.parse(match.group(index)!);
  final year = part(1), month = part(2), day = part(3);
  final calendar = DateTime.utc(year, month, day);
  if (year == 0 ||
      calendar.year != year ||
      calendar.month != month ||
      calendar.day != day ||
      part(4) > 23 ||
      part(5) > 59 ||
      part(6) > 59 ||
      (match.group(7) != null && (part(7) > 23 || part(8) > 59))) {
    throw const FormatException('Invalid offline instant.');
  }
  final instant = DateTime.tryParse(value);
  if (instant == null) {
    throw const FormatException('Invalid offline instant.');
  }
  return instant.toUtc();
}

String _nonempty(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Invalid offline context.');
  }
  return value;
}

class OfflineCheckpoint {
  const OfflineCheckpoint(
    this.id,
    this.label,
    this.direction,
    this.opens,
    this.closes,
  );

  final String id, label, direction;
  final DateTime opens, closes;

  factory OfflineCheckpoint.parse(Object? value) {
    if (value is! Map) throw const FormatException('Invalid checkpoint.');
    final checkpoint = OfflineCheckpoint(
      offlineUuid(value['id']),
      _nonempty(value['label']),
      _nonempty(value['direction']),
      offlineInstant(value['opens_at']),
      offlineInstant(value['closes_at']),
    );
    if (!['IN', 'OUT'].contains(checkpoint.direction) ||
        !checkpoint.opens.isBefore(checkpoint.closes)) {
      throw const FormatException('Invalid checkpoint window.');
    }
    return checkpoint;
  }

  Map<String, Object> toJson() => {
    'id': id,
    'label': label,
    'direction': direction,
    'opens_at': opens.toIso8601String(),
    'closes_at': closes.toIso8601String(),
  };
}

class OfflinePreparation {
  const OfflinePreparation._({
    required this.id,
    required this.requestId,
    required this.eventId,
    required this.assignmentId,
    required this.staffId,
    required this.title,
    required this.starts,
    required this.ends,
    required this.issued,
    required this.expires,
    required this.cutoff,
    required this.checkpoints,
    required this.replayed,
  });

  final String id, requestId, eventId, assignmentId, staffId, title;
  final DateTime starts, ends, issued, expires, cutoff;
  final List<OfflineCheckpoint> checkpoints;
  final bool replayed;

  factory OfflinePreparation.parse(
    Object? value, {
    required String eventId,
    required String assignmentId,
    required String staffId,
    required String requestId,
  }) {
    if (value is! Map ||
        value['checkpoints'] is! List ||
        value['replayed'] is! bool) {
      throw const FormatException('Invalid preparation response.');
    }
    final checkpoints = (value['checkpoints'] as List)
        .map(OfflineCheckpoint.parse)
        .toList();
    final preparation = OfflinePreparation._(
      id: offlineUuid(value['preparation_id']),
      requestId: offlineUuid(value['request_id']),
      eventId: offlineUuid(value['event_id']),
      assignmentId: offlineUuid(value['assignment_id']),
      staffId: offlineUuid(value['staff_user_id']),
      title: _nonempty(value['event_title']),
      starts: offlineInstant(value['event_starts_at']),
      ends: offlineInstant(value['event_ends_at']),
      issued: offlineInstant(value['issued_at']),
      expires: offlineInstant(value['expires_at']),
      cutoff: offlineInstant(value['upload_cutoff']),
      checkpoints: List.unmodifiable(checkpoints),
      replayed: value['replayed'] as bool,
    );
    if (preparation.eventId != eventId ||
        preparation.assignmentId != assignmentId ||
        preparation.staffId != staffId ||
        preparation.requestId != requestId ||
        !preparation.starts.isBefore(preparation.ends) ||
        !preparation.issued.isBefore(preparation.expires) ||
        checkpoints.isEmpty ||
        checkpoints.map((c) => c.id).toSet().length != checkpoints.length ||
        checkpoints.any(
          (c) =>
              c.opens.isBefore(preparation.starts) ||
              c.closes.isAfter(preparation.ends),
        )) {
      throw const FormatException('Preparation scope or schedule mismatch.');
    }
    final lastClose = checkpoints
        .map((c) => c.closes)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final maxExpiry = preparation.issued.add(const Duration(hours: 8));
    final expectedExpiry = lastClose.isBefore(maxExpiry)
        ? lastClose
        : maxExpiry;
    if (preparation.expires != expectedExpiry ||
        preparation.cutoff != lastClose.add(const Duration(hours: 24))) {
      throw const FormatException('Preparation bounds mismatch.');
    }
    return preparation;
  }

  Map<String, Object> toJson() => {
    'preparation_id': id,
    'request_id': requestId,
    'event_id': eventId,
    'assignment_id': assignmentId,
    'staff_user_id': staffId,
    'event_title': title,
    'event_starts_at': starts.toIso8601String(),
    'event_ends_at': ends.toIso8601String(),
    'issued_at': issued.toIso8601String(),
    'expires_at': expires.toIso8601String(),
    'upload_cutoff': cutoff.toIso8601String(),
    'checkpoints': checkpoints.map((c) => c.toJson()).toList(),
    'replayed': replayed,
  };
}

/// Process-local conservative guard, never a proof of physical capture time.
/// Upper bound starts at the ORIGINAL request dispatch; the lower bound
/// starts at receipt. A replay after restart has no such guard.
class OfflineTimeGuard {
  OfflineTimeGuard({
    required this.preparation,
    required this.elapsed,
    required this.wallNow,
    required this.requestWall,
    required this.receivedElapsed,
  });

  final OfflinePreparation preparation;
  final Duration Function() elapsed;
  final DateTime Function() wallNow;
  final DateTime requestWall;
  final Duration receivedElapsed;
  bool _invalid = false;

  bool get isLeaseUsable => _bounds() != null;

  ({DateTime now, DateTime lower, DateTime upper})? _bounds() {
    if (_invalid) return null;
    final now = wallNow().toUtc();
    final duration = elapsed();
    final wallDuration = now.difference(requestWall);
    // Detect clock jumps and suspend-related divergence. The maximum elapsed
    // value is used for the upper bound; a rollback cannot extend the lease.
    const tolerance = Duration(seconds: 2);
    if (duration < receivedElapsed ||
        wallDuration.isNegative ||
        (wallDuration - duration).abs() > tolerance) {
      _invalid = true;
      return null;
    }
    final upper = preparation.issued.add(
      Duration(
        microseconds: math.max(
          duration.inMicroseconds,
          wallDuration.inMicroseconds,
        ),
      ) + tolerance,
    );
    final lower = preparation.issued.add(
      Duration(
        microseconds: math.max(
          0,
          (duration - receivedElapsed - tolerance).inMicroseconds,
        ),
      ),
    );
    if (!upper.isBefore(preparation.expires) ||
        now.isBefore(lower) ||
        now.isAfter(upper)) {
      _invalid = true;
      return null;
    }
    return (now: now, lower: lower, upper: upper);
  }

  DateTime? claimTime(String checkpointId) {
    final bounds = _bounds();
    if (bounds == null) return null;
    final now = bounds.now;
    for (final checkpoint in preparation.checkpoints) {
      if (checkpoint.id != checkpointId) continue;
      if (bounds.lower.isBefore(checkpoint.opens) ||
          !bounds.upper.isBefore(checkpoint.closes) ||
          now.isBefore(preparation.issued) ||
          !now.isBefore(preparation.expires) ||
          now.isBefore(checkpoint.opens) ||
          !now.isBefore(checkpoint.closes)) {
        return null;
      }
      return now;
    }
    return null;
  }
}

class OfflineCaptureException implements Exception {
  const OfflineCaptureException(this.message);

  final String message;
}

enum OfflineClaimStatus { queued, submitted, blocked }

class OfflineClaim {
  const OfflineClaim({
    required this.id,
    required this.preparationId,
    required this.eventId,
    required this.checkpointId,
    required this.staffId,
    required this.studentId,
    required this.claimedAt,
    required this.status,
    this.receivedAt,
    this.replayed,
  });

  final String id, preparationId, eventId, checkpointId, staffId, studentId;
  final DateTime claimedAt;
  final OfflineClaimStatus status;
  final DateTime? receivedAt;
  final bool? replayed;

  Map<String, dynamic> get parameters {
    if (!isApprovedDevelopmentStudentId(studentId)) {
      throw const FormatException('Only synthetic claims can be uploaded.');
    }
    return {
      'p_preparation_id': preparationId,
      'p_capture_id': id,
      'p_checkpoint_id': checkpointId,
      'p_student_id': studentId,
      'p_claimed_at': claimedAt.toUtc().toIso8601String(),
    };
  }
}

class OfflineAcknowledgement {
  const OfflineAcknowledgement(this.receivedAt, this.replayed);

  final DateTime receivedAt;
  final bool replayed;

  factory OfflineAcknowledgement.parse(Object? value, OfflineClaim claim) {
    if (value is! Map ||
        value['capture_id'] != claim.id ||
        value['preparation_id'] != claim.preparationId ||
        value['status'] != 'submitted' ||
        value['replayed'] is! bool) {
      throw const FormatException('Invalid offline acknowledgement.');
    }
    return OfflineAcknowledgement(
      offlineInstant(value['received_at']),
      value['replayed'] as bool,
    );
  }
}

class OfflineQueueCounts {
  const OfflineQueueCounts(this.queued, this.submitted, this.blocked);

  final int queued, submitted, blocked;
}
