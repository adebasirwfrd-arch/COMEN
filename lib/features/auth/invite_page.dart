import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../ui/theme.dart';
import '../status/status_pages.dart';

/// Undangan dicocokkan via email terverifikasi saat login (C5) — halaman ini hanya informasi.
class InvitePage extends StatelessWidget {
  const InvitePage({super.key, this.email});
  final String? email;

  @override
  Widget build(BuildContext context) => BrandBackdrop(
        child: StatusMessage(
          icon: Icons.mark_email_read_rounded,
          color: Brand.blue,
          title: 'Anda diundang ke COMEN',
          message: email == null
              ? 'Masuk dengan Google atau kode email menggunakan alamat email yang diundang. Akun akan langsung aktif.'
              : 'Masuk dengan Google atau kode email menggunakan $email. Akun akan langsung aktif dengan akses sesuai undangan.',
          actions: [FilledButton.icon(onPressed: () => context.go('/login'), icon: const Icon(Icons.login_rounded), label: const Text('Masuk sekarang'))],
        ),
      );
}
