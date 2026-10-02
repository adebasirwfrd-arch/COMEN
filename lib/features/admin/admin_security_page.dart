import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_settings_page.dart' show editSetting, settingPreview;
import 'admin_widgets.dart';

const securityEventCols = 'id,user_id,event,severity,detail,handled_at,handled_by,handle_note,created_at';

const _eventLabels = <String, String>{
  'login': 'Login',
  'new_device': 'Perangkat baru',
  'device_revoked': 'Perangkat dicabut',
  'force_logout': 'Force logout',
  'role_changed': 'Role berubah',
  'user_status': 'Status akun',
  'export': 'Export data',
  'anomaly': 'Anomali',
  'settings_changed': 'Setting berubah',
  'danger_zone': 'Danger Zone',
  'audit_anchor': 'Audit anchor',
  'chat_admin': 'Chat admin',
  'chat_moderation': 'Moderasi chat',
  'retention': 'Retensi',
  'anonymized': 'Anonimisasi',
};

String eventLabel(String? e) => _eventLabels[e] ?? (e ?? '-');

(Color, String) severityStyle(String? s) => switch (s) {
      'critical' => (Brand.red, 'Critical'),
      'warning' => (Brand.amber, 'Warning'),
      _ => (Brand.blue, 'Info'),
    };

String eventSummary(J e) {
  final d = jm(e['detail']);
  if (e['event'] == 'anomaly' && d['type'] != null) {
    return switch (d['type']) {
      'rate_limit_saturated' => 'Rate limit jenuh${d['bucket'] != null ? ' · ${d['bucket']}' : ''}',
      'many_new_devices' => 'Banyak perangkat baru${d['count'] != null ? ' (${d['count']})' : ''}',
      'signup_burst' => 'Lonjakan pendaftaran${d['count'] != null ? ' (${d['count']})' : ''}',
      _ => '${d['type']}',
    };
  }
  for (final k in const ['key', 'reason', 'kind', 'status', 'role', 'type']) {
    if (d[k] != null) return '$k: ${d[k] is Map || d[k] is List ? settingPreview(d[k]) : d[k]}';
  }
  return d.isEmpty ? '-' : d.keys.take(4).join(', ');
}

class AdminSecurityPage extends ConsumerStatefulWidget {
  const AdminSecurityPage({super.key});
  @override
  ConsumerState<AdminSecurityPage> createState() => _AdminSecurityPageState();
}

class _AdminSecurityPageState extends ConsumerState<AdminSecurityPage> {
  String _tab = 'alerts';
  int _rev = 0;

  @override
  Widget build(BuildContext context) {
    return AdminScaffold(
      title: 'Security Center',
      subtitle: 'Alert keamanan, jejak event, perangkat tepercaya, dan kebijakan MFA / rate limit',
      actions: [OutlinedButton.icon(onPressed: () => setState(() => _rev++), icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang'))],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'alerts', label: Text('Alert'), icon: Icon(Icons.notification_important_outlined, size: 18)),
              ButtonSegment(value: 'events', label: Text('Semua event'), icon: Icon(Icons.list_alt_rounded, size: 18)),
              ButtonSegment(value: 'devices', label: Text('Perangkat'), icon: Icon(Icons.devices_rounded, size: 18)),
              ButtonSegment(value: 'policy', label: Text('Kebijakan'), icon: Icon(Icons.policy_outlined, size: 18)),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
        ),
        const SizedBox(height: 16),
        switch (_tab) {
          'events' => _EventsView(key: ValueKey('events$_rev'), alertsOnly: false),
          'devices' => _DevicesView(key: ValueKey('devices$_rev')),
          'policy' => _PolicyView(key: ValueKey('policy$_rev')),
          _ => _EventsView(key: ValueKey('alerts$_rev'), alertsOnly: true),
        },
      ]),
    );
  }
}

// ─────────────────────────── Events / Alerts ───────────────────────────
class _EventsView extends ConsumerStatefulWidget {
  const _EventsView({super.key, required this.alertsOnly});
  final bool alertsOnly;
  @override
  ConsumerState<_EventsView> createState() => _EventsViewState();
}

