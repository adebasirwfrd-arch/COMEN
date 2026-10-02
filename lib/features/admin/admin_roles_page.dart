import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

class _RolesData {
  _RolesData(this.roles, this.perms, this.rolePerms, this.userCounts);
  final List<J> roles;
  final List<J> perms;
  final Map<String, Set<String>> rolePerms;
  final Map<String, int>? userCounts;
}

class AdminRolesPage extends ConsumerStatefulWidget {
  const AdminRolesPage({super.key});
  @override
  ConsumerState<AdminRolesPage> createState() => _AdminRolesPageState();
}

class _AdminRolesPageState extends ConsumerState<AdminRolesPage> {
  late Future<_RolesData> _future = _load();
  String _view = 'editor';
  String? _roleId;
  Set<String>? _draft;
  String _q = '';

  Future<_RolesData> _load() async {
    final api = ref.read(apiProvider);
    final r = await Future.wait([
      api.select('roles', 'id,key,name,description,is_system,is_wfrd,created_at,updated_at', build: (q) => q.order('is_system', ascending: false).order('name')),
      api.select('permissions', 'key,module,description,risk_level,audience', build: (q) => q.order('module').order('key')),
      api.select('role_permissions', 'role_id,permission_key'),
    ]);
    Map<String, int>? counts;
    try {
      final ur = await api.select('user_roles', 'role_id');
      counts = {};
      for (final x in ur) {
        counts.update(x['role_id'] as String, (v) => v + 1, ifAbsent: () => 1);
      }
    } catch (_) {}
    final rp = <String, Set<String>>{};
    for (final x in r[2]) {
      rp.putIfAbsent(x['role_id'] as String, () => <String>{}).add(x['permission_key'] as String);
    }
    return _RolesData(r[0], r[1], rp, counts);
  }

  void _reload() {
    ref.invalidate(adminLookupsProvider);
    setState(() {
      _draft = null;
      _future = _load();
    });
  }

  Future<void> _editRole(J? role) async {
    final res = await showDialog<_RoleForm>(context: context, builder: (_) => _RoleDialog(role: role));
    if (res == null || !mounted) return;
    final id = await runActionId(() => ref.read(apiProvider).rpc('admin_upsert_role', {
          'p_id': role?['id'],
          'p_key': res.key,
          'p_name': res.name,
          'p_description': res.description,
          'p_is_wfrd': res.isWfrd,
          'p_reason': res.reason,
        }), role == null ? 'Role dibuat' : 'Role diperbarui');
    if (id != null) {
      _roleId = id;
      _reload();
    }
  }

  Future<String?> runActionId(Future<dynamic> Function() fn, String success) async {
    String? id;
    final ok = await adminRun(context, ref, () async => id = (await fn())?.toString(), success: success);
    return ok ? id : null;
  }

  Future<void> _clone(J role, Set<String> perms) async {
    final res = await showDialog<_RoleForm>(context: context, builder: (_) => _RoleDialog(cloneOf: role));
    if (res == null || !mounted) return;
    final api = ref.read(apiProvider);
    final id = await runActionId(
        () => api.rpc('admin_upsert_role', {'p_id': null, 'p_key': res.key, 'p_name': res.name, 'p_description': res.description, 'p_is_wfrd': res.isWfrd, 'p_reason': res.reason}),
        'Role dibuat');
    if (id == null || !mounted) return;
    if (perms.isNotEmpty) {
      await adminRun(context, ref, () => api.rpc('admin_set_role_permissions', {'p_role': id, 'p_permissions': perms.where((p) => p != '*').toList(), 'p_reason': res.reason}),
          success: 'Permission disalin dari ${role['name']}');
    }
    _roleId = id;
    _reload();
  }

  Future<void> _delete(J role) async {
    final ok = await withReason(context, ref,
        title: 'Hapus role ${role['name']}',
        message: 'Role kustom yang masih dipakai user/undangan/katalog tidak bisa dihapus.',
        confirmLabel: 'Hapus',
        destructive: true,
        success: 'Role dihapus',
        action: (r) => ref.read(apiProvider).rpc('admin_delete_role', {'p_role': role['id'], 'p_reason': r}));
    if (ok) {
      _roleId = null;
      _reload();
    }
  }

