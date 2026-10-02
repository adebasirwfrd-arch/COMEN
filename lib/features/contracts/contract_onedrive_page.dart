import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/errors/app_failure.dart';
import '../../core/security/url_policy.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'contract_common.dart';

const _linkCols = 'id,scope_type,contractor_id,contract_id,subcontractor_id,task_id,doc_type_code,url,link_type,label,expires_at,active,created_by,created_at,updated_at';

const _phaseFolder = {
  'post_award': '01-POST-AWARD',
  'pre_mobilization': '02-PRE-MOB',
  'mobilization': '03-MOBILIZATION',
  'execution': '04-EXECUTION',
  'monitoring': '04-EXECUTION/EVIDENCE',
  'demobilization': '05-DEMOB',
  'final_evaluation': '06-OPR',
};

const _linkTypeLabel = {'file_request': 'File Request', 'folder_edit': 'Folder (edit)'};

const _warnLabel = {
  'personal_onedrive': 'Link OneDrive personal (1drv.ms / onedrive.live.com) — gunakan OneDrive for Business / SharePoint tenant Weatherford.',
  'folder_edit_sensitive': 'Folder edit dipakai untuk dokumen sensitif / semua jenis — File Request lebih aman (kontraktor hanya bisa upload).',
};

String _subCode(dynamic seq) => 'SUB-${(seq ?? 0).toString().padLeft(2, '0')}';

bool _expired(J l) {
  final d = parseDate(l['expires_at']);
  if (d == null) return false;
  final now = DateTime.now();
  return DateTime(d.year, d.month, d.day).isBefore(DateTime(now.year, now.month, now.day));
}

bool _live(J l) => l['active'] == true && !_expired(l);

class _Data {
  _Data(this.k, this.contractor, this.subs, this.links, this.tasks, this.gaps, this.reqs, this.types);
  final J k, contractor;
  final List<J> subs, links, tasks, gaps, reqs;
  final Map<String, J> types;

  String get contractNo => str(k['contract_no']);
  String get folderRoot => '$contractNo - ${str(contractor['legal_name'])}';

  J? liveLink({required String scope, String? sub, String? docType, String? task}) {
    for (final l in links) {
      if (!_live(l) || l['scope_type'] != scope) continue;
      if (scope == 'task' && l['task_id'] != task) continue;
      if (scope == 'subcontractor' && l['subcontractor_id'] != sub) continue;
      if (scope != 'task' && l['doc_type_code'] != docType) continue;
      return l;
    }
    return null;
  }
}

/// Link OneDrive per kontrak / fase / jenis dokumen / subkontraktor + daftar gap `link_coverage` (Part 7.4, R21).
class ContractOneDrivePage extends ConsumerStatefulWidget {
  const ContractOneDrivePage({super.key, required this.contractId});
  final String contractId;
  @override
  ConsumerState<ContractOneDrivePage> createState() => _ContractOneDrivePageState();
}

class _ContractOneDrivePageState extends ConsumerState<ContractOneDrivePage> {
  late Future<_Data> _future = _load();
  bool _showInactive = false;

