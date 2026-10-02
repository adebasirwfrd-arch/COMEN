import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/security/disposable_domains.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

const _statusFilters = <(String?, String)>[
  (null, 'Semua'),
  ('active', 'Active'),
  ('pending', 'Pending'),
  ('suspended', 'Suspended'),
  ('deactivated', 'Deactivated'),
  ('rejected', 'Rejected'),
];

String _domainOf(String? email) {
  final e = email ?? '';
  final at = e.lastIndexOf('@');
  return at < 0 ? '-' : e.substring(at + 1);
}

Widget _providerBadge(dynamic p) => switch (p) {
      'google' => const StatusBadge(Brand.blue, 'Google', icon: Icons.g_mobiledata_rounded),
      'email' => const StatusBadge(Brand.grey, 'Email OTP', icon: Icons.mail_outline_rounded),
      null => const StatusBadge(Brand.grey, '-'),
      _ => StatusBadge(Brand.purple, p.toString(), icon: Icons.login_rounded),
    };

Widget _mfaBadge(dynamic on) => on == true
    ? const StatusBadge(Brand.green, 'MFA', icon: Icons.verified_user_rounded)
    : const StatusBadge(Brand.grey, 'Tanpa MFA', icon: Icons.no_encryption_gmailerrorred_rounded);

// ═══════════════════════════ User Approval ═══════════════════════════
class AdminApprovalsPage extends ConsumerStatefulWidget {
  const AdminApprovalsPage({super.key});
  @override
  ConsumerState<AdminApprovalsPage> createState() => _AdminApprovalsPageState();
}

class _AdminApprovalsPageState extends ConsumerState<AdminApprovalsPage> {
  late Future<List<J>> _future = _load();
  String _q = '';
  final Set<String> _selected = {};

  Future<List<J>> _load() async => jl(await ref.read(apiProvider).rpc('admin_list_users', {'p_status': 'pending', 'p_limit': 200, 'p_offset': 0}));
  void _reload() => setState(() {
        _selected.clear();
        _future = _load();
      });

  Future<void> _approve(List<J> users) async {
    final lookups = await ref.read(adminLookupsProvider.future);
    if (!mounted) return;
    final single = users.length == 1 ? users.first : null;
    final g = await showRoleGrantDialog(
      context,
      title: single == null ? 'Bulk approve ${users.length} user' : 'Approve ${str(single['full_name'])}',
      mode: RoleGrantMode.approve,
      lookups: lookups,
      session: sessionOf(ref),
      subject: single == null ? 'Role & scope yang sama diberikan ke ${users.length} user terpilih.' : '${single['email']}${single['contractor_name'] != null ? ' · draft: ${single['contractor_name']}' : ''}',
      presetContractorId: single?['contractor_id'] as String?,
    );
    if (g == null || !mounted) return;
    var ok = 0;
    for (final u in users) {
      if (!mounted) return;
      final r = await adminRun(context, ref, () => ref.read(apiProvider).rpc('admin_approve_user', {
            'p_user': u['id'],
            'p_role_key': g.roleKey,
            'p_scope_type': g.scopeType,
            'p_scope_id': g.scopeId,
            'p_contractor': g.contractorId,
            'p_expires_at': g.expiresIso,
            'p_reason': g.reason,
          }));
      if (r) ok++;
    }
    if (mounted && ok > 0) showSnack(context, ok == 1 ? 'User disetujui' : '$ok user disetujui');
    _reload();
  }

