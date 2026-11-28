import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hnu_dash_mobile/offline_v2.dart';
import 'package:hnu_dash_mobile/offline_v2_gateway.dart';
import 'package:hnu_dash_mobile/student_qr_scanner.dart';

/// Explicit test-only entrypoint. No normal application code imports this
/// fixture workspace, and it never accepts an arbitrary event ID from UI.
class OfflineV2FixtureWorkspace extends StatefulWidget {
  const OfflineV2FixtureWorkspace({
    super.key,
    required this.controller,
    required this.fixtures,
    required this.accountChanges,
    this.scannerBuilder,
  });

  final OfflineV2Controller controller;
  final List<V2Scope> fixtures;
  final Stream<void> accountChanges;
  final ScannerSurfaceBuilder? scannerBuilder;

  @override
  State<OfflineV2FixtureWorkspace> createState() =>
      _OfflineV2FixtureWorkspaceState();
}

class _OfflineV2FixtureWorkspaceState extends State<OfflineV2FixtureWorkspace>
    with WidgetsBindingObserver {
  OfflineV2Controller get controller => widget.controller;
  StreamSubscription<void>? _auth;
  int? _selected;
  bool _busy = false;
  String? _message;
  Route<dynamic>? _activeRoute;

  void _dismissActiveRoute() {
    final route = _activeRoute;
    _activeRoute = null;
    if (route != null && route.isActive) {
      Navigator.of(context, rootNavigator: true).removeRoute(route);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _auth = widget.accountChanges.listen((_) {
      if (!controller.accountAvailable) {
        unawaited(controller.invalidate());
        if (mounted) {
          _dismissActiveRoute();
          setState(() => _message = null);
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      controller.suspend();
      if (mounted) {
        _dismissActiveRoute();
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    controller.suspend();
    unawaited(_auth?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _run(FutureOr<void> Function() action) async {
    if (_busy || !controller.accountAvailable) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted && controller.accountAvailable) {
        setState(
          () => _message = 'Operation not confirmed. Evidence retained; retry or contact support.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _select(int index) {
    setState(() {
      _selected = index;
      _message = null;
    });
    try {
      controller.selectFixture(widget.fixtures[index]);
    } catch (_) {
      setState(() {
        _selected = null;
        _message = 'Original encrypted context unavailable.';
      });
    }
  }

  Future<bool> _confirm(String title, String content, String action) async {
    if (!mounted || !controller.accountAvailable) return false;
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    _activeRoute = route;
    try {
      final confirmed = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      return confirmed == true && mounted && controller.accountAvailable;
    } finally {
      if (identical(_activeRoute, route)) _activeRoute = null;
    }
  }

  Future<void> _scan() async {
    V2PendingQr? observation;
    try {
      final route = MaterialPageRoute<String>(
        builder: (_) => StudentQrScannerPage(
          scannerBuilder: widget.scannerBuilder,
          onObservation: (id) async {
            observation = await controller.observeQr(id);
          },
        ),
      );
      _activeRoute = route;
      final result = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      if (identical(_activeRoute, route)) _activeRoute = null;
      final pending = observation;
      if (!mounted ||
          !controller.accountAvailable ||
          result == null ||
          pending == null ||
          result != pending.studentId) {
        return;
      }
      if (pending.warning != null) {
        final description = switch (pending.warning!) {
          V2Warning.early => 'Before the planned checkpoint window.',
          V2Warning.late => 'At or after the planned checkpoint end.',
          V2Warning.unknown => 'The observation clock is unavailable.',
        };
        if (!await _confirm(
          'Schedule warning',
          '$description Continue collecting unverified evidence?',
          'Continue',
        )) {
          return;
        }
        controller.continueAfterWarning(pending);
      }
      final saved = controller.selected!;
      final checkpoint = saved.preparation.checkpoints.singleWhere(
        (c) => c.id == pending.checkpointId,
      );
      if (!await _confirm(
        'Confirm local capture',
        '${saved.preparation.receipt['event_title']}\n'
            '${checkpoint.label} (${checkpoint.direction})\n'
            'Student ID: ${maskStudentId(pending.studentId)}\n'
            'Save unverified evidence only, not attendance.',
        'Save locally',
      )) {
        return;
      }
      final claim = await controller.confirm(pending);
      final clock = claim.parameters['p_clock'] as Map;
      if (mounted && controller.accountAvailable) {
        setState(
          () => _message = clock['anomaly'] == 'none'
              ? 'Saved locally. No upload or attendance decision.'
              : 'Saved locally with uncertain timing. No attendance decision.',
        );
      }
    } finally {
      controller.cancelQr();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!controller.accountAvailable) {
      return const Scaffold(
        body: Center(child: Text('Original Staff session unavailable.')),
      );
    }
    try {
      final saved = controller.selected;
      final counts = controller.counts;
      final collecting = controller.collecting;
      return Scaffold(
        appBar: AppBar(title: const Text('Policy 2 synthetic fixture')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Fixture only. Not official attendance.'),
            DropdownButton<int>(
              hint: const Text('Select synthetic preparation'),
              value: _selected,
              items: [
                for (var i = 0; i < widget.fixtures.length; i++)
                  DropdownMenuItem(value: i, child: Text('Fixture ${i + 1}')),
              ],
              onChanged: _busy || collecting
                  ? null
                  : (index) {
                      if (index != null) _select(index);
                    },
            ),
            Text(
              'Installation unresolved: ${controller.installationUnresolved} / 2400',
            ),
            if (saved == null || counts == null)
              FilledButton(
                onPressed: _busy || _selected == null
                    ? null
                    : () => _run(controller.prepare),
                child: const Text('Prepare online'),
              )
            else ...[
              Text('Preparation: ${saved.preparation.id}'),
              Text(
                'Queued: ${counts.queued}; attempted: ${counts.attempted}; '
                'submitted: ${counts.submitted}; blocked: ${counts.blocked}',
              ),
              Text('Accounting: ${saved.disposition ?? 'not declared'}'),
              if (saved.intent != null)
                Text('Retained completion count: ${saved.intent}'),
              if (collecting) ...[
                DropdownButton<String>(
                  hint: const Text('Select checkpoint'),
                  value: controller.selectedCheckpoint,
                  items: [
                    for (final c in saved.preparation.checkpoints)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text('${c.label} (${c.direction})'),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (id) {
                          if (id != null) {
                            setState(() => controller.selectCheckpoint(id));
                          }
                        },
                ),
                FilledButton(
                  onPressed: _busy || controller.selectedCheckpoint == null
                      ? null
                      : () => _run(_scan),
                  child: const Text('Scan QR'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => setState(controller.stop),
                  child: const Text('Stop collecting'),
                ),
              ] else ...[
                FilledButton(
                  onPressed: _busy || !saved.canCapture
                      ? null
                      : () => _run(controller.resume),
                  child: const Text('Resume local collection'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final status = await controller.checkStatus();
                          if (mounted) {
                            setState(
                              () => _message =
                                  'Server: ${status.state}; submitted: ${status.count}.',
                            );
                          }
                        }),
                  child: const Text('Check server status'),
                ),
                FilledButton(
                  onPressed: _busy || counts.unresolved == 0
                      ? null
                      : () => _run(controller.sync),
                  child: const Text('Synchronize selected preparation'),
                ),
                FilledButton(
                  onPressed:
                      _busy ||
                          counts.unresolved != 0 ||
                          (saved.disposition != null &&
                              saved.disposition != 'completed')
                      ? null
                      : () => _run(() async {
                          final count = counts.submitted;
                          if (await _confirm(
                            'Complete preparation?',
                            'Declare $count distinct acknowledged claims. This stops collection permanently, not attendance acceptance.',
                            'Declare $count',
                          )) {
                            await controller.complete(count);
                          }
                        }),
                  child: const Text('Complete preparation'),
                ),
              ],
            ],
            if (_busy) const LinearProgressIndicator(),
            if (_message != null) Text(_message!),
          ],
        ),
      );
    } catch (_) {
      return const Scaffold(
        body: Center(
          child: Text('Secure context unavailable. Evidence retained.'),
        ),
      );
    }
  }
}