  Future<void> _save(J role, Set<String> draft) async {
    final api = ref.read(apiProvider);
    final perms = draft.where((p) => p != '*').toList()..sort();
    final preview = await runAction<J>(context, ref, () => api.rpcMap('admin_preview_role_change', {'p_role': role['id'], 'p_permissions': perms}));
    if (preview == null || !mounted) return;
    final reason = await showDialog<String>(context: context, builder: (_) => _PreviewDialog(role: role, preview: preview));
    if (reason == null || !mounted) return;
    final ok = await adminRun(context, ref, () => api.rpc('admin_set_role_permissions', {'p_role': role['id'], 'p_permissions': perms, 'p_reason': reason}), success: 'Permission role disimpan');
    if (ok) {
      ref.read(sessionProvider.notifier).refresh();
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    final canManage = s?.can('admin.roles.manage') ?? false;
    return AdminScaffold(
      title: 'Roles & Permissions',
      subtitle: 'Matriks permission per role · perubahan critical butuh MFA ≤ 12 jam',
      actions: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'editor', label: Text('Per role'), icon: Icon(Icons.tune_rounded, size: 18)),
            ButtonSegment(value: 'matrix', label: Text('Matriks'), icon: Icon(Icons.grid_on_rounded, size: 18)),
          ],
          selected: {_view},
          onSelectionChanged: (v) => setState(() => _view = v.first),
        ),
        if (canManage) FilledButton.icon(onPressed: () => _editRole(null), icon: const Icon(Icons.add_rounded), label: const Text('Role kustom')),
        OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang')),
      ],
      child: AsyncView<_RolesData>(
        future: _future,
        onRetry: _reload,
        builder: (context, d) {
          if (_view == 'matrix') return _Matrix(data: d);
          final role = d.roles.where((r) => r['id'] == _roleId).firstOrNull ?? d.roles.firstOrNull;
          if (role == null) return const SectionCard(child: EmptyState(icon: Icons.key_off_rounded, title: 'Belum ada role'));
          final current = d.rolePerms[role['id']] ?? const <String>{};
          final draft = (_roleId == role['id'] ? _draft : null) ?? current;
          final locked = role['key'] == 'super_admin' || !canManage;
          final dirty = !_setEq(draft, current);
          final list = _RoleList(
            roles: d.roles,
            selectedId: role['id'] as String,
            counts: d.userCounts,
            rolePerms: d.rolePerms,
            onSelect: (id) => setState(() {
              _roleId = id;
              _draft = null;
            }),
          );
          final editor = _RoleEditor(
            role: role,
            perms: d.perms,
            draft: draft,
            dirty: dirty,
            locked: locked,
            canManage: canManage,
            userCount: d.userCounts?[role['id']],
            query: _q,
            onQuery: (v) => setState(() => _q = v),
            onToggle: (k, v) => setState(() {
              _roleId = role['id'] as String;
              _draft = {...draft};
              v ? _draft!.add(k) : _draft!.remove(k);
            }),
            onReset: () => setState(() => _draft = null),
            onSave: () => _save(role, draft),
            onEdit: () => _editRole(role),
            onClone: () => _clone(role, current),
            onDelete: () => _delete(role),
          );
          return LayoutBuilder(builder: (context, c) {
            if (c.maxWidth < 900) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [list, const SizedBox(height: 16), editor]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 300, child: list), const SizedBox(width: 16), Expanded(child: editor)]);
          });
        },
      ),
    );
  }
}

