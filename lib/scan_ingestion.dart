import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'development_scan_policy.dart';
import 'offline_capture.dart';
import 'secure_attendance_store.dart';
import 'secure_value_store.dart';

class ScanAttemptResult {
  const ScanAttemptResult({
    required this.record,
    required this.message,
    required this.retryAllowed,
  });

  final ScanRecord? record;
  final String message;
  final bool retryAllowed;
}

abstract interface class StaffScanGateway {
  Future<void> openForAccount(String staffUserId);
  Future<void> close();
  Future<List<ScanRecord>> readRecent();
  Future<bool> hasUnresolvedRecords();
  Future<ScanAttemptResult> capture({
    required String eventId,
    required String checkpointId,
    required String studentId,
  });
  Future<ScanAttemptResult> retry(String scanId);
}

/// Separate opt-in path; the existing online interface remains unchanged.
abstract interface class OfflineScanGateway {
  OfflinePreparation? get activePreparation;
  void invalidateOffline();
  Future<String> prepareOffline({
    required String eventId,
    required String assignmentId,
    required String title,
    required DateTime starts,
    required DateTime ends,
    required DateTime cutoff,
    required List<OfflineCheckpoint> checkpoints,
  });
  OfflineClaim captureOffline({
    required String preparationId,
    required String checkpointId,
    required String studentId,
  });
  OfflineQueueCounts offlineCounts();
  List<OfflineClaim> recentOffline();
  Future<String> syncOffline(void Function(OfflineQueueCounts) onProgress);
}

typedef CurrentStaffId = String? Function();

/// Immutable identity and bearer token captured for one RPC submission.
class StaffScanSession {
  const StaffScanSession({
    required this.staffUserId,
    required this.accessToken,
  });

  final String staffUserId;
  final String accessToken;
}

typedef CurrentStaffSession = Future<StaffScanSession?> Function();
typedef AttendanceScanRpc = Future<dynamic> Function(
  Map<String, dynamic> parameters,
  String accessToken,
);

/// A per-request Authorization header is preserved by Supabase Dart 2.16.5's
/// AuthHttpClient (putIfAbsent), even if its shared auth session changes while
/// the request is preparing to send. No global client header is modified.
Future<dynamic> submitPinnedAttendanceRpc(
  SupabaseClient client,
  Map<String, dynamic> parameters,
  String accessToken,
) => client
    .rpc('ingest_attendance_scan', params: parameters)
    .setHeader('Authorization', 'Bearer $accessToken');
typedef AttendanceStoreOpener = Future<SecureAttendanceStore> Function(
  String staffUserId,
);

