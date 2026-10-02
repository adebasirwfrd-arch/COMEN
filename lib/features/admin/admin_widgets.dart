import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web/web.dart' as web;
import '../../core/session/failure_handler.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;
J jm(dynamic v) => v == null ? <String, dynamic>{} : Map<String, dynamic>.from(v as Map);
List<J> jl(dynamic v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String shortId(dynamic id) {
  final s = id?.toString();
  if (s == null || s.isEmpty) return '-';
  return s.length > 8 ? s.substring(0, 8) : s;
}

String prettyJson(dynamic v) => const JsonEncoder.withIndent('  ').convert(v);
String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// Unduh teks sebagai file (Blob + anchor) — tidak ada data yang dikirim ke server.
void downloadText(String filename, String content, {String mime = 'application/json'}) {
  final blob = web.Blob(<JSAny>[content.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body?.append(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
}

// ─────────────────────────── Aksi ───────────────────────────
/// runAction untuk RPC VOID: true bila sukses.
Future<bool> adminRun(BuildContext context, WidgetRef ref, Future<dynamic> Function() fn, {String? success}) async {
  final r = await runAction<bool>(context, ref, () async {
    await fn();
    return true;
  }, success: success);
  return r == true;
}

/// showReasonDialog → runAction (alasan dikirim sebagai p_reason).
Future<bool> withReason(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  String? message,
  String confirmLabel = 'Simpan',
  String fieldLabel = 'Alasan',
  bool destructive = false,
  String? success,
  required Future<dynamic> Function(String reason) action,
}) async {
  final r = await showReasonDialog(context, title: title, message: message, confirmLabel: confirmLabel, fieldLabel: fieldLabel, destructive: destructive);
  if (r == null || !context.mounted) return false;
  return adminRun(context, ref, () => action(r), success: success);
}

/// Danger Zone: frasa "SAYA PAHAM" + alasan → runAction.
Future<bool> withDanger(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String message,
  String? success,
  required Future<dynamic> Function(String reason) action,
}) async {
  final r = await showConfirmPhraseDialog(context, title: title, message: message);
  if (r == null || !context.mounted) return false;
  return adminRun(context, ref, () => action(r), success: success);
}

// ─────────────────────────── Lookup bersama ───────────────────────────
Future<List<J>> _safe(Future<List<J>> f) async {
  try {
    return await f;
  } catch (_) {
    return const [];
  }
}

/// Profil per id (untuk menampilkan email/nama); kosong bila RLS menolak.
Future<Map<String, J>> loadProfilesByIds(WidgetRef ref, Iterable<dynamic> ids) async {
  final list = ids.whereType<String>().toSet().toList();
  if (list.isEmpty) return {};
  final r = await _safe(ref.read(apiProvider).select('profiles', Cols.profiles, build: (q) => q.inFilter('id', list).limit(list.length)));
  return {for (final p in r) p['id'] as String: p};
}

class AdminLookups {
  AdminLookups({required this.roles, required this.contractors, required this.contracts, required this.geozones, required this.permissions, required this.rolePerms, required this.rolePermsLoaded});
  final List<J> roles, contractors, contracts, geozones;
  final Map<String, J> permissions;
  final Map<String, Set<String>> rolePerms;
  final bool rolePermsLoaded;

  J? roleById(String? id) => roles.where((r) => r['id'] == id).firstOrNull;
  J? roleByKey(String? key) => roles.where((r) => r['key'] == key).firstOrNull;
  String roleName(String? id) => str(roleById(id)?['name'], shortId(id));
  String contractorName(String? id) => id == null ? '-' : str(contractors.where((c) => c['id'] == id).firstOrNull?['legal_name'], shortId(id));
  String contractLabel(String? id) {
    if (id == null) return '-';
    final k = contracts.where((c) => c['id'] == id).firstOrNull;
    return k == null ? shortId(id) : '${str(k['contract_no'])} · ${str(k['title'])}';
  }

  String scopeLabel(String? type, String? id) => switch (type) {
        null || 'global' => 'Global',
        'geozone' => 'Geozone $id',
        'contract' => 'Kontrak ${contractLabel(id)}',
        'contractor' => 'Contractor ${contractorName(id)}',
        _ => '$type ${shortId(id)}',
      };

  /// Anti-eskalasi (cermin _assert_can_grant): semua permission non-contractor role harus Anda miliki secara global.
  List<J> grantableRoles(SessionState? s) => roles.where((r) {
        if (r['key'] == 'super_admin') return false;
        if (s == null || !rolePermsLoaded) return true;
        final perms = rolePerms[r['id']] ?? const <String>{};
        return perms.every((p) {
          final pm = permissions[p];
          if (pm == null) return p != '*';
          return pm['audience'] == 'contractor' || s.globalPermissions.contains(p);
        });
      }).toList();
}

final adminLookupsProvider = FutureProvider.autoDispose<AdminLookups>((ref) async {
  final api = ref.read(apiProvider);
  final r = await Future.wait([
    _safe(api.select('roles', 'id,key,name,description,is_system,is_wfrd,created_at,updated_at', build: (q) => q.order('name'))),
    _safe(api.select('contractors', Cols.contractors, build: (q) => q.order('legal_name').limit(1000))),
    _safe(api.select('contracts', 'id,contract_no,title,contractor_id,status,geozone', build: (q) => q.order('contract_seq', ascending: false).limit(1000))),
    _safe(api.select('geozones', 'code,name,review_mailbox,timezone,active', build: (q) => q.order('code'))),
    _safe(api.select('permissions', 'key,module,description,risk_level,audience', build: (q) => q.order('module').order('key'))),
  ]);
  List<J>? rp;
  try {
    rp = await api.select('role_permissions', 'role_id,permission_key');
  } catch (_) {
    rp = null;
  }
  final rolePerms = <String, Set<String>>{};
  for (final x in rp ?? const <J>[]) {
    rolePerms.putIfAbsent(x['role_id'] as String, () => <String>{}).add(x['permission_key'] as String);
  }
  return AdminLookups(
    roles: r[0],
    contractors: r[1],
    contracts: r[2],
    geozones: r[3],
    permissions: {for (final p in r[4]) p['key'] as String: p},
    rolePerms: rolePerms,
    rolePermsLoaded: rp != null,
  );
});

// ─────────────────────────── Widget ───────────────────────────
class AdminSearchField extends StatefulWidget {
  const AdminSearchField({super.key, required this.onChanged, this.hint = 'Cari…', this.width = 300, this.debounce = const Duration(milliseconds: 300)});
  final ValueChanged<String> onChanged;
  final String hint;
  final double width;
  final Duration debounce;
  @override
  State<AdminSearchField> createState() => _AdminSearchFieldState();
}

class _AdminSearchFieldState extends State<AdminSearchField> {
  final _ctl = TextEditingController();
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _t?.cancel();
    _t = Timer(widget.debounce, () => widget.onChanged(v.trim()));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width < 600 ? double.infinity : widget.width;
    return SizedBox(
      width: w,
      child: TextField(
        controller: _ctl,
        onChanged: _changed,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon: _ctl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    _ctl.clear();
                    _changed('');
                  },
                ),
        ),
      ),
    );
  }
}

