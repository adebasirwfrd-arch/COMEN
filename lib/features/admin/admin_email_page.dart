import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_settings_page.dart' show loadSetting;
import 'admin_widgets.dart';

/// Katalog template email COMEN (BLUEPRINT3 §17).
const emailTemplates = <int, String>{
  1001: 'Registration Received', 1002: 'Needs Info', 1003: 'ASL Approved', 1004: 'ASL Conditional', 1005: 'Vendor Rejected',
  1006: 'ASL Expiry', 1007: 'Account Invite',
  2001: 'Task Generated', 2002: 'Reminder', 2003: 'Overdue', 2004: 'Submitted (ke reviewer)', 2005: 'Approved', 2006: 'Revision',
  2007: 'Rejected', 2008: 'File Issue', 2009: 'Doc Expiry', 2010: 'Daily Digest', 2011: 'Review SLA', 2012: 'Upload Link Missing (Admin)',
  2013: 'Email Confirmation Pending', 2014: 'Manual Reminder (Ingatkan)',
  3001: 'Incident High/Critical', 3002: 'Incident Report Overdue', 3003: 'Critical Finding', 3004: 'Stop-Work', 3005: 'Subcon Approval Request',
  4001: 'Awarded', 4002: 'MoM Ready to Sign', 4003: 'Pre-Mob Complete', 4004: 'Go-Live', 4005: 'Contract Expiry 60d', 4006: 'Demob',
  4007: 'OPR Complete', 4008: 'Closed',
  5001: 'Weekly KPI', 5002: 'Monthly Report Reminder',
  6001: 'Unread Digest (tanpa isi)', 6002: 'Urgent Message (tanpa isi)', 6003: 'Announcement Wajib Dibaca',
  7001: 'New User Pending (Admin)', 7002: 'New Device Login', 7003: 'Account Approved', 7004: 'Account Suspended',
  7005: 'Security Alert (Admin)', 7006: 'Daily Audit Anchor (Admin)', 7007: 'Role Changed', 7008: 'Account Rejected',
};
const _templateGroups = <int, String>{1: 'Onboarding', 2: 'Task', 3: 'Operasi HSE', 4: 'Kontrak', 5: 'Digest', 6: 'Chat', 7: 'Keamanan'};

String templateLabel(dynamic id) {
  final n = id is int ? id : int.tryParse('$id');
  return '#$id · ${emailTemplates[n] ?? 'Template'}';
}

(Color, String) _outboxStyle(String? s) => switch (s) {
      'queued' => (Brand.blue, 'Antri'),
      'sending' => (Brand.cyan, 'Mengirim'),
      'sent' => (Brand.green, 'Terkirim'),
      'failed' => (Brand.red, 'Gagal'),
      'skipped' => (Brand.grey, 'Dilewati'),
      _ => (Brand.grey, s ?? '-'),
    };

class AdminEmailPage extends ConsumerStatefulWidget {
  const AdminEmailPage({super.key});
  @override
  ConsumerState<AdminEmailPage> createState() => _AdminEmailPageState();
}

class _AdminEmailPageState extends ConsumerState<AdminEmailPage> {
  String _tab = 'outbox';
  String? _status = 'failed';
  String _q = '';
  final _selected = <int>{};
  late Future<(List<J>, Map<String, J>)> _outbox = _loadOutbox();
  late Future<J?> _map = loadSetting(ref, 'brevo_template_map');

  Future<(List<J>, Map<String, J>)> _loadOutbox() async {
    final rows = await ref.read(apiProvider).select('notification_outbox', Cols.outbox, build: (q) {
      final f = _status == null ? q : q.eq('status', _status!);
      return f.order('id', ascending: false).limit(300);
    });
    final profiles = await loadProfilesByIds(ref, rows.map((r) => r['to_user']));
    return (rows, profiles);
  }

  void _reloadOutbox() => setState(() {
        _selected.clear();
        _outbox = _loadOutbox();
      });

