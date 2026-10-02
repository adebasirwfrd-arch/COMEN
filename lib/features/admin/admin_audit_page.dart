import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/errors/app_failure.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_security_page.dart' show securityEventCols;
import 'admin_widgets.dart';

const auditedTables = [
  'admin_allowlist', 'app_settings', 'audit_findings', 'audits', 'bbs_observations', 'chat_channels', 'chat_members', 'chat_messages',
  'chat_pins', 'chat_scheduled', 'checklist_items', 'contract_requirements', 'contractors', 'contracts', 'daily_briefings',
  'doc_type_catalog', 'geozones', 'holidays', 'incidents', 'inspections', 'manning', 'meeting_attendees', 'meetings', 'opr_reviews',
  'permissions', 'profiles', 'risk_items', 'role_permissions', 'roles', 'self_assessments', 'signatures', 'stop_work_events',
  'subcontractors', 'tasks', 'trusted_devices', 'upload_links', 'user_invites', 'user_roles', 'vendor_evaluations',
];

(Color, String) _actionStyle(String? a) => switch (a) {
      'INSERT' => (Brand.green, 'INSERT'),
      'UPDATE' => (Brand.blue, 'UPDATE'),
      'DELETE' => (Brand.red, 'DELETE'),
      _ => (Brand.grey, a ?? '-'),
    };

/// Kunci yang berubah antara old_data dan new_data.
List<String> changedKeys(J row) {
  final o = jm(row['old_data']), n = jm(row['new_data']);
  final keys = {...o.keys, ...n.keys}.toList()..sort();
  return keys.where((k) => prettyJson(o[k]) != prettyJson(n[k])).toList();
}

class AdminAuditPage extends ConsumerStatefulWidget {
  const AdminAuditPage({super.key});
  @override
  ConsumerState<AdminAuditPage> createState() => _AdminAuditPageState();
}