  Future<_Data> _load() async {
    final api = ref.read(apiProvider);
    final id = widget.contractId;
    final k = await api.selectOne('contracts', 'id,contract_no,title,status,contractor_id', 'id', id);
    if (k == null) throw const AppFailure(Hint.forbidden, 'Kontrak tidak ditemukan atau Anda tidak memiliki akses.');
    final r = await Future.wait<dynamic>([
      api.selectOne('contractors', Cols.contractors, 'id', k['contractor_id'] as String),
      api.select('subcontractors', 'id,sub_seq,legal_name,status', build: (q) => q.eq('contract_id', id).order('sub_seq')),
      api.select('upload_links', _linkCols, build: (q) => q.eq('contract_id', id).order('updated_at', ascending: false)),
      api.select('v_task_tracking', 'id,task_id,title,doc_type_code,doc_label,status,phase,subcontractor_id,due_date',
          build: (q) => q.eq('contract_id', id).order('due_date').limit(1000)),
      api.rpcList('link_coverage', {'p_contract': id}),
      api.select('contract_requirements', 'doc_type_code,applicable,is_mandatory,is_mob_gate', build: (q) => q.eq('contract_id', id).eq('applicable', true)),
    ]);
    final tasks = r[3] as List<J>;
    final reqs = r[5] as List<J>;
    final taskIds = tasks.map((t) => t['id'] as String).toList();
    final more = await Future.wait<List<J>>([
      taskIds.isEmpty
          ? Future.value(<J>[])
          : api.select('upload_links', _linkCols, build: (q) => q.eq('scope_type', 'task').inFilter('task_id', taskIds).order('updated_at', ascending: false)),
      api.select('doc_type_catalog', 'code,label,phase,kind,sensitive,allowed_scopes', build: (q) => q.eq('active', true).order('code')),
    ]);
    return _Data(
      k,
      (r[0] as J?) ?? <String, dynamic>{},
      r[1] as List<J>,
      [...r[2] as List<J>, ...more[0]],
      tasks,
      r[4] as List<J>,
      reqs,
      {for (final t in more[1]) t['code'] as String: t},
    );
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _edit(_Data d, {J? link, required String scope, String? sub, String? docType, String? task, String? hint}) async {
    final r = await showDialog<J>(
      context: context,
      builder: (_) => _LinkDialog(
        contractId: widget.contractId,
        existing: link,
        scope: scope,
        subcontractorId: sub,
        docType: docType,
        taskId: task,
        types: d.types.values.where((t) => (t['allowed_scopes'] as List? ?? const []).contains(scope == 'subcontractor' ? 'subcontractor' : 'contract')).toList(),
        hint: hint,
      ),
    );
    if (r == null || !mounted) return;
    final warns = (r['warnings'] as List? ?? const []).cast<String>();
    if (warns.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: Brand.amber, size: 40),
          title: const Text('Link tersimpan dengan peringatan'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final w in warns) ...[InfoBanner(message: _warnLabel[w] ?? w, color: Brand.amber, icon: Icons.shield_outlined), const SizedBox(height: 8)],
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Mengerti'))],
        ),
      );
    }
    _reload();
  }

  Future<void> _deactivate(J l) async {
    final reason = await showReasonDialog(
      context,
      title: 'Nonaktifkan link?',
      message: 'Task yang memakai link ini akan jatuh ke link cakupan di atasnya, atau masuk daftar gap (reminder ditahan).',
      confirmLabel: 'Nonaktifkan',
      destructive: true,
    );
    if (reason == null || !mounted) return;
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('admin_deactivate_upload_link', {'p_id': l['id'], 'p_reason': reason}),
        success: 'Link dinonaktifkan');
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref);
    final manage = s?.can('upload_link.manage') ?? false;
    return AsyncView<_Data>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) {
        final live = d.links.where(_live).toList();
        return PageScaffold(
          title: 'OneDrive · ${d.contractNo}',
          subtitle: str(d.k['title']),
          leading: IconButton(
            tooltip: 'Kembali ke kontrak',
            onPressed: () => context.go('/contracts/${widget.contractId}?tab=onedrive'),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          actions: [
            FilterChip(
              selected: _showInactive,
              onSelected: (v) => setState(() => _showInactive = v),
              avatar: const Icon(Icons.history_rounded, size: 16),
              label: const Text('Tampilkan riwayat'),
            ),
            IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            HeroHeader(
              title: d.folderRoot,
              icon: Icons.cloud_rounded,
              lines: [
                'Upload dokumen kontraktor masuk ke OneDrive / SharePoint Weatherford — COMEN hanya menyimpan link.',
                if (!manage) 'Mode baca: Anda tidak memiliki izin upload_link.manage.',
              ],
              chips: [
                HeroChip('${live.length} link aktif', icon: Icons.link_rounded),
                HeroChip('${d.gaps.length} task tanpa link', icon: Icons.link_off_rounded),
                HeroChip('${d.subs.length} subkontraktor', icon: Icons.groups_2_rounded),
              ],
            ),
            const SizedBox(height: 16),
            if (d.gaps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: InfoBanner(
                  color: Brand.red,
                  icon: Icons.notifications_paused_rounded,
                  message: '${d.gaps.length} task dokumen/bukti terbuka belum punya link upload — reminder ke kontraktor ditahan sampai link tersedia (R21).',
                ),
              ),
            LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth >= 1100;
              final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _defaultsCard(d, manage),
                const SizedBox(height: 16),
                _docTypeCard(d, manage),
                const SizedBox(height: 16),
                _taskOverrideCard(d, manage),
                if (_showInactive) ...[const SizedBox(height: 16), _historyCard(d)],
              ]);
              final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _gapCard(d, manage),
                const SizedBox(height: 16),
                _folderCard(d),
                const SizedBox(height: 16),
                _securityCard(),
              ]);
              if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, const SizedBox(height: 16), right]);
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

  // ─────────── Default kontrak & subkontraktor ───────────
  Widget _defaultsCard(_Data d, bool manage) {
    final contractDefault = d.liveLink(scope: 'contract');
    return SectionCard(
      title: 'Link default',
      subtitle: 'Dipakai semua dokumen kontrak / subkontraktor yang tidak punya link spesifik',
      icon: Icons.folder_shared_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Slot(
          title: 'Kontrak ${d.contractNo}',
          subtitle: d.folderRoot,
          icon: Icons.description_rounded,
          link: contractDefault,
          manage: manage,
          onOpen: _open,
          onEdit: () => _edit(d, link: contractDefault, scope: 'contract', hint: d.folderRoot),
          onDeactivate: contractDefault == null ? null : () => _deactivate(contractDefault),
        ),
        for (final sub in d.subs.where((x) => x['status'] != 'removed' && x['status'] != 'rejected')) ...[
          const Divider(height: 24),
          Builder(builder: (_) {
            final l = d.liveLink(scope: 'subcontractor', sub: sub['id'] as String);
            final folder = '${_subCode(sub['sub_seq'])} - ${str(sub['legal_name'])}';
            return _Slot(
              title: folder,
              subtitle: 'Subkontraktor · ${StatusStyle.generic(sub['status'] as String?).$2}',
              icon: Icons.groups_2_rounded,
              link: l,
              inheritedFrom: l == null && contractDefault != null ? 'default kontrak' : null,
              manage: manage,
              onOpen: _open,
              onEdit: () => _edit(d, link: l, scope: 'subcontractor', sub: sub['id'] as String, hint: '${d.folderRoot}/$folder'),
              onDeactivate: l == null ? null : () => _deactivate(l),
            );
          }),
        ],
      ]),
    );
  }

  // ─────────── Per jenis dokumen (dikelompokkan per fase) ───────────
  Widget _docTypeCard(_Data d, bool manage) {
    final contractDefault = d.liveLink(scope: 'contract');
    final byPhase = <String, List<J>>{};
    for (final r in d.reqs) {
      final t = d.types[r['doc_type_code']];
      byPhase.putIfAbsent(t?['phase'] as String? ?? 'other', () => []).add(r);
    }
    final specific = d.links.where((l) => _live(l) && l['scope_type'] == 'contract' && l['doc_type_code'] != null).toList();
    final order = Labels.phase.keys.toList();
    int rank(String p) => order.contains(p) ? order.indexOf(p) : 99;
    final phases = byPhase.keys.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
    return SectionCard(
      title: 'Link per jenis dokumen',
      subtitle: 'Folder khusus per fase / jenis (mis. ${d.contractNo}/02-PRE-MOB/HSEPLN) — prioritas di atas link default',
      icon: Icons.account_tree_rounded,
      trailing: manage
          ? OutlinedButton.icon(
              onPressed: () => _edit(d, scope: 'contract', docType: '', hint: d.folderRoot),
              icon: const Icon(Icons.add_link_rounded, size: 18),
              label: const Text('Link jenis lain'),
            )
          : null,
      child: d.reqs.isEmpty && specific.isEmpty
          ? const EmptyState(icon: Icons.rule_folder_outlined, title: 'Belum ada kebutuhan dokumen', message: 'Kebutuhan dokumen dihitung saat kontrak dibuat / klasifikasi risiko berubah.')
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final p in phases) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Row(children: [
                    Text(Labels.phaseOf(p).toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.6, color: Brand.grey)),
                    const SizedBox(width: 8),
                    if (_phaseFolder[p] != null) MonoText('/${_phaseFolder[p]}', size: 11),
                  ]),
                ),
                for (final r in byPhase[p]!)
                  Builder(builder: (_) {
                    final code = r['doc_type_code'] as String;
                    final t = d.types[code];
                    final l = d.liveLink(scope: 'contract', docType: code);
                    return _DocTypeRow(
                      code: code,
                      label: str(t?['label'], code),
                      mandatory: r['is_mandatory'] == true,
                      gate: r['is_mob_gate'] == true,
                      sensitive: t?['sensitive'] == true,
                      link: l,
                      inherited: l == null ? contractDefault : null,
                      manage: manage,
                      onOpen: _open,
                      onEdit: () => _edit(d, link: l, scope: 'contract', docType: code, hint: '${d.folderRoot}/${_phaseFolder[p] ?? ''}/$code'),
                      onDeactivate: l == null ? null : () => _deactivate(l),
                    );
                  }),
              ],
              for (final l in specific.where((l) => !d.reqs.any((r) => r['doc_type_code'] == l['doc_type_code'])))
                _DocTypeRow(
                  code: l['doc_type_code'] as String,
                  label: str(d.types[l['doc_type_code']]?['label'], l['doc_type_code'] as String),
                  mandatory: false,
                  gate: false,
                  sensitive: d.types[l['doc_type_code']]?['sensitive'] == true,
                  link: l,
                  manage: manage,
                  onOpen: _open,
                  onEdit: () => _edit(d, link: l, scope: 'contract', docType: l['doc_type_code'] as String),
                  onDeactivate: () => _deactivate(l),
                ),
            ]),
    );
  }

  // ─────────── Override per task ───────────
  Widget _taskOverrideCard(_Data d, bool manage) {
    final overrides = d.links.where((l) => _live(l) && l['scope_type'] == 'task').toList();
    final taskById = {for (final t in d.tasks) t['id'] as String: t};
    return SectionCard(
      title: 'Override per task',
      subtitle: 'Link khusus satu task — prioritas tertinggi',
      icon: Icons.push_pin_rounded,
      child: overrides.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Tidak ada override. Atur dari daftar "Task tanpa link" bila perlu.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            )
          : Column(children: [
              for (final l in overrides)
                _LinkTile(
                  link: l,
                  title: '${str(taskById[l['task_id']]?['task_id'])} · ${str(taskById[l['task_id']]?['doc_label'] ?? taskById[l['task_id']]?['title'])}',
                  manage: manage,
                  onOpen: _open,
                  onEdit: () => _edit(d, link: l, scope: 'task', task: l['task_id'] as String),
                  onDeactivate: () => _deactivate(l),
                  onTitleTap: () => context.go('/tasks/${l['task_id']}'),
                ),
            ]),
    );
  }

  Widget _historyCard(_Data d) {
    final old = d.links.where((l) => !_live(l)).toList();
    return SectionCard(
      title: 'Riwayat link',
      subtitle: 'Link nonaktif / kedaluwarsa (tidak dipakai resolusi)',
      icon: Icons.history_rounded,
      child: old.isEmpty
          ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Belum ada riwayat.'))
          : Column(children: [
              for (final l in old)
                _LinkTile(
                  link: l,
                  title: switch (l['scope_type']) {
                    'subcontractor' => '${_subCode(d.subs.firstWhere((s) => s['id'] == l['subcontractor_id'], orElse: () => <String, dynamic>{})['sub_seq'])} ${l['doc_type_code'] ?? '(default)'}',
                    'task' => 'Task ${str(d.tasks.firstWhere((t) => t['id'] == l['task_id'], orElse: () => <String, dynamic>{})['task_id'])}',
                    _ => 'Kontrak ${l['doc_type_code'] ?? '(default)'}',
                  },
                  manage: false,
                  onOpen: _open,
                ),
            ]),
    );
  }

  // ─────────── Gap list (link_coverage) ───────────
  Widget _gapCard(_Data d, bool manage) => SectionCard(
        title: 'Task tanpa link',
        subtitle: 'link_coverage — task dokumen/bukti terbuka yang tidak ter-resolve ke link aktif',
        icon: Icons.link_off_rounded,
        trailing: StatusBadge(d.gaps.isEmpty ? Brand.green : Brand.red, '${d.gaps.length}'),
        child: d.gaps.isEmpty
            ? const EmptyState(icon: Icons.verified_rounded, title: 'Semua task tercakup', message: 'Setiap task dokumen/bukti terbuka punya link upload aktif.')
            : Column(children: [
                for (final g in d.gaps)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    onTap: () => context.go('/tasks/${g['task_uuid']}'),
                    leading: const Icon(Icons.link_off_rounded, color: Brand.red),
                    title: MonoText(str(g['task_id']), size: 12),
                    subtitle: Text(str(g['title']), maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(dueLabel(g['due_date']), style: TextStyle(color: dueColor(g['due_date']), fontWeight: FontWeight.w800, fontSize: 12)),
                      if (manage)
                        IconButton(
                          tooltip: 'Set link khusus task',
                          onPressed: () => _edit(d, scope: 'task', task: g['task_uuid'] as String),
                          icon: const Icon(Icons.add_link_rounded),
                        ),
                    ]),
                  ),
              ]),
      );

  // ─────────── Struktur folder rekomendasi ───────────
  Widget _folderCard(_Data d) {
    final subs = d.subs.where((x) => x['status'] != 'removed' && x['status'] != 'rejected').toList();
    final lines = <String>[
      'COMEN/',
      '└── ${d.folderRoot}/    ← link Kontrak',
      for (final f in const ['01-POST-AWARD', '02-PRE-MOB', '03-MOBILIZATION', '04-EXECUTION/EVIDENCE', '05-DEMOB', '06-OPR']) '    ├── $f/',
      for (var i = 0; i < subs.length; i++) '    ${i == subs.length - 1 ? '└' : '├'}── ${_subCode(subs[i]['sub_seq'])} - ${str(subs[i]['legal_name'])}/    ← link Subkontraktor',
    ];
    if (subs.isEmpty) lines[lines.length - 1] = lines.last.replaceFirst('├', '└');
    final tree = lines.join('\n');
    return SectionCard(
      title: 'Struktur folder rekomendasi',
      subtitle: 'Buat di SharePoint / OneDrive for Business',
      icon: Icons.folder_copy_rounded,
      trailing: CopyButton(tree, tooltip: 'Copy struktur'),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: MonoText(tree, size: 12)),
      ),
    );
  }

  Widget _securityCard() => SectionCard(
        title: 'Tipe link & keamanan',
        icon: Icons.shield_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: const [
          _Bullet(icon: Icons.upload_file_rounded, color: Brand.green, title: 'File Request (default)', text: 'Kontraktor hanya bisa upload — tidak bisa melihat / mengubah file lain. Wajib untuk dokumen sensitif.'),
          _Bullet(icon: Icons.folder_open_rounded, color: Brand.amber, title: 'Folder (edit)', text: 'Bagikan hanya ke email tertentu. Ada version history, tetapi kontraktor bisa melihat isi folder.'),
          _Bullet(icon: Icons.block_rounded, color: Brand.red, title: 'Hindari "Anyone with the link"', text: 'Siapa pun pemegang link bisa mengubah isi folder.'),
          _Bullet(icon: Icons.domain_verification_rounded, color: Brand.blue, title: 'Domain diterima', text: '1drv.ms · onedrive.live.com · <tenant>.sharepoint.com · <tenant>-my.sharepoint.com'),
        ]),
      );

  Future<void> _open(String url) async {
    await runAction<bool>(context, ref, () async {
      await UrlPolicy.open(url);
      return true;
    });
  }
}

