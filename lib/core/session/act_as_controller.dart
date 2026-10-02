// lib/core/session/act_as_controller.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web/web.dart' as web;
import '../../data/api.dart';
import 'act_as.dart';
import 'session_controller.dart';

final actAsProvider = NotifierProvider<ActAsController, ActAsContext?>(ActAsController.new);

/// Pesan satu kali yang ditampilkan setelah reload (start/exit Act As memuat ulang app agar tidak ada cache identitas lama).
const actAsFlashKey = 'comen_act_as_flash';

class ActAsController extends Notifier<ActAsContext?> {
  Timer? _expiry;
  Future<void>? _extending;

  @override
  ActAsContext? build() {
    ref.onDispose(() => _expiry?.cancel());
    return null;
  }

  /// Dipanggil setiap my_session_state diterima.
  void sync(ActAsContext? ctx) {
    ActAsRuntime.effectiveUserId = ctx != null && ctx.isUser ? ctx.targetUserId : null;
    state = ctx;
    _arm();
  }

  void _arm() {
    _expiry?.cancel();
    final c = state;
    if (c == null) return;
    _expiry = Timer(c.remaining(), () => recoverOrEnd('waktu habis.'));
  }

  Future<void> start({String? userId, String? roleKey, required String reason}) async {
    final r = await ref.read(apiProvider).rpcMap('act_as_start', {
      'p_target_user': userId,
      'p_role_key': roleKey,
      'p_reason': reason,
    });
    await _storeToken(r['token'] as String?);
    _reload('Mode Act As aktif. Semua aksi tercatat di audit atas nama Anda.');
  }

  /// Interaksi user (klik/tap) → perpanjang otomatis bila sisa < 5 menit. Tanpa interaksi sesi habis sendiri (R38).
  void touch() {
    final c = state;
    if (c == null || _extending != null || !c.shouldAutoExtend()) return;
    extend().catchError((_) {});
  }

  Future<void> extend() => _extending ??= _doExtend().whenComplete(() => _extending = null);

  Future<void> _doExtend() async {
    final r = await ref.read(apiProvider).rpcMap('act_as_refresh');
    await _storeToken(r['token'] as String?);
    state = ActAsContext.fromJson(Map<String, dynamic>.from(r['context'] as Map));
    _arm();
  }

  /// Keluar dari Act As lalu reload sebagai super admin.
  /// [closeOnServer] hanya untuk exit manual/logout: act_as_close menutup SEMUA konteks aktor, jadi tab dengan token
  /// usang tidak boleh memanggilnya (bisa menutup sesi baru di tab lain). Konteks kedaluwarsa ditutup job sweep.
  Future<void> end({String reason = 'user_exit', String? flash, bool reload = true, bool closeOnServer = true}) async {
    _expiry?.cancel();
    if (closeOnServer && ActAsRuntime.token != null) {
      try {
        await ref.read(apiProvider).rpc('act_as_close', {'p_reason': reason});
      } catch (_) {}
    }
    await clearLocal();
    if (reload) _reload(flash ?? 'Anda kembali sebagai diri sendiri.');
  }

  /// Server menolak token. Bila tab lain sudah merotasi token (tersimpan di SecureStore) → adopsi; selain itu keluar.
  Future<void> recoverOrEnd(String message) async {
    final stored = await ref.read(secureStoreProvider).read(ActAsRuntime.storeKey);
    if (ActAsRuntime.isValidToken(stored) && stored != ActAsRuntime.token) {
      ActAsRuntime.token = stored;
      await ref.read(sessionProvider.notifier).refresh();
      return;
    }
    await end(reason: 'expired', flash: 'Sesi Act As berakhir: $message', closeOnServer: false);
  }

  Future<void> clearLocal() async {
    _expiry?.cancel();
    ActAsRuntime.token = null;
    ActAsRuntime.effectiveUserId = null;
    await ref.read(secureStoreProvider).del(ActAsRuntime.storeKey);
    state = null;
  }

  Future<void> _storeToken(String? token) async {
    if (!ActAsRuntime.isValidToken(token)) throw StateError('Token Act As tidak valid');
    ActAsRuntime.token = token;
    await ref.read(secureStoreProvider).put(ActAsRuntime.storeKey, token!);
  }

  void _reload(String flash) {
    web.window.sessionStorage.setItem(actAsFlashKey, flash);
    web.window.location.assign('/dashboard');
  }
}

/// Ambil (dan hapus) pesan flash setelah reload.
String? takeActAsFlash() {
  final v = web.window.sessionStorage.getItem(actAsFlashKey);
  if (v != null) web.window.sessionStorage.removeItem(actAsFlashKey);
  return v;
}
