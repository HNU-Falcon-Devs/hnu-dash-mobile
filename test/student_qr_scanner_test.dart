import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/student_qr_scanner.dart';

void main() {
  test('canonical Student IDs preserve leading zeros, case, and hyphens', () {
    expect(canonicalStudentId('00001234'), '00001234');
    expect(canonicalStudentId('AbC-001-x'), 'AbC-001-x');
    expect(canonicalStudentId('A'), 'A');
    expect(canonicalStudentId('A' * 64), 'A' * 64);
  });

  test('malformed QR payloads are rejected without normalization', () {
    for (final value in [
      null,
      '',
      ' 00001234',
      '00001234 ',
      'https://hnu.example/00001234',
      '{"student_id":"00001234"}',
      'A_B',
      'A' * 65,
    ]) {
      expect(canonicalStudentId(value), isNull);
    }
  });

  test('confirmation masking never reveals short or full identifiers', () {
    expect(maskStudentId('00001234'), '••••1234');
    expect(maskStudentId('A-1'), '••••');
  });

  testWidgets('repeated scanner callbacks return one canonical ID', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => StudentQrScannerPage(
                    scannerBuilder: (context, onValue, onProblem) =>
                        FilledButton(
                          onPressed: () {
                            onValue('00000123456');
                            onValue('00000123456');
                          },
                          child: const Text('Emit QR twice'),
                        ),
                  ),
                ),
              );
            },
            child: const Text('Open scanner'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open scanner'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emit QR twice'));
    await tester.pumpAndSettle();

    expect(result, '00000123456');
  });

  testWidgets('invalid QR stays in scanner and displays a safe error', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StudentQrScannerPage(
          scannerBuilder: (context, onValue, onProblem) => FilledButton(
            onPressed: () => onValue('https://example.test/student/123'),
            child: const Text('Emit invalid QR'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Emit invalid QR'));
    await tester.pumpAndSettle();

    expect(
      find.text('This QR code is not a valid Student ID Number.'),
      findsOneWidget,
    );
    expect(find.textContaining('example.test'), findsNothing);
  });

  testWidgets('canonical but real-looking QR cannot leave the scanner', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StudentQrScannerPage(
          scannerBuilder: (context, onValue, onProblem) => FilledButton(
            onPressed: () => onValue('202611091234'),
            child: const Text('Emit non-synthetic QR'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Emit non-synthetic QR'));
    await tester.pumpAndSettle();
    expect(
      find.text('Development scanning accepts synthetic test IDs only.'),
      findsOneWidget,
    );
    expect(find.textContaining('202611091234'), findsNothing);
  });

  testWidgets('camera permission denial offers settings and retry', (
    tester,
  ) async {
    var openedSettings = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StudentQrScannerPage(
          openSettings: () async {
            openedSettings = true;
            return true;
          },
          scannerBuilder: (context, onValue, onProblem) => FilledButton(
            onPressed: () => onProblem(ScannerProblem.permissionDenied),
            child: const Text('Simulate permission denial'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Simulate permission denial'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Camera permission is required'),
      findsOneWidget,
    );

    await tester.tap(find.text('Open app settings'));
    await tester.pumpAndSettle();
    expect(openedSettings, isTrue);

    await tester.tap(find.text('Retry camera'));
    await tester.pumpAndSettle();
    expect(find.text('Simulate permission denial'), findsOneWidget);
  });
}
