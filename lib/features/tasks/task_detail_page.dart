import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/security/fingerprint.dart';
import '../../core/security/url_policy.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/classification_badges.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;
J _m(dynamic v) => v == null ? <String, dynamic>{} : Map<String, dynamic>.from(v as Map);
List<J> _l(dynamic v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

class TaskDetailPage extends ConsumerStatefulWidget {
  const TaskDetailPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends ConsumerState<TaskDetailPage> {
  late Future<J> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant TaskDetailPage old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _reload();
  }

  Future<J> _load() => ref.read(apiProvider).rpcMap('get_task_detail', {'p_task': widget.id});
  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return AsyncView<J>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) => _TaskView(key: ValueKey(_m(d['task'])['updated_at']), data: d, onChanged: _reload),
    );
  }
}

class _TaskView extends ConsumerWidget {
  const _TaskView({super.key, required this.data, required this.onChanged});
  final J data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = _m(data['task']);
    final doc = _m(data['doc']);
    final contract = data['contract'] == null ? null : _m(data['contract']);
    final contractor = _m(data['contractor']);
    final status = t['status'] as String;
    final canConfirm = data['can_confirm'] == true;
    final blockReason = data['confirm_block_reason'] as String?;
    final canReview = data['can_review'] == true;
    final st = ref.watch(sessionProvider);
    final s = st is SessionReady ? st.s : null;
    final taskId = t['task_id'] as String;
    final kind = t['kind'] as String;
    final open = const {'open', 'file_issue'}.contains(status);

    return PageScaffold(
      title: str(doc['label'] ?? t['title']),
      subtitle: [
        if (contract != null) str(contract['contract_no']) else str(contractor['vendor_ref']),
        str(contractor['legal_name']),
        Labels.phaseOf(t['phase']),
      ].join(' · '),
      leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.canPop() ? context.pop() : context.go('/tasks')),
      actions: [
        OutlinedButton.icon(
          onPressed: () async {
            final id = await runAction(context, ref, () => ref.read(apiProvider).rpc('get_or_create_task_thread', {'p_task': t['id']}));
            if (id != null && context.mounted) context.go('/chat/$id');
          },
          icon: const Icon(Icons.forum_outlined),
          label: const Text('Diskusikan'),
        ),
        if (s != null && s.isWfrd) _WfrdMenu(task: t, s: s.permissions, onChanged: onChanged),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Header(task: t, doc: doc, contract: contract),
        const SizedBox(height: 16),
        if (blockReason != null && (open || status == 'awaiting_email'))
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: InfoBanner(
              message: '$blockReason. Minta PIC/Supervisor perusahaan Anda untuk menyelesaikan task ini.',
              color: Brand.amber,
              icon: Icons.lock_person_outlined,
            ),
          ),
        if (t['status_reason'] != null && const {'file_issue', 'revise', 'rejected', 'waived', 'cancelled', 'superseded'}.contains(status))
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: InfoBanner(
              message: 'Catatan: ${t['status_reason']}',
              color: status == 'file_issue' ? Brand.purple : Brand.amber,
              icon: Icons.sticky_note_2_outlined,
            ),
          ),
        if (t['review_notes'] != null && status != 'file_issue')
          Padding(padding: const EdgeInsets.only(bottom: 16), child: InfoBanner(message: 'Catatan reviewer: ${t['review_notes']}', icon: Icons.rate_review_outlined)),
        if (canConfirm && open)
          _ContractorFlow(data: data, onChanged: onChanged)
        else if (canConfirm && status == 'awaiting_email')
          _EmailCard(taskUuid: t['id'] as String, canClaim: true, onChanged: onChanged)
        else if (s != null && s.isWfrd && kind == 'action' && status == 'open')
          _WfrdActionCard(task: t, onChanged: onChanged),
        if (canReview && const {'submitted', 'under_review'}.contains(status)) _ReviewPanel(data: data, onChanged: onChanged),
        if (kind == 'checklist' && !(canConfirm && open)) ...[const SizedBox(height: 16), _ChecklistView(data: data, onChanged: onChanged, editable: false)],
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, c) {
          final info = _SubmissionInfo(task: t, link: data['link'] == null ? null : _m(data['link']));
          final timeline = _Timeline(events: _l(data['events']), revisions: _l(data['revisions']), currentId: t['id'] as String);
          return c.maxWidth > 1000
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: info), const SizedBox(width: 16), Expanded(child: timeline)])
              : Column(children: [info, const SizedBox(height: 16), timeline]);
        }),
        if (taskId.isEmpty) const SizedBox.shrink(),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.task, required this.doc, this.contract});
  final J task, doc;
  final J? contract;

  @override
  Widget build(BuildContext context) {
    final status = task['status'] as String;
    final due = task['due_date'];
    final openish = const {'open', 'awaiting_email', 'file_issue'}.contains(status);
    return SectionCard(
      child: Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        TaskIdChip(task['task_id'] as String, large: true),
        StatusBadge.task(status),
        if (due != null)
          StatusBadge(openish ? dueColor(due) : Brand.grey, 'Due ${fmtDate(due)}${openish ? ' · ${dueLabel(due)}' : ''}', icon: Icons.event_rounded),
        StatusBadge(Brand.blue, Labels.kindOf(task['kind']), icon: Icons.category_outlined),
        if (task['is_mandatory'] == true) const StatusBadge(Brand.navy, 'Wajib', icon: Icons.priority_high_rounded),
        if (task['is_blocker'] == true) const StatusBadge(Brand.red, 'Gate blocker', icon: Icons.block_rounded),
        if (doc['sensitive'] == true) const StatusBadge(Brand.purple, 'Sensitif', icon: Icons.lock_rounded),
        if ((task['revision'] as num? ?? 0) > 0) StatusBadge(Brand.amber, 'Revisi ${task['revision']}', icon: Icons.history_rounded),
        if (contract != null) ClassificationBadges(contract!, compact: true),
      ]),
    );
  }
}

