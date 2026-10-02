import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

const _contractStatuses = ['awarded', 'post_award', 'pre_mobilization', 'mobilization', 'active', 'demobilization', 'final_evaluation', 'suspended', 'closed', 'terminated'];

class _ContractsData {
  _ContractsData(this.contracts, this.contractors, this.people);
  final List<J> contracts;
  final Map<String, String> contractors;
  final Map<String, J> people;
}

class AdminContractsPage extends ConsumerStatefulWidget {
  const AdminContractsPage({super.key});
  @override
  ConsumerState<AdminContractsPage> createState() => _AdminContractsPageState();
}

class _AdminContractsPageState extends ConsumerState<AdminContractsPage> {
  late Future<_ContractsData> _future = _load();
  String _q = '';
  String? _status;
  bool _openOnly = true;

  Future<_ContractsData> _load() async {
    final api = ref.read(apiProvider);
    final contracts = await api.select(
      'contracts',
      'id,contract_no,title,contractor_id,status,status_before_hold,health_flag,risk_class,geozone,site,start_date,end_date,target_mob_date,process_owner_id,hse_reviewer_id,review_mailbox,updated_at',
      build: (q) => q.order('contract_seq', ascending: false).limit(1000),
    );
    final cids = contracts.map((c) => c['contractor_id'] as String).toSet().toList();
    final pids = {for (final c in contracts) ...[c['process_owner_id'] as String?, c['hse_reviewer_id'] as String?]}.whereType<String>().toList();
    List<J> contractors = const [];
    List<J> people = const [];
    try {
      if (cids.isNotEmpty) contractors = await api.select('contractors', Cols.contractors, build: (q) => q.inFilter('id', cids));
    } catch (_) {}
    try {
      if (pids.isNotEmpty) people = await api.select('profiles', Cols.profiles, build: (q) => q.inFilter('id', pids));
    } catch (_) {}
    return _ContractsData(
      contracts,
      {for (final c in contractors) c['id'] as String: str(c['legal_name'])},
      {for (final p in people) p['id'] as String: p},
    );
  }

  void _reload() => setState(() => _future = _load());

  String _person(_ContractsData d, String? id) => id == null ? '-' : str(d.people[id]?['full_name'], shortId(id));

  Future<void> _changePeople(J k, _ContractsData d) async {
    final res = await showDialog<(J, String)>(context: context, builder: (_) => _PeopleDialog(contract: k, people: d.people));
    if (res == null || !mounted) return;
    final ok = await adminRun(context, ref, () => ref.read(apiProvider).rpc('update_contract', {'p_contract': k['id'], 'p_patch': res.$1, 'p_reason': res.$2}),
        success: 'PIC kontrak diperbarui');
    if (ok) _reload();
  }