bool _setEq(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

class _RoleList extends StatelessWidget {
  const _RoleList({required this.roles, required this.selectedId, required this.counts, required this.rolePerms, required this.onSelect});
  final List<J> roles;
  final String selectedId;
  final Map<String, int>? counts;
  final Map<String, Set<String>> rolePerms;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => SectionCard(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final r in roles)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: r['id'] == selectedId ? Brand.blue.withValues(alpha: 0.1) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onSelect(r['id'] as String),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(children: [
                      Icon(r['key'] == 'super_admin' ? Icons.shield_rounded : (r['is_wfrd'] == true ? Icons.badge_outlined : Icons.engineering_outlined),
                          size: 20, color: r['key'] == 'super_admin' ? Brand.red : (r['is_wfrd'] == true ? Brand.navy : Brand.cyan)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(str(r['name']), style: TextStyle(fontWeight: r['id'] == selectedId ? FontWeight.w800 : FontWeight.w600)),
                          Text(
                            '${r['key']} · ${(rolePerms[r['id']] ?? const {}).contains('*') ? 'semua' : (rolePerms[r['id']] ?? const {}).length} perm${counts == null ? '' : ' · ${counts![r['id']] ?? 0} user'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ]),
                      ),
                      if (r['is_system'] != true) const StatusBadge(Brand.purple, 'Kustom'),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}

class _RoleEditor extends StatelessWidget {
  const _RoleEditor({
    required this.role,
    required this.perms,
    required this.draft,
    required this.dirty,
    required this.locked,
    required this.canManage,
    required this.userCount,
    required this.query,
    required this.onQuery,
    required this.onToggle,
    required this.onReset,
    required this.onSave,
    required this.onEdit,
    required this.onClone,
    required this.onDelete,
  });
  final J role;
  final List<J> perms;
  final Set<String> draft;
  final bool dirty, locked, canManage;
  final int? userCount;
  final String query;
  final ValueChanged<String> onQuery;
  final void Function(String key, bool on) onToggle;
  final VoidCallback onReset, onSave, onEdit, onClone, onDelete;

  bool _audienceOk(J p) {
    final wfrd = role['is_wfrd'] == true;
    return p['audience'] == 'any' || (wfrd ? p['audience'] == 'wfrd' : p['audience'] == 'contractor');
  }

  @override
  Widget build(BuildContext context) {
    final isSuper = role['key'] == 'super_admin';
    final all = draft.contains('*');
    final q = query.toLowerCase();
    final visible = perms.where((p) => p['key'] != '*' && (q.isEmpty || '${p['key']} ${p['description']} ${p['module']}'.toLowerCase().contains(q))).toList();
    final modules = <String, List<J>>{};
    for (final p in visible) {
      modules.putIfAbsent(p['module'] as String, () => []).add(p);
    }
    return SectionCard(
      title: str(role['name']),
      subtitle: [str(role['key']), if (role['description'] != null) str(role['description'])].join(' · '),
      icon: Icons.key_rounded,
      trailing: canManage && !isSuper
          ? PopupMenuButton<String>(
              tooltip: 'Aksi role',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) => switch (v) { 'edit' => onEdit(), 'clone' => onClone(), _ => onDelete() },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Ubah nama/deskripsi'))),
                const PopupMenuItem(value: 'clone', child: ListTile(leading: Icon(Icons.copy_all_rounded), title: Text('Clone role'))),
                if (role['is_system'] != true) const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline_rounded, color: Brand.red), title: Text('Hapus role'))),
              ],
            )
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          role['is_wfrd'] == true ? const StatusBadge(Brand.navy, 'Role WFRD', icon: Icons.badge_outlined) : const StatusBadge(Brand.cyan, 'Role contractor', icon: Icons.engineering_outlined),
          role['is_system'] == true ? const StatusBadge(Brand.grey, 'Sistem', icon: Icons.lock_outline_rounded) : const StatusBadge(Brand.purple, 'Kustom'),
          if (userCount != null) StatusBadge(Brand.blue, '$userCount user', icon: Icons.people_alt_outlined),
          StatusBadge(Brand.green, all ? 'Semua permission (*)' : '${draft.length} permission', icon: Icons.check_circle_outline_rounded),
        ]),
        const SizedBox(height: 12),
        if (isSuper)
          const InfoBanner(message: 'super_admin terkunci (permission *) — hanya untuk email allowlist via migration.', color: Brand.red, icon: Icons.shield_rounded)
        else if (!canManage)
          const PermissionNote('admin.roles.manage', what: 'mengubah permission role'),
        if (dirty) ...[
          const SizedBox(height: 12),
          InfoBanner(
            message: 'Ada perubahan belum disimpan.',
            color: Brand.amber,
            icon: Icons.edit_note_rounded,
            action: Wrap(spacing: 8, children: [
              TextButton(onPressed: onReset, child: const Text('Batalkan')),
              FilledButton.icon(onPressed: onSave, icon: const Icon(Icons.preview_rounded, size: 18), label: const Text('Preview & simpan')),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        AdminSearchField(hint: 'Cari permission', onChanged: onQuery),
        const SizedBox(height: 8),
        if (visible.isEmpty) const EmptyState(icon: Icons.search_off_rounded, title: 'Tidak ada permission cocok'),
        for (final m in modules.entries) ...[
          GroupLabel(m.key),
          for (final p in m.value)
            Builder(builder: (context) {
              final on = all || draft.contains(p['key']);
              final audOk = _audienceOk(p);
              final enabled = !locked && audOk;
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: on,
                onChanged: enabled ? (v) => onToggle(p['key'] as String, v ?? false) : null,
                title: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  MonoText(str(p['key']), size: 12),
                  RiskBadge(p['risk_level'] as String?),
                  AudienceBadge(p['audience'] as String?),
                  if (!audOk) const StatusBadge(Brand.grey, 'Audience tidak cocok', icon: Icons.block_rounded),
                ]),
                subtitle: Text(str(p['description'])),
              );
            }),
        ],
      ]),
    );
  }
}

