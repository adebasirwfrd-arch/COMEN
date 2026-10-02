import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

const dangerSettingKeys = {'read_only_mode', 'global_sessions_valid_after', 'email_otp_enabled', 'password_login_enabled'};
const _groups = <String, (String, IconData, Color)>{
  'admin.settings.manage': ('Aturan bisnis', Icons.tune_rounded, Brand.blue),
  'admin.templates.manage': ('Email & template', Icons.outgoing_mail, Brand.cyan),
  'admin.security.manage': ('Keamanan', Icons.security_rounded, Brand.purple),
  'admin.system.danger': ('Danger Zone (read-only di sini)', Icons.warning_amber_rounded, Brand.red),
};

String settingPreview(dynamic v) {
  if (v is Map) return '{${v.length} kunci}';
  if (v is List) return v.join(', ');
  if (v is bool) return v ? 'true' : 'false';
  return v?.toString() ?? 'null';
}

Future<J?> loadSetting(WidgetRef ref, String key) async {
  final r = await ref.read(apiProvider).select('app_settings', 'key,value,is_public,required_permission,description,updated_by,updated_at', build: (q) => q.eq('key', key));
  return r.firstOrNull;
}

/// Dialog ubah nilai setting (tipe mengikuti nilai saat ini) + alasan → admin_upsert_setting.
Future<bool> editSetting(BuildContext context, WidgetRef ref, J setting) async {
  final lookups = setting['key'] == 'mfa_required_roles' ? await ref.read(adminLookupsProvider.future) : null;
  if (!context.mounted) return false;
  final res = await showDialog<(dynamic, String)>(context: context, builder: (_) => _SettingDialog(setting: setting, roles: lookups?.roles));
  if (res == null || !context.mounted) return false;
  return adminRun(context, ref, () => ref.read(apiProvider).rpc('admin_upsert_setting', {'p_key': setting['key'], 'p_value': res.$1, 'p_reason': res.$2}),
      success: 'Setting ${setting['key']} disimpan');
}

class AdminSettingsPage extends ConsumerStatefulWidget {
  const AdminSettingsPage({super.key});
  @override
  ConsumerState<AdminSettingsPage> createState() => _AdminSettingsPageState();
}

class _AdminSettingsPageState extends ConsumerState<AdminSettingsPage> {
  String _tab = 'settings';
  late Future<List<J>> _settings = _loadSettings();
  late Future<List<J>> _holidays = _loadHolidays();
  late Future<List<J>> _geozones = _loadGeozones();
  String _q = '';
  String _year = 'next';

  Future<List<J>> _loadSettings() =>
      ref.read(apiProvider).select('app_settings', 'key,value,is_public,required_permission,description,updated_by,updated_at', build: (q) => q.order('key'));
  Future<List<J>> _loadHolidays() => ref.read(apiProvider).select('holidays', 'id,holiday_date,geozone,name', build: (q) => q.order('holiday_date'));
  Future<List<J>> _loadGeozones() => ref.read(apiProvider).select('geozones', 'code,name,review_mailbox,timezone,active', build: (q) => q.order('code'));

