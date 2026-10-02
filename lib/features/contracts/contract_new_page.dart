import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../core/session/contract_classification.dart';
import '../../data/columns.dart';
import '../../ui/classification_badges.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'contract_common.dart';

class _Refs {
  _Refs(this.contractors, this.geozones);
  final List<J> contractors, geozones;
}

class ContractNewPage extends ConsumerStatefulWidget {
  const ContractNewPage({super.key});
  @override
  ConsumerState<ContractNewPage> createState() => _ContractNewPageState();
}

class _ContractNewPageState extends ConsumerState<ContractNewPage> {
  late Future<_Refs> _future = _load();
  final _title = TextEditingController();
  final _scope = TextEditingController();
  final _site = TextEditingController();
  final _mailbox = TextEditingController();
  final _oversight = TextEditingController();
  ContractMode _mode = ContractMode.mode1;
  String? _contractorId, _geozone;
  String _risk = 'medium';
  DateTime? _start, _end, _mob;
  DateTime _awarded = DateTime.now();
  J? _po, _reviewer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final s = readSession(ref);
    if (s != null && s.roles.any((r) => r['key'] == 'process_owner')) {
      _po = {'id': s.userId, 'full_name': s.fullName ?? s.email, 'avatar_url': s.avatarUrl};
    }
  }

  Future<_Refs> _load() async {
    final api = ref.read(apiProvider);
    final today = isoDate(DateTime.now());
    final r = await Future.wait([
      api.select('contractors', Cols.contractors,
          build: (q) => q.inFilter('status', ['asl_approved', 'asl_conditional']).gte('asl_expires_on', today).order('legal_name').limit(500)),
      api.select('geozones', 'code,name,review_mailbox,timezone,active', build: (q) => q.eq('active', true).order('code')),
    ]);
    final gz = r[1];
    if (_geozone == null && gz.length == 1) _geozone = gz.first['code'] as String;
    return _Refs(r[0], gz);
  }

  void _reload() => setState(() => _future = _load());

  int? get _days => _start == null || _end == null ? null : contractDurationDays(_start!, _end!);
  AccessTier? get _tier => _days == null || _days! < 0 ? null : AccessTier.resolve(_mode, _days!);

  List<String> _problems() => [
        if (_contractorId == null) 'Pilih contractor',
        if (_title.text.trim().length < 3) 'Judul minimal 3 karakter',
        if (_geozone == null) 'Pilih geozone',
        if (_start == null || _end == null || _mob == null) 'Lengkapi tanggal mulai, selesai & target mobilisasi',
        if (_start != null && _end != null && _end!.isBefore(_start!)) 'Tanggal selesai harus ≥ tanggal mulai',
        if (_mob != null && _end != null && (_mob!.isAfter(_end!) || _mob!.isBefore(DateTime(_awarded.year, _awarded.month, _awarded.day))))
          'Target mobilisasi harus di antara tanggal award dan tanggal selesai',
        if (_mode == ContractMode.mode3 && _oversight.text.trim().length < 20) 'Mode 3 wajib catatan HSE oversight (min. 20 karakter)',
        if (_po == null) 'Pilih Process Owner',
        if (_reviewer == null) 'Pilih HSE Reviewer',
        if (_mailbox.text.trim().isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_mailbox.text.trim())) 'Format mailbox review tidak valid',
      ];

  Future<void> _submit() async {
    setState(() => _busy = true);
    final id = await runAction<dynamic>(
      context,
      ref,
      () => ref.read(apiProvider).rpc('create_contract', {
        'p_contractor': _contractorId,
        'p_title': _title.text.trim(),
        'p_scope_of_work': trimOrNull(_scope),
        'p_geozone': _geozone,
        'p_site': trimOrNull(_site),
        'p_risk_class': _risk,
        'p_start': isoDate(_start!),
        'p_end': isoDate(_end!),
        'p_target_mob': isoDate(_mob!),
        'p_awarded_at': isoDate(_awarded),
        'p_process_owner': _po!['id'],
        'p_hse_reviewer': _reviewer!['id'],
        'p_review_mailbox': trimOrNull(_mailbox),
        'p_contract_mode': _mode.code,
        'p_hse_oversight_notes': trimOrNull(_oversight),
      }),
      success: 'Kontrak dibuat · task post-award & channel kontrak disiapkan',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (id is String) context.go('/contracts/$id');
  }

  Future<void> _date(String which) async {
    final now = DateTime.now();
    final d = await pickDate(
      context,
      initial: switch (which) { 'start' => _start, 'end' => _end ?? _start, 'mob' => _mob ?? _start, _ => _awarded },
      first: DateTime(now.year - 2),
      last: DateTime(now.year + 15),
    );
    if (d == null) return;
    setState(() {
      switch (which) {
        case 'start':
          _start = d;
        case 'end':
          _end = d;
        case 'mob':
          _mob = d;
        default:
          _awarded = d;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Kontrak baru',
      subtitle: 'Award kontrak ke vendor ASL aktif · Fase 2 (Award + Post-Award)',
      maxWidth: 1200,
      leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.canPop() ? context.pop() : context.go('/contracts')),
      child: AsyncView<_Refs>(
        future: _future,
        onRetry: _reload,
        builder: (context, refs) {
          if (refs.contractors.isEmpty) {
            return SectionCard(
              child: EmptyState(
                icon: Icons.verified_user_outlined,
                title: 'Belum ada vendor dengan ASL aktif',
                message: 'Kontrak hanya bisa dibuat untuk vendor berstatus ASL Approved/Conditional yang belum kedaluwarsa (R5).',
                action: OutlinedButton.icon(onPressed: () => context.go('/vendors'), icon: const Icon(Icons.apartment_rounded), label: const Text('Lihat vendor')),
              ),
            );
          }
          final form = _form(refs);
          final summary = _summary(refs);
          return LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 1000
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: form), const SizedBox(width: 20), Expanded(flex: 2, child: summary)])
                : Column(children: [form, const SizedBox(height: 16), summary]),
          );
        },
      ),
    );
  }

  Widget _form(_Refs refs) {
    final gz = refs.geozones.where((g) => g['code'] == _geozone).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        title: 'Contractor & lingkup',
        icon: Icons.apartment_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(
            initialValue: _contractorId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Contractor (ASL aktif) *', prefixIcon: Icon(Icons.verified_rounded)),
            items: [
              for (final c in refs.contractors)
                DropdownMenuItem(
                  value: c['id'] as String,
                  child: Row(children: [
                    Expanded(child: Text('${c['legal_name']}', overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Text(vendorRef(c['vendor_seq']), style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Brand.grey)),
                  ]),
                ),
            ],
            onChanged: (v) => setState(() => _contractorId = v),
          ),
          const SizedBox(height: 12),
          TextField(controller: _title, maxLength: 200, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Judul kontrak *')),
          const SizedBox(height: 4),
          TextField(controller: _scope, maxLines: 4, maxLength: 8000, decoration: const InputDecoration(labelText: 'Scope of work', alignLabelWithHint: true)),
        ]),
      ),
      const SizedBox(height: 16),
      _modeCard(),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Lokasi & risiko',
        icon: Icons.place_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ResponsiveGrid(minItemWidth: 240, spacing: 12, children: [
            DropdownButtonFormField<String>(
              initialValue: _geozone,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Geozone *', prefixIcon: Icon(Icons.public_rounded)),
              items: [for (final g in refs.geozones) DropdownMenuItem(value: g['code'] as String, child: Text('${g['code']} · ${g['name']}'))],
              onChanged: (v) => setState(() => _geozone = v),
            ),
            TextField(controller: _site, decoration: const InputDecoration(labelText: 'Site / lokasi kerja', prefixIcon: Icon(Icons.factory_outlined))),
          ]),
          const SizedBox(height: 16),
          Text('Kelas risiko *', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'low', label: Text('Rendah'), icon: Icon(Icons.shield_outlined)),
              ButtonSegment(value: 'medium', label: Text('Sedang'), icon: Icon(Icons.shield_rounded)),
              ButtonSegment(value: 'high', label: Text('Tinggi'), icon: Icon(Icons.gpp_maybe_rounded)),
            ],
            selected: {_risk},
            onSelectionChanged: (v) => setState(() => _risk = v.first),
          ),
          const SizedBox(height: 6),
          Text('Kelas risiko menentukan dokumen pre-mob kondisional (rules engine).', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Jadwal',
        icon: Icons.event_note_rounded,
        child: ResponsiveGrid(minItemWidth: 220, spacing: 12, children: [
          DateField(label: 'Tanggal award', value: _awarded, onTap: () => _date('award')),
          DateField(label: 'Tanggal mulai *', value: _start, onTap: () => _date('start')),
          DateField(label: 'Target mobilisasi *', value: _mob, onTap: () => _date('mob')),
          DateField(label: 'Tanggal selesai *', value: _end, onTap: () => _date('end')),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Penanggung jawab WFRD',
        icon: Icons.badge_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ResponsiveGrid(minItemWidth: 260, spacing: 12, children: [
            UserPickField(
              label: 'Process Owner *',
              value: _po,
              helper: 'Role process_owner · approve Go-Live',
              onPick: () async {
                final u = await pickWfrdUser(context, title: 'Pilih Process Owner', roleKeys: const {'process_owner'});
                if (u != null) setState(() => _po = u);
              },
            ),
            UserPickField(
              label: 'HSE Reviewer *',
              value: _reviewer,
              helper: 'Role hse_reviewer / hse_admin',
              onPick: () async {
                final u = await pickWfrdUser(context, title: 'Pilih HSE Reviewer', roleKeys: const {'hse_reviewer', 'hse_admin'});
                if (u != null) setState(() => _reviewer = u);
              },
            ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _mailbox,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'Mailbox review (opsional)',
              prefixIcon: const Icon(Icons.alternate_email_rounded),
              helperText: gz == null ? 'Kosong = default geozone' : 'Kosong = default geozone: ${gz['review_mailbox']}',
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _modeCard() {
    final t = Theme.of(context);
    return SectionCard(
      title: 'Mode kontrak',
      subtitle: 'Siapa yang mengelola HSE selama operasi (GL-WFT-OEPS-L3-78). Bersama durasi menentukan kategori kontrak.',
      icon: Icons.account_tree_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final m in ContractMode.values) ...[
          _ModeOption(mode: m, selected: _mode == m, onTap: () => setState(() => _mode = m)),
          const SizedBox(height: 10),
        ],
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: _mode != ContractMode.mode3
              ? const SizedBox(width: double.infinity)
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const SizedBox(height: 4),
                  TextField(
                    controller: _oversight,
                    maxLines: 3,
                    maxLength: 2000,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Catatan HSE oversight *',
                      alignLabelWithHint: true,
                      helperText: 'Dasar pengakuan HSE-MS contractor (mis. sertifikasi ISO 45001, hasil audit) · min. 20 karakter',
                    ),
                  ),
                  Text('Mode 3 tidak boleh memakai subcontractor. Kontrak ≤ 90 hari menjadi kategori Visitor (tanpa submission dokumen).',
                      style: t.textTheme.bodySmall?.copyWith(color: Brand.amber)),
                ]),
        ),
      ]),
    );
  }

  Widget _tierPreview() {
    final tier = _tier;
    final days = _days;
    if (tier == null) {
      return const InfoBanner(message: 'Isi tanggal mulai & selesai untuk melihat kategori kontrak.', icon: Icons.info_outline_rounded);
    }
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Kategori kontrak (otomatis)', style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          ModeBadge(_mode),
          DurationBadge(DurationCategory.fromDays(days!), days: days),
          TierBadge(tier),
        ]),
        const SizedBox(height: 10),
        Text(tier.description, style: t.textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text('SLA review ${tier.reviewSlaDays} hari kerja · target BBS ${tier.bbsPerWeek}/minggu', style: t.textTheme.bodySmall),
      ]),
    );
  }

  Widget _summary(_Refs refs) {
    final c = refs.contractors.where((x) => x['id'] == _contractorId).firstOrNull;
    final problems = _problems();
    final ok = problems.isEmpty && !_busy;
    return SectionCard(
      title: 'Ringkasan',
      icon: Icons.fact_check_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(gradient: Brand.heroGradient, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('CTR-… (otomatis)', style: TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 4),
            Text(_title.text.trim().isEmpty ? 'Judul kontrak' : _title.text.trim(),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 4),
            Text(str(c?['legal_name'], 'Contractor belum dipilih'), style: const TextStyle(color: Colors.white70)),
          ]),
        ),
        const SizedBox(height: 12),
        if (c != null)
          Wrap(spacing: 8, runSpacing: 6, children: [
            StatusBadge.vendor(c['status'] as String?),
            StatusBadge(Brand.grey, 'ASL s/d ${fmtDate(c['asl_expires_on'])}', icon: Icons.event_rounded),
          ]),
        if (c?['asl_conditions'] != null) ...[
          const SizedBox(height: 8),
          InfoBanner(message: 'Syarat ASL: ${c!['asl_conditions']}', color: Brand.amber, icon: Icons.rule_rounded),
        ],
        const SizedBox(height: 8),
        ReviewRow('Geozone / site', [_geozone ?? '-', if (_site.text.trim().isNotEmpty) _site.text.trim()].join(' · ')),
        ReviewRow('Risiko', riskClassLabel[_risk]),
        ReviewRow('Award', fmtDate(_awarded.toIso8601String())),
        ReviewRow('Mulai → selesai', '${_start == null ? '-' : fmtDate(_start!.toIso8601String())} → ${_end == null ? '-' : fmtDate(_end!.toIso8601String())}'),
        ReviewRow('Target mobilisasi', _mob == null ? '-' : fmtDate(_mob!.toIso8601String())),
        ReviewRow('Process Owner', _po?['full_name'] as String?),
        ReviewRow('HSE Reviewer', _reviewer?['full_name'] as String?),
        const SizedBox(height: 12),
        _tierPreview(),
        const Divider(height: 28),
        const Text('Otomatis setelah dibuat', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        for (final l in const [
          'Task post-award sesuai kategori kontrak',
          'Contract Channel untuk chat',
          'Notifikasi PO/Admin: siapkan folder OneDrive',
          'Email #4001 ke contractor',
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              const Icon(Icons.bolt_rounded, size: 16, color: Brand.amber),
              const SizedBox(width: 8),
              Expanded(child: Text(l, style: Theme.of(context).textTheme.bodySmall)),
            ]),
          ),
        const SizedBox(height: 16),
        if (problems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InfoBanner(message: problems.first, color: Brand.amber, icon: Icons.info_outline_rounded),
          ),
        FilledButton.icon(
          onPressed: ok ? _submit : null,
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18)),
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.handshake_rounded),
          label: const Text('BUAT KONTRAK'),
        ),
      ]),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({required this.mode, required this.selected, required this.onTap});
  final ContractMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected ? Brand.blue.withValues(alpha: 0.07) : null,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? Brand.blue : t.dividerColor, width: selected ? 2 : 1),
          ),
          child: Row(children: [
            ModeBadge(mode),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(mode.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(mode.hint, style: t.textTheme.bodySmall),
              ]),
            ),
            Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: selected ? Brand.blue : Brand.grey),
          ]),
        ),
      ),
    );
  }
}
