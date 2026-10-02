// lib/core/router/gate.dart
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
import '../session/session_controller.dart';
import 'route_rules.dart';

const publicPaths = {'/login', '/auth/callback', '/invite', '/privacy'};
const statusPaths = {'/splash', '/pending', '/suspended', '/account-closed', '/device-revoked'};
const _nextKey = 'comen_next';

/// Anti open-redirect (C3): hanya path relatif internal, bukan halaman sesi/status
String? safeNext(String? n) {
  if (n == null || n.isEmpty || n.length > 512) return null;
  if (!n.startsWith('/') || n.startsWith('//') || n.contains('\\') || n.contains('\u0000')) return null;
  final u = Uri.tryParse(n);
  if (u == null || u.hasScheme || u.hasAuthority) return null;
  if (publicPaths.contains(u.path) || statusPaths.contains(u.path) || u.path.startsWith('/mfa/')) return null;
  return n;
}

/// `next` disimpan di sessionStorage selama OAuth (redirect Google tidak membawa query aplikasi)
void rememberNext(String? n) {
  final s = safeNext(n);
  s == null ? web.window.sessionStorage.removeItem(_nextKey) : web.window.sessionStorage.setItem(_nextKey, s);
}
String takeNext() {
  final s = safeNext(web.window.sessionStorage.getItem(_nextKey));
  web.window.sessionStorage.removeItem(_nextKey);
  return s ?? '/dashboard';
}

String? gate(SessionStatus status, GoRouterState st) => gateUri(status, st.uri);

String? gateUri(SessionStatus status, Uri uri) {
  final path = uri.path;
  final here = uri.toString();
  final nextParam = safeNext(uri.queryParameters['next']);
  String? only(String target, {Set<String> also = const {}}) =>
      (path == target || also.contains(path)) ? null : '$target?next=${Uri.encodeComponent(nextParam ?? safeNext(here) ?? '/dashboard')}';

  switch (status) {
    case SessionBooting():
      return path == '/splash' ? null : '/splash?next=${Uri.encodeComponent(safeNext(here) ?? '/dashboard')}';
    case SessionSignedOut(:final reason):
      if (publicPaths.contains(path)) return null;
      return '/login?${reason == null ? '' : 'reason=${Uri.encodeComponent(reason)}&'}'
          'next=${Uri.encodeComponent(nextParam ?? safeNext(here) ?? '/dashboard')}';
    case SessionDeviceRevoked():
      return path == '/device-revoked' ? null : '/device-revoked';     // C1: tidak redirect ke dirinya sendiri
    case SessionError():
      return path == '/splash' ? null : '/splash';
    case SessionReady(:final s):
      switch (s.status) {
        case 'pending':
          return only('/pending', also: const {'/register', '/register/wfrd', '/settings/devices', '/privacy'});
        case 'suspended':
          return only('/suspended');
        case 'rejected': case 'deactivated':
          return only('/account-closed');
      }
      if (s.mfaRequired && !s.mfaEnrolled) return only('/mfa/enroll');
      if (s.mfaRequired && s.aal != 'aal2') return only('/mfa/verify');
      if (path == '/mfa/verify' || path == '/mfa/enroll') {
        if (!s.mfaEnrolled) return path == '/mfa/enroll' ? null : only('/mfa/enroll');
        if (s.aal != 'aal2') return path == '/mfa/verify' ? null : only('/mfa/verify');
        return nextParam ?? takeNext();
      }
      if (statusPaths.contains(path) || publicPaths.contains(path) && path != '/privacy') {
        return nextParam ?? takeNext();
      }
      final rule = RouteRules.match(path);
      if (rule == null) return null;                                   // 404 ditangani errorBuilder
      if (rule.requiresAal2 && s.aal != 'aal2') {
        return s.mfaEnrolled ? '/mfa/verify?next=${Uri.encodeComponent(here)}' : '/mfa/enroll?next=${Uri.encodeComponent(here)}';
      }
      return rule.allows(s) ? null : '/forbidden';
  }
}