  void _reload() {
    ref.invalidate(adminLookupsProvider);
    setState(() {
      _settings = _loadSettings();
      _holidays = _loadHolidays();
      _geozones = _loadGeozones();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    return AdminScaffold(
      title: 'Rules & Settings',
      subtitle: 'Konfigurasi aplikasi, kalender hari libur, dan geozone · setiap perubahan wajib alasan',
      actions: [OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang'))],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (s?.can('admin.system.danger') ?? false) ...[
          DangerCard(
            title: 'Read-only mode',
            description: 'Semua mutasi ditolak kecuali pemegang admin.system.danger. Gunakan saat insiden atau migrasi.',
            icon: Icons.lock_clock_rounded,
            status: s!.readOnly ? const StatusBadge(Brand.red, 'AKTIF') : const StatusBadge(Brand.green, 'Nonaktif'),
            action: Switch(
              value: s.readOnly,
              activeTrackColor: Brand.red,
              onChanged: (v) async {
                final ok = await withDanger(context, ref,
                    title: v ? 'Aktifkan read-only mode' : 'Matikan read-only mode',
                    message: v ? 'Seluruh pengguna tidak bisa mengubah data sampai mode ini dimatikan.' : 'Mutasi data akan diizinkan kembali untuk semua pengguna.',
                    success: v ? 'Read-only mode aktif' : 'Read-only mode dimatikan',
                    action: (r) => ref.read(apiProvider).rpc('admin_set_read_only', {'p_on': v, 'p_reason': r}));
                if (ok) ref.read(sessionProvider.notifier).refresh();
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'settings', label: Text('Pengaturan'), icon: Icon(Icons.settings_suggest_rounded, size: 18)),
              ButtonSegment(value: 'holidays', label: Text('Hari libur'), icon: Icon(Icons.event_rounded, size: 18)),
              ButtonSegment(value: 'geozones', label: Text('Geozone'), icon: Icon(Icons.map_outlined, size: 18)),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
        ),
        const SizedBox(height: 16),
        switch (_tab) {
          'holidays' => _holidaysView(),
          'geozones' => _geozonesView(),
          _ => _settingsView(),
        },
      ]),
    );
  }

  Widget _settingsView() => AsyncView<List<J>>(
        future: _settings,
        onRetry: _reload,
        builder: (context, all) {
          final s = sessionOf(ref);
          final q = _q.toLowerCase();
          final list = all.where((x) => q.isEmpty || '${x['key']} ${x['description'] ?? ''}'.toLowerCase().contains(q)).toList();
          final byGroup = <String, List<J>>{};
          for (final x in list) {
            byGroup.putIfAbsent(x['required_permission'] as String, () => []).add(x);
          }
          final order = [..._groups.keys.where(byGroup.containsKey), ...byGroup.keys.where((k) => !_groups.containsKey(k))];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              AdminSearchField(hint: 'Cari key / deskripsi', onChanged: (v) => setState(() => _q = v)),
              const Spacer(),
              StatusBadge(Brand.grey, '${all.length} setting terlihat', icon: Icons.visibility_outlined),
            ]),
            const SizedBox(height: 16),
            if (list.isEmpty) const SectionCard(child: EmptyState(icon: Icons.search_off_rounded, title: 'Tidak ada setting cocok')),
            for (final g in order) ...[
              SectionCard(
                title: _groups[g]?.$1 ?? g,
                subtitle: 'Permission: $g',
                icon: _groups[g]?.$2 ?? Icons.settings_rounded,
                child: Column(children: [
                  for (final x in byGroup[g]!)
                    _SettingTile(
                      setting: x,
                      canEdit: (s?.can(g) ?? false) && !dangerSettingKeys.contains(x['key']),
                      danger: dangerSettingKeys.contains(x['key']),
                      onEdit: () async {
                        if (x['key'] == 'brevo_template_map') {
                          context.go('/admin/email');
                          return;
                        }
                        if (await editSetting(context, ref, x)) _reload();
                      },
                    ),
                ]),
              ),
              const SizedBox(height: 16),
            ],
          ]);
        },
      );

  Widget _holidaysView() => AsyncView<List<J>>(
        future: _holidays,
        onRetry: _reload,
        builder: (context, all) {
          final now = DateTime.now().year;
          final list = all.where((h) {
            final y = parseDate(h['holiday_date'])?.year;
            return switch (_year) { 'this' => y == now, 'next' => y == now + 1, _ => true };
          }).toList();
          return TableCard(
            title: 'Kalender hari libur',
            subtitle: 'Dipakai untuk perhitungan hari kerja (due revisi, SLA review). Geozone kosong = berlaku semua.',
            icon: Icons.event_rounded,
            count: list.length,
            trailing: FilledButton.tonalIcon(onPressed: () => _editHoliday(null), icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Tambah')),
            toolbar: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'this', label: Text('$now')),
                  ButtonSegment(value: 'next', label: Text('${now + 1}')),
                  const ButtonSegment(value: 'all', label: Text('Semua')),
                ],
                selected: {_year},
                onSelectionChanged: (v) => setState(() => _year = v.first),
              ),
              if (_year == 'next' && list.isEmpty) const StatusBadge(Brand.amber, 'Belum ada data tahun depan (checklist go-live)', icon: Icons.warning_amber_rounded),
            ],
            child: DataList(
              empty: 'Belum ada hari libur',
              columns: const ['Tanggal', 'Hari', 'Nama', 'Geozone', ''],
              rows: [
                for (final h in list)
                  [
                    Text(fmtDate(h['holiday_date']), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(_weekday(parseDate(h['holiday_date']))),
                    Text(str(h['name'])),
                    h['geozone'] == null ? const StatusBadge(Brand.blue, 'Semua') : StatusBadge(Brand.navy, str(h['geozone'])),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'Ubah', onPressed: () => _editHoliday(h), icon: const Icon(Icons.edit_outlined, size: 20)),
                      IconButton(
                        tooltip: 'Hapus',
                        icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Brand.red),
                        onPressed: () async {
                          final ok = await withReason(context, ref,
                              title: 'Hapus hari libur',
                              message: '${h['name']} (${fmtDate(h['holiday_date'])}) akan dihapus dari kalender.',
                              confirmLabel: 'Hapus',
                              destructive: true,
                              success: 'Hari libur dihapus',
                              action: (r) => ref.read(apiProvider).rpc('admin_delete_holiday', {'p_id': h['id'], 'p_reason': r}));
                          if (ok) _reload();
                        },
                      ),
                    ]),
                  ],
              ],
            ),
          );
        },
      );

  static String _weekday(DateTime? d) => d == null ? '-' : const ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'][d.weekday - 1];

  Future<void> _editHoliday(J? h) async {
    final geos = await _geozones.catchError((_) => <J>[]);
    if (!mounted) return;
    final res = await showDialog<(DateTime, String?, String, String)>(context: context, builder: (_) => _HolidayDialog(holiday: h, geozones: geos));
    if (res == null || !mounted) return;
    final ok = await adminRun(
        context,
        ref,
        () => ref.read(apiProvider).rpc('admin_upsert_holiday', {'p_id': h?['id'], 'p_date': isoDate(res.$1), 'p_geozone': res.$2, 'p_name': res.$3, 'p_reason': res.$4}),
        success: 'Hari libur disimpan');
    if (ok) _reload();
  }

  Widget _geozonesView() => AsyncView<List<J>>(
        future: _geozones,
        onRetry: _reload,
        builder: (context, list) => TableCard(
          title: 'Geozone',
          subtitle: 'Wilayah operasi · mailbox review & zona waktu per geozone',
          icon: Icons.map_outlined,
          count: list.length,
          trailing: FilledButton.tonalIcon(onPressed: () => _editGeozone(null), icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Tambah')),
          child: DataList(
            empty: 'Belum ada geozone',
            columns: const ['Kode', 'Nama', 'Mailbox review', 'Zona waktu', 'Status', ''],
            onTap: (i) => _editGeozone(list[i]),
            rows: [
              for (final g in list)
                [
                  MonoText(str(g['code']), size: 12),
                  Text(str(g['name'])),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(str(g['review_mailbox'])),
                    if (str(g['review_mailbox'], '').toLowerCase().endsWith('example.com')) ...[const SizedBox(width: 6), const StatusBadge(Brand.amber, 'Placeholder')],
                  ]),
                  Text(str(g['timezone'])),
                  BoolBadge(g['active'] == true, trueLabel: 'Aktif', falseLabel: 'Nonaktif'),
                  IconButton(tooltip: 'Ubah', onPressed: () => _editGeozone(g), icon: const Icon(Icons.edit_outlined, size: 20)),
                ],
            ],
          ),
        ),
      );

  Future<void> _editGeozone(J? g) async {
    final res = await showDialog<J>(context: context, builder: (_) => _GeozoneDialog(geozone: g));
    if (res == null || !mounted) return;
    final ok = await adminRun(context, ref, () => ref.read(apiProvider).rpc('admin_upsert_geozone', res), success: 'Geozone disimpan');
    if (ok) _reload();
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({required this.setting, required this.canEdit, required this.danger, required this.onEdit});
  final J setting;
  final bool canEdit, danger;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) {
    final v = setting['value'];
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              MonoText(str(setting['key']), size: 13),
              if (setting['is_public'] == true) const StatusBadge(Brand.grey, 'Publik', icon: Icons.public_rounded),
              if (v is String && v.toLowerCase().contains('example.com')) const StatusBadge(Brand.amber, 'Placeholder', icon: Icons.warning_amber_rounded),
            ]),
            if (setting['description'] != null) Text(str(setting['description']), style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
              child: Text(settingPreview(v), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 4),
            Text('Diperbarui ${fmtRelative(setting['updated_at'])}', style: t.labelSmall?.copyWith(color: Brand.grey)),
          ]),
        ),
        const SizedBox(width: 12),
        if (danger)
          TextButton.icon(onPressed: () => context.go('/admin/system'), icon: const Icon(Icons.lock_outline_rounded, size: 16), label: const Text('Danger Zone'))
        else if (canEdit)
          OutlinedButton.icon(onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 16), label: const Text('Ubah'))
        else
          const Tooltip(message: 'Butuh permission terkait', child: Icon(Icons.lock_outline_rounded, color: Brand.grey)),
      ]),
    );
  }
}

