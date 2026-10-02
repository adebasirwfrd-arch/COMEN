import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
import '../../core/errors/app_failure.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;
J _m(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<J> _l(dynamic v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

// ═══════════════════════════ Label & gaya ═══════════════════════════
const _types = <String, String>{
  'near_miss': 'Near miss',
  'first_aid': 'First aid',
  'mtc': 'Medical treatment (MTC)',
  'rwc': 'Restricted work (RWC)',
  'lti': 'Lost time injury (LTI)',
  'fatality': 'Fatality',
  'vehicle': 'Insiden kendaraan',
  'property_damage': 'Kerusakan properti',
  'environmental': 'Lingkungan',
  'security': 'Security',
  'other': 'Lainnya',
};
const _severities = <String, String>{'low': 'Low', 'medium': 'Medium', 'high': 'High', 'critical': 'Critical'};
const _recordableTypes = {'mtc', 'rwc', 'lti', 'fatality'};

String _typeLabel(dynamic v) => _types[v] ?? str(v);

IconData _typeIcon(dynamic t) => switch (t) {
      'near_miss' => Icons.warning_amber_rounded,
      'first_aid' => Icons.medical_services_outlined,
      'mtc' || 'rwc' || 'lti' => Icons.personal_injury_outlined,
      'fatality' => Icons.dangerous_rounded,
      'vehicle' => Icons.directions_car_filled_outlined,
      'property_damage' => Icons.construction_rounded,
      'environmental' => Icons.eco_outlined,
      'security' => Icons.shield_outlined,
      _ => Icons.report_gmailerrorred_rounded,
    };

(Color, String) _incStatus(dynamic s) => switch (s) {
      'reported' => (Brand.amber, 'Dilaporkan'),
      'investigating' => (Brand.purple, 'Investigasi'),
      'closed' => (Brand.grey, 'Ditutup'),
      _ => (Brand.grey, str(s)),
    };

(Color, String) _findingStatus(dynamic s) => switch (s) {
      'open' => (Brand.blue, 'Open'),
      'closure_submitted' => (Brand.cyan, 'Penutupan diajukan'),
      'closed' => (Brand.green, 'Closed'),
      'cancelled' => (Brand.grey, 'Dibatalkan'),
      _ => (Brand.grey, str(s)),
    };

Widget _sevBadge(dynamic s) {
  final (c, _) = StatusStyle.generic(s as String?);
  return StatusBadge(c, _severities[s] ?? str(s), icon: Icons.local_fire_department_rounded);
}

const _incListCols = 'id,incident_no,contract_id,occurred_at,reported_at,type,severity,is_preventable_vehicle,high_potential,title,'
    'lat,lng,location_text,flash_due_at,flash_at,full_report_due_at,full_report_at,rca_task_id,status,closed_at,created_at,updated_at,'
    'contract:contracts(id,contract_no,title,contractor_id,status)';
const _incCols = 'id,incident_no,contract_id,occurred_at,reported_at,type,severity,is_preventable_vehicle,high_potential,title,description,'
    'lat,lng,location_text,evidence_ref,flash_due_at,flash_at,full_report_due_at,full_report_at,full_report,rca_task_id,status,'
    'reported_by,closed_by,closed_at,created_at,updated_at,contract:contracts(id,contract_no,title,contractor_id,status)';
const _findingCols = 'id,finding_no,contract_id,audit_id,inspection_id,area,description,severity,due_date,status,fndcls_task_id,'
    'verified_at,created_at,contract:contracts(id,contract_no,title)';
const _contractCols = 'id,contract_no,title,status,contractor_id';
const _rcaCols = 'id,task_id,base_task_id,revision,status,due_date,title,is_overdue,created_at,updated_at';

bool _canSubmitReport(SessionState? s) => s != null && (s.isWfrd ? s.can('incident.manage') : s.can('record.submit'));

/// Tenggat laporan insiden: (warna, label) untuk ditampilkan di list & detail.
(Color, String) _deadline(J i) {
  if (i['status'] == 'closed') return (Brand.grey, 'Ditutup ${fmtDate(i['closed_at'])}');
  if (i['full_report_at'] == null) {
    final due = parseDate(i['full_report_due_at']);
    if (due != null && due.isBefore(DateTime.now())) return (Brand.red, 'Full report terlambat');
    return (Brand.amber, 'Full report ${fmtRelative(i['full_report_due_at'])}');
  }
  return (Brand.purple, i['rca_task_id'] == null ? 'Menunggu penutupan' : 'RCA berjalan');
}

String _isoLocal(DateTime d) => d.toUtc().toIso8601String();

// ═══════════════════════════ LIST ═══════════════════════════
class IncidentListPage extends ConsumerStatefulWidget {
  const IncidentListPage({super.key});
  @override
  ConsumerState<IncidentListPage> createState() => _IncidentListPageState();
}

class _IncidentListPageState extends ConsumerState<IncidentListPage> {
  String _tab = 'incidents';
  late Future<List<J>> _incidents, _findings;
  List<J> _contracts = const [];
  String _status = '', _severity = '', _contract = '', _q = '';
  String _fStatus = '', _fSeverity = '', _fContract = '';
  StreamSubscription<String>? _sub;
  bool _init = false;

  @override
  void initState() {
    super.initState();
    _incidents = _loadIncidents();
    _findings = _loadFindings();
    ref
        .read(apiProvider)
        .select('contracts', _contractCols, build: (q) => q.order('contract_no', ascending: true).limit(500))
        .then((r) => mounted ? setState(() => _contracts = r) : null)
        .catchError((_) => null);
    _sub = ref.read(notificationBus).stream.listen((_) => _reload());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final p = GoRouterState.of(context).uri.queryParameters;
    if (p['tab'] == 'findings') _tab = 'findings';
    if (p['contract'] != null && uuidRe.hasMatch(p['contract']!)) {
      _contract = p['contract']!;
      _fContract = p['contract']!;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<List<J>> _loadIncidents() => ref
      .read(apiProvider)
      .select('incidents', _incListCols, build: (q) => q.order('occurred_at', ascending: false).limit(500));

  Future<List<J>> _loadFindings() => ref
      .read(apiProvider)
      .select('audit_findings', _findingCols, build: (q) => q.order('due_date', ascending: true).limit(500));

  void _reload() {
    if (!mounted) return;
    setState(() {
      _incidents = _loadIncidents();
      _findings = _loadFindings();
    });
  }

  Future<void> _newFinding() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _FindingDialog(contracts: _contracts.where((k) => !const {'closed', 'terminated'}.contains(k['status'])).toList(), initial: _fContract),
    );
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(sessionProvider);
    final s = st is SessionReady ? st.s : null;
    final canReport = s?.can('incident.report') == true;
    final canFinding = s != null && s.isWfrd && s.can('audit.conduct');
    return PageScaffold(
      title: 'Insiden & finding',
      subtitle: 'Insiden HSE (flash ≤ 1 jam · full report ≤ 24 jam · RCA ≤ 14 hari) dan finding audit/inspeksi',
      actions: [
        if (_tab == 'incidents' && canReport)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Brand.red),
            onPressed: () => context.go(_contract.isEmpty ? '/incidents/new' : '/incidents/new?contract=$_contract'),
            icon: const Icon(Icons.campaign_rounded),
            label: const Text('Lapor insiden'),
          ),
        if (_tab == 'findings' && canFinding)
          FilledButton.icon(onPressed: _newFinding, icon: const Icon(Icons.add_rounded), label: const Text('Finding baru')),
        IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'incidents', label: Text('Insiden'), icon: Icon(Icons.report_gmailerrorred_rounded)),
              ButtonSegment(value: 'findings', label: Text('Finding audit'), icon: Icon(Icons.find_in_page_rounded)),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
        ),
        const SizedBox(height: 16),
        if (_tab == 'incidents')
          AsyncView<List<J>>(future: _incidents, onRetry: _reload, builder: (context, rows) => _incidentView(rows, canReport))
        else
          AsyncView<List<J>>(future: _findings, onRetry: _reload, builder: (context, rows) => _findingView(rows, s)),
      ]),
    );
  }

  List<(String, String)> get _contractItems => [
        ('', 'Semua kontrak'),
        for (final k in _contracts) (k['id'] as String, '${str(k['contract_no'], 'CTR-…')} · ${str(k['title'])}'),
      ];

  Widget _drop(String label, String value, List<(String, String)> items, ValueChanged<String> on, double w, IconData icon) => SizedBox(
        width: w,
        child: DropdownButtonFormField<String>(
          key: ValueKey('$label|$value|${items.length}'),
          initialValue: items.any((e) => e.$1 == value) ? value : '',
          isExpanded: true,
          menuMaxHeight: 420,
          decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon, size: 18)),
          items: [for (final (v, l) in items) DropdownMenuItem(value: v, child: Text(l, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => on(v ?? ''),
        ),
      );

  Widget _incidentView(List<J> rows, bool canReport) {
    final open = rows.where((i) => i['status'] != 'closed').toList();
    final highOpen = open.where((i) => const {'high', 'critical'}.contains(i['severity'])).length;
    final lateReport = open.where((i) => _deadline(i).$2 == 'Full report terlambat').length;
    final hipo = open.where((i) => i['high_potential'] == true).length;
    final q = _q.toLowerCase();
    final list = rows.where((i) {
      if (_status.isEmpty && i['status'] == 'closed') return false;
      if (_status.isNotEmpty && _status != 'all' && i['status'] != _status) return false;
      if (_severity.isNotEmpty && i['severity'] != _severity) return false;
      if (_contract.isNotEmpty && i['contract_id'] != _contract) return false;
      if (q.isNotEmpty && !'${i['incident_no']} ${i['title']} ${i['location_text']}'.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
    final filtered = _status.isNotEmpty || _severity.isNotEmpty || _contract.isNotEmpty || _q.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ResponsiveGrid(minItemWidth: 200, spacing: 12, children: [
        StatCard(label: 'Insiden terbuka', value: '${open.length}', icon: Icons.report_gmailerrorred_rounded, color: Brand.red, onTap: () => setState(() => _status = '')),
        StatCard(label: 'High / Critical terbuka', value: '$highOpen', icon: Icons.local_fire_department_rounded, color: const Color(0xFFDC6803)),
        StatCard(label: 'Full report terlambat', value: '$lateReport', icon: Icons.timer_off_rounded, color: Brand.amber),
        StatCard(label: 'High potential (HiPo)', value: '$hipo', icon: Icons.bolt_rounded, color: Brand.purple),
      ]),
      const SizedBox(height: 16),
      SectionCard(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 860;
          final w = wide ? 200.0 : c.maxWidth;
          return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: wide ? 280 : c.maxWidth,
              child: TextField(
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: const InputDecoration(hintText: 'Cari nomor / judul / lokasi', prefixIcon: Icon(Icons.search_rounded)),
              ),
            ),
            _drop('Status', _status, const [('', 'Terbuka'), ('reported', 'Dilaporkan'), ('investigating', 'Investigasi'), ('closed', 'Ditutup'), ('all', 'Semua')],
                (v) => setState(() => _status = v), w, Icons.flag_outlined),
            _drop('Severity', _severity, [('', 'Semua severity'), for (final e in _severities.entries) (e.key, e.value)], (v) => setState(() => _severity = v), w,
                Icons.local_fire_department_outlined),
            _drop('Kontrak', _contract, _contractItems, (v) => setState(() => _contract = v), wide ? 260 : c.maxWidth, Icons.handshake_outlined),
          ]);
        }),
      ),
      const SizedBox(height: 16),
      if (list.isEmpty)
        SectionCard(
          child: EmptyState(
            icon: filtered ? Icons.filter_alt_off_rounded : Icons.health_and_safety_rounded,
            title: filtered ? 'Tidak ada insiden yang cocok' : 'Tidak ada insiden terbuka',
            message: filtered ? 'Ubah filter untuk melihat insiden lain.' : 'Tetap waspada — laporkan setiap near miss.',
            action: canReport && !filtered
                ? FilledButton.icon(onPressed: () => context.go('/incidents/new'), icon: const Icon(Icons.campaign_rounded), label: const Text('Lapor insiden'))
                : null,
          ),
        )
      else if (MediaQuery.sizeOf(context).width >= 900)
        _IncidentTable(rows: list)
      else
        for (final i in list) _IncidentCard(i: i),
    ]);
  }

  Widget _findingView(List<J> rows, SessionState? s) {
    final active = rows.where((f) => const {'open', 'closure_submitted'}.contains(f['status'])).toList();
    final today = DateTime.now();
    final late = active.where((f) => (parseDate(f['due_date']) ?? today).isBefore(DateTime(today.year, today.month, today.day))).length;
    final list = rows.where((f) {
      if (_fStatus.isEmpty && !const {'open', 'closure_submitted'}.contains(f['status'])) return false;
      if (_fStatus.isNotEmpty && _fStatus != 'all' && f['status'] != _fStatus) return false;
      if (_fSeverity.isNotEmpty && f['severity'] != _fSeverity) return false;
      if (_fContract.isNotEmpty && f['contract_id'] != _fContract) return false;
      return true;
    }).toList();
    final canCancel = s != null && s.isWfrd && s.can('finding.verify');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ResponsiveGrid(minItemWidth: 200, spacing: 12, children: [
        StatCard(label: 'Finding terbuka', value: '${active.length}', icon: Icons.find_in_page_rounded, color: Brand.blue),
        StatCard(label: 'Critical terbuka', value: '${active.where((f) => f['severity'] == 'critical').length}', icon: Icons.dangerous_rounded, color: Brand.red),
        StatCard(label: 'Major terbuka', value: '${active.where((f) => f['severity'] == 'major').length}', icon: Icons.priority_high_rounded, color: const Color(0xFFDC6803)),
        StatCard(label: 'Lewat due', value: '$late', icon: Icons.alarm_rounded, color: Brand.amber),
      ]),
      const SizedBox(height: 16),
      SectionCard(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 860;
          final w = wide ? 220.0 : c.maxWidth;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            _drop('Status', _fStatus,
                const [('', 'Terbuka'), ('open', 'Open'), ('closure_submitted', 'Penutupan diajukan'), ('closed', 'Closed'), ('cancelled', 'Dibatalkan'), ('all', 'Semua')],
                (v) => setState(() => _fStatus = v), w, Icons.flag_outlined),
            _drop('Severity', _fSeverity, const [('', 'Semua severity'), ('critical', 'Critical'), ('major', 'Major'), ('minor', 'Minor')],
                (v) => setState(() => _fSeverity = v), w, Icons.local_fire_department_outlined),
            _drop('Kontrak', _fContract, _contractItems, (v) => setState(() => _fContract = v), wide ? 280 : c.maxWidth, Icons.handshake_outlined),
          ]);
        }),
      ),
      const SizedBox(height: 16),
      if (list.isEmpty)
        const SectionCard(child: EmptyState(icon: Icons.fact_check_rounded, title: 'Tidak ada finding', message: 'Finding dari audit/inspeksi akan tampil di sini beserta task penutupannya (FNDCLS).'))
      else
        SectionCard(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(children: [
            for (final (i, f) in list.indexed) ...[
              if (i > 0) const Divider(height: 1),
              _FindingTile(f: f, canCancel: canCancel, onChanged: _reload),
            ],
          ]),
        ),
    ]);
  }
}

