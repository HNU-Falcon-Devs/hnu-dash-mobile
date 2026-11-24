import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/offline_capture.dart';
import 'package:hnu_dash_mobile/offline_completion.dart';
import 'package:hnu_dash_mobile/scan_ingestion.dart';
import 'package:hnu_dash_mobile/staff_workspace.dart';

import 'offline_fixture.dart';
import 'widget_test.dart' show FakeGateway, FakeScanGateway, buildApp;

class OfflineWidgetGateway extends FakeScanGateway
    implements OfflineScanGateway {
  OfflineWidgetGateway(this.fixture);

  final OfflineFixture fixture;
  @override
  OfflinePreparation? activePreparation;
  int preparationCalls = 0;
  int syncCalls = 0;
  int saved = 0;
  int submitted = 0;

  @override
  void invalidateOffline() => activePreparation = null;

  @override
  Future<void> close() async {
    invalidateOffline();
    await super.close();
  }

  @override
  void suspendOffline() {}

  @override
  Future<bool> resumeOffline(String preparationId, bool Function() shouldContinue) async =>
      shouldContinue() && activePreparation?.id == preparationId;

  @override
  List<OfflinePreparationSummary> preparations({int offset = 0}) => [];

  @override
  Future<OfflinePreparationStatus> preparationStatus(
    String preparationId, bool Function() shouldContinue,
  ) async => throw UnimplementedError();

  @override
  Future<String> completePreparation(
    String preparationId, int count, bool Function() shouldContinue,
  ) async => throw UnimplementedError();

  @override
  bool canCaptureOffline(String preparationId, String checkpointId) =>
      activePreparation?.id == preparationId &&
      checkpointId == fixture.checkpoint.id;

  @override
  Future<String> prepareOffline({
    required String eventId,
    required String assignmentId,
    required String title,
    required DateTime starts,
    required DateTime ends,
    required DateTime cutoff,
    required List<OfflineCheckpoint> checkpoints,
  }) async {
    preparationCalls++;
    activePreparation = fixture.parse(requestId);
    return 'Offline preparation saved.';
  }

  @override
  OfflineClaim captureOffline({
    required String preparationId,
    required String checkpointId,
    required String studentId,
  }) {
    saved++;
    return OfflineClaim(
      id: requestId,
      preparationId: preparationId,
      eventId: eventId,
      checkpointId: checkpointId,
      staffId: staffA,
      studentId: studentId,
      claimedAt: fixture.issued,
      status: OfflineClaimStatus.queued,
    );
  }

  @override
  OfflineQueueCounts offlineCounts() =>
      OfflineQueueCounts(saved - submitted, submitted, 0);

  @override
  List<OfflineSyncGroup> offlineSyncGroups() => saved > submitted
      ? [
          OfflineSyncGroup(
            preparationA,
            'Synthetic Assembly',
            saved - submitted,
          ),
        ]
      : [];

  @override
  List<OfflineClaim> recentOffline({int offset = 0}) => [];

  @override
  Future<String> syncOffline(
    void Function(OfflineQueueCounts) onProgress, {
    required String preparationId,
    required bool Function() shouldContinue,
  }) async {
    expect(preparationId, preparationA);
    syncCalls++;
    submitted = saved;
    onProgress(offlineCounts());
    return 'Submitted claims await review.';
  }
}

void main() {
  testWidgets('offline requires explicit preparation, mode, consent and sync', (
    tester,
  ) async {
    final fixture = OfflineFixture(DateTime.utc(2026, 11, 24, 6));
    final gateway = FakeGateway(staffA)
      ..assigned = [
        StaffEvent(
          eventId,
          'Synthetic Assembly',
          fixture.starts,
          fixture.ends,
          'OPEN',
          assignmentId: assignmentA,
          offlineEnabled: true,
          uploadCutoff: fixture.cutoff,
        ),
      ]
      ..configured = [
        Checkpoint(
          checkpointId,
          'Entrance',
          'IN',
          fixture.starts,
          fixture.closes,
        ),
      ];
    final scans = OfflineWidgetGateway(fixture);
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway, scanGateway: scans));
    await tester.pumpAndSettle();

    Future<void> tap(String label) async {
      final target = find.text(label);
      await tester.scrollUntilVisible(target, 150);
      await tester.tap(target);
      // Offline capture keeps an indeterminate progress indicator active
      // behind the scanner and confirmation dialog.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await tap('Synthetic Assembly');
    expect(scans.preparationCalls, 0);
    await tap('Prepare offline (online)');
    expect(scans.preparationCalls, 1);
    expect(scans.saved, 0);
    await tap('Enter offline capture mode');
    await tap('Entrance');
    await tap('Scan synthetic ID offline');
    await tester.tap(find.text('Use synthetic QR'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Confirm offline capture'), findsOneWidget);
    expect(find.text('Student ID: ••••3456'), findsOneWidget);
    expect(scans.saved, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(scans.saved, 0);
    await tap('Scan synthetic ID offline');
    await tester.tap(find.text('Use synthetic QR'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Save offline claim'));
    await tester.pumpAndSettle();
    expect(scans.saved, 1);
    expect(scans.captures, isEmpty);
    expect(scans.syncCalls, 0);
    expect(find.textContaining('Locally queued: 1'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Sync queued claims (online)'),
          )
          .onPressed,
      isNull,
    );
    await tap('Select preparation to sync');
    await tester.tap(
      find.text('Synthetic Assembly • 1 queued\n$preparationA').last,
    );
    await tester.pumpAndSettle();
    await tap('Sync queued claims (online)');
    expect(scans.syncCalls, 1);
    expect(find.textContaining('Submitted for review: 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('account switch dismisses pending offline confirmation', (
    tester,
  ) async {
    final fixture = OfflineFixture(DateTime.utc(2026, 11, 24, 6));
    final gateway = FakeGateway(staffA)
      ..assigned = [
        StaffEvent(
          eventId,
          'Synthetic Assembly',
          fixture.starts,
          fixture.ends,
          'OPEN',
          assignmentId: assignmentA,
          offlineEnabled: true,
          uploadCutoff: fixture.cutoff,
        ),
      ]
      ..configured = [
        Checkpoint(
          checkpointId,
          'Entrance',
          'IN',
          fixture.starts,
          fixture.closes,
        ),
      ];
    final scans = OfflineWidgetGateway(fixture);
    addTearDown(gateway.close);
    await tester.pumpWidget(buildApp(gateway, scanGateway: scans));
    await tester.pumpAndSettle();

    Future<void> tap(String label) async {
      final target = find.text(label);
      await tester.scrollUntilVisible(target, 150);
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await tap('Synthetic Assembly');
    await tap('Prepare offline (online)');
    await tap('Enter offline capture mode');
    await tap('Entrance');
    await tap('Scan synthetic ID offline');
    await tester.tap(find.text('Use synthetic QR'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Confirm offline capture'), findsOneWidget);
    expect(scans.saved, 0);
    gateway.assigned = [];
    gateway.setAccount(staffB);
    await tester.pumpAndSettle();
    expect(find.text('Confirm offline capture'), findsNothing);
    expect(find.text('Save offline claim'), findsNothing);
    expect(find.textContaining('OFFLINE MODE'), findsNothing);
    expect(scans.saved, 0);
    gateway.setAccount(staffA);
    await tester.pumpAndSettle();
    expect(scans.saved, 0);
    expect(scans.syncCalls, 0);
    expect(find.text('Enter offline capture mode'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
