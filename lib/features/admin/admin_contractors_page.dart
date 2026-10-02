import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

const _vendorStatuses = ['draft', 'under_review', 'asl_approved', 'asl_conditional', 'rejected', 'asl_expired', 'suspended', 'blacklisted'];

class AdminContractorsPage extends ConsumerStatefulWidget {
  const AdminContractorsPage({super.key});
  @override
  ConsumerState<AdminContractorsPage> createState() => _AdminContractorsPageState();
}

class _AdminContractorsPageState extends ConsumerState<AdminContractorsPage> {
  late Future<List<J>> _future = _load();
  String _q = '';
  String? _status;

  Future<List<J>> _load() => ref.read(apiProvider).select('contractors', Cols.contractors, build: (q) => q.order('updated_at', ascending: false).limit(1000));

  void _reload() {
    ref.invalidate(adminLookupsProvider);
    setState(() => _future = _load());
  }

  Future<void> _edit(J? c) async {
    J? detail;
    if (c != null) {
      try {
        detail = await ref.read(apiProvider).rpcMap('get_contractor_detail', {'p_contractor': c['id']});
      } catch (_) {}
    }
    if (!mounted) return;
    final res = await showDialog<(J, String)>(context: context, builder: (_) => _ContractorDialog(contractor: c, detail: detail));
    if (res == null || !mounted) return;
    final ok = await adminRun(context, ref, () => ref.read(apiProvider).rpc('admin_upsert_contractor', {'p_id': c?['id'], 'p_data': res.$1, 'p_reason': res.$2}),
        success: c == null ? 'Contractor dibuat' : 'Contractor diperbarui');
    if (ok) _reload();
  }