class _IncidentTable extends StatelessWidget {
  const _IncidentTable({required this.rows});
  final List<J> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final head = t.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 0.3);
    Widget h(String s, int flex) => Expanded(flex: flex, child: Text(s.toUpperCase(), style: head));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(children: [h('Nomor', 16), h('Insiden', 30), h('Kontrak', 16), h('Severity', 12), h('Status', 12), h('Tenggat', 16)]),
        ),
        for (final (idx, i) in rows.indexed) ...[
          if (idx > 0) const Divider(height: 1),
          InkWell(
            onTap: () => context.go('/incidents/${i['id']}'),
            child: Container(
              decoration: BoxDecoration(border: Border(left: BorderSide(color: StatusStyle.generic(i['severity'] as String?).$1, width: 4))),
              padding: const EdgeInsets.fromLTRB(16, 12, 20, 12),
              child: Row(children: [
                Expanded(
                  flex: 16,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(str(i['incident_no']), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 13)),
                    Text(fmtDateTime(i['occurred_at']), style: t.bodySmall),
                  ]),
                ),
                Expanded(
                  flex: 30,
                  child: Row(children: [
                    Icon(_typeIcon(i['type']), color: StatusStyle.generic(i['severity'] as String?).$1, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(str(i['title']), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          [_typeLabel(i['type']), if (i['high_potential'] == true) 'HiPo', if (i['lat'] != null) 'GPS', if (i['location_text'] != null) str(i['location_text'])].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall,
                        ),
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 16,
                  child: Text(str(_m(i['contract'])['contract_no']), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700, fontSize: 12)),
                ),
                Expanded(flex: 12, child: Align(alignment: Alignment.centerLeft, child: _sevBadge(i['severity']))),
                Expanded(flex: 12, child: Align(alignment: Alignment.centerLeft, child: StatusBadge(_incStatus(i['status']).$1, _incStatus(i['status']).$2))),
                Expanded(
                  flex: 16,
                  child: Text(_deadline(i).$2, style: TextStyle(color: _deadline(i).$1, fontWeight: FontWeight.w700, fontSize: 12)),
                ),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

class _IncidentCard extends StatelessWidget {
  const _IncidentCard({required this.i});
  final J i;
  @override
  Widget build(BuildContext context) {
    final sevColor = StatusStyle.generic(i['severity'] as String?).$1;
    final (dc, dl) = _deadline(i);
    final (sc, sl) = _incStatus(i['status']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go('/incidents/${i['id']}'),
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: sevColor, width: 4))),
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(_typeIcon(i['type']), color: sevColor),
                const SizedBox(width: 8),
                Expanded(child: Text(str(i['incident_no']), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800))),
                _sevBadge(i['severity']),
              ]),
              const SizedBox(height: 8),
              Text(str(i['title']), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 4),
              Text('${_typeLabel(i['type'])} · ${str(_m(i['contract'])['contract_no'])} · ${fmtDateTime(i['occurred_at'])}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                StatusBadge(sc, sl),
                StatusBadge(dc, dl, icon: Icons.schedule_rounded),
                if (i['high_potential'] == true) const StatusBadge(Brand.purple, 'HiPo', icon: Icons.bolt_rounded),
                if (i['lat'] != null) const StatusBadge(Brand.cyan, 'GPS', icon: Icons.my_location_rounded),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _FindingTile extends ConsumerWidget {
  const _FindingTile({required this.f, required this.canCancel, required this.onChanged});
  final J f;
  final bool canCancel;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (sc, sl) = _findingStatus(f['status']);
    final active = const {'open', 'closure_submitted'}.contains(f['status']);
    final taskId = f['fndcls_task_id'] as String?;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      onTap: taskId == null ? null : () => context.go('/tasks/$taskId'),
      leading: CircleAvatar(
        backgroundColor: StatusStyle.generic(f['severity'] as String?).$1.withValues(alpha: 0.12),
        child: Icon(Icons.find_in_page_rounded, color: StatusStyle.generic(f['severity'] as String?).$1),
      ),
      title: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(str(f['finding_no']), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800)),
        StatusBadge(StatusStyle.generic(f['severity'] as String?).$1, StatusStyle.generic(f['severity'] as String?).$2),
        StatusBadge(sc, sl),
        if (active && f['due_date'] != null) StatusBadge(dueColor(f['due_date']), 'Due ${fmtDate(f['due_date'])} · ${dueLabel(f['due_date'])}', icon: Icons.event_rounded),
      ]),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('${str(_m(f['contract'])['contract_no'])} · ${str(f['area'])} — ${str(f['description'])}', maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (taskId != null) const Tooltip(message: 'Buka task penutupan (FNDCLS)', child: Icon(Icons.chevron_right_rounded)),
        if (canCancel && active)
          IconButton(
            tooltip: 'Batalkan finding',
            icon: const Icon(Icons.cancel_outlined, color: Brand.red),
            onPressed: () async {
              final r = await showReasonDialog(context,
                  title: 'Batalkan ${f['finding_no']}', message: 'Task penutupan (FNDCLS) yang masih terbuka ikut dibatalkan.', confirmLabel: 'Batalkan finding', destructive: true);
              if (r == null || !context.mounted) return;
              final ok = await runAction(context, ref, () async {
                await ref.read(apiProvider).rpc('cancel_finding', {'p_finding': f['id'], 'p_reason': r});
                return true;
              }, success: 'Finding dibatalkan');
              if (ok == true) onChanged();
            },
          ),
      ]),
    );
  }
}