  Future<void> _reject(J u) async {
    final ok = await withReason(context, ref,
        title: 'Tolak ${str(u['full_name'])}',
        message: 'Akun ${u['email']} akan ditolak dan menerima email pemberitahuan berisi alasan.',
        confirmLabel: 'Tolak',
        destructive: true,
        success: 'User ditolak',
        action: (r) => ref.read(apiProvider).rpc('admin_reject_user', {'p_user': u['id'], 'p_reason': r}));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final disposable = ref.watch(disposableDomainsProvider).valueOrNull ?? const <String>{};
    return AdminScaffold(
      title: 'User Approval',
      subtitle: 'Antrean akun baru · periksa risk hint sebelum memberi role',
      actions: [
        if (_selected.isNotEmpty)
          FilledButton.icon(
            onPressed: () async {
              final all = await _future;
              await _approve(all.where((u) => _selected.contains(u['id'])).toList());
            },
            icon: const Icon(Icons.done_all_rounded),
            label: Text('Bulk approve (${_selected.length})'),
          ),
        OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang')),
      ],
      child: AsyncView<List<J>>(
        future: _future,
        onRetry: _reload,
        builder: (context, all) {
          final q = _q.toLowerCase();
          final list = all.where((u) => q.isEmpty || '${u['email']} ${u['full_name']} ${u['contractor_name'] ?? ''}'.toLowerCase().contains(q)).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              AdminSearchField(hint: 'Cari nama / email / perusahaan', onChanged: (v) => setState(() => _q = v)),
              StatusBadge(all.isEmpty ? Brand.green : Brand.amber, '${all.length} pending', icon: Icons.hourglass_top_rounded),
              if (list.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() {
                    final ids = list.map((u) => u['id'] as String).toSet();
                    if (_selected.containsAll(ids)) {
                      _selected.removeAll(ids);
                    } else {
                      _selected.addAll(ids);
                    }
                  }),
                  icon: const Icon(Icons.select_all_rounded),
                  label: const Text('Pilih semua'),
                ),
            ]),
            const SizedBox(height: 16),
            if (all.isEmpty)
              const SectionCard(child: EmptyState(icon: Icons.verified_rounded, title: 'Antrean kosong', message: 'Tidak ada akun yang menunggu approval.'))
            else if (list.isEmpty)
              const SectionCard(child: EmptyState(icon: Icons.search_off_rounded, title: 'Tidak ada yang cocok'))
            else
              ResponsiveGrid(minItemWidth: 420, children: [
                for (final u in list)
                  _PendingCard(
                    user: u,
                    disposable: isDisposableEmail(disposable, str(u['email'], '')),
                    selected: _selected.contains(u['id']),
                    onSelect: (v) => setState(() => v ? _selected.add(u['id'] as String) : _selected.remove(u['id'])),
                    onApprove: () => _approve([u]),
                    onReject: () => _reject(u),
                  ),
              ]),
          ]);
        },
      ),
    );
  }
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.user, required this.disposable, required this.selected, required this.onSelect, required this.onApprove, required this.onReject});
  final J user;
  final bool disposable, selected;
  final ValueChanged<bool> onSelect;
  final VoidCallback onApprove, onReject;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final sameDomain = (user['same_domain_pending'] as num?)?.toInt() ?? 0;
    final email = str(user['email'], '');
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? Brand.blue : (disposable ? Brand.red.withValues(alpha: 0.5) : Theme.of(context).dividerColor), width: selected ? 1.6 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Avatar(name: user['full_name'] as String?, url: user['avatar_url'] as String?, radius: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(str(user['full_name']), style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                SelectableText(email, style: t.bodySmall),
                const SizedBox(height: 2),
                Text('Daftar ${fmtRelative(user['created_at'])} · ${fmtDateTime(user['created_at'])}', style: t.bodySmall?.copyWith(color: Brand.grey)),
              ]),
            ),
            Checkbox(value: selected, onChanged: (v) => onSelect(v ?? false)),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _providerBadge(user['provider']),
            StatusBadge(Brand.grey, '@${_domainOf(email)}', icon: Icons.domain_rounded),
            StatusBadge(Brand.grey, '${user['devices'] ?? 0} perangkat', icon: Icons.devices_rounded),
            _mfaBadge(user['mfa_enrolled']),
          ]),
          const SizedBox(height: 10),
          const GroupLabel('Risk hint', color: Brand.grey),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (disposable) const StatusBadge(Brand.red, 'Domain disposable', icon: Icons.report_rounded),
            if (sameDomain > 1) StatusBadge(Brand.amber, '$sameDomain pending dari domain sama', icon: Icons.warning_amber_rounded),
            if (user['domain_matches_contractor'] == true) const StatusBadge(Brand.green, 'Domain cocok contractor terdaftar', icon: Icons.verified_rounded),
            if (!disposable && sameDomain <= 1 && user['domain_matches_contractor'] != true) const StatusBadge(Brand.grey, 'Tidak ada sinyal khusus'),
          ]),
          if (user['contractor_name'] != null) ...[
            const SizedBox(height: 10),
            InfoBanner(
              message: 'Draft registrasi: ${user['contractor_name']} (${StatusStyle.vendor(user['vendor_status'] as String?).$2})',
              icon: Icons.apartment_rounded,
              color: Brand.cyan,
            ),
          ],
          const SizedBox(height: 14),
          Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
            TextButton.icon(
              onPressed: email.isEmpty ? null : () => launchUrl(Uri(scheme: 'mailto', path: email, query: 'subject=COMEN%20-%20Informasi%20pendaftaran')),
              icon: const Icon(Icons.forward_to_inbox_rounded, size: 18),
              label: const Text('Minta info'),
            ),
            OutlinedButton.icon(
              onPressed: onReject,
              style: OutlinedButton.styleFrom(foregroundColor: Brand.red),
              icon: const Icon(Icons.block_rounded, size: 18),
              label: const Text('Tolak'),
            ),
            FilledButton.icon(onPressed: onApprove, icon: const Icon(Icons.how_to_reg_rounded, size: 18), label: const Text('Approve…')),
          ]),
        ]),
      ),
    );
  }
}

