import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'contract_common.dart';
import 'contract_detail_page.dart';

const _taskCols = 'id,task_id,title,doc_label,doc_type_code,status,phase,kind,due_date,review_due_at,is_mandatory,is_blocker,is_overdue,'
    'review_overdue,subcontractor_id,revision';

// ═══════════════════════════ Tasks ═══════════════════════════
class ContractTasksTab extends ConsumerStatefulWidget {
  const ContractTasksTab({super.key, required this.c});
  final ContractCtx c;
  @override
  ConsumerState<ContractTasksTab> createState() => _ContractTasksTabState();
}

class _ContractTasksTabState extends ConsumerState<ContractTasksTab> {
  late Future<List<J>> _future = _load();
  final _q = TextEditingController();
  String _filter = 'action';
  String? _phase;

  Future<List<J>> _load() => ref.read(apiProvider).select('v_task_tracking', _taskCols,
      build: (q) => q.eq('contract_id', widget.c.id).order('due_date', ascending: true, nullsFirst: false).limit(1000));

  bool _match(J t, [String? filter]) {
    final st = t['status'] as String?;
    final ok = switch (filter ?? _filter) {
      'action' => const {'open', 'awaiting_email', 'file_issue', 'revise'}.contains(st),
      'review' => const {'submitted', 'under_review'}.contains(st),
      'done' => const {'approved', 'waived'}.contains(st),
      'overdue' => t['is_overdue'] == true,
      _ => true,
    };
    if (!ok) return false;
    if (_phase != null && t['phase'] != _phase) return false;
    final q = _q.text.trim().toLowerCase();
    return q.isEmpty || '${t['task_id']} ${t['title']} ${t['doc_label']} ${t['doc_type_code']}'.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref)!;
    return AsyncView<List<J>>(
      future: _future,
      onRetry: () => setState(() => _future = _load()),
      builder: (context, all) {
        final rows = all.where((t) => _match(t)).toList();
        final order = Labels.phase.keys.toList();
        final phases = all.map((t) => t['phase'] as String?).whereType<String>().toSet().toList()..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
        int count(String f) => all.where((t) => _match(t, f)).length;

        final byPhase = <String, List<J>>{};
        for (final t in rows) {
          byPhase.putIfAbsent(t['phase'] as String? ?? '-', () => []).add(t);
        }
        return SectionCard(
          title: 'Task kontrak',
          subtitle: '${all.length} task · klik untuk membuka detail',
          icon: Icons.checklist_rounded,
          trailing: s.isWfrd && s.can('task.generate') && !widget.c.isFinal
              ? FilledButton.tonalIcon(
                  onPressed: () async {
                    final r = await showAdhocTaskDialog(context, contractId: widget.c.id, contractorId: widget.c.contractorId);
                    if (r != null) setState(() => _future = _load());
                  },
                  icon: const Icon(Icons.add_task_rounded),
                  label: const Text('Task ad-hoc'),
                )
              : null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _q,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Cari Task ID / dokumen'),
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  initialValue: _phase,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Fase'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Semua fase')),
                    for (final p in phases) DropdownMenuItem<String?>(value: p, child: Text(Labels.phaseOf(p))),
                  ],
                  onChanged: (v) => setState(() => _phase = v),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (f, l) in const [('action', 'Perlu aksi'), ('overdue', 'Overdue'), ('review', 'Dalam review'), ('done', 'Selesai'), ('all', 'Semua')])
                ChoiceChip(label: Text('$l · ${count(f)}'), selected: _filter == f, onSelected: (_) => setState(() => _filter = f)),
            ]),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              EmptyState(
                icon: Icons.task_alt_rounded,
                title: all.isEmpty ? 'Belum ada task' : 'Tidak ada task pada filter ini',
                message: all.isEmpty ? 'Task dibuat otomatis per fase oleh rules engine.' : null,
              )
            else
              for (final p in byPhase.keys) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Row(children: [
                    Text(Labels.phaseOf(p), style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.blue)),
                    const SizedBox(width: 8),
                    StatusBadge(Brand.grey, '${byPhase[p]!.length}'),
                  ]),
                ),
                for (final t in byPhase[p]!) TaskRow(t: t, onTap: () => context.go('/tasks/${t['id']}')),
              ],
          ]),
        );
      },
    );
  }
}

// ═══════════════════════════ Subkontraktor ═══════════════════════════
class _SubData {
  _SubData(this.subs, this.tasks);
  final List<J> subs, tasks;
}

class ContractSubcontractorsTab extends ConsumerStatefulWidget {
  const ContractSubcontractorsTab({super.key, required this.c});
  final ContractCtx c;
  @override
  ConsumerState<ContractSubcontractorsTab> createState() => _ContractSubcontractorsTabState();
}

class _ContractSubcontractorsTabState extends ConsumerState<ContractSubcontractorsTab> {
  late Future<_SubData> _future = _load();

