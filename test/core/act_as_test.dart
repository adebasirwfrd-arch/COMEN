import 'package:comen/core/router/route_rules.dart';
import 'package:comen/core/session/act_as.dart';
import 'package:comen/core/session/session_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _token = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abcde';

Map<String, dynamic> _ctx({String kind = 'user', DateTime? now, Duration left = const Duration(minutes: 15), Duration hard = const Duration(hours: 2)}) {
  final n = now ?? DateTime.utc(2026, 10, 2, 8);
  return {
    'id': 'c0000000-0000-4000-8000-000000000001',
    'kind': kind,
    'target_user_id': kind == 'user' ? 'u0000000-0000-4000-8000-000000000002' : null,
    'target_name': kind == 'user' ? 'Budi PIC' : null,
    'target_email': kind == 'user' ? 'budi@eji.co.id' : null,
    'contractor_id': kind == 'user' ? 'k0000000-0000-4000-8000-000000000003' : null,
    'contractor_name': kind == 'user' ? 'PT EJI' : null,
    'level': kind == 'user' ? 'pic' : null,
    'role_key': kind == 'role' ? 'process_owner' : null,
    'role_name': kind == 'role' ? 'Process Owner' : null,
    'reason': 'Investigasi tiket #42',
    'started_at': n.toIso8601String(),
    'expires_at': n.add(left).toIso8601String(),
    'hard_expires_at': n.add(hard).toIso8601String(),
    'server_now': n.toIso8601String(),
  };
}

Map<String, dynamic> _session({Map<String, dynamic>? actAs, bool canActAs = false}) => {
      'user_id': actAs == null ? 'root' : 'u0000000-0000-4000-8000-000000000002',
      'email': actAs == null ? 'ade@weatherford.com' : 'budi@eji.co.id',
      'status': 'active',
      'is_root_admin': false,
      'is_wfrd': actAs == null,
      'contractor_id': actAs == null ? null : 'k0000000-0000-4000-8000-000000000003',
      'device_state': 'trusted',
      'aal': 'aal2',
      'roles': const [],
      'permissions': actAs == null ? const ['admin.users.manage', 'contract.read'] : const ['task.read', 'chat.use'],
      'act_as': actAs,
      'real_user_id': 'root',
      'real_email': 'ade@weatherford.com',
      'real_full_name': 'Ade',
      'real_is_root_admin': true,
      'can_act_as': canActAs,
    };