class _FindingDialog extends ConsumerStatefulWidget {
  const _FindingDialog({required this.contracts, required this.initial});
  final List<J> contracts;
  final String initial;
  @override
  ConsumerState<_FindingDialog> createState() => _FindingDialogState();
}

class _FindingDialogState extends ConsumerState<_FindingDialog> {
  late String? _contract = widget.contracts.any((k) => k['id'] == widget.initial) ? widget.initial : null;
  String _severity = 'major';
  final _area = TextEditingController();
  final _desc = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _area.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final id = await runAction(
      context,
      ref,
      () => ref.read(apiProvider).rpc('create_finding', {
        'p_contract': _contract,
        'p_audit': null,
        'p_inspection': null,
        'p_area': _area.text.trim(),
        'p_description': _desc.text.trim(),
        'p_severity': _severity,
      }),
      success: 'Finding dibuat',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final ok = !_busy && _contract != null && _area.text.trim().isNotEmpty && _desc.text.trim().length >= 5;
    final days = switch (_severity) { 'critical' => 3, 'major' => 7, _ => 30 };
    return AlertDialog(
      icon: const Icon(Icons.find_in_page_rounded, color: Brand.amber, size: 36),
      title: const Text('Finding baru'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
              initialValue: _contract,
              isExpanded: true,
              menuMaxHeight: 420,
              decoration: const InputDecoration(labelText: 'Kontrak *', prefixIcon: Icon(Icons.handshake_outlined)),
              items: [
                for (final k in widget.contracts)
                  DropdownMenuItem(value: k['id'] as String, child: Text('${str(k['contract_no'], 'CTR-…')} · ${str(k['title'])}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _contract = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: _area, maxLength: 200, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Area *', hintText: 'mis. Housekeeping, PPE, Lifting')),
            TextField(controller: _desc, maxLines: 4, maxLength: 4000, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Deskripsi temuan *')),
            const SizedBox(height: 4),
            const Text('Severity', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'critical', label: Text('Critical')),
                ButtonSegment(value: 'major', label: Text('Major')),
                ButtonSegment(value: 'minor', label: Text('Minor')),
              ],
              selected: {_severity},
              onSelectionChanged: (v) => setState(() => _severity = v.first),
            ),
            const SizedBox(height: 12),
            InfoBanner(
              message: 'Task penutupan FNDCLS dibuat otomatis dengan due $days hari${_severity == 'minor' ? '' : ' dan menjadi gate blocker mobilisasi'}.',
              color: _severity == 'critical' ? Brand.red : Brand.amber,
              icon: Icons.task_alt_rounded,
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: ok ? _save : null,
          child: const Text('Simpan finding'),
        ),
      ],
    );
  }
}

// ═══════════════════════════ GEOLOCATION (19.1) ═══════════════════════════
typedef _Fix = ({double lat, double lng, double accuracy});

