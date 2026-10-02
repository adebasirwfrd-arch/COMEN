import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/errors/app_failure.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../core/session/contract_classification.dart';
import '../../data/api.dart';
import '../../ui/classification_badges.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../contracts/contract_common.dart';
import '../vendors/vendor_common.dart';

const _taskCols = 'id,task_id,status,phase,title,doc_type_code,doc_label,contractor_id,due_date,is_mandatory,is_blocker,expiry_date,is_overdue,created_at,updated_at';
final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _phoneRe = RegExp(r'^\+?[0-9 ()-]{6,20}$');

class _Data {
  _Data(this.c, this.tasks, this.sa);
  final J c;
  final List<J> tasks, sa;
  String get status => c['status'] as String? ?? 'draft';
}

/// Perusahaan saya (kontraktor): status ASL, data perusahaan, dokumen vendor, self-assessment, kontrak, user.
class MyCompanyPage extends ConsumerStatefulWidget {
  const MyCompanyPage({super.key});
  @override
  ConsumerState<MyCompanyPage> createState() => _MyCompanyPageState();
}

class _MyCompanyPageState extends ConsumerState<MyCompanyPage> {
  late Future<_Data> _future = _load();
  StreamSubscription<String>? _sub;
  bool _saEditing = false;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(notificationBus).stream.listen((_) {
      if (mounted && !_saEditing) _reload();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<_Data> _load() async {
    final s = readSession(ref);
    final cid = s?.contractorId;
    if (cid == null) throw const AppFailure(Hint.forbidden, 'Akun Anda belum tertaut ke perusahaan kontraktor.');
    final api = ref.read(apiProvider);
    final r = await Future.wait<dynamic>([
      api.rpcMap('get_contractor_detail', {'p_contractor': cid}),
      api.select('v_task_tracking', _taskCols, build: (q) => q.eq('contractor_id', cid).eq('scope', 'vendor').order('due_date')),
      api.select('self_assessments', 'id,period_year,answers,computed,status,submitted_at,updated_at',
          build: (q) => q.eq('contractor_id', cid).order('period_year', ascending: false)),
    ]);
    return _Data(r[0] as J, r[1] as List<J>, r[2] as List<J>);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _edit(J c) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _EditCompanyDialog(c: c));
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref);
    final canEdit = s?.can('company.edit') ?? false;
    return AsyncView<_Data>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) {
        final c = d.c;
        return PageScaffold(
          title: 'Perusahaan saya',
          subtitle: '${str(c['legal_name'])} · ${str(c['vendor_ref'], vendorRef(c['vendor_seq']))}',
          actions: [
            if (canEdit && d.status != 'draft')
              FilledButton.tonalIcon(onPressed: () => _edit(c), icon: const Icon(Icons.edit_rounded), label: const Text('Ubah data')),
            IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _hero(d),
            const SizedBox(height: 16),
            ..._banners(d),
            LayoutBuilder(builder: (context, box) {
              final wide = box.maxWidth >= 1100;
              final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                VendorTasksCard(tasks: d.tasks),
                const SizedBox(height: 16),
                _SelfAssessmentSection(
                  data: d,
                  canEdit: canEdit && d.status != 'draft',
                  onChanged: _reload,
                  onEditing: (v) => _saEditing = v,
                ),
                const SizedBox(height: 16),
                CompanyProfileCard(
                  c: c,
                  trailing: canEdit && d.status != 'draft' ? IconButton(tooltip: 'Ubah data', onPressed: () => _edit(c), icon: const Icon(Icons.edit_rounded)) : null,
                ),
              ]);
              final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AslStatusCard(c: c),
                const SizedBox(height: 16),
                ContractMiniList(contracts: jl(c['contracts']), emptyMessage: 'Kontrak muncul setelah Weatherford memberikan award.'),
                const SizedBox(height: 16),
                _UsersCard(s: s),
              ]);
              if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [right, const SizedBox(height: 16), left]);
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 3, child: left),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: right),
              ]);
            }),
          ]),
        );
      },
    );
  }

  Widget _hero(_Data d) {
    final c = d.c;
    final (color, label) = StatusStyle.vendor(d.status);
    final days = aslDaysLeft(c);
    final mandatory = d.tasks.where((t) => t['is_mandatory'] == true && !const {'superseded', 'cancelled'}.contains(t['status'])).toList();
    final done = mandatory.where((t) => const {'approved', 'waived'}.contains(t['status'])).length;
    return HeroHeader(
      title: str(c['legal_name']),
      icon: Icons.apartment_rounded,
      lines: [
        if (c['trading_name'] != null) c['trading_name'] as String,
        '${countryLabel(c['country'])} · NPWP ${str(c['tax_id'])}',
      ],
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w900)),
      ),
      chips: [
        HeroChip(str(c['vendor_ref'], vendorRef(c['vendor_seq'])), icon: Icons.tag_rounded),
        if (days != null && d.status != 'rejected') HeroChip(days < 0 ? 'ASL lewat ${-days} hari' : 'ASL s.d. ${fmtDate(c['asl_expires_on'])}', icon: Icons.verified_user_rounded),
        HeroChip('Dokumen $done/${mandatory.length}', icon: Icons.folder_special_rounded),
        HeroChip('${jl(c['contracts']).length} kontrak', icon: Icons.handshake_rounded),
      ],
    );
  }

  List<Widget> _banners(_Data d) {
    final out = <Widget>[];
    void add(Widget w) => out.addAll([w, const SizedBox(height: 12)]);
    final reason = d.c['status_reason'] as String?;
    switch (d.status) {
      case 'draft':
        add(InfoBanner(
          color: Brand.amber,
          icon: Icons.edit_document,
          message: reason == null ? 'Registrasi perusahaan belum dikirim.' : 'Weatherford meminta informasi tambahan: $reason',
          action: FilledButton(onPressed: () => context.go('/register'), child: const Text('Lengkapi registrasi')),
        ));
      case 'under_review':
        add(const InfoBanner(
          icon: Icons.hourglass_top_rounded,
          message: 'Registrasi sedang direview. Lengkapi dokumen legal vendor dan kirim HSE self-assessment agar screening bisa dilakukan.',
        ));
      case 'rejected':
        add(InfoBanner(color: Brand.red, icon: Icons.cancel_rounded, message: 'Pengajuan ASL ditolak${reason == null ? '' : ': $reason'}'));
      case 'suspended' || 'blacklisted':
        add(InfoBanner(color: Brand.red, icon: Icons.block_rounded, message: 'Status vendor ${StatusStyle.vendor(d.status).$2}${reason == null ? '' : ': $reason'}. Hubungi Procurement Weatherford.'));
      case 'asl_expired':
        add(const InfoBanner(color: Brand.red, icon: Icons.event_busy_rounded, message: 'ASL kedaluwarsa. Kirim self-assessment tahun berjalan untuk re-evaluasi.'));
    }
    final days = aslDaysLeft(d.c);
    if (aslActiveStatuses.contains(d.status) && days != null && days >= 0 && days <= 60) {
      add(InfoBanner(color: Brand.amber, icon: Icons.schedule_rounded, message: 'ASL berakhir dalam $days hari — siapkan re-evaluasi.'));
    }
    return out;
  }
}

