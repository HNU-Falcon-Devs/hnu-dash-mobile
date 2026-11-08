import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

typedef CurrentStaffId = String? Function();
typedef AttendanceScanRpc = Future<dynamic> Function(
  Map<String, dynamic> parameters,
);
typedef AttendanceStoreOpener = Future<SecureAttendanceStore> Function(
  String staffUserId,
);

class SupabaseStaffScanGateway implements StaffScanGateway {
  SupabaseStaffScanGateway.forSupabase(
    SupabaseClient client, {
    required SecureValueStore secureValues,
  }) : this._(
         currentStaffId: () => client.auth.currentUser?.id,
         ingest: (parameters) =>
             client.rpc('ingest_attendance_scan', params: parameters),
         openStore: (staffUserId) => SecureAttendanceStore.openOnDevice(
           staffUserId: staffUserId,
           keyStore: secureValues,
         ),
       );

  @visibleForTesting
  SupabaseStaffScanGateway.test({
    required CurrentStaffId currentStaffId,
    required AttendanceScanRpc ingest,
    required AttendanceStoreOpener openStore,
  }) : this._(
         currentStaffId: currentStaffId,
         ingest: ingest,
         openStore: openStore,
       );

  SupabaseStaffScanGateway._({
    required this._currentStaffId,
    required this._ingest,
    required this._openStore,
  });

  final CurrentStaffId _currentStaffId;
  final AttendanceScanRpc _ingest;
  final AttendanceStoreOpener _openStore;
  SecureAttendanceStore? _store;
  String? _staffUserId;

  @override
  Future<void> openForAccount(String staffUserId) async {
    if (_currentStaffId() != staffUserId) {
      throw StateError('The authenticated Staff account changed.');
    }
    if (_staffUserId == staffUserId && _store != null) return;

    await close();
    final store = await _openStore(staffUserId);
    if (_currentStaffId() != staffUserId) {
      await store.close();
      throw StateError('The authenticated Staff account changed.');
    }
    _store = store;
    _staffUserId = staffUserId;
  }

  @override
  Future<void> close() async {
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
  }) async {
    _ensureCurrentAccount();
    if (await _store!.hasUnresolvedRecords()) {
      return const ScanAttemptResult(
        record: null,
        message:
            'Resolve the existing pending attempt before scanning another ID.',
        retryAllowed: false,
      );
    }

    final record = await _store!.createPending(
      eventId: eventId,
      checkpointId: checkpointId,
      studentId: studentId,
    );
    return _submit(record);
  }

  @override
  Future<ScanAttemptResult> retry(String scanId) async {
    _ensureCurrentAccount();
    final record = await _store!.findPending(scanId);
    if (record == null) {
      return const ScanAttemptResult(
        record: null,
        message:
            'This pending attempt is no longer available for this account.',
        retryAllowed: false,
      );
    }
    return _submit(record);
  }

  Future<ScanAttemptResult> _submit(ScanRecord record) async {
    _ensureRecordAccount(record);
    try {
      final response = await _ingest({
        'p_scan_id': record.scanId,
        'p_event_id': record.eventId,
        'p_checkpoint_id': record.checkpointId,
        'p_student_id': record.studentId,
      });
      _ensureRecordAccount(record);
      final receipt = _parseReceipt(response, record.scanId);
      await _store!.recordReceipt(
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
      return await _handleBackendFailure(record, error.code);
    } catch (_) {
      return ScanAttemptResult(
        record: record,
        message: 'No authoritative receipt was confirmed. This attempt is saved as pending. Retry it manually using the same scan ID.',
        retryAllowed: true,
      );
    }
  }

  Future<ScanAttemptResult> _handleBackendFailure(
    ScanRecord record,
    String? code,
  ) async {
    switch (code) {
      case '23505':
        try {
          await _store!.markBlocked(record.scanId);
        } catch (_) {
          // Preserve the pending record if the local state cannot be updated.
        }
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
        try {
          await _store!.markBlocked(record.scanId);
        } catch (_) {
          // Preserve the pending record if the local state cannot be updated.
        }
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

  void _ensureRecordAccount(ScanRecord record) {
    final owner = record.staffUserId;
    if (owner == null ||
        _store == null ||
        _staffUserId != owner ||
        _currentStaffId() != owner) {
      throw StateError(
        'The scan does not belong to the currently authenticated Staff account.',
      );
    }
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
