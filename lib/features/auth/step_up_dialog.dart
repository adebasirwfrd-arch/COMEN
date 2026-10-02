import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/errors/app_failure.dart';
import '../../ui/theme.dart';
import 'auth_gateway.dart';

/// Step-up MFA (≤ 12 jam) untuk aksi critical — bukan logout, hanya minta kode TOTP.
class StepUpDialog extends ConsumerStatefulWidget {
  const StepUpDialog({super.key});
  @override
  ConsumerState<StepUpDialog> createState() => _StepUpDialogState();
}

class _StepUpDialogState extends ConsumerState<StepUpDialog> {
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
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = AppFailure.from(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.shield_rounded, color: Brand.blue, size: 36),
      title: const Text('Konfirmasi dengan MFA'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Aksi ini bersifat kritis. Masukkan kode authenticator untuk melanjutkan.'),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            maxLength: 6,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, letterSpacing: 10, fontWeight: FontWeight.w800),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _code.text.trim().length == 6 ? _verify() : null,
            decoration: InputDecoration(counterText: '', errorText: _error),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
        FilledButton(onPressed: _busy || _code.text.trim().length != 6 ? null : _verify, child: const Text('Verifikasi')),
      ],
    );
  }
}
