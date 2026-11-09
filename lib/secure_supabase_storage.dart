import 'package:supabase_flutter/supabase_flutter.dart';

import 'secure_value_store.dart';

String projectSessionStorageKey(String supabaseUrl) =>
    'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';

/// Supabase Flutter 2.x session storage backed by Android Keystore encryption.
class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage({required this.values, required this.supabaseUrl})
    : _persistSessionKey = projectSessionStorageKey(supabaseUrl),
      _legacy = SharedPreferencesLocalStorage(
        persistSessionKey: projectSessionStorageKey(supabaseUrl),
      );

  final SecureValueStore values;
  final String supabaseUrl;
  final String _persistSessionKey;
  final SharedPreferencesLocalStorage _legacy;

  @override
  Future<void> initialize() async {
    await _legacy.initialize();

    final secureSession = await values.read(_persistSessionKey);
    if (secureSession == null) {
      final legacySession = await _legacy.accessToken();
      if (legacySession != null) {
        await values.write(_persistSessionKey, legacySession);
        if (await values.read(_persistSessionKey) != legacySession) {
          throw StateError(
            'The existing Supabase session could not be secured.',
          );
        }
      }
    }

    // Remove only the old Supabase session key, and only after the secure copy
    // has been verified. Other SharedPreferences values remain untouched.
    if (await values.read(_persistSessionKey) != null) {
      await _legacy.removePersistedSession();
    }
  }

  @override
  Future<String?> accessToken() => values.read(_persistSessionKey);

  @override
  Future<bool> hasAccessToken() async =>
      await values.read(_persistSessionKey) != null;

  @override
  Future<void> persistSession(String persistSessionString) =>
      values.write(_persistSessionKey, persistSessionString);

  @override
  Future<void> removePersistedSession() => values.delete(_persistSessionKey);
}

/// Supabase Flutter 2.x PKCE verifier storage. The SDK uses a separate
/// GotrueAsyncStorage interface for OAuth code verifiers.
class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage({required this.values});

  static const legacyVerifierKey = 'supabase.auth.token-code-verifier';
  static const _securePrefix = 'hnu_dash_pkce_v1_';

  final SecureValueStore values;
  final SharedPreferencesGotrueAsyncStorage _legacy =
      SharedPreferencesGotrueAsyncStorage();

  String _key(String key) => '$_securePrefix$key';

  Future<void> migrateLegacyVerifier() async {
    final legacyVerifier = await _legacy.getItem(key: legacyVerifierKey);
    if (legacyVerifier == null) return;

    final secureVerifier = await values.read(_key(legacyVerifierKey));
    if (secureVerifier == null) {
      await values.write(_key(legacyVerifierKey), legacyVerifier);
      if (await values.read(_key(legacyVerifierKey)) != legacyVerifier) {
        throw StateError('The pending OAuth verifier could not be secured.');
      }
    }

    // Only the old PKCE verifier is removed; unrelated preferences survive.
    await _legacy.removeItem(key: legacyVerifierKey);
  }

  @override
  Future<String?> getItem({required String key}) => values.read(_key(key));

  @override
  Future<void> setItem({required String key, required String value}) =>
      values.write(_key(key), value);

  @override
  Future<void> removeItem({required String key}) => values.delete(_key(key));
}
