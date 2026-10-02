@TestOn('browser')
library;

import 'package:comen/core/errors/app_failure.dart';
import 'package:comen/core/router/gate.dart';
import 'package:comen/core/router/route_rules.dart';
import 'package:comen/core/session/session_controller.dart';
import 'package:comen/core/session/session_state.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '0f8fad5b-d9cb-469f-a165-70867728950e';

const _allPaths = [
  '/splash', '/login', '/auth/callback', '/invite', '/privacy', '/pending', '/register', '/suspended',
  '/account-closed', '/device-revoked', '/mfa/enroll', '/mfa/verify', '/forbidden', '/dashboard', '/notifications',
  '/tasks', '/tasks/tracking', '/tasks/review', '/tasks/$_id', '/contracts', '/contracts/new', '/contracts/$_id',
  '/contracts/$_id/onedrive', '/contracts/$_id/meetings/$_id', '/vendors', '/vendors/$_id', '/my-company',
  '/incidents', '/incidents/new', '/incidents/$_id', '/kpi', '/chat', '/chat/saved', '/chat/$_id',
  '/settings/profile', '/settings/devices', '/settings/security', '/settings/notifications', '/admin',
  '/admin/approvals', '/admin/users', '/admin/users/$_id', '/admin/roles', '/admin/invites', '/admin/contractors',
  '/admin/contracts', '/admin/onedrive-links', '/admin/doc-catalog', '/admin/settings', '/admin/email', '/admin/chat',
  '/admin/security', '/admin/audit', '/admin/privacy', '/admin/system',
];

SessionState _s({
  String status = 'active',
  bool wfrd = true,
  String? contractor,
  List<String> perms = const [],
  bool mfaRequired = false,
  bool mfaEnrolled = false,
  String aal = 'aal1',
}) =>
    SessionState.fromJson({
      'user_id': _id,
      'email': 'u@x.com',
      'status': status,
      'is_wfrd': wfrd,
      'contractor_id': contractor,
      'permissions': perms,
      'mfa_required': mfaRequired,
      'mfa_enrolled': mfaEnrolled,
      'aal': aal,
      'device_state': 'ok',
    });

/// Mengikuti rantai redirect seperti GoRouter; gagal bila terjadi loop (C1).
String _resolve(SessionStatus status, String location) {
  var uri = Uri.parse(location);
  final seen = <String>{};
  for (var i = 0; i < 8; i++) {
    final next = gateUri(status, uri);
    if (next == null) return uri.path;
    if (!seen.add(next)) fail('redirect loop: $seen');
    uri = Uri.parse(next);
  }
  fail('redirect terlalu panjang dari $location');
}