// ─────────────────────────── Widgets ───────────────────────────
class _Bullet extends StatelessWidget {
  const _Bullet({required this.icon, required this.color, required this.title, required this.text});
  final IconData icon;
  final Color color;
  final String title, text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(text, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      );
}

class _LinkBadges extends StatelessWidget {
  const _LinkBadges(this.l);
  final J l;
  @override
  Widget build(BuildContext context) {
    final url = l['url'] as String? ?? '';
    final exp = parseDate(l['expires_at']);
    return Wrap(spacing: 6, runSpacing: 4, children: [
      StatusBadge(l['link_type'] == 'folder_edit' ? Brand.amber : Brand.green, _linkTypeLabel[l['link_type']] ?? str(l['link_type']),
          icon: l['link_type'] == 'folder_edit' ? Icons.folder_open_rounded : Icons.upload_file_rounded),
      if (l['active'] != true) const StatusBadge(Brand.grey, 'Nonaktif'),
      if (_expired(l)) const StatusBadge(Brand.red, 'Kedaluwarsa', icon: Icons.event_busy_rounded),
      if (!_expired(l) && exp != null && exp.difference(DateTime.now()).inDays <= 14)
        StatusBadge(Brand.amber, 'Exp ${fmtDate(l['expires_at'])}', icon: Icons.schedule_rounded),
      if (UrlPolicy.isPersonalOneDrive(url)) const StatusBadge(Brand.amber, 'OneDrive personal', icon: Icons.warning_amber_rounded),
    ]);
  }
}

