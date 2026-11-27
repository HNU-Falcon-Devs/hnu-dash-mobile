import 'package:supabase_flutter/supabase_flutter.dart';

import 'development_scan_policy.dart';
import 'offline_capture.dart';
import 'offline_v2.dart';
import 'scan_ingestion.dart';
import 'secure_attendance_store.dart';

enum V2Rpc {
  prepare('prepare_offline_capture_v2'),
  status('get_offline_preparation_status_v2'),
  submit('submit_offline_capture_v2'),
  complete('complete_offline_preparation_v2');

  const V2Rpc(this.nameOnServer);

  final String nameOnServer;
}

typedef V2RpcCall =
    Future<dynamic> Function(
      V2Rpc operation,
      Map<String, dynamic> parameters,
      String bearer,
    );

Future<dynamic> pinnedV2Rpc(
  SupabaseClient client,
  V2Rpc operation,
  Map<String, dynamic> parameters,
  String bearer,
) => client
    .rpc(operation.nameOnServer, params: parameters)
    .setHeader('Authorization', 'Bearer $bearer');

class V2PendingQr {
  const V2PendingQr._(
    this.studentId,
    this.checkpointId,
    this.observation,
    this.warning,
  );

  final String studentId, checkpointId;
  final V2Observation observation;
  final V2Warning? warning;
}

/// Dormant fixture consumer. No application route, event discovery or
/// activation constructs this controller. A harness supplies only known
/// synthetic context and the existing securely restored session binding.
/// Account epoch must change on sign-out/switch, including A -> B -> A.
class OfflineV2Controller {
  OfflineV2Controller({
    required SecureAttendanceStore store,
    required CurrentStaffId currentStaffId,
    required int Function() accountEpoch,
    required CurrentStaffSession liveSession,
    required bool Function() foreground,
    required V2RpcCall rpc,
    V2Clock clock = observeAndroidClock,
  }) : _store = store,
       _owner = store.staffUserId,
       _currentStaffId = currentStaffId,
       _accountEpoch = accountEpoch,
       _ownerEpoch = accountEpoch(),
       _liveSession = liveSession,
       _foreground = foreground,
       _rpc = rpc,
       _clock = clock;

  final SecureAttendanceStore _store;
  final String _owner;
  final CurrentStaffId _currentStaffId;
  final int Function() _accountEpoch;
  final int _ownerEpoch;
  final CurrentStaffSession _liveSession;
  final bool Function() _foreground;
  final V2RpcCall _rpc;
  final V2Clock _clock;

  V2Scope? _scope;
  String? _selected;
  String? _checkpoint;
  bool _collecting = false;
  bool _invalidated = false;
  bool _busy = false;
  bool _captureOperation = false;
  int _networkEpoch = 0;
  int _segment = 0;
  V2PendingQr? _pending;
  bool _warningAccepted = false;
  final _warnings = V2Warnings();

  bool get collecting => _collecting;
  String? get selectedCheckpoint => _checkpoint;
  bool get accountAvailable =>
      !_invalidated &&
      _currentStaffId() == _owner &&
      _accountEpoch() == _ownerEpoch;

  void _ensureOwner() {
    if (!accountAvailable) {
      throw StateError('The original Staff session is unavailable.');
    }
  }

  void _ensureIdle() {
    _ensureOwner();
    if (_busy) throw StateError('Another operation is in progress.');
  }

  V2SavedPreparation? get selected {
    _ensureOwner();
    final id = _selected;
    return id == null ? null : _store.readV2Preparation(id);
  }

  V2Counts? get counts {
    _ensureOwner();
    final id = _selected;
    return id == null ? null : _store.v2Counts(id);
  }

  int get installationUnresolved {
    _ensureOwner();
    return _store.installationUnresolvedCount();
  }

  /// Select an injected fixture and recover the exact encrypted context.
  /// Does not perform login, network access, re-anchoring, or resume capture.
  void selectFixture(V2Scope scope) {
    _ensureIdle();
    stop();
    _scope = scope;
    _selected = null;
    _selected = _store.findV2Preparation(scope)?.preparation.id;
  }

  void stop() {
    _collecting = false;
    _checkpoint = null;
    _segment++;
    _pending = null;
    _warningAccepted = false;
    _warnings.reset();
  }

  void suspend() {
    stop();
    _networkEpoch++;
  }

  /// A new controller and newly opened owner-bound handle are required after
  /// sign-out/account change; close the original handle without deleting data.
  Future<void> invalidate() async {
    suspend();
    _invalidated = true;
    _selected = null;
    _scope = null;
    await _store.close();
  }

