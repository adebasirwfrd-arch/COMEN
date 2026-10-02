import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/errors/app_failure.dart';
import '../../core/session/session_controller.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Latar halaman status/auth: gradien navy + kartu tengah.
class BrandBackdrop extends StatelessWidget {
  const BrandBackdrop({super.key, required this.child, this.maxWidth = 480});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Brand.navyDeep, Brand.navy, Color(0xFF0B3A8C)],
          ),
        ),
        child: Stack(children: [
          Positioned(
            top: -120,
            right: -80,
            child: Container(
              width: 380,
              height: 380,
              decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Brand.cyan.withValues(alpha: 0.35), Colors.transparent])),
            ),
          ),
          Positioned(
            bottom: -140,
            left: -100,
            child: Container(
              width: 420,
              height: 420,
              decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Brand.blue.withValues(alpha: 0.35), Colors.transparent])),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const _Logo(),
                  const SizedBox(height: 28),
                  Card(
                    elevation: 12,
                    shadowColor: Colors.black45,
                    child: Padding(padding: const EdgeInsets.all(32), child: child),
                  ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.06, end: 0, curve: Curves.easeOutCubic),
                  const SizedBox(height: 20),
                  const Text('© Weatherford · COMEN v3.2 · Zero-file-storage · AES-256',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            gradient: Brand.heroGradient,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Brand.cyan.withValues(alpha: 0.4), blurRadius: 24)],
          ),
          child: const Icon(Icons.shield_moon_rounded, color: Colors.white, size: 30),
        ),
        const SizedBox(width: 14),
        const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('COMEN', style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 2)),
          Text('Contractor Management · WFRD', style: TextStyle(color: Colors.white70, fontSize: 13)),
        ]),
      ]);
}

class StatusMessage extends StatelessWidget {
  const StatusMessage({super.key, required this.icon, required this.color, required this.title, this.message, this.actions = const []});
  final IconData icon;
  final Color color;
  final String title;
  final String? message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
        child: Icon(icon, size: 38, color: color),
      ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
      const SizedBox(height: 20),
      Text(title, textAlign: TextAlign.center, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      if (message != null) ...[
        const SizedBox(height: 10),
        Text(message!, textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
      if (actions.isNotEmpty) ...[const SizedBox(height: 24), ...actions.map((a) => Padding(padding: const EdgeInsets.only(top: 8), child: SizedBox(width: double.infinity, child: a)))],
    ]);
  }
}

class SplashPage extends ConsumerWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    if (s is SessionError) {
      return BrandBackdrop(
        child: StatusMessage(
          icon: Icons.cloud_off_rounded,
          color: Brand.red,
          title: 'Tidak dapat memulai sesi',
          message: s.failure.hint == Hint.network ? 'Koneksi bermasalah. Periksa internet Anda.' : s.failure.message,
          actions: [
            FilledButton.icon(
              onPressed: () => ref.read(sessionProvider.notifier).bootstrap(force: true),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Coba lagi'),
            ),
            OutlinedButton(onPressed: () => ref.read(sessionProvider.notifier).signOutLocal(), child: const Text('Masuk dengan akun lain')),
          ],
        ),
      );
    }
    return const BrandBackdrop(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
        SizedBox(height: 20),
        Text('Memverifikasi perangkat & sesi…', style: TextStyle(fontWeight: FontWeight.w600)),
        SizedBox(height: 6),
        Text('Device binding · AES-256-GCM · Zero Trust', style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}

class PendingPage extends ConsumerWidget {
  const PendingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final st = s is SessionReady ? s.s : null;
    final submitted = st?.registrationSubmitted == true;
    return BrandBackdrop(
      child: StatusMessage(
        icon: Icons.hourglass_top_rounded,
        color: Brand.amber,
        title: 'Akun Anda menunggu persetujuan Admin',
        message: submitted
            ? 'Registrasi perusahaan ${st?.contractorName ?? ''} sudah dikirim (status: ${st?.vendorStatus ?? '-'}). '
                'Anda akan otomatis masuk begitu Admin menyetujui akun.'
            : 'Jika Anda mewakili perusahaan contractor, lengkapi registrasi perusahaan agar Admin dapat memproses akun Anda.',
        actions: [
          if (!submitted)
            FilledButton.icon(onPressed: () => context.go('/register'), icon: const Icon(Icons.apartment_rounded), label: const Text('Lengkapi registrasi perusahaan')),
          OutlinedButton.icon(
            onPressed: () => ref.read(sessionProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Periksa status'),
          ),
          TextButton(onPressed: () => context.go('/settings/devices'), child: const Text('Perangkat saya / keluar')),
        ],
      ),
    );
  }
}

class SuspendedPage extends ConsumerWidget {
  const SuspendedPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final reason = s is SessionReady ? s.s.statusReason : null;
    return BrandBackdrop(
      child: StatusMessage(
        icon: Icons.block_rounded,
        color: Brand.red,
        title: 'Akun ditangguhkan',
        message: '${reason == null ? '' : 'Alasan: $reason. '}Hubungi admin COMEN untuk informasi lebih lanjut.',
        actions: [OutlinedButton(onPressed: () => ref.read(sessionProvider.notifier).refresh(), child: const Text('Periksa ulang'))],
      ),
    );
  }
}