class _EventsViewState extends ConsumerState<_EventsView> {
  String? _severity;
  String? _event;
  String _handled = 'all';
  String _q = '';
  final _selected = <int>{};
  late Future<(List<J>, Map<String, J>)> _future = _load();

  Future<(List<J>, Map<String, J>)> _load() async {
    final rows = await ref.read(apiProvider).select('security_events', securityEventCols, build: (q) {
      var f = q;
      if (widget.alertsOnly) {
        f = f.isFilter('handled_at', null).neq('severity', 'info');
      } else {
        if (_severity != null) f = f.eq('severity', _severity!);
        if (_event != null) f = f.eq('event', _event!);
        if (_handled == 'open') f = f.isFilter('handled_at', null);
        if (_handled == 'done') f = f.not('handled_at', 'is', null);
      }
      return f.order('created_at', ascending: false).limit(widget.alertsOnly ? 300 : 500);
    });
    final profiles = await loadProfilesByIds(ref, [...rows.map((r) => r['user_id']), ...rows.map((r) => r['handled_by'])]);
    return (rows, profiles);
  }

  void _reload() => setState(() {
        _selected.clear();
        _future = _load();
      });

  Future<void> _handle(List<int> ids) async {
    final note = await showReasonDialog(context,
        title: ids.length == 1 ? 'Tangani event #${ids.first}' : 'Tangani ${ids.length} event',
        message: 'Catat tindakan yang diambil (mis. "Dikonfirmasi user, login sah" / "Akun di-suspend").',
        fieldLabel: 'Catatan penanganan',
        confirmLabel: 'Tandai ditangani');
    if (note == null || !mounted) return;
    final ok = await adminRun(context, ref, () async {
      for (final id in ids) {
        await ref.read(apiProvider).rpc('admin_handle_security_event', {'p_id': id, 'p_note': note});
      }
    }, success: '${ids.length} event ditandai ditangani');
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    return AsyncView<(List<J>, Map<String, J>)>(
      future: _future,
      onRetry: _reload,
      builder: (context, data) {
        final (rows, profiles) = data;
        String who(dynamic id) => id == null ? 'Sistem' : str(profiles[id]?['email'], shortId(id));
        final q = _q.toLowerCase();
        final list = rows.where((e) => q.isEmpty || '${who(e['user_id'])} ${e['event']} ${eventLabel(e['event'] as String?)} ${eventSummary(e)}'.toLowerCase().contains(q)).toList();
        final crit = list.where((e) => e['severity'] == 'critical').length;
        final open = list.where((e) => e['handled_at'] == null).map((e) => (e['id'] as num).toInt()).toList();
        final events = {...rows.map((e) => e['event'] as String), ..._eventLabels.keys}.toList()..sort();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.alertsOnly) ...[
            ResponsiveGrid(minItemWidth: 220, children: [
              StatCard(label: 'Alert terbuka', value: '${list.length}', icon: Icons.notification_important_outlined, color: list.isEmpty ? Brand.green : Brand.amber),
              StatCard(label: 'Critical', value: '$crit', icon: Icons.error_outline_rounded, color: crit == 0 ? Brand.green : Brand.red),
              StatCard(
                label: 'Anomali',
                value: '${list.where((e) => e['event'] == 'anomaly').length}',
                icon: Icons.query_stats_rounded,
                color: Brand.purple,
                caption: 'comen-security-scan tiap 15 menit',
              ),
            ]),
            const SizedBox(height: 16),
          ],
          TableCard(
            title: widget.alertsOnly ? 'Alert belum ditangani' : 'Security events',
            subtitle: widget.alertsOnly ? 'Severity warning & critical tanpa penanganan' : 'Maks 500 event terbaru per filter',
            icon: widget.alertsOnly ? Icons.notification_important_outlined : Icons.list_alt_rounded,
            count: list.length,
            trailing: open.isEmpty
                ? null
                : FilledButton.tonalIcon(
                    onPressed: () => _handle(_selected.isEmpty ? open : _selected.toList()),
                    icon: const Icon(Icons.task_alt_rounded, size: 18),
                    label: Text(_selected.isEmpty ? 'Tangani semua (${open.length})' : 'Tangani ${_selected.length} terpilih'),
                  ),
            toolbar: [
              AdminSearchField(hint: 'Cari user / event / detail', onChanged: (v) => setState(() => _q = v)),
              if (!widget.alertsOnly) ...[
                DropdownMenu<String?>(
                  initialSelection: _severity,
                  label: const Text('Severity'),
                  width: 160,
                  onSelected: (v) {
                    _severity = v;
                    _reload();
                  },
                  dropdownMenuEntries: const [
                    DropdownMenuEntry(value: null, label: 'Semua'),
                    DropdownMenuEntry(value: 'critical', label: 'Critical'),
                    DropdownMenuEntry(value: 'warning', label: 'Warning'),
                    DropdownMenuEntry(value: 'info', label: 'Info'),
                  ],
                ),
                DropdownMenu<String?>(
                  initialSelection: _event,
                  label: const Text('Event'),
                  width: 220,
                  enableFilter: true,
                  onSelected: (v) {
                    _event = v;
                    _reload();
                  },
                  dropdownMenuEntries: [
                    const DropdownMenuEntry(value: null, label: 'Semua event'),
                    for (final e in events) DropdownMenuEntry(value: e, label: eventLabel(e)),
                  ],
                ),
                Wrap(spacing: 6, children: [
                  for (final h in const [('all', 'Semua'), ('open', 'Belum ditangani'), ('done', 'Sudah ditangani')])
                    ChoiceChip(
                      label: Text(h.$2),
                      selected: _handled == h.$1,
                      onSelected: (_) {
                        _handled = h.$1;
                        _reload();
                      },
                    ),
                ]),
              ],
            ],
            child: DataList(
              empty: widget.alertsOnly ? 'Tidak ada alert terbuka 🎉' : 'Tidak ada event',
              columns: const ['', 'Waktu', 'Severity', 'Event', 'User', 'Ringkasan', 'Penanganan'],
              onTap: (i) => _detail(list[i], who),
              rows: [
                for (final e in list)
                  [
                    e['handled_at'] == null
                        ? Checkbox(
                            value: _selected.contains((e['id'] as num).toInt()),
                            onChanged: (v) => setState(() => v == true ? _selected.add((e['id'] as num).toInt()) : _selected.remove((e['id'] as num).toInt())),
                          )
                        : const Icon(Icons.check_circle_rounded, color: Brand.green, size: 20),
                    CellText(fmtRelative(e['created_at']), subtitle: fmtDateTime(e['created_at'])),
                    StatusBadge(severityStyle(e['severity'] as String?).$1, severityStyle(e['severity'] as String?).$2),
                    Text(eventLabel(e['event'] as String?), style: const TextStyle(fontWeight: FontWeight.w600)),
                    CellText(who(e['user_id']), subtitle: profiles[e['user_id']]?['full_name'] as String?, maxWidth: 220),
                    CellText(eventSummary(e), maxWidth: 280),
                    e['handled_at'] == null
                        ? const StatusBadge(Brand.amber, 'Terbuka')
                        : CellText('oleh ${who(e['handled_by'])}', subtitle: str(e['handle_note']), maxWidth: 220),
                  ],
              ],
            ),
          ),
          if (!(s?.can('admin.sessions.revoke') ?? false)) ...[
            const SizedBox(height: 12),
            const PermissionNote('admin.sessions.revoke', what: 'force logout dari detail event'),
          ],
        ]);
      },
    );
  }

  void _detail(J e, String Function(dynamic) who) {
    final s = sessionOf(ref);
    final uid = e['user_id'] as String?;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          StatusBadge(severityStyle(e['severity'] as String?).$1, severityStyle(e['severity'] as String?).$2),
          const SizedBox(width: 10),
          Expanded(child: Text('${eventLabel(e['event'] as String?)} · #${e['id']}')),
        ]),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              KeyValueGrid([
                ('Waktu', Text(fmtDateTime(e['created_at']))),
                ('User', SelectableText(who(uid))),
                ('Event', MonoText(str(e['event']), size: 12)),
                ('Penanganan', Text(e['handled_at'] == null ? 'Belum' : '${fmtDateTime(e['handled_at'])} · ${who(e['handled_by'])}')),
              ], minItemWidth: 240),
              if (e['handle_note'] != null) ...[const SizedBox(height: 12), InfoBanner(message: str(e['handle_note']), color: Brand.green, icon: Icons.task_alt_rounded)],
              const SizedBox(height: 16),
              const GroupLabel('Detail'),
              JsonBlock(e['detail']),
            ]),
          ),
        ),
        actions: [
          if (uid != null && (s?.can('admin.users.view') ?? false))
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                context.go('/admin/users/$uid');
              },
              icon: const Icon(Icons.person_search_rounded),
              label: const Text('Profil user'),
            ),
          if (uid != null && uid != s?.userId && (s?.can('admin.sessions.revoke') ?? false))
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await withReason(context, ref,
                    title: 'Force logout ${who(uid)}',
                    message: 'Semua sesi user ini diakhiri; user harus login ulang.',
                    confirmLabel: 'Logout paksa',
                    destructive: true,
                    success: 'Sesi user diakhiri',
                    action: (r) => ref.read(apiProvider).rpc('admin_force_logout', {'p_user': uid, 'p_reason': r}));
              },
              icon: const Icon(Icons.logout_rounded, color: Brand.red),
              label: const Text('Force logout'),
            ),
          if (uid != null && uid != s?.userId && (s?.can('admin.users.suspend') ?? false))
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                final reason = await showReasonDialog(context, title: 'Suspend ${who(uid)}', message: 'Akun diblokir dan semua sesi diakhiri.', confirmLabel: 'Suspend', destructive: true);
                if (reason == null || !mounted) return;
                final r = await runAction<Map<String, dynamic>>(context, ref, () => ref.read(apiProvider).edge('admin-actions', {'action': 'suspend', 'user_id': uid, 'reason': reason}),
                    success: 'Akun di-suspend');
                if (r != null && r['auth_synced'] == false && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Status DB tersimpan, tetapi sinkron Auth gagal — sinkronkan ulang dari profil user.')));
                }
              },
              icon: const Icon(Icons.block_rounded, color: Brand.red),
              label: const Text('Suspend'),
            ),
          if (e['handled_at'] == null)
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.pop(ctx);
                _handle([(e['id'] as num).toInt()]);
              },
              icon: const Icon(Icons.task_alt_rounded),
              label: const Text('Tangani'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
        ],
      ),
    );
  }
}