class _Matrix extends StatelessWidget {
  const _Matrix({required this.data});
  final _RolesData data;
  @override
  Widget build(BuildContext context) {
    final perms = data.perms.where((p) => p['key'] != '*').toList();
    return SectionCard(
      title: 'Matriks permission',
      subtitle: 'Baris = permission · kolom = role (read-only; ubah lewat tampilan "Per role")',
      icon: Icons.grid_on_rounded,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 64,
          dataRowMinHeight: 36,
          dataRowMaxHeight: 44,
          columnSpacing: 18,
          columns: [
            const DataColumn(label: Text('Permission')),
            const DataColumn(label: Text('Risk')),
            for (final r in data.roles)
              DataColumn(
                label: Tooltip(
                  message: '${r['name']} (${r['key']})',
                  child: SizedBox(width: 72, child: Text(str(r['name']), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12))),
                ),
              ),
          ],
          rows: [
            for (final p in perms)
              DataRow(cells: [
                DataCell(MonoText(str(p['key']), size: 12)),
                DataCell(RiskBadge(p['risk_level'] as String?)),
                for (final r in data.roles)
                  DataCell(Center(
                    child: Builder(builder: (_) {
                      final rp = data.rolePerms[r['id']] ?? const <String>{};
                      final star = rp.contains('*') && p['audience'] != 'contractor';
                      if (star) return const Icon(Icons.check_circle_rounded, size: 18, color: Brand.red);
                      return rp.contains(p['key'])
                          ? const Icon(Icons.check_circle_rounded, size: 18, color: Brand.green)
                          : Icon(Icons.remove_rounded, size: 16, color: Theme.of(context).dividerColor);
                    }),
                  )),
              ]),
          ],
        ),
      ),
    );
  }
}

class _RoleForm {
  _RoleForm(this.key, this.name, this.description, this.isWfrd, this.reason);
  final String key, name, reason;
  final String? description;
  final bool isWfrd;
}

