// lib/core/errors/app_failure.dart
import 'package:supabase_flutter/supabase_flutter.dart';

enum Hint {
  unauthenticated, accountInactive, deviceMissing, deviceUnregistered, deviceRevoked, deviceMismatch,
  reauthRequired, mfaRequired, stepUpRequired, forbidden, readOnly, rateLimited, duplicateTaxId,
  captchaRequired, loginMethodDisabled, validation, network, unknown,
}

const _hintMap = <String, Hint>{
  'unauthenticated': Hint.unauthenticated, 'account_inactive': Hint.accountInactive,
  'device_missing': Hint.deviceMissing, 'device_unregistered': Hint.deviceUnregistered,
  'device_revoked': Hint.deviceRevoked, 'device_mismatch': Hint.deviceMismatch,
  'reauth_required': Hint.reauthRequired, 'mfa_required': Hint.mfaRequired, 'step_up_required': Hint.stepUpRequired,
  'forbidden': Hint.forbidden, 'read_only': Hint.readOnly, 'rate_limited': Hint.rateLimited,
  'duplicate_tax_id': Hint.duplicateTaxId, 'captcha_required': Hint.captchaRequired,
  'login_method_disabled': Hint.loginMethodDisabled,
  'insufficient_level': Hint.forbidden, 'use_moc': Hint.forbidden,
};

class AppFailure implements Exception {
  const AppFailure(this.hint, this.message, {this.code});
  final Hint hint;
  final String message;
  final String? code;

  factory AppFailure.from(Object e) {
    if (e is AppFailure) return e;
    if (e is PostgrestException) {
      final h = _hintMap[e.hint ?? ''];
      if (h != null) return AppFailure(h, e.message, code: e.code);
      if (e.code == 'PT429') return AppFailure(Hint.rateLimited, e.message, code: e.code);
      if (e.code == '22023' || e.code == '23514') return AppFailure(Hint.validation, e.message, code: e.code);
      if (e.code == '23505') {
        final generic = e.message.startsWith('duplicate key');
        return AppFailure(Hint.validation, generic ? 'Data yang sama sudah ada.' : e.message, code: e.code);
      }
      if (e.code == '42501') return AppFailure(Hint.forbidden, 'Akses ditolak', code: e.code);
      return AppFailure(Hint.unknown, 'Terjadi kesalahan. Coba lagi.', code: e.code);
    }
    if (e is FunctionException) {
      final err = (e.details is Map) ? (e.details as Map)['error'] as Map? : null;
      final h = _hintMap[err?['hint'] ?? ''] ?? (e.status == 429 ? Hint.rateLimited : e.status == 400 ? Hint.validation : Hint.unknown);
      return AppFailure(h, (err?['message'] as String?) ?? 'Terjadi kesalahan', code: err?['code'] as String?);
    }
    if (e is AuthException) {
      return AppFailure(e.statusCode == '401' ? Hint.unauthenticated : Hint.unknown, e.message, code: e.code);
    }
    return const AppFailure(Hint.network, 'Koneksi bermasalah. Periksa internet Anda.');
  }
}

Future<T> guard<T>(Future<T> Function() call) async {
  try { return await call(); } catch (e) { throw AppFailure.from(e); }
}