// ═══════════════════════════ Contractor flow (17.3) ═══════════════════════════
class _ContractorFlow extends ConsumerStatefulWidget {
  const _ContractorFlow({required this.data, required this.onChanged});
  final J data;
  final VoidCallback onChanged;
  @override
  ConsumerState<_ContractorFlow> createState() => _ContractorFlowState();
}

class _ContractorFlowState extends ConsumerState<_ContractorFlow> {
  late final J t = _m(widget.data['task']);
  late final J doc = _m(widget.data['doc']);
  late final J? link = widget.data['link'] == null ? null : _m(widget.data['link']);
  late final String taskId = t['task_id'] as String;
  late final String kind = t['kind'] as String;
  late final _fileName = TextEditingController(text: (t['uploaded_file_name'] as String?) ?? '$taskId - ${_safeLabel(doc['label'])}.pdf');
  final _docNo = TextEditingController();
  final _issuer = TextEditingController();
  final _evidence = TextEditingController();
  final _note = TextEditingController();
  DateTime? _issueDate, _expiryDate;
  ({String name, int size, String sha256})? _fp;
  bool _hashing = false, _attested = false, _busy = false, _linkOpened = false;
  final Map<String, TextEditingController> _form = {};

  bool get _isFile => kind == 'document' || kind == 'evidence';
  bool get _requiresFp => doc['requires_fingerprint'] == true;
  bool get _requiresExpiry => doc['requires_expiry'] == true;
  bool get _isMonthly => t['doc_type_code'] == 'MONRPT';

  static String _safeLabel(dynamic l) => (l?.toString() ?? 'Dokumen').replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');

  @override
  void initState() {
    super.initState();
    _docNo.text = (t['doc_number'] as String?) ?? '';
    _issuer.text = (t['issuer'] as String?) ?? '';
    _evidence.text = (t['evidence_ref'] as String?) ?? '';
    _issueDate = parseDate(t['issue_date']);
    _expiryDate = parseDate(t['expiry_date']);
    final fd = _m(t['form_data']);
    for (final k in _isMonthly ? const ['period', 'man_hours', 'km_driven', 'lti', 'recordable', 'near_miss', 'observations', 'summary'] : const ['summary', 'details']) {
      _form[k] = TextEditingController(text: fd[k]?.toString() ?? (k == 'period' ? _lastMonth() : ''));
    }
  }

  static String _lastMonth() {
    final n = DateTime.now();
    final d = DateTime(n.year, n.month - 1);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  }

  bool get _nameOk => fileNameMatchesTask(_fileName.text.trim(), taskId) && !_fileName.text.contains(RegExp(r'[\\/]'));

  bool get _ready {
    if (_busy) return false;
    switch (kind) {
      case 'document':
      case 'evidence':
        return link != null && _nameOk && _attested && (!_requiresFp || _fp != null) && (!_requiresExpiry || (_expiryDate != null && _expiryDate!.isAfter(DateTime.now())));
      case 'form':
        return !_isMonthly || (RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(_form['period']!.text.trim()) && num.tryParse(_form['man_hours']!.text) != null && num.tryParse(_form['km_driven']!.text) != null);
      case 'checklist':
        return _l(widget.data['checklist']).where((i) => i['owner_party'] == 'contractor').every((i) => i['checked'] == true);
      case 'action':
        return _evidence.text.trim().isNotEmpty || _note.text.trim().isNotEmpty;
    }
    return false;
  }

  Future<void> _openLink() async {
    final url = link?['url'] as String?;
    if (url == null) return;
    await runAction(context, ref, () async {
      await ref.read(apiProvider).rpc('log_link_opened', {'p_task': t['id']});
      await UrlPolicy.open(url);
    });
    setState(() => _linkOpened = true);
  }

  Future<void> _pickFingerprint() async {
    setState(() => _hashing = true);
    try {
      final r = await pickAndHash(ref.read(secureStoreProvider));
      if (r == null) return;
      if (!fileNameMatchesTask(r.name, taskId)) {
        if (mounted) showSnack(context, 'Nama file "${r.name}" tidak diawali Task ID $taskId. Ganti nama file lalu upload ulang ke OneDrive.', error: true);
        return;
      }
      setState(() {
        _fp = r;
        _fileName.text = r.name;
      });
    } catch (e) {
      if (mounted) await handleFailure(context, ref, e);
    } finally {
      if (mounted) setState(() => _hashing = false);
    }
  }