/// Hanya dipanggil saat pengguna menekan "Ambil lokasi" → browser meminta izin pada saat itu.
Future<_Fix> _currentPosition() {
  final c = Completer<_Fix>();
  void ok(web.GeolocationPosition p) {
    if (!c.isCompleted) c.complete((lat: p.coords.latitude, lng: p.coords.longitude, accuracy: p.coords.accuracy));
  }

  void fail(web.GeolocationPositionError e) {
    if (c.isCompleted) return;
    c.completeError(switch (e.code) {
      1 => 'Izin lokasi ditolak. Aktifkan izin lokasi untuk situs ini di pengaturan browser.',
      2 => 'Lokasi tidak tersedia. Pastikan GPS/Location Services aktif.',
      3 => 'Waktu habis saat mengambil lokasi. Coba lagi di area terbuka.',
      _ => 'Gagal mengambil lokasi: ${e.message}',
    });
  }

  try {
    web.window.navigator.geolocation.getCurrentPosition(ok.toJS, fail.toJS, web.PositionOptions(enableHighAccuracy: true, timeout: 20000, maximumAge: 0));
  } catch (_) {
    c.completeError('Browser tidak mendukung geolokasi (butuh HTTPS).');
  }
  return c.future.timeout(const Duration(seconds: 25), onTimeout: () => throw 'Waktu habis saat mengambil lokasi.');
}

// ═══════════════════════════ NEW ═══════════════════════════
class IncidentNewPage extends ConsumerStatefulWidget {
  const IncidentNewPage({super.key, this.contractId});
  final String? contractId;
  @override
  ConsumerState<IncidentNewPage> createState() => _IncidentNewPageState();
}

class _IncidentNewPageState extends ConsumerState<IncidentNewPage> {
  late Future<List<J>> _contracts;
  String? _contract;
  String? _type;
  String _severity = 'medium';
  DateTime _occurred = DateTime.now();
  bool _hipo = false, _preventable = false, _busy = false, _locating = false;
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _immediate = TextEditingController();
  final _location = TextEditingController();
  final _evidence = TextEditingController();
  _Fix? _fix;
  String? _geoError;

  @override
  void initState() {
    super.initState();
    _contracts = ref
        .read(apiProvider)
        .select('contracts', _contractCols, build: (q) => q.not('status', 'in', '(closed,terminated)').order('contract_no', ascending: true).limit(500));
    _contracts.then((r) {
      if (!mounted) return;
      final pre = widget.contractId;
      setState(() => _contract = r.any((k) => k['id'] == pre) ? pre : (r.length == 1 ? r.first['id'] as String : null));
    }).catchError((_) {});
  }

  @override
  void dispose() {
    for (final c in [_title, _desc, _immediate, _location, _evidence]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _effectiveSeverity => _type == 'fatality' ? 'critical' : _severity;
  bool get _rcaRequired => _effectiveSeverity != 'low' || _hipo || _recordableTypes.contains(_type);
  String get _fullDescription {
    final d = _desc.text.trim();
    final im = _immediate.text.trim();
    return im.isEmpty ? d : '$d\n\nTindakan segera:\n$im';
  }

  bool get _valid =>
      !_busy &&
      _contract != null &&
      _type != null &&
      _title.text.trim().length >= 3 &&
      _desc.text.trim().length >= 10 &&
      _fullDescription.length <= 8000 &&
      !_occurred.isAfter(DateTime.now().add(const Duration(minutes: 5)));

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _geoError = null;
    });
    try {
      final f = await _currentPosition();
      if (mounted) setState(() => _fix = f);
    } catch (e) {
      if (mounted) setState(() => _geoError = e.toString());
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, firstDate: now.subtract(const Duration(days: 365)), lastDate: now, initialDate: _occurred.isAfter(now) ? now : _occurred);
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_occurred));
    if (t == null) return;
    setState(() => _occurred = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  double _round6(double v) => double.parse(v.toStringAsFixed(6));

  Future<void> _submit() async {
    final sev = _effectiveSeverity;
    if (sev == 'high' || sev == 'critical') {
      final ok = await showConfirm(
        context,
        title: 'Laporkan insiden ${sev.toUpperCase()}?',
        message: 'Eskalasi segera: kartu URGENT di channel kontrak, notifikasi PO/HSE/Director, dan email ke HSE manager contractor.',
        confirmLabel: 'Laporkan sekarang',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    final r = await runAction<J>(
      context,
      ref,
      () => ref.read(apiProvider).rpcMap('report_incident', {
        'p_contract': _contract,
        'p_occurred_at': _isoLocal(_occurred),
        'p_type': _type,
        'p_severity': sev,
        'p_title': _title.text.trim(),
        'p_description': _fullDescription,
        'p_lat': _fix == null ? null : _round6(_fix!.lat),
        'p_lng': _fix == null ? null : _round6(_fix!.lng),
        'p_location_text': _location.text.trim().isEmpty ? null : _location.text.trim(),
        'p_evidence_ref': _evidence.text.trim().isEmpty ? null : _evidence.text.trim(),
        'p_is_preventable_vehicle': _type == 'vehicle' && _preventable,
        'p_high_potential': _hipo,
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) {
      showSnack(context, 'Insiden ${r['incident_no']} dilaporkan${r['rca_task'] != null ? ' · task RCA dibuat' : ''}');
      context.go('/incidents/${r['id']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Lapor insiden',
      subtitle: 'Laporkan sesegera mungkin — data awal cukup, detail investigasi menyusul di full report',
      leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.canPop() ? context.pop() : context.go('/incidents')),
      maxWidth: 1200,
      child: AsyncView<List<J>>(
        future: _contracts,
        onRetry: () => setState(() => _contracts = ref.read(apiProvider).select('contracts', _contractCols,
            build: (q) => q.not('status', 'in', '(closed,terminated)').order('contract_no', ascending: true).limit(500))),
        builder: (context, contracts) {
          if (contracts.isEmpty) {
            return const SectionCard(
              child: EmptyState(icon: Icons.handshake_outlined, title: 'Tidak ada kontrak aktif', message: 'Insiden hanya dapat dilaporkan pada kontrak yang dapat Anda akses.'),
            );
          }
          final form = _form(contracts);
          final side = _side();
          return LayoutBuilder(builder: (context, c) {
            if (c.maxWidth < 980) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [form, const SizedBox(height: 16), side]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: form), const SizedBox(width: 16), Expanded(flex: 2, child: side)]);
          });
        },
      ),
    );
  }

  Widget _form(List<J> contracts) {
    final sev = _effectiveSeverity;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        title: 'Kontrak & klasifikasi',
        icon: Icons.category_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(
            key: ValueKey('inc-contract-$_contract'),
            initialValue: _contract,
            isExpanded: true,
            menuMaxHeight: 420,
            decoration: const InputDecoration(labelText: 'Kontrak *', prefixIcon: Icon(Icons.handshake_outlined)),
            items: [
              for (final k in contracts)
                DropdownMenuItem(
                  value: k['id'] as String,
                  child: Text('${str(k['contract_no'], 'CTR-…')} · ${str(k['title'])} (${StatusStyle.contract(k['status'] as String?).$2})', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _contract = v),
          ),
          const SizedBox(height: 16),
          const Text('Jenis insiden *', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in _types.entries)
              ChoiceChip(
                selected: _type == e.key,
                avatar: Icon(_typeIcon(e.key), size: 16),
                label: Text(e.value),
                onSelected: (_) => setState(() => _type = e.key),
              ),
          ]),
          const SizedBox(height: 16),
          const Text('Severity *', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              for (final e in _severities.entries)
                ButtonSegment(value: e.key, label: Text(e.value), icon: Icon(Icons.circle, size: 12, color: StatusStyle.generic(e.key).$1)),
            ],
            selected: {sev},
            onSelectionChanged: _type == 'fatality' ? null : (v) => setState(() => _severity = v.first),
          ),
          if (_type == 'fatality') ...[
            const SizedBox(height: 8),
            const Text('Fatality selalu dikategorikan CRITICAL.', style: TextStyle(color: Brand.red, fontWeight: FontWeight.w600, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            value: _hipo,
            onChanged: (v) => setState(() => _hipo = v),
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.bolt_rounded, color: _hipo ? Brand.purple : Brand.grey),
            title: const Text('High potential (HiPo)', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Berpotensi menyebabkan cedera serius/fatality walau hasil aktualnya ringan.'),
          ),
          if (_type == 'vehicle')
            SwitchListTile(
              value: _preventable,
              onChanged: (v) => setState(() => _preventable = v),
              contentPadding: EdgeInsets.zero,
              secondary: Icon(Icons.directions_car_filled_outlined, color: _preventable ? Brand.amber : Brand.grey),
              title: const Text('Preventable vehicle incident', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Dihitung ke PVIR (per 1.000.000 km).'),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Kejadian',
        icon: Icons.event_note_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _pickDateTime,
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Tanggal & waktu kejadian *', prefixIcon: Icon(Icons.schedule_rounded), suffixIcon: Icon(Icons.edit_calendar_rounded)),
              child: Text(fmtDateTime(_occurred.toIso8601String())),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            maxLength: 200,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Judul singkat *', hintText: 'mis. Pekerja terpeleset di area rig floor'),
          ),
          TextField(
            controller: _desc,
            maxLines: 5,
            maxLength: 7000,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Deskripsi kejadian *', hintText: 'Apa yang terjadi, siapa yang terlibat, kondisi saat itu…', alignLabelWithHint: true),
          ),
          TextField(
            controller: _immediate,
            maxLines: 3,
            maxLength: 900,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Tindakan segera yang sudah dilakukan', hintText: 'P3K, isolasi area, stop work…', alignLabelWithHint: true),
          ),
          TextField(
            controller: _evidence,
            maxLength: 500,
            decoration: const InputDecoration(labelText: 'Referensi bukti (opsional)', hintText: 'Folder EVIDENCE/ OneDrive kontrak', prefixIcon: Icon(Icons.attach_file_rounded)),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Lokasi',
        icon: Icons.place_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _location,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Lokasi (teks)', hintText: 'mis. Well pad B-12, area loading', prefixIcon: Icon(Icons.location_city_rounded)),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(_fix == null ? Icons.location_searching_rounded : Icons.my_location_rounded, color: _fix == null ? Brand.grey : Brand.green),
                const SizedBox(width: 10),
                Expanded(
                  child: _fix == null
                      ? const Text('Koordinat GPS (opsional)', style: TextStyle(fontWeight: FontWeight.w700))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          MonoText('${_fix!.lat.toStringAsFixed(6)}, ${_fix!.lng.toStringAsFixed(6)}'),
                          Text('Akurasi ± ${_fix!.accuracy.round()} m', style: Theme.of(context).textTheme.bodySmall),
                        ]),
                ),
                if (_fix != null) IconButton(tooltip: 'Hapus koordinat', onPressed: () => setState(() => _fix = null), icon: const Icon(Icons.close_rounded)),
                OutlinedButton.icon(
                  onPressed: _locating ? null : _locate,
                  icon: _locating ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.gps_fixed_rounded),
                  label: Text(_fix == null ? 'Ambil lokasi' : 'Perbarui'),
                ),
              ]),
              if (_geoError != null) ...[
                const SizedBox(height: 10),
                Text(_geoError!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600, fontSize: 12)),
              ],
              const SizedBox(height: 8),
              Text(
                'Browser hanya meminta izin lokasi saat Anda menekan "Ambil lokasi". Koordinat disimpan sebagai bagian rekaman HSE insiden ini saja.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: _valid ? _submit : null,
          style: FilledButton.styleFrom(
            backgroundColor: (sev == 'high' || sev == 'critical') ? Brand.red : null,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
          ),
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.campaign_rounded),
          label: const Text('KIRIM LAPORAN INSIDEN'),
        ),
      ),
    ]);
  }

  Widget _side() {
    final sev = _effectiveSeverity;
    final high = sev == 'high' || sev == 'critical';
    Widget step(IconData icon, Color c, String title, String body, {bool active = true}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Opacity(
            opacity: active ? 1 : 0.45,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(radius: 16, backgroundColor: c.withValues(alpha: 0.12), child: Icon(icon, size: 17, color: c)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(body, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            ]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: high ? const [Color(0xFFB42318), Brand.red] : const [Brand.navy, Brand.blue]),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(high ? Icons.campaign_rounded : Icons.health_and_safety_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Text(high ? 'ESKALASI SEGERA' : 'Pelaporan standar', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 0.4)),
          ]),
          const SizedBox(height: 10),
          Text(
            high
                ? 'Insiden ${sev.toUpperCase()} dieskalasi saat laporan dikirim: kartu urgent di channel kontrak, notifikasi PO/HSE/Director, email ke HSE manager.'
                : 'Insiden dicatat di channel kontrak dan tim HSE WFRD dapat menindaklanjuti.',
            style: const TextStyle(color: Colors.white, height: 1.4),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Kewajiban setelah melapor',
        icon: Icons.checklist_rounded,
        child: Column(children: [
          step(Icons.flash_on_rounded, Brand.red, 'Flash report ≤ 1 jam', 'Untuk High/Critical — laporan ini tercatat sebagai flash report.', active: high),
          step(Icons.description_rounded, Brand.amber, 'Full report ≤ 24 jam', 'Lengkapi kronologi, penyebab & tindakan di halaman detail insiden.'),
          step(Icons.manage_search_rounded, Brand.purple, 'RCA ≤ 14 hari (task INVRPT)',
              _rcaRequired ? 'Task RCA akan dibuat otomatis untuk insiden ini.' : 'Tidak wajib untuk insiden Low tanpa HiPo/recordable.',
              active: _rcaRequired),
          step(Icons.lock_rounded, Brand.grey, 'Penutupan oleh WFRD', 'Setelah full report ada dan RCA approved/waived.'),
        ]),
      ),
    ]);
  }
}

