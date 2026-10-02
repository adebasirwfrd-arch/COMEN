// lib/core/env.dart — SEMUA nilai compile-time (const) → tree-shaking dijamin
abstract final class Env {
  static const supabaseUrl     = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const appOrigin       = String.fromEnvironment('APP_ORIGIN', defaultValue: 'http://localhost:3000');
  static const turnstileSiteKey = String.fromEnvironment('TURNSTILE_SITE_KEY', defaultValue: '1x00000000000000000000AA');
  static const vapidPublicKey  = String.fromEnvironment('VAPID_PUBLIC_KEY');
  static const sentryDsn       = String.fromEnvironment('SENTRY_DSN');
  static const environment     = String.fromEnvironment('COMEN_ENV', defaultValue: 'local');
  static const mockAuth        = bool.fromEnvironment('COMEN_MOCK_AUTH');   // CI: wajib false di staging/prod

  static void assertValid() {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) throw StateError('SUPABASE_URL / SUPABASE_ANON_KEY kosong');
    if (environment != 'local' && mockAuth) throw StateError('Mock auth dilarang di $environment');
  }
}
