import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/main.dart';
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
  int calls = 0;

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
    calls++;
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

final sampleEvent = StaffEvent(
  'event-1',
  'BSIT Assembly',
  DateTime.utc(2026, 11, 8, 1),
  DateTime.utc(2026, 11, 8, 3),
  'OPEN',
);
final sampleCheckpoint = Checkpoint(
  'Entrance',
  'IN',
  DateTime.utc(2026, 11, 8, 1, 30),
  DateTime.utc(2026, 11, 8, 2),
);

void main() {
  testWidgets('missing build configuration displays setup instructions',
      (tester) async {
    await tester.pumpWidget(const HnuDashMobileApp());
    expect(find.textContaining('Development configuration required'), findsOneWidget);
  });

  testWidgets('signed-out state and Google login entry', (tester) async {
    final gateway = FakeGateway();
    addTearDown(gateway.close);
    await tester.pumpWidget(HnuDashMobileApp(gateway: gateway));
    expect(find.text('Staff sign-in'), findsOneWidget);
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    gateway.setAccount('staff-a');
    await tester.pumpAndSettle();
    expect(find.text('No assigned events are currently available.'), findsOneWidget);
  });

  testWidgets('restored session lists assigned events and checkpoints',
      (tester) async {
    final gateway = FakeGateway('staff-a')
      ..assigned = [sampleEvent]
      ..configured = [sampleCheckpoint];
    addTearDown(gateway.close);
    await tester.pumpWidget(HnuDashMobileApp(gateway: gateway));
    await tester.pumpAndSettle();
    expect(find.text('BSIT Assembly'), findsOneWidget);
    expect(find.textContaining('2026-11-08 09:00 PHT'), findsOneWidget);
    expect(find.textContaining('State: OPEN'), findsOneWidget);
    await tester.tap(find.text('BSIT Assembly'));
    await tester.pumpAndSettle();
    expect(find.text('Entrance'), findsOneWidget);
    expect(find.textContaining('IN • 2026-11-08 09:30 PHT'), findsOneWidget);
    expect(find.text('Event state: OPEN'), findsOneWidget);
  });

  testWidgets('revoked checkpoint access clears prior event information',
      (tester) async {
    final gateway = FakeGateway('staff-a')..assigned = [sampleEvent];
    addTearDown(gateway.close);
    await tester.pumpWidget(HnuDashMobileApp(gateway: gateway));
    await tester.pumpAndSettle();
    gateway.revoke = true;
    await tester.tap(find.text('BSIT Assembly'));
    await tester.pumpAndSettle();
    expect(find.text('BSIT Assembly'), findsNothing);
    expect(find.textContaining('access could not be verified'), findsOneWidget);
  });

  testWidgets('refresh drops stale assignments and errors can be retried',
      (tester) async {
    final gateway = FakeGateway('staff-a')..assigned = [sampleEvent];
    addTearDown(gateway.close);
    await tester.pumpWidget(HnuDashMobileApp(gateway: gateway));
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
    expect(find.text('No assigned events are currently available.'), findsOneWidget);
  });

  testWidgets('session expiry and switch ignore previous account results',
      (tester) async {
    final gateway = FakeGateway('staff-a')..assigned = [sampleEvent];
    addTearDown(gateway.close);
    await tester.pumpWidget(HnuDashMobileApp(gateway: gateway));
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