// ═══════════════════════════ Users & Access ═══════════════════════════
class AdminUsersPage extends ConsumerStatefulWidget {
  const AdminUsersPage({super.key});
  @override
  ConsumerState<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends ConsumerState<AdminUsersPage> {
  static const _limit = 25;
  String? _status;
  String _q = '';
  String? _contractor;
  int _offset = 0;
  late Future<List<J>> _future = _load();

  Future<List<J>> _load() async => jl(await ref.read(apiProvider).rpc('admin_list_users', {
        'p_status': _status,
        'p_search': _q.isEmpty ? null : _q,
        'p_contractor': _contractor,
        'p_limit': _limit,
        'p_offset': _offset,
      }));

  void _reload({bool resetPage = false}) => setState(() {
        if (resetPage) _offset = 0;
        _future = _load();
      });

  @override
  Widget build(BuildContext context) {
    final lookups = ref.watch(adminLookupsProvider).valueOrNull;
    return AdminScaffold(
      title: 'Users & Access',
      subtitle: 'Semua akun, role, dan status akses',
      actions: [OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang'))],
      child: TableCard(
        toolbar: [
          AdminSearchField(hint: 'Cari nama / email', onChanged: (v) {
            _q = v;
            _reload(resetPage: true);
          }),
          if (lookups != null && lookups.contractors.isNotEmpty)
            SizedBox(
              width: 280,
              child: LookupPicker(
                label: 'Filter contractor',
                icon: Icons.apartment_rounded,
                value: _contractor,
                items: [('', 'Semua'), for (final c in lookups.contractors) (c['id'] as String, str(c['legal_name']))],
                onChanged: (v) {
                  _contractor = (v == null || v.isEmpty) ? null : v;
                  _reload(resetPage: true);
                },
              ),
            ),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (v, l) in _statusFilters)
              ChoiceChip(
                label: Text(l),
                selected: _status == v,
                onSelected: (_) {
                  _status = v;
                  _reload(resetPage: true);
                },
              ),
          ]),
        ],
        child: AsyncView<List<J>>(
          future: _future,
          onRetry: _reload,
          builder: (context, list) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DataList(
              empty: 'Tidak ada user cocok',
              columns: const ['User', 'Status', 'Tipe', 'Role', 'MFA', 'Perangkat', 'Login terakhir', 'Terdaftar'],
              onTap: (i) => context.go('/admin/users/${list[i]['id']}'),
              rows: [
                for (final u in list)
                  [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Avatar(name: u['full_name'] as String?, url: u['avatar_url'] as String?, radius: 16),
                      const SizedBox(width: 10),
                      CellText(str(u['full_name']), subtitle: str(u['email'])),
                      if (u['is_root_admin'] == true) ...[const SizedBox(width: 6), const Icon(Icons.shield_rounded, size: 16, color: Brand.red)],
                    ]),
                    StatusBadge.account(u['status'] as String?),
                    u['contractor_id'] == null ? const StatusBadge(Brand.navy, 'WFRD', icon: Icons.badge_outlined) : CellText(str(u['contractor_name']), subtitle: 'Contractor', maxWidth: 200),
                    _RoleChips(roles: jl(u['roles']), lookups: lookups),
                    _mfaBadge(u['mfa_enrolled']),
                    Text('${u['devices'] ?? 0}'),
                    Text(fmtRelative(u['last_login_at'])),
                    Text(fmtDate(u['created_at'])),
                  ],
              ],
            ),
            const SizedBox(height: 8),
            PagerBar(offset: _offset, limit: _limit, count: list.length, onPage: (o) {
              _offset = o;
              _reload();
            }),
          ]),
        ),
      ),
    );
  }
}

class _RoleChips extends StatelessWidget {
  const _RoleChips({required this.roles, required this.lookups});
  final List<J> roles;
  final AdminLookups? lookups;
  @override
  Widget build(BuildContext context) {
    if (roles.isEmpty) return const Text('-');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Wrap(spacing: 4, runSpacing: 4, children: [
        for (final r in roles.take(3))
          StatusBadge(r['expires_at'] != null ? Brand.amber : Brand.blue, '${str(lookups?.roleByKey(r['role'] as String?)?['name'] ?? r['role'])}${r['scope_type'] != 'global' ? ' · ${r['scope_type']}' : ''}'),
        if (roles.length > 3) StatusBadge(Brand.grey, '+${roles.length - 3}'),
      ]),
    );
  }
}

