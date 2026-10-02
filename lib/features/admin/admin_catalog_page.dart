import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

const _catalogCols = 'code,label,allowed_scopes,kind,phase,requirement,condition_key,min_risk_class,vendor_requirement,vendor_condition_key,'
    'subcon_required,reviewer_role,requires_email,requires_expiry,requires_fingerprint,sensitive,due_anchor,due_offset_days,review_sla_days,'
    'is_mob_gate,checklist_template,active';
const _kinds = ['document', 'evidence', 'form', 'checklist', 'action'];
const _scopes = ['vendor', 'contract', 'subcontractor'];
const _requirements = ['mandatory', 'conditional', 'optional', 'recurring', 'adhoc'];
const _vendorRequirements = ['mandatory', 'conditional', 'optional'];
const _anchors = <String, String>{
  'created': 'Sejak task dibuat',
  'award_date': 'Tanggal award',
  'target_mob_date': 'Target mobilisasi',
  'period_end': 'Akhir periode',
  'event': 'Saat kejadian',
};

class AdminCatalogPage extends ConsumerStatefulWidget {
  const AdminCatalogPage({super.key});
  @override
  ConsumerState<AdminCatalogPage> createState() => _AdminCatalogPageState();
}

class _AdminCatalogPageState extends ConsumerState<AdminCatalogPage> {
  late Future<List<J>> _future = _load();
  String _q = '';
  String? _kind;
  bool _activeOnly = false;

  Future<List<J>> _load() => ref.read(apiProvider).select('doc_type_catalog', _catalogCols, build: (q) => q.order('code'));
  void _reload() => setState(() => _future = _load());

  Future<void> _edit(J? d) async {
    final lookups = await ref.read(adminLookupsProvider.future);
    if (!mounted) return;
    final res = await showDialog<(String, J, String)>(context: context, builder: (_) => _DocTypeDialog(doc: d, roles: lookups.roles.where((r) => r['is_wfrd'] == true).toList()));
    if (res == null || !mounted) return;
    final ok = await adminRun(context, ref, () => ref.read(apiProvider).rpc('admin_upsert_doc_type', {'p_code': res.$1, 'p_data': res.$2, 'p_reason': res.$3}),
        success: d == null ? 'Jenis dokumen ditambahkan' : 'Katalog diperbarui (berlaku untuk task baru)');
    if (ok) _reload();
  }

  Future<void> _assign(List<J> all, [J? preset]) async {
    final lookups = await ref.read(adminLookupsProvider.future);
    if (!mounted) return;
    final docs = all.where(_assignable).toList();
    final req = await showDialog<J>(context: context, builder: (_) => _AssignDialog(docs: docs, contractors: lookups.contractors, preset: preset));
    if (req == null || !mounted) return;
    final r = await runAction<J>(context, ref, () => ref.read(apiProvider).rpcMap('admin_assign_doc_type', req));
    if (r == null || !mounted) return;
    final created = r['created'] ?? 0, skipped = r['skipped'] ?? 0;
    showSnack(context, '$created task dibuat${skipped == 0 ? '' : ' · $skipped dilewati (sudah punya task aktif sejenis / status vendor tidak eligible)'}');
  }

