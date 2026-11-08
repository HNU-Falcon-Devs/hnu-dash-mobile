import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'scan_ingestion.dart';
import 'secure_supabase_storage.dart';
import 'secure_value_store.dart';
import 'staff_workspace.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  StaffGateway? staffGateway;
  StaffScanGateway? scanGateway;
  String? configurationError;

  if (_url.isNotEmpty && _key.isNotEmpty) {
    final secureValues = FlutterSecureValueStore();
    final sessionStorage = SecureSessionStorage(
      values: secureValues,
      supabaseUrl: _url,
    );
    final pkceStorage = SecurePkceStorage(values: secureValues);
    try {
      await pkceStorage.migrateLegacyVerifier();
      await Supabase.initialize(
        url: _url,
        publishableKey: _key,
        authOptions: FlutterAuthClientOptions(
          localStorage: sessionStorage,
          pkceAsyncStorage: pkceStorage,
        ),
      );
      final client = Supabase.instance.client;
      staffGateway = SupabaseStaffGateway(client);
      scanGateway = SupabaseStaffScanGateway.forSupabase(
        client,
        secureValues: secureValues,
      );
    } catch (_) {
      configurationError = 'Secure device storage could not be initialized. Sign-in and attendance scanning are disabled. Existing local records have not been intentionally removed.';
    }
  }

  runApp(
    HnuDashMobileApp(
      gateway: staffGateway,
      scanGateway: scanGateway,
      configurationError: configurationError,
    ),
  );
}

class HnuDashMobileApp extends StatelessWidget {
  const HnuDashMobileApp({
    super.key,
    this.gateway,
    this.scanGateway,
    this.configurationError,
    this.scannerPageBuilder,
  });

  final StaffGateway? gateway;
  final StaffScanGateway? scanGateway;
  final String? configurationError;
  final Widget Function()? scannerPageBuilder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HNU DASH Mobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF164A68)),
        useMaterial3: true,
      ),
      home: gateway == null
          ? ConfigurationScreen(error: configurationError)
          : StaffWorkspace(
              gateway: gateway!,
              scanGateway: scanGateway,
              scannerPageBuilder: scannerPageBuilder,
            ),
    );
  }
}

class ConfigurationScreen extends StatelessWidget {
  const ConfigurationScreen({super.key, this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HNU DASH Mobile')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error ??
                'Development configuration required. Supply SUPABASE_URL and '
                    'SUPABASE_PUBLISHABLE_KEY using --dart-define. '
                    'Use synthetic Student IDs only.',
          ),
        ),
      ),
    );
  }
}