  Future<void> _transition(J k, String target) async {
    final api = ref.read(apiProvider);
    if (target == 'terminated') {
      final ok = await withDanger(context, ref,
          title: 'Terminasi ${k['contract_no']}',
          message: 'Kontrak diterminasi permanen: semua task terbuka dibatalkan, temuan audit dibatalkan, dan channel chat diarsipkan. Tidak bisa dibatalkan.',
          success: 'Kontrak diterminasi',
          action: (r) => api.rpc('transition_contract', {'p_contract': k['id'], 'p_target': 'terminated', 'p_reason': r}));
      if (ok) _reload();
      return;
    }
    final hold = target == 'suspended';
    final ok = await withReason(context, ref,
        title: hold ? 'Hold kontrak ${k['contract_no']}' : 'Resume kontrak ${k['contract_no']}',
        message: hold ? 'Kontrak di-hold (suspended). Contractor diberi tahu.' : 'Kontrak kembali ke status ${StatusStyle.contract(target).$2}.',
        confirmLabel: hold ? 'Hold' : 'Resume',
        destructive: hold,
        success: hold ? 'Kontrak di-hold' : 'Kontrak dilanjutkan',
        action: (r) => api.rpc('transition_contract', {'p_contract': k['id'], 'p_target': target, 'p_reason': r}));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    final canEdit = s?.can('contract.edit') ?? false;
    final canTransition = s?.can('contract.transition') ?? false;
    return AdminScaffold(
      title: 'Contract Setup',
      subtitle: 'Ringkasan semua kontrak · ganti PIC, hold/resume, terminasi',
      actions: [
        if (s?.can('contract.create') ?? false) FilledButton.icon(onPressed: () => context.go('/contracts/new'), icon: const Icon(Icons.post_add_rounded), label: const Text('Kontrak baru')),
        OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang')),
      ],
      child: AsyncView<_ContractsData>(
        future: _future,
        onRetry: _reload,
        builder: (context, d) {
          final q = _q.toLowerCase();
          final list = d.contracts.where((k) {
            final st = k['status'] as String;
            if (_status != null && st != _status) return false;
            if (_status == null && _openOnly && (st == 'closed' || st == 'terminated')) return false;
            return q.isEmpty || '${k['contract_no']} ${k['title']} ${d.contractors[k['contractor_id']] ?? ''} ${k['geozone']}'.toLowerCase().contains(q);
          }).toList();
          final counts = <String, int>{};
          for (final k in d.contracts) {
            counts.update(k['status'] as String, (v) => v + 1, ifAbsent: () => 1);
          }
          final red = d.contracts.where((k) => k['health_flag'] == 'red' && k['status'] != 'closed' && k['status'] != 'terminated').length;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ResponsiveGrid(minItemWidth: 220, children: [
              StatCard(label: 'Total kontrak', value: '${d.contracts.length}', icon: Icons.handshake_rounded),
              StatCard(label: 'Aktif', value: '${counts['active'] ?? 0}', icon: Icons.play_circle_outline_rounded, color: Brand.green, onTap: () => setState(() => _status = 'active')),
              StatCard(label: 'Di-hold', value: '${counts['suspended'] ?? 0}', icon: Icons.pause_circle_outline_rounded, color: Brand.red, onTap: () => setState(() => _status = 'suspended')),
              StatCard(label: 'Health merah', value: '$red', icon: Icons.monitor_heart_outlined, color: red > 0 ? Brand.red : Brand.green),
            ]),
            const SizedBox(height: 16),
            TableCard(
              count: list.length,
              toolbar: [
                AdminSearchField(hint: 'Cari no. kontrak / judul / contractor', onChanged: (v) => setState(() => _q = v)),
                SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<String?>(
                    initialValue: _status,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Status', prefixIcon: Icon(Icons.filter_alt_outlined, size: 20)),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Semua status')),
                      for (final st in _contractStatuses) DropdownMenuItem(value: st, child: Text('${StatusStyle.contract(st).$2} (${counts[st] ?? 0})')),
                    ],
                    onChanged: (v) => setState(() => _status = v),
                  ),
                ),
                if (_status == null) FilterChip(label: const Text('Sembunyikan closed/terminated'), selected: _openOnly, onSelected: (v) => setState(() => _openOnly = v)),
              ],
              child: d.contracts.isEmpty
                  ? const EmptyState(icon: Icons.handshake_outlined, title: 'Belum ada kontrak')
                  : DataList(
                      empty: 'Tidak ada kontrak cocok',
                      columns: const ['', 'Kontrak', 'Contractor', 'Status', 'Risiko', 'Geozone', 'Process owner', 'HSE reviewer', 'Target mob', 'Berakhir', ''],
                      onTap: (i) => context.go('/contracts/${list[i]['id']}'),
                      rows: [
                        for (final k in list)
                          [
                            HealthDot(k['health_flag'] as String?),
                            CellText(str(k['contract_no']), subtitle: str(k['title']), maxWidth: 260),
                            Text(d.contractors[k['contractor_id']] ?? shortId(k['contractor_id'])),
                            StatusBadge.contract(k['status'] as String?),
                            StatusBadge.generic(k['risk_class'] as String?),
                            Text(str(k['geozone'])),
                            Text(_person(d, k['process_owner_id'] as String?)),
                            Text(_person(d, k['hse_reviewer_id'] as String?)),
                            Text(fmtDate(k['target_mob_date'])),
                            Text(fmtDate(k['end_date'])),
                            _ContractMenu(
                              contract: k,
                              canEdit: canEdit,
                              canTransition: canTransition,
                              onOpen: () => context.go('/contracts/${k['id']}'),
                              onPeople: () => _changePeople(k, d),
                              onTransition: (t) => _transition(k, t),
                            ),
                          ],
                      ],
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

class _ContractMenu extends StatelessWidget {
  const _ContractMenu({required this.contract, required this.canEdit, required this.canTransition, required this.onOpen, required this.onPeople, required this.onTransition});
  final J contract;
  final bool canEdit, canTransition;
  final VoidCallback onOpen, onPeople;
  final ValueChanged<String> onTransition;

  @override
  Widget build(BuildContext context) {
    final st = contract['status'] as String;
    final closed = st == 'closed' || st == 'terminated';
    return PopupMenuButton<String>(
      tooltip: 'Aksi',
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      onSelected: (v) => switch (v) {
        'open' => onOpen(),
        'people' => onPeople(),
        _ => onTransition(v),
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.open_in_new_rounded), title: Text('Buka detail'))),
        if (canEdit && !closed) const PopupMenuItem(value: 'people', child: ListTile(leading: Icon(Icons.manage_accounts_outlined), title: Text('Ganti PO / reviewer'))),
        if (canTransition && !closed && st != 'suspended')
          const PopupMenuItem(value: 'suspended', child: ListTile(leading: Icon(Icons.pause_circle_outline_rounded, color: Brand.amber), title: Text('Hold kontrak'))),
        if (canTransition && st == 'suspended' && contract['status_before_hold'] != null)
          PopupMenuItem(
            value: contract['status_before_hold'] as String,
            child: ListTile(leading: const Icon(Icons.play_circle_outline_rounded, color: Brand.green), title: Text('Resume → ${StatusStyle.contract(contract['status_before_hold'] as String?).$2}')),
          ),
        if (canTransition && !closed) const PopupMenuItem(value: 'terminated', child: ListTile(leading: Icon(Icons.dangerous_outlined, color: Brand.red), title: Text('Terminasi…'))),
      ],
    );
  }
}