// ═══════════════════════════ User detail ═══════════════════════════
class _UserData {
  _UserData({required this.profile, required this.row, required this.roles, required this.perms, required this.devices, required this.events});
  final J? profile;
  final J? row;
  final List<J> roles;
  final List<J>? perms;
  final List<J>? devices;
  final List<J>? events;
}

class AdminUserDetailPage extends ConsumerStatefulWidget {
  const AdminUserDetailPage({super.key, required this.userId});
  final String userId;
  @override
  ConsumerState<AdminUserDetailPage> createState() => _AdminUserDetailPageState();
}

class _AdminUserDetailPageState extends ConsumerState<AdminUserDetailPage> {
  late Future<_UserData> _future = _load();
  bool? _authSynced;

  @override
  void didUpdateWidget(covariant AdminUserDetailPage old) {
    super.didUpdateWidget(old);
    if (old.userId != widget.userId) _reload();
  }

  Future<T?> _try<T>(Future<T> f) async {
    try {
      return await f;
    } catch (_) {
      return null;
    }
  }

  Future<_UserData> _load() async {
    final api = ref.read(apiProvider);
    final id = widget.userId;
    final profile = await api.selectOne('profiles', Cols.profiles, 'id', id);
    if (profile == null) return _UserData(profile: null, row: null, roles: const [], perms: null, devices: null, events: null);
    final canSec = sessionOf(ref)?.can('admin.security.manage') ?? false;
    final r = await Future.wait<dynamic>([
      _try(api.rpc('admin_list_users', {'p_search': profile['email'], 'p_limit': 10, 'p_offset': 0})),
      api.select('user_roles', 'id,user_id,role_id,scope_type,scope_id,granted_by,granted_at,expires_at,reason', build: (q) => q.eq('user_id', id).order('granted_at')),
      _try(api.rpcList('admin_user_effective_permissions', {'p_user': id})),
      _try(api.select('trusted_devices', Cols.trustedDevices, build: (q) => q.eq('user_id', id).order('last_seen', ascending: false))),
      canSec ? _try(api.select('security_events', 'id,event,severity,detail,handled_at,handle_note,created_at', build: (q) => q.eq('user_id', id).order('created_at', ascending: false).limit(50))) : Future.value(null),
    ]);
    final rows = r[0] == null ? const <J>[] : jl(r[0]);
    return _UserData(
      profile: profile,
      row: rows.where((x) => x['id'] == id).firstOrNull,
      roles: r[1] as List<J>,
      perms: r[2] as List<J>?,
      devices: r[3] as List<J>?,
      events: r[4] as List<J>?,
    );
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _edge(String action, String reason, String success) async {
    final r = await runAction<J>(context, ref, () => ref.read(apiProvider).edge('admin-actions', {'action': action, 'user_id': widget.userId, 'reason': reason}), success: success);
    if (r == null || !mounted) return;
    setState(() => _authSynced = r['auth_synced'] as bool?);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    return AsyncView<_UserData>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) {
        final p = d.profile;
        if (p == null) {
          return AdminScaffold(
            title: 'User tidak ditemukan',
            child: EmptyState(
              icon: Icons.person_off_rounded,
              title: 'User tidak ditemukan',
              action: FilledButton.tonal(onPressed: () => context.go('/admin/users'), child: const Text('Kembali ke daftar')),
            ),
          );
        }
        final status = p['status'] as String;
        final isRoot = p['is_root_admin'] == true;
        final isSelf = s?.userId == widget.userId;
        final anonymized = p['anonymized_at'] != null;
        final locked = isRoot || isSelf || anonymized;
        final canSuspend = (s?.can('admin.users.suspend') ?? false) && !locked;
        final canEdit = (s?.can('admin.users.edit') ?? false) && !isSelf && !anonymized;
        final canRevoke = (s?.can('admin.sessions.revoke') ?? false) && !isRoot && !anonymized;
        return AdminScaffold(
          title: str(p['full_name']),
          subtitle: str(p['email']),
          actions: [
            OutlinedButton.icon(onPressed: () => context.go('/admin/users'), icon: const Icon(Icons.arrow_back_rounded), label: const Text('Daftar user')),
            if (canRevoke && !isSelf)
              OutlinedButton.icon(
                onPressed: () async {
                  final ok = await withReason(context, ref,
                      title: 'Force logout semua perangkat',
                      message: 'Semua sesi ${p['email']} ditolak; user harus login ulang.',
                      confirmLabel: 'Force logout',
                      destructive: true,
                      success: 'Sesi user dicabut',
                      action: (r) => ref.read(apiProvider).rpc('admin_force_logout', {'p_user': widget.userId, 'p_reason': r}));
                  if (ok) _reload();
                },
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Force logout'),
              ),
            if (canSuspend) _StatusMenu(status: status, onAction: _edge),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_authSynced == false) ...[
              InfoBanner(
                message: 'Status tersimpan, sinkron Auth gagal.',
                color: Brand.amber,
                icon: Icons.sync_problem_rounded,
                action: TextButton(
                  onPressed: () async {
                    final r = await showReasonDialog(context, title: 'Sinkronkan ulang Auth', message: status == 'active' ? 'Unban identitas Auth user.' : 'Ban identitas Auth user.');
                    if (r != null && context.mounted) await _edge(status == 'active' ? 'unban' : 'ban', r, 'Auth disinkronkan');
                  },
                  child: const Text('Sinkronkan ulang'),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (anonymized) ...[
              InfoBanner(message: 'Akun dianonimkan ${fmtDateTime(p['anonymized_at'])} — tidak bisa diubah.', color: Brand.grey, icon: Icons.person_off_rounded),
              const SizedBox(height: 16),
            ] else if (isRoot) ...[
              const InfoBanner(message: 'Root admin (allowlist migration) — status & role terkunci.', color: Brand.red, icon: Icons.shield_rounded),
              const SizedBox(height: 16),
            ] else if (status == 'pending') ...[
              InfoBanner(
                message: 'Akun masih pending — gunakan User Approval.',
                color: Brand.amber,
                icon: Icons.hourglass_top_rounded,
                action: TextButton(onPressed: () => context.go('/admin/approvals'), child: const Text('Buka')),
              ),
              const SizedBox(height: 16),
            ],
            _ProfileCard(profile: p, row: d.row, canResetMfa: canSuspend || (s?.can('admin.users.suspend') == true && isSelf), onResetMfa: () async {
              final r = await showReasonDialog(context,
                  title: 'Reset MFA',
                  message: 'Semua faktor TOTP user dihapus dan sesinya dicabut. Aksi critical — membutuhkan verifikasi MFA Anda (step-up).',
                  confirmLabel: 'Reset MFA',
                  destructive: true);
              if (r != null && context.mounted) await _edge('reset_mfa', r, 'MFA direset');
            }),
            const SizedBox(height: 16),
            _ContractorCard(profile: p, canEdit: canEdit && !(p['contractor_id'] == null && status == 'active'), onChanged: _reload),
            const SizedBox(height: 16),
            _RolesCard(userId: widget.userId, profile: p, roles: d.roles, canEdit: canEdit && status == 'active', onChanged: _reload),
            const SizedBox(height: 16),
            _EffectivePermsCard(perms: d.perms),
            const SizedBox(height: 16),
            _DevicesCard(devices: d.devices, canRevoke: canRevoke, onChanged: _reload),
            if (d.events != null) ...[
              const SizedBox(height: 16),
              _EventsCard(events: d.events!),
            ],
          ]),
        );
      },
    );
  }
}