/// Kartu tabel: judul + toolbar (search/filter) + isi.
class TableCard extends StatelessWidget {
  const TableCard({super.key, this.title, this.subtitle, this.icon, this.toolbar = const [], this.trailing, required this.child, this.count});
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> toolbar;
  final Widget? trailing;
  final Widget child;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: title,
      subtitle: subtitle,
      icon: icon,
      trailing: count == null && trailing == null
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: [
              if (count != null) StatusBadge(Brand.grey, '$count baris', icon: Icons.table_rows_rounded),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (toolbar.isNotEmpty) ...[
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: toolbar),
          const SizedBox(height: 16),
        ],
        child,
      ]),
    );
  }
}

class BoolBadge extends StatelessWidget {
  const BoolBadge(this.value, {super.key, this.trueLabel = 'Ya', this.falseLabel = 'Tidak', this.trueColor = Brand.green, this.falseColor = Brand.grey});
  final bool value;
  final String trueLabel, falseLabel;
  final Color trueColor, falseColor;
  @override
  Widget build(BuildContext context) => StatusBadge(value ? trueColor : falseColor, value ? trueLabel : falseLabel,
      icon: value ? Icons.check_circle_rounded : Icons.remove_circle_outline_rounded);
}

class RiskBadge extends StatelessWidget {
  const RiskBadge(this.risk, {super.key});
  final String? risk;
  @override
  Widget build(BuildContext context) => StatusBadge.generic(risk);
}

