import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/step_up_dialog.dart';
import '../errors/app_failure.dart';
import 'session_controller.dart';

void showSnack(BuildContext context, String message, {bool error = false, SnackBarAction? action}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    action: action,
  ));
}

/// Reaksi UI terpusat atas hint (tabel 16.7).
Future<void> handleFailure(BuildContext context, WidgetRef ref, Object error) async {
  final f = AppFailure.from(error);
  final session = ref.read(sessionProvider.notifier);
  switch (f.hint) {
    case Hint.unauthenticated:
    case Hint.reauthRequired:
    case Hint.loginMethodDisabled:
    case Hint.deviceRevoked:
    case Hint.deviceMissing:
    case Hint.deviceUnregistered:
    case Hint.deviceMismatch:
    case Hint.accountInactive:
      await session.handle(f);
    case Hint.mfaRequired:
      if (context.mounted) context.go('/mfa/verify?next=${Uri.encodeComponent(GoRouterState.of(context).uri.toString())}');
    case Hint.readOnly:
      if (context.mounted) showSnack(context, 'Sistem sedang read-only. Perubahan dinonaktifkan.', error: true);
      await session.refresh();
    case Hint.rateLimited:
      if (context.mounted) showSnack(context, 'Terlalu banyak permintaan, coba sebentar lagi.', error: true);
    case Hint.forbidden:
      if (context.mounted) showSnack(context, f.message.isEmpty ? 'Akses ditolak' : f.message, error: true);
    case Hint.validation:
    case Hint.duplicateTaxId:
      if (context.mounted) showSnack(context, f.message, error: true);
    case Hint.captchaRequired:
      if (context.mounted) showSnack(context, 'Verifikasi manusia diperlukan. Selesaikan captcha lalu coba lagi.', error: true);
    case Hint.stepUpRequired:
      if (context.mounted) showSnack(context, 'Verifikasi MFA diperlukan untuk aksi ini.', error: true);
    case Hint.actAsBlocked:
      if (context.mounted) showSnack(context, f.message, error: true);
    case Hint.actAsEnded:
      if (context.mounted) showSnack(context, 'Sesi Act As berakhir: ${f.message}', error: true);
      await session.handle(f);
    case Hint.network:
    case Hint.unknown:
      if (context.mounted) showSnack(context, f.message, error: true);
  }
}

/// Jalankan aksi tulis: step-up otomatis (ulang sekali setelah TOTP), error → [handleFailure], sukses → snackbar.
Future<T?> runAction<T>(
  BuildContext context,
  WidgetRef ref,
  Future<T> Function() action, {
  String? success,
}) async {
  try {
    final r = await withStepUp(context, action);
    if (success != null && context.mounted) showSnack(context, success);
    return r;
  } catch (e) {
    if (context.mounted) await handleFailure(context, ref, e);
    return null;
  }
}

Future<T> withStepUp<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } on AppFailure catch (f) {
    if (f.hint != Hint.stepUpRequired || !context.mounted) rethrow;
    final ok = await showDialog<bool>(context: context, builder: (_) => const StepUpDialog());
    if (ok != true) rethrow;
    return await action();
  }
}