class _StatusMenu extends StatelessWidget {
  const _StatusMenu({required this.status, required this.onAction});
  final String status;
  final Future<void> Function(String action, String reason, String success) onAction;

  @override
  Widget build(BuildContext context) {
    final items = <PopupMenuEntry<String>>[
      if (status == 'active') ...[
        const PopupMenuItem(value: 'suspend', child: ListTile(leading: Icon(Icons.pause_circle_outline_rounded, color: Brand.red), title: Text('Suspend + ban'))),
        const PopupMenuItem(value: 'deactivate', child: ListTile(leading: Icon(Icons.person_off_outlined), title: Text('Nonaktifkan (deactivate)'))),
      ],
      if (status == 'suspended' || status == 'deactivated')
        const PopupMenuItem(value: 'reactivate', child: ListTile(leading: Icon(Icons.play_circle_outline_rounded, color: Brand.green), title: Text('Aktifkan kembali + unban'))),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'Ubah status',
      itemBuilder: (_) => items,
      onSelected: (v) async {
        final (title, msg, label, ok) = switch (v) {
          'suspend' => ('Suspend user', 'Akun ditangguhkan, semua sesi dicabut, dan identitas Auth di-ban.', 'Suspend', 'User disuspend'),
          'deactivate' => ('Nonaktifkan user', 'Akun dinonaktifkan permanen (dapat diaktifkan kembali).', 'Nonaktifkan', 'User dinonaktifkan'),
          _ => ('Aktifkan kembali', 'Akun aktif kembali dan identitas Auth di-unban.', 'Aktifkan', 'User diaktifkan'),
        };
        final r = await showReasonDialog(context, title: title, message: msg, confirmLabel: label, destructive: v != 'reactivate');
        if (r != null && context.mounted) await onAction(v, r, ok);
      },
      child: IgnorePointer(
        child: FilledButton.icon(
          onPressed: () {},
          style: FilledButton.styleFrom(backgroundColor: status == 'active' ? Brand.red : Brand.green),
          icon: Icon(status == 'active' ? Icons.gpp_bad_rounded : Icons.gpp_good_rounded),
          label: const Text('Status akun'),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.row, required this.canResetMfa, required this.onResetMfa});
  final J profile;
  final J? row;
  final bool canResetMfa;
  final VoidCallback onResetMfa;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Avatar(name: p['full_name'] as String?, url: p['avatar_url'] as String?, radius: 30),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(str(p['full_name']), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                StatusBadge.account(p['status'] as String?),
                if (p['is_root_admin'] == true) const StatusBadge(Brand.red, 'Root admin', icon: Icons.shield_rounded),
                p['contractor_id'] == null ? const StatusBadge(Brand.navy, 'WFRD', icon: Icons.badge_outlined) : const StatusBadge(Brand.cyan, 'Contractor', icon: Icons.engineering_outlined),
                if (row != null) _mfaBadge(row!['mfa_enrolled']),
                if (row != null) _providerBadge(row!['provider']),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Flexible(child: SelectableText(str(p['email']))),
                CopyButton(str(p['email']), tooltip: 'Copy email'),
              ]),
            ]),
          ),
        ]),
        if (p['status_reason'] != null) ...[
          const SizedBox(height: 12),
          InfoBanner(message: 'Alasan status: ${p['status_reason']}', color: Brand.amber, icon: Icons.sticky_note_2_outlined),
        ],
        const SizedBox(height: 16),
        KeyValueGrid(minItemWidth: 200, [
          ('User ID', Row(children: [Flexible(child: MonoText(shortId(p['id']), size: 12)), CopyButton(str(p['id']), tooltip: 'Copy ID')])),
          ('Jabatan', Text(str(p['job_title']))),
          ('Geozone', Text(str(p['geozone']))),
          ('Bahasa', Text(str(p['locale']).toUpperCase())),
          ('Terdaftar', Text(fmtDateTime(p['created_at']))),
          ('Disetujui', Text(fmtDateTime(p['approved_at']))),
          ('Login terakhir', Text(fmtDateTime(p['last_login_at']))),
          ('Privacy disetujui', Text(fmtDateTime(p['privacy_accepted_at']))),
          if (row != null) ('Perangkat aktif', Text('${row!['devices'] ?? 0}')),
        ]),
        if (canResetMfa && row?['mfa_enrolled'] == true) ...[
          const Divider(height: 32),
          Row(children: [
            const Icon(Icons.phonelink_lock_rounded, color: Brand.grey),
            const SizedBox(width: 12),
            const Expanded(child: Text('MFA terdaftar. Reset bila user kehilangan authenticator (critical + step-up).')),
            OutlinedButton.icon(
              onPressed: onResetMfa,
              style: OutlinedButton.styleFrom(foregroundColor: Brand.red),
              icon: const Icon(Icons.lock_reset_rounded, size: 18),
              label: const Text('Reset MFA'),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _ContractorCard extends ConsumerWidget {
  const _ContractorCard({required this.profile, required this.canEdit, required this.onChanged});
  final J profile;
  final bool canEdit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cid = profile['contractor_id'] as String?;
    final lookups = ref.watch(adminLookupsProvider).valueOrNull;
    return SectionCard(
      title: 'Perusahaan',
      icon: Icons.apartment_rounded,
      trailing: canEdit
          ? OutlinedButton.icon(
              onPressed: lookups == null
                  ? null
                  : () async {
                      final r = await showDialog<(String, String)>(context: context, builder: (_) => _SetContractorDialog(lookups: lookups, current: cid));
                      if (r == null || !context.mounted) return;
                      final ok = await adminRun(context, ref,
                          () => ref.read(apiProvider).rpc('admin_set_user_contractor', {'p_user': profile['id'], 'p_contractor': r.$1, 'p_reason': r.$2}),
                          success: 'Contractor diperbarui');
                      if (ok) onChanged();
                    },
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: Text(cid == null ? 'Set contractor' : 'Ganti contractor'),
            )
          : null,
      child: cid == null
          ? const Text('User WFRD (tidak terhubung ke contractor).')
          : Row(children: [
              Expanded(child: CellText(lookups?.contractorName(cid) ?? shortId(cid), subtitle: 'Contractor ID ${shortId(cid)}', maxWidth: 600)),
              TextButton.icon(onPressed: () => context.go('/vendors/$cid'), icon: const Icon(Icons.open_in_new_rounded, size: 16), label: const Text('Buka vendor')),
            ]),
    );
  }
}

class _SetContractorDialog extends StatefulWidget {
  const _SetContractorDialog({required this.lookups, this.current});
  final AdminLookups lookups;
  final String? current;
  @override
  State<_SetContractorDialog> createState() => _SetContractorDialogState();
}

class _SetContractorDialogState extends State<_SetContractorDialog> {
  late String? _c = widget.current;
  final _reason = TextEditingController();
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Set contractor'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            LookupPicker(
              label: 'Contractor *',
              icon: Icons.apartment_rounded,
              value: _c,
              items: [for (final c in widget.lookups.contractors) (c['id'] as String, str(c['legal_name']))],
              onChanged: (v) => setState(() => _c = v),
            ),
            const SizedBox(height: 12),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(
            onPressed: _c != null && _c != widget.current && _reason.text.trim().length >= 5 ? () => Navigator.pop(context, (_c!, _reason.text.trim())) : null,
            child: const Text('Simpan'),
          ),
        ],
      );
}

