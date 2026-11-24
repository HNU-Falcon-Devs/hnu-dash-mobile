import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'development_scan_policy.dart';
import 'offline_capture.dart';
import 'scan_ingestion.dart';
import 'secure_attendance_store.dart';
import 'student_qr_scanner.dart';

abstract class StaffGateway {
  String? get account;
  Stream<String?> get authChanges;
  Future<void> signIn();
  Future<void> signOut();
  Future<List<StaffEvent>> events();
  Future<List<Checkpoint>> checkpoints(String eventId);
}

class StaffEvent {
  const StaffEvent(
    this.id,
    this.title,
    this.start,
    this.end,
    this.state, {
    this.assignmentId,
    this.offlineEnabled = false,
    this.uploadCutoff,
  });
  final String id, title, state;
  final DateTime start, end;
  final String? assignmentId;
  final bool offlineEnabled;
  final DateTime? uploadCutoff;

  factory StaffEvent.fromJson(
    Map<String, dynamic> json, {
    String? assignmentId,
  }) => StaffEvent(
    json['id'] as String,
    json['title'] as String,
    DateTime.parse(json['starts_at'] as String),
    DateTime.parse(json['ends_at'] as String),
    json['state'] as String,
    assignmentId: assignmentId,
    offlineEnabled: json['offline_enabled'] == true,
    uploadCutoff: json['offline_upload_cutoff'] == null
        ? null
        : offlineInstant(json['offline_upload_cutoff']),
  );
}

class Checkpoint {
  const Checkpoint(this.id, this.label, this.direction, this.start, this.end);

  final String id, label, direction;
  final DateTime start, end;

  factory Checkpoint.fromJson(Map<String, dynamic> json) => Checkpoint(
    json['id'] as String,
    json['label'] as String,
    json['direction'] as String,
    DateTime.parse(json['opens_at'] as String),
    DateTime.parse(json['closes_at'] as String),
  );
}

class SupabaseStaffGateway implements StaffGateway {
  SupabaseStaffGateway(this.client);

  final SupabaseClient client;
  static const redirect = 'dev.hnudash.mobile://login-callback';

  @override
  String? get account => client.auth.currentSession?.user.id;

  @override
  Stream<String?> get authChanges =>
      client.auth.onAuthStateChange.map((event) => event.session?.user.id);

  @override
  Future<void> signIn() async {
    final launched = await client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: redirect,
      authScreenLaunchMode: LaunchMode.externalApplication,
    );
    if (!launched) throw StateError('Could not open Google sign-in.');
  }

  @override
  Future<void> signOut() => client.auth.signOut();

  @override
  Future<List<StaffEvent>> events() async {
    final id = account;
    if (id == null) throw StateError('Session expired');
    final assignments = await client
        .from('event_staff')
        .select('id,event_id')
        .eq('staff_user_id', id)
        .isFilter('revoked_at', null);
    if (account != id) throw StateError('Session changed');
    final assignmentIds = {
      for (final row in assignments)
        row['event_id'] as String: row['id'] as String,
    };
    final ids = assignmentIds.keys.toList();
    if (ids.isEmpty) return [];
    final rows = await client
        .from('events')
        .select('id,title,starts_at,ends_at,state,offline_enabled,offline_upload_cutoff')
        .inFilter('id', ids)
        .order('starts_at');
    if (account != id) throw StateError('Session changed');
    return rows
        .map(
          (row) => StaffEvent.fromJson(
            row,
            assignmentId: assignmentIds[row['id']],
          ),
        )
        .toList();
  }

  @override
  Future<List<Checkpoint>> checkpoints(String eventId) async {
    final id = account;
    if (id == null) throw StateError('Session expired');
    final allowed = await client.rpc(
      'can_access_assigned_event',
      params: {'eid': eventId},
    );
    if (allowed != true || account != id) throw StateError('Access revoked');
    final rows = await client
        .from('event_checkpoints')
        .select('id,label,direction,opens_at,closes_at')
        .eq('event_id', eventId)
        .order('sort_order');
    if (account != id) throw StateError('Session changed');
    return rows.map((row) => Checkpoint.fromJson(row)).toList();
  }
}

String manilaTime(DateTime time) {
  final date = time.toUtc().add(const Duration(hours: 8));
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${pad(date.month)}-${pad(date.day)} '
      '${pad(date.hour)}:${pad(date.minute)} PHT';
}