// ─────────────────────────── Users ───────────────────────────
class _UsersCard extends ConsumerStatefulWidget {
  const _UsersCard({required this.s});
  final SessionState? s;
  @override
  ConsumerState<_UsersCard> createState() => _UsersCardState();
}

class _UsersCardState extends ConsumerState<_UsersCard> {
  late final Future<List<J>> _users = ref.read(apiProvider).rpcList('list_contractor_users').catchError((_) => const <J>[]);
  static const _roleLabel = {'contractor_rep': 'Contractor Representative', 'contractor_viewer': 'Contractor Viewer'};

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return SectionCard(
      title: 'User perusahaan',
      subtitle: s?.contractorLevel == null ? null : 'Level Anda: ${s!.contractorLevel!.label} — ${s.contractorLevel!.description}',
      icon: Icons.people_alt_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FutureBuilder<List<J>>(
          future: _users,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()));
            final users = snap.data ?? const <J>[];
            return Column(children: [
              for (final u in users)
                UserCardTile(
                  dense: true,
                  card: {'id': u['id'], 'full_name': u['full_name'] ?? u['email'], 'avatar_url': u['avatar_url'], 'job_title': u['job_title'] ?? u['email']},
                  caption: u['id'] == s?.userId ? 'Anda' : str(u['email'], ''),
                  trailing: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (ContractorUserLevel.tryCode(u['level'] as String?) case final lv?) LevelBadge(lv),
                    for (final r in jl(u['roles'])) StatusBadge(Brand.blue, _roleLabel[r['role']] ?? str(r['role'])),
                    if (u['status'] != 'active') StatusBadge.account(u['status'] as String?),
                  ]),
                ),
            ]);
          },
        ),
        const SizedBox(height: 8),
        const InfoBanner(
          icon: Icons.admin_panel_settings_outlined,
          message: 'Penambahan / penonaktifan user dan penetapan level (PIC / Supervisor / Employee) dilakukan oleh Admin Weatherford. '
              'Rekan kerja dapat mendaftar dengan email domain perusahaan lalu menunggu persetujuan.',
        ),
      ]),
    );
  }
}

