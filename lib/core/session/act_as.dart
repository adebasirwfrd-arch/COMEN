// lib/core/session/act_as.dart — Act As Mode (Blueprint addition 2, R37–R45)
import 'package:http/http.dart' as http;
import 'contract_classification.dart';

/// Status Act As tingkat proses: token (dibaca [ActAsHttpClient] di setiap request) dan identitas efektif.
abstract final class ActAsRuntime {
  static const storeKey = 'comen_act_as';
  static const header = 'x-comen-act-as';
  static final _tokenRe = RegExp(r'^[A-Za-z0-9_-]{43}$');

  static String? token;

  /// User ID efektif saat Act As mode user (null = sama dengan user login).
  static String? effectiveUserId;

  static bool isValidToken(String? t) => t != null && _tokenRe.hasMatch(t);
}

/// Menyuntikkan header Act As hanya ke PostgREST & Edge Functions host Supabase sendiri.
/// Auth & Storage tidak menerimanya; Realtime WebSocket tidak lewat HTTP client ini (tetap identitas nyata).
class ActAsHttpClient extends http.BaseClient {
  ActAsHttpClient({required this.host, http.Client? inner}) : _inner = inner ?? http.Client();
  final String host;
  final http.Client _inner;

  bool appliesTo(Uri url) =>
      url.host == host && (url.path.startsWith('/rest/v1/') || url.path.startsWith('/functions/v1/'));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final t = ActAsRuntime.token;
    if (t != null && appliesTo(request.url)) request.headers[ActAsRuntime.header] = t;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

enum ActAsKind { user, role }

class ActAsContext {
  ActAsContext.fromJson(Map<String, dynamic> j, {DateTime? receivedAt})
      : id = j['id'] as String,
        kind = j['kind'] == 'role' ? ActAsKind.role : ActAsKind.user,
        targetUserId = j['target_user_id'] as String?,
        targetName = j['target_name'] as String?,
        targetEmail = j['target_email'] as String?,
        contractorId = j['contractor_id'] as String?,
        contractorName = j['contractor_name'] as String?,
        level = ContractorUserLevel.tryCode(j['level'] as String?),
        roleKey = j['role_key'] as String?,
        roleName = j['role_name'] as String?,
        reason = (j['reason'] as String?) ?? '',
        startedAt = DateTime.parse(j['started_at'] as String),
        expiresAt = DateTime.parse(j['expires_at'] as String),
        hardExpiresAt = DateTime.parse(j['hard_expires_at'] as String),
        clockSkew = j['server_now'] == null
            ? Duration.zero
            : DateTime.parse(j['server_now'] as String).difference(receivedAt ?? DateTime.now());

  final String id;
  final ActAsKind kind;
  final String? targetUserId, targetName, targetEmail, contractorId, contractorName, roleKey, roleName;
  final ContractorUserLevel? level;
  final String reason;
  final DateTime startedAt, expiresAt, hardExpiresAt;

  /// Jam server − jam lokal saat diterima; countdown memakai jam server.
  final Duration clockSkew;

  bool get isUser => kind == ActAsKind.user;

  String get title => isUser ? (targetName ?? targetEmail ?? 'User') : (roleName ?? roleKey ?? 'Role');

  String get subtitle => isUser
      ? [contractorName ?? 'Weatherford', if (level != null) level!.label].join(' · ')
      : 'Template role WFRD (scope global)';

  Duration remaining([DateTime? now]) {
    final r = expiresAt.difference((now ?? DateTime.now()).add(clockSkew));
    return r.isNegative ? Duration.zero : r;
  }

  /// Masih bisa diperpanjang (belum menyentuh batas 2 jam).
  bool get canExtend => expiresAt.isBefore(hardExpiresAt);

  /// Diperpanjang otomatis hanya saat user berinteraksi dan sisa waktu < 5 menit.
  bool shouldAutoExtend([DateTime? now]) => canExtend && remaining(now) < const Duration(minutes: 5);
}

String formatCountdown(Duration d) {
  final m = d.inMinutes, s = d.inSeconds % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
