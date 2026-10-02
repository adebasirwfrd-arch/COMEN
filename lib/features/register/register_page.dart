import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/turnstile_box.dart';
import '../../ui/widgets.dart';
import '../contracts/contract_common.dart';
import '../status/status_pages.dart';
import '../vendors/vendor_common.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _phoneRe = RegExp(r'^\+?[0-9 ()-]{6,20}$');
final _iso2Re = RegExp(r'^[A-Z]{2}$');

const _companyKeys = ['legal_name', 'trading_name', 'registration_no', 'tax_id', 'country', 'address', 'website'];
const _contactKeys = ['primary_contact_name', 'primary_contact_email', 'primary_contact_phone', 'hse_manager_name', 'hse_manager_email'];

const _steps = [
  ('Akun', Icons.login_rounded),
  ('Perusahaan', Icons.apartment_rounded),
  ('Kontak', Icons.contacts_rounded),
  ('Dokumen', Icons.folder_copy_rounded),
  ('Review', Icons.fact_check_rounded),
];

/// Wizard registrasi kontraktor (Fase 0): Akun → Perusahaan → Kontak → Pratinjau dokumen → Review & kirim.
class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});
  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _opened = Stopwatch()..start();
  late Future<J> _future = _load();
  final _ctl = {for (final k in [..._companyKeys, ..._contactKeys]) k: TextEditingController()};
  final _honeypot = TextEditingController();
  final _turnstileKey = GlobalKey<TurnstileBoxState>();
  String? _countryPick;
  int _step = 1;
  bool _showErrors = false, _busy = false, _privacy = false, _attest = false;
  String? _token, _trackingId;
  DateTime? _savedAt;

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    _honeypot.dispose();
    super.dispose();
  }

  Future<J> _load() async {
    final r = await ref.read(apiProvider).rpcMap('get_my_registration');
    final c = r['contractor'];
    if (c is Map) {
      for (final k in _ctl.keys) {
        _ctl[k]!.text = c[k]?.toString() ?? '';
      }
      _trackingId = c['tracking_id'] as String?;
      final country = _ctl['country']!.text;
      _countryPick = country.isEmpty ? 'ID' : (countryNames.containsKey(country) ? country : 'OTHER');
      if (country.isEmpty) _ctl['country']!.text = 'ID';
    } else {
      _countryPick = 'ID';
      _ctl['country']!.text = 'ID';
      final s = readSession(ref);
      if (s?.fullName != null) _ctl['primary_contact_name']!.text = s!.fullName!;
      if (s != null) _ctl['primary_contact_email']!.text = s.email;
    }
    return r;
  }

  String _v(String k) => _ctl[k]!.text.trim();

  String? _err(String k) {
    final v = _v(k);
    switch (k) {
      case 'legal_name':
        return v.length < 2 ? 'Nama legal wajib (min. 2 karakter)' : null;
      case 'registration_no':
        return v.isEmpty ? 'Nomor registrasi / NIB wajib' : null;
      case 'tax_id':
        return v.isEmpty ? 'NPWP / Tax ID wajib' : null;
      case 'country':
        return _iso2Re.hasMatch(v.toUpperCase()) ? null : 'Kode negara ISO-2 (mis. ID)';
      case 'address':
        return v.length < 5 ? 'Alamat lengkap wajib' : null;
      case 'website':
        return v.isEmpty || RegExp(r'^https?://\S+\.\S+').hasMatch(v) ? null : 'Awali dengan https://';
      case 'primary_contact_name' || 'hse_manager_name':
        return v.length < 2 ? 'Nama wajib' : null;
      case 'primary_contact_email' || 'hse_manager_email':
        return _emailRe.hasMatch(v) ? null : 'Email tidak valid';
      case 'primary_contact_phone':
        return _phoneRe.hasMatch(v) ? null : 'Format: +62 812 3456 7890';
    }
    return null;
  }

  List<String> _keysOf(int step) => switch (step) { 1 => _companyKeys, 2 => _contactKeys, _ => const [] };
  bool _stepValid(int step) => _keysOf(step).every((k) => _err(k) == null);
  bool get _allValid => _stepValid(1) && _stepValid(2);

  Future<bool> _saveStep(int step) async {
    final keys = step == 1 || step == 2 ? _keysOf(step) : [..._companyKeys, ..._contactKeys];
    final data = <String, dynamic>{
      for (final k in keys) k: k == 'country' ? _v(k).toUpperCase() : (_v(k).isEmpty ? null : _v(k)),
    };
    if (!data.containsKey('legal_name')) data['legal_name'] = _v('legal_name');
    setState(() => _busy = true);
    final r = await runAction<J>(context, ref, () => ref.read(apiProvider).rpcMap('save_registration_draft', {'p_data': data}));
    if (!mounted) return false;
    setState(() {
      _busy = false;
      if (r != null) {
        _trackingId = r['tracking_id'] as String? ?? _trackingId;
        _savedAt = DateTime.now();
      }
    });
    return r != null;
  }

  Future<void> _next() async {
    if (!_stepValid(_step)) {
      setState(() => _showErrors = true);
      return;
    }
    if ((_step == 1 || _step == 2) && !await _saveStep(_step)) return;
    if (!mounted) return;
    _setStep(_step + 1);
  }

  void _back() => _setStep(_step - 1);

  /// Token Turnstile hanya berlaku untuk widget yang sedang tampil; pindah dari step review membuangnya.
  void _setStep(int step, {bool showErrors = false}) => setState(() {
        _showErrors = showErrors;
        _step = step.clamp(1, 4);
        if (_step != 4) _token = null;
      });

  Future<void> _goto(int step) async {
    if (step == _step || step < 1) return;
    if (step > _step) {
      for (var s = _step; s < step; s++) {
        if (!_stepValid(s)) {
          _setStep(s, showErrors: true);
          return;
        }
      }
      if ((_step == 1 || _step == 2) && !await _saveStep(_step)) return;
    }
    if (mounted) _setStep(step);
  }

  Future<void> _submit() async {
    if (!_allValid) {
      _setStep(_stepValid(1) ? 2 : 1, showErrors: true);
      return;
    }
    if (!await _saveStep(4) || !mounted) return;
    setState(() => _busy = true);
    final r = await runAction<J>(
      context,
      ref,
      () => ref.read(apiProvider).edge('submit-registration', {
        'turnstile_token': _token,
        'privacy_accepted': true,
        'website_url2': _honeypot.text,
        'elapsed_ms': _opened.elapsedMilliseconds,
      }),
    );
    if (!mounted) return;
    _turnstileKey.currentState?.reset();
    setState(() => _busy = false);
    if (r == null) return;
    final tracking = r['tracking_id'] as String? ?? _trackingId ?? '-';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.verified_rounded, color: Brand.green, size: 48),
        title: const Text('Registrasi terkirim'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Simpan Tracking ID berikut untuk korespondensi dengan Weatherford:', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TaskIdChip(tracking, large: true),
            const SizedBox(height: 16),
            const Text(
              'Status vendor: Under Review. Anda akan menerima email setelah akun disetujui. Task dokumen legal vendor dibuat otomatis setelah akun aktif.',
              textAlign: TextAlign.center,
            ),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Lanjutkan'))],
      ),
    );
    if (!mounted) return;
    await ref.read(sessionProvider.notifier).refresh();
    if (mounted) context.go('/pending');
  }

  @override
  Widget build(BuildContext context) {
    return BrandBackdrop(
      maxWidth: 860,
      child: AsyncView<J>(
        future: _future,
        onRetry: () => setState(() => _future = _load()),
        builder: (context, r) {
          final c = r['contractor'] is Map ? jm(r['contractor']) : null;
          if (c != null && c['status'] != 'draft') return _alreadySubmitted(c);
          return _wizard(c, jl(r['documents_preview']));
        },
      ),
    );
  }

  Widget _alreadySubmitted(J c) => StatusMessage(
        icon: Icons.mark_email_read_rounded,
        color: Brand.green,
        title: 'Registrasi sudah dikirim',
        message: 'Tracking ID ${str(c['tracking_id'])} · status ${StatusStyle.vendor(c['status'] as String?).$2}'
            '${c['submitted_at'] == null ? '' : ' · dikirim ${fmtDate(c['submitted_at'])}'}. Perubahan data dilakukan melalui profil perusahaan setelah akun aktif.',
        actions: [
          FilledButton.icon(
            onPressed: () async {
              await ref.read(sessionProvider.notifier).refresh();
              if (mounted) context.go('/pending');
            },
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Lihat status'),
          ),
        ],
      );

  Widget _wizard(J? c, List<J> docs) {
    final t = Theme.of(context).textTheme;
    final s = watchSession(ref);
    final reason = c?['status_reason'] as String?;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Registrasi kontraktor', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            const SizedBox(height: 4),
            Text('Lengkapi data perusahaan untuk masuk Approved Supplier List Weatherford.', style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        if (_trackingId != null)
          Tooltip(message: 'Tracking ID (draft)', child: TaskIdChip(_trackingId!)),
      ]),
      const SizedBox(height: 24),
      _Stepper(current: _step, valid: [true, _stepValid(1), _stepValid(2), true, _allValid && _privacy && _attest], onTap: _goto),
      const SizedBox(height: 24),
      if (reason != null && reason.isNotEmpty) ...[
        InfoBanner(color: Brand.amber, icon: Icons.forum_rounded, message: 'Weatherford meminta informasi tambahan: $reason'),
        const SizedBox(height: 16),
      ],
      Offstage(
        child: ExcludeFocus(
          child: ExcludeSemantics(
            child: SizedBox(
              width: 1,
              height: 1,
              child: TextField(controller: _honeypot, autofillHints: const [], decoration: const InputDecoration(labelText: 'website_url2')),
            ),
          ),
        ),
      ),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (child, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(a), child: child)),
        child: KeyedSubtree(
          key: ValueKey(_step),
          child: switch (_step) {
            1 => _companyStep(),
            2 => _contactStep(),
            3 => _docsStep(docs),
            _ => _reviewStep(),
          },
        ),
      ),
      const SizedBox(height: 28),
      const Divider(height: 1),
      const SizedBox(height: 16),
      Row(children: [
        if (_step > 1) TextButton.icon(onPressed: _busy ? null : _back, icon: const Icon(Icons.arrow_back_rounded), label: const Text('Kembali')),
        const Spacer(),
        if (_savedAt != null && !_busy)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.cloud_done_rounded, size: 16, color: Brand.green),
              const SizedBox(width: 4),
              Text('Draft tersimpan', style: t.bodySmall?.copyWith(color: Brand.green)),
            ]),
          ),
        if (_step < 4)
          FilledButton.icon(
            onPressed: _busy ? null : _next,
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.arrow_forward_rounded),
            label: Text(_step == 3 ? 'Lanjut ke review' : 'Simpan & lanjut'),
          )
        else
          FilledButton.icon(
            onPressed: !_busy && _allValid && _privacy && _attest && _token != null ? _submit : null,
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded),
            label: const Text('Kirim registrasi'),
          ),
      ]),
      const SizedBox(height: 12),
      Text('Masuk sebagai ${str(s?.email)}', textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: Brand.grey)),
    ]);
  }

  // ─────────── Step widgets ───────────
  Widget _field(String k, String label, {IconData? icon, String? helper, int maxLines = 1, int? maxLength, TextInputType? type, List<TextInputFormatter>? formatters, String? hint}) {
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

  Widget _sectionTitle(String title, String subtitle, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
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

  Widget _companyStep() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionTitle('Informasi perusahaan', 'Sesuai akta / dokumen legal. Nama legal, NIB, NPWP & negara terkunci setelah dikirim.', Icons.apartment_rounded),
        _field('legal_name', 'Nama legal perusahaan *', icon: Icons.business_rounded, maxLength: 200, hint: 'PT Maju Jaya Abadi'),
        const SizedBox(height: 6),
        _field('trading_name', 'Nama dagang', icon: Icons.storefront_outlined, maxLength: 200),
        const SizedBox(height: 6),
        _pair(
          _field('registration_no', 'No. registrasi / NIB *', icon: Icons.badge_outlined, maxLength: 60),
          _field('tax_id', 'NPWP / Tax ID *', icon: Icons.receipt_long_outlined, maxLength: 40, helper: 'Unik per negara'),
        ),
        const SizedBox(height: 14),
        _pair(
          DropdownButtonFormField<String>(
            initialValue: _countryPick,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Negara *', prefixIcon: Icon(Icons.public_rounded)),
            items: [
              for (final e in countryNames.entries) DropdownMenuItem(value: e.key, child: Text('${e.value} (${e.key})')),
              const DropdownMenuItem(value: 'OTHER', child: Text('Lainnya (kode ISO-2)…')),
            ],
            onChanged: (v) => setState(() {
              _countryPick = v;
              _ctl['country']!.text = v == null || v == 'OTHER' ? '' : v;
            }),
          ),
          _countryPick == 'OTHER'
              ? _field('country', 'Kode negara ISO-2 *', icon: Icons.flag_outlined, maxLength: 2, formatters: [
                  FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
                  TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase())),
                ])
              : _field('website', 'Website', icon: Icons.language_rounded, type: TextInputType.url, hint: 'https://'),
        ),
        if (_countryPick == 'OTHER') ...[const SizedBox(height: 14), _field('website', 'Website', icon: Icons.language_rounded, type: TextInputType.url, hint: 'https://')],
        const SizedBox(height: 14),
        _field('address', 'Alamat lengkap *', icon: Icons.place_outlined, maxLines: 3, maxLength: 500),
      ]);

  Widget _contactStep() {
    final domain = _v('primary_contact_email').contains('@') ? _v('primary_contact_email').split('@').last : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle('Kontak utama', 'Penerima notifikasi registrasi & ASL', Icons.person_pin_rounded),
      _field('primary_contact_name', 'Nama lengkap *', icon: Icons.person_outline_rounded, maxLength: 120),
      const SizedBox(height: 6),
      _pair(
        _field('primary_contact_email', 'Email *', icon: Icons.email_outlined, type: TextInputType.emailAddress),
        _field('primary_contact_phone', 'Telepon *', icon: Icons.phone_outlined, type: TextInputType.phone, helper: 'Disimpan terenkripsi', formatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ()-]')),
        ]),
      ),
      if (domain != null && _emailRe.hasMatch(_v('primary_contact_email'))) ...[
        const SizedBox(height: 10),
        InfoBanner(
          icon: Icons.alternate_email_rounded,
          message: 'Domain @$domain dipakai untuk mencocokkan rekan kerja yang mendaftar kemudian. Gunakan email perusahaan, bukan email pribadi.',
        ),
      ],
      const SizedBox(height: 28),
      _sectionTitle('HSE Manager', 'Penanggung jawab HSE perusahaan', Icons.health_and_safety_rounded),
      _pair(
        _field('hse_manager_name', 'Nama *', icon: Icons.person_outline_rounded, maxLength: 120),
        _field('hse_manager_email', 'Email *', icon: Icons.email_outlined, type: TextInputType.emailAddress),
      ),
    ]);
  }

  Widget _docsStep(List<J> docs) {
    const reqLabel = {'mandatory': 'Wajib', 'conditional': 'Kondisional', 'optional': 'Opsional'};
    const reqColor = {'mandatory': Brand.red, 'conditional': Brand.amber, 'optional': Brand.grey};
    final groups = <String, List<J>>{};
    for (final d in docs) {
      groups.putIfAbsent(d['requirement'] as String? ?? 'optional', () => []).add(d);
    }
    final order = ['mandatory', 'conditional', 'optional', ...groups.keys.where((k) => !reqLabel.containsKey(k))];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle('Dokumen legal yang akan diminta', 'Pratinjau — task upload dibuat otomatis setelah akun Anda aktif', Icons.folder_copy_rounded),
      const InfoBanner(
        icon: Icons.cloud_upload_outlined,
        message: 'Siapkan dokumen dalam PDF. Upload dilakukan ke OneDrive/SharePoint Weatherford melalui link di setiap task — COMEN tidak menyimpan file.',
      ),
      const SizedBox(height: 16),
      if (docs.isEmpty)
        const EmptyState(icon: Icons.folder_open_rounded, title: 'Belum ada daftar dokumen', message: 'Weatherford akan menginformasikan dokumen yang dibutuhkan.')
      else
        for (final g in order)
          if (groups[g] != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Row(children: [
                StatusBadge(reqColor[g] ?? Brand.grey, reqLabel[g] ?? g),
                const SizedBox(width: 8),
                Text('${groups[g]!.length} dokumen', style: const TextStyle(color: Brand.grey, fontSize: 12)),
              ]),
            ),
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth >= 600 ? 2 : 1;
              final w = (c.maxWidth - (cols - 1) * 10) / cols;
              return Wrap(spacing: 10, runSpacing: 10, children: [
                for (final d in groups[g]!)
                  SizedBox(
                    width: w,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      child: Row(children: [
                        Icon(Icons.description_outlined, color: reqColor[g] ?? Brand.grey),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(str(d['label']), style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(
                              [str(d['code']), if (d['condition'] != null) 'bila ${d['condition'].toString().replaceAll('_', ' ')}'].join(' · '),
                              style: const TextStyle(fontSize: 12, color: Brand.grey),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
              ]);
            }),
          ],
    ]);
  }

  Widget _reviewStep() {
    final countryCode = _v('country').toUpperCase();
    Widget block(String title, int step, List<(String, String)> rows) => Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: Theme.of(context).dividerColor)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800))),
              if (!_stepValid(step)) const StatusBadge(Brand.red, 'Belum lengkap'),
              TextButton.icon(onPressed: () => _setStep(step), icon: const Icon(Icons.edit_rounded, size: 16), label: const Text('Ubah')),
            ]),
            for (final (k, v) in rows) ReviewRow(k, v.isEmpty ? null : v),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle('Review & kirim', 'Periksa kembali sebelum mengirim — data legal terkunci setelah dikirim', Icons.fact_check_rounded),
      block('Perusahaan', 1, [
        ('Nama legal', _v('legal_name')),
        ('Nama dagang', _v('trading_name')),
        ('NIB / registrasi', _v('registration_no')),
        ('NPWP / Tax ID', _v('tax_id')),
        ('Negara', countryCode.isEmpty ? '' : countryLabel(countryCode)),
        ('Alamat', _v('address')),
        ('Website', _v('website')),
      ]),
      block('Kontak', 2, [
        ('Kontak utama', _v('primary_contact_name')),
        ('Email', _v('primary_contact_email')),
        ('Telepon', _v('primary_contact_phone')),
        ('HSE Manager', _v('hse_manager_name')),
        ('Email HSE Manager', _v('hse_manager_email')),
      ]),
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
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _attest,
        onChanged: (v) => setState(() => _attest = v ?? false),
        title: const Text('Saya menyatakan data di atas benar, dan saya berwenang mewakili perusahaan ini. *'),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(_token == null ? Icons.shield_outlined : Icons.verified_user_rounded, size: 18, color: _token == null ? Brand.grey : Brand.green),
            const SizedBox(width: 8),
            Text(_token == null ? 'Verifikasi keamanan' : 'Terverifikasi', style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          TurnstileBox(
            key: _turnstileKey,
            action: 'registration',
            onToken: (t) {
              if (mounted) setState(() => _token = t);
            },
          ),
        ]),
      ),
      if (!_allValid) ...[
        const SizedBox(height: 12),
        const InfoBanner(color: Brand.red, icon: Icons.error_outline_rounded, message: 'Masih ada data wajib yang belum lengkap atau tidak valid.'),
      ],
    ]);
  }
}