// ─────────────────────────── Edit perusahaan ───────────────────────────
class _EditCompanyDialog extends ConsumerStatefulWidget {
  const _EditCompanyDialog({required this.c});
  final J c;
  @override
  ConsumerState<_EditCompanyDialog> createState() => _EditCompanyDialogState();
}

class _EditCompanyDialogState extends ConsumerState<_EditCompanyDialog> {
  late final _ctl = {
    for (final k in const ['trading_name', 'address', 'website', 'primary_contact_name', 'primary_contact_email', 'primary_contact_phone', 'hse_manager_name', 'hse_manager_email'])
      k: TextEditingController(text: widget.c[k] as String?),
  };
  bool _busy = false;

  String _v(String k) => _ctl[k]!.text.trim();

  String? _err(String k) {
    final v = _v(k);
    switch (k) {
      case 'address' || 'primary_contact_name' || 'hse_manager_name':
        return v.length < 2 ? 'Wajib diisi' : null;
      case 'primary_contact_email' || 'hse_manager_email':
        return _emailRe.hasMatch(v) ? null : 'Email tidak valid';
      case 'primary_contact_phone':
        return _phoneRe.hasMatch(v) ? null : 'Format: +62 21 555-0100';
      case 'website':
        return v.isEmpty || RegExp(r'^https?://').hasMatch(v) ? null : 'Awali dengan https://';
    }
    return null;
  }