// ═══════════════════════════ DETAIL ═══════════════════════════
class _Detail {
  _Detail(this.incident, this.rca, this.people);
  final J incident;
  final J? rca;
  final Map<String, J> people;
}

class IncidentDetailPage extends ConsumerStatefulWidget {
  const IncidentDetailPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<IncidentDetailPage> createState() => _IncidentDetailPageState();
}

class _IncidentDetailPageState extends ConsumerState<IncidentDetailPage> {
  late Future<_Detail> _future = _load();

  @override
  void didUpdateWidget(covariant IncidentDetailPage old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _reload();
  }

  Future<_Detail> _load() async {
    final api = ref.read(apiProvider);
    final i = await api.selectOne('incidents', _incCols, 'id', widget.id);
    if (i == null) throw const AppFailure(Hint.forbidden, 'Insiden tidak ditemukan atau Anda tidak memiliki akses.');
    J? rca;
    final rcaId = i['rca_task_id'] as String?;
    if (rcaId != null) {
      final first = await api.select('v_task_tracking', _rcaCols,
          build: (q) => q.eq('id', rcaId).limit(1)).catchError((_) => <J>[]);
      if (first.isNotEmpty) {
        final revs = await api.select('v_task_tracking', _rcaCols,
            build: (q) => q.eq('base_task_id', first.first['base_task_id'] as Object).order('revision', ascending: false)).catchError((_) => first);
        rca = {
          ...revs.first,
          'any_done': revs.any((r) => const {'approved', 'waived'}.contains(r['status'])),
        };
      }
    }
    final ids = [i['reported_by'], i['closed_by']].whereType<String>().toSet().toList();
    final people = <String, J>{};
    if (ids.isNotEmpty) {
      try {
        for (final p in _l(await api.rpc('get_user_cards', {'p_ids': ids}))) {
          people[p['id'] as String] = p;
        }
      } catch (_) {}
    }
    return _Detail(i, rca, people);
  }

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<_Detail>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) => _IncidentView(key: ValueKey(d.incident['updated_at']), d: d, onChanged: _reload),
    );
  }
}