class _RolesCard extends ConsumerWidget {
  const _RolesCard({required this.userId, required this.profile, required this.roles, required this.canEdit, required this.onChanged});
  final String userId;
  final J profile;
  final List<J> roles;
  final bool canEdit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookups = ref.watch(adminLookupsProvider).valueOrNull;
    return SectionCard(
      title: 'Role & scope',
      subtitle: 'Role sementara berwarna kuning (punya tanggal kedaluwarsa)',
      icon: Icons.key_rounded,
      trailing: canEdit
          ? FilledButton.tonalIcon(
              onPressed: lookups == null
                  ? null
                  : () async {
                      final g = await showRoleGrantDialog(context,
                          title: 'Berikan role',
                          mode: RoleGrantMode.grant,
                          lookups: lookups,
                          session: sessionOf(ref),
                          subject: '${profile['full_name']} · ${profile['email']}',
                          onlyWfrd: profile['contractor_id'] == null);
                      if (g == null || !context.mounted) return;
                      final ok = await adminRun(
                          context,
                          ref,
                          () => ref.read(apiProvider).rpc('admin_grant_role', {
                                'p_user': userId,
                                'p_role_key': g.roleKey,
                                'p_scope_type': g.scopeType,
                                'p_scope_id': g.scopeId,
                                'p_expires_at': g.expiresIso,
                                'p_reason': g.reason,
                              }),
                          success: 'Role diberikan');
                      if (ok) {
                        onChanged();
                        if (sessionOf(ref)?.userId == userId) ref.read(sessionProvider.notifier).refresh();
                      }
                    },
              icon: const Icon(Icons.add_moderator_rounded, size: 18),
              label: const Text('Tambah role'),
            )
          : null,
      child: roles.isEmpty
          ? const EmptyState(icon: Icons.key_off_rounded, title: 'Belum ada role')
          : Column(children: [
              for (final r in roles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: (r['expires_at'] != null ? Brand.amber : Brand.blue).withValues(alpha: 0.12),
                    child: Icon(Icons.key_rounded, color: r['expires_at'] != null ? Brand.amber : Brand.blue, size: 18),
                  ),
                  title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(lookups?.roleName(r['role_id'] as String?) ?? shortId(r['role_id']), style: const TextStyle(fontWeight: FontWeight.w700)),
                    StatusBadge(Brand.grey, lookups?.scopeLabel(r['scope_type'] as String?, r['scope_id'] as String?) ?? str(r['scope_type']), icon: Icons.my_location_rounded),
                    if (r['expires_at'] != null) StatusBadge(Brand.amber, 's/d ${fmtDate(r['expires_at'])}', icon: Icons.timer_outlined),
                  ]),
                  subtitle: Text('Diberikan ${fmtDateTime(r['granted_at'])} · ${str(r['reason'])}'),
                  trailing: canEdit
                      ? IconButton(
                          tooltip: 'Cabut role',
                          icon: const Icon(Icons.remove_circle_outline_rounded, color: Brand.red),
                          onPressed: () async {
                            final ok = await withReason(context, ref,
                                title: 'Cabut role ${lookups?.roleName(r['role_id'] as String?) ?? ''}',
                                message: 'User akan diberi tahu. Akses yang bergantung pada role ini langsung hilang.',
                                confirmLabel: 'Cabut',
                                destructive: true,
                                success: 'Role dicabut',
                                action: (reason) => ref.read(apiProvider).rpc('admin_revoke_role', {'p_user_role': r['id'], 'p_reason': reason}));
                            if (ok) onChanged();
                          },
                        )
                      : null,
                ),
            ]),
    );
  }
}