class _SettingDialog extends StatefulWidget {
  const _SettingDialog({required this.setting, this.roles});
  final J setting;
  final List<J>? roles;
  @override
  State<_SettingDialog> createState() => _SettingDialogState();
}

class _SettingDialogState extends State<_SettingDialog> {
  late final dynamic _orig = widget.setting['value'];
  late bool _bool = _orig == true;
  late final _text = TextEditingController(text: _orig is String || _orig is num ? _orig.toString() : prettyJson(_orig));
  late final Set<String> _roles = _orig is List ? {..._orig.map((e) => e.toString())} : <String>{};
  final _reason = TextEditingController();

  String get _key => widget.setting['key'] as String;
  bool get _isRoles => _key == 'mfa_required_roles' && widget.roles != null;

  (dynamic, String?) get _parsed {
    if (_isRoles) return (_roles.toList()..sort(), _roles.contains('super_admin') ? null : 'Wajib memuat super_admin');
    if (_orig is bool) return (_bool, null);
    final t = _text.text.trim();
    if (_orig is num) {
      final n = num.tryParse(t);
      return n == null ? (null, 'Harus angka') : (n, null);
    }
    if (_orig is String) return t.isEmpty ? (null, 'Tidak boleh kosong') : (t, null);
    try {
      final v = jsonDecode(t);
      if (_key == 'kpi_weights' && v is Map) {
        final sum = v.values.fold<num>(0, (a, b) => a + (b is num ? b : 0));
        if (sum != 100) return (v, 'Total bobot KPI harus 100 (saat ini $sum)');
      }
      return (v, null);
    } catch (_) {
      return (null, 'JSON tidak valid');
    }
  }

