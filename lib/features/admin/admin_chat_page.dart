import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

(Color, String, IconData) _typeStyle(String? t) => switch (t) {
      'contract' => (Brand.navy, 'Kontrak', Icons.description_outlined),
      'task' => (Brand.cyan, 'Task', Icons.task_alt_rounded),
      'announcement' => (Brand.purple, 'Pengumuman', Icons.campaign_outlined),
      'group' => (Brand.blue, 'Grup', Icons.groups_2_outlined),
      _ => (Brand.grey, t ?? '-', Icons.chat_bubble_outline_rounded),
    };

class AdminChatPage extends ConsumerStatefulWidget {
  const AdminChatPage({super.key});
  @override
  ConsumerState<AdminChatPage> createState() => _AdminChatPageState();
}

class _AdminChatPageState extends ConsumerState<AdminChatPage> {
  String _search = '';
  String _type = 'all';
  String _flag = 'all';
  late Future<List<J>> _future = _load();

  Future<List<J>> _load() => ref.read(apiProvider).rpcList('admin_list_channels', {'p_search': _search.isEmpty ? null : _search, 'p_limit': 500});
  void _reload() => setState(() => _future = _load());

  Future<void> _patch(J c, Map<String, dynamic> patch, {required String title, String? message, String? success, bool destructive = false}) async {
    final ok = await withReason(context, ref,
        title: title,
        message: message,
        destructive: destructive,
        success: success ?? 'Channel diperbarui',
        action: (r) => ref.read(apiProvider).rpc('admin_chat_set_channel', {'p_channel': c['id'], 'p_patch': patch, 'p_reason': r}));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    final canExport = s?.can('chat.export') ?? false;
    return AdminScaffold(
      title: 'Chat Admin',
      subtitle: 'Kunci / arsip channel, legal hold, retensi pesan, dan export transcript (non-DM)',
      actions: [OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang'))],
      child: AsyncView<List<J>>(
        future: _future,
        onRetry: _reload,
        builder: (context, all) {
          final list = all.where((c) {
            if (_type != 'all' && c['type'] != _type) return false;
            return switch (_flag) {
              'locked' => c['is_locked'] == true,
              'archived' => c['is_archived'] == true,
              'hold' => c['legal_hold'] == true,
              _ => true,
            };
          }).toList();
          int n(bool Function(J) f) => all.where(f).length;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ResponsiveGrid(minItemWidth: 200, children: [
              StatCard(label: 'Channel', value: '${all.length}', icon: Icons.forum_outlined, onTap: () => setState(() => _flag = 'all')),
              StatCard(label: 'Terkunci', value: '${n((c) => c['is_locked'] == true)}', icon: Icons.lock_outline_rounded, color: Brand.amber, onTap: () => setState(() => _flag = 'locked')),
              StatCard(label: 'Diarsipkan', value: '${n((c) => c['is_archived'] == true)}', icon: Icons.archive_outlined, color: Brand.grey, onTap: () => setState(() => _flag = 'archived')),
              StatCard(label: 'Legal hold', value: '${n((c) => c['legal_hold'] == true)}', icon: Icons.gavel_rounded, color: Brand.purple, onTap: () => setState(() => _flag = 'hold')),
            ]),
            const SizedBox(height: 16),
            const InfoBanner(
              message: 'Pesan DM tidak ditampilkan di sini (privasi). Retensi dihapus otomatis oleh cron comen-retention 03:00 WIB, kecuali channel dengan legal hold.',
              icon: Icons.privacy_tip_outlined,
            ),
            const SizedBox(height: 16),
            TableCard(
              title: 'Channel',
              subtitle: 'Urut aktivitas terakhir',
              icon: Icons.forum_outlined,
              count: list.length,
              toolbar: [
                AdminSearchField(
                  hint: 'Cari nama channel',
                  onChanged: (v) {
                    _search = v.trim();
                    _reload();
                  },
                ),
                DropdownMenu<String>(
                  initialSelection: _type,
                  label: const Text('Tipe'),
                  width: 180,
                  onSelected: (v) => setState(() => _type = v ?? 'all'),
                  dropdownMenuEntries: const [
                    DropdownMenuEntry(value: 'all', label: 'Semua tipe'),
                    DropdownMenuEntry(value: 'contract', label: 'Kontrak'),
                    DropdownMenuEntry(value: 'task', label: 'Task'),
                    DropdownMenuEntry(value: 'group', label: 'Grup'),
                    DropdownMenuEntry(value: 'announcement', label: 'Pengumuman'),
                  ],
                ),
                Wrap(spacing: 6, children: [
                  for (final f in const [('all', 'Semua'), ('locked', 'Terkunci'), ('archived', 'Arsip'), ('hold', 'Legal hold')])
                    ChoiceChip(label: Text(f.$2), selected: _flag == f.$1, onSelected: (_) => setState(() => _flag = f.$1)),
                ]),
              ],
              child: DataList(
                empty: 'Tidak ada channel',
                columns: const ['Channel', 'Tipe', 'Anggota', 'Status', 'Retensi', 'Aktivitas', ''],
                rows: [
                  for (final c in list)
                    [
                      CellText(str(c['name'], '(tanpa nama)'), subtitle: shortId(c['id']), maxWidth: 260),
                      StatusBadge(_typeStyle(c['type'] as String?).$1, _typeStyle(c['type'] as String?).$2, icon: _typeStyle(c['type'] as String?).$3),
                      Text('${c['members'] ?? 0}'),
                      Wrap(spacing: 4, runSpacing: 4, children: [
                        if (c['is_locked'] == true) const StatusBadge(Brand.amber, 'Terkunci', icon: Icons.lock_rounded),
                        if (c['is_archived'] == true) const StatusBadge(Brand.grey, 'Arsip', icon: Icons.archive_rounded),
                        if (c['legal_hold'] == true) const StatusBadge(Brand.purple, 'Legal hold', icon: Icons.gavel_rounded),
                        if (c['is_locked'] != true && c['is_archived'] != true && c['legal_hold'] != true) const StatusBadge(Brand.green, 'Normal'),
                      ]),
                      Text(c['legal_hold'] == true ? '∞ (hold)' : '${c['retention_days']} hari'),
                      Text(fmtRelative(c['last_message_at'])),
                      _menu(c, canExport),
                    ],
                ],
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _menu(J c, bool canExport) {
    final locked = c['is_locked'] == true, archived = c['is_archived'] == true, hold = c['legal_hold'] == true;
    return PopupMenuButton<String>(
      tooltip: 'Aksi',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (a) async {
        switch (a) {
          case 'open':
            context.go('/chat/${c['id']}');
          case 'lock':
            await _patch(c, {'is_locked': !locked},
                title: locked ? 'Buka kunci channel' : 'Kunci channel',
                message: locked ? 'Anggota bisa mengirim pesan lagi.' : 'Channel menjadi read-only untuk semua anggota.',
                success: locked ? 'Channel dibuka' : 'Channel dikunci');
          case 'archive':
            await _patch(c, {'is_archived': !archived},
                title: archived ? 'Pulihkan dari arsip' : 'Arsipkan channel', success: archived ? 'Channel dipulihkan' : 'Channel diarsipkan');
          case 'hold':
            await _patch(c, {'legal_hold': !hold},
                title: hold ? 'Lepas legal hold' : 'Pasang legal hold',
                message: hold
                    ? 'Pesan lama akan kembali dihapus sesuai retensi (${c['retention_days']} hari) pada run cron berikutnya.'
                    : 'Semua pesan channel ini dikecualikan dari penghapusan retensi sampai hold dilepas.',
                destructive: hold,
                success: hold ? 'Legal hold dilepas' : 'Legal hold dipasang');
          case 'edit':
            await _edit(c);
          case 'export':
            await _export(c);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'open', child: ListTile(dense: true, leading: Icon(Icons.open_in_new_rounded), title: Text('Buka channel'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'lock', child: ListTile(dense: true, leading: Icon(locked ? Icons.lock_open_rounded : Icons.lock_rounded), title: Text(locked ? 'Buka kunci' : 'Kunci'))),
        PopupMenuItem(value: 'archive', child: ListTile(dense: true, leading: Icon(archived ? Icons.unarchive_rounded : Icons.archive_rounded), title: Text(archived ? 'Pulihkan' : 'Arsipkan'))),
        PopupMenuItem(value: 'hold', child: ListTile(dense: true, leading: const Icon(Icons.gavel_rounded, color: Brand.purple), title: Text(hold ? 'Lepas legal hold' : 'Legal hold'))),
        const PopupMenuItem(value: 'edit', child: ListTile(dense: true, leading: Icon(Icons.edit_outlined), title: Text('Nama, topik & retensi'))),
        if (canExport) const PopupMenuItem(value: 'export', child: ListTile(dense: true, leading: Icon(Icons.download_rounded), title: Text('Export transcript'))),
      ],
    );
  }

  Future<void> _edit(J c) async {
    final res = await showDialog<(Map<String, dynamic>, String)>(context: context, builder: (_) => _ChannelDialog(channel: c));
    if (res == null || !mounted) return;
    final ok = await adminRun(context, ref, () => ref.read(apiProvider).rpc('admin_chat_set_channel', {'p_channel': c['id'], 'p_patch': res.$1, 'p_reason': res.$2}),
        success: 'Channel diperbarui');
    if (ok) _reload();
  }

  Future<void> _export(J c) async {
    final res = await showDialog<(DateTime, DateTime, String)>(context: context, builder: (_) => _ExportDialog(channel: c));
    if (res == null || !mounted) return;
    final (from, to, reason) = res;
    final r = await runAction<Map<String, dynamic>>(
      context,
      ref,
      () => ref.read(apiProvider).rpcMap('chat_export', {
        'p_channel': c['id'],
        'p_from': from.toUtc().toIso8601String(),
        'p_to': to.add(const Duration(days: 1)).toUtc().toIso8601String(),
        'p_reason': reason,
      }),
    );
    if (r == null || !mounted) return;
    final data = r['data'];
    final count = (jm(data)['messages'] as List? ?? const []).length;
    final base = 'chat-${str(c['name'], shortId(c['id'])).replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')}-${isoDate(from)}_${isoDate(to)}';
    downloadText('$base.json', jsonEncode(data));
    downloadText('$base.manifest.txt',
        'COMEN chat export\nchannel: ${c['id']}\nfrom: ${isoDate(from)}\nto: ${isoDate(to)}\nmessages: $count\nmanifest_sha256 (server): ${r['manifest_sha256']}\nexported_at: ${DateTime.now().toUtc().toIso8601String()}\n',
        mime: 'text/plain');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.verified_rounded, color: Brand.green, size: 40),
        title: const Text('Export selesai'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$count pesan diunduh ($base.json) beserta manifest. Aksi ini tercatat di security events.'),
            const SizedBox(height: 12),
            const GroupLabel('Manifest SHA-256 (server)'),
            Row(children: [
              Expanded(child: MonoText(str(r['manifest_sha256']), size: 11)),
              CopyButton(str(r['manifest_sha256'], '')),
            ]),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup'))],
      ),
    );
  }
}

class _ChannelDialog extends StatefulWidget {
  const _ChannelDialog({required this.channel});
  final J channel;
  @override
  State<_ChannelDialog> createState() => _ChannelDialogState();
}

class _ChannelDialogState extends State<_ChannelDialog> {
  late final _name = TextEditingController(text: str(widget.channel['name'], ''));
  final _topic = TextEditingController();
  late final _ret = TextEditingController(text: '${widget.channel['retention_days'] ?? 2555}');
  bool _setTopic = false;
  final _reason = TextEditingController();

  Map<String, dynamic> get _patch {
    final p = <String, dynamic>{};
    final name = _name.text.trim();
    if (name.isNotEmpty && name != str(widget.channel['name'], '')) p['name'] = name;
    if (_setTopic) p['topic'] = _topic.text.trim().isEmpty ? null : _topic.text.trim();
    final ret = int.tryParse(_ret.text.trim());
    if (ret != null && ret != widget.channel['retention_days']) p['retention_days'] = ret;
    return p;
  }

  @override
  Widget build(BuildContext context) {
    final ret = int.tryParse(_ret.text.trim());
    final retOk = ret != null && ret >= 30;
    final ok = retOk && _patch.isNotEmpty && _reason.text.trim().length >= 5;
    return AlertDialog(
      title: const Text('Ubah channel'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _name, onChanged: (_) => setState(() {}), maxLength: 120, decoration: const InputDecoration(labelText: 'Nama channel')),
            const SizedBox(height: 8),
            LabeledSwitch(label: 'Ganti topik', subtitle: 'Topik saat ini tidak dimuat; aktifkan untuk menimpa', value: _setTopic, onChanged: (v) => setState(() => _setTopic = v)),
            if (_setTopic)
              TextField(controller: _topic, onChanged: (_) => setState(() {}), maxLength: 500, maxLines: 2, decoration: const InputDecoration(labelText: 'Topik baru (kosong = hapus)')),
            const SizedBox(height: 12),
            TextField(
              controller: _ret,
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Retensi pesan (hari)',
                helperText: 'Minimal 30 · default 2555 (±7 tahun)',
                errorText: retOk ? null : 'Minimal 30 hari',
                suffixText: 'hari',
              ),
            ),
            if (widget.channel['legal_hold'] == true) ...[
              const SizedBox(height: 8),
              const InfoBanner(message: 'Legal hold aktif — retensi tidak dijalankan sampai hold dilepas.', color: Brand.purple, icon: Icons.gavel_rounded),
            ],
            const SizedBox(height: 12),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: ok ? () => Navigator.pop(context, (_patch, _reason.text.trim())) : null, child: const Text('Simpan')),
      ],
    );
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.channel});
  final J channel;
  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 30));
  DateTime _to = DateTime.now();
  final _reason = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final ok = !_to.isBefore(_from) && _reason.text.trim().length >= 5;
    return AlertDialog(
      title: Text('Export ${str(widget.channel['name'], 'channel')}'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const InfoBanner(
            message: 'Transcript berisi isi pesan terdekripsi. Dibatasi 3 export/jam dan dicatat sebagai security event (warning).',
            color: Brand.amber,
            icon: Icons.warning_amber_rounded,
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: DateField(label: 'Dari', value: _from, clearable: false, last: DateTime.now(), onChanged: (d) => setState(() => _from = d ?? _from))),
            const SizedBox(width: 12),
            Expanded(child: DateField(label: 'Sampai (inklusif)', value: _to, clearable: false, last: DateTime.now(), onChanged: (d) => setState(() => _to = d ?? _to))),
          ]),
          if (_to.isBefore(_from)) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Tanggal akhir sebelum tanggal awal', style: TextStyle(color: Brand.red))),
          const SizedBox(height: 12),
          ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: ok ? () => Navigator.pop(context, (DateTime(_from.year, _from.month, _from.day), DateTime(_to.year, _to.month, _to.day), _reason.text.trim())) : null,
          icon: const Icon(Icons.download_rounded),
          label: const Text('Export'),
        ),
      ],
    );
  }
}