class _EffectivePermsCard extends StatefulWidget {
  const _EffectivePermsCard({required this.perms});
  final List<J>? perms;
  @override
  State<_EffectivePermsCard> createState() => _EffectivePermsCardState();
}

class _EffectivePermsCardState extends State<_EffectivePermsCard> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final all = widget.perms;
    final list = all == null ? const <J>[] : all.where((p) => _q.isEmpty || '${p['permission_key']} ${p['role_key']}'.toLowerCase().contains(_q.toLowerCase())).toList();
    return TableCard(
      title: 'Effective permissions',
      subtitle: '"Kenapa user ini bisa X?" — permission beserta role & scope sumbernya',
      icon: Icons.rule_rounded,
      count: all == null ? null : list.length,
      toolbar: all == null ? const [] : [AdminSearchField(hint: 'Cari permission / role', onChanged: (v) => setState(() => _q = v))],
      child: all == null
          ? const InfoBanner(message: 'Tidak dapat memuat effective permissions.', color: Brand.grey)
          : DataList(
              empty: 'Tidak ada permission',
              columns: const ['Permission', 'Risk', 'Audience', 'Dari role', 'Scope', 'Kedaluwarsa'],
              rows: [
                for (final p in list)
                  [
                    MonoText(str(p['permission_key']), size: 12),
                    RiskBadge(p['risk_level'] as String?),
                    AudienceBadge(p['audience'] as String?),
                    Text(str(p['role_key'])),
                    Text(p['scope_type'] == 'global' ? 'Global' : '${p['scope_type']} ${shortId(p['scope_id'])}'),
                    Text(fmtDate(p['expires_at'])),
                  ],
              ],
            ),
    );
  }
}