class _IncidentView extends ConsumerWidget {
  const _IncidentView({super.key, required this.d, required this.onChanged});
  final _Detail d;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i = d.incident;
    final st = ref.watch(sessionProvider);
    final s = st is SessionReady ? st.s : null;
    final contract = _m(i['contract']);
    final closed = i['status'] == 'closed';
    final canManage = s != null && s.isWfrd && s.can('incident.manage') && !closed;
    final canReport = _canSubmitReport(s) && !closed;
    return PageScaffold(
      title: str(i['title']),
      subtitle: '${str(i['incident_no'])} · ${str(contract['contract_no'])} · ${_typeLabel(i['type'])}',
      leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.canPop() ? context.pop() : context.go('/incidents')),
      actions: [
        if (canManage) _ManageMenu(d: d, onChanged: onChanged),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Header(i: i),
        const SizedBox(height: 16),
        _Obligations(d: d),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, c) {
          final info = _InfoCard(d: d);
          final tl = _TimelineCard(d: d);
          return c.maxWidth > 1000
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: info), const SizedBox(width: 16), Expanded(flex: 2, child: tl)])
              : Column(children: [info, const SizedBox(height: 16), tl]);
        }),
        const SizedBox(height: 16),
        _FullReportCard(incident: i, editable: canReport, onChanged: onChanged),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.i});
  final J i;
  @override
  Widget build(BuildContext context) {
    final sevColor = StatusStyle.generic(i['severity'] as String?).$1;
    final (sc, sl) = _incStatus(i['status']);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [sevColor.withValues(alpha: 0.14), Colors.transparent], begin: Alignment.centerLeft, end: Alignment.centerRight),
          border: Border(left: BorderSide(color: sevColor, width: 6)),
        ),
        padding: const EdgeInsets.all(20),
        child: Wrap(spacing: 14, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          CircleAvatar(radius: 24, backgroundColor: sevColor.withValues(alpha: 0.15), child: Icon(_typeIcon(i['type']), color: sevColor, size: 26)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            SelectableText(str(i['incident_no']), style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w900, fontSize: 22, color: Theme.of(context).colorScheme.primary)),
            CopyButton(str(i['incident_no']), tooltip: 'Copy nomor insiden'),
          ]),
          _sevBadge(i['severity']),
          StatusBadge(Brand.blue, _typeLabel(i['type']), icon: _typeIcon(i['type'])),
          StatusBadge(sc, sl),
          if (i['high_potential'] == true) const StatusBadge(Brand.purple, 'High potential', icon: Icons.bolt_rounded),
          if (i['is_preventable_vehicle'] == true) const StatusBadge(Brand.amber, 'Preventable vehicle', icon: Icons.directions_car_filled_outlined),
          if (_recordableTypes.contains(i['type'])) const StatusBadge(Brand.red, 'Recordable', icon: Icons.personal_injury_outlined),
        ]),
      ),
    );
  }
}

class _Obligations extends StatelessWidget {
  const _Obligations({required this.d});
  final _Detail d;

  @override
  Widget build(BuildContext context) {
    final i = d.incident;
    final high = const {'high', 'critical'}.contains(i['severity']);
    final now = DateTime.now();
    final fullDue = parseDate(i['full_report_due_at']);
    final rca = d.rca;
    Widget tile(IconData icon, String title, Color c, String status, String caption, {VoidCallback? onTap}) => InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: c.withValues(alpha: 0.4)), color: c.withValues(alpha: 0.06)),
            child: Row(children: [
              Icon(icon, color: c),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(status, style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12)),
                  Text(caption, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              if (onTap != null) const Icon(Icons.chevron_right_rounded),
            ]),
          ),
        );
    final flash = !high
        ? tile(Icons.flash_on_rounded, 'Flash report', Brand.grey, 'Tidak wajib', 'Hanya untuk High/Critical')
        : i['flash_at'] != null
            ? tile(Icons.flash_on_rounded, 'Flash report', Brand.green, 'Terkirim', fmtDateTime(i['flash_at']))
            : tile(Icons.flash_on_rounded, 'Flash report', Brand.red, 'Belum', 'Batas ${fmtDateTime(i['flash_due_at'])}');
    final full = i['full_report_at'] != null
        ? tile(Icons.description_rounded, 'Full report', Brand.green, 'Diserahkan', fmtDateTime(i['full_report_at']))
        : tile(Icons.description_rounded, 'Full report', fullDue != null && fullDue.isBefore(now) ? Brand.red : Brand.amber,
            fullDue != null && fullDue.isBefore(now) ? 'Terlambat' : 'Belum diserahkan', 'Batas ${fmtDateTime(i['full_report_due_at'])} (${fmtRelative(i['full_report_due_at'])})');
    final rcaTile = rca == null
        ? tile(Icons.manage_search_rounded, 'RCA (INVRPT)', Brand.grey, 'Tidak wajib', 'Insiden Low tanpa HiPo/recordable')
        : tile(
            Icons.manage_search_rounded,
            'RCA · ${str(rca['task_id'])}',
            StatusStyle.task(rca['status'] as String?).$1,
            StatusStyle.task(rca['status'] as String?).$2,
            'Due ${fmtDate(rca['due_date'])}${rca['is_overdue'] == true ? ' · overdue' : ''}',
            onTap: () => context.go('/tasks/${rca['id']}'),
          );
    return SectionCard(
      title: 'Kewajiban pelaporan',
      icon: Icons.rule_rounded,
      child: ResponsiveGrid(minItemWidth: 250, spacing: 12, children: [flash, full, rcaTile]),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.d});
  final _Detail d;
  @override
  Widget build(BuildContext context) {
    final i = d.incident;
    final contract = _m(i['contract']);
    final reporter = d.people[i['reported_by']];
    final closer = d.people[i['closed_by']];
    final hasGps = i['lat'] != null && i['lng'] != null;
    final coords = hasGps ? '${i['lat']}, ${i['lng']}' : null;
    return SectionCard(
      title: 'Detail insiden',
      icon: Icons.info_outline_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValueGrid(minItemWidth: 220, [
          (
            'Kontrak',
            InkWell(
              onTap: contract['id'] == null ? null : () => context.go('/contracts/${contract['id']}'),
              child: Text('${str(contract['contract_no'])} · ${str(contract['title'])}', style: const TextStyle(color: Brand.blue)),
            )
          ),
          ('Waktu kejadian', Text(fmtDateTime(i['occurred_at']))),
          ('Dilaporkan', Text('${fmtDateTime(i['reported_at'])}${reporter == null ? '' : ' · ${str(reporter['full_name'])}'}')),
          ('Lokasi', Text(str(i['location_text']))),
          (
            'Koordinat GPS',
            coords == null
                ? const Text('Tidak diambil')
                : Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: MonoText(coords, size: 12)), CopyButton(coords, tooltip: 'Copy koordinat')]),
          ),
          ('Referensi bukti', SelectableText(str(i['evidence_ref']))),
          if (i['closed_at'] != null) ('Ditutup', Text('${fmtDateTime(i['closed_at'])}${closer == null ? '' : ' · ${str(closer['full_name'])}'}')),
        ]),
        const SizedBox(height: 16),
        const Text('Deskripsi', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(12)),
          child: SelectableText(str(i['description']), style: const TextStyle(height: 1.5)),
        ),
      ]),
    );
  }
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.d});
  final _Detail d;

  @override
  Widget build(BuildContext context) {
    final i = d.incident;
    final ev = <(DateTime, IconData, Color, String, String?)>[];
    void add(dynamic at, IconData icon, Color c, String label, [String? sub]) {
      final t = parseDate(at);
      if (t != null) ev.add((t, icon, c, label, sub));
    }

    add(i['occurred_at'], _typeIcon(i['type']), StatusStyle.generic(i['severity'] as String?).$1, 'Kejadian', _typeLabel(i['type']));
    add(i['reported_at'], Icons.campaign_rounded, Brand.blue, 'Dilaporkan', str(d.people[i['reported_by']]?['full_name'], ''));
    add(i['flash_at'], Icons.flash_on_rounded, Brand.red, 'Flash report / eskalasi');
    add(i['full_report_at'], Icons.description_rounded, Brand.amber, 'Full report diserahkan', 'Status → investigasi');
    final rca = d.rca;
    if (rca != null) {
      add(rca['created_at'], Icons.manage_search_rounded, Brand.purple, 'Task RCA dibuat', '${str(rca['task_id'])} · due ${fmtDate(rca['due_date'])}');
      if (const {'approved', 'waived'}.contains(rca['status'])) {
        final (c, l) = StatusStyle.task(rca['status'] as String?);
        add(rca['updated_at'], Icons.verified_rounded, c, 'RCA $l', str(rca['task_id']));
      }
    }
    add(i['closed_at'], Icons.lock_rounded, Brand.grey, 'Insiden ditutup', str(d.people[i['closed_by']]?['full_name'], ''));
    ev.sort((a, b) => a.$1.compareTo(b.$1));
    final pending = <String>[
      if (i['full_report_at'] == null && i['status'] != 'closed') 'Full report — batas ${fmtDateTime(i['full_report_due_at'])}',
      if (i['status'] != 'closed') 'Penutupan oleh WFRD',
    ];
    return SectionCard(
      title: 'Timeline',
      icon: Icons.timeline_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (idx, e) in ev.indexed)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(children: [
              CircleAvatar(radius: 14, backgroundColor: e.$3.withValues(alpha: 0.14), child: Icon(e.$2, size: 15, color: e.$3)),
              if (idx < ev.length - 1 || pending.isNotEmpty) Container(width: 2, height: 30, color: Theme.of(context).dividerColor),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.$4, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text([fmtDateTime(e.$1.toIso8601String()), if (e.$5 != null && e.$5!.isNotEmpty) e.$5!].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            ),
          ]),
        for (final p in pending)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(radius: 14, backgroundColor: Theme.of(context).dividerColor, child: const Icon(Icons.more_horiz_rounded, size: 15, color: Brand.grey)),
            const SizedBox(width: 12),
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 4, bottom: 12), child: Text(p, style: const TextStyle(color: Brand.grey)))),
          ]),
      ]),
    );
  }
}