class _LinkActions extends StatelessWidget {
  const _LinkActions({required this.link, required this.manage, required this.onOpen, this.onEdit, this.onDeactivate});
  final J link;
  final bool manage;
  final Future<void> Function(String url) onOpen;
  final VoidCallback? onEdit, onDeactivate;
  @override
  Widget build(BuildContext context) {
    final url = link['url'] as String? ?? '';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(tooltip: 'Buka di OneDrive', onPressed: url.isEmpty ? null : () => onOpen(url), icon: const Icon(Icons.open_in_new_rounded, size: 18)),
      CopyButton(url, tooltip: 'Copy link'),
      if (manage && onEdit != null) IconButton(tooltip: 'Ganti link', onPressed: onEdit, icon: const Icon(Icons.edit_rounded, size: 18)),
      if (manage && onDeactivate != null)
        IconButton(tooltip: 'Nonaktifkan', onPressed: onDeactivate, icon: const Icon(Icons.link_off_rounded, size: 18, color: Brand.red)),
    ]);
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.link, required this.title, required this.manage, required this.onOpen, this.onEdit, this.onDeactivate, this.onTitleTap});
  final J link;
  final String title;
  final bool manage;
  final Future<void> Function(String url) onOpen;
  final VoidCallback? onEdit, onDeactivate, onTitleTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(onTap: onTitleTap, child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
              if (link['label'] != null) Text(str(link['label']), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(str(link['url']), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Brand.grey)),
              const SizedBox(height: 6),
              _LinkBadges(link),
            ]),
          ),
          _LinkActions(link: link, manage: manage, onOpen: onOpen, onEdit: onEdit, onDeactivate: onDeactivate),
        ]),
      );
}

