import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/errors/app_failure.dart';
import '../../core/session/session_controller.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../status/status_pages.dart';
import 'auth_gateway.dart';

class MfaEnrollPage extends ConsumerStatefulWidget {
  const MfaEnrollPage({super.key});
  @override
  ConsumerState<MfaEnrollPage> createState() => _MfaEnrollPageState();
}

class _MfaEnrollPageState extends ConsumerState<MfaEnrollPage> {
  AuthMFAEnrollResponse? _enroll;
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sb = Supabase.instance.client;
      final factors = await sb.auth.mfa.listFactors();
      for (final f in factors.all.where((f) => f.status == FactorStatus.unverified)) {
        await sb.auth.mfa.unenroll(f.id);
      }
      final r = await ref.read(authGatewayProvider).enrollTotp(name: 'Authenticator ${DateTime.now().millisecondsSinceEpoch % 10000}');
      setState(() => _enroll = r);
    } catch (e) {
      setState(() => _error = AppFailure.from(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authGatewayProvider).verifyEnrollment(_enroll!.id, _code.text);
      await ref.read(sessionProvider.notifier).refresh();
    } catch (e) {
      setState(() => _error = AppFailure.from(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final totp = _enroll?.totp;
    return BrandBackdrop(
      maxWidth: 520,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.verified_user_rounded, color: Brand.blue),
          const SizedBox(width: 10),
          Text('Aktifkan MFA (TOTP)', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),
        Text('COMEN mewajibkan autentikasi dua faktor untuk semua pengguna. Pindai QR dengan Google Authenticator, Microsoft Authenticator, 1Password, atau aplikasi TOTP lain.',
            style: t.bodyMedium),
        const SizedBox(height: 20),
        if (_error != null) ...[InfoBanner(message: _error!, color: Brand.red), const SizedBox(height: 12)],
        if (totp == null)
          _busy ? const LoadingView() : FilledButton(onPressed: _start, child: const Text('Mulai ulang'))
        else ...[
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE4E7EC))),
              child: QrImageView(data: totp.uri, size: 200, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(height: 12),
          Text('Atau masukkan kunci manual:', style: t.bodySmall, textAlign: TextAlign.center),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Flexible(child: MonoText(totp.secret, size: 12)),
            CopyButton(totp.secret),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 26, letterSpacing: 10, fontWeight: FontWeight.w800),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(counterText: '', labelText: 'Kode 6 digit'),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _busy || _code.text.trim().length != 6 ? null : _verify, child: const Text('Verifikasi & aktifkan')),
          const SizedBox(height: 12),
          const InfoBanner(
            message: 'Setelah aktif, daftarkan authenticator CADANGAN di Pengaturan → Keamanan (Supabase tidak menyediakan recovery code).',
            color: Brand.amber,
            icon: Icons.key_rounded,
          ),
        ],
      ]),
    );
  }
}

class MfaVerifyPage extends ConsumerStatefulWidget {
  const MfaVerifyPage({super.key});
  @override
  ConsumerState<MfaVerifyPage> createState() => _MfaVerifyPageState();
}

class _MfaVerifyPageState extends ConsumerState<MfaVerifyPage> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authGatewayProvider).verifyTotp(_code.text);
      await ref.read(sessionProvider.notifier).refresh();
    } catch (e) {
      setState(() => _error = AppFailure.from(e).message);
      _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return BrandBackdrop(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_clock_rounded, size: 44, color: Brand.blue),
        const SizedBox(height: 12),
        Text('Verifikasi dua langkah', textAlign: TextAlign.center, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('Masukkan kode dari aplikasi authenticator Anda.', textAlign: TextAlign.center, style: t.bodyMedium),
        const SizedBox(height: 20),
        if (_error != null) ...[InfoBanner(message: _error!, color: Brand.red), const SizedBox(height: 12)],
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 28, letterSpacing: 12, fontWeight: FontWeight.w800),
          onChanged: (v) {
            setState(() {});
            if (v.trim().length == 6 && !_busy) _verify();
          },
          decoration: const InputDecoration(counterText: '', hintText: '••••••'),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _busy || _code.text.trim().length != 6 ? null : _verify, child: const Text('Verifikasi')),
        TextButton(onPressed: () => ref.read(sessionProvider.notifier).signOutLocal(), child: const Text('Masuk dengan akun lain')),
      ]),
    );
  }
}