  Future<_SubData> _load() async {
    final api = ref.read(apiProvider);
    final r = await Future.wait([
      api.select('subcontractors', 'id,contract_id,sub_seq,legal_name,scope_of_work,pic_name,pic_email,hse_manager,est_manpower,on_site_from,on_site_to,status,decided_by,decided_at,decision_reason,created_at',
          build: (q) => q.eq('contract_id', widget.c.id).order('sub_seq')),
      api.select('v_task_tracking', _taskCols, build: (q) => q.eq('contract_id', widget.c.id).not('subcontractor_id', 'is', null).order('due_date')),
    ]);
    return _SubData(r[0], r[1]);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _decide(J sub, String decision) async {
    final label = switch (decision) { 'approved' => 'Setujui', 'rejected' => 'Tolak', _ => 'Keluarkan' };
    final reason = await showReasonDialog(
      context,
      title: '$label subkontraktor',
      message: decision == 'approved'
          ? 'Semua dokumen wajib subkontraktor harus sudah approved/waived.'
          : 'Task terbuka subkontraktor ${sub['legal_name']} akan dibatalkan.',
      confirmLabel: label,
      destructive: decision != 'approved',
    );
    if (reason == null || !mounted) return;
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('decide_subcontractor', {'p_sub': sub['id'], 'p_decision': decision, 'p_reason': reason}),
        success: 'Keputusan tersimpan');
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref)!;
    final canAdd = const {'post_award', 'pre_mobilization', 'mobilization', 'active'}.contains(widget.c.status) &&
        (s.isWfrd ? s.can('contract.edit') : s.can('record.submit'));
    final canDecide = s.isWfrd && s.can('subcon.approve') && !widget.c.isFinal;
    return AsyncView<_SubData>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) => SectionCard(
        title: 'Subkontraktor',
        subtitle: 'Maksimum 1 tier & 99 subkontraktor per kontrak · 6 dokumen per subkontraktor',
        icon: Icons.groups_2_rounded,
        trailing: canAdd
            ? FilledButton.tonalIcon(
                onPressed: () async {
                  final ok = await showDialog<bool>(context: context, builder: (_) => _AddSubDialog(contractId: widget.c.id));
                  if (ok == true) _reload();
                },
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Tambah'),
              )
            : null,
        child: d.subs.isEmpty
            ? const EmptyState(icon: Icons.groups_2_outlined, title: 'Belum ada subkontraktor', message: 'Subkontraktor ditambahkan oleh contractor atau WFRD sejak fase Post-Award.')
            : Column(children: [
                for (final sub in d.subs) ...[
                  _SubCard(
                    sub: sub,
                    tasks: d.tasks.where((t) => t['subcontractor_id'] == sub['id']).toList(),
                    actions: [
                      if (canDecide && sub['status'] == 'pending') ...[
                        FilledButton.icon(
                          onPressed: () => _decide(sub, 'approved'),
                          style: FilledButton.styleFrom(backgroundColor: Brand.green),
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Setujui'),
                        ),
                        OutlinedButton.icon(onPressed: () => _decide(sub, 'rejected'), icon: const Icon(Icons.close_rounded, color: Brand.red), label: const Text('Tolak')),
                      ],
                      if (canDecide && sub['status'] == 'approved')
                        OutlinedButton.icon(onPressed: () => _decide(sub, 'removed'), icon: const Icon(Icons.person_remove_rounded, color: Brand.red), label: const Text('Keluarkan')),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ]),
      ),
    );
  }
}

class _SubCard extends StatelessWidget {
  const _SubCard({required this.sub, required this.tasks, required this.actions});
  final J sub;
  final List<J> tasks;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final st = sub['status'] as String?;
    final color = switch (st) { 'approved' => Brand.green, 'rejected' => Brand.red, 'removed' => Brand.grey, _ => Brand.amber };
    final label = switch (st) { 'approved' => 'Disetujui', 'rejected' => 'Ditolak', 'removed' => 'Dikeluarkan', _ => 'Menunggu keputusan' };
    final live = tasks.where((t) => !const {'cancelled', 'superseded'}.contains(t['status'])).toList();
    final done = live.where((t) => const {'approved', 'waived'}.contains(t['status'])).length;
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: Theme.of(context).dividerColor)),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.12), child: Text('S${sub['sub_seq'].toString().padLeft(2, '0')}', style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12))),
        title: Text(str(sub['legal_name']), style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            StatusBadge(color, label),
            StatusBadge(done == live.length && live.isNotEmpty ? Brand.green : Brand.blue, 'Dokumen $done/${live.length}', icon: Icons.folder_rounded),
            if (sub['est_manpower'] != null) StatusBadge(Brand.grey, '${sub['est_manpower']} orang', icon: Icons.engineering_rounded),
          ]),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueGrid(minItemWidth: 200, [
            ('PIC', Text([sub['pic_name'], sub['pic_email']].whereType<String>().join(' · ').isEmpty ? '-' : [sub['pic_name'], sub['pic_email']].whereType<String>().join(' · '))),
            ('HSE manager', Text(str(sub['hse_manager']))),
            ('Di site', Text('${fmtDate(sub['on_site_from'])} → ${fmtDate(sub['on_site_to'])}')),
            ('Diputuskan', Text(sub['decided_at'] == null ? '-' : fmtDateTime(sub['decided_at']))),
          ]),
          const SizedBox(height: 10),
          Text(str(sub['scope_of_work']), style: Theme.of(context).textTheme.bodyMedium),
          if (sub['decision_reason'] != null) ...[
            const SizedBox(height: 10),
            InfoBanner(message: 'Catatan keputusan: ${sub['decision_reason']}', color: color, icon: Icons.sticky_note_2_outlined),
          ],
          const SizedBox(height: 8),
          if (tasks.isEmpty) const Text('Belum ada task subkontraktor.', style: TextStyle(color: Brand.grey)),
          for (final t in tasks) TaskRow(t: t, onTap: () => context.go('/tasks/${t['id']}')),
          if (actions.isNotEmpty) ...[const SizedBox(height: 12), Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.end, children: actions)],
        ],
      ),
    );
  }
}

class _AddSubDialog extends ConsumerStatefulWidget {
  const _AddSubDialog({required this.contractId});
  final String contractId;
  @override
  ConsumerState<_AddSubDialog> createState() => _AddSubDialogState();
}

class _AddSubDialogState extends ConsumerState<_AddSubDialog> {
  final _name = TextEditingController();
  final _scope = TextEditingController();
  final _pic = TextEditingController();
  final _picEmail = TextEditingController();
  final _hse = TextEditingController();
  final _manpower = TextEditingController();
  DateTime? _from, _to;
  bool _busy = false;