  Future<void> _submit() async {
    final patch = <String, dynamic>{};
    for (final e in _ctl.entries) {
      final v = e.value.text.trim();
      if (v == ((widget.c[e.key] as String?) ?? '')) continue;
      patch[e.key] = v.isEmpty ? null : v;
    }
    if (patch.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    setState(() => _busy = true);
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('update_my_company', {'p_data': patch}), success: 'Data perusahaan diperbarui');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  Widget _field(String k, String label, {IconData? icon, int maxLines = 1, int? maxLength, TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _ctl[k],
          maxLines: maxLines,
          maxLength: maxLength,
          keyboardType: type,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: label, prefixIcon: icon == null ? null : Icon(icon), errorText: _v(k).isEmpty && !label.endsWith('*') ? null : _err(k)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final valid = _ctl.keys.every((k) => _err(k) == null);
    final wide = MediaQuery.sizeOf(context).width >= 700;
    Widget pair(Widget a, Widget b) => wide ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)]) : Column(children: [a, b]);
    return AlertDialog(
      title: const Text('Ubah data perusahaan'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const InfoBanner(
              icon: Icons.lock_outline_rounded,
              message: 'Nama legal, NIB, NPWP, dan negara hanya bisa diubah Weatherford (hubungi Procurement).',
            ),
            const SizedBox(height: 16),
            pair(_field('trading_name', 'Nama dagang', icon: Icons.storefront_outlined, maxLength: 200), _field('website', 'Website', icon: Icons.language_rounded, type: TextInputType.url)),
            _field('address', 'Alamat *', icon: Icons.place_outlined, maxLines: 3, maxLength: 500),
            const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Kontak utama', style: TextStyle(fontWeight: FontWeight.w800))),
            _field('primary_contact_name', 'Nama *', icon: Icons.person_outline_rounded),
            pair(
              _field('primary_contact_email', 'Email *', icon: Icons.email_outlined, type: TextInputType.emailAddress),
              _field('primary_contact_phone', 'Telepon *', icon: Icons.phone_outlined, type: TextInputType.phone),
            ),
            const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('HSE Manager', style: TextStyle(fontWeight: FontWeight.w800))),
            pair(
              _field('hse_manager_name', 'Nama *', icon: Icons.health_and_safety_outlined),
              _field('hse_manager_email', 'Email *', icon: Icons.email_outlined, type: TextInputType.emailAddress),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: valid && !_busy ? _submit : null,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_rounded),
          label: const Text('Simpan'),
        ),
      ],
    );
  }
}

// ─────────────────────────── Self-assessment ───────────────────────────
const _perfFields = [
  ('man_hours', 'Man-hours'),
  ('km', 'Km kendaraan'),
  ('recordable', 'Recordable'),
  ('lti', 'LTI'),
  ('pvi', 'PVI'),
  ('fatality', 'Fatality'),
];

const _boolQuestions = <String, List<(String, String)>>{
  'safety': [
    ('hse_policy', 'Memiliki HSE Policy tertulis & ditandatangani direksi (→ HSEPOL)'),
    ('hse_manager_fulltime', 'HSE Manager full-time'),
    ('bbs_program', 'Program Behavior-Based Safety (BBS) berjalan'),
    ('incident_reporting', 'Prosedur pelaporan & investigasi insiden'),
  ],
  'training': [('training_matrix', 'Memiliki training matrix (→ TRNSMP)')],
  'equipment': [
    ('certified', 'Equipment bersertifikat / inspeksi pihak ketiga (→ EQPLST)'),
    ('preventive_maintenance', 'Program preventive maintenance'),
  ],
  'insurance': [
    ('public_liability', 'Asuransi Public Liability aktif (→ INSCRT)'),
    ('workers_comp', 'Asuransi Workers Compensation / BPJS Ketenagakerjaan'),
  ],
  'legal': [
    ('ISOCRT', 'Sertifikat ISO 45001 / 14001 / 9001'),
    ('K3DSNK', 'Izin / sertifikasi K3 Disnaker'),
    ('SMK3XX', 'Sertifikat SMK3'),
    ('CLNREF', 'Clean reference dari klien sebelumnya'),
    ('FINSTM', 'Laporan keuangan teraudit'),
  ],
};

const _numQuestions = <String, List<(String, String, String)>>{
  'safety': [('ca_close_days', 'Rata-rata waktu tutup corrective action', 'hari')],
  'training': [
    ('certified_count', 'Jumlah pekerja tersertifikasi', 'orang'),
    ('first_aid_pct', 'Pekerja terlatih First Aid', '%'),
    ('h2s_pct', 'Pekerja terlatih H2S', '%'),
  ],
  'equipment': [('equipment_count', 'Jumlah unit equipment utama', 'unit')],
};

const _sectionTitles = {
  'safety': ('A', 'Safety management', Icons.health_and_safety_rounded),
  'training': ('B', 'Training', Icons.school_rounded),
  'performance': ('C', 'Performa 3 tahun terakhir', Icons.query_stats_rounded),
  'equipment': ('D', 'Equipment', Icons.precision_manufacturing_rounded),
  'insurance': ('E', 'Asuransi', Icons.shield_rounded),
  'legal': ('F', 'Legal', Icons.gavel_rounded),
};