class _AdminAuditPageState extends ConsumerState<AdminAuditPage> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 7));
  DateTime _to = DateTime.now();
  J? _actor;
  String? _table;
  String? _action;
  final _record = TextEditingController();

  final _rows = <J>[];
  bool _loading = false;
  bool _hasMore = false;
  Object? _error;
  static const _pageSize = 100;

  late Future<(J?, J?)> _chain = _loadChain();
  J? _verify;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _record.dispose();
    super.dispose();
  }

  Future<(J?, J?)> _loadChain() async {
    final api = ref.read(apiProvider);
    J? head, anchor;
    try {
      head = jm((await api.rpcMap('admin_overview'))['audit_head']);
    } catch (_) {}
    try {
      final r = await api.select('security_events', securityEventCols, build: (q) => q.eq('event', 'audit_anchor').order('created_at', ascending: false).limit(1));
      anchor = r.firstOrNull;
    } catch (_) {}
    return (head, anchor);
  }

  Future<void> _search({bool more = false}) async {
    final rangeDays = _to.difference(_from).inDays;
    if (_to.isBefore(_from) || rangeDays > 365) {
      setState(() => _error = 'Rentang tanggal tidak valid (maks 366 hari).');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      if (!more) _rows.clear();
    });
    try {
      final r = await ref.read(apiProvider).rpcList('admin_audit_search', {
        'p_from': DateTime(_from.year, _from.month, _from.day).toUtc().toIso8601String(),
        'p_to': DateTime(_to.year, _to.month, _to.day).add(const Duration(days: 1)).toUtc().toIso8601String(),
        'p_actor': _actor?['id'],
        'p_table': _table,
        'p_action': _action,
        'p_record': _record.text.trim().isEmpty ? null : _record.text.trim(),
        'p_before_id': more && _rows.isNotEmpty ? _rows.last['id'] : null,
        'p_limit': _pageSize,
      });
      if (!mounted) return;
      setState(() {
        _rows.addAll(r);
        _hasMore = r.length == _pageSize;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runVerify() async {
    setState(() => _verifying = true);
    final r = await runAction<Map<String, dynamic>>(context, ref, () => ref.read(apiProvider).rpcMap('admin_verify_audit_chain'));
    if (!mounted) return;
    setState(() {
      _verifying = false;
      if (r != null) _verify = r;
    });
  }

  void _reset() {
    setState(() {
      _from = DateTime.now().subtract(const Duration(days: 7));
      _to = DateTime.now();
      _actor = null;
      _table = null;
      _action = null;
      _record.clear();
    });
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    return AdminScaffold(
      title: 'Audit Explorer',
      subtitle: 'Jejak perubahan data (hash chain, immutable) · pencarian per rentang waktu, actor, tabel, aksi, record',
      actions: [
        OutlinedButton.icon(
          onPressed: () {
            setState(() => _chain = _loadChain());
            _search();
          },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Muat ulang'),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _chainCard(s?.can('admin.audit.verify') ?? false),
        const SizedBox(height: 16),
        _filters(),
        const SizedBox(height: 16),
        _results(),
      ]),
    );
  }

  Widget _chainCard(bool canVerify) => FutureBuilder<(J?, J?)>(
        future: _chain,
        builder: (context, snap) {
          final (head, anchor) = snap.data ?? (null, null);
          final a = jm(anchor?['detail']);
          final v = _verify;
          final anchorMatches = anchor != null && head != null && a['last_id'] == head['id'];
          return ResponsiveGrid(minItemWidth: 300, children: [
            SectionCard(
              title: 'Chain head',
              icon: Icons.link_rounded,
              child: head == null
                  ? Text(snap.connectionState == ConnectionState.done ? 'Tidak tersedia' : 'Memuat…')
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('#${head['id'] ?? '-'}', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: Brand.navy)),
                      const SizedBox(height: 4),
                      Row(children: [Expanded(child: MonoText(str(head['hash']), size: 11)), if (head['hash'] != null) CopyButton(str(head['hash'], ''))]),
                    ]),
            ),
            SectionCard(
              title: 'Anchor harian terakhir',
              icon: Icons.anchor_rounded,
              trailing: anchor == null ? null : StatusBadge(anchorMatches ? Brand.green : Brand.blue, anchorMatches ? 'Sama dgn head' : 'Head sudah maju'),
              child: anchor == null
                  ? Text(snap.connectionState == ConnectionState.done ? 'Belum ada / butuh admin.security.manage' : 'Memuat…',
                      style: Theme.of(context).textTheme.bodySmall)
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(fmtDateTime(a['anchored_at'] ?? anchor['created_at']), style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('id #${a['last_id']} · ${a['rows_24h'] ?? 0} baris / 24 jam', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 4),
                      MonoText(str(a['last_hash']), size: 11),
                      const SizedBox(height: 4),
                      Text('Cron comen-audit-anchor 23:55 WIB · dikirim email #7006', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Brand.grey)),
                    ]),
            ),
            SectionCard(
              title: 'Verifikasi hash chain',
              icon: Icons.verified_outlined,
              trailing: canVerify
                  ? FilledButton.tonalIcon(
                      onPressed: _verifying ? null : _runVerify,
                      icon: _verifying ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow_rounded, size: 18),
                      label: Text(_verifying ? 'Memeriksa…' : 'Verifikasi'),
                    )
                  : null,
              child: !canVerify
                  ? const PermissionNote('admin.audit.verify', what: 'memverifikasi chain')
                  : v == null
                      ? Text('Hitung ulang hash setiap baris dan cocokkan dengan prev_hash (maks 200.000 baris).', style: Theme.of(context).textTheme.bodySmall)
                      : v['ok'] == true
                          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const StatusBadge(Brand.green, 'UTUH', icon: Icons.verified_rounded),
                              const SizedBox(height: 6),
                              Text('${v['checked']} baris diperiksa'),
                              if (jm(v['head'])['hash'] != null && v['last_hash'] != null && jm(v['head'])['hash'] != v['last_hash'])
                                const Text('Catatan: last_hash ≠ head (batas 200.000 baris tercapai atau ada insert baru).', style: TextStyle(color: Brand.amber)),
                            ])
                          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const StatusBadge(Brand.red, 'RUSAK', icon: Icons.gpp_bad_rounded),
                              const SizedBox(height: 6),
                              Text('Putus di id #${v['broken_at_id']} · ${v['reason'] == 'prev_hash_mismatch' ? 'prev_hash tidak cocok' : 'row_hash tidak cocok'}'),
                              Text('${v['checked']} baris valid sebelum titik putus', style: Theme.of(context).textTheme.bodySmall),
                            ]),
            ),
          ]);
        },
      );

  Widget _filters() => SectionCard(
        title: 'Filter',
        icon: Icons.filter_alt_outlined,
        trailing: TextButton.icon(onPressed: _reset, icon: const Icon(Icons.restart_alt_rounded, size: 18), label: const Text('Reset')),
        child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 180, child: DateField(label: 'Dari', value: _from, clearable: false, last: DateTime.now(), onChanged: (d) => setState(() => _from = d ?? _from))),
          SizedBox(width: 180, child: DateField(label: 'Sampai', value: _to, clearable: false, last: DateTime.now(), onChanged: (d) => setState(() => _to = d ?? _to))),
          Wrap(spacing: 6, children: [
            for (final p in const [(1, '24 jam'), (7, '7 hari'), (30, '30 hari'), (90, '90 hari')])
              ActionChip(
                label: Text(p.$2),
                onPressed: () => setState(() {
                  _to = DateTime.now();
                  _from = _to.subtract(Duration(days: p.$1));
                }),
              ),
          ]),
          InputChip(
            avatar: const Icon(Icons.person_outline_rounded, size: 18),
            label: Text(_actor == null ? 'Semua actor' : str(_actor!['email'], shortId(_actor!['id']))),
            onPressed: () async {
              final u = await showUserPicker(context, ref, title: 'Filter actor', status: null);
              if (u != null) setState(() => _actor = u);
            },
            onDeleted: _actor == null ? null : () => setState(() => _actor = null),
          ),
          DropdownMenu<String?>(
            initialSelection: _table,
            label: const Text('Tabel'),
            width: 240,
            enableFilter: true,
            requestFocusOnTap: true,
            onSelected: (v) => setState(() => _table = v),
            dropdownMenuEntries: [const DropdownMenuEntry(value: null, label: 'Semua tabel'), for (final t in auditedTables) DropdownMenuEntry(value: t, label: t)],
          ),
          SegmentedButton<String?>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: null, label: Text('Semua')),
              ButtonSegment(value: 'INSERT', label: Text('Insert')),
              ButtonSegment(value: 'UPDATE', label: Text('Update')),
              ButtonSegment(value: 'DELETE', label: Text('Delete')),
            ],
            selected: {_action},
            onSelectionChanged: (v) => setState(() => _action = v.first),
          ),
          SizedBox(
            width: 260,
            child: TextField(
              controller: _record,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(labelText: 'Record ID (exact)', prefixIcon: Icon(Icons.tag_rounded), isDense: true),
            ),
          ),
          FilledButton.icon(onPressed: _loading ? null : () => _search(), icon: const Icon(Icons.search_rounded), label: const Text('Cari')),
        ]),
      );

  Widget _results() {
    if (_error != null && _rows.isEmpty) {
      return SectionCard(child: _error is String ? EmptyState(icon: Icons.error_outline_rounded, title: _error as String) : ErrorView(_error!, onRetry: _search));
    }
    if (_loading && _rows.isEmpty) return const SectionCard(child: LoadingView());
    return TableCard(
      title: 'Hasil',
      subtitle: 'Urut id terbaru · $_pageSize per halaman',
      icon: Icons.manage_search_rounded,
      count: _rows.length,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DataList(
          empty: 'Tidak ada perubahan pada rentang/filter ini',
          columns: const ['ID', 'Waktu', 'Tabel', 'Aksi', 'Record', 'Actor', 'Field berubah'],
          onTap: (i) => _detail(_rows[i]),
          rows: [
            for (final r in _rows)
              [
                MonoText('${r['id']}', size: 12),
                CellText(fmtDateTime(r['created_at']), subtitle: fmtRelative(r['created_at'])),
                MonoText(str(r['table_name']), size: 12),
                StatusBadge(_actionStyle(r['action'] as String?).$1, _actionStyle(r['action'] as String?).$2),
                CellText(str(r['record_id']), mono: true, maxWidth: 200),
                CellText(r['actor_id'] == null ? 'Sistem' : str(r['actor_email'], shortId(r['actor_id'])), maxWidth: 220),
                CellText(r['action'] == 'UPDATE' ? changedKeys(r).join(', ') : (r['action'] == 'INSERT' ? 'baris baru' : 'baris dihapus'), maxWidth: 260),
              ],
          ],
        ),
        if (_error != null && _rows.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(AppFailure.from(_error!).message, style: const TextStyle(color: Brand.red))),
        if (_hasMore || _loading)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Center(
              child: OutlinedButton.icon(
                onPressed: _loading ? null : () => _search(more: true),
                icon: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.expand_more_rounded),
                label: const Text('Muat lebih lama'),
              ),
            ),
          ),
      ]),
    );
  }

  void _detail(J r) {
    final o = jm(r['old_data']), n = jm(r['new_data']);
    final keys = r['action'] == 'UPDATE' ? changedKeys(r) : ({...o.keys, ...n.keys}.toList()..sort());
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          StatusBadge(_actionStyle(r['action'] as String?).$1, _actionStyle(r['action'] as String?).$2),
          const SizedBox(width: 10),
          Expanded(child: Text('${r['table_name']} · #${r['id']}', overflow: TextOverflow.ellipsis)),
        ]),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              KeyValueGrid([
                ('Waktu', Text(fmtDateTime(r['created_at']))),
                ('Actor', SelectableText(r['actor_id'] == null ? 'Sistem' : str(r['actor_email'], str(r['actor_id'])))),
                ('Record', MonoText(str(r['record_id']), size: 12)),
                ('Row hash', MonoText(str(r['row_hash']), size: 11)),
              ], minItemWidth: 300),
              const SizedBox(height: 16),
              GroupLabel(r['action'] == 'UPDATE' ? 'Perubahan (${keys.length} field)' : 'Data'),
              if (keys.isEmpty)
                const Text('Tidak ada perbedaan field (mis. hanya updated_at).')
              else
                Table(
                  columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth(), 2: FlexColumnWidth()},
                  defaultVerticalAlignment: TableCellVerticalAlignment.top,
                  border: TableBorder(horizontalInside: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.4))),
                  children: [
                    const TableRow(children: [
                      Padding(padding: EdgeInsets.all(6), child: Text('Field', style: TextStyle(fontWeight: FontWeight.w800))),
                      Padding(padding: EdgeInsets.all(6), child: Text('Sebelum', style: TextStyle(fontWeight: FontWeight.w800, color: Brand.red))),
                      Padding(padding: EdgeInsets.all(6), child: Text('Sesudah', style: TextStyle(fontWeight: FontWeight.w800, color: Brand.green))),
                    ]),
                    for (final k in keys)
                      TableRow(children: [
                        Padding(padding: const EdgeInsets.all(6), child: MonoText(k, size: 12)),
                        Padding(padding: const EdgeInsets.all(6), child: _val(o.containsKey(k) ? o[k] : null, o.containsKey(k))),
                        Padding(padding: const EdgeInsets.all(6), child: _val(n.containsKey(k) ? n[k] : null, n.containsKey(k))),
                      ]),
                  ],
                ),
              const SizedBox(height: 16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('JSON mentah'),
                children: [
                  if (r['old_data'] != null) ...[const GroupLabel('old_data', color: Brand.red), JsonBlock(r['old_data'], maxHeight: 240)],
                  if (r['new_data'] != null) ...[const GroupLabel('new_data', color: Brand.green), JsonBlock(r['new_data'], maxHeight: 240)],
                ],
              ),
            ]),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _table = r['table_name'] as String?;
                _record.text = str(r['record_id'], '');
                _action = null;
              });
              _search();
            },
            icon: const Icon(Icons.history_rounded),
            label: const Text('Riwayat record ini'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
        ],
      ),
    );
  }

  Widget _val(dynamic v, bool present) {
    if (!present) return const Text('—', style: TextStyle(color: Brand.grey));
    final text = v is Map || v is List ? prettyJson(v) : (v?.toString() ?? 'null');
    return SelectableText(text, maxLines: 8, style: const TextStyle(fontFamily: 'monospace', fontSize: 12));
  }
}