  bool get _emailOk => _picEmail.text.trim().isEmpty || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_picEmail.text.trim());

  Future<void> _save() async {
    setState(() => _busy = true);
    final id = await runAction<dynamic>(
      context,
      ref,
      () => ref.read(apiProvider).rpc('add_subcontractor', {
        'p_contract': widget.contractId,
        'p_data': {
          'legal_name': _name.text.trim(),
          'scope_of_work': _scope.text.trim(),
          'pic_name': trimOrNull(_pic),
          'pic_email': trimOrNull(_picEmail),
          'hse_manager': trimOrNull(_hse),
          'est_manpower': int.tryParse(_manpower.text.trim()),
          'on_site_from': _from == null ? null : isoDate(_from!),
          'on_site_to': _to == null ? null : isoDate(_to!),
        },
      }),
      success: 'Subkontraktor ditambahkan · 6 task dokumen dibuat',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final ok = !_busy && _name.text.trim().length >= 2 && _scope.text.trim().length >= 3 && _emailOk && (_from == null || _to == null || !_to!.isBefore(_from!));
    return AlertDialog(
      icon: const Icon(Icons.groups_2_rounded, color: Brand.blue, size: 36),
      title: const Text('Tambah subkontraktor'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _name, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Nama legal *')),
            const SizedBox(height: 12),
            TextField(controller: _scope, onChanged: (_) => setState(() {}), maxLines: 3, decoration: const InputDecoration(labelText: 'Scope of work *', alignLabelWithHint: true)),
            const SizedBox(height: 12),
            ResponsiveGrid(minItemWidth: 240, spacing: 12, children: [
              TextField(controller: _pic, decoration: const InputDecoration(labelText: 'Nama PIC')),
              TextField(
                controller: _picEmail,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'Email PIC', errorText: _emailOk ? null : 'Email tidak valid'),
              ),
              TextField(controller: _hse, decoration: const InputDecoration(labelText: 'HSE manager')),
              TextField(controller: _manpower, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Estimasi manpower')),
              DateField(
                label: 'Di site dari',
                value: _from,
                onClear: () => setState(() => _from = null),
                onTap: () async {
                  final d = await pickDate(context, initial: _from);
                  if (d != null) setState(() => _from = d);
                },
              ),
              DateField(
                label: 'Di site sampai',
                value: _to,
                onClear: () => setState(() => _to = null),
                onTap: () async {
                  final d = await pickDate(context, initial: _to ?? _from);
                  if (d != null) setState(() => _to = d);
                },
              ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: ok ? _save : null, child: const Text('Tambah')),
      ],
    );
  }
}

// ═══════════════════════════ Risiko / JRA ═══════════════════════════
class _RiskData {
  _RiskData(this.risks, this.jra, this.signatures, this.users);
  final List<J> risks;
  final J? jra;
  final List<J> signatures;
  final Map<String, J> users;
}

class ContractRisksTab extends ConsumerStatefulWidget {
  const ContractRisksTab({super.key, required this.c});
  final ContractCtx c;
  @override
  ConsumerState<ContractRisksTab> createState() => _ContractRisksTabState();
}

class _ContractRisksTabState extends ConsumerState<ContractRisksTab> {
  late Future<_RiskData> _future = _load();

  Future<_RiskData> _load() async {
    final api = ref.read(apiProvider);
    final r = await Future.wait([
      api.select('risk_items',
          'id,contract_id,task_id,hazard,category,location_activity,exposed,existing_controls,likelihood,severity,risk_score,additional_controls,'
              'residual_likelihood,residual_severity,residual_score,action_owner,action_task_id,due_date,evidence_ref,residual_approved_by,residual_approved_at,created_at,updated_at',
          build: (q) => q.eq('contract_id', widget.c.id).order('residual_score', ascending: false)),
      api.select('v_task_tracking', 'id,task_id,status,revision,due_date',
          build: (q) => q.eq('contract_id', widget.c.id).eq('doc_type_code', 'JRAREG').order('revision', ascending: false).limit(1)),
    ]);
    final jra = r[1].firstOrNull;
    final sigs = jra == null
        ? <J>[]
        : await api.select('signatures', 'id,entity,entity_id,signer_id,party,method,sig_hash,signed_at',
            build: (q) => q.eq('entity', 'jra').eq('entity_id', jra['id'] as String).order('signed_at'));
    final users = await loadUserCards(api, [...sigs.map((x) => x['signer_id'] as String?), ...r[0].map((x) => x['residual_approved_by'] as String?)]);
    return _RiskData(r[0], jra, sigs, users);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _approve(J r) async {
    final reason = await showReasonDialog(context,
        title: 'Setujui residual risk', message: 'Residual ${riskLevel(r['residual_score'] as num?).$2} (${r['residual_score']}): ${r['hazard']}', confirmLabel: 'Setujui');
    if (reason == null || !mounted) return;
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('approve_residual_risk', {'p_risk': r['id'], 'p_reason': reason}), success: 'Residual risk disetujui');
    if (ok) _reload();
  }

  Future<void> _delete(J r) async {
    final reason = await showReasonDialog(context, title: 'Hapus risk item', message: r['hazard'] as String?, confirmLabel: 'Hapus', destructive: true);
    if (reason == null || !mounted) return;
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('delete_risk_item', {'p_id': r['id'], 'p_reason': reason}), success: 'Risk item dihapus');
    if (ok) _reload();
  }

  Future<void> _edit([J? r]) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _RiskDialog(contractId: widget.c.id, item: r));
    if (ok == true) _reload();
  }

  Future<void> _signJra(J jra) async {
    final s = readSession(ref)!;
    final name = await showReasonDialog(context,
        title: 'Tanda tangan JRA',
        message: 'Ketik nama lengkap Anda sebagai tanda tangan (typed name). Snapshot JRA di-hash SHA-256.',
        fieldLabel: 'Nama lengkap',
        minLength: 3,
        initial: s.fullName,
        confirmLabel: 'Tanda tangan');
    if (name == null || !mounted) return;
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('sign_entity', {'p_entity': 'jra', 'p_entity_id': jra['id'], 'p_method': 'typed_name'}),
        success: 'JRA ditandatangani');
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref)!;
    final canEdit = !widget.c.isFinal && (s.isWfrd ? s.can('contract.edit') : s.can('record.submit'));
    return AsyncView<_RiskData>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) {
        final pending = d.risks.where((r) => ((r['residual_score'] as num?) ?? 0) >= 10 && r['residual_approved_at'] == null).length;
        final matrix = SectionCard(
          title: 'Matriks residual 5×5',
          icon: Icons.grid_on_rounded,
          child: _RiskMatrix(risks: d.risks),
        );
        final jra = _jraCard(s, d);
        final list = SectionCard(
          title: 'Register risiko (JRA)',
          subtitle: '${d.risks.length} risiko${pending > 0 ? ' · $pending residual High/Critical menunggu approval' : ''}',
          icon: Icons.warning_amber_rounded,
          trailing: canEdit ? FilledButton.tonalIcon(onPressed: () => _edit(), icon: const Icon(Icons.add_rounded), label: const Text('Risiko')) : null,
          child: d.risks.isEmpty
              ? const EmptyState(icon: Icons.health_and_safety_outlined, title: 'Belum ada risiko', message: 'Tambahkan hazard, kontrol & skor L×S untuk JRA kontrak ini.')
              : Column(children: [
                  for (final r in d.risks)
                    _RiskCard(
                      r: r,
                      approver: d.users[r['residual_approved_by']],
                      onEdit: canEdit ? () => _edit(r) : null,
                      onDelete: s.isWfrd && s.can('contract.edit') && !widget.c.isFinal ? () => _delete(r) : null,
                      onApprove: r['residual_approved_at'] == null &&
                              (((r['residual_score'] as num?) ?? 0) >= 20 ? s.can('risk.approve.critical') : ((r['residual_score'] as num?) ?? 0) >= 10 && s.can('risk.approve.high'))
                          ? () => _approve(r)
                          : null,
                    ),
                ]),
        );
        return LayoutBuilder(builder: (context, box) {
          if (box.maxWidth >= 1100) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: list),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: Column(children: [matrix, const SizedBox(height: 16), jra])),
            ]);
          }
          return Column(children: [matrix, const SizedBox(height: 16), jra, const SizedBox(height: 16), list]);
        });
      },
    );
  }

  Widget _jraCard(SessionState s, _RiskData d) {
    final jra = d.jra;
    final signable = jra != null && const {'submitted', 'under_review'}.contains(jra['status']) && s.can('meeting.sign');
    final mine = d.signatures.any((x) => x['signer_id'] == s.userId);
    return SectionCard(
      title: 'Sign-off JRA',
      subtitle: 'Kedua pihak (WFRD & contractor) menandatangani JRAREG',
      icon: Icons.draw_rounded,
      child: jra == null
          ? const Text('Task JRAREG belum dibuat (dibuat saat masuk Pre-Mobilization).', style: TextStyle(color: Brand.grey))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                MonoText(str(jra['task_id']), size: 12),
                const SizedBox(width: 8),
                StatusBadge.task(jra['status'] as String?),
                const Spacer(),
                TextButton(onPressed: () => context.go('/tasks/${jra['id']}'), child: const Text('Buka task')),
              ]),
              const SizedBox(height: 8),
              for (final p in const ['wfrd', 'contractor'])
                GateItem(
                  ok: d.signatures.any((x) => x['party'] == p),
                  label: p == 'wfrd' ? 'Tanda tangan WFRD' : 'Tanda tangan contractor',
                  detail: d.signatures
                      .where((x) => x['party'] == p)
                      .map((x) => '${str(d.users[x['signer_id']]?['full_name'])} · ${fmtDateTime(x['signed_at'])}')
                      .join('\n'),
                ),
              if (signable && !mine) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(onPressed: () => _signJra(jra), icon: const Icon(Icons.draw_rounded), label: const Text('Tanda tangani JRA')),
                ),
              ],
              if (!signable && !const {'submitted', 'under_review'}.contains(jra['status']))
                Text('Tanda tangan tersedia setelah JRAREG dikirim (submitted).', style: Theme.of(context).textTheme.bodySmall),
            ]),
    );
  }
}