class _RoleDialog extends StatefulWidget {
  const _RoleDialog({this.role, this.cloneOf});
  final J? role;
  final J? cloneOf;
  @override
  State<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<_RoleDialog> {
  late final _key = TextEditingController(text: widget.role?['key'] as String? ?? (widget.cloneOf == null ? '' : '${widget.cloneOf!['key']}_copy'));
  late final _name = TextEditingController(text: widget.role?['name'] as String? ?? (widget.cloneOf == null ? '' : '${widget.cloneOf!['name']} (salinan)'));
  late final _desc = TextEditingController(text: (widget.role ?? widget.cloneOf)?['description'] as String? ?? '');
  late bool _wfrd = (widget.role ?? widget.cloneOf)?['is_wfrd'] as bool? ?? true;
  final _reason = TextEditingController();

  bool get _isNew => widget.role == null;
  bool get _keyOk => !_isNew || RegExp(r'^[a-z_]{3,40}$').hasMatch(_key.text.trim());
  bool get _ok => _keyOk && _name.text.trim().isNotEmpty && _reason.text.trim().length >= 5;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.cloneOf != null ? 'Clone role ${widget.cloneOf!['name']}' : (_isNew ? 'Role kustom baru' : 'Ubah role')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: _key,
                enabled: _isNew,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'Key *', helperText: 'huruf kecil & underscore, 3–40 · tidak bisa diubah', errorText: _key.text.isEmpty || _keyOk ? null : 'Format key tidak valid'),
              ),
              const SizedBox(height: 12),
              TextField(controller: _name, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Nama *')),
              const SizedBox(height: 12),
              TextField(controller: _desc, maxLines: 2, decoration: const InputDecoration(labelText: 'Deskripsi')),
              const SizedBox(height: 12),
              LabeledSwitch(
                label: 'Role WFRD',
                subtitle: _wfrd ? 'Untuk staf Weatherford' : 'Untuk user contractor',
                value: _wfrd,
                onChanged: widget.role?['is_system'] == true ? (_) {} : (v) => setState(() => _wfrd = v),
              ),
              const SizedBox(height: 8),
              ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(
            onPressed: _ok
                ? () => Navigator.pop(context, _RoleForm(_key.text.trim(), _name.text.trim(), _desc.text.trim().isEmpty ? null : _desc.text.trim(), _wfrd, _reason.text.trim()))
                : null,
            child: const Text('Simpan'),
          ),
        ],
      );
}

class _PreviewDialog extends StatefulWidget {
  const _PreviewDialog({required this.role, required this.preview});
  final J role;
  final J preview;
  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  final _reason = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    final added = (p['added'] as List? ?? const []).cast<dynamic>();
    final removed = (p['removed'] as List? ?? const []).cast<dynamic>();
    final invalid = (p['invalid_audience'] as List? ?? const []).cast<dynamic>();
    final users = jl(p['affected_users']);
    final ok = invalid.isEmpty && _reason.text.trim().length >= 5 && (added.isNotEmpty || removed.isNotEmpty);
    return AlertDialog(
      title: Text('Preview perubahan · ${widget.role['name']}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            if (p['has_critical'] == true) ...[
              const InfoBanner(message: 'Perubahan menyentuh permission CRITICAL — butuh verifikasi MFA (step-up).', color: Brand.red, icon: Icons.gpp_maybe_rounded),
              const SizedBox(height: 12),
            ],
            if (invalid.isNotEmpty) ...[
              InfoBanner(message: 'Audience tidak cocok: ${invalid.join(', ')}', color: Brand.red, icon: Icons.block_rounded),
              const SizedBox(height: 12),
            ],
            const GroupLabel('Ditambah', color: Brand.green),
            if (added.isEmpty) const Text('-') else Wrap(spacing: 6, runSpacing: 6, children: [for (final a in added) StatusBadge(Brand.green, '+ $a')]),
            const SizedBox(height: 8),
            const GroupLabel('Dihapus', color: Brand.red),
            if (removed.isEmpty) const Text('-') else Wrap(spacing: 6, runSpacing: 6, children: [for (final a in removed) StatusBadge(Brand.red, '− $a')]),
            const SizedBox(height: 8),
            GroupLabel('User terdampak (${p['affected_count'] ?? 0})', color: Brand.grey),
            if (users.isEmpty)
              const Text('Tidak ada user')
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: ListView(shrinkWrap: true, children: [
                  for (final u in users) ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Avatar(name: u['name'] as String?, radius: 14), title: Text(str(u['name'])), subtitle: Text(str(u['email']))),
                ]),
              ),
            const SizedBox(height: 12),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(onPressed: ok ? () => Navigator.pop(context, _reason.text.trim()) : null, icon: const Icon(Icons.save_rounded), label: const Text('Simpan')),
      ],
    );
  }
}