  @override
  Widget build(BuildContext context) {
    final (value, err) = _parsed;
    final ok = err == null && _reason.text.trim().length >= 5;
    final sec = widget.setting['required_permission'] == 'admin.security.manage';
    return AlertDialog(
      title: Text('Ubah $_key'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.setting['description'] != null) ...[Text(str(widget.setting['description'])), const SizedBox(height: 12)],
            if (sec) ...[
              const InfoBanner(message: 'Setting keamanan — membutuhkan verifikasi MFA (step-up).', color: Brand.purple, icon: Icons.verified_user_rounded),
              const SizedBox(height: 12),
            ],
            if (_isRoles)
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final r in widget.roles!)
                  FilterChip(
                    label: Text(str(r['name'])),
                    selected: _roles.contains(r['key']),
                    onSelected: r['key'] == 'super_admin' ? null : (v) => setState(() => v ? _roles.add(r['key'] as String) : _roles.remove(r['key'])),
                  ),
              ])
            else if (_orig is bool)
              LabeledSwitch(label: _bool ? 'Aktif (true)' : 'Nonaktif (false)', value: _bool, onChanged: (v) => setState(() => _bool = v))
            else
              TextField(
                controller: _text,
                onChanged: (_) => setState(() {}),
                maxLines: (_orig is Map || _orig is List || _orig == null) ? 12 : 1,
                keyboardType: _orig is num ? TextInputType.number : null,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(labelText: _orig is num ? 'Angka' : (_orig is String ? 'Teks' : 'JSON'), errorText: err),
              ),
            if (err != null && (_isRoles || _orig is bool)) ...[const SizedBox(height: 8), Text(err, style: const TextStyle(color: Brand.red))],
            const SizedBox(height: 12),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: ok ? () => Navigator.pop(context, (value, _reason.text.trim())) : null, child: const Text('Simpan')),
      ],
    );
  }
}