class AccountClosedPage extends ConsumerWidget {
  const AccountClosedPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final reason = s is SessionReady ? s.s.statusReason : null;
    return BrandBackdrop(
      child: StatusMessage(
        icon: Icons.person_off_rounded,
        color: Brand.grey,
        title: 'Akun ditutup / ditolak',
        message: reason == null ? 'Akun ini tidak lagi aktif.' : 'Alasan: $reason',
        actions: [OutlinedButton(onPressed: () => ref.read(sessionProvider.notifier).signOutLocal(), child: const Text('Keluar'))],
      ),
    );
  }
}

class DeviceRevokedPage extends ConsumerWidget {
  const DeviceRevokedPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => BrandBackdrop(
        child: StatusMessage(
          icon: Icons.phonelink_erase_rounded,
          color: Brand.red,
          title: 'Perangkat ini dicabut',
          message: 'Akses dari perangkat ini telah dicabut oleh Anda atau Admin. Untuk melanjutkan, masuk ulang — perangkat akan didaftarkan dengan identitas baru.',
          actions: [
            FilledButton.icon(
              onPressed: () => ref.read(sessionProvider.notifier).resetDeviceAndSignOut(),
              icon: const Icon(Icons.login_rounded),
              label: const Text('Masuk ulang di perangkat ini'),
            ),
          ],
        ),
      );
}

class ForbiddenPage extends StatelessWidget {
  const ForbiddenPage({super.key});
  @override
  Widget build(BuildContext context) => BrandBackdrop(
        child: StatusMessage(
          icon: Icons.lock_outline_rounded,
          color: Brand.amber,
          title: '403 · Akses ditolak',
          message: 'Anda tidak memiliki izin untuk membuka halaman ini.',
          actions: [FilledButton(onPressed: () => context.go('/dashboard'), child: const Text('Kembali ke Dashboard'))],
        ),
      );
}

class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});
  @override
  Widget build(BuildContext context) => BrandBackdrop(
        child: StatusMessage(
          icon: Icons.travel_explore_rounded,
          color: Brand.blue,
          title: '404 · Halaman tidak ditemukan',
          message: 'Tautan mungkin salah atau data sudah tidak tersedia.',
          actions: [FilledButton(onPressed: () => context.go('/dashboard'), child: const Text('Kembali ke Dashboard'))],
        ),
      );
}

/// Konten bawaan bila sebuah halaman dibuka tanpa sesi siap (seharusnya dicegah gate()).
Widget sessionGuardFallback() => const LoadingView();
