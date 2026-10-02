import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/security/url_policy.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

const _scopeLabels = <String, String>{
  'global': 'Global',
  'vendor': 'Vendor',
  'contract': 'Kontrak',
  'subcontractor': 'Subkontraktor',
  'task': 'Task',
};
const _linkTypeLabels = <String, String>{'file_request': 'File Request', 'folder_edit': 'Folder (edit)'};

class _LinksData {
  _LinksData(this.links, this.coverage, this.docTypes, this.tasks);
  final List<J> links;
  final List<J>? coverage;
  final List<J> docTypes;
  final Map<String, String> tasks;
}

class AdminOneDrivePage extends ConsumerStatefulWidget {
  const AdminOneDrivePage({super.key});
  @override
  ConsumerState<AdminOneDrivePage> createState() => _AdminOneDrivePageState();
}

class _AdminOneDrivePageState extends ConsumerState<AdminOneDrivePage> {
  late Future<_LinksData> _future = _load();
  String _tab = 'links';
  String _q = '';
  bool _activeOnly = true;

  Future<_LinksData> _load() async {
    final api = ref.read(apiProvider);
    final r = await Future.wait([
      api.select('upload_links', 'id,scope_type,contractor_id,contract_id,subcontractor_id,task_id,doc_type_code,url,link_type,label,expires_at,active,created_at,updated_at',
          build: (q) => q.order('updated_at', ascending: false).limit(1000)),
      api.select('doc_type_catalog', 'code,label,kind,sensitive,active', build: (q) => q.order('code')),
    ]);
    List<J>? coverage;
    try {
      coverage = await api.rpcList('link_coverage', {'p_contract': null});
    } catch (_) {}
    final taskIds = r[0].map((l) => l['task_id']).whereType<String>().toSet().toList();
    final tasks = <String, String>{};
    if (taskIds.isNotEmpty) {
      try {
        for (final t in await api.select('tasks', 'id,task_id', build: (q) => q.inFilter('id', taskIds))) {
          tasks[t['id'] as String] = t['task_id'] as String;
        }
      } catch (_) {}
    }
    return _LinksData(r[0], coverage, r[1], tasks);
  }

  void _reload() => setState(() => _future = _load());

  String _target(J l, AdminLookups? lk, _LinksData d) => switch (l['scope_type']) {
        'vendor' => lk?.contractorName(l['contractor_id'] as String?) ?? shortId(l['contractor_id']),
        'contract' => lk?.contractLabel(l['contract_id'] as String?) ?? shortId(l['contract_id']),
        'subcontractor' => '${lk?.contractLabel(l['contract_id'] as String?) ?? shortId(l['contract_id'])} · sub ${shortId(l['subcontractor_id'])}',
        'task' => d.tasks[l['task_id']] ?? 'Task ${shortId(l['task_id'])}',
        _ => 'Semua task vendor',
      };