class _HolidayDialog extends StatefulWidget {
  const _HolidayDialog({this.holiday, required this.geozones});
  final J? holiday;
  final List<J> geozones;
  @override
  State<_HolidayDialog> createState() => _HolidayDialogState();
}

class _HolidayDialogState extends State<_HolidayDialog> {
  late DateTime? _date = parseDate(widget.holiday?['holiday_date']);
  late String? _geo = widget.holiday?['geozone'] as String?;
  late final _name = TextEditingController(text: str(widget.holiday?['name'], ''));
  final _reason = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final ok = _date != null && _name.text.trim().isNotEmpty && _reason.text.trim().length >= 5;
    return AlertDialog(
      title: Text(widget.holiday == null ? 'Tambah hari libur' : 'Ubah hari libur'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DateField(label: 'Tanggal *', value: _date, clearable: false, onChanged: (d) => setState(() => _date = d)),
          const SizedBox(height: 12),
          TextField(controller: _name, onChanged: (_) => setState(() {}), maxLength: 120, decoration: const InputDecoration(labelText: 'Nama *', counterText: '')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: _geo,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Geozone'),
            items: [const DropdownMenuItem(value: null, child: Text('Semua geozone')), for (final g in widget.geozones) DropdownMenuItem(value: g['code'] as String, child: Text('${g['code']} · ${g['name']}'))],
            onChanged: (v) => setState(() => _geo = v),
          ),
          const SizedBox(height: 12),
          ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: ok ? () => Navigator.pop(context, (_date!, _geo, _name.text.trim(), _reason.text.trim())) : null, child: const Text('Simpan')),
      ],
    );
  }
}

class _GeozoneDialog extends StatefulWidget {
  const _GeozoneDialog({this.geozone});
  final J? geozone;
  @override
  State<_GeozoneDialog> createState() => _GeozoneDialogState();
}

class _GeozoneDialogState extends State<_GeozoneDialog> {
  late final _code = TextEditingController(text: str(widget.geozone?['code'], ''));
  late final _name = TextEditingController(text: str(widget.geozone?['name'], ''));
  late final _mail = TextEditingController(text: str(widget.geozone?['review_mailbox'], ''));
  late final _tz = TextEditingController(text: str(widget.geozone?['timezone'], 'Asia/Jakarta'));
  late bool _active = widget.geozone?['active'] as bool? ?? true;
  final _reason = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final codeOk = RegExp(r'^[A-Za-z]{2,10}$').hasMatch(_code.text.trim());
    final mailOk = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_mail.text.trim());
    final ok = codeOk && mailOk && _name.text.trim().isNotEmpty && _tz.text.trim().isNotEmpty && _reason.text.trim().length >= 5;
    return AlertDialog(
      title: Text(widget.geozone == null ? 'Geozone baru' : 'Ubah geozone ${widget.geozone!['code']}'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _code,
            enabled: widget.geozone == null,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: 'Kode * (2–10 huruf)', errorText: _code.text.isEmpty || codeOk ? null : 'Hanya huruf, 2–10'),
          ),
          const SizedBox(height: 12),
          TextField(controller: _name, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Nama *')),
          const SizedBox(height: 12),
          TextField(
            controller: _mail,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: 'Mailbox review *', errorText: _mail.text.isEmpty || mailOk ? null : 'Email tidak valid'),
          ),
          const SizedBox(height: 12),
          TextField(controller: _tz, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Zona waktu IANA *', helperText: 'mis. Asia/Jakarta, Asia/Makassar')),
          const SizedBox(height: 8),
          LabeledSwitch(label: 'Aktif', value: _active, onChanged: (v) => setState(() => _active = v)),
          const SizedBox(height: 8),
          ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: ok
              ? () => Navigator.pop(context, <String, dynamic>{
                    'p_code': _code.text.trim().toUpperCase(),
                    'p_name': _name.text.trim(),
                    'p_review_mailbox': _mail.text.trim(),
                    'p_timezone': _tz.text.trim(),
                    'p_active': _active,
                    'p_reason': _reason.text.trim(),
                  })
              : null,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
