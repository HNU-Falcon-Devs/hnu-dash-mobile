import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'staff_workspace.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_url.isNotEmpty && _key.isNotEmpty) {
    await Supabase.initialize(url: _url, anonKey: _key);
  }
  runApp(HnuDashMobileApp(
    gateway: _url.isNotEmpty && _key.isNotEmpty
        ? SupabaseStaffGateway(Supabase.instance.client)
        : null,
  ));
}

class HnuDashMobileApp extends StatelessWidget {
  const HnuDashMobileApp({super.key, this.gateway});

  final StaffGateway? gateway;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HNU DASH Mobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF164A68)),
        useMaterial3: true,
      ),
      home: gateway == null
          ? const ConfigurationScreen()
          : StaffWorkspace(gateway: gateway!),
    );
  }
}

class ConfigurationScreen extends StatelessWidget {
  const ConfigurationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HNU DASH Mobile')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Development configuration required. Supply SUPABASE_URL and '
            'SUPABASE_PUBLISHABLE_KEY using --dart-define. '
            'Do not use real student data.',
          ),
        ),
      ),
    );
  }
}