  Map<String, dynamic>? _formData() {
    if (kind != 'form') return null;
    final m = <String, dynamic>{};
    _form.forEach((k, c) {
      final v = c.text.trim();
      if (v.isEmpty) return;
      m[k] = (k == 'period' || k == 'summary' || k == 'details' || k == 'observations') ? v : (num.tryParse(v) ?? v);
    });
    return m;
  }

  String? _d(DateTime? d) => d == null ? null : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _confirm() async {
    setState(() => _busy = true);
    final r = await runAction<Map<String, dynamic>>(
      context,
      ref,
      () => ref.read(apiProvider).rpcMap('confirm_upload', {
        'p_task': t['id'],
        'p_file_name': _isFile ? _fileName.text.trim() : null,
        'p_sha256': _fp?.sha256,
        'p_doc_number': _docNo.text.trim().isEmpty ? null : _docNo.text.trim(),
        'p_issuer': _issuer.text.trim().isEmpty ? null : _issuer.text.trim(),
        'p_issue_date': _d(_issueDate),
        'p_expiry_date': _d(_expiryDate),
        'p_evidence_ref': _evidence.text.trim().isEmpty ? null : _evidence.text.trim(),
        'p_form_data': _formData(),
        'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'p_integrity_attested': _isFile ? _attested : null,
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) {
      showSnack(context, r['status'] == 'awaiting_email' ? 'Upload dikonfirmasi · KODE ${r['confirm_code']}. Kirim email konfirmasi.' : 'Terkirim untuk review WFRD');
      widget.onChanged();
    }
  }

  Future<void> _pickDate(bool expiry) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      firstDate: expiry ? now.add(const Duration(days: 1)) : DateTime(now.year - 30),
      lastDate: expiry ? DateTime(now.year + 30) : now,
      initialDate: (expiry ? _expiryDate : _issueDate) ?? (expiry ? now.add(const Duration(days: 365)) : now),
    );
    if (d != null) setState(() => expiry ? _expiryDate = d : _issueDate = d);
  }

