import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/errors/app_failure.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'contract_common.dart';
import 'contract_tabs.dart';

const _contractCols = 'id,contract_seq,contract_no,contractor_id,title,scope_of_work,geozone,site,risk_class,start_date,end_date,'
    'target_mob_date,awarded_at,process_owner_id,hse_reviewer_id,review_mailbox,premob_questionnaire,status,status_before_hold,'
    'health_flag,compressed_timeline,golive_requested_at,golive_requested_by,golive_approved_at,golive_approved_by,closed_at,'
    'created_at,updated_at';

/// Data inti kontrak yang dipakai semua tab.
class ContractCtx {
  ContractCtx(this.k, this.contractor, this.users);
  final J k;
  final J contractor;
  final Map<String, J> users;
  String get id => k['id'] as String;
  String get status => k['status'] as String;
  bool get isFinal => status == 'closed' || status == 'terminated';
  String get contractorId => k['contractor_id'] as String;
}

const _tabs = <(String, String, IconData)>[
  ('overview', 'Ringkasan', Icons.dashboard_rounded),
  ('tasks', 'Tasks', Icons.checklist_rounded),
  ('premob', 'Pre-Mob', Icons.quiz_rounded),
  ('subcontractors', 'Subkontraktor', Icons.groups_2_rounded),
  ('risks', 'Risiko / JRA', Icons.warning_amber_rounded),
  ('meetings', 'Meeting', Icons.event_note_rounded),
  ('incidents', 'Insiden', Icons.report_gmailerrorred_rounded),
  ('kpi', 'KPI', Icons.speed_rounded),
  ('onedrive', 'OneDrive', Icons.cloud_upload_rounded),
];

class ContractDetailPage extends ConsumerStatefulWidget {
  const ContractDetailPage({super.key, required this.id, this.initialTab});
  final String id;
  final String? initialTab;
  @override
  ConsumerState<ContractDetailPage> createState() => _ContractDetailPageState();
}

class _ContractDetailPageState extends ConsumerState<ContractDetailPage> {
  late Future<ContractCtx> _future = _load();
  late String _tab = widget.initialTab ?? 'overview';
  int _rev = 0;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(notificationBus).stream.listen((_) => _reload());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ContractDetailPage old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _reload();
    if (old.initialTab != widget.initialTab && widget.initialTab != null) setState(() => _tab = widget.initialTab!);
  }

  Future<ContractCtx> _load() async {
    final api = ref.read(apiProvider);
    final k = await api.selectOne('contracts', _contractCols, 'id', widget.id);
    if (k == null) throw const AppFailure(Hint.forbidden, 'Kontrak tidak ditemukan atau Anda tidak memiliki akses.');
    final r = await Future.wait([
      api.selectOne('contractors', Cols.contractors, 'id', k['contractor_id'] as String),
      loadUserCards(api, [k['process_owner_id'], k['hse_reviewer_id'], k['golive_requested_by'], k['golive_approved_by']]),
    ]);
    return ContractCtx(k, r[0] ?? <String, dynamic>{}, r[1] as Map<String, J>);
  }

  void _reload() {
    if (mounted) {
      setState(() {
        _future = _load();
        _rev++;
      });
    }
  }

  Future<void> _openChat() async {
    final chs = await runAction<List<J>>(context, ref, () => ref.read(apiProvider).rpcList('list_my_channels'));
    if (chs == null || !mounted) return;
    final ch = chs.where((c) => c['contract_id'] == widget.id && c['type'] == 'contract').firstOrNull;
    if (ch == null) {
      showSnack(context, 'Anda belum menjadi anggota channel kontrak ini.', error: true);
      return;
    }
    context.go('/chat/${ch['id']}');
  }

  List<(String, String, IconData)> _visibleTabs(SessionState s) =>
      _tabs.where((t) => t.$1 != 'onedrive' || (s.isWfrd && s.can('upload_link.view'))).toList();

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref);
    if (s == null) return const LoadingView();
    return AsyncView<ContractCtx>(
      future: _future,
      onRetry: _reload,
      builder: (context, c) {
        final tabs = _visibleTabs(s);
        final current = tabs.any((t) => t.$1 == _tab) ? _tab : 'overview';
        return PageScaffold(
          title: str(c.k['contract_no'], 'Kontrak'),
          subtitle: '${c.k['title']} · ${str(c.contractor['legal_name'])}',
          leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.canPop() ? context.pop() : context.go('/contracts')),
          actions: [
            IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
            if (s.can('chat.use')) OutlinedButton.icon(onPressed: _openChat, icon: const Icon(Icons.forum_rounded), label: const Text('Chat kontrak')),
            if (s.can('incident.report') && !c.isFinal)
              OutlinedButton.icon(
                onPressed: () => context.go('/incidents/new?contract=${c.id}'),
                icon: const Icon(Icons.report_gmailerrorred_rounded, color: Brand.red),
                label: const Text('Lapor insiden'),
              ),
            if (s.isWfrd && s.can('contract.edit') && !c.isFinal)
              FilledButton.tonalIcon(
                onPressed: () async {
                  final ok = await showDialog<bool>(context: context, builder: (_) => _EditContractDialog(c: c));
                  if (ok == true) _reload();
                },
                icon: const Icon(Icons.edit_rounded),
                label: const Text('Edit'),
              ),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Card(
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(children: [
                  for (final t in tabs)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _TabPill(label: t.$2, icon: t.$3, selected: t.$1 == current, onTap: () => setState(() => _tab = t.$1)),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            KeyedSubtree(
              key: ValueKey('$current-$_rev'),
              child: switch (current) {
                'tasks' => ContractTasksTab(c: c),
                'premob' => _PremobTab(c: c, onChanged: _reload),
                'subcontractors' => ContractSubcontractorsTab(c: c),
                'risks' => ContractRisksTab(c: c),
                'meetings' => ContractMeetingsTab(c: c),
                'incidents' => ContractIncidentsTab(c: c),
                'kpi' => ContractKpiTab(c: c),
                'onedrive' => ContractOneDriveTab(c: c),
                _ => _OverviewTab(c: c, onChanged: _reload, onTab: (t) => setState(() => _tab = t)),
              },
            ),
          ]),
        );
      },
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: selected ? Brand.blue : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: selected ? Colors.white : Brand.grey),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: selected ? Colors.white : null)),
            ]),
          ),
        ),
      );
}