class AudienceBadge extends StatelessWidget {
  const AudienceBadge(this.audience, {super.key});
  final String? audience;
  @override
  Widget build(BuildContext context) => switch (audience) {
        'wfrd' => const StatusBadge(Brand.navy, 'WFRD', icon: Icons.badge_outlined),
        'contractor' => const StatusBadge(Brand.cyan, 'Contractor', icon: Icons.engineering_outlined),
        _ => const StatusBadge(Brand.purple, 'Semua', icon: Icons.groups_2_outlined),
      };
}

class JsonBlock extends StatelessWidget {
  const JsonBlock(this.value, {super.key, this.maxHeight = 360});
  final dynamic value;
  final double maxHeight;
  @override
  Widget build(BuildContext context) => Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: SingleChildScrollView(
          child: SelectableText(value is String ? value as String : prettyJson(value), style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45)),
        ),
      );
}

/// Kartu Danger Zone (border merah).
class DangerCard extends StatelessWidget {
  const DangerCard({super.key, required this.title, required this.description, required this.action, this.icon = Icons.warning_amber_rounded, this.status, this.color = Brand.red});
  final String title;
  final String description;
  final Widget action;
  final IconData icon;
  final Widget? status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.all(18),
      child: LayoutBuilder(builder: (context, c) {
        final info = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                if (status != null) status!,
              ]),
              const SizedBox(height: 4),
              Text(description, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
        ]);
        if (c.maxWidth < 560) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [info, const SizedBox(height: 12), Align(alignment: Alignment.centerRight, child: action)]);
        }
        return Row(children: [Expanded(child: info), const SizedBox(width: 16), action]);
      }),
    );
  }
}

class PagerBar extends StatelessWidget {
  const PagerBar({super.key, required this.offset, required this.limit, required this.count, required this.onPage});
  final int offset, limit, count;
  final ValueChanged<int> onPage;
  @override
  Widget build(BuildContext context) {
    final from = count == 0 ? 0 : offset + 1;
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      Text('$from–${offset + count}', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(width: 8),
      IconButton(tooltip: 'Sebelumnya', onPressed: offset == 0 ? null : () => onPage((offset - limit).clamp(0, 1 << 30)), icon: const Icon(Icons.chevron_left_rounded)),
      IconButton(tooltip: 'Berikutnya', onPressed: count < limit ? null : () => onPage(offset + limit), icon: const Icon(Icons.chevron_right_rounded)),
    ]);
  }
}

/// Bar distribusi status (mis. kontrak per status).
class StatusDistribution extends StatelessWidget {
  const StatusDistribution({super.key, required this.data, required this.style});
  final Map<String, dynamic> data;
  final (Color, String) Function(String?) style;