  @override
  Widget build(BuildContext context) {
    final step = _StepCounter();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_isFile) ...[
        _Step(
          n: step.next(),
          title: 'Upload ke OneDrive',
          done: _linkOpened,
          child: link == null
              ? const InfoBanner(message: 'Link OneDrive belum tersedia untuk task ini — WFRD sudah diberi tahu. Coba lagi nanti.', color: Brand.red, icon: Icons.link_off_rounded)
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
                    child: Row(children: [
                      const Icon(Icons.cloud_upload_rounded, color: Brand.blue),
                      const SizedBox(width: 10),
                      Expanded(child: SelectableText(link!['url'] as String, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    FilledButton.icon(onPressed: _openLink, icon: const Icon(Icons.open_in_new_rounded), label: const Text('Buka folder')),
                    CopyButton(link!['url'] as String, label: 'Copy link'),
                    StatusBadge(Brand.cyan, Labels.of(Labels.linkType, link!['link_type']), icon: Icons.folder_shared_outlined),
                    if (link!['label'] != null) Text(str(link!['label']), style: Theme.of(context).textTheme.bodySmall),
                  ]),
                  if (link!['personal'] == true) ...[
                    const SizedBox(height: 12),
                    const InfoBanner(
                      message: 'Link ini mengarah ke OneDrive pribadi (bukan tenant WFRD). Pastikan Anda yakin sebelum mengupload dokumen.',
                      color: Brand.amber,
                      icon: Icons.warning_amber_rounded,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(children: [
                    const Icon(Icons.drive_file_rename_outline_rounded, size: 18, color: Brand.grey),
                    const SizedBox(width: 8),
                    const Text('Nama file wajib: '),
                    Flexible(child: MonoText('$taskId - ${_safeLabel(doc['label'])}.pdf', size: 12)),
                    CopyButton('$taskId - ${_safeLabel(doc['label'])}.pdf', tooltip: 'Copy nama file'),
                  ]),
                ]),
        ),
        _Step(
          n: step.next(),
          title: _requiresFp ? 'Sidik jari dokumen (wajib)' : 'Sidik jari dokumen (opsional)',
          done: _fp != null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pilih file yang sama dengan yang Anda upload. SHA-256 dihitung di browser — file TIDAK dikirim ke COMEN.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                onPressed: _hashing ? null : _pickFingerprint,
                icon: _hashing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.fingerprint_rounded),
                label: Text(_fp == null ? 'Pilih file lokal' : 'Ganti file'),
              ),
              if (_fp != null) ...[
                const StatusBadge(Brand.green, 'Nama cocok', icon: Icons.check_circle_rounded),
                MonoText('SHA-256 ${_fp!.sha256.substring(0, 16)}…', size: 12),
                Text('${(_fp!.size / 1024).toStringAsFixed(0)} KB', style: Theme.of(context).textTheme.bodySmall),
              ],
            ]),
          ]),
        ),
      ],
      _Step(
        n: step.next(),
        title: switch (kind) { 'form' => 'Isi form', 'checklist' => 'Checklist', 'action' => 'Bukti pelaksanaan', _ => 'Data dokumen' },
        done: false,
        child: switch (kind) {
          'checklist' => _ChecklistView(data: widget.data, onChanged: widget.onChanged, editable: true),
          'form' => _buildForm(),
          'action' => Column(children: [
              TextField(controller: _evidence, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Referensi bukti (nomor dokumen / link OneDrive)')),
              const SizedBox(height: 12),
              TextField(controller: _note, onChanged: (_) => setState(() {}), maxLines: 3, decoration: const InputDecoration(labelText: 'Catatan pelaksanaan')),
            ]),
          _ => Column(children: [
              TextField(
                controller: _fileName,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Nama file yang diupload *',
                  errorText: _fileName.text.isEmpty || _nameOk ? null : 'Harus diawali "$taskId" lalu spasi/titik',
                  prefixIcon: const Icon(Icons.insert_drive_file_outlined),
                ),
              ),
              const SizedBox(height: 12),
              ResponsiveGrid(minItemWidth: 240, spacing: 12, children: [
                TextField(controller: _docNo, decoration: const InputDecoration(labelText: 'Nomor dokumen')),
                TextField(controller: _issuer, decoration: const InputDecoration(labelText: 'Penerbit')),
                _DateField(label: 'Tanggal terbit', value: _issueDate, onTap: () => _pickDate(false)),
                if (_requiresExpiry) _DateField(label: 'Tanggal kedaluwarsa *', value: _expiryDate, onTap: () => _pickDate(true)),
              ]),
              const SizedBox(height: 12),
              TextField(controller: _note, maxLines: 2, decoration: const InputDecoration(labelText: 'Catatan untuk reviewer (opsional)')),
            ]),
        },
      ),
      _Step(
        n: step.next(),
        title: 'Konfirmasi',
        done: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_isFile)
            CheckboxListTile(
              value: _attested,
              onChanged: (v) => setState(() => _attested = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Saya menyatakan file sudah diupload ke folder OneDrive di atas', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Pernyataan integritas tercatat di audit log.'),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _ready ? _confirm : null,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18)),
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.verified_rounded),
              label: Text(_isFile ? 'KONFIRMASI UPLOAD' : 'KIRIM'),
            ),
          ),
          if (doc['requires_email'] == true)
            Text('Setelah konfirmasi, Anda akan mendapat KODE dan template email konfirmasi untuk dikirim ke reviewer.', textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    ]);
  }

  Widget _buildForm() {
    Widget f(String k, String label, {bool number = false, int lines = 1}) => TextField(
          controller: _form[k],
          maxLines: lines,
          onChanged: (_) => setState(() {}),
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : null,
          decoration: InputDecoration(labelText: label),
        );
    if (_isMonthly) {
      return Column(children: [
        ResponsiveGrid(minItemWidth: 200, spacing: 12, children: [
          f('period', 'Periode (YYYY-MM) *'),
          f('man_hours', 'Man-hours *', number: true),
          f('km_driven', 'Kilometer berkendara *', number: true),
          f('lti', 'LTI', number: true),
          f('recordable', 'Recordable injury', number: true),
          f('near_miss', 'Near miss', number: true),
          f('observations', 'Safety observation', number: true),
        ]),
        const SizedBox(height: 12),
        f('summary', 'Ringkasan bulan ini', lines: 3),
      ]);
    }
    return Column(children: [f('summary', 'Ringkasan *', lines: 3), const SizedBox(height: 12), f('details', 'Detail tambahan', lines: 4)]);
  }
}

class _StepCounter {
  int _n = 0;
  int next() => ++_n;
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.title, required this.child, this.done = false});
  final int n;
  final String title;
  final Widget child;
  final bool done;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SectionCard(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: done ? Brand.green : Brand.blue,
              child: done ? const Icon(Icons.check_rounded, size: 18, color: Colors.white) : Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(title.toUpperCase(), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                const SizedBox(height: 12),
                child,
              ]),
            ),
          ]),
        ),
      );
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap});
  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.calendar_month_rounded)),
          child: Text(value == null ? 'Pilih tanggal' : fmtDate(value!.toIso8601String())),
        ),
      );
}

// ═══════════════════════════ Email konfirmasi (7.6) ═══════════════════════════
class _EmailCard extends ConsumerStatefulWidget {
  const _EmailCard({required this.taskUuid, required this.canClaim, required this.onChanged});
  final String taskUuid;
  final bool canClaim;
  final VoidCallback onChanged;
  @override
  ConsumerState<_EmailCard> createState() => _EmailCardState();
}

