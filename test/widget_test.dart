import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/main.dart';

void main() {
  testWidgets('launches and identifies the foundation screen', (tester) async {
    await tester.pumpWidget(const HnuDashMobileApp());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('HNU DASH Mobile'), findsNWidgets(2));
    expect(
      find.text('Attendance-scanning companion for HNU DASH.'),
      findsOneWidget,
    );
    expect(find.text('Planned features'), findsOneWidget);
    expect(find.textContaining('not available yet'), findsOneWidget);
  });
}