class _Slot extends StatelessWidget {
  const _Slot({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.link,
    required this.manage,
    required this.onOpen,
    required this.onEdit,
    this.onDeactivate,
    this.inheritedFrom,
  });
  final String title, subtitle;
  final IconData icon;
  final J? link;
  final bool manage;
  final Future<void> Function(String url) onOpen;
  final VoidCallback onEdit;
  final VoidCallback? onDeactivate;
  final String? inheritedFrom;

  @override
  Widget build(BuildContext context) {
    final l = link;
    final color = l != null ? Brand.green : (inheritedFrom != null ? Brand.blue : Brand.red);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: color),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          if (l != null) ...[
            if (l['label'] != null) Text(str(l['label']), style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(str(l['url']), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Brand.grey)),
            const SizedBox(height: 6),
            _LinkBadges(l),
          ] else
            StatusBadge(color, inheritedFrom != null ? 'Mewarisi $inheritedFrom' : 'Belum ada link', icon: inheritedFrom != null ? Icons.subdirectory_arrow_right_rounded : Icons.link_off_rounded),
        ]),
      ),
      if (l != null)
        _LinkActions(link: l, manage: manage, onOpen: onOpen, onEdit: onEdit, onDeactivate: onDeactivate)
      else if (manage)
        FilledButton.tonalIcon(onPressed: onEdit, icon: const Icon(Icons.add_link_rounded, size: 18), label: const Text('Set link')),
    ]);
  }
}