  Future<void> _setStatus(J c, String target) async {
    final label = StatusStyle.vendor(target).$2;
    final ok = await withReason(context, ref,
        title: 'Ubah status vendor → $label',
        message: target == 'suspended' || target == 'blacklisted'
            ? '${c['legal_name']} akan di-$label. Process owner kontrak aktif diberi tahu untuk mempertimbangkan hold kontrak.'
            : 'Reinstate ${c['legal_name']} dari suspended (ASL harus belum kedaluwarsa).',
        confirmLabel: label,
        destructive: target == 'suspended' || target == 'blacklisted',
        success: 'Status vendor diperbarui',
        action: (r) => ref.read(apiProvider).rpc('set_vendor_status', {'p_contractor': c['id'], 'p_status': target, 'p_reason': r}));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    final canStatus = s?.can('vendor.suspend') ?? false;
    final canView = s?.can('vendor.view') ?? false;
    return AdminScaffold(
      title: 'Contractor Setup',
      subtitle: 'Data master vendor/contractor · ID vendor & domain email untuk pencocokan user',
      actions: [
        FilledButton.icon(onPressed: () => _edit(null), icon: const Icon(Icons.add_business_rounded), label: const Text('Contractor baru')),
        OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang')),
      ],
      child: AsyncView<List<J>>(
        future: _future,
        onRetry: _reload,
        builder: (context, all) {
          final q = _q.toLowerCase();
          final list = all
              .where((c) => (_status == null || c['status'] == _status) &&
                  (q.isEmpty || '${c['legal_name']} ${c['trading_name'] ?? ''} ${c['email_domain'] ?? ''} ${c['tax_id'] ?? ''}'.toLowerCase().contains(q)))
              .toList();
          final counts = <String, int>{};
          for (final c in all) {
            counts.update(c['status'] as String, (v) => v + 1, ifAbsent: () => 1);
          }
          return TableCard(
            count: list.length,
            toolbar: [
              AdminSearchField(hint: 'Cari nama / domain / tax ID', onChanged: (v) => setState(() => _q = v)),
              Wrap(spacing: 6, runSpacing: 6, children: [
                ChoiceChip(label: Text('Semua (${all.length})'), selected: _status == null, onSelected: (_) => setState(() => _status = null)),
                for (final st in _vendorStatuses.where(counts.containsKey))
                  ChoiceChip(label: Text('${StatusStyle.vendor(st).$2} (${counts[st]})'), selected: _status == st, onSelected: (_) => setState(() => _status = st)),
              ]),
            ],
            child: all.isEmpty
                ? EmptyState(
                    icon: Icons.apartment_rounded,
                    title: 'Belum ada contractor',
                    action: FilledButton.icon(onPressed: () => _edit(null), icon: const Icon(Icons.add_business_rounded), label: const Text('Contractor baru')),
                  )
                : DataList(
                    empty: 'Tidak ada contractor cocok',
                    columns: const ['#', 'Contractor', 'Domain', 'Negara', 'Kontak utama', 'Status', 'ASL s/d', 'Diperbarui', ''],
                    onTap: canView ? (i) => context.go('/vendors/${list[i]['id']}') : null,
                    rows: [
                      for (final c in list)
                        [
                          MonoText('V${(c['vendor_seq'] ?? '').toString().padLeft(4, '0')}', size: 12),
                          CellText(str(c['legal_name']), subtitle: c['trading_name'] as String?),
                          Text(str(c['email_domain'])),
                          Text(str(c['country'])),
                          CellText(str(c['primary_contact_name']), subtitle: c['primary_contact_email'] as String?, maxWidth: 220),
                          StatusBadge.vendor(c['status'] as String?),
                          Text(fmtDate(c['asl_expires_on']), style: TextStyle(color: c['asl_expires_on'] == null ? null : dueColor(c['asl_expires_on']))),
                          Text(fmtRelative(c['updated_at'])),
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(tooltip: 'Ubah data', onPressed: () => _edit(c), icon: const Icon(Icons.edit_outlined, size: 20)),
                            if (canStatus)
                              PopupMenuButton<String>(
                                tooltip: 'Status vendor',
                                icon: const Icon(Icons.more_vert_rounded, size: 20),
                                onSelected: (v) => _setStatus(c, v),
                                itemBuilder: (_) => [
                                  if (c['status'] != 'suspended' && c['status'] != 'blacklisted')
                                    const PopupMenuItem(value: 'suspended', child: ListTile(leading: Icon(Icons.pause_circle_outline_rounded, color: Brand.red), title: Text('Suspend'))),
                                  if (c['status'] != 'blacklisted')
                                    const PopupMenuItem(value: 'blacklisted', child: ListTile(leading: Icon(Icons.gpp_bad_outlined, color: Brand.red), title: Text('Blacklist'))),
                                  if (c['status'] == 'suspended') ...[
                                    const PopupMenuItem(value: 'asl_approved', child: ListTile(leading: Icon(Icons.verified_outlined, color: Brand.green), title: Text('Reinstate (ASL Approved)'))),
                                    const PopupMenuItem(value: 'asl_conditional', child: ListTile(leading: Icon(Icons.rule_rounded, color: Brand.amber), title: Text('Reinstate (Conditional)'))),
                                  ],
                                ],
                              ),
                            if (canView) IconButton(tooltip: 'Buka detail vendor', onPressed: () => context.go('/vendors/${c['id']}'), icon: const Icon(Icons.open_in_new_rounded, size: 18)),
                          ]),
                        ],
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _ContractorDialog extends StatefulWidget {
  const _ContractorDialog({this.contractor, this.detail});
  final J? contractor;
  final J? detail;
  @override
  State<_ContractorDialog> createState() => _ContractorDialogState();
}

class _ContractorDialogState extends State<_ContractorDialog> {
  static const _fields = <(String, String, int)>[
    ('legal_name', 'Nama legal *', 200),
    ('trading_name', 'Nama dagang', 200),
    ('registration_no', 'No. registrasi (NIB)', 60),
    ('tax_id', 'NPWP / Tax ID', 40),
    ('country', 'Negara (ISO 2 huruf)', 2),
    ('website', 'Website', 300),
    ('email_domain', 'Domain email', 120),
    ('primary_contact_name', 'Kontak utama', 120),
    ('primary_contact_email', 'Email kontak utama', 200),
    ('primary_contact_phone', 'Telepon kontak utama', 20),
    ('hse_manager_name', 'HSE manager', 120),
    ('hse_manager_email', 'Email HSE manager', 200),
    ('address', 'Alamat', 500),
    ('internal_notes', 'Catatan internal (WFRD)', 2000),
  ];

  late final Map<String, TextEditingController> _c = {
    for (final f in _fields) f.$1: TextEditingController(text: _initial(f.$1)),
  };
  final _reason = TextEditingController();
  bool _submit = false;

  String _initial(String k) {
    final src = (k == 'primary_contact_phone' || k == 'internal_notes') ? widget.detail : widget.contractor;
    return (src?[k] ?? '').toString();
  }

  bool get _isNew => widget.contractor == null;
  bool get _ok => _c['legal_name']!.text.trim().isNotEmpty && _reason.text.trim().length >= 5 && (_c['country']!.text.trim().isEmpty || _c['country']!.text.trim().length == 2);

  J _data() {
    final d = <String, dynamic>{};
    for (final f in _fields) {
      final v = _c[f.$1]!.text.trim();
      final changed = v != _initial(f.$1);
      // Telepon & catatan internal hanya terbaca bila punya vendor.view → kirim hanya bila diubah agar tidak terhapus
      if ((f.$1 == 'primary_contact_phone' || f.$1 == 'internal_notes') && !changed) continue;
      if (!_isNew && !changed) continue;
      if (_isNew && v.isEmpty) continue;
      d[f.$1] = v.isEmpty ? null : v;
    }
    if (_submit) d['submit'] = true;
    return d;
  }

  @override
  Widget build(BuildContext context) {
    Widget field((String, String, int) f) => TextField(
          controller: _c[f.$1],
          maxLength: f.$3 > 200 ? null : f.$3,
          maxLines: f.$3 > 300 ? 3 : 1,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: f.$2, counterText: ''),
        );
    final status = widget.contractor?['status'];
    return AlertDialog(
      title: Text(_isNew ? 'Contractor baru' : 'Ubah ${widget.contractor!['legal_name']}'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const GroupLabel('Identitas'),
            ResponsiveGrid(minItemWidth: 300, spacing: 12, children: [for (final f in _fields.take(7)) field(f)]),
            const GroupLabel('Kontak'),
            ResponsiveGrid(minItemWidth: 300, spacing: 12, children: [for (final f in _fields.skip(7).take(5)) field(f)]),
            const SizedBox(height: 12),
            field(_fields[12]),
            const SizedBox(height: 12),
            field(_fields[13]),
            if (widget.detail == null && !_isNew) ...[
              const SizedBox(height: 8),
              Text('Telepon & catatan internal tersembunyi (butuh vendor.view) — isi hanya bila ingin mengganti.', style: Theme.of(context).textTheme.bodySmall),
            ],
            if (_isNew || status == 'draft') ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _submit,
                onChanged: (v) => setState(() => _submit = v ?? false),
                title: const Text('Ajukan untuk review (draft → under review)'),
                subtitle: const Text('Task dokumen vendor dibuat dan due date mulai berjalan sekarang.'),
              ),
            ],
            const SizedBox(height: 8),
            ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: _ok ? () => Navigator.pop(context, (_data(), _reason.text.trim())) : null, child: const Text('Simpan')),
      ],
    );
  }
}