// ── Full report / investigasi (submit_incident_report) ──
const _reportFields = <(String, String, String)>[
  ('summary', 'Kronologi kejadian', 'Urutan kejadian sebelum, saat, dan sesudah insiden'),
  ('people_involved', 'Orang terlibat & saksi', 'Nama/jabatan korban, saksi, supervisor'),
  ('injury_damage', 'Cedera / kerusakan / dampak', 'Jenis cedera, bagian tubuh, kerusakan aset, dampak lingkungan'),
  ('immediate_actions', 'Tindakan segera', 'P3K, isolasi, stop work, pengamanan area'),
  ('immediate_cause', 'Penyebab langsung', 'Tindakan/kondisi tidak aman yang langsung memicu insiden'),
  ('root_cause', 'Akar masalah (RCA)', 'Faktor sistemik: prosedur, pelatihan, supervisi, desain'),
  ('contributing_factors', 'Faktor kontribusi', 'Cuaca, kelelahan, komunikasi, peralatan'),
  ('lessons_learned', 'Lessons learned', 'Pembelajaran untuk dibagikan ke tim lain'),
];

class _FullReportCard extends ConsumerStatefulWidget {
  const _FullReportCard({required this.incident, required this.editable, required this.onChanged});
  final J incident;
  final bool editable;
  final VoidCallback onChanged;
  @override
  ConsumerState<_FullReportCard> createState() => _FullReportCardState();
}

class _CaRow {
  _CaRow({String action = '', String owner = '', this.due, this.done = false})
      : action = TextEditingController(text: action),
        owner = TextEditingController(text: owner);
  final TextEditingController action, owner;
  DateTime? due;
  bool done;
  void dispose() {
    action.dispose();
    owner.dispose();
  }
}

class _FullReportCardState extends ConsumerState<_FullReportCard> {
  late final J _report = _m(widget.incident['full_report']);
  bool _editing = false;
  final Map<String, TextEditingController> _c = {};
  final List<TextEditingController> _why = [];
  final List<_CaRow> _ca = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _fill();
  }

  void _fill() {
    for (final (k, _, _) in _reportFields) {
      (_c[k] ??= TextEditingController()).text = _report[k]?.toString() ?? (k == 'immediate_actions' ? _immediateFromDescription() : '');
    }
    for (final w in _why) {
      w.dispose();
    }
    _why
      ..clear()
      ..addAll([for (var n = 0; n < 5; n++) TextEditingController(text: (_report['five_whys'] as List?)?.elementAtOrNull(n)?.toString() ?? '')]);
    for (final r in _ca) {
      r.dispose();
    }
    _ca
      ..clear()
      ..addAll([
        for (final a in _l(_report['corrective_actions']))
          _CaRow(action: str(a['action'], ''), owner: str(a['owner'], ''), due: parseDate(a['due']), done: a['status'] == 'done'),
      ]);
    if (_ca.isEmpty) _ca.add(_CaRow());
  }

  String _immediateFromDescription() {
    final d = widget.incident['description']?.toString() ?? '';
    final i = d.indexOf('Tindakan segera:\n');
    return i < 0 ? '' : d.substring(i + 'Tindakan segera:\n'.length).trim();
  }

  @override
  void dispose() {
    for (final c in [..._c.values, ..._why]) {
      c.dispose();
    }
    for (final r in _ca) {
      r.dispose();
    }
    super.dispose();
  }

  J _build() {
    String d(DateTime x) => '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    return {
      ..._report,
      for (final (k, _, _) in _reportFields) k: _c[k]!.text.trim(),
      'five_whys': [for (final w in _why) if (w.text.trim().isNotEmpty) w.text.trim()],
      'corrective_actions': [
        for (final r in _ca)
          if (r.action.text.trim().isNotEmpty)
            {'action': r.action.text.trim(), 'owner': r.owner.text.trim(), 'due': r.due == null ? null : d(r.due!), 'status': r.done ? 'done' : 'open'},
      ],
      'updated_at_client': DateTime.now().toUtc().toIso8601String(),
    };
  }

  bool get _valid => !_busy && _c['summary']!.text.trim().length >= 10 && _c['immediate_cause']!.text.trim().isNotEmpty;

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await runAction(context, ref, () async {
      await ref.read(apiProvider).rpc('submit_incident_report', {'p_incident': widget.incident['id'], 'p_full_report': _build()});
      return true;
    }, success: 'Full report tersimpan');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final has = _report.isNotEmpty;
    return SectionCard(
      title: 'Full report & investigasi',
      icon: Icons.manage_search_rounded,
      subtitle: has ? 'Diserahkan ${fmtDateTime(widget.incident['full_report_at'])}' : 'Wajib ≤ 24 jam setelah kejadian',
      trailing: widget.editable && has && !_editing
          ? OutlinedButton.icon(onPressed: () => setState(() => _editing = true), icon: const Icon(Icons.edit_rounded, size: 18), label: const Text('Perbarui'))
          : null,
      child: _editing ? _form() : (has ? _view() : _empty()),
    );
  }

  Widget _empty() => EmptyState(
        icon: Icons.description_outlined,
        title: 'Full report belum diserahkan',
        message: widget.editable ? null : 'Contractor/HSE WFRD akan melengkapi laporan ini.',
        action: widget.editable
            ? FilledButton.icon(onPressed: () => setState(() => _editing = true), icon: const Icon(Icons.edit_note_rounded), label: const Text('Isi full report'))
            : null,
      );

  Widget _view() {
    final t = Theme.of(context).textTheme;
    final whys = (_report['five_whys'] as List? ?? const []).map((e) => e.toString()).toList();
    final cas = _l(_report['corrective_actions']);
    final known = {for (final f in _reportFields) f.$1, 'five_whys', 'corrective_actions', 'updated_at_client'};
    final extra = _report.entries.where((e) => !known.contains(e.key) && e.value != null && e.value.toString().isNotEmpty).toList();
    Widget block(String label, String v) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.toUpperCase(), style: t.labelSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            SelectableText(v, style: const TextStyle(height: 1.45)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ResponsiveGrid(minItemWidth: 360, spacing: 20, children: [
        for (final (k, label, _) in _reportFields)
          if ((_report[k]?.toString() ?? '').isNotEmpty) block(label, _report[k].toString()),
        for (final e in extra) block(e.key, e.value.toString()),
      ]),
      if (whys.isNotEmpty) ...[
        const Divider(height: 24),
        const Text('5 Why', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (final (n, w) in whys.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(radius: 11, backgroundColor: Brand.purple.withValues(alpha: 0.14), child: Text('${n + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Brand.purple))),
              const SizedBox(width: 10),
              Expanded(child: Text(w)),
            ]),
          ),
      ],
      const Divider(height: 24),
      Row(children: [
        const Text('Corrective actions', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        if (cas.isNotEmpty) StatusBadge(Brand.green, '${cas.where((a) => a['status'] == 'done').length}/${cas.length} selesai'),
      ]),
      const SizedBox(height: 8),
      if (cas.isEmpty)
        Text('Belum ada corrective action.', style: t.bodySmall)
      else
        for (final a in cas)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(a['status'] == 'done' ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: a['status'] == 'done' ? Brand.green : Brand.amber),
            title: Text(str(a['action']), style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('PIC ${str(a['owner'])} · due ${fmtDate(a['due'])}'),
            trailing: a['status'] == 'done' || a['due'] == null ? null : StatusBadge(dueColor(a['due']), dueLabel(a['due'])),
          ),
    ]);
  }

  Widget _form() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ResponsiveGrid(minItemWidth: 360, spacing: 16, children: [
        for (final (k, label, hint) in _reportFields)
          TextField(
            controller: _c[k],
            maxLines: 4,
            minLines: 2,
            maxLength: 6000,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: '$label${k == 'summary' || k == 'immediate_cause' ? ' *' : ''}',
              hintText: hint,
              alignLabelWithHint: true,
            ),
          ),
      ]),
      const SizedBox(height: 8),
      const Text('5 Why (analisis akar masalah)', style: TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      for (final (n, w) in _why.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(controller: w, maxLength: 500, decoration: InputDecoration(labelText: 'Why ${n + 1}', counterText: '', prefixIcon: const Icon(Icons.help_outline_rounded, size: 18))),
        ),
      const SizedBox(height: 8),
      Row(children: [
        const Expanded(child: Text('Corrective actions', style: TextStyle(fontWeight: FontWeight.w800))),
        TextButton.icon(onPressed: () => setState(() => _ca.add(_CaRow())), icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Tambah')),
      ]),
      const SizedBox(height: 8),
      for (final (n, r) in _ca.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth > 720;
            final due = InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(context: context, firstDate: now.subtract(const Duration(days: 365)), lastDate: now.add(const Duration(days: 730)), initialDate: r.due ?? now.add(const Duration(days: 14)));
                if (picked != null) setState(() => r.due = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Due', suffixIcon: Icon(Icons.event_rounded, size: 18)),
                child: Text(r.due == null ? '-' : fmtDate(r.due!.toIso8601String())),
              ),
            );
            final fields = [
              TextField(controller: r.action, decoration: InputDecoration(labelText: 'Tindakan ${n + 1}')),
              TextField(controller: r.owner, decoration: const InputDecoration(labelText: 'PIC')),
              due,
            ];
            final tail = Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: r.done, onChanged: (v) => setState(() => r.done = v ?? false)),
              const Text('Selesai'),
              IconButton(
                tooltip: 'Hapus',
                onPressed: _ca.length == 1
                    ? null
                    : () => setState(() {
                          _ca.removeAt(n).dispose();
                        }),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ]);
            if (!wide) return Column(children: [for (final f in fields) Padding(padding: const EdgeInsets.only(bottom: 8), child: f), Align(alignment: Alignment.centerRight, child: tail)]);
            return Row(children: [
              Expanded(flex: 5, child: fields[0]),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: fields[1]),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: fields[2]),
              tail,
            ]);
          }),
        ),
      const SizedBox(height: 12),
      Wrap(alignment: WrapAlignment.end, spacing: 10, runSpacing: 10, children: [
        if (_report.isNotEmpty)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _fill();
                      _editing = false;
                    }),
            child: const Text('Batal'),
          ),
        FilledButton.icon(
          onPressed: _valid ? _save : null,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded),
          label: Text(_report.isEmpty ? 'Serahkan full report' : 'Simpan perubahan'),
        ),
      ]),
    ]);
  }
}