// ═══════════════════════════ Ringkasan ═══════════════════════════
class _OverviewData {
  _OverviewData(this.tasks, this.meetings, this.blockers, this.oprSigned);
  final List<J> tasks, meetings, blockers;
  final bool oprSigned;
}

class _OverviewTab extends ConsumerStatefulWidget {
  const _OverviewTab({required this.c, required this.onChanged, required this.onTab});
  final ContractCtx c;
  final VoidCallback onChanged;
  final ValueChanged<String> onTab;
  @override
  ConsumerState<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends ConsumerState<_OverviewTab> {
  late Future<_OverviewData> _future = _load();
  bool _busy = false;

  ContractCtx get c => widget.c;

  Future<_OverviewData> _load() async {
    final api = ref.read(apiProvider);
    final st = c.status;
    final r = await Future.wait<dynamic>([
      api.select('v_task_tracking', 'id,task_id,title,doc_label,doc_type_code,status,phase,is_mandatory,is_blocker,is_overdue,review_overdue,due_date,revision',
          build: (q) => q.eq('contract_id', c.id).order('due_date', ascending: true).limit(1000)),
      api.select('meetings', 'id,meeting_type,mom_no,status,scheduled_at', build: (q) => q.eq('contract_id', c.id).order('scheduled_at', ascending: false)),
      st == 'pre_mobilization'
          ? api.rpcList('mobilization_blockers', {'p_contract': c.id})
          : st == 'demobilization'
              ? api.rpcList('demob_blockers', {'p_contract': c.id})
              : Future.value(<J>[]),
      st == 'final_evaluation'
          ? api.select('opr_reviews', 'id,status', build: (q) => q.eq('contract_id', c.id).eq('status', 'signed').limit(1))
          : Future.value(<J>[]),
    ]);
    return _OverviewData(r[0] as List<J>, r[1] as List<J>, r[2] as List<J>, (r[3] as List<J>).isNotEmpty);
  }

  Future<void> _transition(String target, String title, String message, {bool destructive = false}) async {
    final reason = target == 'terminated'
        ? await showConfirmPhraseDialog(context, title: title, message: message)
        : await showReasonDialog(context, title: title, message: message, confirmLabel: 'Lanjutkan', destructive: destructive);
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('transition_contract', {'p_contract': c.id, 'p_target': target, 'p_reason': reason}),
        success: 'Status kontrak → ${StatusStyle.contract(target).$2}');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onChanged();
  }