  @override
  Widget build(BuildContext context) {
    return AdminScaffold(
      title: 'Email & Template',
      subtitle: 'Antrian notification outbox (Brevo) dan pemetaan template COMEN → Brevo',
      actions: [
        OutlinedButton.icon(
          onPressed: () => _tab == 'outbox' ? _reloadOutbox() : setState(() => _map = loadSetting(ref, 'brevo_template_map')),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Muat ulang'),
        ),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'outbox', label: Text('Outbox'), icon: Icon(Icons.outbox_rounded, size: 18)),
              ButtonSegment(value: 'templates', label: Text('Template Brevo'), icon: Icon(Icons.dashboard_customize_outlined, size: 18)),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
        ),
        const SizedBox(height: 16),
        if (_tab == 'outbox') _outboxView() else _templatesView(),
      ]),
    );
  }

  // ─────────── Outbox ───────────
  Widget _outboxView() => AsyncView<(List<J>, Map<String, J>)>(
        future: _outbox,
        onRetry: _reloadOutbox,
        builder: (context, data) {
          final (rows, profiles) = data;
          final q = _q.toLowerCase();
          String recipient(J r) => str(r['to_email'], str(profiles[r['to_user']]?['email'], shortId(r['to_user'])));
          final list = rows
              .where((r) => q.isEmpty || '${recipient(r)} ${r['template_id']} ${templateLabel(r['template_id'])} ${r['dedupe_key'] ?? ''} ${r['last_error'] ?? ''}'.toLowerCase().contains(q))
              .toList();
          final failed = list.where((r) => r['status'] == 'failed').map((r) => (r['id'] as num).toInt()).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const InfoBanner(
              message: 'Kirim ulang hanya untuk status Gagal (admin_retry_outbox). Batalkan antrian & kirim email uji belum tersedia di backend — tidak ditampilkan.',
              icon: Icons.info_outline_rounded,
            ),
            const SizedBox(height: 16),
            TableCard(
              title: 'Notification outbox',
              subtitle: 'Maks 300 baris terbaru per filter · dikirim cron comen-notify-dispatch tiap menit',
              icon: Icons.outbox_rounded,
              count: list.length,
              trailing: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Brand.red),
                onPressed: (_selected.isEmpty && failed.isEmpty) ? null : () => _retry(_selected.isEmpty ? failed : _selected.toList()),
                icon: const Icon(Icons.replay_rounded, size: 18),
                label: Text(_selected.isEmpty ? 'Kirim ulang semua gagal (${failed.length})' : 'Kirim ulang ${_selected.length} terpilih'),
              ),
              toolbar: [
                AdminSearchField(hint: 'Cari penerima / template / error', onChanged: (v) => setState(() => _q = v)),
                Wrap(spacing: 6, children: [
                  for (final s in const [null, 'failed', 'queued', 'sending', 'sent', 'skipped'])
                    ChoiceChip(
                      label: Text(s == null ? 'Semua' : _outboxStyle(s).$2),
                      selected: _status == s,
                      onSelected: (_) {
                        _status = s;
                        _reloadOutbox();
                      },
                    ),
                ]),
              ],
              child: DataList(
                empty: _status == 'failed' ? 'Tidak ada email gagal 🎉' : 'Tidak ada email',
                columns: const ['', 'ID', 'Template', 'Penerima', 'Status', 'Percobaan', 'Error', 'Waktu'],
                onTap: (i) => _detail(list[i], recipient(list[i])),
                rows: [
                  for (final r in list)
                    [
                      r['status'] == 'failed'
                          ? Checkbox(
                              value: _selected.contains((r['id'] as num).toInt()),
                              onChanged: (v) => setState(() => v == true ? _selected.add((r['id'] as num).toInt()) : _selected.remove((r['id'] as num).toInt())),
                            )
                          : const SizedBox(width: 40),
                      MonoText('${r['id']}', size: 12),
                      CellText(templateLabel(r['template_id']), subtitle: r['channel'] == 'push' ? 'Push' : 'Email', maxWidth: 240),
                      CellText(recipient(r), subtitle: profiles[r['to_user']]?['full_name'] as String?, maxWidth: 240),
                      StatusBadge(_outboxStyle(r['status'] as String?).$1, _outboxStyle(r['status'] as String?).$2),
                      Text('${r['attempts'] ?? 0}'),
                      CellText(str(r['last_error']), maxWidth: 260),
                      CellText(fmtRelative(r['sent_at'] ?? r['created_at']),
                        subtitle: r['status'] == 'queued' ? 'kirim ${fmtRelative(r['send_after'])}' : fmtDateTime(r['created_at']),
                      ),
                    ],
                ],
              ),
            ),
          ]);
        },
      );

  Future<void> _retry(List<int> ids) async {
    final n = await _withReasonResult(
      title: 'Kirim ulang ${ids.length} email',
      message: 'Email berstatus Gagal akan diantrikan ulang (percobaan direset ke 0).',
      action: (r) => ref.read(apiProvider).rpc('admin_retry_outbox', {'p_ids': ids, 'p_reason': r}),
    );
    if (n == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n email diantrikan ulang')));
    _reloadOutbox();
  }

  Future<dynamic> _withReasonResult({required String title, String? message, required Future<dynamic> Function(String) action}) async {
    final r = await showReasonDialog(context, title: title, message: message, confirmLabel: 'Kirim ulang');
    if (r == null || !mounted) return null;
    return runAction<dynamic>(context, ref, () => action(r));
  }

  void _detail(J r, String recipient) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Outbox #${r['id']}'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                KeyValueGrid([
                  ('Template', Text(templateLabel(r['template_id']))),
                  ('Kanal', Text(str(r['channel']))),
                  ('Penerima', SelectableText(recipient)),
                  ('Status', StatusBadge(_outboxStyle(r['status'] as String?).$1, _outboxStyle(r['status'] as String?).$2)),
                  ('Percobaan', Text('${r['attempts'] ?? 0}')),
                  ('Dibuat', Text(fmtDateTime(r['created_at']))),
                  ('Kirim setelah', Text(fmtDateTime(r['send_after']))),
                  ('Terkirim', Text(fmtDateTime(r['sent_at']))),
                  ('Provider msg id', MonoText(str(r['provider_msg_id']), size: 12)),
                  ('Dedupe key', MonoText(str(r['dedupe_key']), size: 12)),
                ], minItemWidth: 220),
                if (r['last_error'] != null) ...[
                  const SizedBox(height: 16),
                  const GroupLabel('Error terakhir'),
                  JsonBlock(str(r['last_error']), maxHeight: 200),
                ],
              ]),
            ),
          ),
          actions: [
            if (r['status'] == 'failed')
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _retry([(r['id'] as num).toInt()]);
                },
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Kirim ulang'),
              ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
          ],
        ),
      );

  // ─────────── Template map ───────────
  Widget _templatesView() {
    final s = sessionOf(ref);
    if (!(s?.can('admin.templates.manage') ?? false)) return const PermissionNote('admin.templates.manage', what: 'mengelola template email');
    return AsyncView<J?>(
      future: _map,
      onRetry: () => setState(() => _map = loadSetting(ref, 'brevo_template_map')),
      builder: (context, setting) {
        if (setting == null) return const SectionCard(child: EmptyState(icon: Icons.lock_outline_rounded, title: 'Setting brevo_template_map tidak terlihat'));
        return _TemplateMapEditor(
          key: ValueKey(setting['updated_at']),
          setting: setting,
          onSaved: () => setState(() => _map = loadSetting(ref, 'brevo_template_map')),
        );
      },
    );
  }
}