class _RiskMatrix extends StatelessWidget {
  const _RiskMatrix({required this.risks});
  final List<J> risks;

  @override
  Widget build(BuildContext context) {
    int n(int l, int s) => risks.where((r) => r['residual_likelihood'] == l && r['residual_severity'] == s).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const RotatedBox(quarterTurns: 3, child: Text('Likelihood', style: TextStyle(fontSize: 11, color: Brand.grey))),
        const SizedBox(width: 6),
        Expanded(
          child: Column(children: [
            for (var l = 5; l >= 1; l--)
              Row(children: [
                SizedBox(width: 16, child: Text('$l', style: const TextStyle(fontSize: 11, color: Brand.grey))),
                for (var sv = 1; sv <= 5; sv++)
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 1.4,
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(color: riskLevel(l * sv).$1.withValues(alpha: n(l, sv) > 0 ? 0.85 : 0.18), borderRadius: BorderRadius.circular(6)),
                        child: Center(
                          child: Text(n(l, sv) > 0 ? '${n(l, sv)}' : '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ),
                  ),
              ]),
            Row(children: [
              const SizedBox(width: 16),
              for (var sv = 1; sv <= 5; sv++) Expanded(child: Center(child: Text('$sv', style: const TextStyle(fontSize: 11, color: Brand.grey)))),
            ]),
            const Text('Severity', style: TextStyle(fontSize: 11, color: Brand.grey)),
          ]),
        ),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 6, children: [
        for (final (score, range) in const [(1, '1–4'), (5, '5–9'), (10, '10–16'), (20, '20–25')]) StatusBadge(riskLevel(score).$1, '${riskLevel(score).$2} $range'),
      ]),
    ]);
  }
}

class _RiskCard extends StatelessWidget {
  const _RiskCard({required this.r, this.approver, this.onEdit, this.onDelete, this.onApprove});
  final J r;
  final J? approver;
  final VoidCallback? onEdit, onDelete, onApprove;

