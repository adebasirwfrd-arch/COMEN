import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../contracts/contract_common.dart';
import '../status/status_pages.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _phoneRe = RegExp(r'^\+?[0-9 ()-]{6,20}$');
final _employeeIdRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]{1,39}$');

const _keys = [
  'full_name', 'employee_id', 'work_email', 'job_title', 'department', 'work_location',
  'line_manager_name', 'line_manager_email', 'phone', 'note',
];

/// Pengajuan akses karyawan Weatherford oleh akun pending — diverifikasi & diberi role oleh Admin.
class WfrdRegisterPage extends ConsumerStatefulWidget {
  const WfrdRegisterPage({super.key});
  @override
  ConsumerState<WfrdRegisterPage> createState() => _WfrdRegisterPageState();
}

class _WfrdRegisterPageState extends ConsumerState<WfrdRegisterPage> {
  late Future<J> _future = _load();
  final _ctl = {for (final k in _keys) k: TextEditingController()};
  String? _geozone, _role;
  bool _showErrors = false, _busy = false, _privacy = false, _attest = false, _editing = false;

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<J> _load() async {
    final r = await ref.read(apiProvider).rpcMap('get_my_wfrd_request');
    final req = r['request'] is Map ? jm(r['request']) : null;
    _editing = req != null;
    if (req != null) {
      for (final k in _keys) {
        _ctl[k]!.text = req[k]?.toString() ?? '';
      }
      _geozone = req['geozone'] as String?;
      _role = req['requested_role_key'] as String?;
    } else {
      _ctl['full_name']!.text = jm(r['profile'])['full_name']?.toString() ?? '';
      final geos = jl(r['geozones']);
      if (geos.length == 1) _geozone = geos.first['code'] as String?;
    }
    return r;
  }

  String _v(String k) => _ctl[k]!.text.trim();

  String? _err(String k) {
    final v = _v(k);
    return switch (k) {
      'full_name' || 'job_title' || 'department' || 'line_manager_name' => v.length < 2 ? 'Wajib diisi' : null,
      'employee_id' => _employeeIdRe.hasMatch(v) ? null : 'Huruf/angka 2–40 karakter (boleh . _ / -)',
      'work_email' => v.isEmpty || _emailRe.hasMatch(v) ? null : 'Email tidak valid',
      'line_manager_email' => _emailRe.hasMatch(v) ? null : 'Email atasan wajib & valid',
      'phone' => v.isEmpty || _phoneRe.hasMatch(v) ? null : 'Format: +62 812 3456 7890',
      _ => null,
    };
  }

  bool get _valid => _keys.every((k) => _err(k) == null) && _geozone != null;