class StaffWorkspace extends StatefulWidget {
  const StaffWorkspace({
    super.key,
    required this.gateway,
    this.scanGateway,
    this.scannerPageBuilder,
  });

  final StaffGateway gateway;
  final StaffScanGateway? scanGateway;
  final Widget Function()? scannerPageBuilder;

  @override
  State<StaffWorkspace> createState() => _StaffWorkspaceState();
}

class _StaffWorkspaceState extends State<StaffWorkspace>
    with WidgetsBindingObserver {
  StreamSubscription<String?>? _auth;
  String? _account;
  List<StaffEvent> _events = [];
  StaffEvent? _selected;
  List<Checkpoint> _checkpoints = [];
  Checkpoint? _selectedCheckpoint;
  String? _error;
  bool _busy = false;
  int _epoch = 0;
  int _accountEpoch = 0;

  OfflinePreparation? _offlinePreparation;
  OfflineCheckpoint? _offlineCheckpoint;
  OfflineQueueCounts _offlineCounts = const OfflineQueueCounts(0, 0, 0);
  List<OfflineClaim> _offlineRecords = [];
  bool _offlineMode = false;
  bool _foreground = true;
  int _syncEpoch = 0;
  int _offlineOffset = 0;
  Timer? _offlineTimer;

  OfflineScanGateway? get _offlineGateway {
    final Object? gateway = widget.scanGateway;
    return gateway is OfflineScanGateway ? gateway : null;
  }

  List<ScanRecord> _scanRecords = [];
  bool _scanStoreReady = false;
  bool _scanBusy = false;
  bool _hasUnresolvedScans = false;
  int _scanEpoch = 0;
  String? _scanStoreError;
  String? _scanMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = widget.gateway.account;
    _auth = widget.gateway.authChanges.listen(
      _onAuth,
      onError: (Object _) => _onAuth(null),
    );
    if (_account != null) {
      _refresh();
      _bindScanAccount(_account!);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _syncEpoch++;
      return;
    }
    if (widget.gateway.account != _account) {
      _onAuth(widget.gateway.account);
    } else if (_account != null) {
      if (!_offlineMode && !_scanBusy) _refresh();
      if (!_scanBusy) _refreshScanRecords(_account!);
    }
  }

  void _clear() {
    _epoch++;
    _scanEpoch++;
    _accountEpoch++;
    _syncEpoch++;
    _offlineTimer?.cancel();
    setState(() {
      _events = [];
      _selected = null;
      _checkpoints = [];
      _selectedCheckpoint = null;
      _error = null;
      _busy = false;
      _scanRecords = [];
      _scanStoreReady = false;
      _scanBusy = false;
      _hasUnresolvedScans = false;
      _scanStoreError = null;
      _scanMessage = null;
      _offlineMode = false;
      _offlinePreparation = null;
      _offlineCheckpoint = null;
      _offlineCounts = const OfflineQueueCounts(0, 0, 0);
      _offlineRecords = [];
      _offlineOffset = 0;
    });
  }

  void _onAuth(String? id) {
    if (!mounted) return;
    if (id != _account) {
      _account = id;
      _clear();
      if (id != null) {
        _refresh();
        _bindScanAccount(id);
      } else {
        unawaited(widget.scanGateway?.close());
      }
    } else if (id == null) {
      _clear();
      unawaited(widget.scanGateway?.close());
    }
  }

  bool _valid(int version, String id) =>
      mounted &&
      version == _epoch &&
      _account == id &&
      widget.gateway.account == id;

  bool _validScan(int version, String id) =>
      mounted &&
      version == _scanEpoch &&
      _account == id &&
      widget.gateway.account == id;

  Future<void> _bindScanAccount(String id) async {
    final gateway = widget.scanGateway;
    if (gateway == null) return;
    final version = ++_scanEpoch;
    setState(() {
      _scanRecords = [];
      _scanStoreReady = false;
      _scanStoreError = null;
      _scanMessage = null;
      _hasUnresolvedScans = false;
    });
    try {
      await gateway.close();
      if (!_validScan(version, id)) return;
      await gateway.openForAccount(id);
      if (!_validScan(version, id)) return;
      final records = await gateway.readRecent();
      final unresolved = await gateway.hasUnresolvedRecords();
      if (!_validScan(version, id)) return;
      final offline = _offlineGateway;
      final counts = offline?.offlineCounts();
      final offlineRecords = offline?.recentOffline();
      final preparation = offline?.activePreparation;
      setState(() {
        _scanRecords = records;
        _hasUnresolvedScans = unresolved;
        _scanStoreReady = true;
        _offlineCounts = counts ?? const OfflineQueueCounts(0, 0, 0);
        _offlineRecords = offlineRecords ?? [];
        _offlineOffset = 0;
        _offlinePreparation = preparation;
      });
    } catch (_) {
      if (!_validScan(version, id)) return;
      setState(() {
        _scanStoreReady = false;
        _scanStoreError = 'Secure attendance storage could not be opened. Scanning is disabled; existing records have been preserved.';
      });
    }
  }

  Future<void> _refreshScanRecords(String id) async {
    final gateway = widget.scanGateway;
    if (gateway == null || !_scanStoreReady) return;
    final version = ++_scanEpoch;
    try {
      final records = await gateway.readRecent();
      final unresolved = await gateway.hasUnresolvedRecords();
      if (!_validScan(version, id)) return;
      final offline = _offlineGateway;
      final counts = offline?.offlineCounts();
      final offlineRecords = offline?.recentOffline();
      final preparation = offline?.activePreparation;
      setState(() {
        _scanRecords = records;
        _hasUnresolvedScans = unresolved;
        _offlineCounts = counts ?? const OfflineQueueCounts(0, 0, 0);
        _offlineRecords = offlineRecords ?? [];
        _offlineOffset = 0;
        _offlinePreparation = preparation;
        if (preparation == null) {
          _offlineMode = false;
          _offlineCheckpoint = null;
          _offlineTimer?.cancel();
        }
      });
    } catch (_) {
      if (!_validScan(version, id)) return;
      setState(() {
        _scanStoreError =
            'Local attendance records could not be read. Scanning is disabled.';
        _scanStoreReady = false;
        _scanRecords = [];
        _hasUnresolvedScans = true;
        _offlineMode = false;
        _offlinePreparation = null;
        _offlineCheckpoint = null;
        _offlineRecords = [];
        _offlineCounts = const OfflineQueueCounts(0, 0, 0);
        _offlineTimer?.cancel();
      });
    }
  }

  Future<void> _refresh() async {
    final id = _account;
    if (id == null || _offlineMode || _scanBusy) return;
    final version = ++_epoch;
    setState(() {
      _events = [];
      _selected = null;
      _checkpoints = [];
      _selectedCheckpoint = null;
      _busy = true;
      _error = null;
    });
    try {
      final items = await widget.gateway.events();
      if (!_valid(version, id)) return;
      final prepared = _offlinePreparation;
      if (prepared != null &&
          !items.any(
            (event) =>
                event.id == prepared.eventId &&
                event.assignmentId == prepared.assignmentId &&
                event.state == 'OPEN' &&
                event.offlineEnabled &&
                event.uploadCutoff == prepared.cutoff,
          )) {
        _invalidateOffline();
      }
      setState(() {
        _events = items;
        _busy = false;
      });
    } catch (_) {
      if (!_valid(version, id)) return;
      setState(() {
        _busy = false;
        _error = 'Could not load events. Check your session, permissions, and connection.';
      });
    }
  }

  Future<void> _open(StaffEvent event) async {
    final id = _account;
    if (id == null || _offlineMode || _scanBusy) return;
    final version = ++_epoch;
    setState(() {
      _selected = event;
      _checkpoints = [];
      _selectedCheckpoint = null;
      _error = null;
      _busy = true;
    });
    try {
      final items = await widget.gateway.checkpoints(event.id);
      if (!_valid(version, id)) return;
      setState(() {
        _checkpoints = items;
        _busy = false;
      });
    } catch (_) {
      if (!_valid(version, id)) return;
      if (_offlinePreparation?.eventId == event.id) _invalidateOffline();
      setState(() {
        _events = [];
        _selected = null;
        _checkpoints = [];
        _selectedCheckpoint = null;
        _busy = false;
        _error = 'Event access could not be verified. Refresh assignments.';
      });
    }
  }

  Future<void> _startScan() async {
    final event = _selected;
    final checkpoint = _selectedCheckpoint;
    final account = _account;
    final scanGateway = widget.scanGateway;
    final generation = _accountEpoch;
    if (event == null ||
        checkpoint == null ||
        account == null ||
        scanGateway == null ||
        event.state != 'OPEN' ||
        _offlineMode ||
        !_scanStoreReady ||
        _scanBusy ||
        _hasUnresolvedScans) {
      return;
    }

    final studentId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            widget.scannerPageBuilder?.call() ?? const StudentQrScannerPage(),
      ),
    );
    if (studentId == null ||
        !mounted ||
        !_validScanAccount(account, generation) ||
        !isApprovedDevelopmentStudentId(studentId)) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm attendance scan'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Event: ${event.title}'),
            Text('Checkpoint: ${checkpoint.label} (${checkpoint.direction})'),
            Text('Student ID: ${maskStudentId(studentId)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm scan'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !_validScanAccount(account, generation) ||
        canonicalStudentId(studentId) == null) {
      return;
    }

    setState(() {
      _scanBusy = true;
      _scanMessage = null;
    });
    try {
      final result = await scanGateway.capture(
        eventId: event.id,
        checkpointId: checkpoint.id,
        studentId: studentId,
      );
      if (!mounted || !_validScanAccount(account, generation)) return;
      setState(() {
        _scanBusy = false;
        _scanMessage = result.message;
      });
      await _refreshScanRecords(account);
    } catch (_) {
      if (!mounted || !_validScanAccount(account, generation)) return;
      setState(() {
        _scanBusy = false;
        _scanMessage = 'The attempt could not be saved securely. No Backend receipt is confirmed; do not scan again until storage is checked.';
      });
      await _refreshScanRecords(account);
    }
  }

  bool _validScanAccount(String id, int generation) =>
      mounted &&
      _accountEpoch == generation &&
      _account == id &&
      widget.gateway.account == id;

  Future<void> _retryScan(ScanRecord record) async {
    final account = _account;
    final scanGateway = widget.scanGateway;
    final generation = _accountEpoch;
    if (account == null ||
        scanGateway == null ||
        record.status != ScanStatus.pending ||
        _offlineMode ||
        _scanBusy ||
        !_scanStoreReady) {
      return;
    }
    setState(() {
      _scanBusy = true;
      _scanMessage = null;
    });
    try {
      final result = await scanGateway.retry(record.scanId);
      if (!mounted || !_validScanAccount(account, generation)) return;
      setState(() {
        _scanBusy = false;
        _scanMessage = result.message;
      });
      await _refreshScanRecords(account);
    } catch (_) {
      if (!mounted || !_validScanAccount(account, generation)) return;
      setState(() {
        _scanBusy = false;
        _scanMessage = 'The same pending attempt could not be retried. No new scan was created.';
      });
      await _refreshScanRecords(account);
    }
  }

  void _invalidateOffline() {
    _offlineGateway?.invalidateOffline();
    _offlineTimer?.cancel();
    setState(() {
      _offlineMode = false;
      _offlinePreparation = null;
      _offlineCheckpoint = null;
    });
  }

  Future<void> _prepareOffline() async {
    final gateway = _offlineGateway;
    final event = _selected;
    final account = _account;
    final generation = _accountEpoch;
    if (gateway == null ||
        event == null ||
        account == null ||
        event.assignmentId == null ||
        event.uploadCutoff == null ||
        event.state != 'OPEN' ||
        !event.offlineEnabled ||
        _busy ||
        _scanBusy ||
        !_scanStoreReady ||
        _hasUnresolvedScans ||
        _checkpoints.isEmpty) {
      return;
    }
    final checkpoints = _checkpoints
        .map(
          (c) => OfflineCheckpoint(c.id, c.label, c.direction, c.start, c.end),
        )
        .toList();
    setState(() {
      _scanBusy = true;
      _scanMessage = null;
    });
    try {
      final message = await gateway.prepareOffline(
        eventId: event.id,
        assignmentId: event.assignmentId!,
        title: event.title,
        starts: event.start,
        ends: event.end,
        cutoff: event.uploadCutoff!,
        checkpoints: checkpoints,
      );
      if (!_validScanAccount(account, generation)) return;
      setState(() => _scanMessage = message);
      await _refreshScanRecords(account);
    } catch (_) {
      if (!_validScanAccount(account, generation)) return;
      setState(() {
        _scanMessage = 'Offline preparation could not be verified. Existing evidence is retained.';
      });
    } finally {
      if (_validScanAccount(account, generation)) {
        setState(() => _scanBusy = false);
      }
    }
  }

  void _enterOffline() {
    final gateway = _offlineGateway;
    if (gateway == null ||
        !_scanStoreReady ||
        _scanBusy ||
        _busy ||
        _hasUnresolvedScans) {
      return;
    }
    try {
      final preparation = gateway.activePreparation;
      if (preparation == null) {
        setState(() {
          _offlinePreparation = null;
          _scanMessage = 'No valid offline time anchor. Reconnect and prepare again.';
        });
        return;
      }
      setState(() {
        _offlinePreparation = preparation;
        _offlineMode = true;
        _offlineCheckpoint = null;
        _scanMessage = null;
      });
      _offlineTimer?.cancel();
      _offlineTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !_offlineMode) return;
        try {
          if (gateway.activePreparation == null) {
            _invalidateOffline();
            setState(() {
              _scanMessage = 'Offline capture context expired or became unsafe. Reconnect and prepare again. Saved claims are retained.';
            });
          } else {
            setState(() {});
          }
        } catch (_) {
          _invalidateOffline();
        }
      });
    } catch (_) {
      setState(() {
        _scanMessage = 'Offline capture is unavailable. Check secure storage and sign-in.';
      });
    }
  }

  void _exitOffline() {
    _offlineTimer?.cancel();
    setState(() {
      _offlineMode = false;
      _offlineCheckpoint = null;
    });
  }

  bool get _canCaptureOffline {
    final preparation = _offlinePreparation;
    final checkpoint = _offlineCheckpoint;
    final gateway = _offlineGateway;
    if (!_offlineMode ||
        !_scanStoreReady ||
        _scanBusy ||
        _hasUnresolvedScans ||
        preparation == null ||
        checkpoint == null ||
        gateway == null) {
      return false;
    }
    try {
      return gateway.canCaptureOffline(preparation.id, checkpoint.id);
    } catch (_) {
      return false;
    }
  }

  Future<void> _startOfflineCapture() async {
    final preparation = _offlinePreparation;
    final checkpoint = _offlineCheckpoint;
    final account = _account;
    final gateway = _offlineGateway;
    final generation = _accountEpoch;
    if (!_canCaptureOffline ||
        preparation == null ||
        checkpoint == null ||
        account == null ||
        gateway == null) {
      return;
    }
    setState(() {
      _scanBusy = true;
      _scanMessage = null;
    });
    bool valid() =>
        _validScanAccount(account, generation) &&
        _offlineMode &&
        _offlinePreparation?.id == preparation.id &&
        _offlineCheckpoint?.id == checkpoint.id;
    try {
      final studentId = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) =>
              widget.scannerPageBuilder?.call() ?? const StudentQrScannerPage(),
        ),
      );
      if (studentId == null ||
          !valid() ||
          !isApprovedDevelopmentStudentId(studentId)) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm offline capture'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Event: ${preparation.title}'),
              Text('Checkpoint: ${checkpoint.label} (${checkpoint.direction})'),
              Text('Student ID: ${maskStudentId(studentId)}'),
              const Text('Save locally as unverified evidence, not attendance.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save offline claim'),
            ),
          ],
        ),
      );
      if (confirmed != true || !valid()) return;
      gateway.captureOffline(
        preparationId: preparation.id,
        checkpointId: checkpoint.id,
        studentId: studentId,
      );
      if (!_validScanAccount(account, generation)) return;
      setState(() {
        _scanMessage = 'Saved locally — unverified offline claim. No upload or attendance acceptance was performed.';
      });
      await _refreshScanRecords(account);
    } on OfflineCaptureException catch (error) {
      if (!_validScanAccount(account, generation)) return;
      setState(() => _scanMessage = error.message);
    } catch (_) {
      if (!_validScanAccount(account, generation)) return;
      setState(() {
        _scanMessage = 'The offline claim could not be saved securely. Existing evidence is retained; reload before retrying.';
      });
      await _refreshScanRecords(account);
    } finally {
      if (_validScanAccount(account, generation)) {
        setState(() => _scanBusy = false);
      }
    }
  }

  Future<void> _syncOffline() async {
    final gateway = _offlineGateway;
    final account = _account;
    final generation = _accountEpoch;
    final syncEpoch = _syncEpoch;
    if (gateway == null ||
        account == null ||
        !_foreground ||
        !_scanStoreReady ||
        _scanBusy ||
        _offlineCounts.queued == 0) {
      return;
    }
    setState(() {
      _scanBusy = true;
      _scanMessage = null;
    });
    try {
      final message = await gateway.syncOffline(
        (counts) {
          if (!_validScanAccount(account, generation)) return;
          setState(() => _offlineCounts = counts);
        },
        shouldContinue: () =>
            _foreground &&
            _syncEpoch == syncEpoch &&
            _validScanAccount(account, generation),
      );
      if (!_validScanAccount(account, generation)) return;
      setState(() => _scanMessage = message);
      await _refreshScanRecords(account);
    } catch (_) {
      if (!_validScanAccount(account, generation)) return;
      setState(() {
        _scanMessage = 'Sync interrupted. No unconfirmed claim was removed. Reload and retry explicitly.';
      });
      await _refreshScanRecords(account);
    } finally {
      if (_validScanAccount(account, generation)) {
        setState(() => _scanBusy = false);
      }
    }
  }

  int get _offlineTotal =>
      _offlineCounts.queued + _offlineCounts.submitted + _offlineCounts.blocked;

  void _pageOfflineRecords(int offset) {
    if (_scanBusy || offset < 0 || offset >= _offlineTotal) return;
    try {
      final records = _offlineGateway!.recentOffline(offset: offset);
      setState(() {
        _offlineRecords = records;
        _offlineOffset = offset;
      });
    } catch (_) {
      setState(() {
        _scanMessage = 'Offline evidence could not be reloaded securely.';
      });
    }
  }

  Widget _offlineRecordCard(OfflineClaim claim) {
    final status = switch (claim.status) {
      OfflineClaimStatus.queued => 'LOCALLY QUEUED — unverified',
      OfflineClaimStatus.submitted => 'SUBMITTED — awaiting review',
      OfflineClaimStatus.blocked => 'BLOCKED — contact support',
    };
    return Card(
      child: ListTile(
        title: Text(status),
        subtitle: Text(
          'Student ID: ${maskStudentId(claim.studentId)}\n'
          'Claimed: ${manilaTime(claim.claimedAt)} (untrusted)\n'
          'Capture UUID: ${claim.id}',
        ),
        isThreeLine: true,
      ),
    );
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.gateway.signIn();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Google sign-in could not start. Check OAuth setup.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    _account = null;
    _clear();
    try {
      await widget.scanGateway?.close();
    } catch (_) {
      // Keep the UI cleared and continue signing out.
    }
    if (mounted) setState(() => _busy = true);
    try {
      await widget.gateway.signOut();
    } catch (_) {
      if (mounted) setState(() => _error = 'Sign-out failed. Please retry.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (widget.gateway.account != null) _onAuth(widget.gateway.account);
      }
    }
  }

  String _statusLabel(ScanStatus status) => switch (status) {
    ScanStatus.pending => 'PENDING — no Backend receipt',
    ScanStatus.accepted => 'ACCEPTED — evidence received',
    ScanStatus.rejected => 'REJECTED — attempt recorded',
    ScanStatus.duplicate => 'DUPLICATE — no new accepted capture',
    ScanStatus.blocked => 'BLOCKED — contact support',
    ScanStatus.legacy => 'LEGACY — unassigned',
  };

  Widget _scanRecordCard(ScanRecord record) {
    final receipt = record.receivedAt;
    final subtitle = record.status == ScanStatus.blocked
        ? 'Student ID: ${maskStudentId(record.studentId)}\n'
              'Terminal conflict — no retry. Contact support with scan UUID '
              '${record.scanId}. Original evidence is preserved.'
        : receipt == null
        ? 'Student ID: ${maskStudentId(record.studentId)}\nNo authoritative receipt is stored.'
        : 'Student ID: ${maskStudentId(record.studentId)}\n'
              'Backend received: ${manilaTime(DateTime.parse(receipt))}'
              '${record.replayed == true ? '\nOriginal receipt recovered' : ''}';
    return Card(
      child: ListTile(
        title: Text(_statusLabel(record.status)),
        subtitle: Text(subtitle),
        isThreeLine: true,
        trailing: record.status == ScanStatus.pending
            ? TextButton(
                onPressed: _scanBusy || _offlineMode
                    ? null
                    : () => _retryScan(record),
                child: const Text('Retry'),
              )
            : null,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    _scanEpoch++;
    _auth?.cancel();
    _offlineTimer?.cancel();
    unawaited(widget.scanGateway?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _account != null;
    final eventIsOpen = _selected?.state == 'OPEN';
    final canScan =
        signedIn &&
        eventIsOpen &&
        !_offlineMode &&
        _selectedCheckpoint != null &&
        _scanStoreReady &&
        !_scanBusy &&
        !_hasUnresolvedScans &&
        widget.scanGateway != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('HNU DASH Staff'),
        actions: [
          if (signedIn)
            IconButton(
              tooltip: 'Refresh assignments',
              onPressed: _busy || _scanBusy || _offlineMode ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          if (signedIn)
            TextButton(
              onPressed: _busy ? null : _signOut,
              child: const Text('Sign out'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: signedIn ? _refresh : () async {},
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (!signedIn) ...[
              const Text('Staff sign-in', style: TextStyle(fontSize: 24)),
              const Text(
                'Use your verified HNU Google account. Staff access is assigned by HNU DASH.',
              ),
              FilledButton(
                onPressed: _busy ? null : _signIn,
                child: const Text('Continue with Google'),
              ),
            ] else ...[
              const Card(
                child: ListTile(
                  leading: Icon(Icons.science_outlined),
                  title: Text('DEVELOPMENT ONLY'),
                  subtitle: Text(
                    'Synthetic Student IDs only. Real attendance collection is not authorized.',
                  ),
                ),
              ),
              if (!_offlineMode) ...[
                const Text('Assigned events', style: TextStyle(fontSize: 24)),
                const Text('Read-only • Asia/Manila'),
              ],
            ],
            if (_busy) const Center(child: CircularProgressIndicator()),
            if (_error != null) ...[
              Text(_error!, key: const Key('workspace-error')),
              if (signedIn)
                TextButton(onPressed: _refresh, child: const Text('Retry')),
            ],
            if (signedIn && !_busy && _error == null && _events.isEmpty)
              const Text('No assigned events are currently available.'),
            if (signedIn && !_offlineMode)
              for (final event in _events)
                Card(
                  child: ListTile(
                    title: Text(event.title),
                    subtitle: Text(
                      '${manilaTime(event.start)} – ${manilaTime(event.end)}\nState: ${event.state}',
                    ),
                    isThreeLine: true,
                    selected: _selected?.id == event.id,
                    onTap: _scanBusy ? null : () => _open(event),
                  ),
                ),
            if (signedIn &&
                !_offlineMode &&
                _selected != null &&
                !_busy) ...[
              Text(
                'Checkpoints — ${_selected!.title}',
                style: const TextStyle(fontSize: 20),
              ),
              Text('Event state: ${_selected!.state}'),
              if (!eventIsOpen)
                const Text(
                  'Scanning is available only while the event is OPEN.',
                ),
              if (_checkpoints.isEmpty) const Text('No checkpoints available.'),
              for (final checkpoint in _checkpoints)
                Card(
                  child: ListTile(
                    title: Text(checkpoint.label),
                    subtitle: Text(
                      '${checkpoint.direction} • ${manilaTime(checkpoint.start)} – ${manilaTime(checkpoint.end)}',
                    ),
                    selected: _selectedCheckpoint?.id == checkpoint.id,
                    trailing: _selectedCheckpoint?.id == checkpoint.id
                        ? const Icon(Icons.check_circle)
                        : const Icon(Icons.circle_outlined),
                    onTap: _scanBusy
                        ? null
                        : () => setState(() {
                            _selectedCheckpoint = checkpoint;
                            _scanMessage = null;
                          }),
                  ),
                ),
              if (_offlineGateway != null &&
                  eventIsOpen &&
                  _selected!.offlineEnabled &&
                  _selected!.assignmentId != null &&
                  _selected!.uploadCutoff != null &&
                  _checkpoints.isNotEmpty)
                OutlinedButton(
                  onPressed: _scanStoreReady &&
                          !_scanBusy &&
                          !_hasUnresolvedScans
                      ? _prepareOffline
                      : null,
                  child: const Text('Prepare offline (online)'),
                ),
              if (canScan)
                FilledButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan Student ID'),
                ),
            ],
            if (signedIn && _scanBusy) const LinearProgressIndicator(),
            if (signedIn && _scanMessage != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _scanMessage!,
                  key: const Key('scan-result-message'),
                ),
              ),
            if (signedIn && _scanStoreReady && _offlineGateway != null) ...[
              const SizedBox(height: 16),
              const Text(
                'Offline evidence — synthetic only',
                style: TextStyle(fontSize: 20),
              ),
              Semantics(
                liveRegion: true,
                child: Text(
                  'Locally queued: ${_offlineCounts.queued} • '
                  'Submitted for review: ${_offlineCounts.submitted} • '
                  'Blocked: ${_offlineCounts.blocked}',
                  key: const Key('offline-queue-counts'),
                ),
              ),
              const Text(
                'These are local account counts, not official attendance or completion.',
              ),
              if (_offlinePreparation != null && !_offlineMode)
                OutlinedButton(
                  onPressed: _scanBusy || _busy || _hasUnresolvedScans
                      ? null
                      : _enterOffline,
                  child: const Text('Enter offline capture mode'),
                ),
              if (_offlineMode && _offlinePreparation != null) ...[
                Text('OFFLINE MODE — ${_offlinePreparation!.title}'),
                Text(
                  'Preparation expires: ${manilaTime(_offlinePreparation!.expires)}',
                ),
                const Text('Saved claims are unverified until manager review.'),
                for (final checkpoint in _offlinePreparation!.checkpoints)
                  ListTile(
                    title: Text(checkpoint.label),
                    subtitle: Text(
                      '${checkpoint.direction} • ${manilaTime(checkpoint.opens)} – ${manilaTime(checkpoint.closes)}',
                    ),
                    selected: _offlineCheckpoint?.id == checkpoint.id,
                    trailing: _offlineCheckpoint?.id == checkpoint.id
                        ? const Icon(Icons.check_circle)
                        : const Icon(Icons.circle_outlined),
                    onTap: _scanBusy
                        ? null
                        : () => setState(() => _offlineCheckpoint = checkpoint),
                  ),
                if (_offlineCheckpoint != null && !_canCaptureOffline)
                  const Text(
                    'Capture is unavailable until the checkpoint and lease bounds are safely established.',
                  ),
                FilledButton.icon(
                  onPressed: _canCaptureOffline ? _startOfflineCapture : null,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan synthetic ID offline'),
                ),
                TextButton(
                  onPressed: _scanBusy ? null : _exitOffline,
                  child: const Text('Exit offline capture mode'),
                ),
              ],
              OutlinedButton(
                onPressed: _scanBusy || _offlineCounts.queued == 0
                    ? null
                    : _syncOffline,
                child: const Text('Sync queued claims (online)'),
              ),
              TextButton(
                onPressed: _scanBusy
                    ? null
                    : () => _refreshScanRecords(_account!),
                child: const Text('Reload local evidence'),
              ),
              if (_offlineRecords.isNotEmpty) ...[
                Text(
                  'Offline claims ${_offlineOffset + 1}–'
                  '${_offlineOffset + _offlineRecords.length} of $_offlineTotal '
                  '(blocked first)',
                ),
                for (final claim in _offlineRecords) _offlineRecordCard(claim),
                Row(
                  children: [
                    TextButton(
                      onPressed: _scanBusy || _offlineOffset == 0
                          ? null
                          : () => _pageOfflineRecords(_offlineOffset - 10),
                      child: const Text('Previous claims'),
                    ),
                    TextButton(
                      onPressed: _scanBusy ||
                              _offlineOffset + 10 >= _offlineTotal
                          ? null
                          : () => _pageOfflineRecords(_offlineOffset + 10),
                      child: const Text('Next claims'),
                    ),
                  ],
                ),
              ],
            ],
            if (signedIn && _scanStoreError != null)
              Text(_scanStoreError!, key: const Key('scan-store-error')),
            if (signedIn &&
                widget.scanGateway != null &&
                !_scanStoreReady &&
                _scanStoreError == null)
              const Text('Opening encrypted attendance storage…'),
            if (signedIn && _hasUnresolvedScans)
              const Text(
                'Retry the pending attempt before scanning another ID. Blocked conflicts remain saved for support; only unrelated captures may continue.',
              ),
            if (signedIn && _scanStoreReady && _scanRecords.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Recent scan attempts',
                style: TextStyle(fontSize: 20),
              ),
              for (final record in _scanRecords) _scanRecordCard(record),
            ],
          ],
        ),
      ),
    );
  }
}