class _DevicesCard extends ConsumerWidget {
  const _DevicesCard({required this.devices, required this.canRevoke, required this.onChanged});
  final List<J>? devices;
  final bool canRevoke;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = devices;
    return TableCard(
      title: 'Perangkat',
      subtitle: 'Perangkat terpercaya — mencabut perangkat menolak semua request darinya seketika',
      icon: Icons.devices_rounded,
      count: d?.length,
      child: d == null
          ? const PermissionNote('admin.security.manage / admin.sessions.revoke', what: 'melihat perangkat user')
          : DataList(
              empty: 'Belum ada perangkat',
              columns: const ['Perangkat', 'Pertama terlihat', 'Terakhir aktif', 'Status', ''],
              rows: [
                for (final x in d)
                  [
                    CellText(str(x['label'], 'Perangkat tanpa nama'), subtitle: shortId(x['id'])),
                    Text(fmtDateTime(x['first_seen'])),
                    Text(fmtRelative(x['last_seen'])),
                    x['revoked_at'] == null
                        ? const StatusBadge(Brand.green, 'Aktif')
                        : Tooltip(message: str(x['revoke_reason']), child: StatusBadge(Brand.red, 'Dicabut ${fmtDate(x['revoked_at'])}')),
                    x['revoked_at'] == null && canRevoke
                        ? TextButton.icon(
                            style: TextButton.styleFrom(foregroundColor: Brand.red),
                            onPressed: () async {
                              final ok = await withReason(context, ref,
                                  title: 'Cabut perangkat',
                                  message: 'Perangkat "${str(x['label'], 'tanpa nama')}" tidak bisa dipakai lagi; user harus login ulang di perangkat baru.',
                                  confirmLabel: 'Cabut',
                                  destructive: true,
                                  success: 'Perangkat dicabut',
                                  action: (r) => ref.read(apiProvider).rpc('admin_revoke_device', {'p_device': x['id'], 'p_reason': r}));
                              if (ok) onChanged();
                            },
                            icon: const Icon(Icons.phonelink_erase_rounded, size: 18),
                            label: const Text('Cabut'),
                          )
                        : const SizedBox.shrink(),
                  ],
              ],
            ),
    );
  }
}

class _EventsCard extends StatelessWidget {
  const _EventsCard({required this.events});
  final List<J> events;
  @override
  Widget build(BuildContext context) => TableCard(
        title: 'Riwayat keamanan',
        subtitle: '50 security event terakhir untuk user ini',
        icon: Icons.history_rounded,
        count: events.length,
        child: DataList(
          empty: 'Belum ada event',
          columns: const ['Waktu', 'Event', 'Severity', 'Detail', 'Ditangani'],
          rows: [
            for (final e in events)
              [
                Text(fmtDateTime(e['created_at'])),
                MonoText(str(e['event']), size: 12),
                StatusBadge.generic(e['severity'] as String?),
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: Text(e['detail'] == null ? '-' : jm(e['detail']).entries.map((x) => '${x.key}: ${x.value}').join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis)),
                e['handled_at'] == null ? const Text('-') : Tooltip(message: str(e['handle_note']), child: Text(fmtDate(e['handled_at']))),
              ],
          ],
        ),
      );
}