  Future<void> _requestGoLive() async {
    final yes = await showConfirm(context,
        title: 'Ajukan Go-Live?', message: 'Checklist mobilisasi (MOBCHK) harus sudah 100% terverifikasi & approved. PO kontrak akan diberi tahu.', confirmLabel: 'Ajukan');
    if (!yes || !mounted) return;
    setState(() => _busy = true);
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('request_go_live', {'p_contract': c.id}), success: 'Permintaan Go-Live terkirim');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onChanged();
  }

  Future<void> _approveGoLive() async {
    final reason = await showReasonDialog(context,
        title: 'Approve Go-Live', message: 'Kontrak akan berstatus ACTIVE dan contractor menerima email #4004.', confirmLabel: 'Approve Go-Live', fieldLabel: 'Catatan persetujuan');
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('approve_go_live', {'p_contract': c.id, 'p_reason': reason}), success: 'Go-Live disetujui · kontrak ACTIVE');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onChanged();
  }

  static bool premobComplete(J q) {
    const keys = ['has_confined_space', 'has_hot_work', 'has_work_at_height', 'has_chemicals', 'near_water', 'has_driving', 'generates_waste', 'has_subcontractor'];
    return keys.every((k) => q[k] is bool) && q['max_workers_on_site'] is num && (q['max_workers_on_site'] as num) >= 0;
  }

  void _openTaskByRef(List<J> tasks, String? ref, {bool byDocType = false}) {
    final t = tasks.where((x) => byDocType ? x['doc_type_code'] == ref : x['task_id'] == ref).toList()
      ..sort((a, b) => ((b['revision'] as num?) ?? 0).compareTo((a['revision'] as num?) ?? 0));
    if (t.isNotEmpty) context.go('/tasks/${t.first['id']}');
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref)!;
    final k = c.k;
    return AsyncView<_OverviewData>(
      future: _future,
      onRetry: () => setState(() => _future = _load()),
      builder: (context, d) {
        final open = d.tasks.where((t) => const {'open', 'awaiting_email', 'file_issue'}.contains(t['status'])).length;
        final overdue = d.tasks.where((t) => t['is_overdue'] == true).length;
        final review = d.tasks.where((t) => const {'submitted', 'under_review'}.contains(t['status'])).length;
        final relevant = d.tasks.where((t) => !const {'superseded', 'cancelled'}.contains(t['status'])).toList();
        final done = relevant.where((t) => const {'approved', 'waived'}.contains(t['status'])).length;
        final pct = relevant.isEmpty ? 0.0 : done / relevant.length;
        final hero = HeroHeader(
          title: str(k['title']),
          icon: Icons.handshake_rounded,
          gradient: c.status == 'suspended' || c.status == 'terminated'
              ? const LinearGradient(colors: [Color(0xFF7A271A), Brand.red])
              : Brand.heroGradient,
          lines: [
            '${str(k['contract_no'])} · ${str(c.contractor['legal_name'])}',
            'Fase: ${StatusStyle.contract(c.status).$2}${c.status == 'suspended' ? ' (sebelumnya ${StatusStyle.contract(k['status_before_hold'] as String?).$2})' : ''}',
          ],
          chips: [
            HeroChip(StatusStyle.contract(c.status).$2, icon: Icons.flag_rounded),
            HeroChip('Health ${healthLabel(k['health_flag'] as String?)}', icon: Icons.monitor_heart_rounded),
            HeroChip('Risiko ${riskClassLabel[k['risk_class']] ?? '-'}', icon: Icons.shield_rounded),
            HeroChip('${str(k['geozone'])}${k['site'] == null ? '' : ' · ${k['site']}'}', icon: Icons.place_rounded),
            if (k['compressed_timeline'] == true) const HeroChip('Timeline dipadatkan', icon: Icons.compress_rounded),
          ],
          trailing: SizedBox(
            width: 74,
            height: 74,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(value: pct, strokeWidth: 7, backgroundColor: Colors.white24, color: Colors.white),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${(pct * 100).round()}%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
                const Text('task', style: TextStyle(color: Colors.white70, fontSize: 10)),
              ]),
            ]),
          ),
        );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          hero,
          if (k['health_flag'] == 'red') ...[
            const SizedBox(height: 12),
            const InfoBanner(message: 'Kesehatan kontrak MERAH — cek task overdue, dokumen gate kedaluwarsa, atau KPI.', color: Brand.red, icon: Icons.local_fire_department_rounded),
          ],
          if (c.isFinal) ...[
            const SizedBox(height: 12),
            InfoBanner(
              message: 'Kontrak ${StatusStyle.contract(c.status).$2.toLowerCase()} pada ${fmtDateTime(k['closed_at'])} — data read-only, channel diarsipkan.',
              color: Brand.grey,
              icon: Icons.lock_rounded,
            ),
          ],
          const SizedBox(height: 16),
          SectionCard(title: 'Fase kontrak', icon: Icons.timeline_rounded, child: ContractPhaseStepper(status: c.status, statusBeforeHold: k['status_before_hold'] as String?)),
          const SizedBox(height: 16),
          ResponsiveGrid(minItemWidth: 200, children: [
            StatCard(label: 'Task terbuka', value: '$open', icon: Icons.assignment_rounded, onTap: () => widget.onTab('tasks')),
            StatCard(label: 'Overdue', value: '$overdue', icon: Icons.alarm_rounded, color: overdue > 0 ? Brand.red : Brand.green, onTap: () => widget.onTab('tasks')),
            StatCard(label: 'Dalam review', value: '$review', icon: Icons.fact_check_rounded, color: Brand.purple, onTap: () => widget.onTab('tasks')),
            StatCard(label: 'Selesai', value: '$done/${relevant.length}', icon: Icons.verified_rounded, color: Brand.green, onTap: () => widget.onTab('tasks')),
          ]),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, box) {
            final gate = _gateCard(s, d);
            final info = _infoCard();
            return box.maxWidth >= 1000
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 5, child: gate), const SizedBox(width: 16), Expanded(flex: 4, child: info)])
                : Column(children: [gate, const SizedBox(height: 16), info]);
          }),
          if (k['scope_of_work'] != null) ...[
            const SizedBox(height: 16),
            SectionCard(title: 'Scope of work', icon: Icons.description_rounded, child: SelectableText(str(k['scope_of_work']), style: const TextStyle(height: 1.5))),
          ],
          if (s.isWfrd && s.can('contract.transition') && !c.isFinal) ...[
            const SizedBox(height: 16),
            _holdCard(),
          ],
        ]);
      },
    );
  }

  Widget _infoCard() {
    final k = c.k;
    final po = c.users[k['process_owner_id']];
    final rv = c.users[k['hse_reviewer_id']];
    return SectionCard(
      title: 'Detail kontrak',
      icon: Icons.info_outline_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValueGrid(minItemWidth: 180, [
          ('Nomor', MonoText(str(k['contract_no']))),
          ('Contractor', Text(str(c.contractor['legal_name']))),
          ('Award', Text(fmtDate(k['awarded_at']))),
          ('Mulai', Text(fmtDate(k['start_date']))),
          ('Target mobilisasi', Text(fmtDate(k['target_mob_date']))),
          ('Selesai', Text(fmtDate(k['end_date']))),
          ('Mailbox review', SelectableText(str(k['review_mailbox']))),
          ('Kelas risiko', StatusBadge(riskClassColor(k['risk_class'] as String?), riskClassLabel[k['risk_class']] ?? '-')),
          if (k['golive_requested_at'] != null) ('Go-Live diminta', Text(fmtDateTime(k['golive_requested_at']))),
          if (k['golive_approved_at'] != null) ('Go-Live disetujui', Text(fmtDateTime(k['golive_approved_at']))),
        ]),
        const Divider(height: 28),
        UserCardTile(card: po, fallbackId: k['process_owner_id'] as String?, caption: 'Process Owner'),
        UserCardTile(card: rv, fallbackId: k['hse_reviewer_id'] as String?, caption: 'HSE Reviewer'),
      ]),
    );
  }

  Widget _gateCard(SessionState s, _OverviewData d) {
    final k = c.k;
    final canTransition = s.isWfrd && s.can('contract.transition');
    final items = <Widget>[];
    Widget? action;
    String title;
    String? subtitle;

    Widget btn(String label, IconData icon, VoidCallback? onPressed, {Color? color}) => FilledButton.icon(
          onPressed: _busy ? null : onPressed,
          style: color == null ? null : FilledButton.styleFrom(backgroundColor: color),
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Icon(icon),
          label: Text(label),
        );

    switch (c.status) {
      case 'awarded':
        title = 'Gate → Post-Award';
        subtitle = 'Mulai persiapan post-award: key personnel, questionnaire, meeting post-award.';
        items.add(const GateItem(ok: true, label: 'Kontrak dibuat untuk vendor ASL aktif'));
        if (canTransition) action = btn('Mulai Post-Award', Icons.play_arrow_rounded, () => _transition('post_award', 'Mulai fase Post-Award', 'Status kontrak menjadi Post-Award.'));
      case 'post_award':
        title = 'Gate → Pre-Mobilization (R6)';
        final signed = d.meetings.any((m) => m['meeting_type'] == 'post_award' && m['status'] == 'signed');
        final pm = d.meetings.where((m) => m['meeting_type'] == 'post_award').firstOrNull;
        final q = premobComplete(jm(k['premob_questionnaire']));
        items
          ..add(GateItem(
            ok: signed,
            label: 'MoM post-award ditandatangani kedua pihak',
            detail: pm == null ? 'Belum ada meeting post-award' : '${pm['mom_no']} · ${StatusStyle.generic(pm['status'] as String?).$2}',
            onTap: () => pm == null ? widget.onTab('meetings') : context.go('/contracts/${c.id}/meetings/${pm['id']}'),
          ))
          ..add(GateItem(ok: q, label: 'Pre-Mob Questionnaire lengkap', detail: q ? null : '8 pertanyaan ya/tidak + jumlah pekerja maksimum', onTap: () => widget.onTab('premob')));
        if (canTransition) {
          action = btn('Lanjut ke Pre-Mobilization', Icons.arrow_forward_rounded, signed && q
              ? () => _transition('pre_mobilization', 'Masuk Pre-Mobilization', 'Rules engine akan menghitung dokumen wajib & membuat task pre-mob secara massal.')
              : null);
        }
      case 'pre_mobilization':
        title = 'Gate → Mobilization (R7)';
        subtitle = d.blockers.isEmpty ? 'Tidak ada blocker — siap mobilisasi.' : '${d.blockers.length} blocker harus diselesaikan.';
        if (d.blockers.isEmpty) items.add(const GateItem(ok: true, label: 'mobilization_blockers() kosong'));
        for (final b in d.blockers.take(25)) {
          final code = b['code'] as String?;
          items.add(GateItem(
            ok: false,
            label: '${blockerLabel[code] ?? code} · ${str(b['ref'])}',
            detail: b['detail'] as String?,
            onTap: switch (code) {
              'gate_document' => () => _openTaskByRef(d.tasks, b['ref'] as String?, byDocType: true),
              'blocker_task' => () => _openTaskByRef(d.tasks, b['ref'] as String?),
              'subcontractor_pending' => () => widget.onTab('subcontractors'),
              'residual_critical' || 'residual_high' => () => widget.onTab('risks'),
              _ => null,
            },
          ));
        }
        if (d.blockers.length > 25) items.add(Text('+${d.blockers.length - 25} blocker lainnya', style: const TextStyle(color: Brand.grey)));
        if (canTransition) {
          action = btn('Mulai Mobilisasi', Icons.local_shipping_rounded,
              d.blockers.isEmpty ? () => _transition('mobilization', 'Mulai Mobilisasi', 'Task MOBCHK dibuat dan contractor menerima email #4003.') : null);
        }
      case 'mobilization':
        title = 'Gate → Go-Live (R9)';
        final mob = (d.tasks.where((t) => t['doc_type_code'] == 'MOBCHK').toList()
              ..sort((a, b) => ((b['revision'] as num?) ?? 0).compareTo((a['revision'] as num?) ?? 0)))
            .firstOrNull;
        final mobOk = mob != null && mob['status'] == 'approved';
        final requested = k['golive_requested_at'] != null;
        items
          ..add(GateItem(
            ok: mobOk,
            label: 'Checklist mobilisasi (MOBCHK) 100% terverifikasi & approved',
            detail: mob == null ? 'Task MOBCHK belum ada' : '${mob['task_id']} · ${StatusStyle.task(mob['status'] as String?).$2}',
            onTap: mob == null ? null : () => context.go('/tasks/${mob['id']}'),
          ))
          ..add(GateItem(
            ok: requested,
            label: 'Contractor mengajukan Go-Live',
            detail: requested ? '${fmtDateTime(k['golive_requested_at'])} · ${str(c.users[k['golive_requested_by']]?['full_name'])}' : null,
          ))
          ..add(const GateItem(ok: false, label: 'Persetujuan PO kontrak / HSE Director'));
        if (!s.isWfrd && s.can('contract.golive.request') && !requested) {
          action = btn('Ajukan Go-Live', Icons.rocket_launch_rounded, mobOk ? _requestGoLive : null, color: Brand.purple);
        } else if (s.isWfrd && s.can('contract.golive.approve') && requested) {
          action = btn('Approve Go-Live', Icons.verified_rounded, _approveGoLive, color: Brand.green);
        }
      case 'active':
        title = 'Eksekusi & monitoring';
        subtitle = 'Record harian/mingguan, laporan bulanan MONRPT, KPI otomatis.';
        items.add(GateItem(ok: true, label: 'Go-Live disetujui', detail: fmtDateTime(k['golive_approved_at'])));
        if (canTransition) {
          action = btn('Mulai Demobilisasi', Icons.logout_rounded,
              () => _transition('demobilization', 'Mulai Demobilisasi', 'Task DMBCHK, WSTMNF, FINRPT dibuat. Contractor menerima email #4006.'));
        }
      case 'demobilization':
        title = 'Gate → Final Evaluation (R10)';
        subtitle = d.blockers.isEmpty ? 'Demobilisasi bersih.' : '${d.blockers.length} blocker demobilisasi.';
        if (d.blockers.isEmpty) items.add(const GateItem(ok: true, label: 'demob_blockers() kosong'));
        for (final b in d.blockers.take(25)) {
          final code = b['code'] as String?;
          items.add(GateItem(
            ok: false,
            label: '${blockerLabel[code] ?? code} · ${str(b['ref'])}',
            detail: b['detail'] as String?,
            onTap: switch (code) {
              'task_open' => () => _openTaskByRef(d.tasks, b['ref'] as String?),
              'demob_checklist' => () => _openTaskByRef(d.tasks, 'DMBCHK', byDocType: true),
              'incident_open' => () => widget.onTab('incidents'),
              _ => null,
            },
          ));
        }
        if (canTransition) {
          action = btn('Lanjut ke Final Evaluation', Icons.grading_rounded,
              d.blockers.isEmpty ? () => _transition('final_evaluation', 'Masuk Final Evaluation', 'Task OPR self-evaluation (OPRSLF) dibuat untuk contractor.') : null);
        }
      case 'final_evaluation':
        title = 'Gate → Close-out';
        final opr = d.tasks.where((t) => t['doc_type_code'] == 'OPRSLF').toList();
        final oprDone = opr.isNotEmpty && opr.every((t) => !const {'open', 'awaiting_email', 'file_issue', 'submitted', 'under_review'}.contains(t['status']));
        items
          ..add(GateItem(ok: d.oprSigned, label: 'OPR review WFRD ditandatangani kedua pihak'))
          ..add(GateItem(
            ok: oprDone,
            label: 'OPR self-evaluation contractor (OPRSLF) selesai / waived',
            onTap: opr.isEmpty ? null : () => context.go('/tasks/${opr.first['id']}'),
          ));
        if (canTransition) {
          action = btn('Tutup kontrak', Icons.lock_rounded, d.oprSigned && oprDone
              ? () => _transition('closed', 'Tutup kontrak', 'Data menjadi read-only, channel diarsipkan, ASL ter-update. Contractor menerima email #4008.')
              : null);
        }
      case 'suspended':
        title = 'Kontrak on hold';
        subtitle = 'Resume hanya ke status sebelum hold.';
        items.add(GateItem(ok: false, label: 'Status sebelum hold: ${StatusStyle.contract(k['status_before_hold'] as String?).$2}'));
        if (canTransition && k['status_before_hold'] != null) {
          action = btn('Resume', Icons.play_arrow_rounded, () => _transition(k['status_before_hold'] as String, 'Resume kontrak',
              'Kontrak kembali ke ${StatusStyle.contract(k['status_before_hold'] as String?).$2}.'), color: Brand.green);
        }
      default:
        title = 'Kontrak final';
        items.add(GateItem(ok: true, label: StatusStyle.contract(c.status).$2, detail: fmtDateTime(k['closed_at'])));
    }

    return SectionCard(
      title: title,
      subtitle: subtitle,
      icon: Icons.verified_user_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...items,
        if (action != null) ...[const SizedBox(height: 12), Align(alignment: Alignment.centerRight, child: action)],
        if (action == null && !c.isFinal && !s.isWfrd && c.status != 'mobilization')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Perpindahan fase dilakukan oleh WFRD setelah semua gate terpenuhi.', style: Theme.of(context).textTheme.bodySmall),
          ),
      ]),
    );
  }

  Widget _holdCard() {
    final suspended = c.status == 'suspended';
    return SectionCard(
      title: 'Hold & terminasi',
      subtitle: 'Aksi tercatat di audit log, contractor diberi tahu.',
      icon: Icons.gpp_maybe_rounded,
      child: Wrap(spacing: 12, runSpacing: 12, children: [
        if (!suspended)
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _transition('suspended', 'Hold (suspend) kontrak', 'Kontrak dihentikan sementara; bisa di-resume ke status saat ini.', destructive: true),
            icon: const Icon(Icons.pause_circle_rounded, color: Brand.amber),
            label: const Text('Hold kontrak'),
          ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Brand.red, side: const BorderSide(color: Brand.red)),
          onPressed: _busy
              ? null
              : () => _transition('terminated', 'Terminasi kontrak',
                  'Tindakan FINAL: semua task terbuka dibatalkan, finding dibatalkan, channel diarsipkan. Tidak bisa dibatalkan.'),
          icon: const Icon(Icons.dangerous_rounded),
          label: const Text('Terminasi'),
        ),
      ]),
    );
  }
}