class _SelfAssessmentSection extends ConsumerStatefulWidget {
  const _SelfAssessmentSection({required this.data, required this.canEdit, required this.onChanged, required this.onEditing});
  final _Data data;
  final bool canEdit;
  final VoidCallback onChanged;
  final ValueChanged<bool> onEditing;
  @override
  ConsumerState<_SelfAssessmentSection> createState() => _SelfAssessmentSectionState();
}

class _SelfAssessmentSectionState extends ConsumerState<_SelfAssessmentSection> {
  final int _year = DateTime.now().year;
  final Map<String, TextEditingController> _num = {};
  final Map<String, bool> _bool = {};
  final _notes = TextEditingController();
  DateTime? _insExpiry;
  bool _editing = false, _busy = false, _dirty = false;
  DateTime? _savedAt;
  Timer? _debounce;

  J? get _current => widget.data.sa.where((x) => x['period_year'] == _year).firstOrNull;
  bool get _submitted => _current?['status'] == 'submitted';

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  void _setEditing(bool v) {
    if (!mounted) return;
    setState(() => _editing = v);
    widget.onEditing(v);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.onEditing(false);
    for (final c in _num.values) {
      c.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  TextEditingController _c(String key) => _num.putIfAbsent(key, TextEditingController.new);

  void _hydrate() {
    final a = jm(_current?['answers']);
    for (final e in _boolQuestions.entries) {
      final sec = jm(a[e.key]);
      for (final (k, _) in e.value) {
        _bool['${e.key}.$k'] = sec[k] == true;
      }
    }
    for (final e in _numQuestions.entries) {
      final sec = jm(a[e.key]);
      for (final (k, _, _) in e.value) {
        _c('${e.key}.$k').text = sec[k]?.toString() ?? '';
      }
    }
    final perf = jm(a['performance']);
    for (final y in const ['y1', 'y2', 'y3']) {
      final row = jm(perf[y]);
      for (final (k, _) in _perfFields) {
        _c('performance.$y.$k').text = row[k]?.toString() ?? '';
      }
    }
    _insExpiry = parseDate(jm(a['insurance'])['expiry']);
    _notes.text = a['notes'] as String? ?? '';
    _savedAt = parseDate(_current?['updated_at']);
  }

  num? _n(String key) => num.tryParse((_num[key]?.text ?? '').replaceAll(',', '.').trim());

  J _answers() {
    final out = <String, dynamic>{};
    for (final e in _boolQuestions.entries) {
      final sec = (out[e.key] ??= <String, dynamic>{}) as Map<String, dynamic>;
      for (final (k, _) in e.value) {
        sec[k] = _bool['${e.key}.$k'] ?? false;
      }
    }
    for (final e in _numQuestions.entries) {
      final sec = (out[e.key] ??= <String, dynamic>{}) as Map<String, dynamic>;
      for (final (k, _, _) in e.value) {
        sec[k] = _n('${e.key}.$k');
      }
    }
    out['performance'] = {
      for (final y in const ['y1', 'y2', 'y3'])
        y: {for (final (k, _) in _perfFields) k: _n('performance.$y.$k') ?? 0},
    };
    (out['insurance'] as Map<String, dynamic>)['expiry'] = _insExpiry == null ? null : isoDate(_insExpiry!);
    out['notes'] = _notes.text.trim();
    out['period_labels'] = {'y1': _year - 1, 'y2': _year - 2, 'y3': _year - 3};
    return out;
  }

  void _touch() {
    setState(() => _dirty = true);
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () {
      if (mounted && _dirty && !_busy) _save(silent: true);
    });
  }

  Future<bool> _save({bool silent = false}) async {
    _debounce?.cancel();
    setState(() => _busy = true);
    final ok = await runOk(
      context,
      ref,
      () => ref.read(apiProvider).rpc('save_self_assessment', {'p_year': _year, 'p_answers': _answers()}),
      success: silent ? null : 'Draft self-assessment disimpan',
    );
    if (!mounted) return ok;
    setState(() {
      _busy = false;
      if (ok) {
        _dirty = false;
        _savedAt = DateTime.now();
      }
    });
    return ok;
  }

  List<String> _problems() => [
        for (final y in const ['y1', 'y2', 'y3'])
          if ((_n('performance.$y.man_hours') ?? 0) <= 0) 'Man-hours ${_year - int.parse(y.substring(1))} wajib > 0',
      ];

  Future<void> _submit() async {
    final p = _problems();
    if (p.isNotEmpty) {
      showSnack(context, p.first);
      return;
    }
    final go = await showConfirm(
      context,
      title: 'Kirim self-assessment $_year?',
      message: 'Setelah dikirim, jawaban tidak bisa diubah. TRIR/LTIR/PVIR dihitung sistem dan tim HSE Weatherford akan melakukan screening.',
      confirmLabel: 'Kirim',
    );
    if (!go || !mounted) return;
    if (!await _save(silent: true) || !mounted) return;
    setState(() => _busy = true);
    final r = await runAction<J>(context, ref, () => ref.read(apiProvider).rpcMap('submit_self_assessment', {'p_year': _year}), success: 'Self-assessment terkirim');
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) {
      _setEditing(false);
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.data.sa.map((x) => <String, dynamic>{...x, 'year': x['period_year']}).toList();
    final canStart = widget.canEdit && !_submitted;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SelfAssessmentCard(
        items: history,
        emptyMessage: canStart ? 'Isi self-assessment tahun $_year untuk proses screening & ASL.' : null,
        trailing: canStart && !_editing
            ? FilledButton.icon(
                onPressed: () => _setEditing(true),
                icon: Icon(_current == null ? Icons.add_rounded : Icons.edit_note_rounded),
                label: Text(_current == null ? 'Isi $_year' : 'Lanjutkan draft $_year'),
              )
            : null,
      ),
      if (_editing && canStart) ...[const SizedBox(height: 16), _form()],
    ]);
  }

  Widget _form() {
    final t = Theme.of(context).textTheme;
    Widget header(String key) {
      final (letter, title, icon) = _sectionTitles[key]!;
      return Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Row(children: [
          CircleAvatar(radius: 14, backgroundColor: Brand.blue.withValues(alpha: 0.12), child: Text(letter, style: const TextStyle(fontWeight: FontWeight.w900, color: Brand.blue, fontSize: 13))),
          const SizedBox(width: 10),
          Icon(icon, size: 18, color: Brand.blue),
          const SizedBox(width: 6),
          Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
        ]),
      );
    }

    Widget bools(String sec) => Column(children: [
          for (final (k, label) in _boolQuestions[sec] ?? const <(String, String)>[])
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _bool['$sec.$k'] ?? false,
              onChanged: (v) {
                _bool['$sec.$k'] = v ?? false;
                _touch();
              },
              title: Text(label),
            ),
        ]);

    Widget nums(String sec) => Wrap(spacing: 12, runSpacing: 12, children: [
          for (final (k, label, unit) in _numQuestions[sec] ?? const <(String, String, String)>[])
            SizedBox(
              width: 260,
              child: TextField(
                controller: _c('$sec.$k'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                onChanged: (_) => _touch(),
                decoration: InputDecoration(isDense: true, labelText: label, suffixText: unit),
              ),
            ),
        ]);

    String rate(String y, List<String> nums, double factor, String base) {
      final b = _n('performance.$y.$base') ?? 0;
      if (b <= 0) return '—';
      final sum = nums.fold<num>(0, (a, k) => a + (_n('performance.$y.$k') ?? 0));
      return (sum * factor / b).toStringAsFixed(2);
    }

    return SectionCard(
      title: 'Self-assessment $_year',
      subtitle: 'Draft tersimpan otomatis · kirim setelah semua bagian lengkap',
      icon: Icons.edit_note_rounded,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (_busy)
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Text(_dirty ? 'Belum disimpan' : (_savedAt == null ? '' : 'Tersimpan ${fmtRelative(_savedAt!.toIso8601String())}'),
              style: TextStyle(fontSize: 12, color: _dirty ? Brand.amber : Brand.grey)),
        IconButton(
          tooltip: 'Tutup',
          onPressed: () async {
            if (_dirty && !await _save(silent: true)) return;
            _setEditing(false);
          },
          icon: const Icon(Icons.close_rounded),
        ),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header('safety'),
        bools('safety'),
        nums('safety'),
        header('training'),
        nums('training'),
        bools('training'),
        header('performance'),
        Text('TRIR = (recordable + fatality) × 200.000 / man-hours · LTIR = (LTI + fatality) × 200.000 / man-hours · PVIR = PVI × 1.000.000 / km. Nilai final dihitung server.',
            style: t.bodySmall),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 12,
            headingRowHeight: 40,
            dataRowMinHeight: 56,
            dataRowMaxHeight: 60,
            columns: [
              const DataColumn(label: Text('Tahun')),
              for (final (_, l) in _perfFields) DataColumn(label: Text(l)),
              const DataColumn(label: Text('TRIR')),
              const DataColumn(label: Text('LTIR')),
              const DataColumn(label: Text('PVIR')),
            ],
            rows: [
              for (final y in const ['y1', 'y2', 'y3'])
                DataRow(cells: [
                  DataCell(Text('${_year - int.parse(y.substring(1))}', style: const TextStyle(fontWeight: FontWeight.w800))),
                  for (final (k, _) in _perfFields)
                    DataCell(SizedBox(
                      width: k == 'man_hours' || k == 'km' ? 110 : 64,
                      child: TextField(
                        controller: _c('performance.$y.$k'),
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        onChanged: (_) => _touch(),
                        decoration: const InputDecoration(isDense: true, hintText: '0'),
                      ),
                    )),
                  DataCell(Text(rate(y, const ['recordable', 'fatality'], 200000, 'man_hours'), style: const TextStyle(fontWeight: FontWeight.w800))),
                  DataCell(Text(rate(y, const ['lti', 'fatality'], 200000, 'man_hours'))),
                  DataCell(Text(rate(y, const ['pvi'], 1000000, 'km'))),
                ]),
            ],
          ),
        ),
        header('equipment'),
        bools('equipment'),
        nums('equipment'),
        header('insurance'),
        bools('insurance'),
        SizedBox(
          width: 260,
          child: DateField(
            label: 'Masa berlaku asuransi',
            value: _insExpiry,
            onTap: () async {
              final d = await pickDate(context, initial: _insExpiry);
              if (d != null) {
                _insExpiry = d;
                _touch();
              }
            },
            onClear: () {
              _insExpiry = null;
              _touch();
            },
          ),
        ),
        header('legal'),
        bools('legal'),
        const SizedBox(height: 12),
        TextField(
          controller: _notes,
          maxLines: 3,
          maxLength: 4000,
          onChanged: (_) => _touch(),
          decoration: const InputDecoration(labelText: 'Catatan tambahan'),
        ),
        const SizedBox(height: 8),
        const InfoBanner(
          icon: Icons.upload_file_rounded,
          message: 'Dokumen pendukung (HSEPOL, TRNSMP, OSHLOG, EQPLST, INSCRT, dokumen legal) diunggah lewat task dokumen vendor masing-masing.',
        ),
        const SizedBox(height: 16),
        Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: _busy ? null : () => _save(), icon: const Icon(Icons.save_rounded), label: const Text('Simpan draft')),
          FilledButton.icon(onPressed: _busy ? null : _submit, icon: const Icon(Icons.send_rounded), label: const Text('Kirim self-assessment')),
        ]),
      ]),
    );
  }
}