class SupabaseStaffScanGateway
    implements StaffScanGateway, OfflineScanGateway {
  SupabaseStaffScanGateway.forSupabase(
    SupabaseClient client, {
    required SecureValueStore secureValues,
  }) : this._(
         currentStaffId: () => client.auth.currentUser?.id,
         currentSession: () async {
           final session = await client.auth.getSession();
           if (session == null) return null;
           return StaffScanSession(
             staffUserId: session.user.id,
             accessToken: session.accessToken,
           );
         },
         ingest: (parameters, token) =>
             submitPinnedAttendanceRpc(client, parameters, token),
         prepare: (parameters, token) => client
             .rpc('prepare_offline_capture', params: parameters)
             .setHeader('Authorization', 'Bearer $token'),
         upload: (parameters, token) => client
             .rpc('submit_offline_capture', params: parameters)
             .setHeader('Authorization', 'Bearer $token'),
         openStore: (staffUserId) => SecureAttendanceStore.openOnDevice(
           staffUserId: staffUserId,
           keyStore: secureValues,
         ),
       );

  @visibleForTesting
  SupabaseStaffScanGateway.test({
    required CurrentStaffId currentStaffId,
    required CurrentStaffSession currentSession,
    required AttendanceScanRpc ingest,
    required AttendanceStoreOpener openStore,
    AttendanceScanRpc? prepare,
    AttendanceScanRpc? upload,
  }) : this._(
         currentStaffId: currentStaffId,
         currentSession: currentSession,
         ingest: ingest,
         prepare: prepare,
         upload: upload,
         openStore: openStore,
       );

  SupabaseStaffScanGateway._({
    required this._currentStaffId,
    required this._currentSession,
    required this._ingest,
    required this._prepare,
    required this._upload,
    required this._openStore,
  });

  final CurrentStaffId _currentStaffId;
  final CurrentStaffSession _currentSession;
  final AttendanceScanRpc _ingest;
  final AttendanceScanRpc? _prepare, _upload;
  final AttendanceStoreOpener _openStore;
  SecureAttendanceStore? _store;
  String? _staffUserId;
  int _bindingEpoch = 0;
  Future<void> _opening = Future<void>.value();
  Object? _operation;
  int _offlineEpoch = 0;
  OfflineTimeGuard? _offlineGuard;
  final _requestClocks = <String, _PreparationClock>{};

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_operation != null) {
      throw StateError('Another attendance operation is in progress.');
    }
    final token = Object();
    _operation = token;
    try {
      return await action();
    } finally {
      if (identical(_operation, token)) _operation = null;
    }
  }

  @override
  Future<void> openForAccount(String staffUserId) async {
    if (_currentStaffId() != staffUserId) {
      throw StateError('The authenticated Staff account changed.');
    }
    if (_staffUserId == staffUserId && _store != null) return;

    final closing = close();
    final generation = _bindingEpoch;
    await closing;
    final opening = _opening.then((_) async {
      if (generation != _bindingEpoch) {
        throw StateError('The authenticated Staff account changed.');
      }
      final store = await _openStore(staffUserId);
      if (generation != _bindingEpoch || _currentStaffId() != staffUserId) {
        await store.close();
        throw StateError('The authenticated Staff account changed.');
      }
      _store = store;
      _staffUserId = staffUserId;
    });
    _opening = opening.then<void>((_) {}, onError: (Object _) {});
    await opening;
  }

  @override
  Future<void> close() async {
    _bindingEpoch++;
    invalidateOffline();
    _operation = null;
    final store = _store;
    _store = null;
    _staffUserId = null;
    if (store != null) await store.close();
  }

  @override
  Future<List<ScanRecord>> readRecent() async {
    _ensureCurrentAccount();
    return _store!.readRecent();
  }

  @override
  Future<bool> hasUnresolvedRecords() async {
    _ensureCurrentAccount();
    return _store!.hasUnresolvedRecords();
  }

  @override
  Future<ScanAttemptResult> capture({
    required String eventId,
    required String checkpointId,
    required String studentId,
  }) => _exclusive(
    () => _captureOnline(
      eventId: eventId,
      checkpointId: checkpointId,
      studentId: studentId,
    ),
  );

  Future<ScanAttemptResult> _captureOnline({
    required String eventId,
    required String checkpointId,
    required String studentId,
  }) async {
    _ensureCurrentAccount();
    final store = _store!;
    final staffUserId = _staffUserId!;

    if (!isApprovedDevelopmentStudentId(studentId)) {
      return const ScanAttemptResult(
        record: null,
        message: 'Development scanning accepts synthetic test IDs only.',
        retryAllowed: false,
      );
    }

    if (await store.hasUnresolvedRecords()) {
      _ensureBoundAccount(store, staffUserId);
      return const ScanAttemptResult(
        record: null,
        message:
            'Resolve the existing pending attempt before scanning another ID.',
        retryAllowed: false,
      );
    }

    // Pin the account's store across awaits. An auth change must never redirect
    // an in-flight capture into the next account's database.
    _ensureBoundAccount(store, staffUserId);
    final record = await store.createPending(
      eventId: eventId,
      checkpointId: checkpointId,
      studentId: studentId,
    );
    _ensureRecordAccount(record, store, staffUserId);
    return _submit(record, store: store, staffUserId: staffUserId);
  }

  @override
  Future<ScanAttemptResult> retry(String scanId) =>
      _exclusive(() => _retryOnline(scanId));

  Future<ScanAttemptResult> _retryOnline(String scanId) async {
    _ensureCurrentAccount();
    final store = _store!;
    final staffUserId = _staffUserId!;
    final record = await store.findPending(scanId);
    _ensureBoundAccount(store, staffUserId);
    if (record == null) {
      return const ScanAttemptResult(
        record: null,
        message:
            'This pending attempt is no longer available for this account.',
        retryAllowed: false,
      );
    }
    _ensureRecordAccount(record, store, staffUserId);
    if (!isApprovedDevelopmentStudentId(record.studentId)) {
      return ScanAttemptResult(
        record: record,
        message: 'This saved attempt is not an approved synthetic test ID. It has been preserved for support and cannot be submitted.',
        retryAllowed: false,
      );
    }
    return _submit(record, store: store, staffUserId: staffUserId);
  }

  Future<ScanAttemptResult> _submit(
    ScanRecord record, {
    required SecureAttendanceStore store,
    required String staffUserId,
  }) async {
    _ensureRecordAccount(record, store, staffUserId);
    try {
      // getSession refreshes an expired token if possible. Recheck the bound
      // account after the await and require the returned session's own UUID.
      final session = await _currentSession();
      _ensureRecordAccount(record, store, staffUserId);
      if (session == null ||
          session.staffUserId != staffUserId ||
          session.accessToken.isEmpty) {
        throw StateError('The submission session does not match its owner.');
      }

      // The shared Supabase client's mutable session is NOT the request's
      // authority. A pinned Authorization header sends this exact token.
      final response = await _ingest({
        'p_scan_id': record.scanId,
        'p_event_id': record.eventId,
        'p_checkpoint_id': record.checkpointId,
        'p_student_id': record.studentId,
      }, session.accessToken);
      _ensureRecordAccount(record, store, staffUserId);
      final receipt = _parseReceipt(response, record.scanId);
      await store.recordReceipt(
        scanId: record.scanId,
        outcome: receipt.outcome,
        receivedAt: receipt.receivedAt,
        replayed: receipt.replayed,
      );
      final saved = ScanRecord(
        scanId: record.scanId,
        eventId: record.eventId,
        checkpointId: record.checkpointId,
        studentId: record.studentId,
        staffUserId: record.staffUserId,
        status: receipt.outcome,
        receivedAt: receipt.receivedAt,
        replayed: receipt.replayed,
      );
      return ScanAttemptResult(
        record: saved,
        message: _receiptMessage(receipt),
        retryAllowed: false,
      );
    } on PostgrestException catch (error) {
      // Ignore a late terminal error after sign-out or account switch: the
      // original pending record must remain available to its owner.
      try {
        _ensureRecordAccount(record, store, staffUserId);
      } catch (_) {
        return _pendingResult(record);
      }
      return await _handleBackendFailure(record, error.code, store: store);
    } catch (_) {
      return _pendingResult(record);
    }
  }

  @override
  OfflinePreparation? get activePreparation {
    _ensureCurrentAccount();
    return _offlineGuard?.preparation;
  }

  @override
  void invalidateOffline() {
    _offlineEpoch++;
    _offlineGuard = null;
    _requestClocks.clear();
  }

  @override
  Future<String> prepareOffline({
    required String eventId,
    required String assignmentId,
    required String title,
    required DateTime starts,
    required DateTime ends,
    required DateTime cutoff,
    required List<OfflineCheckpoint> checkpoints,
  }) => _exclusive(() async {
    _ensureCurrentAccount();
    final store = _store!;
    final staff = _staffUserId!;
    final prepare = _prepare;
    if (prepare == null) throw StateError('Offline preparation unavailable.');
    final epoch = ++_offlineEpoch;
    _offlineGuard = null;

    void ensureContext() {
      _ensureBoundAccount(store, staff);
      if (epoch != _offlineEpoch) {
        throw StateError('Offline preparation context changed.');
      }
    }

    try {
      if (await store.hasUnresolvedRecords()) {
        ensureContext();
        return 'Resolve the pending online attempt before preparing offline.';
      }
      ensureContext();
      final request = store.offlineRequest(eventId, assignmentId);
      final session = await _currentSession();
      ensureContext();
      if (session == null ||
          session.staffUserId != staff ||
          session.accessToken.isEmpty) {
        throw StateError('The preparation session does not match its owner.');
      }
      final dispatch = _PreparationClock();
      if (request.created) _requestClocks[request.id] = dispatch;
      final response = await prepare({
        'p_event_id': eventId,
        'p_request_id': request.id,
      }, session.accessToken);
      ensureContext();
      final parsed = OfflinePreparation.parse(
        response,
        eventId: eventId,
        assignmentId: assignmentId,
        staffId: staff,
        requestId: request.id,
      );
      if (parsed.title != title ||
          parsed.starts != starts.toUtc() ||
          parsed.ends != ends.toUtc() ||
          parsed.cutoff != cutoff.toUtc() ||
          parsed.checkpoints.length != checkpoints.length ||
          !parsed.checkpoints.every(
            (c) => checkpoints.any(
              (expected) => expected.id == c.id &&
                  expected.label == c.label &&
                  expected.direction == c.direction &&
                  expected.opens == c.opens &&
                  expected.closes == c.closes,
            ),
          )) {
        throw const FormatException('Preparation schedule changed.');
      }
      store.saveOfflinePreparation(parsed);
      final original = _requestClocks.remove(request.id);
      // A fresh issuance can use the current dispatch. An identical replay
      // needs the original dispatch from this account's uninterrupted process.
      final anchor = parsed.replayed ? original : dispatch;
      if (anchor == null) {
        return 'Original preparation recovered without a safe time anchor. Existing evidence is retained; prepare again when the old lease expires.';
      }
      _offlineGuard = OfflineTimeGuard(
        preparation: parsed,
        elapsed: () => anchor.stopwatch.elapsed,
        wallNow: () => DateTime.now().toUtc(),
        requestWall: anchor.wall,
        receivedElapsed: anchor.stopwatch.elapsed,
      );
      return 'Offline preparation saved. Enter offline capture mode explicitly.';
    } on PostgrestException catch (error) {
      ensureContext();
      if (error.code == '42501') {
        invalidateOffline();
        return 'Offline access could not be verified. Refresh assignments or contact support.';
      }
      if (error.code == '55000') {
        return 'A new preparation is not currently permitted. An earlier preparation may still be active; refresh and retry explicitly.';
      }
      return 'No valid preparation was confirmed. The request ID is retained; retry the same request or contact support.';
    } catch (_) {
      ensureContext();
      return 'No valid preparation was confirmed. The request ID is retained; retry explicitly.';
    }
  });

  @override
  OfflineClaim captureOffline({
    required String preparationId,
    required String checkpointId,
    required String studentId,
  }) {
    _ensureCurrentAccount();
    if (_operation != null) {
      throw StateError('Another attendance operation is in progress.');
    }
    final store = _store!;
    final staff = _staffUserId!;
    final guard = _offlineGuard;
    if (guard == null || guard.preparation.id != preparationId) {
      throw const OfflineCaptureException(
        'No safely prepared offline context. Reconnect and prepare again.',
      );
    }
    _ensureBoundAccount(store, staff);
    return store.createOfflineClaim(
      guard: guard,
      checkpointId: checkpointId,
      studentId: studentId,
    );
  }

  @override
  OfflineQueueCounts offlineCounts() {
    _ensureCurrentAccount();
    return _store!.offlineCounts();
  }

  @override
  List<OfflineClaim> recentOffline() {
    _ensureCurrentAccount();
    return _store!.readRecentOffline();
  }

  @override
  Future<String> syncOffline(
    void Function(OfflineQueueCounts) onProgress,
  ) => _exclusive(() async {
    _ensureCurrentAccount();
    final store = _store!;
    final staff = _staffUserId!;
    final upload = _upload;
    if (upload == null) throw StateError('Offline upload unavailable.');
    // Snapshot only this owner's unresolved claims; no client-clock cutoff
    // or preparation-expiry check can prevent a legitimate server replay.
    final queued = store.readQueuedOffline();
    for (final claim in queued) {
      _ensureBoundAccount(store, staff);
      if (claim.staffId != staff) {
        throw StateError('Offline claim owner mismatch.');
      }
      try {
        final session = await _currentSession();
        _ensureBoundAccount(store, staff);
        if (session == null ||
            session.staffUserId != staff ||
            session.accessToken.isEmpty) {
          return 'Sync paused: sign in as the original Staff account. Saved evidence is retained.';
        }
        final response = await upload(claim.parameters, session.accessToken);
        _ensureBoundAccount(store, staff);
        final acknowledgement = OfflineAcknowledgement.parse(response, claim);
        store.acknowledgeOffline(claim, acknowledgement);
        onProgress(store.offlineCounts());
      } on PostgrestException catch (error) {
        _ensureBoundAccount(store, staff);
        if (error.code == '23505' || error.code == '22023') {
          store.blockOffline(claim);
          onProgress(store.offlineCounts());
          return 'Sync paused: immutable evidence conflicts or is invalid. Contact support with the capture UUID; do not replace it.';
        }
        if (error.code == '42501') {
          invalidateOffline();
          return 'Sync paused: access could not be verified. Sign in again or contact support.';
        }
        if (error.code == '55000') {
          invalidateOffline();
          return 'Sync paused: the server is not accepting this claim. Contact support; the original UUID is retained.';
        }
        return 'Sync paused: no durable acknowledgement confirmed. Retry the original queued claim explicitly.';
      } catch (_) {
        _ensureBoundAccount(store, staff);
        return 'Sync paused: no durable acknowledgement confirmed. Retry the original queued claim explicitly.';
      }
    }
    return 'Upload pass finished. Submitted claims await review; local counts are not proof of completion.';
  });

  ScanAttemptResult _pendingResult(ScanRecord record) => ScanAttemptResult(
    record: record,
    message: 'No authoritative receipt was confirmed. This attempt is saved as pending. Retry it manually using the same scan ID.',
    retryAllowed: true,
  );

  Future<ScanAttemptResult> _handleBackendFailure(
    ScanRecord record,
    String? code, {
    required SecureAttendanceStore store,
  }) async {
    Future<void> markBlocked() async {
      try {
        await store.markBlocked(record.scanId);
      } catch (_) {
        // Preserve the pending record if the original account store is closed
        // or the local state cannot be updated.
      }
    }

    switch (code) {
      case '23505':
        await markBlocked();
        final blocked = ScanRecord(
          scanId: record.scanId,
          eventId: record.eventId,
          checkpointId: record.checkpointId,
          studentId: record.studentId,
          staffUserId: record.staffUserId,
          status: ScanStatus.blocked,
        );
        return ScanAttemptResult(
          record: blocked,
          message: 'This scan ID conflicts with existing Backend evidence. Do not create a replacement scan; contact support.',
          retryAllowed: false,
        );
      case '42501':
        return ScanAttemptResult(
          record: record,
          message: 'Access could not be verified. No receipt was confirmed. Sign in again or contact your event manager before retrying.',
          retryAllowed: true,
        );
      case '55000':
        return ScanAttemptResult(
          record: record,
          message: 'The event is not currently accepting new scans. No receipt was returned. Retry this same attempt only if the event is reopened.',
          retryAllowed: true,
        );
      case '22023':
        await markBlocked();
        return ScanAttemptResult(
          record: ScanRecord(
            scanId: record.scanId,
            eventId: record.eventId,
            checkpointId: record.checkpointId,
            studentId: record.studentId,
            staffUserId: record.staffUserId,
            status: ScanStatus.blocked,
          ),
          message: 'The Backend rejected this immutable scan payload. No receipt was returned. Do not create a replacement scan; contact support.',
          retryAllowed: false,
        );
      case '40001':
        return ScanAttemptResult(
          record: record,
          message: 'The Backend could not confirm durable receipt storage. This attempt remains pending; retry the same scan ID manually.',
          retryAllowed: true,
        );
      default:
        return ScanAttemptResult(
          record: record,
          message: 'No authoritative receipt was confirmed. This attempt is saved as pending. Retry it manually using the same scan ID.',
          retryAllowed: true,
        );
    }
  }

  _ParsedReceipt _parseReceipt(dynamic response, String expectedScanId) {
    if (response is! Map) {
      throw const FormatException('The Backend receipt was not an object.');
    }
    final json = Map<String, dynamic>.from(response);
    final scanId = json['scan_id'];
    final outcome = json['outcome'];
    final receivedAt = json['received_at'];
    final replayed = json['replayed'];
    if (scanId != expectedScanId ||
        outcome is! String ||
        !['accepted', 'rejected', 'duplicate'].contains(outcome) ||
        receivedAt is! String ||
        DateTime.tryParse(receivedAt) == null ||
        replayed is! bool) {
      throw const FormatException('The Backend receipt was malformed.');
    }
    return _ParsedReceipt(
      outcome: ScanStatus.values.byName(outcome),
      receivedAt: receivedAt,
      replayed: replayed,
    );
  }

  String _receiptMessage(_ParsedReceipt receipt) {
    final replay = receipt.replayed
        ? ' The original receipt was recovered.'
        : '';
    switch (receipt.outcome) {
      case ScanStatus.accepted:
        return 'Backend accepted the scan evidence. This is not finalized attendance.$replay';
      case ScanStatus.rejected:
        return 'Backend recorded a rejected attempt. The reason is not exposed.$replay';
      case ScanStatus.duplicate:
        return 'Backend recorded a duplicate attempt; no additional accepted capture was created.$replay';
      case ScanStatus.pending:
      case ScanStatus.blocked:
      case ScanStatus.legacy:
        throw StateError('A non-receipt status cannot be shown as a receipt.');
    }
  }

  void _ensureBoundAccount(SecureAttendanceStore store, String staffUserId) {
    if (!identical(_store, store) ||
        _staffUserId != staffUserId ||
        _currentStaffId() != staffUserId) {
      throw StateError('The authenticated Staff account changed.');
    }
  }

  void _ensureRecordAccount(
    ScanRecord record,
    SecureAttendanceStore store,
    String staffUserId,
  ) {
    if (record.staffUserId != staffUserId) {
      throw StateError(
        'The scan does not belong to the currently authenticated Staff account.',
      );
    }
    _ensureBoundAccount(store, staffUserId);
  }

  void _ensureCurrentAccount() {
    final staffId = _staffUserId;
    if (_store == null || staffId == null || _currentStaffId() != staffId) {
      throw StateError('The authenticated Staff account is unavailable.');
    }
  }
}

class _ParsedReceipt {
  const _ParsedReceipt({
    required this.outcome,
    required this.receivedAt,
    required this.replayed,
  });

  final ScanStatus outcome;
  final String receivedAt;
  final bool replayed;
}

class _PreparationClock {
  final wall = DateTime.now().toUtc();
  final stopwatch = Stopwatch()..start();
}