// ═══════════════════════════ Pre-Mob questionnaire ═══════════════════════════
const _premobQuestions = <(String, String, IconData)>[
  ('has_confined_space', 'Pekerjaan di ruang terbatas (confined space)?', Icons.sensor_door_outlined),
  ('has_hot_work', 'Ada pekerjaan panas (hot work)?', Icons.local_fire_department_outlined),
  ('has_work_at_height', 'Ada pekerjaan di ketinggian?', Icons.height_rounded),
  ('has_chemicals', 'Menggunakan bahan kimia berbahaya?', Icons.science_outlined),
  ('near_water', 'Bekerja di dekat / di atas air?', Icons.water_rounded),
  ('has_driving', 'Ada aktivitas mengemudi?', Icons.directions_car_outlined),
  ('generates_waste', 'Menghasilkan limbah?', Icons.delete_outline_rounded),
  ('has_subcontractor', 'Menggunakan subkontraktor?', Icons.groups_2_outlined),
];

class _PremobData {
  _PremobData(this.reqs, this.labels);
  final List<J> reqs;
  final Map<String, J> labels;
}

class _PremobTab extends ConsumerStatefulWidget {
  const _PremobTab({required this.c, required this.onChanged});
  final ContractCtx c;
  final VoidCallback onChanged;
  @override
  ConsumerState<_PremobTab> createState() => _PremobTabState();
}

