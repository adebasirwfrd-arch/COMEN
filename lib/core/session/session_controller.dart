// lib/core/session/session_controller.dart
import 'dart:async';
import 'dart:js_interop';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;
import '../errors/app_failure.dart';
import '../security/browser_info.dart';
import '../security/device_identity.dart';
import '../security/secure_store.dart';
import 'act_as_controller.dart';
import 'session_state.dart';

final secureStoreProvider = Provider<SecureStore>((_) => throw UnimplementedError());
final deviceIdentityProvider = Provider<DeviceIdentity>((_) => throw UnimplementedError());
final sessionProvider = NotifierProvider<SessionController, SessionStatus>(SessionController.new);
// Event realtime = petunjuk → fitur terkait melakukan refetch via RPC
final notificationBus = Provider<StreamController<String>>((ref) {
  final c = StreamController<String>.broadcast(); ref.onDispose(c.close); return c;
});
final chatBus = Provider<StreamController<Map<String, dynamic>>>((ref) {
  final c = StreamController<Map<String, dynamic>>.broadcast(); ref.onDispose(c.close); return c;
});

sealed class SessionStatus { const SessionStatus(); }
class SessionBooting extends SessionStatus { const SessionBooting(); }
class SessionSignedOut extends SessionStatus { const SessionSignedOut({this.reason}); final String? reason; }
class SessionDeviceRevoked extends SessionStatus { const SessionDeviceRevoked(); }
class SessionError extends SessionStatus { const SessionError(this.failure); final AppFailure failure; }
class SessionReady extends SessionStatus { const SessionReady(this.s); final SessionState s; }

class SessionController extends Notifier<SessionStatus> {
  SupabaseClient get _sb => Supabase.instance.client;
  StreamSubscription<AuthState>? _authSub;
  RealtimeChannel? _userChannel;
  Future<void>? _boot;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  SessionStatus build() {
    _authSub = _sb.auth.onAuthStateChange.listen(_onAuth, onError: _onAuthError);
    final watchdog = Timer(const Duration(seconds: 20), () {
      if (state is SessionBooting) {
        state = const SessionError(AppFailure(Hint.unknown, 'Memulai sesi terlalu lama. Coba lagi atau masuk ulang.'));
      }
    });
    // Tab kembali aktif → cek ulang sesi (menangkap revoke bila event realtime terlewat), maks 1×/menit
    final JSFunction onVisible = ((web.Event _) {
      if (web.document.visibilityState == 'visible' && DateTime.now().difference(_lastRefresh).inSeconds > 60) refresh();
    }).toJS;
    web.document.addEventListener('visibilitychange', onVisible);
    ref.onDispose(() {
      watchdog.cancel();
      _authSub?.cancel();
      _leaveUserChannel();
      web.document.removeEventListener('visibilitychange', onVisible);
    });
    return const SessionBooting();
  }

  Future<void> _onAuth(AuthState e) async {
    switch (e.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.mfaChallengeVerified:
        if (e.session == null) { state = const SessionSignedOut(); return; }
        await bootstrap(force: e.event != AuthChangeEvent.initialSession);
      case AuthChangeEvent.signedOut:
        _leaveUserChannel();
        state = const SessionSignedOut();
      default:
        break;                                             // tokenRefreshed: realtime setAuth ditangani SDK
    }
  }

  /// URL callback berisi error (link OTP kedaluwarsa, OAuth dibatalkan, code PKCE tidak valid) dikirim SDK sebagai error stream,
  /// tidak selalu diikuti event sesi → putuskan dari sesi tersimpan agar tidak tertahan di splash.
  void _onAuthError(Object e, StackTrace _) {
    if (state is! SessionBooting) return;
    if (_sb.auth.currentSession != null) {
      bootstrap();
      return;
    }
    final banned = e is AuthException && (e.code == 'user_banned' || e.message.toLowerCase().contains('banned'));
    state = SessionSignedOut(reason: banned ? 'account_disabled' : 'auth_error');
  }