  @override
  Widget build(BuildContext context) {
    return AdminScaffold(
      title: 'Document Catalog',
      subtitle: 'Kode dokumen 6 karakter · perubahan berlaku untuk task baru, tidak mengubah task yang sudah ada',
      actions: [
        FutureBuilder<List<J>>(
          future: _future,
          builder: (context, snap) => FilledButton.tonalIcon(
            onPressed: snap.hasData ? () => _assign(snap.data!) : null,
            icon: const Icon(Icons.send_rounded),
            label: const Text('Berikan ke kontraktor'),
          ),
        ),
        FilledButton.icon(onPressed: () => _edit(null), icon: const Icon(Icons.note_add_rounded), label: const Text('Jenis baru')),
        OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang')),
      ],
      child: AsyncView<List<J>>(
        future: _future,
        onRetry: _reload,
        builder: (context, all) {
          final q = _q.toLowerCase();
          final list = all
              .where((d) => (_kind == null || d['kind'] == _kind) && (!_activeOnly || d['active'] == true) && (q.isEmpty || '${d['code']} ${d['label']} ${d['reviewer_role']}'.toLowerCase().contains(q)))
              .toList();
          return TableCard(
            count: list.length,
            toolbar: [
              AdminSearchField(hint: 'Cari kode / label / reviewer', onChanged: (v) => setState(() => _q = v)),
              Wrap(spacing: 6, runSpacing: 6, children: [
                ChoiceChip(label: Text('Semua (${all.length})'), selected: _kind == null, onSelected: (_) => setState(() => _kind = null)),
                for (final k in _kinds) ChoiceChip(label: Text('${Labels.kindOf(k)} (${all.where((d) => d['kind'] == k).length})'), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
              ]),
              FilterChip(label: const Text('Hanya aktif'), selected: _activeOnly, onSelected: (v) => setState(() => _activeOnly = v)),
            ],
            child: DataList(
              empty: 'Tidak ada jenis dokumen cocok',
              columns: const ['Kode', 'Label', 'Jenis', 'Fase', 'Scope', 'Requirement', 'Reviewer', 'Atribut', 'SLA', 'Status', ''],
              onTap: (i) => _edit(list[i]),
              rows: [
                for (final d in list)
                  [
                    MonoText(str(d['code']), size: 12),
                    CellText(str(d['label']), maxWidth: 260),
                    StatusBadge(Brand.blue, Labels.kindOf(d['kind'])),
                    Text(Labels.phaseOf(d['phase'])),
                    Text((d['allowed_scopes'] as List? ?? const []).map((s) => Labels.of(Labels.scope, s)).join(', ')),
                    Text([if (d['requirement'] != null) d['requirement'], if (d['vendor_requirement'] != null) 'vendor:${d['vendor_requirement']}'].join(' · ').ifEmpty('-')),
                    Text(str(d['reviewer_role'])),
                    Wrap(spacing: 4, children: [
                      if (d['requires_email'] == true) const Tooltip(message: 'Wajib email konfirmasi', child: Icon(Icons.mail_outline_rounded, size: 16, color: Brand.blue)),
                      if (d['requires_expiry'] == true) const Tooltip(message: 'Wajib tanggal kedaluwarsa', child: Icon(Icons.event_rounded, size: 16, color: Brand.amber)),
                      if (d['requires_fingerprint'] == true) const Tooltip(message: 'Wajib sidik jari SHA-256', child: Icon(Icons.fingerprint_rounded, size: 16, color: Brand.purple)),
                      if (d['sensitive'] == true) const Tooltip(message: 'Sensitif', child: Icon(Icons.lock_rounded, size: 16, color: Brand.red)),
                      if (d['is_mob_gate'] == true) const Tooltip(message: 'Gate mobilisasi', child: Icon(Icons.block_rounded, size: 16, color: Brand.navy)),
                    ]),
                    Text('${d['review_sla_days']} hr'),
                    BoolBadge(d['active'] == true, trueLabel: 'Aktif', falseLabel: 'Nonaktif'),
                    _assignable(d)
                        ? IconButton(tooltip: 'Berikan ke kontraktor', icon: const Icon(Icons.send_rounded, size: 18), onPressed: () => _assign(all, d))
                        : const SizedBox.shrink(),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

extension on String {
  String ifEmpty(String v) => isEmpty ? v : this;
}

class _DocTypeDialog extends StatefulWidget {
  const _DocTypeDialog({this.doc, required this.roles});
  final J? doc;
  final List<J> roles;
  @override
  State<_DocTypeDialog> createState() => _DocTypeDialogState();
}

class _DocTypeDialogState extends State<_DocTypeDialog> {
  late final J _d = Map<String, dynamic>.from(widget.doc ?? const {'kind': 'document', 'phase': 'pre_mobilization', 'allowed_scopes': ['contract'], 'review_sla_days': 3, 'active': true, 'requires_email': true});
  late final _code = TextEditingController(text: str(_d['code'], ''));
  late final _label = TextEditingController(text: str(_d['label'], ''));
  late final _cond = TextEditingController(text: str(_d['condition_key'], ''));
  late final _vcond = TextEditingController(text: str(_d['vendor_condition_key'], ''));
  late final _offset = TextEditingController(text: _d['due_offset_days']?.toString() ?? '');
  late final _sla = TextEditingController(text: _d['review_sla_days']?.toString() ?? '3');
  late final _checklist = TextEditingController(text: _d['checklist_template'] == null ? '' : prettyJson(_d['checklist_template']));
  late final Set<String> _scopesSel = {...(_d['allowed_scopes'] as List? ?? const []).cast<String>()};
  final _reason = TextEditingController();

  bool get _isNew => widget.doc == null;
  bool _b(String k) => _d[k] == true;
  void _set(String k, dynamic v) => setState(() => _d[k] = v);

  String? get _checklistError {
    final t = _checklist.text.trim();
    if (t.isEmpty) return null;
    try {
      jsonDecode(t);
      return null;
    } catch (_) {
      return 'JSON tidak valid';
    }
  }

  String? get _error {
    if (!RegExp(r'^[A-Z0-9]{6}$').hasMatch(_code.text.trim())) return 'Kode harus 6 karakter A-Z0-9';
    if (_label.text.trim().isEmpty) return 'Label wajib';
    if (_scopesSel.isEmpty) return 'Pilih minimal satu scope';
    if (_d['reviewer_role'] == null) return 'Pilih reviewer role';
    if (_d['requirement'] == 'conditional' && _cond.text.trim().isEmpty && _d['min_risk_class'] == null) return 'Requirement conditional butuh condition key atau min. risk class';
    if (_d['vendor_requirement'] != null && !_scopesSel.contains('vendor')) return 'Vendor requirement butuh scope vendor';
    if (_b('subcon_required') && !_scopesSel.contains('subcontractor')) return 'Wajib subkon butuh scope subcontractor';
    final sla = int.tryParse(_sla.text.trim());
    if (sla == null || sla < 1 || sla > 30) return 'SLA review 1–30 hari';
    if (_offset.text.trim().isNotEmpty && int.tryParse(_offset.text.trim()) == null) return 'Offset due harus angka';
    if (_checklistError != null) return 'Checklist template: JSON tidak valid';
    return null;
  }

  J _payload() => {
        'label': _label.text.trim(),
        'allowed_scopes': _scopes.where(_scopesSel.contains).toList(),
        'kind': _d['kind'],
        'phase': _d['phase'],
        'requirement': _d['requirement'],
        'condition_key': _cond.text.trim().isEmpty ? null : _cond.text.trim(),
        'min_risk_class': _d['min_risk_class'],
        'vendor_requirement': _d['vendor_requirement'],
        'vendor_condition_key': _vcond.text.trim().isEmpty ? null : _vcond.text.trim(),
        'subcon_required': _b('subcon_required'),
        'reviewer_role': _d['reviewer_role'],
        'requires_email': _d['kind'] == 'document' ? true : _b('requires_email'),
        'requires_expiry': _b('requires_expiry'),
        'requires_fingerprint': _b('requires_fingerprint'),
        'sensitive': _b('sensitive'),
        'due_anchor': _d['due_anchor'],
        'due_offset_days': _offset.text.trim().isEmpty ? null : int.parse(_offset.text.trim()),
        'review_sla_days': int.parse(_sla.text.trim()),
        'is_mob_gate': _b('is_mob_gate'),
        'checklist_template': _checklist.text.trim().isEmpty ? null : jsonDecode(_checklist.text.trim()),
        'active': _b('active'),
      };

  Widget _dd(String label, String key, Map<String?, String> items) => DropdownButtonFormField<String?>(
        initialValue: _d[key] as String?,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) => _set(key, v),
      );

  @override
  Widget build(BuildContext context) {
    final err = _error;
    final reasonOk = _reason.text.trim().length >= 5;
    return AlertDialog(
      title: Text(_isNew ? 'Jenis dokumen baru' : 'Ubah ${_d['code']}'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!_isNew) ...[
              const InfoBanner(message: 'Perubahan katalog tidak mengubah task yang sudah ada — berlaku untuk task baru.', icon: Icons.info_outline_rounded),
              const SizedBox(height: 12),
            ],
            const GroupLabel('Identitas'),
            ResponsiveGrid(minItemWidth: 220, spacing: 12, children: [
              TextField(
                controller: _code,
                enabled: _isNew,
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                onChanged: (v) => setState(() {}),
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800),
                decoration: const InputDecoration(labelText: 'Kode *', counterText: ''),
              ),
              _dd('Jenis *', 'kind', {for (final k in _kinds) k: Labels.kindOf(k)}),
              _dd('Fase default *', 'phase', {for (final e in Labels.phase.entries) e.key: e.value}),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _label, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Label *')),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Scope *', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final s in _scopes)
                FilterChip(
                  label: Text(Labels.of(Labels.scope, s)),
                  selected: _scopesSel.contains(s),
                  onSelected: (v) => setState(() => v ? _scopesSel.add(s) : _scopesSel.remove(s)),
                ),
            ]),
            const GroupLabel('Aturan kebutuhan'),
            ResponsiveGrid(minItemWidth: 220, spacing: 12, children: [
              _dd('Requirement (kontrak)', 'requirement', {null: '-', for (final r in _requirements) r: r}),
              TextField(controller: _cond, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Condition key')),
              _dd('Min. risk class', 'min_risk_class', {null: '-', ...Labels.risk}),
              _dd('Requirement vendor', 'vendor_requirement', {null: '-', for (final r in _vendorRequirements) r: r}),
              TextField(controller: _vcond, decoration: const InputDecoration(labelText: 'Vendor condition key')),
              DropdownButtonFormField<String>(
                initialValue: widget.roles.any((r) => r['key'] == _d['reviewer_role']) ? _d['reviewer_role'] as String : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Reviewer role *'),
                items: [for (final r in widget.roles) DropdownMenuItem(value: r['key'] as String, child: Text('${r['name']} (${r['key']})'))],
                onChanged: (v) => _set('reviewer_role', v),
              ),
            ]),
            const GroupLabel('Jadwal'),
            ResponsiveGrid(minItemWidth: 220, spacing: 12, children: [
              _dd('Anchor due', 'due_anchor', {null: '-', ..._anchors}),
              TextField(controller: _offset, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Offset due (hari, boleh negatif)')),
              TextField(controller: _sla, onChanged: (_) => setState(() {}), keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'SLA review (hari) *')),
            ]),
            const GroupLabel('Atribut'),
            ResponsiveGrid(minItemWidth: 230, spacing: 0, children: [
              LabeledSwitch(
                label: 'Wajib email konfirmasi',
                subtitle: _d['kind'] == 'document' ? 'Selalu aktif untuk jenis Dokumen' : null,
                value: _d['kind'] == 'document' || _b('requires_email'),
                onChanged: (v) => _d['kind'] == 'document' ? null : _set('requires_email', v),
              ),
              LabeledSwitch(label: 'Wajib tanggal kedaluwarsa', value: _b('requires_expiry'), onChanged: (v) => _set('requires_expiry', v)),
              LabeledSwitch(label: 'Wajib sidik jari SHA-256', value: _b('requires_fingerprint'), onChanged: (v) => _set('requires_fingerprint', v)),
              LabeledSwitch(label: 'Dokumen sensitif', value: _b('sensitive'), onChanged: (v) => _set('sensitive', v)),
              LabeledSwitch(label: 'Gate mobilisasi', value: _b('is_mob_gate'), onChanged: (v) => _set('is_mob_gate', v)),
              LabeledSwitch(label: 'Wajib untuk subkon', value: _b('subcon_required'), onChanged: (v) => _set('subcon_required', v)),
              LabeledSwitch(label: 'Aktif', value: _b('active'), onChanged: (v) => _set('active', v)),
            ]),
            if (_d['kind'] == 'checklist' || _checklist.text.isNotEmpty) ...[
              const GroupLabel('Checklist template (JSON)'),
              TextField(
                controller: _checklist,
                maxLines: 8,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(hintText: '[{"item_no": 1, "label": "...", "owner_party": "contractor"}]', errorText: _checklistError),
              ),
            ],
            const SizedBox(height: 12),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
            if (err != null && _reason.text.isNotEmpty) InfoBanner(message: err, color: Brand.red, icon: Icons.error_outline_rounded),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: err == null && reasonOk ? () => Navigator.pop(context, (_code.text.trim(), _payload(), _reason.text.trim())) : null, child: const Text('Simpan')),
      ],
    );
  }
}

const _assignStatuses = {'under_review', 'asl_approved', 'asl_conditional', 'asl_expired'};

bool _assignable(J d) {
  final scopes = (d['allowed_scopes'] as List? ?? const []);
  return d['active'] == true && (scopes.contains('vendor') || scopes.contains('contract'));
}

/// Satu jenis dokumen katalog → task untuk banyak contractor sekaligus (`admin_assign_doc_type`).
class _AssignDialog extends StatefulWidget {
  const _AssignDialog({required this.docs, required this.contractors, this.preset});
  final List<J> docs;
  final List<J> contractors;
  final J? preset;
  @override
  State<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends State<_AssignDialog> {
  late String? _code = widget.preset?['code'] as String?;
  String _scope = 'vendor';
  final Set<String> _selected = {};
  DateTime? _due = DateTime.now().add(const Duration(days: 14));
  bool _blocker = false;
  String _filter = '';
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _reason = TextEditingController();

  late final List<J> _eligible = widget.contractors.where((c) => _assignStatuses.contains(c['status'])).toList();

  J? get _doc => widget.docs.where((d) => d['code'] == _code).firstOrNull;
  List<String> get _scopes => [for (final s in ['vendor', 'contract']) if ((_doc?['allowed_scopes'] as List? ?? const []).contains(s)) s];

  @override
  void initState() {
    super.initState();
    _syncDoc();
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _syncDoc() {
    _title.text = str(_doc?['label']);
    if (!_scopes.contains(_scope) && _scopes.isNotEmpty) _scope = _scopes.first;
  }

  bool get _ok => _doc != null && _scopes.contains(_scope) && _selected.isNotEmpty && _due != null && _reason.text.trim().length >= 5;

  @override
  Widget build(BuildContext context) {
    final q = _filter.toLowerCase();
    final shown = _eligible.where((c) => q.isEmpty || str(c['legal_name']).toLowerCase().contains(q)).toList();
    final allShown = shown.isNotEmpty && shown.every((c) => _selected.contains(c['id']));
    return AlertDialog(
      title: const Text('Berikan task ke kontraktor'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const InfoBanner(
              message: 'Jenis dokumen yang sama diberikan sebagai task baru ke setiap contractor terpilih. '
                  'Contractor yang sudah punya task aktif sejenis otomatis dilewati.',
              icon: Icons.info_outline_rounded,
            ),
            const SizedBox(height: 16),
            LookupPicker(
              label: 'Jenis dokumen *',
              icon: Icons.description_outlined,
              items: [for (final d in widget.docs) (d['code'] as String, '${d['code']} · ${str(d['label'])}')],
              value: _code,
              onChanged: (v) => setState(() {
                _code = v;
                _syncDoc();
              }),
            ),
            if (_doc != null) ...[
              const SizedBox(height: 16),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'vendor', label: const Text('Per perusahaan'), icon: const Icon(Icons.apartment_rounded, size: 16), enabled: _scopes.contains('vendor')),
                  ButtonSegment(value: 'contract', label: const Text('Per kontrak berjalan'), icon: const Icon(Icons.handshake_outlined, size: 16), enabled: _scopes.contains('contract')),
                ],
                selected: {_scope},
                onSelectionChanged: (v) => setState(() => _scope = v.first),
              ),
              const SizedBox(height: 4),
              Text(
                _scope == 'vendor' ? 'Satu task untuk setiap perusahaan.' : 'Satu task untuk setiap kontrak yang belum ditutup milik perusahaan terpilih.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            TextField(controller: _title, maxLength: 200, decoration: const InputDecoration(labelText: 'Judul task', counterText: '')),
            const SizedBox(height: 12),
            ResponsiveGrid(minItemWidth: 240, spacing: 12, children: [
              DateField(label: 'Due date *', value: _due, first: DateTime.now(), clearable: false, onChanged: (d) => setState(() => _due = d)),
              LabeledSwitch(label: 'Blocker', subtitle: 'Menahan progres sampai selesai', value: _blocker, onChanged: (v) => setState(() => _blocker = v)),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _desc, maxLines: 3, maxLength: 4000, decoration: const InputDecoration(labelText: 'Instruksi untuk contractor (opsional)')),
            const GroupLabel('Contractor'),
            Row(children: [
              Expanded(child: AdminSearchField(hint: 'Cari perusahaan', onChanged: (v) => setState(() => _filter = v))),
              const SizedBox(width: 8),
              TextButton(
                onPressed: shown.isEmpty
                    ? null
                    : () => setState(() => allShown ? _selected.removeAll(shown.map((c) => c['id'])) : _selected.addAll(shown.map((c) => c['id'] as String))),
                child: Text(allShown ? 'Batal pilih semua' : 'Pilih semua'),
              ),
            ]),
            const SizedBox(height: 4),
            Text('${_selected.length} dari ${_eligible.length} contractor dipilih · hanya vendor berstatus review / ASL yang bisa diberi task',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(12)),
              child: shown.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16), child: Text('Belum ada contractor yang eligible.'))
                  : ListView(shrinkWrap: true, children: [
                      for (final c in shown)
                        CheckboxListTile(
                          dense: true,
                          value: _selected.contains(c['id']),
                          onChanged: (v) => setState(() => v == true ? _selected.add(c['id'] as String) : _selected.remove(c['id'])),
                          title: Text(str(c['legal_name'])),
                          subtitle: Text(StatusStyle.vendor(c['status'] as String?).$2),
                        ),
                    ]),
            ),
            const SizedBox(height: 12),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: _ok
              ? () => Navigator.pop<J>(context, {
                    'p_doc_type': _code,
                    'p_scope': _scope,
                    'p_contractors': _selected.toList(),
                    'p_title': _title.text.trim().isEmpty ? null : _title.text.trim(),
                    'p_due': '${_due!.year.toString().padLeft(4, '0')}-${_due!.month.toString().padLeft(2, '0')}-${_due!.day.toString().padLeft(2, '0')}',
                    'p_is_blocker': _blocker,
                    'p_description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
                    'p_reason': _reason.text.trim(),
                  })
              : null,
          icon: const Icon(Icons.send_rounded),
          label: Text('Berikan ke ${_selected.length} contractor'),
        ),
      ],
    );
  }
}
