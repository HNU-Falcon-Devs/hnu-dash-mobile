import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/main.dart';
import 'package:hnu_dash_mobile/scan_ingestion.dart';
import 'package:hnu_dash_mobile/secure_attendance_store.dart';
import 'package:hnu_dash_mobile/staff_workspace.dart';

class FakeGateway implements StaffGateway {
  FakeGateway([this.account]);

  @override
  String? account;
  final controller = StreamController<String?>.broadcast();
  List<StaffEvent> assigned = [];
  List<Checkpoint> configured = [];
  bool revoke = false;
  bool fail = false;
  Completer<List<StaffEvent>>? pending;

  @override
  Stream<String?> get authChanges => controller.stream;

  @override
  Future<void> signIn() async {}

  @override
  Future<void> signOut() async {
    setAccount(null);
  }

  void setAccount(String? id) {
    account = id;
    controller.add(id);
  }

  @override
  Future<List<StaffEvent>> events() async {
    if (fail || revoke) throw StateError('Request blocked');
    if (pending != null) return pending!.future;
    return assigned;
  }

  @override
  Future<List<Checkpoint>> checkpoints(String id) async {
    if (revoke) throw StateError('Revoked');
    return configured;
  }

  Future<void> close() => controller.close();
}

class FakeScanGateway implements StaffScanGateway {
  final Map<String, List<ScanRecord>> recordsByAccount = {};
  final Map<String, bool> unresolvedByAccount = {};
  final List<String> openedAccounts = [];
  final List<String> retriedIds = [];
  final List<Map<String, String>> captures = [];
  String? account;
  int closeCount = 0;

  @override
  Future<void> openForAccount(String staffUserId) async {
    account = staffUserId;
    openedAccounts.add(staffUserId);
  }

  @override
  Future<void> close() async {
    closeCount++;
    account = null;
  }

  @override
  Future<List<ScanRecord>> readRecent() async =>
      List.of(recordsByAccount[account] ?? []);

  @override
  Future<bool> hasUnresolvedRecords() async =>
      unresolvedByAccount[account] ?? false;

  @override
  Future<ScanAttemptResult> capture({
    required String eventId,
    required String checkpointId,
    required String studentId,
  }) async {
    captures.add({
      'eventId': eventId,
      'checkpointId': checkpointId,
      'studentId': studentId,
    });
    final record = ScanRecord(
      scanId: 'synthetic-scan-uuid',
      eventId: eventId,
      checkpointId: checkpointId,
      studentId: studentId,
      staffUserId: account,
      status: ScanStatus.accepted,
      receivedAt: '2026-11-08T02:15:00Z',
      replayed: false,
    );
    recordsByAccount[account!] = [record];
    unresolvedByAccount[account!] = false;
    return const ScanAttemptResult(
      record: null,
      message: 'Backend accepted the scan evidence. This is not finalized attendance.',
      retryAllowed: false,
    ).copyWithRecord(record);
  }

  @override
  Future<ScanAttemptResult> retry(String scanId) async {
    retriedIds.add(scanId);
    final previous = recordsByAccount[account]!.single;
    final record = ScanRecord(
      scanId: previous.scanId,
      eventId: previous.eventId,
      checkpointId: previous.checkpointId,
      studentId: previous.studentId,
      staffUserId: previous.staffUserId,
      status: ScanStatus.accepted,
      receivedAt: '2026-11-08T02:15:00Z',
      replayed: true,
    );
    recordsByAccount[account!] = [record];
    unresolvedByAccount[account!] = false;
    return ScanAttemptResult(
      record: record,
      message: 'Original receipt recovered.',
      retryAllowed: false,
    );
  }
}

extension on ScanAttemptResult {
  ScanAttemptResult copyWithRecord(ScanRecord record) => ScanAttemptResult(
    record: record,
    message: message,
    retryAllowed: retryAllowed,
  );
}

class FakeScannerPage extends StatelessWidget {
  const FakeScannerPage({required this.studentId, super.key});

  final String studentId;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton(
        onPressed: () => Navigator.pop(context, studentId),
        child: const Text('Use synthetic QR'),
      ),
    ),
  );
}