  @override
  Widget build(BuildContext context) {
    final entries = data.entries.map((e) => MapEntry(e.key, (e.value as num?)?.toInt() ?? 0)).where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (a, e) => a + e.value);
    if (total == 0) return const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Belum ada data'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: SizedBox(
          height: 12,
          child: Row(children: [
            for (final e in entries) Expanded(flex: e.value, child: Container(color: style(e.key).$1)),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in entries) StatusBadge(style(e.key).$1, '${style(e.key).$2} · ${e.value}'),
      ]),
    ]);
  }
}

class LabeledSwitch extends StatelessWidget {
  const LabeledSwitch({super.key, required this.label, required this.value, required this.onChanged, this.subtitle});
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle == null ? null : Text(subtitle!),
        value: value,
        onChanged: onChanged,
      );
}

class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.value, required this.onChanged, this.first, this.last, this.clearable = true});
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final DateTime? first, last;
  final bool clearable;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final now = DateTime.now();
          final d = await showDatePicker(
            context: context,
            firstDate: first ?? DateTime(now.year - 5),
            lastDate: last ?? DateTime(now.year + 10),
            initialDate: value ?? now,
          );
          if (d != null) onChanged(d);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: value != null && clearable
                ? IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => onChanged(null))
                : const Icon(Icons.calendar_month_rounded),
          ),
          child: Text(value == null ? 'Tidak diatur' : fmtDate(value!.toIso8601String())),
        ),
      );
}

/// Dialog reason-less sederhana yang mengembalikan nilai form; dipakai untuk form yang menyertakan alasan inline.
class ReasonField extends StatelessWidget {
  const ReasonField({super.key, required this.controller, this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        maxLines: 2,
        maxLength: 1000,
        onChanged: onChanged,
        decoration: const InputDecoration(labelText: 'Alasan *', helperText: 'Minimal 5 karakter · tercatat di audit log', prefixIcon: Icon(Icons.edit_note_rounded)),
      );
}

// ─────────────────────────── Role + scope (approve / grant / invite) ───────────────────────────
enum RoleGrantMode { approve, grant, invite }

class RoleGrant {
  RoleGrant({required this.roleKey, required this.scopeType, this.scopeId, this.contractorId, this.expiresAt, required this.reason, this.email, this.note});
  final String roleKey, scopeType, reason;
  final String? scopeId, contractorId, email, note;
  final DateTime? expiresAt;
  String? get expiresIso => expiresAt == null ? null : DateTime(expiresAt!.year, expiresAt!.month, expiresAt!.day, 23, 59, 59).toUtc().toIso8601String();
}

Future<RoleGrant?> showRoleGrantDialog(
  BuildContext context, {
  required String title,
  required RoleGrantMode mode,
  required AdminLookups lookups,
  required SessionState? session,
  String? subject,
  String? presetContractorId,
  bool? onlyWfrd,
}) =>
    showDialog<RoleGrant>(
      context: context,
      builder: (_) => _RoleGrantDialog(title: title, mode: mode, lookups: lookups, session: session, subject: subject, presetContractorId: presetContractorId, onlyWfrd: onlyWfrd),
    );

class _RoleGrantDialog extends StatefulWidget {
  const _RoleGrantDialog({required this.title, required this.mode, required this.lookups, required this.session, this.subject, this.presetContractorId, this.onlyWfrd});
  final String title;
  final RoleGrantMode mode;
  final AdminLookups lookups;
  final SessionState? session;
  final String? subject;
  final String? presetContractorId;
  final bool? onlyWfrd;
  @override
  State<_RoleGrantDialog> createState() => _RoleGrantDialogState();
}

class _RoleGrantDialogState extends State<_RoleGrantDialog> {
  String? _role;
  String _scope = 'global';
  String? _scopeId;
  String? _contractor;
  DateTime? _expires;
  final _email = TextEditingController();
  final _note = TextEditingController();
  final _reason = TextEditingController();

  late final List<J> _roles = widget.lookups.grantableRoles(widget.session).where((r) {
    if (widget.onlyWfrd == null) return true;
    return (r['is_wfrd'] == true) == widget.onlyWfrd;
  }).toList();

