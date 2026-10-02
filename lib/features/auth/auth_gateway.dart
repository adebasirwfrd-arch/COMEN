import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/env.dart';
import '../../core/errors/app_failure.dart';
import '../../core/router/gate.dart';

final authGatewayProvider = Provider<AuthGateway>((_) => AuthGateway(Supabase.instance.client));

class AuthGateway {
  AuthGateway(this._sb);
  final SupabaseClient _sb;

  Future<void> google({String? next}) async {
    rememberNext(next);
    await _sb.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: '${Env.appOrigin}/auth/callback',
      queryParams: const {'prompt': 'select_account'},
      authScreenLaunchMode: LaunchMode.platformDefault,          // redirect di tab yang sama
    );
  }

  Future<void> sendOtp(String email, String captchaToken) => guard(() =>
      _sb.auth.signInWithOtp(email: email.trim().toLowerCase(), shouldCreateUser: true, captchaToken: captchaToken));

  Future<void> verifyOtp(String email, String code) => guard(() =>
      _sb.auth.verifyOTP(type: OtpType.email, email: email.trim().toLowerCase(), token: code.trim()));

  /// Hanya ada di build lokal: const false → seluruh cabang dihapus tree-shaker (C12)
  Future<void> mockSignIn(String email, String password) async {
    if (!Env.mockAuth) throw StateError('disabled');
    await guard(() => _sb.auth.signInWithPassword(email: email, password: password));
  }

  // ── MFA TOTP ──
  Future<AuthMFAEnrollResponse> enrollTotp({String name = 'Authenticator'}) => guard(() =>
      _sb.auth.mfa.enroll(factorType: FactorType.totp, issuer: 'COMEN', friendlyName: name));

  Future<void> verifyEnrollment(String factorId, String code) => guard(() =>
      _sb.auth.mfa.challengeAndVerify(factorId: factorId, code: code.trim()));

  /// Login aal1 → aal2, dan step-up (memperbarui klaim amr totp → mfa_fresh)
  Future<void> verifyTotp(String code) => guard(() async {
    final factors = await _sb.auth.mfa.listFactors();
    final f = factors.totp.firstWhere((x) => x.status == FactorStatus.verified,
        orElse: () => throw const AppFailure(Hint.mfaRequired, 'Belum ada authenticator terdaftar'));
    await _sb.auth.mfa.challengeAndVerify(factorId: f.id, code: code.trim());
  });
}