class _TemplateMapEditor extends ConsumerStatefulWidget {
  const _TemplateMapEditor({super.key, required this.setting, required this.onSaved});
  final J setting;
  final VoidCallback onSaved;
  @override
  ConsumerState<_TemplateMapEditor> createState() => _TemplateMapEditorState();
}

class _TemplateMapEditorState extends ConsumerState<_TemplateMapEditor> {
  late final Map<String, dynamic> _orig = jm(widget.setting['value']);
  late final Map<String, TextEditingController> _ctl = {
    for (final k in {..._orig.keys, ...emailTemplates.keys.map((e) => '$e')}) k: TextEditingController(text: _orig[k]?.toString() ?? ''),
  };
  String _q = '';
  bool _onlyUnmapped = false;

  static final _idRe = RegExp(r'^[1-9][0-9]*$');

  bool _valid(String v) => v.isEmpty || _idRe.hasMatch(v);
  bool get _dirty => _ctl.entries.any((e) => e.value.text.trim() != (_orig[e.key]?.toString() ?? ''));
  bool get _allValid => _ctl.values.every((c) => _valid(c.text.trim()));

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final value = {for (final e in _ctl.entries) e.key: e.value.text.trim().isEmpty ? null : int.parse(e.value.text.trim())};
    final changed = _ctl.entries.where((e) => e.value.text.trim() != (_orig[e.key]?.toString() ?? '')).map((e) => '#${e.key}').toList();
    final ok = await withReason(context, ref,
        title: 'Simpan pemetaan template',
        message: 'Perubahan: ${changed.join(', ')}',
        success: 'Pemetaan template disimpan',
        action: (r) => ref.read(apiProvider).rpc('admin_upsert_setting', {'p_key': 'brevo_template_map', 'p_value': value, 'p_reason': r}));
    if (ok) widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final keys = _ctl.keys.toList()..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    final unmapped = keys.where((k) => !_idRe.hasMatch(_ctl[k]!.text.trim())).length;
    final q = _q.toLowerCase();
    final visible = keys.where((k) {
      if (_onlyUnmapped && _idRe.hasMatch(_ctl[k]!.text.trim())) return false;
      return q.isEmpty || templateLabel(k).toLowerCase().contains(q);
    }).toList();
    final groups = <String, List<String>>{};
    for (final k in visible) {
      groups.putIfAbsent(_templateGroups[(int.tryParse(k) ?? 0) ~/ 1000] ?? 'Lainnya', () => []).add(k);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ResponsiveGrid(minItemWidth: 220, children: [
        StatCard(label: 'Template', value: '${keys.length}', icon: Icons.mail_outline_rounded),
        StatCard(label: 'Sudah dipetakan', value: '${keys.length - unmapped}', icon: Icons.check_circle_outline_rounded, color: Brand.green),
        StatCard(
          label: 'Belum dipetakan',
          value: '$unmapped',
          icon: Icons.warning_amber_rounded,
          color: unmapped == 0 ? Brand.green : Brand.amber,
          caption: unmapped == 0 ? 'Siap go-live' : 'Email template ini tidak akan terkirim',
          onTap: () => setState(() => _onlyUnmapped = !_onlyUnmapped),
        ),
      ]),
      const SizedBox(height: 16),
      TableCard(
        title: 'Pemetaan COMEN → Brevo',
        subtitle: 'Isi ID template Brevo (angka). Kosong = belum dipetakan. Diperbarui ${fmtRelative(widget.setting['updated_at'])}.',
        icon: Icons.dashboard_customize_outlined,
        trailing: FilledButton.icon(
          onPressed: _dirty && _allValid ? _save : null,
          icon: const Icon(Icons.save_rounded, size: 18),
          label: const Text('Simpan'),
        ),
        toolbar: [
          AdminSearchField(hint: 'Cari ID / nama template', onChanged: (v) => setState(() => _q = v)),
          FilterChip(label: const Text('Hanya yang belum dipetakan'), selected: _onlyUnmapped, onSelected: (v) => setState(() => _onlyUnmapped = v)),
          if (_dirty) const StatusBadge(Brand.amber, 'Ada perubahan belum disimpan', icon: Icons.edit_rounded),
        ],
        child: visible.isEmpty
            ? const EmptyState(icon: Icons.search_off_rounded, title: 'Tidak ada template cocok')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final g in groups.entries) ...[
                  GroupLabel(g.key),
                  ResponsiveGrid(minItemWidth: 320, spacing: 12, children: [
                    for (final k in g.value) _tile(k),
                  ]),
                  const SizedBox(height: 16),
                ],
              ]),
      ),
    ]);
  }

  Widget _tile(String k) {
    final c = _ctl[k]!;
    final v = c.text.trim();
    final mapped = _idRe.hasMatch(v);
    final changed = v != (_orig[k]?.toString() ?? '');
    return Row(children: [
      Icon(mapped ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 18, color: mapped ? Brand.green : Brand.amber),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MonoText('#$k', size: 12),
          Text(emailTemplates[int.tryParse(k)] ?? 'Template tidak dikenal', maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
      SizedBox(
        width: 120,
        child: TextField(
          controller: c,
          onChanged: (_) => setState(() {}),
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'ID Brevo',
            errorText: _valid(v) ? null : 'Angka',
            suffixIcon: changed ? const Icon(Icons.edit_rounded, size: 14, color: Brand.amber) : null,
          ),
        ),
      ),
    ]);
  }
}
