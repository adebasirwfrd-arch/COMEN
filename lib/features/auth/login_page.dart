import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/env.dart';
import '../../core/errors/app_failure.dart';
import '../../core/router/gate.dart';
import '../../ui/theme.dart';
import '../../ui/turnstile_box.dart';
import '../../ui/widgets.dart';
import '../status/status_pages.dart';
import 'auth_gateway.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key, this.reason, this.next});
  final String? reason;
  final String? next;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

enum _Mode { choose, email, code }

class _LoginPageState extends ConsumerState<LoginPage> {
  _Mode _mode = _Mode.choose;
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _turnstile = GlobalKey<TurnstileBoxState>();
  String? _captcha;
  bool _busy = false;
  String? _error;

  AuthGateway get _auth => ref.read(authGatewayProvider);

  @override
  void initState() {
    super.initState();
    rememberNext(widget.next);
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      final fl = AppFailure.from(e);
      setState(() => _error = fl.message);
      if (fl.hint == Hint.captchaRequired || _mode == _Mode.email) {
        _turnstile.currentState?.reset();
        _captcha = null;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _emailValid => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim());

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final otpDisabled = widget.reason == 'otp_disabled';
    final reasonMsg = switch (widget.reason) {
      'reauth' => 'Sesi berakhir, silakan masuk lagi.',
      'otp_disabled' => 'Login via email dinonaktifkan Admin, gunakan Google.',
      'auth_error' => 'Login sebelumnya gagal atau link login sudah kedaluwarsa. Silakan masuk lagi.',
      'account_disabled' => 'Akun ini sudah dinonaktifkan Admin dan tidak bisa dipakai untuk masuk. Hubungi admin WFRD bila ini keliru.',
      _ => null,
    };
    return BrandBackdrop(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Selamat datang', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('Masuk untuk mengelola dokumen, task, dan kontrak contractor WFRD.',
            style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 24),
        if (reasonMsg != null) ...[InfoBanner(message: reasonMsg, color: Brand.amber, icon: Icons.info_outline), const SizedBox(height: 16)],
        if (_error != null) ...[InfoBanner(message: _error!, color: Brand.red, icon: Icons.error_outline), const SizedBox(height: 16)],
        if (_mode == _Mode.choose) ...[
          FilledButton.icon(
            onPressed: _busy ? null : () => _run(() => _auth.google(next: widget.next)),
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black87, side: const BorderSide(color: Color(0xFFDADCE0))),
            icon: const _GoogleG(),
            label: const Text('Masuk dengan Google'),
          ),
          const SizedBox(height: 12),
          if (!otpDisabled)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => setState(() => _mode = _Mode.email),
              icon: const Icon(Icons.mail_outline_rounded),
              label: const Text('Masuk via email (kode OTP)'),
            ),
          const SizedBox(height: 20),
          Row(children: [
            const Icon(Icons.verified_user_outlined, size: 16, color: Brand.green),
            const SizedBox(width: 8),
            Expanded(child: Text('Akun baru menunggu persetujuan Admin. Perangkat Anda didaftarkan & bisa dicabut kapan saja.', style: t.bodySmall)),
          ]),
          if (Env.mockAuth) ...[const SizedBox(height: 24), const MockLoginCard()],
        ],
        if (_mode == _Mode.email) ...[
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Email kerja', prefixIcon: Icon(Icons.alternate_email_rounded)),
          ),
          const SizedBox(height: 16),
          TurnstileBox(key: _turnstile, action: 'otp', onToken: (tok) => setState(() => _captcha = tok)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || !_emailValid || _captcha == null
                ? null
                : () => _run(() async {
                      await _auth.sendOtp(_email.text, _captcha!);
                      _captcha = null;
                      setState(() => _mode = _Mode.code);
                    }),
            child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Kirim kode'),
          ),
          TextButton(onPressed: () => setState(() => _mode = _Mode.choose), child: const Text('Kembali')),
        ],
        if (_mode == _Mode.code) ...[
          Text('Kode 6 digit telah dikirim ke ${_email.text.trim()}', style: t.bodyMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(fontSize: 28, letterSpacing: 12, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(counterText: '', hintText: '••••••'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || _code.text.trim().length != 6 ? null : () => _run(() => _auth.verifyOtp(_email.text, _code.text)),
            child: const Text('Verifikasi & masuk'),
          ),
          TextButton(onPressed: () => setState(() => _mode = _Mode.email), child: const Text('Kirim ulang kode')),
        ],
      ]),
    );
  }
}

class _GoogleG extends StatelessWidget {
  const _GoogleG();
  @override
  Widget build(BuildContext context) => Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        child: const Text('G', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: Color(0xFF4285F4))),
      );
}

/// Hanya di-render bila Env.mockAuth (const) — seluruh widget dihapus tree-shaker di build production (C12).
class MockLoginCard extends ConsumerStatefulWidget {
  const MockLoginCard({super.key});
  @override
  ConsumerState<MockLoginCard> createState() => _MockLoginCardState();
}

class _MockLoginCardState extends ConsumerState<MockLoginCard> {
  static const marker = 'COMEN_MOCK_AUTH_ENABLED';
  static const accounts = [
    'ade.basirwfrd@gmail.com', 'hse.admin@dev.local', 'reviewer@dev.local', 'po@dev.local',
    'procurement@dev.local', 'director@dev.local', 'rep@maju.dev.local', 'viewer@maju.dev.local',
  ];
  String _email = accounts.first;
  final _pw = TextEditingController(text: 'DevOnly!2026');
  String? _err;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Brand.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.amber.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          Icon(Icons.bug_report_outlined, color: Brand.amber, size: 18),
          SizedBox(width: 8),
          Text('Mock Login (lokal saja)', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        const Text(marker, style: TextStyle(fontSize: 9, color: Colors.transparent)),
        DropdownButtonFormField<String>(
          initialValue: _email,
          isExpanded: true,
          items: [for (final a in accounts) DropdownMenuItem(value: a, child: Text(a))],
          onChanged: (v) => setState(() => _email = v ?? _email),
          decoration: const InputDecoration(labelText: 'Akun seed'),
        ),
        const SizedBox(height: 8),
        TextField(controller: _pw, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
        if (_err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_err!, style: const TextStyle(color: Brand.red))),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () async {
            try {
              await ref.read(authGatewayProvider).mockSignIn(_email, _pw.text);
            } catch (e) {
              setState(() => _err = AppFailure.from(e).message);
            }
          },
          child: const Text('Masuk (mock)'),
        ),
      ]),
    );
  }
}