// ─────────────────────────── Devices ───────────────────────────
class _DevicesView extends ConsumerStatefulWidget {
  const _DevicesView({super.key});
  @override
  ConsumerState<_DevicesView> createState() => _DevicesViewState();
}

class _DevicesViewState extends ConsumerState<_DevicesView> {
  bool _activeOnly = true;
  bool _suspiciousOnly = false;
  String _q = '';
  late Future<(List<J>, Map<String, J>)> _future = _load();

  Future<(List<J>, Map<String, J>)> _load() async {
    final rows = await ref.read(apiProvider).select('trusted_devices', Cols.trustedDevices, build: (q) {
      final f = _activeOnly ? q.isFilter('revoked_at', null) : q;
      return f.order('first_seen', ascending: false).limit(500);
    });
    final profiles = await loadProfilesByIds(ref, rows.map((r) => r['user_id']));
    return (rows, profiles);
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    final canRevoke = s?.can('admin.sessions.revoke') ?? false;
    return AsyncView<(List<J>, Map<String, J>)>(
      future: _future,
      onRetry: _reload,
      builder: (context, data) {
        final (rows, profiles) = data;
        final now = DateTime.now();
        bool isNew(J d) => (parseDate(d['first_seen']) ?? DateTime(2000)).isAfter(now.subtract(const Duration(hours: 24)));
        final recentByUser = <String, int>{};
        for (final d in rows) {
          if ((parseDate(d['first_seen']) ?? DateTime(2000)).isAfter(now.subtract(const Duration(days: 7)))) {
            recentByUser.update(d['user_id'] as String, (v) => v + 1, ifAbsent: () => 1);
          }
        }
        bool suspicious(J d) => (recentByUser[d['user_id']] ?? 0) >= 3;
        String email(J d) => str(profiles[d['user_id']]?['email'], shortId(d['user_id']));
        final q = _q.toLowerCase();
        final list = rows.where((d) {
          if (_suspiciousOnly && !suspicious(d)) return false;
          return q.isEmpty || '${email(d)} ${d['label'] ?? ''}'.toLowerCase().contains(q);
        }).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ResponsiveGrid(minItemWidth: 220, children: [
            StatCard(label: 'Perangkat ${_activeOnly ? 'aktif' : 'total'}', value: '${rows.length}', icon: Icons.devices_rounded),
            StatCard(label: 'Baru 24 jam', value: '${rows.where(isNew).length}', icon: Icons.fiber_new_rounded, color: Brand.cyan),
            StatCard(
              label: 'User mencurigakan',
              value: '${recentByUser.values.where((v) => v >= 3).length}',
              icon: Icons.gpp_maybe_outlined,
              color: recentByUser.values.any((v) => v >= 3) ? Brand.red : Brand.green,
              caption: '≥ 3 perangkat baru dalam 7 hari',
              onTap: () => setState(() => _suspiciousOnly = !_suspiciousOnly),
            ),
          ]),
          const SizedBox(height: 16),
          if (!canRevoke) ...[const PermissionNote('admin.sessions.revoke', what: 'mencabut perangkat'), const SizedBox(height: 12)],
          TableCard(
            title: 'Perangkat tepercaya',
            subtitle: 'Maks 500 terbaru · fingerprint perangkat tidak ditampilkan',
            icon: Icons.devices_rounded,
            count: list.length,
            toolbar: [
              AdminSearchField(hint: 'Cari email / label perangkat', onChanged: (v) => setState(() => _q = v)),
              FilterChip(
                label: const Text('Hanya aktif'),
                selected: _activeOnly,
                onSelected: (v) {
                  _activeOnly = v;
                  _reload();
                },
              ),
              FilterChip(label: const Text('Mencurigakan'), selected: _suspiciousOnly, onSelected: (v) => setState(() => _suspiciousOnly = v)),
            ],
            child: DataList(
              empty: 'Tidak ada perangkat',
              columns: const ['User', 'Perangkat', 'Pertama terlihat', 'Terakhir aktif', 'Status', ''],
              rows: [
                for (final d in list)
                  [
                    CellText(email(d), subtitle: profiles[d['user_id']]?['full_name'] as String?, maxWidth: 240),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(str(d['label'], 'Perangkat')),
                      if (isNew(d)) ...[const SizedBox(width: 6), const StatusBadge(Brand.cyan, 'Baru')],
                      if (suspicious(d)) ...[const SizedBox(width: 6), StatusBadge(Brand.red, '${recentByUser[d['user_id']]}× / 7h', icon: Icons.gpp_maybe_rounded)],
                    ]),
                    CellText(fmtRelative(d['first_seen']), subtitle: fmtDateTime(d['first_seen'])),
                    Text(fmtRelative(d['last_seen'])),
                    d['revoked_at'] == null
                        ? const StatusBadge(Brand.green, 'Aktif')
                        : Tooltip(message: str(d['revoke_reason']), child: StatusBadge(Brand.grey, 'Dicabut ${fmtDate(d['revoked_at'])}')),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (s?.can('admin.users.view') ?? false)
                        IconButton(tooltip: 'Profil user', onPressed: () => context.go('/admin/users/${d['user_id']}'), icon: const Icon(Icons.person_search_rounded, size: 20)),
                      if (canRevoke && d['revoked_at'] == null)
                        IconButton(
                          tooltip: 'Cabut perangkat',
                          icon: const Icon(Icons.phonelink_erase_rounded, size: 20, color: Brand.red),
                          onPressed: () async {
                            final ok = await withReason(context, ref,
                                title: 'Cabut perangkat',
                                message: '${str(d['label'], 'Perangkat')} milik ${email(d)} akan dicabut; user harus verifikasi ulang di perangkat ini.',
                                confirmLabel: 'Cabut',
                                destructive: true,
                                success: 'Perangkat dicabut',
                                action: (r) => ref.read(apiProvider).rpc('admin_revoke_device', {'p_device': d['id'], 'p_reason': r}));
                            if (ok) _reload();
                          },
                        ),
                    ]),
                  ],
              ],
            ),
          ),
        ]);
      },
    );
  }
}