void main() {
  group('ActAsRuntime', () {
    test('format token 43 karakter base64url', () {
      expect(ActAsRuntime.isValidToken(_token), isTrue);
      expect(ActAsRuntime.isValidToken(null), isFalse);
      expect(ActAsRuntime.isValidToken(_token.substring(1)), isFalse);
      expect(ActAsRuntime.isValidToken('${_token.substring(1)}+'), isFalse);
      expect(ActAsRuntime.isValidToken('${_token.substring(1)}='), isFalse);
    });
  });

  group('ActAsHttpClient', () {
    late List<http.BaseRequest> seen;
    late ActAsHttpClient client;

    setUp(() {
      seen = [];
      client = ActAsHttpClient(
        host: 'proj.supabase.co',
        inner: MockClient((r) async {
          seen.add(r);
          return http.Response('{}', 200);
        }),
      );
    });
    tearDown(() => ActAsRuntime.token = null);

    test('header hanya untuk PostgREST & Edge Functions host sendiri', () async {
      ActAsRuntime.token = _token;
      await client.get(Uri.parse('https://proj.supabase.co/rest/v1/rpc/my_session_state'));
      await client.get(Uri.parse('https://proj.supabase.co/functions/v1/admin-actions'));
      await client.get(Uri.parse('https://proj.supabase.co/auth/v1/token'));
      await client.get(Uri.parse('https://proj.supabase.co/storage/v1/object/x'));
      await client.get(Uri.parse('https://evil.example/rest/v1/rpc/x'));
      await client.get(Uri.parse('https://proj.supabase.co.evil.example/rest/v1/rpc/x'));
      expect(seen.map((r) => r.headers[ActAsRuntime.header]).toList(), [_token, _token, null, null, null, null]);
    });

    test('tanpa token tidak ada header', () async {
      await client.get(Uri.parse('https://proj.supabase.co/rest/v1/rpc/my_session_state'));
      expect(seen.single.headers.containsKey(ActAsRuntime.header), isFalse);
    });
  });

  group('ActAsContext', () {
    test('mode user', () {
      final c = ActAsContext.fromJson(_ctx());
      expect(c.isUser, isTrue);
      expect(c.title, 'Budi PIC');
      expect(c.subtitle, contains('PT EJI'));
      expect(c.reason, 'Investigasi tiket #42');
    });

    test('mode role', () {
      final c = ActAsContext.fromJson(_ctx(kind: 'role'));
      expect(c.kind, ActAsKind.role);
      expect(c.title, 'Process Owner');
      expect(c.targetUserId, isNull);
    });

    test('countdown memakai jam server (clock skew)', () {
      final server = DateTime.utc(2026, 10, 2, 8);
      final local = server.subtract(const Duration(minutes: 3));
      final c = ActAsContext.fromJson(_ctx(now: server), receivedAt: local);
      expect(c.clockSkew, const Duration(minutes: 3));
      expect(c.remaining(local), const Duration(minutes: 15));
      expect(c.remaining(local.add(const Duration(minutes: 20))), Duration.zero);
    });

    test('perpanjang otomatis hanya saat sisa < 5 menit dan belum batas 2 jam', () {
      final n = DateTime.utc(2026, 10, 2, 8);
      final fresh = ActAsContext.fromJson(_ctx(now: n), receivedAt: n);
      expect(fresh.shouldAutoExtend(n), isFalse);
      expect(fresh.shouldAutoExtend(n.add(const Duration(minutes: 11))), isTrue);
      final capped = ActAsContext.fromJson(_ctx(now: n, left: const Duration(minutes: 4), hard: const Duration(minutes: 4)), receivedAt: n);
      expect(capped.canExtend, isFalse);
      expect(capped.shouldAutoExtend(n), isFalse);
    });

    test('formatCountdown', () {
      expect(formatCountdown(const Duration(minutes: 14, seconds: 5)), '14:05');
      expect(formatCountdown(Duration.zero), '00:00');
    });
  });

  group('SessionState saat Act As', () {
    test('tanpa Act As: real* = identitas sendiri', () {
      final s = SessionState.fromJson({..._session(canActAs: true), 'real_user_id': null, 'real_email': null});
      expect(s.isActingAs, isFalse);
      expect(s.realUserId, 'root');
      expect(s.realEmail, 'ade@weatherford.com');
      expect(s.canActAs, isTrue);
    });

    test('dengan Act As: identitas efektif & identitas nyata terpisah', () {
      final s = SessionState.fromJson(_session(actAs: _ctx(), canActAs: true));
      expect(s.isActingAs, isTrue);
      expect(s.email, 'budi@eji.co.id');
      expect(s.realEmail, 'ade@weatherford.com');
      expect(s.realIsRootAdmin, isTrue);
      expect(s.actAs!.title, 'Budi PIC');
    });
  });

  group('RouteRules saat Act As', () {
    bool allowed(SessionState s, String path) => RouteRules.match(path)?.allows(s) ?? false;

    test('pengaturan personal tertutup, halaman target terbuka', () {
      final acting = SessionState.fromJson(_session(actAs: _ctx()));
      for (final p in ['/settings/profile', '/settings/security', '/settings/devices', '/settings/notifications']) {
        expect(allowed(acting, p), isFalse, reason: p);
      }
      final normal = SessionState.fromJson(_session());
      expect(allowed(normal, '/settings/profile'), isTrue);
    });

    test('Admin Console tertutup karena izin admin tidak ikut', () {
      final acting = SessionState.fromJson(_session(actAs: _ctx()));
      expect(acting.hasAdminPerm, isFalse);
      expect(allowed(acting, '/admin/users'), isFalse);
    });
  });
}