class _EmailCardState extends ConsumerState<_EmailCard> {
  late Future<J> _ctx = ref.read(apiProvider).rpcMap('get_task_email_context', {'p_task': widget.taskUuid});
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Email konfirmasi',
      icon: Icons.mark_email_unread_rounded,
      subtitle: 'Langkah terakhir: kirim email berisi KODE agar reviewer dapat mencocokkan upload Anda.',
      child: AsyncView<J>(
        future: _ctx,
        onRetry: () => setState(() => _ctx = ref.read(apiProvider).rpcMap('get_task_email_context', {'p_task': widget.taskUuid})),
        builder: (context, c) {
          final uri = mailtoFrom(c);
          final tooLong = uri.toString().length > 1800;
          final template = 'To: ${c['to']}\n${c['cc'] != null ? 'CC: ${c['cc']}\n' : ''}Subject: ${c['subject']}\n\n${c['body']}';
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Text('KODE', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.grey)),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(gradient: Brand.heroGradient, borderRadius: BorderRadius.circular(12)),
                child: SelectableText(str(c['code']), style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 3, fontFamily: 'monospace')),
              ),
              CopyButton(str(c['code']), tooltip: 'Copy kode'),
            ]),
            const SizedBox(height: 16),
            KeyValueGrid([
              ('To', SelectableText(str(c['to']))),
              if (c['cc'] != null) ('CC', SelectableText(str(c['cc']))),
              ('Subject', SelectableText(str(c['subject']))),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
              child: SelectableText(str(c['body']), style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5)),
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.end, children: [
              if (!tooLong)
                OutlinedButton.icon(onPressed: () => launchUrl(uri), icon: const Icon(Icons.outgoing_mail), label: const Text('Buka aplikasi email')),
              CopyButton(template, label: 'Copy template'),
              if (widget.canClaim)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final ok = await showConfirm(context,
                              title: 'Sudah mengirim email?', message: 'Pastikan email dengan KODE ${c['code']} sudah terkirim ke ${c['to']}. Reviewer akan memverifikasinya.', confirmLabel: 'Ya, sudah');
                          if (!ok || !context.mounted) return;
                          setState(() => _busy = true);
                          await runAction(context, ref, () => ref.read(apiProvider).rpc('claim_confirmation_email', {'p_task': widget.taskUuid}), success: 'Terkirim untuk review WFRD');
                          if (mounted) setState(() => _busy = false);
                          widget.onChanged();
                        },
                  icon: const Icon(Icons.task_alt_rounded),
                  label: const Text('Saya sudah mengirim email'),
                ),
            ]),
            if (tooLong) const Text('Template terlalu panjang untuk tautan mailto — gunakan Copy template.', textAlign: TextAlign.right, style: TextStyle(fontSize: 12)),
          ]);
        },
      ),
    );
  }
}

// ═══════════════════════════ Checklist ═══════════════════════════
class _ChecklistView extends ConsumerWidget {
  const _ChecklistView({required this.data, required this.onChanged, required this.editable});
  final J data;
  final VoidCallback onChanged;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = _l(data['checklist']);
    final canReview = data['can_review'] == true && const {'submitted', 'under_review'}.contains(_m(data['task'])['status']);
    if (items.isEmpty) return const EmptyState(icon: Icons.checklist_rounded, title: 'Checklist kosong');
    String? lastCat;
    final children = <Widget>[];
    for (final i in items) {
      if (i['category'] != null && i['category'] != lastCat) {
        lastCat = i['category'] as String;
        children.add(Padding(padding: const EdgeInsets.only(top: 12, bottom: 4), child: Text(lastCat, style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.blue))));
      }
      final mine = i['owner_party'] == 'contractor';
      children.add(ListTile(
        contentPadding: EdgeInsets.zero,
        leading: editable && mine
            ? Checkbox(
                value: i['checked'] == true,
                onChanged: (v) => runAction(context, ref, () => ref.read(apiProvider).rpc('checklist_set_item', {
                      'p_item': i['id'],
                      'p_checked': v ?? false,
                      'p_evidence_ref': i['evidence_ref'],
                      'p_notes': i['notes'],
                    })).then((_) => onChanged()),
              )
            : Icon(i['checked'] == true ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: i['checked'] == true ? Brand.green : Brand.grey),
        title: Text('${i['item_no']}. ${i['label']}'),
        subtitle: Text([
          mine ? 'Contractor' : 'WFRD',
          if (i['evidence_ref'] != null) 'Bukti: ${i['evidence_ref']}',
          if (i['notes'] != null) i['notes'],
        ].join(' · ')),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (editable && mine)
            IconButton(
              tooltip: 'Bukti / catatan',
              icon: const Icon(Icons.edit_note_rounded),
              onPressed: () async {
                final ev = TextEditingController(text: i['evidence_ref'] as String?);
                final nt = TextEditingController(text: i['notes'] as String?);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text('Item ${i['item_no']}'),
                    content: SizedBox(
                      width: 420,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(controller: ev, decoration: const InputDecoration(labelText: 'Referensi bukti')),
                        const SizedBox(height: 12),
                        TextField(controller: nt, maxLines: 3, decoration: const InputDecoration(labelText: 'Catatan')),
                      ]),
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Simpan'))],
                  ),
                );
                if (ok == true && context.mounted) {
                  await runAction(context, ref, () => ref.read(apiProvider).rpc('checklist_set_item', {
                        'p_item': i['id'],
                        'p_checked': i['checked'] == true,
                        'p_evidence_ref': ev.text.trim().isEmpty ? null : ev.text.trim(),
                        'p_notes': nt.text.trim().isEmpty ? null : nt.text.trim(),
                      }));
                  onChanged();
                }
              },
            ),
          if (i['verified'] == true) const StatusBadge(Brand.green, 'Terverifikasi', icon: Icons.verified_rounded),
          if (canReview && i['verified'] != true)
            TextButton.icon(
              onPressed: () => runAction(context, ref, () => ref.read(apiProvider).rpc('checklist_verify_item', {'p_item': i['id'], 'p_verified': true, 'p_notes': null})).then((_) => onChanged()),
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: const Text('Verifikasi'),
            ),
        ]),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

