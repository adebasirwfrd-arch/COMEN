import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../ui/theme.dart';
import '../status/status_pages.dart';

/// Penyelesaian OAuth PKCE: supabase_flutter menukar ?code= otomatis → SessionController (signedIn) → gate() → takeNext().
class AuthCallbackPage extends StatelessWidget {
  const AuthCallbackPage({super.key, this.error});
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return BrandBackdrop(
        child: StatusMessage(
          icon: Icons.error_outline_rounded,
          color: Brand.red,
          title: 'Login gagal',
          message: error,
          actions: [FilledButton(onPressed: () => context.go('/login'), child: const Text('Kembali ke login'))],
        ),
      );
    }
    return const BrandBackdrop(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
        SizedBox(height: 20),
        Text('Menyelesaikan login…', style: TextStyle(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
