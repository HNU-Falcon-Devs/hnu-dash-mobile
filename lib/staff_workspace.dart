import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  factory StaffEvent.fromJson(Map<String, dynamic> j) => StaffEvent(
    j['id'] as String,
    j['title'] as String,
    DateTime.parse(j['starts_at'] as String),
    DateTime.parse(j['ends_at'] as String),
    j['state'] as String,
  );
}

class Checkpoint {
  const Checkpoint(this.label, this.direction, this.start, this.end);
  final String label, direction;
  final DateTime start, end;
  factory Checkpoint.fromJson(Map<String, dynamic> j) => Checkpoint(
    j['label'] as String,
    j['direction'] as String,
    DateTime.parse(j['opens_at'] as String),
    DateTime.parse(j['closes_at'] as String),
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
        .select('label,direction,opens_at,closes_at')
        .eq('event_id', eventId)
        .order('sort_order');
    if (account != id) throw StateError('Session changed');
    return rows.map((row) => Checkpoint.fromJson(row)).toList();
  }
}

String manilaTime(DateTime time) {
  final d = time.toUtc().add(const Duration(hours: 8));
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${pad(d.month)}-${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)} PHT';
}

class StaffWorkspace extends StatefulWidget {
  const StaffWorkspace({super.key, required this.gateway});
  final StaffGateway gateway;
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
  String? _error;
  bool _busy = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = widget.gateway.account;
    _auth = widget.gateway.authChanges.listen(
      _onAuth,
      onError: (Object _) => _onAuth(null),
    );
    if (_account != null) _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.gateway.account != _account) {
        _onAuth(widget.gateway.account);
      } else if (_account != null) {
        _refresh();
      }
    }
  }

  void _clear() {
    _epoch++;
    setState(() {
      _events = [];
      _selected = null;
      _checkpoints = [];
      _error = null;
      _busy = false;
    });
  }

  void _onAuth(String? id) {
    if (!mounted) return;
    if (id != _account) {
      _account = id;
      _clear();
      if (id != null) _refresh();
    } else if (id == null) {
      _clear();
    }
  }

  bool _valid(int version, String id) =>
      mounted &&
      version == _epoch &&
      _account == id &&
      widget.gateway.account == id;
  Future<void> _refresh() async {
    final id = _account;
    if (id == null) return;
    final version = ++_epoch;
    setState(() {
      _events = [];
      _selected = null;
      _checkpoints = [];
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
        _busy = false;
        _error = 'Event access could not be verified. Refresh assignments.';
      });
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
      if (mounted)
        setState(
          () => _error = 'Google sign-in could not start. Check OAuth setup.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    _account = null;
    _clear();
    setState(() => _busy = true);
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    _auth?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _account != null;
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
                      manilaTime(event.start) +
                          ' – ' +
                          manilaTime(event.end) +
                          '\nState: ' +
                          event.state,
                    ),
                    isThreeLine: true,
                    selected: _selected?.id == event.id,
                    onTap: () => _open(event),
                  ),
                ),
            if (signedIn && _selected != null && !_busy) ...[
              Text(
                'Checkpoints — ' + _selected!.title,
                style: const TextStyle(fontSize: 20),
              ),
              Text('Event state: ' + _selected!.state),
              if (_checkpoints.isEmpty) const Text('No checkpoints available.'),
              for (final cp in _checkpoints)
                Card(
                  child: ListTile(
                    title: Text(cp.label),
                    subtitle: Text(
                      cp.direction +
                          ' • ' +
                          manilaTime(cp.start) +
                          ' – ' +
                          manilaTime(cp.end),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
