import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'core/env.dart';
import 'core/security/device_identity.dart';
import 'core/security/encrypted_storage.dart';
import 'core/security/secure_store.dart';
import 'core/session/act_as.dart';
import 'core/session/session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  Env.assertValid();
  await initializeDateFormatting('id');

  const store = SecureStore();
  await store.ready();
  final device = await DeviceIdentity.load(store);
  final sessionStorage = EncryptedSessionStorage(store);
  final actAsToken = await store.read(ActAsRuntime.storeKey);
  if (ActAsRuntime.isValidToken(actAsToken)) ActAsRuntime.token = actAsToken;

  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabaseAnonKey,
    headers: {'x-device-id': device.hash},              // dikirim ke PostgREST, Edge Functions & Realtime REST
    httpClient: ActAsHttpClient(host: Uri.parse(Env.supabaseUrl).host),
    authOptions: FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
      localStorage: sessionStorage,
      pkceAsyncStorage: EncryptedAsyncStorage(store),
      detectSessionInUri: true,
      autoRefreshToken: true,
    ),
  );
  store.onSession(() => sessionStorage.adoptFromOtherTab(Supabase.instance.client.auth));

  final container = ProviderContainer(overrides: [
    secureStoreProvider.overrideWithValue(store),
    deviceIdentityProvider.overrideWithValue(device),
  ]);

  Future<void> run() async => runApp(UncontrolledProviderScope(container: container, child: const ComenApp()));

  if (Env.sentryDsn.isEmpty) return run();
  await SentryFlutter.init((o) {
    o.dsn = Env.sentryDsn;
    o.environment = Env.environment;
    o.sendDefaultPii = false;
    o.tracesSampleRate = 0.0;
    o.beforeSend = (event, hint) => event.copyWith(user: null, request: null, breadcrumbs: const []);
  }, appRunner: run);
}