void main() {
  test('booting → splash', () {
    expect(_resolve(const SessionBooting(), '/tasks'), '/splash');
  });

  test('signedOut → login (publik tetap boleh) & next dibawa', () {
    expect(_resolve(const SessionSignedOut(), '/tasks/$_id'), '/login');
    expect(gateUri(const SessionSignedOut(), Uri.parse('/tasks/$_id')), '/login?next=${Uri.encodeComponent('/tasks/$_id')}');
    expect(gateUri(const SessionSignedOut(reason: 'auth_error'), Uri.parse('/dashboard')), '/login?reason=auth_error&next=%2Fdashboard');
    expect(_resolve(const SessionSignedOut(), '/privacy'), '/privacy');
    expect(_resolve(const SessionSignedOut(), '/invite'), '/invite');
  });

  test('device revoked & error tanpa loop (C1)', () {
    expect(_resolve(const SessionDeviceRevoked(), '/dashboard'), '/device-revoked');
    expect(_resolve(const SessionDeviceRevoked(), '/device-revoked'), '/device-revoked');
    expect(_resolve(const SessionError(AppFailure(Hint.network, 'x')), '/kpi'), '/splash');
  });

  test('pending hanya /pending·/register·/settings/devices·/privacy', () {
    final s = SessionReady(_s(status: 'pending', wfrd: false));
    expect(_resolve(s, '/dashboard'), '/pending');
    expect(_resolve(s, '/admin'), '/pending');
    for (final ok in ['/pending', '/register', '/settings/devices', '/privacy']) {
      expect(_resolve(s, ok), ok);
    }
  });

  test('suspended / closed', () {
    expect(_resolve(SessionReady(_s(status: 'suspended')), '/tasks'), '/suspended');
    expect(_resolve(SessionReady(_s(status: 'suspended')), '/suspended'), '/suspended');
    expect(_resolve(SessionReady(_s(status: 'rejected')), '/tasks'), '/account-closed');
    expect(_resolve(SessionReady(_s(status: 'deactivated')), '/account-closed'), '/account-closed');
  });

  test('MFA wajib → enroll/verify', () {
    expect(_resolve(SessionReady(_s(mfaRequired: true)), '/tasks'), '/mfa/enroll');
    expect(_resolve(SessionReady(_s(mfaRequired: true, mfaEnrolled: true)), '/tasks'), '/mfa/verify');
    expect(_resolve(SessionReady(_s(mfaRequired: true, mfaEnrolled: true, aal: 'aal2')), '/tasks'), '/tasks');
  });

  test('admin tanpa aal2 → verify/enroll; dengan aal2 → masuk', () {
    const perms = ['admin.users.view', 'admin.users.approve'];
    expect(_resolve(SessionReady(_s(perms: perms, mfaEnrolled: true)), '/admin/users'), '/mfa/verify');
    expect(_resolve(SessionReady(_s(perms: perms)), '/admin/users'), '/mfa/enroll');
    expect(_resolve(SessionReady(_s(perms: perms, mfaEnrolled: true, aal: 'aal2')), '/admin/users'), '/admin/users');
  });

  test('rule false → /forbidden', () {
    final contractor = SessionReady(_s(wfrd: false, contractor: _id, perms: const ['chat.use']));
    expect(_resolve(contractor, '/vendors'), '/forbidden');
    expect(_resolve(contractor, '/tasks/review'), '/forbidden');
    expect(_resolve(contractor, '/my-company'), '/my-company');
    expect(_resolve(SessionReady(_s(aal: 'aal2', mfaEnrolled: true)), '/admin/unknown-module'), '/forbidden');
  });

  test('user aktif di halaman publik/status → dashboard', () {
    expect(_resolve(SessionReady(_s()), '/login'), '/dashboard');
    expect(_resolve(SessionReady(_s()), '/pending'), '/dashboard');
    expect(_resolve(SessionReady(_s()), '/login?next=%2Ftasks'), '/tasks');
  });

  test('halaman MFA: tetap di verify saat aal1, lanjut ke next setelah aal2', () {
    const perms = ['admin.users.view'];
    final aal1 = SessionReady(_s(perms: perms, mfaEnrolled: true));
    final aal2 = SessionReady(_s(perms: perms, mfaEnrolled: true, aal: 'aal2'));
    expect(gateUri(aal1, Uri.parse('/mfa/verify?next=%2Fadmin%2Fusers')), isNull);
    expect(_resolve(aal2, '/mfa/verify?next=%2Fadmin%2Fusers'), '/admin/users');
    expect(_resolve(aal1, '/mfa/enroll'), '/mfa/verify');
    expect(gateUri(SessionReady(_s()), Uri.parse('/mfa/enroll')), isNull);
  });

  test('RouteRules: setiap route terlindungi punya rule; admin selalu aal2', () {
    for (final p in _allPaths) {
      if (publicPaths.contains(p) || statusPaths.contains(p) || p == '/forbidden') continue;
      final r = RouteRules.match(p);
      expect(r, isNotNull, reason: p);
      if (p.startsWith('/admin')) expect(r!.requiresAal2, isTrue, reason: p);
    }
  });
}
