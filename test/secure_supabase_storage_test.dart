import 'package:flutter_test/flutter_test.dart';
import 'package:hnu_dash_mobile/secure_supabase_storage.dart';
import 'package:hnu_dash_mobile/secure_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MemorySecureValueStore implements SecureValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  const url = 'https://hnu-test-project.supabase.co';
  const session = '{"currentSession":{"access_token":"synthetic-token"}}';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('moves only the old Supabase session into secure storage', () async {
    final key = projectSessionStorageKey(url);
    final legacy = SharedPreferencesLocalStorage(persistSessionKey: key);
    await legacy.initialize();
    await legacy.persistSession(session);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('unrelated_preference', 'preserve-me');

    final secure = MemorySecureValueStore();
    final storage = SecureSessionStorage(values: secure, supabaseUrl: url);
    await storage.initialize();

    expect(await storage.accessToken(), session);
    expect(await storage.hasAccessToken(), isTrue);
    expect(await legacy.hasAccessToken(), isFalse);
    expect(preferences.getString('unrelated_preference'), 'preserve-me');
  });

  test('does not overwrite a secure session with an old preference', () async {
    final key = projectSessionStorageKey(url);
    final legacy = SharedPreferencesLocalStorage(persistSessionKey: key);
    await legacy.initialize();
    await legacy.persistSession('old-session');

    final secure = MemorySecureValueStore()..values[key] = 'new-secure-session';
    final storage = SecureSessionStorage(values: secure, supabaseUrl: url);
    await storage.initialize();

    expect(await storage.accessToken(), 'new-secure-session');
    expect(await legacy.hasAccessToken(), isFalse);
  });

  test('persists and removes sessions only through secure storage', () async {
    final secure = MemorySecureValueStore();
    final storage = SecureSessionStorage(values: secure, supabaseUrl: url);
    await storage.initialize();
    await storage.persistSession(session);
    expect(await storage.accessToken(), session);
    await storage.removePersistedSession();
    expect(await storage.hasAccessToken(), isFalse);
  });

  test(
    'moves the old PKCE verifier and preserves unrelated preferences',
    () async {
      final legacy = SharedPreferencesGotrueAsyncStorage();
      await legacy.setItem(
        key: SecurePkceStorage.legacyVerifierKey,
        value: 'synthetic-pkce-verifier',
      );
      await legacy.setItem(key: 'unrelated-key', value: 'preserve-me');

      final secure = MemorySecureValueStore();
      final storage = SecurePkceStorage(values: secure);
      await storage.migrateLegacyVerifier();

      expect(
        await storage.getItem(key: SecurePkceStorage.legacyVerifierKey),
        'synthetic-pkce-verifier',
      );
      expect(
        await legacy.getItem(key: SecurePkceStorage.legacyVerifierKey),
        isNull,
      );
      expect(await legacy.getItem(key: 'unrelated-key'), 'preserve-me');
    },
  );

  test(
    'stores PKCE values securely and removes only the requested key',
    () async {
      final secure = MemorySecureValueStore();
      final storage = SecurePkceStorage(values: secure);
      await storage.setItem(key: 'verifier-a', value: 'synthetic-a');
      await storage.setItem(key: 'verifier-b', value: 'synthetic-b');
      await storage.removeItem(key: 'verifier-a');

      expect(await storage.getItem(key: 'verifier-a'), isNull);
      expect(await storage.getItem(key: 'verifier-b'), 'synthetic-b');
    },
  );
}