class _DocTypeRow extends StatelessWidget {
  const _DocTypeRow({
    required this.code,
    required this.label,
    required this.mandatory,
    required this.gate,
    required this.sensitive,
    required this.link,
    this.inherited,
    required this.manage,
    required this.onOpen,
    required this.onEdit,
    this.onDeactivate,
  });
  final String code, label;
  final bool mandatory, gate, sensitive, manage;
  final J? link, inherited;
  final Future<void> Function(String url) onOpen;
  final VoidCallback onEdit;
  final VoidCallback? onDeactivate;

  @override
  Widget build(BuildContext context) {
    final l = link;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(
          l != null ? Icons.link_rounded : (inherited != null ? Icons.subdirectory_arrow_right_rounded : Icons.link_off_rounded),
          size: 20,
          color: l != null ? Brand.green : (inherited != null ? Brand.blue : Brand.red),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              MonoText(code, size: 12),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (gate) const StatusBadge(Brand.red, 'Gate', icon: Icons.flag_rounded),
              if (!mandatory) const StatusBadge(Brand.grey, 'Opsional'),
              if (sensitive) const StatusBadge(Brand.purple, 'Sensitif', icon: Icons.lock_rounded),
            ]),
            const SizedBox(height: 2),
            if (l != null)
              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (l['label'] != null) Text(str(l['label']), style: Theme.of(context).textTheme.bodySmall),
                _LinkBadges(l),
              ])
            else
              Text(
                inherited != null ? 'Memakai link default kontrak' : 'Tidak ada link — task jenis ini masuk gap',
                style: TextStyle(fontSize: 12, color: inherited != null ? Brand.grey : Brand.red),
              ),
            if (l == null && sensitive && inherited?['link_type'] == 'folder_edit')
              const Text('Default kontrak berupa Folder (edit) — disarankan File Request khusus untuk dokumen sensitif.', style: TextStyle(fontSize: 12, color: Brand.amber)),
          ]),
        ),
        if (l != null)
          _LinkActions(link: l, manage: manage, onOpen: onOpen, onEdit: onEdit, onDeactivate: onDeactivate)
        else if (manage)
          TextButton.icon(onPressed: onEdit, icon: const Icon(Icons.add_link_rounded, size: 18), label: const Text('Link khusus')),
      ]),
    );
  }
}

