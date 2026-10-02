import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;
J jm(dynamic v) => v == null ? <String, dynamic>{} : Map<String, dynamic>.from(v as Map);
List<J> jl(dynamic v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

SessionState? watchSession(WidgetRef ref) {
  final s = ref.watch(sessionProvider);
  return s is SessionReady ? s.s : null;
}

SessionState? readSession(WidgetRef ref) {
  final s = ref.read(sessionProvider);
  return s is SessionReady ? s.s : null;
}

String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String? trimOrNull(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
String vendorRef(dynamic seq) => seq == null ? 'CMN-V…' : 'CMN-V${seq.toString().padLeft(5, '0')}';

/// Jalankan RPC tulis yang mungkin mengembalikan VOID: `true` bila sukses, `false` bila gagal (sudah ditangani runAction).
Future<bool> runOk(BuildContext context, WidgetRef ref, Future<void> Function() action, {String? success}) async {
  final r = await runAction<bool>(context, ref, () async {
    await action();
    return true;
  }, success: success);
  return r == true;
}

// ─────────────────────────── Status kontrak ───────────────────────────
const contractFlow = ['awarded', 'post_award', 'pre_mobilization', 'mobilization', 'active', 'demobilization', 'final_evaluation', 'closed'];
const contractOpen = ['awarded', 'post_award', 'pre_mobilization', 'mobilization', 'active', 'demobilization', 'final_evaluation'];

String healthLabel(String? f) => switch (f) { 'red' => 'Merah', 'warning' => 'Warning', 'normal' => 'Normal', _ => '-' };
Color healthColor(String? f) => switch (f) { 'red' => Brand.red, 'warning' => Brand.amber, 'normal' => Brand.green, _ => Brand.grey };

class HealthBadge extends StatelessWidget {
  const HealthBadge(this.flag, {super.key});
  final String? flag;
  @override
  Widget build(BuildContext context) => StatusBadge(healthColor(flag), 'Health ${healthLabel(flag)}',
      icon: flag == 'red' ? Icons.local_fire_department_rounded : flag == 'warning' ? Icons.warning_amber_rounded : Icons.favorite_rounded);
}

const riskClassLabel = {'low': 'Rendah', 'medium': 'Sedang', 'high': 'Tinggi'};
Color riskClassColor(String? r) => switch (r) { 'high' => Brand.red, 'medium' => Brand.amber, _ => Brand.green };

const meetingTypeLabel = {'post_award': 'Post-Award Meeting', 'progress': 'Progress Meeting', 'audit_closing': 'Audit Closing', 'other': 'Lainnya'};

const blockerLabel = {
  'gate_document': 'Dokumen gate belum approved',
  'subcontractor_pending': 'Subkontraktor menunggu keputusan',
  'finding_open': 'Finding Critical/Major terbuka',
  'blocker_task': 'Task blocker belum selesai',
  'residual_critical': 'Residual risk Critical belum disetujui',
  'residual_high': 'Residual risk High belum disetujui',
  'incident_open': 'Insiden belum ditutup',
  'task_open': 'Task wajib masih terbuka',
  'demob_checklist': 'Checklist demobilisasi',
};

/// Matriks risiko 5×5 (Part 11).
(Color, String) riskLevel(num? score) {
  final s = score ?? 0;
  if (s >= 20) return (Brand.red, 'Critical');
  if (s >= 10) return (const Color(0xFFDC6803), 'High');
  if (s >= 5) return (Brand.amber, 'Medium');
  return (Brand.green, 'Low');
}

/// Alur fase kontrak sebagai stepper horizontal (cabang suspended/terminated ditandai).
class ContractPhaseStepper extends StatelessWidget {
  const ContractPhaseStepper({super.key, required this.status, this.statusBeforeHold});
  final String status;
  final String? statusBeforeHold;

  @override
  Widget build(BuildContext context) {
    final effective = status == 'suspended' ? (statusBeforeHold ?? 'awarded') : status;
    final idx = status == 'terminated' ? -1 : contractFlow.indexOf(effective);
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (var i = 0; i < contractFlow.length; i++) ...[
          if (i > 0)
            Container(
              width: 28,
              height: 3,
              margin: const EdgeInsets.only(bottom: 22),
              decoration: BoxDecoration(color: i <= idx ? Brand.blue : Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2)),
            ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < idx || (i == idx && status == 'closed')
                    ? Brand.green
                    : i == idx
                        ? (status == 'suspended' ? Brand.red : Brand.blue)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                boxShadow: i == idx ? [BoxShadow(color: Brand.blue.withValues(alpha: 0.35), blurRadius: 10)] : null,
              ),
              child: Center(
                child: i < idx || (i == idx && status == 'closed')
                    ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                    : i == idx && status == 'suspended'
                        ? const Icon(Icons.pause_rounded, size: 16, color: Colors.white)
                        : Text('${i + 1}', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: i == idx ? Colors.white : Brand.grey)),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 92,
              child: Text(
                StatusStyle.contract(contractFlow[i]).$2,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: t.labelSmall?.copyWith(fontWeight: i == idx ? FontWeight.w800 : FontWeight.w500, color: i == idx ? null : Brand.grey),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

// ─────────────────────────── Form helpers ───────────────────────────
class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.value, required this.onTap, this.onClear});
  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: value != null && onClear != null
                ? IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: onClear)
                : const Icon(Icons.calendar_month_rounded),
          ),
          child: Text(value == null ? 'Pilih tanggal' : fmtDate(value!.toIso8601String())),
        ),
      );
}

