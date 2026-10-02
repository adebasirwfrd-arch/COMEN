import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../contracts/contract_common.dart';
import '../status/status_pages.dart';

/// Akun pending: pilih jalur (karyawan Weatherford / contractor), lalu pantau status pengajuan.
class PendingPage extends ConsumerStatefulWidget {
  const PendingPage({super.key});
  @override
  ConsumerState<PendingPage> createState() => _PendingPageState();
}

class _PendingPageState extends ConsumerState<PendingPage> {
  late Future<J> _future = _load();

  Future<J> _load() => ref.read(apiProvider).rpcMap('get_my_wfrd_request');

  Future<void> _refresh() async {
    await ref.read(sessionProvider.notifier).refresh();
    if (mounted) setState(() => _future = _load());
  }

  Future<void> _withdraw() async {
    final ok = await showConfirm(
      context,
      title: 'Batalkan pengajuan?',
      message: 'Pengajuan akses karyawan Weatherford dibatalkan. Anda bisa memilih jalur pendaftaran lagi setelahnya.',
      confirmLabel: 'Batalkan pengajuan',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final r = await runAction<bool>(context, ref, () async {
      await ref.read(apiProvider).rpc('withdraw_wfrd_join_request');
      return true;
    }, success: 'Pengajuan dibatalkan');
    if (r == true && mounted) setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final st = watchSession(ref);
    final submitted = st?.registrationSubmitted == true;
    return BrandBackdrop(
      maxWidth: 720,
      child: submitted
          ? _companySubmitted(st?.contractorName, st?.vendorStatus)
          : AsyncView<J>(
              future: _future,
              onRetry: () => setState(() => _future = _load()),
              builder: (context, r) {
                final req = r['request'] is Map ? jm(r['request']) : null;
                if (req != null) return _wfrdSubmitted(req);
                final draft = r['contractor_draft'] is Map ? jm(r['contractor_draft']) : null;
                return _choice(draft, st?.email);
              },
            ),
    );
  }

  List<Widget> get _footer => [
        OutlinedButton.icon(onPressed: _refresh, icon: const Icon(Icons.refresh_rounded), label: const Text('Periksa status')),
        TextButton(onPressed: () => context.go('/settings/devices'), child: const Text('Perangkat saya / keluar')),
      ];

  Widget _companySubmitted(String? company, String? vendorStatus) => StatusMessage(
        icon: Icons.hourglass_top_rounded,
        color: Brand.amber,
        title: 'Akun Anda menunggu persetujuan Admin',
        message: 'Registrasi perusahaan ${company ?? ''} sudah dikirim (status: ${vendorStatus ?? '-'}). '
            'Anda akan otomatis masuk begitu Admin menyetujui akun.',
        actions: _footer,
      );

  Widget _wfrdSubmitted(J req) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const StatusMessage(
          icon: Icons.badge_rounded,
          color: Brand.amber,
          title: 'Pengajuan karyawan Weatherford terkirim',
          message: 'Admin WFRD sedang memverifikasi data Anda dan akan menentukan role akses. '
              'Anda akan otomatis masuk dan menerima email begitu akun disetujui.',
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: Theme.of(context).dividerColor)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ReviewRow('Nama', str(req['full_name'])),
            ReviewRow('Employee ID', str(req['employee_id'])),
            ReviewRow('Jabatan', '${str(req['job_title'])} · ${str(req['department'])}'),
            ReviewRow('Geozone', '${str(req['geozone'])} · ${str(req['geozone_name'])}'),
            ReviewRow('Atasan', '${str(req['line_manager_name'])} (${str(req['line_manager_email'])})'),
            ReviewRow('Role diminta', str(req['requested_role_name'], 'Ditentukan Admin')),
            ReviewRow('Dikirim', fmtDateTime(req['submitted_at'])),
          ]),
        ),
        const SizedBox(height: 16),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(onPressed: () => context.go('/register/wfrd'), icon: const Icon(Icons.edit_rounded), label: const Text('Ubah pengajuan')),
          OutlinedButton.icon(
            onPressed: _withdraw,
            style: OutlinedButton.styleFrom(foregroundColor: Brand.red),
            icon: const Icon(Icons.undo_rounded),
            label: const Text('Batalkan pengajuan'),
          ),
          ..._footer,
        ]),
      ]);

  Widget _choice(J? draft, String? email) {
    final t = Theme.of(context).textTheme;
    final hasDraft = draft != null && draft['status'] == 'draft';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Daftar sebagai apa?', textAlign: TextAlign.center, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
      const SizedBox(height: 6),
      Text(
        'Akun ${email ?? ''} sudah terverifikasi. Pilih jalur pendaftaran — Admin WFRD akan memeriksa dan menyetujui akun Anda.',
        textAlign: TextAlign.center,
        style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 22),
      LayoutBuilder(builder: (context, c) {
        final cards = [
          _ChoiceCard(
            icon: Icons.badge_rounded,
            color: Brand.blue,
            title: 'Karyawan Weatherford',
            body: 'Saya pegawai Weatherford dan membutuhkan akses COMEN (mis. HSE, Process Owner, Procurement). '
                'Isi data kepegawaian; Admin memverifikasi & menentukan role.',
            cta: 'Daftar sebagai karyawan',
            onTap: () => context.go('/register/wfrd'),
          ),
          _ChoiceCard(
            icon: Icons.apartment_rounded,
            color: Brand.cyan,
            title: 'Contractor / vendor',
            body: 'Saya mewakili perusahaan yang bekerja untuk Weatherford. Daftarkan perusahaan untuk masuk Approved Supplier List.',
            cta: hasDraft ? 'Lanjutkan draft ${str(draft['legal_name'])}' : 'Daftarkan perusahaan',
            onTap: () => context.go('/register'),
          ),
        ];
        if (c.maxWidth < 560) return Column(children: [cards[0], const SizedBox(height: 12), cards[1]]);
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 14),
            Expanded(child: cards[1]),
          ]),
        );
      }),
      const SizedBox(height: 16),
      const InfoBanner(
        icon: Icons.mail_outline_rounded,
        message: 'Sudah menerima undangan dari Admin? Akun Anda akan aktif otomatis — cukup tekan "Periksa status".',
      ),
      const SizedBox(height: 8),
      ..._footer.map((w) => Padding(padding: const EdgeInsets.only(top: 8), child: w)),
    ]).animate().fadeIn(duration: 250.ms);
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.icon, required this.color, required this.title, required this.body, required this.cta, required this.onTap});
  final IconData icon;
  final Color color;
  final String title, body, cta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: color.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: color.withValues(alpha: 0.35))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: color),
              ),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 6),
              Text(body, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 14),
              Row(children: [
                Flexible(child: Text(cta, style: TextStyle(color: color, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_rounded, size: 18, color: color),
              ]),
            ]),
          ),
        ),
      );
}