// ─────────────────────────── Dialog tambah / ganti link ───────────────────────────
final _urlRe = RegExp(r'^https://(1drv\.ms|onedrive\.live\.com|[a-z0-9-]+(-my)?\.sharepoint\.com)/[^\s<>"]*$', caseSensitive: false);

class _LinkDialog extends ConsumerStatefulWidget {
  const _LinkDialog({
    required this.contractId,
    required this.existing,
    required this.scope,
    this.subcontractorId,
    this.docType,
    this.taskId,
    required this.types,
    this.hint,
  });
  final String contractId, scope;
  final J? existing;
  final String? subcontractorId, docType, taskId, hint;
  final List<J> types;
  @override
  ConsumerState<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends ConsumerState<_LinkDialog> {
  late final _url = TextEditingController(text: widget.existing?['url'] as String?);
  late final _label = TextEditingController(text: widget.existing?['label'] as String? ?? widget.hint);
  final _reason = TextEditingController();
  late String _type = widget.existing?['link_type'] as String? ?? 'file_request';
  late String? _docType = widget.existing?['doc_type_code'] as String? ?? ((widget.docType?.isEmpty ?? true) ? null : widget.docType);
  late DateTime? _expires = parseDate(widget.existing?['expires_at']);
  bool _busy = false;

  bool get _editing => widget.existing != null;
  bool get _pickDocType => !_editing && widget.scope != 'task' && widget.docType == '';

  Future<void> _submit() async {
    setState(() => _busy = true);
    final r = await runAction<J>(
      context,
      ref,
      () => ref.read(apiProvider).rpcMap('admin_upsert_upload_link', {
        'p_id': widget.existing?['id'],
        'p_scope_type': widget.scope,
        'p_contractor': null,
        'p_contract': widget.scope == 'task' ? null : widget.contractId,
        'p_subcontractor': widget.subcontractorId,
        'p_task': widget.taskId,
        'p_doc_type': widget.scope == 'task' ? null : _docType,
        'p_url': _url.text.trim(),
        'p_link_type': _type,
        'p_label': trimOrNull(_label),
        'p_expires_at': _expires == null ? null : isoDate(_expires!),
        'p_reason': _reason.text.trim(),
      }),
      success: _editing ? 'Link diperbarui' : 'Link disimpan',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) Navigator.pop(context, r);
  }

  @override
  Widget build(BuildContext context) {
    final url = _url.text.trim();
    final urlOk = _urlRe.hasMatch(url);
    final sensitive = widget.types.any((t) => t['code'] == _docType && t['sensitive'] == true);
    final ok = !_busy && urlOk && _reason.text.trim().length >= 5 && (!_pickDocType || _docType != null);
    final scopeLabel = switch (widget.scope) {
      'subcontractor' => _docType == null ? 'Subkontraktor · default' : 'Subkontraktor · $_docType',
      'task' => 'Override task',
      _ => _docType == null ? 'Kontrak · default' : 'Kontrak · $_docType',
    };
    return AlertDialog(
      icon: const Icon(Icons.add_link_rounded, color: Brand.blue, size: 36),
      title: Text(_editing ? 'Ganti link OneDrive' : 'Set link OneDrive'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(alignment: Alignment.centerLeft, child: StatusBadge(Brand.blue, scopeLabel, icon: Icons.layers_rounded)),
            const SizedBox(height: 14),
            if (_pickDocType) ...[
              DropdownButtonFormField<String>(
                initialValue: _docType,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Jenis dokumen *', prefixIcon: Icon(Icons.category_outlined)),
                items: [
                  for (final t in widget.types)
                    DropdownMenuItem(value: t['code'] as String, child: Text('${t['code']} · ${t['label']}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _docType = v),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _url,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'URL OneDrive / SharePoint *',
                prefixIcon: const Icon(Icons.link_rounded),
                hintText: 'https://weatherford.sharepoint.com/…',
                errorText: url.isNotEmpty && !urlOk ? 'Harus https://…sharepoint.com / 1drv.ms / onedrive.live.com' : null,
                helperText: urlOk && UrlPolicy.isPersonalOneDrive(url) ? 'OneDrive personal — disarankan SharePoint tenant' : null,
              ),
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'file_request', icon: Icon(Icons.upload_file_rounded), label: Text('File Request')),
                ButtonSegment(value: 'folder_edit', icon: Icon(Icons.folder_open_rounded), label: Text('Folder (edit)')),
              ],
              selected: {_type},
              onSelectionChanged: (v) => setState(() => _type = v.first),
            ),
            if (_type == 'folder_edit' && (sensitive || _docType == null)) ...[
              const SizedBox(height: 10),
              InfoBanner(message: _warnLabel['folder_edit_sensitive']!, color: Brand.amber, icon: Icons.shield_outlined),
            ],
            const SizedBox(height: 14),
            TextField(controller: _label, maxLength: 200, decoration: const InputDecoration(labelText: 'Label / nama folder', prefixIcon: Icon(Icons.label_outline_rounded))),
            DateField(
              label: 'Kedaluwarsa (opsional)',
              value: _expires,
              onTap: () async {
                final d = await pickDate(context, initial: _expires ?? DateTime.now().add(const Duration(days: 180)), first: DateTime.now(), last: DateTime.now().add(const Duration(days: 1825)));
                if (d != null) setState(() => _expires = d);
              },
              onClear: () => setState(() => _expires = null),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _reason,
              maxLines: 2,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Alasan *', helperText: 'Minimal 5 karakter · tercatat di audit log'),
            ),
            if (!_editing) ...[
              const SizedBox(height: 10),
              Text('Link aktif lain pada cakupan yang sama otomatis dinonaktifkan.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.grey)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: ok ? _submit : null,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_rounded),
          label: const Text('Simpan link'),
        ),
      ],
    );
  }
}