  @override
  void initState() {
    super.initState();
    _contractor = widget.presetContractorId;
    if (_registeredCompany && _roles.any((r) => r['key'] == 'contractor_rep')) _role = 'contractor_rep';
  }

  bool get _registeredCompany => widget.mode == RoleGrantMode.approve && widget.presetContractorId != null;
  String get _registeredCompanyName =>
      str(widget.lookups.contractors.where((c) => c['id'] == widget.presetContractorId).firstOrNull?['legal_name']);
  J? get _roleRow => _roles.where((r) => r['key'] == _role).firstOrNull;
  bool get _isWfrd => _roleRow?['is_wfrd'] == true;
  bool get _needsContractor => _roleRow != null && !_isWfrd && widget.mode != RoleGrantMode.grant;

  bool get _ok {
    if (_role == null || _reason.text.trim().length < 5) return false;
    if (widget.mode == RoleGrantMode.invite && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim())) return false;
    if (_isWfrd && _scope != 'global' && (_scopeId == null || _scopeId!.isEmpty)) return false;
    if (_needsContractor && _contractor == null) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.lookups;
    final scopeTargets = switch (_scope) {
      'geozone' => [for (final g in l.geozones.where((g) => g['active'] == true)) (g['code'] as String, '${g['code']} · ${g['name']}')],
      'contract' => [for (final k in l.contracts) (k['id'] as String, '${str(k['contract_no'])} · ${str(k['title'])}')],
      'contractor' => [for (final c in l.contractors) (c['id'] as String, str(c['legal_name']))],
      _ => <(String, String)>[],
    };
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.subject != null) ...[
              InfoBanner(message: widget.subject!, icon: Icons.person_outline_rounded),
              const SizedBox(height: 16),
            ],
            if (widget.mode == RoleGrantMode.invite) ...[
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Email *', prefixIcon: Icon(Icons.alternate_email_rounded)),
              ),
              const SizedBox(height: 12),
            ],
            DropdownButtonFormField<String>(
              initialValue: _role,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Role *', prefixIcon: Icon(Icons.key_rounded), helperText: 'Hanya role yang boleh Anda berikan (anti-eskalasi)'),
              items: [
                for (final r in _roles)
                  DropdownMenuItem(
                    value: r['key'] as String,
                    child: Row(children: [
                      Expanded(child: Text(str(r['name']), overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      Text(r['is_wfrd'] == true ? 'WFRD' : 'Contractor', style: TextStyle(fontSize: 11, color: r['is_wfrd'] == true ? Brand.navy : Brand.cyan, fontWeight: FontWeight.w700)),
                    ]),
                  ),
              ],
              onChanged: (v) => setState(() {
                _role = v;
                _scope = 'global';
                _scopeId = null;
              }),
            ),
            if (_roles.isEmpty) ...[
              const SizedBox(height: 8),
              const InfoBanner(message: 'Tidak ada role yang dapat Anda berikan.', color: Brand.amber, icon: Icons.block_rounded),
            ],
            if (_registeredCompany && _isWfrd) ...[
              const SizedBox(height: 12),
              InfoBanner(
                message: 'User ini mendaftarkan perusahaan "$_registeredCompanyName". Role WFRD menjadikannya karyawan internal '
                    'Weatherford (akses ke semua vendor & kontrak) dan melepas perusahaannya — tidak bisa diubah kembali ke contractor dari aplikasi. '
                    'Untuk kontraktor, pilih Contractor Rep / Contractor Viewer.',
                color: Brand.amber,
                icon: Icons.warning_amber_rounded,
              ),
            ],
            if (_roleRow != null && _isWfrd) ...[
              const SizedBox(height: 16),
              const Text('Scope', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'global', label: Text('Global'), icon: Icon(Icons.public_rounded, size: 16)),
                  ButtonSegment(value: 'geozone', label: Text('Geozone'), icon: Icon(Icons.map_outlined, size: 16)),
                  ButtonSegment(value: 'contract', label: Text('Kontrak'), icon: Icon(Icons.handshake_outlined, size: 16)),
                  ButtonSegment(value: 'contractor', label: Text('Contractor'), icon: Icon(Icons.apartment_rounded, size: 16)),
                ],
                selected: {_scope},
                onSelectionChanged: (v) => setState(() {
                  _scope = v.first;
                  _scopeId = null;
                }),
              ),
              if (_scope != 'global') ...[
                const SizedBox(height: 12),
                LookupPicker(
                  key: ValueKey(_scope),
                  label: 'Target scope *',
                  items: scopeTargets,
                  value: _scopeId,
                  onChanged: (v) => setState(() => _scopeId = v),
                ),
              ],
            ],
            if (_needsContractor) ...[
              const SizedBox(height: 16),
              LookupPicker(
                label: 'Contractor *',
                items: [for (final c in l.contractors) (c['id'] as String, '${str(c['legal_name'])}${c['status'] == 'draft' ? ' (draft)' : ''}')],
                value: _contractor,
                onChanged: (v) => setState(() => _contractor = v),
              ),
              const SizedBox(height: 4),
              Text('Role contractor selalu ber-scope global (dibatasi oleh contractor user).', style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            DateField(
              label: widget.mode == RoleGrantMode.invite ? 'Role berlaku s/d (opsional)' : 'Berlaku s/d (opsional · akses sementara)',
              value: _expires,
              first: DateTime.now(),
              onChanged: (d) => setState(() => _expires = d),
            ),
            if (widget.mode == RoleGrantMode.invite) ...[
              const SizedBox(height: 12),
              TextField(controller: _note, maxLines: 2, maxLength: 500, decoration: const InputDecoration(labelText: 'Catatan undangan (opsional)')),
            ],
            const SizedBox(height: 12),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: _ok
              ? () => Navigator.pop(
                    context,
                    RoleGrant(
                      roleKey: _role!,
                      scopeType: _isWfrd ? _scope : 'global',
                      scopeId: _isWfrd && _scope != 'global' ? _scopeId : null,
                      contractorId: _needsContractor ? _contractor : null,
                      expiresAt: _expires,
                      reason: _reason.text.trim(),
                      email: widget.mode == RoleGrantMode.invite ? _email.text.trim().toLowerCase() : null,
                      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                    ),
                  )
              : null,
          icon: Icon(switch (widget.mode) { RoleGrantMode.approve => Icons.how_to_reg_rounded, RoleGrantMode.grant => Icons.add_moderator_rounded, RoleGrantMode.invite => Icons.send_rounded }),
          label: Text(switch (widget.mode) { RoleGrantMode.approve => 'Approve', RoleGrantMode.grant => 'Berikan role', RoleGrantMode.invite => 'Kirim undangan' }),
        ),
      ],
    );
  }
}