// ═══════════════════════════ Reviewer (17.4) ═══════════════════════════
class _ReviewPanel extends ConsumerStatefulWidget {
  const _ReviewPanel({required this.data, required this.onChanged});
  final J data;
  final VoidCallback onChanged;
  @override
  ConsumerState<_ReviewPanel> createState() => _ReviewPanelState();
}

class _ReviewPanelState extends ConsumerState<_ReviewPanel> {
  late final J t = _m(widget.data['task']);
  late final J doc = _m(widget.data['doc']);
  late final J? link = widget.data['link'] == null ? null : _m(widget.data['link']);
  String _decision = 'approve';
  final _notes = TextEditingController();
  final _dueDays = TextEditingController(text: '5');
  bool _emailConfirmed = false, _busy = false;
  bool? _fpVerified;

  bool get _needsEmail => doc['requires_email'] == true && t['email_verified'] != true;

  Future<void> _verifyFp() async {
    final r = await pickAndHash(ref.read(secureStoreProvider));
    if (r == null) return;
    setState(() => _fpVerified = r.sha256 == t['file_sha256']);
  }

  @override
  Widget build(BuildContext context) {
    final status = t['status'] as String;
    final sha = t['file_sha256'] as String?;
    final notesRequired = _decision != 'approve';
    final canSubmit = !_busy &&
        (!notesRequired || _notes.text.trim().length >= 5) &&
        (_decision != 'approve' || !_needsEmail || _emailConfirmed) &&
        (_decision != 'approve' || doc['requires_fingerprint'] != true || _fpVerified != false);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SectionCard(
        title: 'Review WFRD',
        icon: Icons.fact_check_rounded,
        subtitle: t['review_due_at'] == null ? null : 'SLA review: ${fmtDateTime(t['review_due_at'])} (${fmtRelative(t['review_due_at'])})',
        trailing: status == 'submitted'
            ? FilledButton.icon(
                onPressed: () => runAction(context, ref, () => ref.read(apiProvider).rpc('start_review', {'p_task': t['id']}), success: 'Review dimulai').then((_) => widget.onChanged()),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Mulai review'),
              )
            : const StatusBadge(Brand.purple, 'Sedang direview', icon: Icons.visibility_rounded),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValueGrid([
            ('File', SelectableText(str(t['uploaded_file_name']))),
            ('SHA-256', sha == null ? const Text('(tidak diisi)') : SelectableText(sha, style: const TextStyle(fontFamily: 'monospace', fontSize: 11))),
            ('Email', t['email_verified'] == true ? const StatusBadge(Brand.green, 'Terverifikasi (inbound)', icon: Icons.mark_email_read_rounded) : Text(t['email_claimed_at'] == null ? 'Belum diklaim' : 'Diklaim ${fmtRelative(t['email_claimed_at'])}')),
            ('Kode', SelectableText(str(t['confirm_code']), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (link != null)
              OutlinedButton.icon(
                onPressed: () => runAction(context, ref, () async {
                  await ref.read(apiProvider).rpc('log_link_opened', {'p_task': t['id']});
                  await UrlPolicy.open(link!['url'] as String);
                }),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Buka folder OneDrive'),
              ),
            if (sha != null) OutlinedButton.icon(onPressed: _verifyFp, icon: const Icon(Icons.fingerprint_rounded), label: const Text('Verifikasi sidik jari')),
            if (_fpVerified == true) const StatusBadge(Brand.green, 'Sidik jari cocok', icon: Icons.check_circle_rounded),
            if (_fpVerified == false) const StatusBadge(Brand.red, 'Sidik jari BERBEDA — gunakan File bermasalah', icon: Icons.error_rounded),
          ]),
          if (status == 'under_review') ...[
            const Divider(height: 32),
            if (_needsEmail)
              CheckboxListTile(
                value: _emailConfirmed,
                onChanged: (v) => setState(() => _emailConfirmed = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('Email konfirmasi dengan KODE ${str(t['confirm_code'])} sudah saya terima'),
              ),
            const Text('Keputusan', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'approve', label: Text('Approve'), icon: Icon(Icons.check_circle_outline)),
                ButtonSegment(value: 'revise', label: Text('Revisi'), icon: Icon(Icons.edit_note_rounded)),
                ButtonSegment(value: 'reject', label: Text('Tolak'), icon: Icon(Icons.cancel_outlined)),
                ButtonSegment(value: 'file_issue', label: Text('File bermasalah'), icon: Icon(Icons.report_problem_outlined)),
              ],
              selected: {_decision},
              onSelectionChanged: (v) => setState(() => _decision = v.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: notesRequired ? 'Catatan (wajib, min. 5 karakter)' : 'Catatan (opsional)'),
            ),
            if (_decision == 'revise') ...[
              const SizedBox(height: 12),
              SizedBox(width: 240, child: TextField(controller: _dueDays, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Batas revisi (hari kerja)'))),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: canSubmit
                    ? () async {
                        setState(() => _busy = true);
                        final r = await runAction(
                          context,
                          ref,
                          () => ref.read(apiProvider).rpcMap('review_task', {
                            'p_task': t['id'],
                            'p_decision': _decision,
                            'p_notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
                            'p_email_confirmed': _emailConfirmed,
                            'p_fingerprint_verified': _fpVerified,
                            'p_revision_due_days': _decision == 'revise' ? int.tryParse(_dueDays.text) : null,
                          }),
                          success: 'Keputusan tersimpan',
                        );
                        if (mounted) setState(() => _busy = false);
                        if (r != null) widget.onChanged();
                      }
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: switch (_decision) { 'approve' => Brand.green, 'reject' => Brand.red, 'file_issue' => Brand.purple, _ => Brand.amber },
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                ),
                icon: const Icon(Icons.gavel_rounded),
                label: const Text('SIMPAN KEPUTUSAN'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

// ═══════════════════════════ WFRD action & menu ═══════════════════════════
class _WfrdActionCard extends ConsumerStatefulWidget {
  const _WfrdActionCard({required this.task, required this.onChanged});
  final J task;
  final VoidCallback onChanged;
  @override
  ConsumerState<_WfrdActionCard> createState() => _WfrdActionCardState();
}

class _WfrdActionCardState extends ConsumerState<_WfrdActionCard> {
  final _ev = TextEditingController();
  final _note = TextEditingController();
  @override
  Widget build(BuildContext context) => SectionCard(
        title: 'Selesaikan action WFRD',
        icon: Icons.task_alt_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _ev, decoration: const InputDecoration(labelText: 'Referensi bukti')),
          const SizedBox(height: 12),
          TextField(controller: _note, maxLines: 3, decoration: const InputDecoration(labelText: 'Catatan')),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () => runAction(context, ref, () => ref.read(apiProvider).rpc('complete_wfrd_action', {
                    'p_task': widget.task['id'],
                    'p_evidence_ref': _ev.text.trim().isEmpty ? null : _ev.text.trim(),
                    'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
                  }), success: 'Action selesai').then((_) => widget.onChanged()),
              child: const Text('Tandai selesai'),
            ),
          ),
        ]),
      );
}

class _WfrdMenu extends ConsumerWidget {
  const _WfrdMenu({required this.task, required this.s, required this.onChanged});
  final J task;
  final Set<String> s;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = task['status'] as String;
    final api = ref.read(apiProvider);
    final items = <PopupMenuEntry<String>>[
      if (const {'open', 'awaiting_email', 'file_issue', 'submitted', 'under_review', 'rejected'}.contains(status))
        const PopupMenuItem(value: 'waive', child: ListTile(leading: Icon(Icons.do_not_disturb_on_outlined), title: Text('Waive (N/A)'))),
      if (const {'open', 'awaiting_email', 'file_issue'}.contains(status))
        const PopupMenuItem(value: 'cancel', child: ListTile(leading: Icon(Icons.cancel_outlined), title: Text('Batalkan task'))),
      if (status == 'rejected') const PopupMenuItem(value: 'reopen', child: ListTile(leading: Icon(Icons.restart_alt_rounded), title: Text('Buka ulang (revisi)'))),
      if (status == 'approved') const PopupMenuItem(value: 'supersede', child: ListTile(leading: Icon(Icons.swap_horiz_rounded), title: Text('Supersede (MOC)'))),
      const PopupMenuItem(value: 'email', child: ListTile(leading: Icon(Icons.mail_outline), title: Text('Lihat konteks email'))),
    ];
    return PopupMenuButton<String>(
      tooltip: 'Aksi WFRD',
      icon: const Icon(Icons.more_vert_rounded),
      itemBuilder: (_) => items,
      onSelected: (v) async {
        switch (v) {
          case 'waive':
            final r = await showReasonDialog(context, title: 'Waive task', message: 'Task dianggap tidak berlaku (N/A). Tercatat di audit log.', confirmLabel: 'Waive', destructive: true);
            if (r != null && context.mounted) await runAction(context, ref, () => api.rpc('waive_task', {'p_task': task['id'], 'p_reason': r}), success: 'Task di-waive');
          case 'cancel':
            final r = await showReasonDialog(context, title: 'Batalkan task', message: 'Contractor akan diberi tahu.', confirmLabel: 'Batalkan', destructive: true);
            if (r != null && context.mounted) await runAction(context, ref, () => api.rpc('cancel_task', {'p_task': task['id'], 'p_reason': r}), success: 'Task dibatalkan');
          case 'reopen':
            final r = await showReasonDialog(context, title: 'Buka ulang task', message: 'Membuat revisi baru dengan batas 5 hari kerja.', confirmLabel: 'Buka ulang');
            if (r != null && context.mounted) {
              final id = await runAction(context, ref, () => api.rpc('reopen_rejected_task', {'p_task': task['id'], 'p_due_days': 5, 'p_reason': r}), success: 'Revisi dibuat');
              if (id != null && context.mounted) context.go('/tasks/$id');
            }
          case 'supersede':
            final due = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)), initialDate: DateTime.now().add(const Duration(days: 14)));
            if (due == null || !context.mounted) return;
            final r = await showReasonDialog(context, title: 'Supersede (MOC)', message: 'Task baru akan dibuat; task ini menjadi superseded.', confirmLabel: 'Supersede');
            if (r != null && context.mounted) {
              final id = await runAction(context, ref,
                  () => api.rpc('supersede_task', {'p_task': task['id'], 'p_due': '${due.year}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')}', 'p_reason': r}),
                  success: 'Task baru dibuat');
              if (id != null && context.mounted) context.go('/tasks/$id');
            }
          case 'email':
            await showDialog<void>(
              context: context,
              builder: (c) => Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: SingleChildScrollView(child: _EmailCard(taskUuid: task['id'] as String, canClaim: false, onChanged: () {})))),
            );
            return;
        }
        onChanged();
      },
    );
  }
}