class _PremobTabState extends ConsumerState<_PremobTab> {
  late final Map<String, dynamic> _a = Map<String, dynamic>.from(jm(widget.c.k['premob_questionnaire']));
  late final _workers = TextEditingController(text: _a['max_workers_on_site']?.toString() ?? '');
  late Future<_PremobData> _future = _load();
  bool _busy = false, _dirty = false;

  Future<_PremobData> _load() async {
    final api = ref.read(apiProvider);
    final r = await Future.wait([
      api.select('contract_requirements', 'doc_type_code,applicable,is_mandatory,is_mob_gate,reason,computed_at', build: (q) => q.eq('contract_id', widget.c.id).order('doc_type_code')),
      api.select('doc_type_catalog', 'code,label,phase,kind', build: (q) => q.eq('active', true).order('code')),
    ]);
    return _PremobData(r[0], {for (final d in r[1]) d['code'] as String: d});
  }

  Future<void> _save() async {
    final w = int.tryParse(_workers.text.trim());
    final answers = <String, dynamic>{
      for (final q in _premobQuestions)
        if (_a[q.$1] is bool) q.$1: _a[q.$1],
      if (w != null) 'max_workers_on_site': w,
    };
    setState(() => _busy = true);
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('save_premob_questionnaire', {'p_contract': widget.c.id, 'p_answers': answers}),
        success: 'Questionnaire tersimpan');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _dirty = false;
    });
    if (ok) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref)!;
    final st = widget.c.status;
    final editable = const {'awarded', 'post_award'}.contains(st) && (s.isWfrd ? s.can('contract.edit') : s.can('record.submit'));
    final answered = _premobQuestions.where((q) => _a[q.$1] is bool).length + (int.tryParse(_workers.text.trim()) != null ? 1 : 0);
    final total = _premobQuestions.length + 1;
    final questionnaire = SectionCard(
      title: 'Pre-Mob Questionnaire',
      subtitle: editable ? 'Jawaban menentukan dokumen pre-mob kondisional.' : 'Terkunci setelah pre-mobilization (perubahan via MOC).',
      icon: Icons.quiz_rounded,
      trailing: StatusBadge(answered == total ? Brand.green : Brand.amber, '$answered/$total terjawab'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LinearProgressIndicator(value: answered / total, minHeight: 6, borderRadius: BorderRadius.circular(6)),
        const SizedBox(height: 12),
        for (final q in _premobQuestions)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(q.$3, size: 20, color: Brand.blue),
                  const SizedBox(width: 10),
                  Flexible(child: Text(q.$2, style: const TextStyle(fontWeight: FontWeight.w600))),
                ]),
              ),
              SegmentedButton<bool>(
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                segments: const [ButtonSegment(value: true, label: Text('Ya')), ButtonSegment(value: false, label: Text('Tidak'))],
                selected: _a[q.$1] is bool ? {_a[q.$1] as bool} : <bool>{},
                onSelectionChanged: editable
                    ? (v) => setState(() {
                          _dirty = true;
                          if (v.isEmpty) {
                            _a.remove(q.$1);
                          } else {
                            _a[q.$1] = v.first;
                          }
                        })
                    : null,
              ),
            ]),
          ),
        const SizedBox(height: 8),
        SizedBox(
          width: 280,
          child: TextField(
            controller: _workers,
            enabled: editable,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(labelText: 'Jumlah pekerja maksimum di site *', prefixIcon: Icon(Icons.engineering_rounded)),
          ),
        ),
        if (editable) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy || !_dirty ? null : _save,
              icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_rounded),
              label: const Text('Simpan questionnaire'),
            ),
          ),
        ],
      ]),
    );
    final reqs = SectionCard(
      title: 'Dokumen yang berlaku (rules engine)',
      subtitle: 'Hasil build_contract_requirements untuk kontrak ini',
      icon: Icons.rule_folder_rounded,
      child: AsyncView<_PremobData>(
        future: _future,
        onRetry: () => setState(() => _future = _load()),
        builder: (context, d) {
          final applicable = d.reqs.where((r) => r['applicable'] == true).toList();
          if (applicable.isEmpty) return const EmptyState(icon: Icons.rule_rounded, title: 'Belum ada requirement', message: 'Dihitung saat kontrak dibuat & saat fase berubah.');
          final byPhase = <String, List<J>>{};
          for (final r in applicable) {
            byPhase.putIfAbsent(d.labels[r['doc_type_code']]?['phase'] as String? ?? '-', () => []).add(r);
          }
          final order = Labels.phase.keys.toList();
          final phases = byPhase.keys.toList()..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final p in phases) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(Labels.phaseOf(p), style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.blue)),
              ),
              for (final r in byPhase[p]!)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: MonoText(str(r['doc_type_code']), size: 12),
                  title: Text(str(d.labels[r['doc_type_code']]?['label'])),
                  subtitle: r['reason'] == null ? null : Text(str(r['reason']), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Wrap(spacing: 6, children: [
                    if (r['is_mob_gate'] == true) const StatusBadge(Brand.red, 'Gate', icon: Icons.block_rounded),
                    StatusBadge(r['is_mandatory'] == true ? Brand.navy : Brand.grey, r['is_mandatory'] == true ? 'Wajib' : 'Opsional'),
                  ]),
                ),
            ],
          ]);
        },
      ),
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 1000
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: questionnaire), const SizedBox(width: 16), Expanded(child: reqs)])
          : Column(children: [questionnaire, const SizedBox(height: 16), reqs]),
    );
  }
}