// ─────────────────────────── Policy ───────────────────────────
class _PolicyView extends ConsumerStatefulWidget {
  const _PolicyView({super.key});
  @override
  ConsumerState<_PolicyView> createState() => _PolicyViewState();
}

class _PolicyViewState extends ConsumerState<_PolicyView> {
  late Future<List<J>> _future = _load();
  Future<List<J>> _load() => ref.read(apiProvider).select('app_settings', 'key,value,is_public,required_permission,description,updated_by,updated_at',
      build: (q) => q.inFilter('key', const ['mfa_required_all', 'mfa_required_roles', 'step_up_hours', 'rate_chat_per_min', 'chat_key_ver', 'data_key_ver']).order('key'));

  static const _meta = <String, (String, IconData, String)>{
    'mfa_required_all': ('MFA wajib untuk semua user', Icons.shield_rounded, 'Semua user aktif — karyawan WFRD & contractor — wajib TOTP sebelum akses. User pending tetap bisa menyelesaikan registrasi.'),
    'mfa_required_roles': ('Role wajib MFA', Icons.verified_user_rounded, 'Bila "MFA wajib untuk semua user" dimatikan, hanya role ini yang wajib TOTP.'),
    'step_up_hours': ('Masa berlaku step-up', Icons.timer_outlined, 'Jam sebelum aksi sensitif meminta verifikasi MFA ulang (1–24).'),
    'rate_chat_per_min': ('Rate limit chat', Icons.speed_rounded, 'Maksimum pesan per menit per user (5–120).'),
    'chat_key_ver': ('Versi kunci chat', Icons.key_rounded, 'Rotasi dilakukan di System → Danger Zone.'),
    'data_key_ver': ('Versi kunci data', Icons.key_rounded, 'Rotasi dilakukan di System → Danger Zone.'),
  };

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    return AsyncView<List<J>>(
      future: _future,
      onRetry: () => setState(() => _future = _load()),
      builder: (context, list) {
        if (list.isEmpty) return const SectionCard(child: EmptyState(icon: Icons.lock_outline_rounded, title: 'Setting keamanan tidak terlihat', message: 'Butuh admin.security.manage.'));
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const InfoBanner(message: 'Perubahan kebijakan keamanan membutuhkan step-up MFA dan dicatat sebagai security event (warning).', color: Brand.purple, icon: Icons.verified_user_rounded),
          const SizedBox(height: 16),
          ResponsiveGrid(minItemWidth: 340, children: [
            for (final x in list)
              Builder(builder: (context) {
                final key = x['key'] as String;
                final m = _meta[key] ?? (key, Icons.settings_rounded, str(x['description']));
                final isKey = key.endsWith('_key_ver');
                final v = x['value'];
                return SectionCard(
                  title: m.$1,
                  subtitle: key,
                  icon: m.$2,
                  trailing: isKey
                      ? ((s?.can('admin.system.danger') ?? false)
                          ? TextButton(onPressed: () => context.go('/admin/system'), child: const Text('Rotasi'))
                          : null)
                      : IconButton(
                          tooltip: 'Ubah',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () async {
                            if (await editSetting(context, ref, x)) {
                              setState(() => _future = _load());
                              ref.read(sessionProvider.notifier).refresh();
                            }
                          },
                        ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (v is List)
                      Wrap(spacing: 6, runSpacing: 6, children: [for (final r in v) StatusBadge(Brand.purple, '$r', icon: Icons.shield_outlined)])
                    else
                      Text(isKey ? 'v$v' : '$v${key == 'step_up_hours' ? ' jam' : key == 'rate_chat_per_min' ? ' pesan/menit' : ''}',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: Brand.navy)),
                    const SizedBox(height: 8),
                    Text(m.$3, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text('Diperbarui ${fmtRelative(x['updated_at'])}', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Brand.grey)),
                  ]),
                );
              }),
          ]),
        ]);
      },
    );
  }
}