// ── WFRD: reklasifikasi & penutupan (manage_incident) ──
class _ManageMenu extends ConsumerWidget {
  const _ManageMenu({required this.d, required this.onChanged});
  final _Detail d;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i = d.incident;
    final rcaOk = d.rca == null || d.rca!['any_done'] == true;
    final reportOk = i['full_report'] != null;
    return Wrap(spacing: 8, children: [
      OutlinedButton.icon(
        onPressed: () async {
          final r = await showDialog<(String, String, bool, String)>(context: context, builder: (_) => _ReclassifyDialog(i: i));
          if (r == null || !context.mounted) return;
          final ok = await runAction(context, ref, () async {
            await ref.read(apiProvider).rpc('manage_incident', {
              'p_incident': i['id'],
              'p_type': r.$1,
              'p_severity': r.$2,
              'p_high_potential': r.$3,
              'p_close': false,
              'p_reason': r.$4,
            });
            return true;
          }, success: 'Klasifikasi insiden diperbarui');
          if (ok == true) onChanged();
        },
        icon: const Icon(Icons.tune_rounded),
        label: const Text('Reklasifikasi'),
      ),
      FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: Brand.navy),
        onPressed: () async {
          if (!reportOk || !rcaOk) {
            await showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                icon: const Icon(Icons.lock_clock_rounded, color: Brand.amber, size: 36),
                title: const Text('Belum bisa ditutup'),
                content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _check(reportOk, 'Full report sudah diserahkan'),
                  _check(rcaOk, 'Task RCA (INVRPT) approved / waived'),
                ]),
                actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Mengerti'))],
              ),
            );
            return;
          }
          final r = await showReasonDialog(context,
              title: 'Tutup insiden ${i['incident_no']}', message: 'Insiden akan dikunci (read-only). Pastikan semua corrective action sudah ditindaklanjuti.', confirmLabel: 'Tutup insiden');
          if (r == null || !context.mounted) return;
          final ok = await runAction(context, ref, () async {
            await ref.read(apiProvider).rpc('manage_incident', {
              'p_incident': i['id'],
              'p_type': null,
              'p_severity': null,
              'p_high_potential': null,
              'p_close': true,
              'p_reason': r,
            });
            return true;
          }, success: 'Insiden ditutup');
          if (ok == true) onChanged();
        },
        icon: const Icon(Icons.lock_rounded),
        label: const Text('Tutup insiden'),
      ),
    ]);
  }

  static Widget _check(bool ok, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded, color: ok ? Brand.green : Brand.red, size: 20),
          const SizedBox(width: 8),
          Text(label),
        ]),
      );
}

class _ReclassifyDialog extends StatefulWidget {
  const _ReclassifyDialog({required this.i});
  final J i;
  @override
  State<_ReclassifyDialog> createState() => _ReclassifyDialogState();
}

class _ReclassifyDialogState extends State<_ReclassifyDialog> {
  late String _type = widget.i['type'] as String;
  late String _severity = widget.i['severity'] as String;
  late bool _hipo = widget.i['high_potential'] == true;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sev = _type == 'fatality' ? 'critical' : _severity;
    final changed = _type != widget.i['type'] || sev != widget.i['severity'] || _hipo != (widget.i['high_potential'] == true);
    return AlertDialog(
      title: const Text('Reklasifikasi insiden'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(
            initialValue: _type,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Jenis'),
            items: [for (final e in _types.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: [for (final e in _severities.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {sev},
            onSelectionChanged: _type == 'fatality' ? null : (v) => setState(() => _severity = v.first),
          ),
          SwitchListTile(
            value: _hipo,
            onChanged: (v) => setState(() => _hipo = v),
            contentPadding: EdgeInsets.zero,
            title: const Text('High potential (HiPo)'),
          ),
          TextField(
            controller: _reason,
            maxLines: 2,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Alasan *', helperText: 'Minimal 5 karakter · tercatat di audit log'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: changed && _reason.text.trim().length >= 5 ? () => Navigator.pop(context, (_type, sev, _hipo, _reason.text.trim())) : null,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