  Future<void> _upsert({J? link, String? taskUuid, String? taskLabel, required List<J> docTypes}) async {
    final lookups = await ref.read(adminLookupsProvider.future);
    if (!mounted) return;
    final f = await showDialog<_LinkForm>(context: context, builder: (_) => _LinkDialog(link: link, lookups: lookups, docTypes: docTypes, taskUuid: taskUuid, taskLabel: taskLabel));
    if (f == null || !mounted) return;
    final r = await runAction<J>(
        context,
        ref,
        () => ref.read(apiProvider).rpcMap('admin_upsert_upload_link', {
              'p_id': link?['id'],
              'p_scope_type': f.scope,
              'p_contractor': f.contractor,
              'p_contract': f.contract,
              'p_subcontractor': f.subcontractor,
              'p_task': f.task,
              'p_doc_type': f.docType,
              'p_url': f.url,
              'p_link_type': f.linkType,
              'p_label': f.label,
              'p_expires_at': f.expires == null ? null : isoDate(f.expires!),
              'p_reason': f.reason,
            }),
        success: link == null ? 'Link dibuat' : 'Link diperbarui');
    if (r == null || !mounted) return;
    final warns = (r['warnings'] as List? ?? const []).cast<dynamic>();
    if (warns.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: Brand.amber, size: 36),
          title: const Text('Link tersimpan dengan peringatan'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final w in warns)
              ListTile(
                leading: const Icon(Icons.error_outline_rounded, color: Brand.amber),
                title: Text(switch (w) {
                  'personal_onedrive' => 'Link mengarah ke OneDrive pribadi (bukan tenant WFRD).',
                  'folder_edit_sensitive' => 'Folder edit dipakai untuk dokumen sensitif / tanpa jenis dokumen — contractor bisa melihat file lain.',
                  _ => w.toString(),
                }),
              ),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Mengerti'))],
        ),
      );
    }
    _reload();
  }

  Future<void> _deactivate(J l) async {
    final ok = await withReason(context, ref,
        title: 'Nonaktifkan link',
        message: 'Task yang memakai link ini akan jatuh ke link yang lebih umum (atau tanpa link).',
        confirmLabel: 'Nonaktifkan',
        destructive: true,
        success: 'Link dinonaktifkan',
        action: (r) => ref.read(apiProvider).rpc('admin_deactivate_upload_link', {'p_id': l['id'], 'p_reason': r}));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    final canManage = s?.can('upload_link.manage') ?? false;
    final lk = ref.watch(adminLookupsProvider).valueOrNull;
    return AdminScaffold(
      title: 'OneDrive Link Manager',
      subtitle: 'Resolusi: Task > Subkon+Jenis > Subkon > Kontrak+Jenis > Kontrak > Vendor+Jenis > Vendor > Global',
      actions: [
        if (canManage)
          FilledButton.icon(
            onPressed: () async => _upsert(docTypes: (await _future).docTypes),
            icon: const Icon(Icons.add_link_rounded),
            label: const Text('Link baru'),
          ),
        OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang')),
      ],
      child: AsyncView<_LinksData>(
        future: _future,
        onRetry: _reload,
        builder: (context, d) {
          final gaps = d.coverage?.length ?? 0;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!canManage) ...[const PermissionNote('upload_link.manage', what: 'membuat/mengubah link'), const SizedBox(height: 16)],
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'links', label: Text('Link (${d.links.where((l) => l['active'] == true).length} aktif)'), icon: const Icon(Icons.link_rounded, size: 18)),
                  ButtonSegment(value: 'coverage', label: Text('Link coverage ($gaps)'), icon: Icon(Icons.link_off_rounded, size: 18, color: gaps > 0 ? Brand.amber : null)),
                ],
                selected: {_tab},
                onSelectionChanged: (v) => setState(() => _tab = v.first),
              ),
            ),
            const SizedBox(height: 16),
            if (_tab == 'links') _links(d, lk, canManage) else _coverage(d, canManage),
          ]);
        },
      ),
    );
  }

  Widget _links(_LinksData d, AdminLookups? lk, bool canManage) {
    final q = _q.toLowerCase();
    final list = d.links
        .where((l) => (!_activeOnly || l['active'] == true) && (q.isEmpty || '${l['label']} ${l['url']} ${l['doc_type_code'] ?? ''} ${_target(l, lk, d)}'.toLowerCase().contains(q)))
        .toList();
    return TableCard(
      count: list.length,
      toolbar: [
        AdminSearchField(hint: 'Cari label / URL / target', onChanged: (v) => setState(() => _q = v)),
        FilterChip(label: const Text('Hanya aktif'), selected: _activeOnly, onSelected: (v) => setState(() => _activeOnly = v)),
      ],
      child: DataList(
        empty: 'Belum ada link',
        columns: const ['Scope', 'Target', 'Jenis dok.', 'Label', 'URL', 'Tipe', 'Kedaluwarsa', 'Status', ''],
        rows: [
          for (final l in list)
            [
              StatusBadge(Brand.navy, _scopeLabels[l['scope_type']] ?? str(l['scope_type']), icon: Icons.account_tree_outlined),
              CellText(_target(l, lk, d), maxWidth: 240),
              l['doc_type_code'] == null ? const Text('(default)') : MonoText(str(l['doc_type_code']), size: 12),
              CellText(str(l['label']), maxWidth: 200),
              _UrlCell(url: str(l['url'], '')),
              StatusBadge(l['link_type'] == 'folder_edit' ? Brand.purple : Brand.cyan, _linkTypeLabels[l['link_type']] ?? str(l['link_type'])),
              Text(fmtDate(l['expires_at']), style: TextStyle(color: l['expires_at'] == null ? null : dueColor(l['expires_at']))),
              BoolBadge(l['active'] == true, trueLabel: 'Aktif', falseLabel: 'Nonaktif'),
              canManage
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'Ubah', onPressed: () => _upsert(link: l, docTypes: d.docTypes), icon: const Icon(Icons.edit_outlined, size: 20)),
                      if (l['active'] == true) IconButton(tooltip: 'Nonaktifkan', onPressed: () => _deactivate(l), icon: const Icon(Icons.link_off_rounded, size: 20, color: Brand.red)),
                    ])
                  : const SizedBox.shrink(),
            ],
        ],
      ),
    );
  }

  Widget _coverage(_LinksData d, bool canManage) {
    final c = d.coverage;
    if (c == null) return const SectionCard(child: InfoBanner(message: 'Link coverage tidak tersedia untuk akun Anda.', color: Brand.grey));
    return TableCard(
      title: 'Task terbuka tanpa link',
      subtitle: 'Reminder ke contractor ditahan sampai link tersedia (alert #2012)',
      icon: Icons.link_off_rounded,
      count: c.length,
      child: c.isEmpty
          ? const EmptyState(icon: Icons.verified_rounded, title: 'Semua task punya link', message: 'Tidak ada task dokumen/bukti terbuka tanpa folder OneDrive.')
          : DataList(
              columns: const ['Task ID', 'Judul', 'Kontrak', 'Contractor', 'Due', ''],
              rows: [
                for (final t in c)
                  [
                    TaskIdChip(str(t['task_id'])),
                    CellText(str(t['title']), maxWidth: 260),
                    Text(str(t['contract_no'], 'Vendor')),
                    Text(str(t['contractor_name'])),
                    StatusBadge(dueColor(t['due_date']), '${fmtDate(t['due_date'])} · ${dueLabel(t['due_date'])}'),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (canManage)
                        FilledButton.tonalIcon(
                          onPressed: () => _upsert(taskUuid: t['task_uuid'] as String, taskLabel: '${t['task_id']} · ${t['title']}', docTypes: d.docTypes),
                          icon: const Icon(Icons.add_link_rounded, size: 18),
                          label: const Text('Buat link'),
                        ),
                      IconButton(tooltip: 'Buka task', onPressed: () => context.go('/tasks/${t['task_uuid']}'), icon: const Icon(Icons.open_in_new_rounded, size: 18)),
                    ]),
                  ],
              ],
            ),
    );
  }
}

