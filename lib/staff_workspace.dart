import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'development_scan_policy.dart';
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
  const StaffEvent(this.id, this.title, this.start, this.end, this.state);
  final String id, title, state;
  final DateTime start, end;

  factory StaffEvent.fromJson(Map<String, dynamic> json) => StaffEvent(
    json['id'] as String,
    json['title'] as String,
    DateTime.parse(json['starts_at'] as String),
    DateTime.parse(json['ends_at'] as String),
    json['state'] as String,
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
        .select('event_id')
        .eq('staff_user_id', id)
        .isFilter('revoked_at', null);
    if (account != id) throw StateError('Session changed');
    final ids = assignments
        .map((row) => row['event_id'] as String)
        .toSet()
        .toList();
    if (ids.isEmpty) return [];
    final rows = await client
        .from('events')
        .select('id,title,starts_at,ends_at,state')
        .inFilter('id', ids)
        .order('starts_at');
    if (account != id) throw StateError('Session changed');
    return rows.map((row) => StaffEvent.fromJson(row)).toList();
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
    if (state != AppLifecycleState.resumed) return;
    if (widget.gateway.account != _account) {
      _onAuth(widget.gateway.account);
    } else if (_account != null) {
      _refresh();
      _refreshScanRecords(_account!);
    }
  }

  void _clear() {
    _epoch++;
    _scanEpoch++;
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
      if (!_validScan(version, id)) {
        await gateway.close();
        return;
      }
      final records = await gateway.readRecent();
      final unresolved = await gateway.hasUnresolvedRecords();
      if (!_validScan(version, id)) {
        await gateway.close();
        return;
      }
      setState(() {
        _scanRecords = records;
        _hasUnresolvedScans = unresolved;
        _scanStoreReady = true;
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
      setState(() {
        _scanRecords = records;
        _hasUnresolvedScans = unresolved;
      });
    } catch (_) {
      if (!_validScan(version, id)) return;
      setState(() {
        _scanStoreError =
            'Local attendance records could not be read. Scanning is disabled.';
        _scanStoreReady = false;
        _scanRecords = [];
        _hasUnresolvedScans = true;
      });
    }
  }

  Future<void> _refresh() async {
    final id = _account;
    if (id == null) return;
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
    if (id == null) return;
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
    if (event == null ||
        checkpoint == null ||
        account == null ||
        scanGateway == null ||
        event.state != 'OPEN' ||
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
        !_validScanAccount(account) ||
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
        !_validScanAccount(account) ||
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
      if (!mounted || !_validScanAccount(account)) return;
      setState(() {
        _scanBusy = false;
        _scanMessage = result.message;
      });
      await _refreshScanRecords(account);
    } catch (_) {
      if (!mounted || !_validScanAccount(account)) return;
      setState(() {
        _scanBusy = false;
        _scanMessage = 'The attempt could not be saved securely. No Backend receipt is confirmed; do not scan again until storage is checked.';
      });
      await _refreshScanRecords(account);
    }
  }

  bool _validScanAccount(String id) =>
      mounted && _account == id && widget.gateway.account == id;

  Future<void> _retryScan(ScanRecord record) async {
    final account = _account;
    final scanGateway = widget.scanGateway;
    if (account == null ||
        scanGateway == null ||
        record.status != ScanStatus.pending ||
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
      if (!mounted || !_validScanAccount(account)) return;
      setState(() {
        _scanBusy = false;
        _scanMessage = result.message;
      });
      await _refreshScanRecords(account);
    } catch (_) {
      if (!mounted || !_validScanAccount(account)) return;
      setState(() {
        _scanBusy = false;
        _scanMessage = 'The same pending attempt could not be retried. No new scan was created.';
      });
      await _refreshScanRecords(account);
    }
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
                onPressed: _scanBusy ? null : () => _retryScan(record),
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
              onPressed: _busy ? null : _refresh,
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
              const Text('Assigned events', style: TextStyle(fontSize: 24)),
              const Text('Read-only • Asia/Manila'),
            ],
            if (_busy) const Center(child: CircularProgressIndicator()),
            if (_error != null) ...[
              Text(_error!, key: const Key('workspace-error')),
              if (signedIn)
                TextButton(onPressed: _refresh, child: const Text('Retry')),
            ],
            if (signedIn && !_busy && _error == null && _events.isEmpty)
              const Text('No assigned events are currently available.'),
            if (signedIn)
              for (final event in _events)
                Card(
                  child: ListTile(
                    title: Text(event.title),
                    subtitle: Text(
                      '${manilaTime(event.start)} – ${manilaTime(event.end)}\nState: ${event.state}',
                    ),
                    isThreeLine: true,
                    selected: _selected?.id == event.id,
                    onTap: () => _open(event),
                  ),
                ),
            if (signedIn && _selected != null && !_busy) ...[
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
                    onTap: () => setState(() {
                      _selectedCheckpoint = checkpoint;
                      _scanMessage = null;
                    }),
                  ),
                ),
              if (canScan)
                FilledButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan Student ID'),
                ),
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
            if (signedIn && _scanBusy) const LinearProgressIndicator(),
            if (signedIn && _scanMessage != null)
              Text(_scanMessage!, key: const Key('scan-result-message')),
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