final sampleEvent = StaffEvent(
  'event-1',
  'BSIT Assembly',
  DateTime.utc(2026, 11, 8, 1),
  DateTime.utc(2026, 11, 8, 3),
  'OPEN',
);
final closedEvent = StaffEvent(
  'event-closed',
  'Closed Assembly',
  DateTime.utc(2026, 11, 8, 1),
  DateTime.utc(2026, 11, 8, 3),
  'CLOSED',
);
final sampleCheckpoint = Checkpoint(
  'checkpoint-1',
  'Entrance',
  'IN',
  DateTime.utc(2026, 11, 8, 1, 30),
  DateTime.utc(2026, 11, 8, 2),
);

Widget buildApp(
  FakeGateway gateway, {
  FakeScanGateway? scanGateway,
  String scannerStudentId = '00001234',
}) => HnuDashMobileApp(
  gateway: gateway,
  scanGateway: scanGateway,
  scannerPageBuilder: () => FakeScannerPage(studentId: scannerStudentId),
);

void main() {
  testWidgets('missing build configuration displays setup instructions', (
    tester,
  ) async {
    await tester.pumpWidget(const HnuDashMobileApp());
    expect(
      find.textContaining('Development configuration required'),
      findsOneWidget,
    );
  });

  testWidgets('signed-out state and Google login entry', (tester) async {
    final gateway = FakeGateway();
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway));
    expect(find.text('Staff sign-in'), findsOneWidget);
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    gateway.setAccount('staff-a');
    await tester.pumpAndSettle();
    expect(
      find.text('No assigned events are currently available.'),
      findsOneWidget,
    );
  });

  testWidgets('restored session lists assigned events and checkpoints', (
    tester,
  ) async {
    final gateway = FakeGateway('staff-a')
      ..assigned = [sampleEvent]
      ..configured = [sampleCheckpoint];
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway));
    await tester.pumpAndSettle();
    expect(find.text('BSIT Assembly'), findsOneWidget);
    expect(find.text('DEVELOPMENT ONLY'), findsOneWidget);
    expect(find.textContaining('2026-11-08 09:00 PHT'), findsOneWidget);
    expect(find.textContaining('State: OPEN'), findsOneWidget);
    await tester.tap(find.text('BSIT Assembly'));
    await tester.pumpAndSettle();
    expect(find.text('Entrance'), findsOneWidget);
    expect(find.textContaining('IN • 2026-11-08 09:30 PHT'), findsOneWidget);
    expect(find.text('Event state: OPEN'), findsOneWidget);
  });

  testWidgets('scanning requires an OPEN event and a selected checkpoint', (
    tester,
  ) async {
    final gateway = FakeGateway('staff-a')
      ..assigned = [sampleEvent, closedEvent]
      ..configured = [sampleCheckpoint];
    final scanGateway = FakeScanGateway();
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway, scanGateway: scanGateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('BSIT Assembly'));
    await tester.pumpAndSettle();
    expect(find.text('Scan Student ID'), findsNothing);
    await tester.tap(find.text('Entrance'));
    await tester.pumpAndSettle();
    expect(find.text('Scan Student ID'), findsOneWidget);

    await tester.tap(find.text('Closed Assembly'));
    await tester.pumpAndSettle();
    expect(
      find.text('Scanning is available only while the event is OPEN.'),
      findsOneWidget,
    );
    expect(find.text('Scan Student ID'), findsNothing);
  });

  testWidgets('confirmation masks the ID and submits only after consent', (
    tester,
  ) async {
    final gateway = FakeGateway('staff-a')
      ..assigned = [sampleEvent]
      ..configured = [sampleCheckpoint];
    final scanGateway = FakeScanGateway();
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway, scanGateway: scanGateway));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BSIT Assembly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrance'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scan Student ID'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use synthetic QR'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm attendance scan'), findsOneWidget);
    expect(find.text('Student ID: ••••1234'), findsOneWidget);
    expect(scanGateway.captures, isEmpty);

    await tester.tap(find.text('Confirm scan'));
    await tester.pumpAndSettle();

    expect(scanGateway.captures, hasLength(1));
    expect(scanGateway.captures.single['studentId'], '00001234');
    expect(scanGateway.captures.single['eventId'], 'event-1');
    expect(scanGateway.captures.single['checkpointId'], 'checkpoint-1');
    expect(find.textContaining('not finalized attendance'), findsOneWidget);
    expect(find.textContaining('ACCEPTED'), findsOneWidget);
  });

  testWidgets('pending attempts block new scans and offer explicit retry', (
    tester,
  ) async {
    final gateway = FakeGateway('staff-a')
      ..assigned = [sampleEvent]
      ..configured = [sampleCheckpoint];
    final scanGateway = FakeScanGateway();
    final pending = ScanRecord(
      scanId: 'synthetic-pending-id',
      eventId: 'event-1',
      checkpointId: 'checkpoint-1',
      studentId: 'SYNTHETIC-00123',
      staffUserId: 'staff-a',
      status: ScanStatus.pending,
    );
    scanGateway.recordsByAccount['staff-a'] = [pending];
    scanGateway.unresolvedByAccount['staff-a'] = true;
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway, scanGateway: scanGateway));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('BSIT Assembly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrance'));
    await tester.pumpAndSettle();

    expect(find.text('Scan Student ID'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(scanGateway.retriedIds, ['synthetic-pending-id']);
    expect(find.textContaining('Original receipt recovered.'), findsOneWidget);
  });

  testWidgets('revoked checkpoint access clears prior event information', (
    tester,
  ) async {
    final gateway = FakeGateway('staff-a')..assigned = [sampleEvent];
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway));
    await tester.pumpAndSettle();
    gateway.revoke = true;
    await tester.tap(find.text('BSIT Assembly'));
    await tester.pumpAndSettle();
    expect(find.text('BSIT Assembly'), findsNothing);
    expect(find.textContaining('access could not be verified'), findsOneWidget);
  });

  testWidgets('refresh drops stale assignments and errors can be retried', (
    tester,
  ) async {
    final gateway = FakeGateway('staff-a')..assigned = [sampleEvent];
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway));
    await tester.pumpAndSettle();
    gateway.assigned = [];
    await tester.tap(find.byTooltip('Refresh assignments'));
    await tester.pumpAndSettle();
    expect(find.text('BSIT Assembly'), findsNothing);
    gateway.fail = true;
    await tester.tap(find.byTooltip('Refresh assignments'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workspace-error')), findsOneWidget);
    gateway.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      find.text('No assigned events are currently available.'),
      findsOneWidget,
    );
  });

  testWidgets('account changes clear previous scan records', (tester) async {
    final gateway = FakeGateway('staff-a')..assigned = [sampleEvent];
    final scanGateway = FakeScanGateway()
      ..recordsByAccount['staff-a'] = [
        ScanRecord(
          scanId: 'scan-a',
          eventId: 'event-a',
          checkpointId: 'checkpoint-a',
          studentId: 'SYNTHETIC-1111',
          staffUserId: 'staff-a',
          status: ScanStatus.accepted,
          receivedAt: '2026-11-08T02:15:00Z',
          replayed: false,
        ),
      ]
      ..recordsByAccount['staff-b'] = [
        ScanRecord(
          scanId: 'scan-b',
          eventId: 'event-b',
          checkpointId: 'checkpoint-b',
          studentId: 'SYNTHETIC-2222',
          staffUserId: 'staff-b',
          status: ScanStatus.accepted,
          receivedAt: '2026-11-08T02:16:00Z',
          replayed: false,
        ),
      ];
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway, scanGateway: scanGateway));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BSIT Assembly'));
    await tester.pumpAndSettle();
    expect(find.textContaining('••••1111'), findsOneWidget);

    gateway.setAccount('staff-b');
    await tester.pumpAndSettle();
    expect(find.textContaining('••••1111'), findsNothing);
    expect(find.textContaining('••••2222'), findsOneWidget);
    expect(scanGateway.openedAccounts, ['staff-a', 'staff-b']);
  });

  testWidgets('session expiry and switch ignore previous account results', (
    tester,
  ) async {
    final gateway = FakeGateway('staff-a')..assigned = [sampleEvent];
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway));
    await tester.pumpAndSettle();
    gateway.pending = Completer<List<StaffEvent>>();
    await tester.tap(find.byTooltip('Refresh assignments'));
    await tester.pump();
    gateway.setAccount(null);
    await tester.pump();
    gateway.pending!.complete([sampleEvent]);
    await tester.pumpAndSettle();
    expect(find.text('Staff sign-in'), findsOneWidget);
    expect(find.text('BSIT Assembly'), findsNothing);
    gateway.pending = null;
    gateway.assigned = [];
    gateway.setAccount('staff-b');
    await tester.pumpAndSettle();
    expect(find.text('BSIT Assembly'), findsNothing);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Staff sign-in'), findsOneWidget);
  });
}