  Future<void> _submit(J? draft) async {
    if (!_valid || !_privacy || !_attest) {
      setState(() => _showErrors = true);
      return;
    }
    if (draft != null && draft['status'] == 'draft') {
      final ok = await showConfirm(
        context,
        title: 'Batalkan draft perusahaan?',
        message: 'Draft registrasi perusahaan "${str(draft['legal_name'])}" akan dihapus karena Anda mendaftar sebagai karyawan Weatherford.',
        confirmLabel: 'Lanjutkan',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    final r = await runAction<J>(
      context,
      ref,
      () => ref.read(apiProvider).rpcMap('submit_wfrd_join_request', {
        'p_data': {
          for (final k in _keys) k: _v(k).isEmpty ? null : _v(k),
          'geozone': _geozone,
          'requested_role_key': _role,
          'privacy_accepted': _privacy,
        },
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.verified_rounded, color: Brand.green, size: 48),
        title: Text(_editing ? 'Pengajuan diperbarui' : 'Pengajuan terkirim'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Admin WFRD akan memverifikasi data kepegawaian Anda lalu menentukan role akses. '
            'Anda akan otomatis masuk dan menerima email begitu akun disetujui.',
            textAlign: TextAlign.center,
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Lanjutkan'))],
      ),
    );
    if (!mounted) return;
    await ref.read(sessionProvider.notifier).refresh();
    if (mounted) context.go('/pending');
  }

  @override
  Widget build(BuildContext context) => BrandBackdrop(
        maxWidth: 860,
        child: AsyncView<J>(
          future: _future,
          onRetry: () => setState(() => _future = _load()),
          builder: (context, r) {
            final draft = r['contractor_draft'] is Map ? jm(r['contractor_draft']) : null;
            if (draft != null && draft['status'] != 'draft') return _companySubmitted(draft);
            return _form(r, draft);
          },
        ),
      );

  Widget _companySubmitted(J d) => StatusMessage(
        icon: Icons.apartment_rounded,
        color: Brand.amber,
        title: 'Registrasi perusahaan sudah dikirim',
        message: 'Akun ini sudah mengirim registrasi perusahaan ${str(d['legal_name'])}. '
            'Bila Anda sebenarnya karyawan Weatherford, hubungi Admin WFRD agar registrasi itu ditolak, lalu daftar ulang.',
        actions: [OutlinedButton.icon(onPressed: () => context.go('/pending'), icon: const Icon(Icons.arrow_back_rounded), label: const Text('Kembali'))],
      );

  Widget _form(J r, J? draft) {
    final t = Theme.of(context).textTheme;
    final geos = jl(r['geozones']);
    final roles = jl(r['roles']);
    final email = str(jm(r['profile'])['email'], '');
    final personal = !email.toLowerCase().endsWith('@weatherford.com');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pendaftaran karyawan Weatherford', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            const SizedBox(height: 4),
            Text('Isi data kepegawaian Anda. Admin WFRD memverifikasi lalu menentukan role akses COMEN.',
                style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        if (_editing) const StatusBadge(Brand.amber, 'Menunggu verifikasi', icon: Icons.hourglass_top_rounded),
      ]),
      const SizedBox(height: 20),
      if (draft != null) ...[
        InfoBanner(
          color: Brand.amber,
          icon: Icons.apartment_rounded,
          message: 'Akun ini punya draft registrasi perusahaan "${str(draft['legal_name'])}". Draft itu akan dihapus saat pengajuan ini dikirim.',
        ),
        const SizedBox(height: 12),
      ],
      if (personal) ...[
        InfoBanner(
          icon: Icons.alternate_email_rounded,
          message: 'Anda masuk dengan $email (bukan email Weatherford). Cantumkan email kerja Weatherford bila ada agar verifikasi lebih cepat.',
        ),
        const SizedBox(height: 12),
      ],
      _section('Identitas karyawan', 'Sesuai data HR Weatherford', Icons.badge_rounded),
      _field('full_name', 'Nama lengkap *', icon: Icons.person_outline_rounded, maxLength: 120),
      const SizedBox(height: 6),
      _pair(
        _field('employee_id', 'Employee ID / NIK karyawan *', icon: Icons.badge_outlined, maxLength: 40, hint: 'mis. WFT-10234'),
        _field('work_email', 'Email kerja Weatherford', icon: Icons.email_outlined, type: TextInputType.emailAddress, hint: 'nama@weatherford.com'),
      ),
      const SizedBox(height: 6),
      _field('phone', 'Telepon', icon: Icons.phone_outlined, type: TextInputType.phone, helper: 'Opsional · disimpan terenkripsi', formatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ()-]')),
      ]),
      const SizedBox(height: 22),
      _section('Posisi & lokasi', 'Untuk menentukan role dan cakupan akses', Icons.work_outline_rounded),
      _pair(
        _field('job_title', 'Jabatan *', icon: Icons.work_outline_rounded, maxLength: 120, hint: 'mis. HSE Specialist'),
        _field('department', 'Departemen / fungsi *', icon: Icons.account_tree_outlined, maxLength: 120, hint: 'mis. HSE, Operations, Supply Chain'),
      ),
      const SizedBox(height: 6),
      _pair(
        DropdownButtonFormField<String>(
          initialValue: geos.any((g) => g['code'] == _geozone) ? _geozone : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Geozone *',
            prefixIcon: const Icon(Icons.public_rounded),
            errorText: _showErrors && _geozone == null ? 'Pilih geozone' : null,
          ),
          items: [for (final g in geos) DropdownMenuItem(value: g['code'] as String, child: Text('${g['code']} · ${str(g['name'])}'))],
          onChanged: (v) => setState(() => _geozone = v),
        ),
        _field('work_location', 'Lokasi kerja / base', icon: Icons.place_outlined, maxLength: 120, hint: 'mis. Balikpapan'),
      ),
      const SizedBox(height: 22),
      _section('Atasan langsung', 'Admin dapat mengonfirmasi ke atasan Anda', Icons.supervisor_account_rounded),
      _pair(
        _field('line_manager_name', 'Nama atasan *', icon: Icons.person_outline_rounded, maxLength: 120),
        _field('line_manager_email', 'Email atasan *', icon: Icons.email_outlined, type: TextInputType.emailAddress),
      ),
      const SizedBox(height: 22),
      _section('Akses yang dibutuhkan', 'Keputusan akhir role ada di Admin', Icons.key_rounded),
      DropdownButtonFormField<String?>(
        initialValue: roles.any((x) => x['key'] == _role) ? _role : null,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Role yang diminta', prefixIcon: Icon(Icons.key_rounded)),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('Belum tahu — biar Admin yang menentukan')),
          for (final x in roles)
            DropdownMenuItem<String?>(
              value: x['key'] as String,
              child: Text(x['description'] == null ? str(x['name']) : '${str(x['name'])} — ${x['description']}', overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() => _role = v),
      ),
      const SizedBox(height: 14),
      _field('note', 'Catatan untuk Admin', icon: Icons.notes_rounded, maxLines: 3, maxLength: 1000,
          hint: 'mis. kontrak/area yang akan saya kelola, atau dulu saya terdaftar sebagai contractor'),
      const SizedBox(height: 8),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _privacy,
        onChanged: (v) => setState(() => _privacy = v ?? false),
        title: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Saya telah membaca dan menyetujui '),
          InkWell(
            onTap: () => context.push('/privacy'),
            child: const Text('Privacy Notice', style: TextStyle(color: Brand.blue, fontWeight: FontWeight.w700, decoration: TextDecoration.underline)),
          ),
          const Text(' *'),
        ]),
        subtitle: _showErrors && !_privacy ? const Text('Wajib disetujui', style: TextStyle(color: Brand.red)) : null,
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _attest,
        onChanged: (v) => setState(() => _attest = v ?? false),
        title: const Text('Saya menyatakan saya karyawan Weatherford dan data di atas benar. *'),
        subtitle: _showErrors && !_attest ? const Text('Wajib dicentang', style: TextStyle(color: Brand.red)) : null,
      ),
      const SizedBox(height: 16),
      const Divider(height: 1),
      const SizedBox(height: 16),
      Row(children: [
        TextButton.icon(onPressed: _busy ? null : () => context.go('/pending'), icon: const Icon(Icons.arrow_back_rounded), label: const Text('Kembali')),
        const Spacer(),
        FilledButton.icon(
          onPressed: _busy ? null : () => _submit(draft),
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send_rounded),
          label: Text(_editing ? 'Perbarui pengajuan' : 'Kirim pengajuan'),
        ),
      ]),
      const SizedBox(height: 12),
      Text('Masuk sebagai $email', textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: Brand.grey)),
    ]);
  }

  Widget _field(String k, String label,
      {IconData? icon, String? helper, String? hint, int maxLines = 1, int? maxLength, TextInputType? type, List<TextInputFormatter>? formatters}) {
    final show = _showErrors || _v(k).isNotEmpty;
    return TextField(
      controller: _ctl[k],
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: type,
      inputFormatters: formatters,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        prefixIcon: icon == null ? null : Icon(icon),
        errorText: show ? _err(k) : null,
      ),
    );
  }

  Widget _pair(Widget a, Widget b) => LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 560) return Column(children: [a, const SizedBox(height: 14), b]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 14), Expanded(child: b)]);
      });

  Widget _section(String title, String subtitle, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Brand.blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: Brand.blue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      );
}