  void _ensureNetwork(int epoch) {
    _ensureOwner();
    if (!_foreground() || epoch != _networkEpoch) {
      throw StateError('Foreground operation interrupted; evidence retained.');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function(int epoch) operation) async {
    _ensureIdle();
    final epoch = _networkEpoch;
    _ensureNetwork(epoch);
    if (_collecting || _captureOperation) {
      throw StateError('Stop collecting before online actions.');
    }
    _busy = true;
    try {
      return await operation(epoch);
    } finally {
      _busy = false;
    }
  }

  Future<StaffScanSession> _session(int epoch) async {
    _ensureNetwork(epoch);
    final session = await _liveSession();
    _ensureNetwork(epoch);
    if (session == null ||
        session.staffUserId != _owner ||
        session.accessToken.isEmpty) {
      throw StateError('Live original Staff session is unavailable.');
    }
    return session;
  }

  Future<dynamic> _call(
    V2Rpc operation,
    Map<String, dynamic> parameters,
    StaffScanSession session,
    int epoch,
  ) async {
    _ensureNetwork(epoch);
    final result = await _rpc(operation, parameters, session.accessToken);
    _ensureNetwork(epoch);
    return result;
  }

  Future<void> prepare() => _exclusive((epoch) async {
    final scope = _scope;
    if (scope == null || _selected != null) {
      throw StateError('Select an unprepared synthetic fixture.');
    }
    final session = await _session(epoch);
    final start = await _clock();
    _ensureNetwork(epoch);
    final request = _store.reserveV2Request(scope, start);
    final raw = await _call(V2Rpc.prepare, {
      'p_event_id': scope.eventId,
      'p_assignment_id': scope.assignmentId,
      'p_request_id': request.id,
    }, session, epoch);
    final end = await _clock();
    _ensureNetwork(epoch);
    final preparation = V2Preparation.parse(raw, scope, _owner, request.id);
    final original = request.created && !preparation.replayed;
    final anchor = V2Anchor(
      request.observation,
      original ? end : null,
      original
          ? 'original'
          : preparation.replayed
          ? 'replayed'
          : 'unknown',
    );
    _store.saveV2Preparation(request, preparation, anchor);
    _selected = preparation.id;
  });

  /// Resume only the stored, originally authorized context. Offline recovery
  /// cannot refresh privileges or establish a new anchor. Backend may have
  /// closed or revoked the assignment while the device was disconnected.
  void resume() {
    _ensureIdle();
    final saved = selected;
    if (!_foreground() || saved == null || !saved.canCapture) {
      throw StateError('The original preparation cannot resume capture.');
    }
    stop();
    _collecting = true;
  }

  void selectCheckpoint(String id) {
    _ensureIdle();
    final saved = selected;
    if (!_collecting ||
        saved == null ||
        !saved.canCapture ||
        !saved.preparation.checkpoints.any((c) => c.id == id)) {
      throw StateError('Select a checkpoint in the original preparation.');
    }
    if (_checkpoint != id) {
      _segment++;
      _pending = null;
      _warningAccepted = false;
      _warnings.reset();
      _checkpoint = id;
    }
  }

  OfflineCheckpoint _captureContext() {
    _ensureIdle();
    final saved = selected;
    if (!_foreground() ||
        !_collecting ||
        saved == null ||
        !saved.canCapture ||
        _checkpoint == null) {
      throw StateError('Local capture is unavailable.');
    }
    return saved.preparation.checkpoints.singleWhere(
      (c) => c.id == _checkpoint,
    );
  }

  /// Called at validated QR callback, BEFORE camera shutdown/confirmation.
  /// No live session lookup or RPC is performed in the capture path.
  Future<V2PendingQr> observeQr(String studentId) async {
    final checkpoint = _captureContext();
    if (!isApprovedDevelopmentStudentId(studentId) ||
        _pending != null || _captureOperation) {
      throw StateError('Approved synthetic QR required.');
    }
    final segment = _segment;
    _captureOperation = true;
    final V2Observation qr;
    try {
      qr = await _clock();
    } finally {
      _captureOperation = false;
    }
    _captureContext();
    if (_segment != segment || _pending != null) {
      throw StateError('Collection segment changed.');
    }
    final pending = V2PendingQr._(
      studentId,
      checkpoint.id,
      qr,
      _warnings.observe(checkpoint, qr),
    );
    _pending = pending;
    _warningAccepted = false;
    return pending;
  }

  void continueAfterWarning(V2PendingQr pending) {
    _captureContext();
    if (!identical(_pending, pending) || pending.warning == null) {
      throw StateError('The warning is no longer current.');
    }
    _warnings.acknowledge();
    _warningAccepted = true;
  }

  void cancelQr() {
    _pending = null;
    _warningAccepted = false;
  }

  Future<V2Claim> confirm(V2PendingQr pending) async {
    _captureContext();
    if (_captureOperation || !identical(_pending, pending) ||
        (pending.warning != null && !_warningAccepted)) {
      throw StateError('Explicit warning continuation and confirmation required.');
    }
    final segment = _segment;
    final id = _selected!;
    // Prevent duplicate confirmation even while the native clock is sampled.
    _pending = null;
    _warningAccepted = false;
    _captureOperation = true;
    final V2Observation confirmation;
    try {
      confirmation = await _clock();
    } finally {
      _captureOperation = false;
    }
    _captureContext();
    if (_segment != segment || _selected != id) {
      throw StateError('Collection segment changed.');
    }
    return _store.createV2Claim(
      preparationId: id,
      checkpointId: pending.checkpointId,
      studentId: pending.studentId,
      qr: pending.observation,
      confirmation: confirmation,
    );
  }

  String _selectedId() {
    final id = _selected;
    if (id == null) throw StateError('Select a saved preparation.');
    _store.readV2Preparation(id);
    return id;
  }

  Future<V2Status> _status(String id, int epoch) async {
    try {
      final session = await _session(epoch);
      final raw = await _call(V2Rpc.status, {
        'p_preparation_id': id,
      }, session, epoch);
      final status = V2Status.parse(raw, id);
      _store.recordV2Status(id, status);
      return status;
    } on PostgrestException catch (error) {
      _ensureNetwork(epoch);
      if (error.code == '42501' || error.code == '55000') {
        _store.stopV2Capture(id);
      }
      rethrow;
    } on FormatException {
      _ensureNetwork(epoch);
      // Wrong-policy/malformed responses are unsafe to recover from locally.
      _store.stopV2Capture(id);
      rethrow;
    }
  }

  Future<V2Status> checkStatus() =>
      _exclusive((epoch) => _status(_selectedId(), epoch));

  /// Sequential foreground dispatch for exactly one selected preparation.
  /// The server alone decides the current deadline. A closed status permits
  /// only previously attempted immutable payloads to be replayed.
  Future<void> sync() => _exclusive((epoch) async {
    final id = _selectedId();
    final status = await _status(id, epoch);
    final claims = _store.unresolvedV2Claims(id);
    for (final claim in claims) {
      _ensureNetwork(epoch);
      if (claim.state == V2ClaimState.blocked ||
          (claim.state == V2ClaimState.queued && !status.permitsNewUpload)) {
        throw StateError('Upload is paused; original evidence retained.');
      }
      final session = await _session(epoch);
      _store.markV2Attempted(claim);
      try {
        final raw = await _call(
          V2Rpc.submit,
          claim.parameters,
          session,
          epoch,
        );
        _store.acknowledgeV2(claim, raw);
      } on PostgrestException catch (error) {
        _ensureNetwork(epoch);
        if (error.code == '23505' || error.code == '22023') {
          _store.blockV2(claim);
        } else if (error.code == '55000' ||
            (error.code == '42501' && claim.state == V2ClaimState.queued)) {
          _store.markV2NotAdmitted(claim);
        }
        if (error.code == '42501') _store.stopV2Capture(id);
        rethrow;
      }
    }
  });

  /// Explicit count declaration; zero is valid. A lost response retains the
  /// original intent and retries that count, even after terminal accounting.
  Future<void> complete(int confirmedCount) => _exclusive((epoch) async {
    final id = _selectedId();
    final status = await _status(id, epoch);
    final saved = _store.readV2Preparation(id);
    final counts = _store.v2Counts(id);
    if (counts.unresolved != 0 ||
        counts.submitted != confirmedCount ||
        status.count != confirmedCount ||
        (saved.intent != null && saved.intent != confirmedCount)) {
      throw StateError('The local and authoritative counts do not agree.');
    }
    if (status.disposition == 'completed' &&
        (saved.intent == null || saved.completionReceipt != null)) {
      return; // No new completion or fabricated local receipt.
    }
    if (status.disposition != null && status.disposition != 'completed' ||
        (status.disposition == null && status.state != 'SYNCING')) {
      throw StateError('Preparation cannot be completed.');
    }
    _store.persistV2CompletionIntent(id, confirmedCount);
    final session = await _session(epoch);
    final raw = await _call(V2Rpc.complete, {
      'p_preparation_id': id,
      'p_acknowledged_count': confirmedCount,
    }, session, epoch);
    _store.recordV2Completion(id, raw);
  });
}