  @override
  Widget build(BuildContext context) {
    final init = riskLevel(r['risk_score'] as num?);
    final res = riskLevel(r['residual_score'] as num?);
    final needs = ((r['residual_score'] as num?) ?? 0) >= 10;
    final controls = jm(r['existing_controls']);
    final ctrlText = controls['text'] as String? ?? (controls.isEmpty ? null : controls.values.join(', '));
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: res.$1, width: 4), top: BorderSide(color: Theme.of(context).dividerColor), right: BorderSide(color: Theme.of(context).dividerColor), bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(str(r['hazard']), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text([r['category'], r['location_activity'], if (r['exposed'] != null) 'Terpapar: ${r['exposed']}'].whereType<String>().join(' · '),
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          if (onEdit != null) IconButton(tooltip: 'Edit', onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 20)),
          if (onDelete != null) IconButton(tooltip: 'Hapus', onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Brand.red)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusBadge(init.$1, 'Awal ${r['likelihood']}×${r['severity']} = ${r['risk_score']} ${init.$2}'),
          const Icon(Icons.arrow_forward_rounded, size: 16, color: Brand.grey),
          StatusBadge(res.$1, 'Residual ${r['residual_likelihood']}×${r['residual_severity']} = ${r['residual_score']} ${res.$2}'),
          if (needs && r['residual_approved_at'] != null)
            StatusBadge(Brand.green, 'Disetujui ${str(approver?['full_name'], '')}'.trim(), icon: Icons.verified_rounded)
          else if (needs)
            const StatusBadge(Brand.red, 'Butuh approval', icon: Icons.pending_actions_rounded),
        ]),
        if (ctrlText != null || r['additional_controls'] != null) ...[
          const SizedBox(height: 10),
          if (ctrlText != null) Text('Kontrol eksisting: $ctrlText', style: Theme.of(context).textTheme.bodySmall),
          if (r['additional_controls'] != null) Text('Kontrol tambahan: ${r['additional_controls']}', style: Theme.of(context).textTheme.bodySmall),
        ],
        if (r['action_owner'] != null || r['due_date'] != null || r['evidence_ref'] != null) ...[
          const SizedBox(height: 6),
          Text(
            [if (r['action_owner'] != null) 'PIC: ${r['action_owner']}', if (r['due_date'] != null) 'Due ${fmtDate(r['due_date'])}', if (r['evidence_ref'] != null) 'Bukti: ${r['evidence_ref']}']
                .join(' · '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
        if (onApprove != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(onPressed: onApprove, style: FilledButton.styleFrom(backgroundColor: res.$1), icon: const Icon(Icons.gavel_rounded), label: const Text('Setujui residual')),
          ),
        ],
      ]),
    );
  }
}

class _RiskDialog extends ConsumerStatefulWidget {
  const _RiskDialog({required this.contractId, this.item});
  final String contractId;
  final J? item;
  @override
  ConsumerState<_RiskDialog> createState() => _RiskDialogState();
}

