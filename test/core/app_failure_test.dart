import 'package:comen/core/errors/app_failure.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('AppFailure.from (16.7)', () {
    test('semua hint server terpetakan', () {
      const m = {
        'unauthenticated': Hint.unauthenticated,
        'account_inactive': Hint.accountInactive,
        'device_missing': Hint.deviceMissing,
        'device_unregistered': Hint.deviceUnregistered,
        'device_revoked': Hint.deviceRevoked,
        'device_mismatch': Hint.deviceMismatch,
        'reauth_required': Hint.reauthRequired,
        'mfa_required': Hint.mfaRequired,
        'step_up_required': Hint.stepUpRequired,
        'forbidden': Hint.forbidden,
        'read_only': Hint.readOnly,
        'rate_limited': Hint.rateLimited,
        'duplicate_tax_id': Hint.duplicateTaxId,
        'captcha_required': Hint.captchaRequired,
        'login_method_disabled': Hint.loginMethodDisabled,
      };
      m.forEach((hint, expected) {
        final f = AppFailure.from(PostgrestException(message: 'x', code: '42501', hint: hint));
        expect(f.hint, expected, reason: hint);
      });
    });

    test('kode SQLSTATE', () {
      expect(AppFailure.from(const PostgrestException(message: 'x', code: 'PT429')).hint, Hint.rateLimited);
      expect(AppFailure.from(const PostgrestException(message: 'Nama file salah', code: '22023')).hint, Hint.validation);
      expect(AppFailure.from(const PostgrestException(message: 'Nama file salah', code: '22023')).message, 'Nama file salah');
      expect(AppFailure.from(const PostgrestException(message: 'x', code: '42501')).hint, Hint.forbidden);
      expect(AppFailure.from(const PostgrestException(message: 'x', code: 'XX000')).hint, Hint.unknown);
    });

    test('FunctionException body Edge terurai', () {
      final f = AppFailure.from(FunctionException(status: 400, details: {
        'error': {'code': 'captcha_failed', 'message': 'Captcha gagal', 'hint': 'captcha_required'},
      }));
      expect(f.hint, Hint.captchaRequired);
      expect(f.message, 'Captcha gagal');
      expect(f.code, 'captcha_failed');
      expect(AppFailure.from(const FunctionException(status: 429)).hint, Hint.rateLimited);
    });

    test('error lain → network', () {
      expect(AppFailure.from(Exception('socket')).hint, Hint.network);
      const same = AppFailure(Hint.forbidden, 'x');
      expect(identical(AppFailure.from(same), same), isTrue);
    });
  });
}