/// Dropdown dengan filter teks (untuk daftar panjang contractor/kontrak).
class LookupPicker extends StatelessWidget {
  const LookupPicker({super.key, required this.label, required this.items, required this.value, required this.onChanged, this.icon});
  final String label;
  final List<(String, String)> items;
  final String? value;
  final ValueChanged<String?> onChanged;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => DropdownMenu<String>(
        initialSelection: value,
        expandedInsets: EdgeInsets.zero,
        enableFilter: true,
        requestFocusOnTap: true,
        menuHeight: 320,
        label: Text(label),
        leadingIcon: icon == null ? null : Icon(icon, size: 20),
        dropdownMenuEntries: [for (final (v, l) in items) DropdownMenuEntry(value: v, label: l)],
        onSelected: onChanged,
      );
}

/// Pilih user (admin_list_users). Jika tidak punya akses daftar user → input UUID manual.
Future<J?> showUserPicker(BuildContext context, WidgetRef ref, {String title = 'Pilih user', String? roleKey, String? status = 'active'}) =>
    showDialog<J>(context: context, builder: (_) => _UserPickerDialog(title: title, roleKey: roleKey, status: status));

class _UserPickerDialog extends ConsumerStatefulWidget {
  const _UserPickerDialog({required this.title, this.roleKey, this.status});
  final String title;
  final String? roleKey;
  final String? status;
  @override
  ConsumerState<_UserPickerDialog> createState() => _UserPickerDialogState();
}