class _RiskDialogState extends ConsumerState<_RiskDialog> {
  J get r => widget.item ?? const {};
  late final _hazard = TextEditingController(text: r['hazard'] as String?);
  late final _cat = TextEditingController(text: r['category'] as String?);
  late final _loc = TextEditingController(text: r['location_activity'] as String?);
  late final _exp = TextEditingController(text: r['exposed'] as String?);
  late final _ctrl = TextEditingController(text: jm(r['existing_controls'])['text'] as String?);
  late final _add = TextEditingController(text: r['additional_controls'] as String?);
  late final _owner = TextEditingController(text: r['action_owner'] as String?);
  late final _ev = TextEditingController(text: r['evidence_ref'] as String?);
  late int _l = (r['likelihood'] as num?)?.toInt() ?? 3, _s = (r['severity'] as num?)?.toInt() ?? 3;
  late int _rl = (r['residual_likelihood'] as num?)?.toInt() ?? 2, _rs = (r['residual_severity'] as num?)?.toInt() ?? 2;
  late DateTime? _due = parseDate(r['due_date']);
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    final id = await runAction<dynamic>(
      context,
      ref,
      () => ref.read(apiProvider).rpc('upsert_risk_item', {
        'p_contract': widget.contractId,
        'p_id': widget.item?['id'],
        'p_data': {
          'hazard': _hazard.text.trim(),
          'category': trimOrNull(_cat),
          'location_activity': trimOrNull(_loc),
          'exposed': trimOrNull(_exp),
          'existing_controls': trimOrNull(_ctrl) == null ? <String, dynamic>{} : {'text': _ctrl.text.trim()},
          'likelihood': _l,
          'severity': _s,
          'additional_controls': trimOrNull(_add),
          'residual_likelihood': _rl,
          'residual_severity': _rs,
          'action_owner': trimOrNull(_owner),
          'due_date': _due == null ? null : isoDate(_due!),
          'evidence_ref': trimOrNull(_ev),
        },
      }),
      success: 'Risk item tersimpan',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) Navigator.pop(context, true);
  }

  Widget _ls(String label, int v, ValueChanged<int> on) => DropdownButtonFormField<int>(
        initialValue: v,
        decoration: InputDecoration(labelText: label),
        items: [for (var i = 1; i <= 5; i++) DropdownMenuItem(value: i, child: Text('$i'))],
        onChanged: (x) => setState(() => on(x ?? v)),
      );

  @override
  Widget build(BuildContext context) {
    final init = riskLevel(_l * _s);
    final res = riskLevel(_rl * _rs);
    return AlertDialog(
      title: Text(widget.item == null ? 'Tambah risiko' : 'Edit risiko'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _hazard, onChanged: (_) => setState(() {}), maxLines: 2, decoration: const InputDecoration(labelText: 'Hazard *')),
            const SizedBox(height: 12),
            ResponsiveGrid(minItemWidth: 190, spacing: 12, children: [
              TextField(controller: _cat, decoration: const InputDecoration(labelText: 'Kategori')),
              TextField(controller: _loc, decoration: const InputDecoration(labelText: 'Lokasi / aktivitas')),
              TextField(controller: _exp, decoration: const InputDecoration(labelText: 'Siapa terpapar')),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _ctrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Kontrol eksisting')),
            const SizedBox(height: 16),
            Row(children: [
              const Text('Risiko awal', style: TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              StatusBadge(init.$1, '${_l * _s} · ${init.$2}'),
            ]),
            const SizedBox(height: 8),
            Row(children: [Expanded(child: _ls('Likelihood (L)', _l, (x) => _l = x)), const SizedBox(width: 12), Expanded(child: _ls('Severity (S)', _s, (x) => _s = x))]),
            const SizedBox(height: 12),
            TextField(controller: _add, maxLines: 2, decoration: const InputDecoration(labelText: 'Kontrol tambahan')),
            const SizedBox(height: 16),
            Row(children: [
              const Text('Residual', style: TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              StatusBadge(res.$1, '${_rl * _rs} · ${res.$2}'),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _ls('Residual L', _rl, (x) => _rl = x)),
              const SizedBox(width: 12),
              Expanded(child: _ls('Residual S', _rs, (x) => _rs = x)),
            ]),
            if (_rl * _rs >= 10)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InfoBanner(
                  message: _rl * _rs >= 20 ? 'Residual Critical → wajib approval risk.approve.critical (blocker mobilisasi).' : 'Residual High → wajib approval risk.approve.high.',
                  color: res.$1,
                  icon: Icons.gavel_rounded,
                ),
              ),
            const SizedBox(height: 12),
            ResponsiveGrid(minItemWidth: 190, spacing: 12, children: [
              TextField(controller: _owner, decoration: const InputDecoration(labelText: 'Action owner')),
              DateField(
                label: 'Due',
                value: _due,
                onClear: () => setState(() => _due = null),
                onTap: () async {
                  final d = await pickDate(context, initial: _due);
                  if (d != null) setState(() => _due = d);
                },
              ),
              TextField(controller: _ev, decoration: const InputDecoration(labelText: 'Referensi bukti')),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: !_busy && _hazard.text.trim().length >= 3 ? _save : null, child: const Text('Simpan')),
      ],
    );
  }
}

// ═══════════════════════════ Meeting ═══════════════════════════
class ContractMeetingsTab extends ConsumerStatefulWidget {
  const ContractMeetingsTab({super.key, required this.c});
  final ContractCtx c;
  @override
  ConsumerState<ContractMeetingsTab> createState() => _ContractMeetingsTabState();
}

class _ContractMeetingsTabState extends ConsumerState<ContractMeetingsTab> {
  late Future<List<J>> _future = ref.read(apiProvider).select('meetings', 'id,meeting_type,mom_no,scheduled_at,location,status,finalized_at,signed_at,created_at',
      build: (q) => q.eq('contract_id', widget.c.id).order('scheduled_at', ascending: false));

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref)!;
    final canCreate = s.isWfrd && s.can('meeting.manage') && !widget.c.isFinal;
    return AsyncView<List<J>>(
      future: _future,
      onRetry: () => setState(() => _future = ref.read(apiProvider).select('meetings', 'id,meeting_type,mom_no,scheduled_at,location,status,finalized_at,signed_at,created_at',
          build: (q) => q.eq('contract_id', widget.c.id).order('scheduled_at', ascending: false))),
      builder: (context, rows) => SectionCard(
        title: 'Meeting & MoM',
        subtitle: 'Post-award (15 agenda), progress, audit closing · MoM final → tanda tangan kedua pihak',
        icon: Icons.event_note_rounded,
        trailing: canCreate
            ? FilledButton.tonalIcon(
                onPressed: () async {
                  final id = await showDialog<String>(
                    context: context,
                    builder: (_) => _NewMeetingDialog(contractId: widget.c.id, hasPostAward: rows.any((m) => m['meeting_type'] == 'post_award')),
                  );
                  if (id != null && context.mounted) context.go('/contracts/${widget.c.id}/meetings/$id');
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Meeting baru'),
              )
            : null,
        child: rows.isEmpty
            ? EmptyState(
                icon: Icons.event_busy_rounded,
                title: 'Belum ada meeting',
                message: widget.c.status == 'post_award' || widget.c.status == 'awarded' ? 'Jadwalkan Post-Award Meeting — MoM signed adalah gate menuju Pre-Mobilization.' : null,
              )
            : Column(children: [
                for (final m in rows)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    onTap: () => context.go('/contracts/${widget.c.id}/meetings/${m['id']}'),
                    leading: _DateBadge(date: m['scheduled_at']),
                    title: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(meetingTypeLabel[m['meeting_type']] ?? str(m['meeting_type']), style: const TextStyle(fontWeight: FontWeight.w800)),
                      StatusBadge.generic(m['status'] as String?),
                    ]),
                    subtitle: Text([str(m['mom_no']), fmtDateTime(m['scheduled_at']), if (m['location'] != null) m['location'] as String].join(' · ')),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
              ]),
      ),
    );
  }
}

class _DateBadge extends StatelessWidget {
  const _DateBadge({required this.date});
  final dynamic date;
  @override
  Widget build(BuildContext context) {
    final d = parseDate(date);
    const months = ['JAN', 'FEB', 'MAR', 'APR', 'MEI', 'JUN', 'JUL', 'AGU', 'SEP', 'OKT', 'NOV', 'DES'];
    return Container(
      width: 48,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: Brand.blue.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: Brand.blue.withValues(alpha: 0.2))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(d == null ? '-' : months[d.month - 1], style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Brand.blue)),
        Text(d == null ? '' : '${d.day}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Brand.blue, height: 1.1)),
      ]),
    );
  }
}

class _NewMeetingDialog extends ConsumerStatefulWidget {
  const _NewMeetingDialog({required this.contractId, required this.hasPostAward});
  final String contractId;
  final bool hasPostAward;
  @override
  ConsumerState<_NewMeetingDialog> createState() => _NewMeetingDialogState();
}

class _NewMeetingDialogState extends ConsumerState<_NewMeetingDialog> {
  late String _type = widget.hasPostAward ? 'progress' : 'post_award';
  DateTime _date = DateTime.now().add(const Duration(days: 3));
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  final _loc = TextEditingController();
  final _agenda = TextEditingController();
  bool _busy = false;

