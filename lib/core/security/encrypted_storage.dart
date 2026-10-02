// lib/core/security/encrypted_storage.dart
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'secure_store.dart';

const _sessionKey = 'sb_session_v1';

/// Sesi Supabase (access + refresh token) — terenkripsi AES-256-GCM, tidak pernah plaintext di storage.
class EncryptedSessionStorage extends LocalStorage {
  EncryptedSessionStorage(this._store);
  final SecureStore _store;
  String? _cache;

  @override
  Future<void> initialize() async => _cache = await _store.read(_sessionKey);
  @override
  Future<bool> hasAccessToken() async => (_cache ?? await _store.read(_sessionKey)) != null;
  @override
  Future<String?> accessToken() async => _cache ??= await _store.read(_sessionKey);
  @override
  Future<void> persistSession(String s) async {
    _cache = s;
    await _store.put(_sessionKey, s);
    _store.notifySession();
  }
  @override
  Future<void> removePersistedSession() async {
    _cache = null;
    await _store.del(_sessionKey);
    _store.notifySession();
  }

  /// Dipanggil saat tab lain menyimpan sesi baru → adopsi tanpa refresh (hindari reuse refresh token lama)
  Future<void> adoptFromOtherTab(GoTrueClient auth) async {
    final s = await _store.read(_sessionKey);
    _cache = s;
    if (s == null) {
      if (auth.currentSession != null) await auth.signOut(scope: SignOutScope.local);
      return;
    }
    final incoming = jsonDecode(s) as Map<String, dynamic>;
    if (incoming['refresh_token'] != auth.currentSession?.refreshToken) await auth.recoverSession(s);
  }
}

/// PKCE code verifier — terenkripsi (C13)
class EncryptedAsyncStorage extends GotrueAsyncStorage {
  EncryptedAsyncStorage(this._store);
  final SecureStore _store;
  @override
  Future<String?> getItem({required String key}) => _store.read('pkce:$key');
  @override
  Future<void> setItem({required String key, required String value}) => _store.put('pkce:$key', value);
  @override
  Future<void> removeItem({required String key}) => _store.del('pkce:$key');
}