  /// Urutan wajib (C7): register_device → my_session_state → subscribe user:{id}
  Future<void> bootstrap({bool force = false}) => _boot = (_boot != null && !force) ? _boot! : _doBootstrap();

  Future<void> _doBootstrap() async {
    try {
      final reg = Map<String, dynamic>.from(await _sb.rpc('register_device', params: {
        'p_device_hash': ref.read(deviceIdentityProvider).hash,
        'p_label': BrowserInfo.label(),
      }) as Map);
      switch (reg['device_state']) {
        case 'revoked':
          state = const SessionDeviceRevoked();
          return;
        case 'reauth_required':
          await signOutLocal(reason: 'reauth');
          return;
      }
      await refresh();
      _joinUserChannel();
    } catch (e) {
      await handle(AppFailure.from(e));
    } finally {
      _boot = null;
    }
  }

  Future<void> refresh() async {
    if (_sb.auth.currentSession == null) return;
    _lastRefresh = DateTime.now();
    try {
      final s = SessionState.fromJson(Map<String, dynamic>.from(await _sb.rpc('my_session_state') as Map));
      ref.read(actAsProvider.notifier).sync(s.actAs);
      switch (s.deviceState) {
        case 'revoked': state = const SessionDeviceRevoked();
        case 'reauth_required': await signOutLocal(reason: 'reauth');
        case 'missing': case 'unregistered': await bootstrap(force: true);
        default: state = SessionReady(s);
      }
    } catch (e) {
      await handle(AppFailure.from(e));
    }
  }

  /// Reaksi terpusat atas hint (tabel 16.7) yang menyangkut sesi
  Future<void> handle(AppFailure f) async {
    switch (f.hint) {
      case Hint.unauthenticated: case Hint.reauthRequired: await signOutLocal(reason: 'reauth');
      case Hint.loginMethodDisabled: await signOutLocal(reason: 'otp_disabled');
      case Hint.deviceRevoked: state = const SessionDeviceRevoked();
      case Hint.deviceMissing: case Hint.deviceUnregistered: await bootstrap(force: true);
      case Hint.deviceMismatch: web.window.location.reload();
      case Hint.accountInactive: case Hint.mfaRequired: await refresh();
      case Hint.actAsEnded: await ref.read(actAsProvider.notifier).recoverOrEnd(f.message);
      default: if (state is SessionBooting) state = SessionError(f);
    }
  }

  void _joinUserChannel() {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null || _userChannel != null) return;
    _userChannel = _sb.channel('user:$uid', opts: const RealtimeChannelConfig(private: true))
      ..onBroadcast(event: 'session_check', callback: (_) => refresh())
      ..onBroadcast(event: 'notification', callback: (_) => ref.read(notificationBus).add('notification'))
      ..onBroadcast(event: 'chat_activity', callback: (p) => ref.read(chatBus).add(p))
      ..onBroadcast(event: 'chat_read', callback: (p) => ref.read(chatBus).add(p))
      ..subscribe();
  }

  void _leaveUserChannel() {
    final ch = _userChannel;
    _userChannel = null;
    if (ch != null) _sb.removeChannel(ch);
  }

  Future<void> signOutLocal({String? reason}) async {
    _leaveUserChannel();
    await ref.read(actAsProvider.notifier).end(reason: 'logout', reload: false);   // R42: logout menutup Act As
    await _sb.auth.signOut(scope: SignOutScope.local);
    state = SessionSignedOut(reason: reason);
  }

  /// /device-revoked → "Masuk ulang di perangkat ini": identitas perangkat baru + login segar
  Future<void> resetDeviceAndSignOut() async {
    await ref.read(actAsProvider.notifier).end(reason: 'logout', reload: false);
    await DeviceIdentity.reset(ref.read(secureStoreProvider));
    await _sb.auth.signOut(scope: SignOutScope.local);
    web.window.location.replace('/login');               // reload → header x-device-id baru
  }
}