// ═══════════════════════════ Edit kontrak ═══════════════════════════
class _EditContractDialog extends ConsumerStatefulWidget {
  const _EditContractDialog({required this.c});
  final ContractCtx c;
  @override
  ConsumerState<_EditContractDialog> createState() => _EditContractDialogState();
}

class _EditContractDialogState extends ConsumerState<_EditContractDialog> {
  J get k => widget.c.k;
  late final _title = TextEditingController(text: k['title'] as String?);
  late final _scope = TextEditingController(text: k['scope_of_work'] as String?);
  late final _site = TextEditingController(text: k['site'] as String?);
  late final _mailbox = TextEditingController(text: k['review_mailbox'] as String?);
  final _reason = TextEditingController();
  late DateTime? _end = parseDate(k['end_date']);
  late DateTime? _mob = parseDate(k['target_mob_date']);
  late String _risk = k['risk_class'] as String;
  late J? _po = widget.c.users[k['process_owner_id']] ?? {'id': k['process_owner_id'], 'full_name': 'Process Owner saat ini'};
  late J? _rv = widget.c.users[k['hse_reviewer_id']] ?? {'id': k['hse_reviewer_id'], 'full_name': 'HSE Reviewer saat ini'};
  bool _busy = false;

  Map<String, dynamic> _patch() {
    final p = <String, dynamic>{};
    void txt(String key, TextEditingController c) {
      final v = c.text.trim();
      if (v != ((k[key] as String?) ?? '')) p[key] = v.isEmpty ? null : v;
    }

    txt('title', _title);
    txt('scope_of_work', _scope);
    txt('site', _site);
    txt('review_mailbox', _mailbox);
    if (_end != null && isoDate(_end!) != k['end_date']) p['end_date'] = isoDate(_end!);
    if (_mob != null && isoDate(_mob!) != k['target_mob_date']) p['target_mob_date'] = isoDate(_mob!);
    if (_risk != k['risk_class']) p['risk_class'] = _risk;
    if (_po?['id'] != k['process_owner_id']) p['process_owner_id'] = _po?['id'];
    if (_rv?['id'] != k['hse_reviewer_id']) p['hse_reviewer_id'] = _rv?['id'];
    return p;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await runOk(context, ref,
        () => ref.read(apiProvider).rpc('update_contract', {'p_contract': widget.c.id, 'p_patch': _patch(), 'p_reason': _reason.text.trim()}),
        success: 'Kontrak diperbarui');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final riskEditable = const {'awarded', 'post_award'}.contains(widget.c.status);
    final patch = _patch();
    final ok = !_busy && patch.isNotEmpty && _reason.text.trim().length >= 5 && _title.text.trim().length >= 3;
    return AlertDialog(
      title: const Text('Edit kontrak'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _title, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Judul *')),
            const SizedBox(height: 12),
            TextField(controller: _scope, onChanged: (_) => setState(() {}), maxLines: 4, decoration: const InputDecoration(labelText: 'Scope of work', alignLabelWithHint: true)),
            const SizedBox(height: 12),
            ResponsiveGrid(minItemWidth: 260, spacing: 12, children: [
              TextField(controller: _site, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Site')),
              TextField(controller: _mailbox, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Mailbox review')),
              DateField(
                label: 'Target mobilisasi',
                value: _mob,
                onTap: () async {
                  final d = await pickDate(context, initial: _mob);
                  if (d != null) setState(() => _mob = d);
                },
              ),
              DateField(
                label: 'Tanggal selesai',
                value: _end,
                onTap: () async {
                  final d = await pickDate(context, initial: _end);
                  if (d != null) setState(() => _end = d);
                },
              ),
              UserPickField(
                label: 'Process Owner',
                value: _po,
                onPick: () async {
                  final u = await pickWfrdUser(context, title: 'Pilih Process Owner', roleKeys: const {'process_owner'});
                  if (u != null) setState(() => _po = u);
                },
              ),
              UserPickField(
                label: 'HSE Reviewer',
                value: _rv,
                onPick: () async {
                  final u = await pickWfrdUser(context, title: 'Pilih HSE Reviewer', roleKeys: const {'hse_reviewer', 'hse_admin'});
                  if (u != null) setState(() => _rv = u);
                },
              ),
            ]),
            const SizedBox(height: 12),
            Text(riskEditable ? 'Kelas risiko' : 'Kelas risiko (terkunci setelah pre-mobilization)', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'low', label: Text('Rendah')),
                ButtonSegment(value: 'medium', label: Text('Sedang')),
                ButtonSegment(value: 'high', label: Text('Tinggi')),
              ],
              selected: {_risk},
              onSelectionChanged: riskEditable ? (v) => setState(() => _risk = v.first) : null,
            ),
            if (_risk != k['risk_class'])
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: InfoBanner(message: 'Mengubah kelas risiko menghitung ulang dokumen wajib.', color: Brand.amber, icon: Icons.rule_rounded),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _reason,
              onChanged: (_) => setState(() {}),
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Alasan perubahan *', helperText: 'Minimal 5 karakter · tercatat di audit log'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: ok ? _save : null, child: Text(patch.isEmpty ? 'Tidak ada perubahan' : 'Simpan ${patch.length} perubahan')),
      ],
    );
  }
}