class _PeopleDialog extends ConsumerStatefulWidget {
  const _PeopleDialog({required this.contract, required this.people});
  final J contract;
  final Map<String, J> people;
  @override
  ConsumerState<_PeopleDialog> createState() => _PeopleDialogState();
}

class _PeopleDialogState extends ConsumerState<_PeopleDialog> {
  late J? _po = widget.people[widget.contract['process_owner_id']] ?? {'id': widget.contract['process_owner_id']};
  late J? _rev = widget.people[widget.contract['hse_reviewer_id']] ?? {'id': widget.contract['hse_reviewer_id']};
  late final _mailbox = TextEditingController(text: str(widget.contract['review_mailbox'], ''));
  final _reason = TextEditingController();

  J get _patch {
    final p = <String, dynamic>{};
    if (_po?['id'] != widget.contract['process_owner_id']) p['process_owner_id'] = _po?['id'];
    if (_rev?['id'] != widget.contract['hse_reviewer_id']) p['hse_reviewer_id'] = _rev?['id'];
    final mb = _mailbox.text.trim();
    if (mb.isNotEmpty && mb != widget.contract['review_mailbox']) p['review_mailbox'] = mb;
    return p;
  }

  Widget _pick(String label, J? who, String role, ValueChanged<J> onPick) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final u = await showUserPicker(context, ref, title: label, roleKey: role == 'hse_reviewer' ? null : role);
          if (u != null) onPick(u);
        },
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.person_search_rounded)),
          child: Text(who == null ? '-' : (who['full_name'] != null ? '${who['full_name']} · ${str(who['email'])}' : 'User ${shortId(who['id'])}')),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ok = _patch.isNotEmpty && _reason.text.trim().length >= 5;
    return AlertDialog(
      title: Text('PIC kontrak ${widget.contract['contract_no']}'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _pick('Process owner (role process_owner)', _po, 'process_owner', (u) => setState(() => _po = u)),
          const SizedBox(height: 12),
          _pick('HSE reviewer (role hse_reviewer / hse_admin)', _rev, 'hse_reviewer', (u) => setState(() => _rev = u)),
          const SizedBox(height: 12),
          TextField(controller: _mailbox, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Review mailbox', prefixIcon: Icon(Icons.alternate_email_rounded))),
          const SizedBox(height: 8),
          Text('Server memvalidasi role PIC; channel chat kontrak disinkronkan otomatis. Risiko: ${Labels.of(Labels.risk, widget.contract['risk_class'])}.', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          ReasonField(controller: _reason, onChanged: (_) => setState(() {})),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: ok ? () => Navigator.pop(context, (_patch, _reason.text.trim())) : null, child: const Text('Simpan')),
      ],
    );
  }
}