// ═══════════════════════════ Info & timeline ═══════════════════════════
class _SubmissionInfo extends StatelessWidget {
  const _SubmissionInfo({required this.task, required this.link});
  final J task;
  final J? link;

  @override
  Widget build(BuildContext context) {
    final fd = _m(task['form_data']);
    return SectionCard(
      title: 'Detail',
      icon: Icons.info_outline_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValueGrid(minItemWidth: 200, [
          ('Kode dokumen', MonoText(str(task['doc_type_code']))),
          ('Scope', Text(Labels.of(Labels.scope, task['scope']))),
          ('Dibuat', Text(fmtDateTime(task['created_at']))),
          ('Dikonfirmasi', Text(fmtDateTime(task['upload_confirmed_at']))),
          ('No. dokumen', Text(str(task['doc_number']))),
          ('Penerbit', Text(str(task['issuer']))),
          ('Terbit', Text(fmtDate(task['issue_date']))),
          ('Kedaluwarsa', Text(fmtDate(task['expiry_date']))),
          ('Direview', Text(fmtDateTime(task['reviewed_at']))),
          ('Sidik jari diverifikasi', Text(task['fingerprint_verified'] == null ? '-' : (task['fingerprint_verified'] == true ? 'Cocok' : 'Berbeda'))),
          if (task['evidence_ref'] != null) ('Bukti', Text(str(task['evidence_ref']))),
          if (link != null) ('Folder', Text(str(link!['label'] ?? link!['scope_type']))),
        ]),
        if (task['description'] != null) ...[const SizedBox(height: 12), Text(str(task['description']))],
        if (fd.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Data form', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          SelectableText(const JsonEncoder.withIndent('  ').convert(fd), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ]),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.events, required this.revisions, required this.currentId});
  final List<J> events, revisions;
  final String currentId;

  IconData _icon(String e) => switch (e) {
        'link_opened' => Icons.folder_open_rounded,
        'upload_confirmed' => Icons.cloud_done_rounded,
        'email_claimed' || 'email_verified' => Icons.mark_email_read_rounded,
        'review_started' => Icons.visibility_rounded,
        'approved' => Icons.verified_rounded,
        'rejected' || 'cancelled' => Icons.cancel_rounded,
        'revise' || 'reopened' => Icons.edit_note_rounded,
        'file_issue' => Icons.report_problem_rounded,
        'reminder' || 'escalated' => Icons.notifications_active_rounded,
        _ => Icons.circle_outlined,
      };

  @override
  Widget build(BuildContext context) => SectionCard(
        title: 'Timeline',
        icon: Icons.timeline_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (revisions.length > 1) ...[
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in revisions)
                ActionChip(
                  avatar: Icon(r['id'] == currentId ? Icons.radio_button_checked : Icons.radio_button_off, size: 16),
                  label: Text('${r['task_id']} · ${StatusStyle.task(r['status'] as String?).$2}', style: const TextStyle(fontSize: 12)),
                  onPressed: r['id'] == currentId ? null : () => context.go('/tasks/${r['id']}'),
                ),
            ]),
            const Divider(height: 24),
          ],
          if (events.isEmpty) const Text('Belum ada aktivitas'),
          for (final (i, e) in events.reversed.indexed)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Column(children: [
                CircleAvatar(radius: 14, backgroundColor: Brand.blue.withValues(alpha: 0.12), child: Icon(_icon(e['event'] as String), size: 15, color: Brand.blue)),
                if (i < events.length - 1) Container(width: 2, height: 28, color: Theme.of(context).dividerColor),
              ]),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(Labels.of(Labels.taskEvent, e['event']), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      [fmtDateTime(e['at']), if (_m(e['payload'])['reason'] != null) _m(e['payload'])['reason'], if (_m(e['payload'])['decision'] != null) _m(e['payload'])['decision']].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ]),
                ),
              ),
            ]),
        ]),
      );
}