class _UserPickerDialogState extends ConsumerState<_UserPickerDialog> {
  String _q = '';
  late Future<List<J>> _f = _load();
  final _manual = TextEditingController();

  Future<List<J>> _load() async {
    final r = await ref.read(apiProvider).rpc('admin_list_users', {'p_status': widget.status, 'p_search': _q.isEmpty ? null : _q, 'p_limit': 50, 'p_offset': 0});
    final l = jl(r);
    if (widget.roleKey == null) return l;
    return l.where((u) => jl(u['roles']).any((x) => x['role'] == widget.roleKey)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AdminSearchField(width: 520, hint: 'Cari nama / email', onChanged: (v) => setState(() {
                _q = v;
                _f = _load();
              })),
          if (widget.roleKey != null) ...[
            const SizedBox(height: 8),
            Text('Hanya user dengan role ${widget.roleKey}', style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<J>>(
              future: _f,
              builder: (context, s) {
                if (s.hasError) {
                  return Column(mainAxisSize: MainAxisSize.min, children: [
                    const InfoBanner(message: 'Daftar user tidak tersedia untuk Anda. Masukkan User ID (UUID) secara manual.', color: Brand.amber),
                    const SizedBox(height: 12),
                    TextField(controller: _manual, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'User ID (UUID)')),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: uuidRe.hasMatch(_manual.text.trim()) ? () => Navigator.pop(context, <String, dynamic>{'id': _manual.text.trim()}) : null,
                        child: const Text('Gunakan'),
                      ),
                    ),
                  ]);
                }
                if (s.connectionState != ConnectionState.done) return const LoadingView();
                final l = s.data!;
                if (l.isEmpty) return const EmptyState(icon: Icons.person_search_rounded, title: 'Tidak ada user cocok');
                return ListView.separated(
                  itemCount: l.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final u = l[i];
                    return ListTile(
                      leading: Avatar(name: u['full_name'] as String?, url: u['avatar_url'] as String?),
                      title: Text(str(u['full_name'])),
                      subtitle: Text('${str(u['email'])}${u['contractor_name'] != null ? ' · ${u['contractor_name']}' : ''}'),
                      trailing: StatusBadge.account(u['status'] as String?),
                      onTap: () => Navigator.pop(context, u),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal'))],
    );
  }
}

/// Header kecil untuk kelompok di dalam kartu.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key, this.color = Brand.blue});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Text(text.toUpperCase(), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.8, color: color)),
      );
}

/// Teks satu baris dua tingkat (judul tebal + keterangan) untuk sel tabel.
class CellText extends StatelessWidget {
  const CellText(this.title, {super.key, this.subtitle, this.maxWidth = 280, this.mono = false});
  final String title;
  final String? subtitle;
  final double maxWidth;
  final bool mono;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontFamily: mono ? 'monospace' : null)),
          if (subtitle != null && subtitle!.isNotEmpty)
            Text(subtitle!, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      );
}

/// Banner standar bila session tidak punya permission aksi tertentu.
class PermissionNote extends StatelessWidget {
  const PermissionNote(this.perm, {super.key, this.what = 'mengubah data ini'});
  final String perm;
  final String what;
  @override
  Widget build(BuildContext context) => InfoBanner(message: 'Mode baca: Anda butuh permission $perm untuk $what.', color: Brand.grey, icon: Icons.visibility_outlined);
}