  Future<void> _save() async {
    final at = DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);
    final lines = _agenda.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    setState(() => _busy = true);
    final id = await runAction<dynamic>(
      context,
      ref,
      () => ref.read(apiProvider).rpc('create_meeting', {
        'p_contract': widget.contractId,
        'p_type': _type,
        'p_scheduled_at': at.toUtc().toIso8601String(),
        'p_location': trimOrNull(_loc),
        'p_agenda': lines.isEmpty ? null : lines,
      }),
      success: 'Meeting dijadwalkan',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (id is String) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.event_available_rounded, color: Brand.blue, size: 36),
        title: const Text('Jadwalkan meeting'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Tipe meeting'),
                items: [for (final e in meetingTypeLabel.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setState(() => _type = v ?? _type),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DateField(
                    label: 'Tanggal',
                    value: _date,
                    onTap: () async {
                      final d = await pickDate(context, initial: _date, first: DateTime.now().subtract(const Duration(days: 60)));
                      if (d != null) setState(() => _date = d);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      final t = await showTimePicker(context: context, initialTime: _time);
                      if (t != null) setState(() => _time = t);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Jam', suffixIcon: Icon(Icons.schedule_rounded)),
                      child: Text(_time.format(context)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              TextField(controller: _loc, decoration: const InputDecoration(labelText: 'Lokasi / link meeting', prefixIcon: Icon(Icons.place_outlined))),
              const SizedBox(height: 12),
              TextField(
                controller: _agenda,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: 'Agenda (satu per baris)',
                  alignLabelWithHint: true,
                  helperText: _type == 'post_award' ? 'Kosongkan untuk memakai 15 agenda standar post-award' : null,
                ),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Jadwalkan')),
        ],
      );
}

// ═══════════════════════════ Insiden ═══════════════════════════
class ContractIncidentsTab extends ConsumerStatefulWidget {
  const ContractIncidentsTab({super.key, required this.c});
  final ContractCtx c;
  @override
  ConsumerState<ContractIncidentsTab> createState() => _ContractIncidentsTabState();
}

class _ContractIncidentsTabState extends ConsumerState<ContractIncidentsTab> {
  late Future<List<J>> _future = _load();
  Future<List<J>> _load() => ref.read(apiProvider).select('incidents', 'id,incident_no,occurred_at,type,severity,title,status,high_potential,full_report_due_at,full_report_at',
      build: (q) => q.eq('contract_id', widget.c.id).order('occurred_at', ascending: false).limit(200));

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref)!;
    return AsyncView<List<J>>(
      future: _future,
      onRetry: () => setState(() => _future = _load()),
      builder: (context, rows) => SectionCard(
        title: 'Insiden',
        subtitle: 'Flash ≤ 1 jam (High/Critical) · laporan lengkap ≤ 24 jam · RCA ≤ 14 hari',
        icon: Icons.report_gmailerrorred_rounded,
        trailing: s.can('incident.report') && !widget.c.isFinal
            ? FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Brand.red),
                onPressed: () => context.go('/incidents/new?contract=${widget.c.id}'),
                icon: const Icon(Icons.add_alert_rounded),
                label: const Text('Lapor insiden'),
              )
            : null,
        child: rows.isEmpty
            ? const EmptyState(icon: Icons.health_and_safety_rounded, title: 'Tidak ada insiden', message: 'Semoga tetap begitu. Laporkan near miss sekalipun.')
            : Column(children: [
                for (final i in rows)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    onTap: () => context.go('/incidents/${i['id']}'),
                    leading: CircleAvatar(
                      backgroundColor: StatusStyle.generic(i['severity'] as String?).$1.withValues(alpha: 0.12),
                      child: Icon(Icons.warning_rounded, color: StatusStyle.generic(i['severity'] as String?).$1),
                    ),
                    title: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      MonoText(str(i['incident_no']), size: 12),
                      StatusBadge.generic(i['severity'] as String?),
                      StatusBadge(i['status'] == 'closed' ? Brand.grey : Brand.blue, switch (i['status']) { 'investigating' => 'Investigasi', 'closed' => 'Ditutup', _ => 'Dilaporkan' }),
                      if (i['high_potential'] == true) const StatusBadge(Brand.purple, 'High potential', icon: Icons.bolt_rounded),
                    ]),
                    subtitle: Text('${str(i['title'])} · ${fmtDateTime(i['occurred_at'])}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
              ]),
      ),
    );
  }
}

// ═══════════════════════════ KPI ═══════════════════════════
class ContractKpiTab extends ConsumerStatefulWidget {
  const ContractKpiTab({super.key, required this.c});
  final ContractCtx c;
  @override
  ConsumerState<ContractKpiTab> createState() => _ContractKpiTabState();
}

class _ContractKpiTabState extends ConsumerState<ContractKpiTab> {
  late Future<List<J>> _future = _load();
  Future<List<J>> _load() => ref.read(apiProvider).select('kpi_snapshots', 'contract_id,period_month,metrics,score,color,computed_at',
      build: (q) => q.eq('contract_id', widget.c.id).order('period_month', ascending: true).limit(36));

  static const _components = <(String, String, int)>[
    ('trir', 'TRIR', 15),
    ('ltir', 'LTIR', 15),
    ('pvir', 'PVIR', 5),
    ('hipo', 'High-potential', 5),
    ('bbs', 'BBS', 10),
    ('finding_ontime', 'Finding on-time', 10),
    ('training', 'Training compliance', 10),
    ('stopwork', 'Stop-work culture', 5),
    ('task_ontime', 'Task on-time', 10),
    ('monrpt_ontime', 'Monthly report on-time', 5),
    ('audit', 'Audit score', 10),
  ];

