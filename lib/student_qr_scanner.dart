import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import 'development_scan_policy.dart';

enum ScannerProblem { permissionDenied, unavailable }

typedef ScannerSurfaceBuilder = Widget Function(
  BuildContext context,
  ValueChanged<String?> onValue,
  ValueChanged<ScannerProblem> onProblem,
);

String? canonicalStudentId(String? value) {
  if (!isCanonicalStudentId(value)) {
    return null;
  }
  return value;
}

String maskStudentId(String studentId) {
  if (studentId.length <= 4) return '••••';
  return '••••${studentId.substring(studentId.length - 4)}';
}

class StudentQrScannerPage extends StatefulWidget {
  const StudentQrScannerPage({
    super.key,
    this.scannerBuilder,
    this.openSettings = openAppSettings,
  });

  final ScannerSurfaceBuilder? scannerBuilder;
  final Future<bool> Function() openSettings;

  @override
  State<StudentQrScannerPage> createState() => _StudentQrScannerPageState();
}

class _StudentQrScannerPageState extends State<StudentQrScannerPage> {
  late final MobileScannerController _controller;
  bool _handling = false;
  ScannerProblem? _problem;
  String? _message;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
      returnImage: false,
    );
  }

  void _onBarcodeCapture(BarcodeCapture capture) {
    if (_handling) return;
    if (capture.barcodes.length != 1) {
      setState(() => _message = 'Show one HNU ID QR code at a time.');
      return;
    }
    _handleValue(capture.barcodes.single.rawValue);
  }

  Future<void> _handleValue(String? rawValue) async {
    if (_handling) return;
    final studentId = canonicalStudentId(rawValue);
    if (studentId == null) {
      setState(() {
        _message = 'This QR code is not a valid Student ID Number.';
      });
      return;
    }

    if (!isApprovedDevelopmentStudentId(studentId)) {
      setState(() {
        _message = 'Development scanning accepts synthetic test IDs only.';
      });
      return;
    }

    // Lock synchronously before stopping the camera; repeated frame callbacks
    // cannot create another confirmation or capture.
    _handling = true;
    setState(() => _message = null);
    if (widget.scannerBuilder == null) {
      try {
        await _controller.stop();
      } catch (_) {
        // Popping the route still disposes the camera controller.
      }
    }
    if (mounted) Navigator.of(context).pop(studentId);
  }

  void _handleProblem(ScannerProblem problem) {
    if (!mounted) return;
    setState(() {
      _problem = problem;
      _message = null;
    });
  }

  Future<void> _retryCamera() async {
    setState(() {
      _problem = null;
      _message = null;
    });
    if (widget.scannerBuilder != null) return;
    try {
      // Stopping clears a prior permission-denied controller error so the
      // plugin can request access again after the user returns from Settings.
      await _controller.stop();
      await _controller.start();
    } on MobileScannerException catch (error) {
      _handleProblem(
        error.errorCode == MobileScannerErrorCode.permissionDenied
            ? ScannerProblem.permissionDenied
            : ScannerProblem.unavailable,
      );
    } catch (_) {
      _handleProblem(ScannerProblem.unavailable);
    }
  }

  Future<void> _openSettings() async {
    await widget.openSettings();
  }

  Widget _problemPanel(ScannerProblem problem) {
    final denied = problem == ScannerProblem.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(denied ? Icons.no_photography : Icons.camera_alt_outlined),
            const SizedBox(height: 12),
            Text(
              denied ? 'Camera permission is required to scan an HNU ID.' : 'The camera is unavailable. Check camera access and try again.',
              textAlign: TextAlign.center,
            ),
            if (denied) ...[
              const SizedBox(height: 8),
              const Text(
                'Allow camera access in Android app settings, then return here.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _openSettings,
                child: const Text('Open app settings'),
              ),
            ],
            FilledButton(
              onPressed: _retryCamera,
              child: const Text('Retry camera'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final builder = widget.scannerBuilder;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan synthetic Student ID')),
      body: Column(
        children: [
          Expanded(
            child: _problem != null
                ? _problemPanel(_problem!)
                : builder != null
                ? builder(context, _handleValue, _handleProblem)
                : MobileScanner(
                    controller: _controller,
                    onDetect: _onBarcodeCapture,
                    errorBuilder: (context, error) {
                      final problem =
                          error.errorCode ==
                              MobileScannerErrorCode.permissionDenied
                          ? ScannerProblem.permissionDenied
                          : ScannerProblem.unavailable;
                      return _problemPanel(problem);
                    },
                  ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_message!, textAlign: TextAlign.center),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Scan an approved synthetic test QR code only. '
              'Real student data is not permitted. No image is saved.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