// ─────────────────────────── Stepper ───────────────────────────
class _Stepper extends StatelessWidget {
  const _Stepper({required this.current, required this.valid, required this.onTap});
  final int current;
  final List<bool> valid;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final compact = c.maxWidth < 560;
      return Row(children: [
        for (var i = 0; i < _steps.length; i++) ...[
          if (i > 0)
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 3,
                margin: EdgeInsets.only(bottom: compact ? 0 : 20),
                decoration: BoxDecoration(color: i <= current ? Brand.blue : Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: i == 0 ? null : () => onTap(i),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < current ? Brand.green : (i == current ? Brand.blue : Theme.of(context).colorScheme.surfaceContainerHighest),
                  boxShadow: i == current ? [BoxShadow(color: Brand.blue.withValues(alpha: 0.4), blurRadius: 12)] : null,
                ),
                child: Icon(
                  i < current && valid[i] ? Icons.check_rounded : (i < current ? Icons.priority_high_rounded : _steps[i].$2),
                  size: 18,
                  color: i <= current ? Colors.white : Brand.grey,
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 6),
                Text(_steps[i].$1, style: TextStyle(fontSize: 12, fontWeight: i == current ? FontWeight.w800 : FontWeight.w500, color: i == current ? null : Brand.grey)),
              ],
            ]),
          ),
        ],
      ]);
    }).animate().fadeIn(duration: 250.ms);
  }
}
