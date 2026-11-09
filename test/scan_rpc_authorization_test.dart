import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/scan_ingestion.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'RPC sends the originating token despite shared-session changes',
    () async {
      var sharedToken = 'token-staff-b';
      final observed = <String>[];
      const scanId = '65000000-0000-4000-8000-000000000001';
      final transport = MockClient((request) async {
        observed.add(request.headers['authorization'] ?? '');
        expect(request.url.path, '/rest/v1/rpc/ingest_attendance_scan');
        expect(
          (jsonDecode(request.body) as Map<String, dynamic>)['p_student_id'],
          '00000123456',
        );
        return http.Response(
          jsonEncode({
            'scan_id': scanId,
            'outcome': 'accepted',
            'received_at': '2026-11-08T02:15:00Z',
            'replayed': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = SupabaseClient(
        'https://project.example',
        'sb_publishable_synthetic_test',
        httpClient: transport,
        accessToken: () async => sharedToken,
      );
      addTearDown(client.dispose);

      // Authentication already belongs to B by the time the request is sent.
      // The per-request bearer must still be the captured Staff A token.
      final response = await submitPinnedAttendanceRpc(client, {
        'p_scan_id': scanId,
        'p_event_id': '63000000-0000-4000-8000-000000000001',
        'p_checkpoint_id': '64000000-0000-4000-8000-000000000001',
        'p_student_id': '00000123456',
      }, 'token-staff-a');
      expect((response as Map<String, dynamic>)['outcome'], 'accepted');
      expect(observed, ['Bearer token-staff-a']);

      sharedToken = 'token-staff-c';
      final retryResponse = await submitPinnedAttendanceRpc(client, {
        'p_scan_id': scanId,
        'p_event_id': '63000000-0000-4000-8000-000000000001',
        'p_checkpoint_id': '64000000-0000-4000-8000-000000000001',
        'p_student_id': '00000123456',
      }, 'token-staff-a');
      expect((retryResponse as Map<String, dynamic>)['scan_id'], scanId);
      expect(observed, ['Bearer token-staff-a', 'Bearer token-staff-a']);
    },
  );
}