Future<DateTime?> pickDate(BuildContext context, {DateTime? initial, DateTime? first, DateTime? last}) {
  final now = DateTime.now();
  final f = first ?? DateTime(now.year - 5);
  final l = last ?? DateTime(now.year + 10);
  var init = initial ?? now;
  if (init.isBefore(f)) init = f;
  if (init.isAfter(l)) init = l;
  return showDatePicker(context: context, firstDate: f, lastDate: l, initialDate: init);
}

/// Pasangan label → widget untuk ringkasan form review.
class ReviewRow extends StatelessWidget {
  const ReviewRow(this.label, this.value, {super.key});
  final String label;
  final String? value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 170, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(child: SelectableText(str(value), style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

// ─────────────────────────── User cards ───────────────────────────
Future<Map<String, J>> loadUserCards(Api api, Iterable<String?> ids) async {
  final list = ids.whereType<String>().where(uuidRe.hasMatch).toSet().toList();
  if (list.isEmpty) return {};
  final r = await api.rpc('get_user_cards', {'p_ids': list});
  return {for (final u in jl(r)) u['id'] as String: u};
}

class UserCardTile extends StatelessWidget {
  const UserCardTile({super.key, required this.card, this.fallbackId, this.trailing, this.caption, this.dense = false});
  final J? card;
  final String? fallbackId;
  final Widget? trailing;
  final String? caption;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = card;
    final name = c?['full_name'] as String? ?? (fallbackId == null ? '-' : 'User ${fallbackId!.substring(0, 8)}…');
    final sub = [
      if (caption != null) caption!,
      if (c?['job_title'] != null) c!['job_title'] as String,
      if (c?['company'] != null) c!['company'] as String,
    ].join(' · ');
    return ListTile(
      dense: dense,
      contentPadding: EdgeInsets.zero,
      leading: Avatar(name: name, url: c?['avatar_url'] as String?, radius: dense ? 16 : 18),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing ?? (c != null && c['active'] == false ? const StatusBadge(Brand.grey, 'Nonaktif') : null),
    );
  }
}

/// Pemilih user WFRD. Sumber kandidat: Admin (admin_list_users, butuh MFA) atau PO/reviewer kontrak yang terlihat
/// + diri sendiri; selalu bisa memasukkan UUID user secara manual (divalidasi via get_user_cards).
Future<J?> pickWfrdUser(BuildContext context, {required String title, required Set<String> roleKeys}) =>
    showDialog<J>(context: context, builder: (_) => _UserPickerDialog(title: title, roleKeys: roleKeys));

class _UserPickerDialog extends ConsumerStatefulWidget {
  const _UserPickerDialog({required this.title, required this.roleKeys});
  final String title;
  final Set<String> roleKeys;
  @override
  ConsumerState<_UserPickerDialog> createState() => _UserPickerDialogState();
}

class _UserPickerDialogState extends ConsumerState<_UserPickerDialog> {
  final _q = TextEditingController();
  late Future<List<J>> _future = _load();
  bool _adminSource = false;

  Future<List<J>> _load() async {
    final api = ref.read(apiProvider);
    final s = readSession(ref);
    final q = _q.text.trim();
    if (s != null && s.adminMode && s.can('admin.users.view')) {
      _adminSource = true;
      final r = await api.rpc('admin_list_users', {'p_status': 'active', 'p_search': q.isEmpty ? null : q, 'p_limit': 100});
      return jl(r).where((u) => u['contractor_id'] == null).map((u) {
        final roles = jl(u['roles']).map((x) => x['role'] as String?).whereType<String>().toSet();
        return <String, dynamic>{
          'id': u['id'],
          'full_name': u['full_name'] ?? u['email'],
          'job_title': u['email'],
          'company': 'Weatherford',
          'avatar_url': u['avatar_url'],
          'roles': roles.toList(),
          'match': roles.intersection(widget.roleKeys).isNotEmpty,
        };
      }).toList()
        ..sort((a, b) => (b['match'] == true ? 1 : 0) - (a['match'] == true ? 1 : 0));
    }
    final ids = <String>{if (s != null && s.isWfrd) s.userId};
    if (uuidRe.hasMatch(q)) ids.add(q);
    final rows = await api.select('contracts', 'process_owner_id,hse_reviewer_id', build: (b) => b.order('updated_at', ascending: false).limit(300));
    for (final r in rows) {
      for (final k in const ['process_owner_id', 'hse_reviewer_id']) {
        if (r[k] is String) ids.add(r[k] as String);
      }
    }
    final cards = await loadUserCards(api, ids);
    return cards.values.where((c) => c['is_wfrd'] == true && c['active'] != false).toList();
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim().toLowerCase();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 480,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _q,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _reload(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: 'Cari nama / email, atau tempel UUID user',
              suffixIcon: IconButton(tooltip: 'Cari di server', icon: const Icon(Icons.arrow_forward_rounded), onPressed: _reload),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Server memvalidasi role: ${widget.roleKeys.join(' / ')}.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.grey),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: AsyncView<List<J>>(
              future: _future,
              onRetry: _reload,
              builder: (context, all) {
                final list = _adminSource
                    ? all
                    : all.where((u) => q.isEmpty || uuidRe.hasMatch(q) || '${u['full_name']} ${u['job_title']}'.toLowerCase().contains(q)).toList();
                if (list.isEmpty) {
                  return EmptyState(
                    icon: Icons.person_search_rounded,
                    title: 'User tidak ditemukan',
                    message: _adminSource ? 'Coba kata kunci lain.' : 'Tempel UUID user WFRD lalu tekan Enter untuk memvalidasi.',
                  );
                }
                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final u = list[i];
                    final roles = (u['roles'] as List?)?.cast<String>();
                    return InkWell(
                      onTap: () => Navigator.pop(context, u),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: UserCardTile(
                          card: u,
                          dense: true,
                          trailing: roles == null
                              ? const Icon(Icons.chevron_right_rounded)
                              : u['match'] == true
                                  ? const StatusBadge(Brand.green, 'Role sesuai', icon: Icons.verified_rounded)
                                  : Text(roles.isEmpty ? 'tanpa role' : roles.join(', '), style: const TextStyle(fontSize: 11, color: Brand.grey)),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal'))],
    );
  }
}

/// Field formulir yang menampilkan user terpilih + tombol ganti.
class UserPickField extends StatelessWidget {
  const UserPickField({super.key, required this.label, required this.value, required this.onPick, this.helper});
  final String label;
  final J? value;
  final VoidCallback onPick;
  final String? helper;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, helperText: helper, suffixIcon: const Icon(Icons.person_search_rounded)),
          child: value == null
              ? const Text('Pilih user', style: TextStyle(color: Brand.grey))
              : Row(children: [
                  Avatar(name: value!['full_name'] as String?, url: value!['avatar_url'] as String?, radius: 12),
                  const SizedBox(width: 10),
                  Expanded(child: Text(str(value!['full_name']), overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                ]),
        ),
      );
}

// ─────────────────────────── Ad-hoc task ───────────────────────────
/// `create_adhoc_task` (task.generate). Mengembalikan `{id, task_id}` bila berhasil.
Future<J?> showAdhocTaskDialog(
  BuildContext context, {
  required String contractId,
  String? contractorId,
  String? subcontractorId,
  String docType = 'ACTITM',
  String? title,
  String? sourceRef,
  String? description,
  DateTime? due,
}) =>
    showDialog<J>(
      context: context,
      builder: (_) => _AdhocDialog(
        contractId: contractId,
        contractorId: contractorId,
        subcontractorId: subcontractorId,
        docType: docType,
        title: title,
        sourceRef: sourceRef,
        description: description,
        due: due,
      ),
    );

class _AdhocDialog extends ConsumerStatefulWidget {
  const _AdhocDialog({required this.contractId, this.contractorId, this.subcontractorId, required this.docType, this.title, this.sourceRef, this.description, this.due});
  final String contractId;
  final String? contractorId, subcontractorId, title, sourceRef, description;
  final String docType;
  final DateTime? due;
  @override
  ConsumerState<_AdhocDialog> createState() => _AdhocDialogState();
}

class _AdhocDialogState extends ConsumerState<_AdhocDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _desc = TextEditingController(text: widget.description);
  late final _src = TextEditingController(text: widget.sourceRef);
  late String _docType = widget.docType;
  late DateTime? _due = widget.due ?? DateTime.now().add(const Duration(days: 7));
  bool _blocker = false, _busy = false;
  String? _assignee;
  late final Future<List<J>> _people = widget.contractorId == null
      ? Future.value(const <J>[])
      : ref
          .read(apiProvider)
          .rpcList('list_contractor_users', {'p_contractor': widget.contractorId})
          .then((l) => l.where((u) => u['status'] == 'active').toList())
          .catchError((_) => const <J>[]);
  late final Future<List<J>> _types = ref.read(apiProvider).select('doc_type_catalog', 'code,label,kind,phase',
      build: (q) => q.eq('active', true).contains('allowed_scopes', [widget.subcontractorId == null ? 'contract' : 'subcontractor']).order('code'));

  Future<void> _submit() async {
    setState(() => _busy = true);
    final r = await runAction<J>(
      context,
      ref,
      () => ref.read(apiProvider).rpcMap('create_adhoc_task', {
        'p_contractor': widget.contractorId,
        'p_contract': widget.contractId,
        'p_subcontractor': widget.subcontractorId,
        'p_doc_type': _docType,
        'p_title': _title.text.trim(),
        'p_due': _due == null ? null : isoDate(_due!),
        'p_is_blocker': _blocker,
        'p_assigned_to': _assignee,
        'p_source_ref': trimOrNull(_src),
        'p_description': trimOrNull(_desc),
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) {
      showSnack(context, 'Task ${r['task_id']} dibuat');
      Navigator.pop(context, r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ok = !_busy && _title.text.trim().length >= 3 && _due != null;
    return AlertDialog(
      icon: const Icon(Icons.add_task_rounded, color: Brand.blue, size: 36),
      title: const Text('Buat task ad-hoc'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FutureBuilder<List<J>>(
              future: _types,
              builder: (context, s) {
                final items = s.data ?? [<String, dynamic>{'code': _docType, 'label': _docType}];
                final has = items.any((e) => e['code'] == _docType);
                return DropdownButtonFormField<String>(
                  initialValue: has ? _docType : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Jenis dokumen *', prefixIcon: Icon(Icons.category_outlined)),
                  items: [
                    for (final d in items)
                      DropdownMenuItem(value: d['code'] as String, child: Text('${d['code']} · ${d['label']}', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _docType = v ?? _docType),
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(controller: _title, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Judul task *')),
            const SizedBox(height: 12),
            DateField(
              label: 'Jatuh tempo *',
              value: _due,
              onTap: () async {
                final d = await pickDate(context, initial: _due, first: DateTime.now(), last: DateTime.now().add(const Duration(days: 730)));
                if (d != null) setState(() => _due = d);
              },
            ),
            const SizedBox(height: 12),
            TextField(controller: _src, decoration: const InputDecoration(labelText: 'Referensi sumber (mis. MOM-00042-001)')),
            const SizedBox(height: 12),
            FutureBuilder<List<J>>(
              future: _people,
              builder: (context, s) => DropdownButtonFormField<String?>(
                key: ValueKey('adhoc-assignee-${s.data?.length}'),
                initialValue: _assignee,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Assignee (opsional)', prefixIcon: Icon(Icons.person_outline_rounded)),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('— Semua pengguna contractor —')),
                  for (final p in s.data ?? const <J>[])
                    DropdownMenuItem<String?>(value: p['id'] as String, child: Text(str(p['full_name'] ?? p['email']), overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _assignee = v),
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: _desc, maxLines: 3, decoration: const InputDecoration(labelText: 'Deskripsi')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _blocker,
              onChanged: (v) => setState(() => _blocker = v),
              title: const Text('Gate blocker'),
              subtitle: const Text('Task wajib selesai sebelum mobilisasi'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: ok ? _submit : null,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_rounded),
          label: const Text('Buat task'),
        ),
      ],
    );
  }
}

/// Baris task ringkas (v_task_tracking) → /tasks/:id.
class TaskRow extends StatelessWidget {
  const TaskRow({super.key, required this.t, required this.onTap});
  final J t;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final status = t['status'] as String?;
    final open = const {'open', 'awaiting_email', 'file_issue'}.contains(status);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: onTap,
      leading: Icon(
        t['is_blocker'] == true ? Icons.block_rounded : (status == 'approved' ? Icons.verified_rounded : Icons.description_outlined),
        color: t['is_blocker'] == true ? Brand.red : (status == 'approved' ? Brand.green : Brand.blue),
      ),
      title: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        MonoText(str(t['task_id']), size: 12),
        StatusBadge.task(status),
        if (t['is_mandatory'] == false) const StatusBadge(Brand.grey, 'Opsional'),
      ]),
      subtitle: Text(str(t['doc_label'] ?? t['title']), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: open && t['due_date'] != null
          ? Text(dueLabel(t['due_date']), style: TextStyle(color: dueColor(t['due_date']), fontWeight: FontWeight.w800, fontSize: 12))
          : Text(fmtDate(t['due_date']), style: const TextStyle(fontSize: 12, color: Brand.grey)),
    );
  }
}

/// Header gradien (gaya dashboard) untuk halaman detail.
class HeroHeader extends StatelessWidget {
  const HeroHeader({super.key, required this.title, required this.lines, required this.icon, this.trailing, this.gradient = Brand.heroGradient, this.chips = const []});
  final String title;
  final List<String> lines;
  final IconData icon;
  final Widget? trailing;
  final Gradient gradient;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return Container(
      padding: EdgeInsets.all(wide ? 24 : 18),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Brand.blue.withValues(alpha: 0.22), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (wide) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
              child: Icon(icon, color: Colors.white, size: 30),
            ),
            const SizedBox(width: 18),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(color: Colors.white, fontSize: wide ? 22 : 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              for (final l in lines) Text(l, style: const TextStyle(color: Colors.white70)),
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ]),
    );
  }
}

/// Chip putih transparan untuk di atas HeroHeader.
class HeroChip extends StatelessWidget {
  const HeroChip(this.label, {super.key, this.icon});
  final String label;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(999), border: Border.all(color: Colors.white24)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 5)],
          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
      );
}

/// Ikon berlabel untuk gate checklist.
class GateItem extends StatelessWidget {
  const GateItem({super.key, required this.ok, required this.label, this.detail, this.onTap});
  final bool ok;
  final String label;
  final String? detail;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        onTap: onTap,
        contentPadding: EdgeInsets.zero,
        leading: Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded, color: ok ? Brand.green : Brand.red),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: detail == null ? null : Text(detail!, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded),
      );
}
