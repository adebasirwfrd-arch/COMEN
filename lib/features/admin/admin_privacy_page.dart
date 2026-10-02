import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_security_page.dart' show securityEventCols;
import 'admin_widgets.dart';

class AdminPrivacyPage extends ConsumerStatefulWidget {
  const AdminPrivacyPage({super.key});
  @override
  ConsumerState<AdminPrivacyPage> createState() => _AdminPrivacyPageState();
}

class _AdminPrivacyPageState extends ConsumerState<AdminPrivacyPage> {
  J? _user;
  bool _loadingUser = false;
  J? _lastExport;
  late Future<(List<J>, Map<String, J>)?> _history = _loadHistory();

  Future<(List<J>, Map<String, J>)?> _loadHistory() async {
    try {
      final rows = await ref.read(apiProvider).select('security_events', securityEventCols,
          build: (q) => q.inFilter('event', const ['export', 'anonymized']).order('created_at', ascending: false).limit(50));
      final list = rows.where((e) => e['event'] == 'anonymized' || jm(e['detail'])['kind'] == 'dsar').toList();
      final profiles = await loadProfilesByIds(ref, [...list.map((e) => e['user_id']), ...list.map((e) => jm(e['detail'])['by'])]);
      return (list, profiles);
    } catch (_) {
      return null;
    }
  }