  Color _c(String? color) => switch (color) { 'green' => Brand.green, 'yellow' => Brand.amber, 'red' => Brand.red, _ => Brand.grey };

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<J>>(
      future: _future,
      onRetry: () => setState(() => _future = _load()),
      builder: (context, rows) {
        if (rows.isEmpty) {
          return const SectionCard(
            child: EmptyState(icon: Icons.insights_rounded, title: 'Belum ada snapshot KPI', message: 'KPI dihitung otomatis sejak fase Mobilization (rolling 12 bulan).'),
          );
        }
        final last = rows.last;
        final m = jm(last['metrics']);
        final comp = jm(m['components']);
        final score = (last['score'] as num?)?.toDouble() ?? 0;
        final color = _c(last['color'] as String?);
        num? n(String k) => m[k] as num?;
        final head = SectionCard(
          title: 'Skor KPI ${fmtDate(last['period_month'])}',
          subtitle: 'Dihitung ${fmtRelative(last['computed_at'])} · ≥85 hijau · 70–84 kuning · <70 merah',
          icon: Icons.speed_rounded,
          child: Wrap(spacing: 24, runSpacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 140,
              height: 140,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(child: CircularProgressIndicator(value: score / 100, strokeWidth: 12, color: color, backgroundColor: color.withValues(alpha: 0.12))),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(score.toStringAsFixed(1), style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: color)),
                  Text(StatusStyle.generic(last['color'] as String?).$2, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: KeyValueGrid(minItemWidth: 150, [
                ('TRIR', Text(n('trir')?.toStringAsFixed(2) ?? '-')),
                ('LTIR', Text(n('ltir')?.toStringAsFixed(2) ?? '-')),
                ('PVIR', Text(n('pvir')?.toStringAsFixed(2) ?? '-')),
                ('Man-hours', Text('${n('man_hours') ?? 0}')),
                ('Km', Text('${n('km') ?? 0}')),
                ('Recordable · LTI', Text('${n('recordables') ?? 0} · ${n('lti') ?? 0}')),
                ('BBS 4 minggu', Text('${n('bbs_4w') ?? 0}')),
                ('Stop-work 90 hari', Text('${n('stopwork_90d') ?? 0}')),
                ('Fatality', Text('${n('fatality') ?? 0}', style: TextStyle(color: (n('fatality') ?? 0) > 0 ? Brand.red : null))),
              ]),
            ),
          ]),
        );
        final chart = SectionCard(
          title: 'Tren skor',
          icon: Icons.show_chart_rounded,
          child: SizedBox(
            height: 220,
            child: LineChart(LineChartData(
              minY: 0,
              maxY: 100,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, interval: 25)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 1,
                    reservedSize: 28,
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i < 0 || i >= rows.length || v != i.toDouble()) return const SizedBox.shrink();
                      final d = parseDate(rows[i]['period_month']);
                      return Padding(padding: const EdgeInsets.only(top: 6), child: Text(d == null ? '' : '${d.month}/${d.year % 100}', style: const TextStyle(fontSize: 10)));
                    },
                  ),
                ),
              ),
              extraLinesData: ExtraLinesData(horizontalLines: [
                HorizontalLine(y: 85, color: Brand.green.withValues(alpha: 0.5), strokeWidth: 1, dashArray: [6, 4]),
                HorizontalLine(y: 70, color: Brand.red.withValues(alpha: 0.5), strokeWidth: 1, dashArray: [6, 4]),
              ]),
              lineBarsData: [
                LineChartBarData(
                  spots: [for (var i = 0; i < rows.length; i++) FlSpot(i.toDouble(), (rows[i]['score'] as num?)?.toDouble() ?? 0)],
                  isCurved: true,
                  color: Brand.blue,
                  barWidth: 3,
                  dotData: FlDotData(show: true, getDotPainter: (s, _, __, i) => FlDotCirclePainter(radius: 4, color: _c(rows[i]['color'] as String?), strokeWidth: 0)),
                  belowBarData: BarAreaData(show: true, color: Brand.blue.withValues(alpha: 0.08)),
                ),
              ],
            )),
          ),
        );
        final components = SectionCard(
          title: 'Komponen skor (bobot)',
          icon: Icons.tune_rounded,
          child: Column(children: [
            for (final (k, l, w) in _components)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  SizedBox(width: 190, child: Text('$l · $w%', style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: (((comp[k] as num?) ?? 0) / 100).clamp(0, 1).toDouble(),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(6),
                      color: ((comp[k] as num?) ?? 0) >= 85 ? Brand.green : ((comp[k] as num?) ?? 0) >= 70 ? Brand.amber : Brand.red,
                    ),
                  ),
                  SizedBox(width: 52, child: Text((comp[k] as num?)?.toStringAsFixed(0) ?? '-', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800))),
                ]),
              ),
          ]),
        );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          head,
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, b) => b.maxWidth >= 1000
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: chart), const SizedBox(width: 16), Expanded(child: components)])
                : Column(children: [chart, const SizedBox(height: 16), components]),
          ),
        ]);
      },
    );
  }
}

// ═══════════════════════════ OneDrive (ringkas) ═══════════════════════════
class ContractOneDriveTab extends ConsumerStatefulWidget {
  const ContractOneDriveTab({super.key, required this.c});
  final ContractCtx c;
  @override
  ConsumerState<ContractOneDriveTab> createState() => _ContractOneDriveTabState();
}

class _ContractOneDriveTabState extends ConsumerState<ContractOneDriveTab> {
  late Future<(List<J>, List<J>)> _future = _load();

  Future<(List<J>, List<J>)> _load() async {
    final api = ref.read(apiProvider);
    final r = await Future.wait([
      api.select('upload_links', 'id,scope_type,doc_type_code,label,link_type,active', build: (q) => q.eq('contract_id', widget.c.id).eq('active', true)),
      api.rpcList('link_coverage', {'p_contract': widget.c.id}),
    ]);
    return (r[0], r[1]);
  }

  @override
  Widget build(BuildContext context) => AsyncView<(List<J>, List<J>)>(
        future: _future,
        onRetry: () => setState(() => _future = _load()),
        builder: (context, d) {
          final (links, gaps) = d;
          final hasDefault = links.any((l) => l['scope_type'] == 'contract' && l['doc_type_code'] == null);
          return SectionCard(
            title: 'Link OneDrive kontrak',
            subtitle: 'Folder upload per kontrak / fase / jenis dokumen (Part 7.4)',
            icon: Icons.cloud_upload_rounded,
            trailing: FilledButton.icon(
              onPressed: () => context.go('/contracts/${widget.c.id}/onedrive'),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Kelola link'),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ResponsiveGrid(minItemWidth: 200, children: [
                StatCard(label: 'Link aktif', value: '${links.length}', icon: Icons.link_rounded, color: Brand.cyan),
                StatCard(label: 'Task tanpa link', value: '${gaps.length}', icon: Icons.link_off_rounded, color: gaps.isEmpty ? Brand.green : Brand.red),
              ]),
              const SizedBox(height: 12),
              GateItem(ok: hasDefault, label: 'Link default kontrak (semua dokumen kontrak)'),
              GateItem(ok: gaps.isEmpty, label: 'Semua task dokumen/bukti terbuka punya link', detail: gaps.isEmpty ? null : 'Reminder ditahan untuk ${gaps.length} task (R21)'),
            ]),
          );
        },
      );
}
