import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/offline_capture.dart';

import 'offline_fixture.dart';

void main() {
  final fixture = OfflineFixture(DateTime.utc(2026, 11, 24, 1));

  OfflinePreparation parse(Object? response) => OfflinePreparation.parse(
    response,
    eventId: eventId,
    assignmentId: assignmentA,
    staffId: staffA,
    requestId: requestId,
  );

  test('validates exact preparation scope and immutable bounds', () {
    final response = fixture.response(requestId);
    final preparation = parse(response);
    expect(preparation.checkpoints.single.id, checkpointId);
    expect(preparation.expires, fixture.closes);
    expect(preparation.cutoff, fixture.cutoff);
    for (final key in [
      'preparation_id',
      'event_id',
      'request_id',
      'assignment_id',
      'staff_user_id',
      'issued_at',
      'expires_at',
      'upload_cutoff',
      'event_title',
      'event_starts_at',
      'event_ends_at',
      'checkpoints',
      'replayed',
    ]) {
      final invalid = Map<String, Object>.from(response)..remove(key);
      expect(() => parse(invalid), throwsFormatException, reason: key);
    }
    for (final entry in {
      'staff_user_id': staffB,
      'assignment_id': assignmentB,
      'request_id': preparationA,
      'event_id': preparationB,
      'expires_at': fixture.ends.toIso8601String(),
      'upload_cutoff': fixture.ends.toIso8601String(),
    }.entries) {
      expect(
        () => parse({...response, entry.key: entry.value}),
        throwsFormatException,
        reason: entry.key,
      );
    }
    expect(
      () => parse({
        ...response,
        'checkpoints': [
          fixture.checkpoint.toJson(),
          fixture.checkpoint.toJson(),
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => parse({
        ...response,
        'checkpoints': [
          {...fixture.checkpoint.toJson(), 'direction': 'UNKNOWN'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('timestamps require valid calendar dates and explicit offsets', () {
    expect(offlineInstant('2026-11-24T09:00:00+08:00'), fixture.issued);
    for (final value in [
      '2026-02-30T01:00:00Z',
      '2026-11-24T01:00:00',
      '2026-11-24T25:00:00Z',
      '2026-11-24T01:00:00+99:00',
      'infinity',
    ]) {
      expect(() => offlineInstant(value), throwsFormatException);
    }
  });

  test('clock rollback or jump invalidates the process-local guard', () {
    final prep = fixture.parse(requestId);
    for (final jump in [-60, 60]) {
      var elapsed = const Duration(seconds: 5);
      var wall = fixture.issued.add(const Duration(seconds: 4));
      final guard = OfflineTimeGuard(
        preparation: prep,
        elapsed: () => elapsed,
        wallNow: () => wall,
        requestWall: fixture.issued.subtract(const Duration(seconds: 1)),
        receivedElapsed: const Duration(seconds: 2),
      );
      expect(guard.claimTime(checkpointId), wall);
      elapsed += const Duration(seconds: 1);
      wall = wall.add(Duration(seconds: jump));
      expect(guard.claimTime(checkpointId), isNull);
      wall = fixture.issued.add(const Duration(seconds: 5));
      expect(guard.claimTime(checkpointId), isNull);
    }
  });

  test('conservative bounds refuse capture near the exclusive expiry', () {
    final prep = fixture.parse(requestId);
    final guard = OfflineTimeGuard(
      preparation: prep,
      elapsed: () => const Duration(minutes: 59, seconds: 59),
      wallNow: () => prep.expires.subtract(const Duration(seconds: 2)),
      requestWall: prep.issued.subtract(const Duration(seconds: 1)),
      receivedElapsed: const Duration(seconds: 2),
    );
    expect(guard.claimTime(checkpointId), isNull);
    expect(guard.isLeaseUsable, isFalse);
  });

  test('the lower time bound must reach the checkpoint opening', () {
    final response = fixture.response(requestId);
    final prep = parse({
      ...response,
      'checkpoints': [
        {
          ...fixture.checkpoint.toJson(),
          'opens_at': fixture.issued
              .add(const Duration(seconds: 20))
              .toIso8601String(),
        },
      ],
    });
    var elapsed = const Duration(seconds: 21);
    final guard = OfflineTimeGuard(
      preparation: prep,
      elapsed: () => elapsed,
      wallNow: () => fixture.issued.add(elapsed - const Duration(seconds: 1)),
      requestWall: fixture.issued.subtract(const Duration(seconds: 1)),
      receivedElapsed: const Duration(seconds: 2),
    );
    expect(guard.claimTime(checkpointId), isNull);
    elapsed = const Duration(seconds: 25);
    expect(guard.claimTime(checkpointId), isNotNull);
    expect(guard.claimTime(preparationA), isNull);
  });

  test('typed immutable claim payload and strict acknowledgement', () {
    final claim = OfflineClaim(
      id: requestId,
      preparationId: preparationA,
      eventId: eventId,
      checkpointId: checkpointId,
      staffId: staffA,
      studentId: 'SYNTHETIC-00Ab-c',
      claimedAt: fixture.issued,
      status: OfflineClaimStatus.queued,
    );
    expect(claim.parameters, {
      'p_capture_id': requestId,
      'p_preparation_id': preparationA,
      'p_checkpoint_id': checkpointId,
      'p_student_id': 'SYNTHETIC-00Ab-c',
      'p_claimed_at': fixture.issued.toIso8601String(),
    });
    final ack = acknowledgement(claim.parameters, replayed: true);
    expect(OfflineAcknowledgement.parse(ack, claim).replayed, isTrue);
    for (final entry in {
      'capture_id': preparationB,
      'preparation_id': preparationB,
      'status': 'accepted',
      'received_at': '2026-11-24T01:00:00',
      'replayed': 'true',
    }.entries) {
      expect(
        () => OfflineAcknowledgement.parse({
          ...ack,
          entry.key: entry.value,
        }, claim),
        throwsFormatException,
      );
    }
  });
}