  Future<void> _pick() async {
    final u = await showUserPicker(context, ref, title: 'Pilih subjek data', status: null);
    if (u == null || !mounted) return;
    setState(() {
      _loadingUser = true;
      _lastExport = null;
    });
    J? p;
    try {
      p = await ref.read(apiProvider).selectOne('profiles', Cols.profiles, 'id', u['id'] as Object);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _user = p ?? u;
      _loadingUser = false;
    });
  }

  Future<void> _reloadUser() async {
    final id = _user?['id'];
    if (id == null) return;
    try {
      final p = await ref.read(apiProvider).selectOne('profiles', Cols.profiles, 'id', id as Object);
      if (mounted && p != null) setState(() => _user = p);
    } catch (_) {}
  }

  Future<void> _export() async {
    final u = _user!;
    final reason = await showReasonDialog(context,
        title: 'Export data pribadi (DSAR)',
        message: 'Seluruh data pribadi ${u['email']} (profil, role, perangkat, event keamanan, konfirmasi task, pesan chat terdekripsi) '
            'akan diunduh ke perangkat Anda. Butuh step-up MFA · maks 3 export/jam · tercatat sebagai security event.',
        fieldLabel: 'Dasar permintaan (mis. nomor tiket DSAR)',
        confirmLabel: 'Export');
    if (reason == null || !mounted) return;
    final r = await runAction<Map<String, dynamic>>(context, ref,
        () => ref.read(apiProvider).rpcMap('admin_export_user_data', {'p_user': u['id'], 'p_reason': reason}),
        success: 'Data diekspor');
    if (r == null || !mounted) return;
    final content = const JsonEncoder.withIndent('  ').convert(r);
    final hash = sha256Hex(content);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final base = 'dsar-${shortId(u['id'])}-$stamp';
    downloadText('$base.json', content);
    downloadText('$base.sha256.txt', '$hash  $base.json\n', mime: 'text/plain');
    setState(() {
      _lastExport = {
        'file': '$base.json',
        'sha256': hash,
        'roles': (r['roles'] as List? ?? const []).length,
        'devices': (r['devices'] as List? ?? const []).length,
        'security_events': (r['security_events'] as List? ?? const []).length,
        'tasks_confirmed': (r['tasks_confirmed'] as List? ?? const []).length,
        'messages': (r['messages'] as List? ?? const []).length,
        'generated_at': r['generated_at'],
      };
      _history = _loadHistory();
    });
  }

  Future<void> _anonymize() async {
    final u = _user!;
    final reason = await showConfirmPhraseDialog(context,
        title: 'Anonimkan ${u['email']}',
        message: 'TIDAK BISA DIBATALKAN. Nama, email, foto, telepon, jabatan dihapus; semua role dicabut; perangkat & notifikasi dihapus; '
            'akun dinonaktifkan dan di-ban di Auth. Jejak audit & pesan chat tetap ada dengan nama "Pengguna Terhapus". '
            'Sarankan export DSAR dulu bila diminta subjek.',
        phrase: 'ANONIMKAN');
    if (reason == null || !mounted) return;
    final r = await runAction<Map<String, dynamic>>(context, ref,
        () => ref.read(apiProvider).edge('admin-actions', {'action': 'anonymize', 'user_id': u['id'], 'reason': reason}));
    if (r == null || !mounted) return;
    final already = r['already'] == true;
    final synced = r['auth_synced'] != false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(synced ? Icons.check_circle_rounded : Icons.sync_problem_rounded, color: synced ? Brand.green : Brand.amber, size: 40),
        title: Text(already ? 'User sudah dianonimkan' : 'Anonimisasi selesai'),
        content: SizedBox(
          width: 460,
          child: Text(synced
              ? 'Data pribadi telah dihapus dan akun Auth di-ban.'
              : 'Data di database sudah dianonimkan, tetapi sinkronisasi ke Auth (email/ban/MFA) gagal. '
                  'Buka profil user lalu jalankan "Sinkronkan ulang" (ban) dan Reset MFA.'),
        ),
        actions: [
          if (!synced)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.go('/admin/users/${u['id']}');
              },
              child: const Text('Buka profil user'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
        ],
      ),
    );
    await _reloadUser();
    if (mounted) setState(() => _history = _loadHistory());
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    final u = _user;
    final anonymized = u?['anonymized_at'] != null;
    final isSelf = u != null && u['id'] == s?.userId;
    final isRoot = u?['is_root_admin'] == true;
    return AdminScaffold(
      title: 'Privacy & DSAR',
      subtitle: 'Permintaan akses data subjek (export) dan hak untuk dilupakan (anonimisasi) · UU PDP',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionCard(
          title: 'Subjek data',
          subtitle: 'Pilih user yang mengajukan permintaan',
          icon: Icons.person_search_rounded,
          trailing: FilledButton.tonalIcon(onPressed: _pick, icon: const Icon(Icons.search_rounded, size: 18), label: Text(u == null ? 'Pilih user' : 'Ganti')),
          child: _loadingUser
              ? const LoadingView()
              : u == null
                  ? const EmptyState(icon: Icons.person_outline_rounded, title: 'Belum ada user dipilih', message: 'Cari berdasarkan nama atau email.')
                  : Row(children: [
                      Avatar(name: u['full_name'] as String?, url: u['avatar_url'] as String?, radius: 26),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(str(u['full_name']), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                          SelectableText(str(u['email'])),
                          const SizedBox(height: 6),
                          Wrap(spacing: 6, runSpacing: 6, children: [
                            StatusBadge.account(u['status'] as String?),
                            if (anonymized) StatusBadge(Brand.grey, 'Dianonimkan ${fmtDate(u['anonymized_at'])}', icon: Icons.person_off_rounded),
                            if (isRoot) const StatusBadge(Brand.red, 'Root admin', icon: Icons.shield_rounded),
                            if (isSelf) const StatusBadge(Brand.blue, 'Akun Anda'),
                            if (u['created_at'] != null) StatusBadge(Brand.grey, 'Terdaftar ${fmtDate(u['created_at'])}'),
                          ]),
                        ]),
                      ),
                      if (s?.can('admin.users.view') ?? false)
                        IconButton(tooltip: 'Profil lengkap', onPressed: () => context.go('/admin/users/${u['id']}'), icon: const Icon(Icons.open_in_new_rounded)),
                    ]),
        ),
        const SizedBox(height: 16),
        ResponsiveGrid(minItemWidth: 420, children: [
          SectionCard(
            title: 'Export data (DSAR)',
            subtitle: 'JSON + file checksum SHA-256',
            icon: Icons.download_rounded,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Isi: profil (termasuk telepon terdekripsi), role & scope, perangkat, riwayat event keamanan, task yang dikonfirmasi, pesan chat yang dikirim.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: u == null ? null : _export,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Export data'),
                ),
              ),
              if (_lastExport != null) ...[
                const SizedBox(height: 16),
                InfoBanner(message: 'Diunduh: ${_lastExport!['file']}', color: Brand.green, icon: Icons.check_circle_rounded),
                const SizedBox(height: 12),
                KeyValueGrid([
                  ('Role', Text('${_lastExport!['roles']}')),
                  ('Perangkat', Text('${_lastExport!['devices']}')),
                  ('Event keamanan', Text('${_lastExport!['security_events']}')),
                  ('Task dikonfirmasi', Text('${_lastExport!['tasks_confirmed']}')),
                  ('Pesan chat', Text('${_lastExport!['messages']}')),
                  ('Dibuat', Text(fmtDateTime(_lastExport!['generated_at']))),
                ], minItemWidth: 140),
                const SizedBox(height: 12),
                const GroupLabel('SHA-256'),
                Row(children: [Expanded(child: MonoText(str(_lastExport!['sha256']), size: 11)), CopyButton(str(_lastExport!['sha256'], ''))]),
              ],
            ]),
          ),
          DangerCard(
            title: 'Anonimisasi (hak untuk dilupakan)',
            description: anonymized
                ? 'User ini sudah dianonimkan.'
                : isRoot
                    ? 'Root admin dilindungi dan tidak bisa dianonimkan.'
                    : isSelf
                        ? 'Tidak bisa menganonimkan akun sendiri.'
                        : 'Menghapus PII secara permanen, mencabut semua akses, dan mem-ban akun di Auth. Wajib frasa konfirmasi + alasan + step-up MFA.',
            icon: Icons.person_off_rounded,
            status: anonymized ? const StatusBadge(Brand.grey, 'Selesai') : null,
            action: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              onPressed: (u == null || anonymized || isRoot || isSelf) ? null : _anonymize,
              icon: const Icon(Icons.delete_forever_rounded),
              label: const Text('Anonimkan'),
            ),
          ),
        ]),
        const SizedBox(height: 16),
        FutureBuilder<(List<J>, Map<String, J>)?>(
          future: _history,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const SectionCard(child: LoadingView());
            final data = snap.data;
            if (data == null) return const PermissionNote('admin.security.manage', what: 'melihat riwayat DSAR & anonimisasi');
            final (rows, profiles) = data;
            String who(dynamic id) => id == null ? '-' : str(profiles[id]?['email'], shortId(id));
            return TableCard(
              title: 'Riwayat privasi',
              subtitle: '50 event export DSAR & anonimisasi terbaru',
              icon: Icons.history_rounded,
              count: rows.length,
              child: DataList(
                empty: 'Belum ada permintaan privasi',
                columns: const ['Waktu', 'Jenis', 'Subjek', 'Oleh', 'Alasan'],
                rows: [
                  for (final e in rows)
                    [
                      CellText(fmtRelative(e['created_at']), subtitle: fmtDateTime(e['created_at'])),
                      e['event'] == 'anonymized'
                          ? const StatusBadge(Brand.red, 'Anonimisasi', icon: Icons.person_off_rounded)
                          : const StatusBadge(Brand.blue, 'Export DSAR', icon: Icons.download_rounded),
                      CellText(who(e['user_id']), maxWidth: 240),
                      CellText(who(jm(e['detail'])['by']), maxWidth: 220),
                      CellText(str(jm(e['detail'])['reason']), maxWidth: 300),
                    ],
                ],
              ),
            );
          },
        ),
      ]),
    );
  }
}