class _UrlCell extends ConsumerWidget {
  const _UrlCell({required this.url});
  final String url;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (UrlPolicy.isPersonalOneDrive(url)) const Tooltip(message: 'OneDrive pribadi', child: Icon(Icons.person_pin_rounded, size: 16, color: Brand.amber)),
          Flexible(
            child: InkWell(
              onTap: UrlPolicy.clickable(url) ? () => runAction(context, ref, () => UrlPolicy.open(url)) : null,
              child: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Brand.blue)),
            ),
          ),
          CopyButton(url, tooltip: 'Copy URL'),
        ]),
      );
}

class _LinkForm {
  _LinkForm({required this.scope, this.contractor, this.contract, this.subcontractor, this.task, this.docType, required this.url, required this.linkType, required this.label, this.expires, required this.reason});
  final String scope, url, linkType, label, reason;
  final String? contractor, contract, subcontractor, task, docType;
  final DateTime? expires;
}

class _LinkDialog extends ConsumerStatefulWidget {
  const _LinkDialog({this.link, required this.lookups, required this.docTypes, this.taskUuid, this.taskLabel});
  final J? link;
  final AdminLookups lookups;
  final List<J> docTypes;
  final String? taskUuid;
  final String? taskLabel;
  @override
  ConsumerState<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends ConsumerState<_LinkDialog> {
  late String _scope = widget.link?['scope_type'] as String? ?? (widget.taskUuid != null ? 'task' : 'contract');
  late String? _contractor = widget.link?['contractor_id'] as String?;
  late String? _contract = widget.link?['contract_id'] as String?;
  late String? _sub = widget.link?['subcontractor_id'] as String?;
  late final _task = TextEditingController(text: widget.link?['task_id'] as String? ?? widget.taskUuid ?? '');
  late String? _docType = widget.link?['doc_type_code'] as String?;
  late final _url = TextEditingController(text: widget.link?['url'] as String? ?? '');
  late String _type = widget.link?['link_type'] as String? ?? 'file_request';
  late final _label = TextEditingController(text: widget.link?['label'] as String? ?? '');
  late DateTime? _expires = parseDate(widget.link?['expires_at']);
  final _reason = TextEditingController();
  Future<List<J>>? _subs;

  bool get _edit => widget.link != null;

  @override
  void initState() {
    super.initState();
    if (_contract != null) _loadSubs();
  }

  void _loadSubs() {
    final c = _contract;
    _subs = c == null ? null : ref.read(apiProvider).select('subcontractors', 'id,contract_id,sub_seq,legal_name,status', build: (q) => q.eq('contract_id', c).order('sub_seq'));
  }

  bool get _targetOk => switch (_scope) {
        'vendor' => _contractor != null,
        'contract' => _contract != null,
        'subcontractor' => _contract != null && _sub != null,
        'task' => uuidRe.hasMatch(_task.text.trim()),
        _ => true,
      };

  bool get _ok => (_edit || _targetOk) && UrlPolicy.isOneDrive(_url.text) && _label.text.trim().isNotEmpty && _reason.text.trim().length >= 5;

  @override
  Widget build(BuildContext context) {
    final url = _url.text.trim();
    final sensitive = _docType != null && widget.docTypes.any((d) => d['code'] == _docType && d['sensitive'] == true);
    return AlertDialog(
      title: Text(_edit ? 'Ubah link OneDrive' : 'Link OneDrive baru'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_edit)
              InfoBanner(message: 'Scope ${_scopeLabels[_scope]} · target & jenis dokumen tidak bisa diubah (buat link baru bila perlu).', icon: Icons.lock_outline_rounded)
            else ...[
              const Text('Scope', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final e in _scopeLabels.entries)
                  ChoiceChip(label: Text(e.value), selected: _scope == e.key, onSelected: (_) => setState(() => _scope = e.key)),
              ]),
              const SizedBox(height: 12),
              if (_scope == 'vendor')
                LookupPicker(
                  label: 'Contractor *',
                  icon: Icons.apartment_rounded,
                  value: _contractor,
                  items: [for (final c in widget.lookups.contractors) (c['id'] as String, str(c['legal_name']))],
                  onChanged: (v) => setState(() => _contractor = v),
                ),
              if (_scope == 'contract' || _scope == 'subcontractor')
                LookupPicker(
                  label: 'Kontrak *',
                  icon: Icons.handshake_outlined,
                  value: _contract,
                  items: [for (final k in widget.lookups.contracts) (k['id'] as String, '${str(k['contract_no'])} · ${str(k['title'])}')],
                  onChanged: (v) => setState(() {
                    _contract = v;
                    _sub = null;
                    _loadSubs();
                  }),
                ),
              if (_scope == 'subcontractor' && _subs != null) ...[
                const SizedBox(height: 12),
                FutureBuilder<List<J>>(
                  future: _subs,
                  builder: (context, s) {
                    if (s.connectionState != ConnectionState.done) return const LinearProgressIndicator();
                    final subs = s.data ?? const <J>[];
                    if (subs.isEmpty) return const InfoBanner(message: 'Kontrak ini belum punya subkontraktor.', color: Brand.amber);
                    return DropdownButtonFormField<String>(
                      key: ValueKey(_contract),
                      initialValue: _sub,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Subkontraktor *'),
                      items: [for (final x in subs) DropdownMenuItem(value: x['id'] as String, child: Text('S${x['sub_seq']} · ${x['legal_name']} (${x['status']})'))],
                      onChanged: (v) => setState(() => _sub = v),
                    );
                  },
                ),
              ],
              if (_scope == 'task') ...[
                if (widget.taskLabel != null) ...[InfoBanner(message: widget.taskLabel!, icon: Icons.task_alt_rounded), const SizedBox(height: 12)],
                TextField(
                  controller: _task,
                  enabled: widget.taskUuid == null,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Task UUID *', helperText: 'Ambil dari URL halaman task (/tasks/<uuid>) atau tab Link coverage'),
                ),
              ],
              if (_scope != 'task') ...[
                const SizedBox(height: 12),
                LookupPicker(
                  label: 'Jenis dokumen (opsional — kosong = default scope)',
                  icon: Icons.description_outlined,
                  value: _docType,
                  items: [('', '(default scope)'), for (final d in widget.docTypes.where((d) => d['active'] == true)) (d['code'] as String, '${d['code']} · ${d['label']}')],
                  onChanged: (v) => setState(() => _docType = (v == null || v.isEmpty) ? null : v),
                ),
              ],
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'URL OneDrive / SharePoint *',
                prefixIcon: const Icon(Icons.cloud_outlined),
                errorText: url.isEmpty || UrlPolicy.isOneDrive(url) ? null : 'Harus https:// 1drv.ms, onedrive.live.com, atau *.sharepoint.com',
              ),
            ),
            if (UrlPolicy.isPersonalOneDrive(url)) ...[
              const SizedBox(height: 8),
              const InfoBanner(message: 'Link OneDrive pribadi (bukan tenant WFRD) — contractor akan diberi peringatan.', color: Brand.amber, icon: Icons.person_pin_rounded),
            ],
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'file_request', label: Text('File Request (upload saja)'), icon: Icon(Icons.upload_file_rounded, size: 18)),
                ButtonSegment(value: 'folder_edit', label: Text('Folder (edit)'), icon: Icon(Icons.folder_shared_outlined, size: 18)),
              ],
              selected: {_type},
              onSelectionChanged: (v) => setState(() => _type = v.first),
            ),
            if (_type == 'folder_edit' && (sensitive || (_docType == null && !_edit))) ...[
              const SizedBox(height: 8),
              const InfoBanner(message: 'Folder edit memperlihatkan isi folder ke contractor — hindari untuk dokumen sensitif.', color: Brand.amber, icon: Icons.visibility_rounded),
            ],
            const SizedBox(height: 12),
            ResponsiveGrid(minItemWidth: 260, spacing: 12, children: [
              TextField(controller: _label, maxLength: 200, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Label *', counterText: '')),
              DateField(label: 'Link kedaluwarsa (opsional)', value: _expires, first: DateTime.now(), onChanged: (d) => setState(() => _expires = d)),
            ]),
            const SizedBox(height: 12),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: _ok
              ? () => Navigator.pop(
                    context,
                    _LinkForm(
                      scope: _scope,
                      contractor: _scope == 'vendor' ? _contractor : null,
                      contract: (_scope == 'contract' || _scope == 'subcontractor') ? _contract : null,
                      subcontractor: _scope == 'subcontractor' ? _sub : null,
                      task: _scope == 'task' ? _task.text.trim() : null,
                      docType: _scope == 'task' ? null : _docType,
                      url: url,
                      linkType: _type,
                      label: _label.text.trim(),
                      expires: _expires,
                      reason: _reason.text.trim(),
                    ),
                  )
              : null,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
