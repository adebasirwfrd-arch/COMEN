import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'contract_common.dart';

class _ListData {
  _ListData(this.contracts, this.contractors);
  final List<J> contracts;
  final Map<String, J> contractors;
}

class ContractListPage extends ConsumerStatefulWidget {
  const ContractListPage({super.key});
  @override
  ConsumerState<ContractListPage> createState() => _ContractListPageState();
}

class _ContractListPageState extends ConsumerState<ContractListPage> {
  late Future<_ListData> _future = _load();
  StreamSubscription<String>? _sub;
  final _search = TextEditingController();
  String _group = 'running';
  String? _status;
  String? _health;

  static const _cols = 'id,contract_seq,contract_no,contractor_id,title,geozone,site,risk_class,start_date,end_date,target_mob_date,'
      'status,health_flag,compressed_timeline,golive_requested_at,golive_approved_at,closed_at,updated_at';

  @override
  void initState() {
    super.initState();
    _sub = ref.read(notificationBus).stream.listen((_) => _reload());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<_ListData> _load() async {
    final api = ref.read(apiProvider);
    final rows = await api.select('contracts', _cols, build: (q) => q.order('contract_seq', ascending: false).limit(500));
    final ids = rows.map((r) => r['contractor_id']).whereType<String>().toSet().toList();
    final cs = ids.isEmpty ? <J>[] : await api.select('contractors', Cols.contractors, build: (q) => q.inFilter('id', ids).limit(500));
    return _ListData(rows, {for (final c in cs) c['id'] as String: c});
  }

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  bool _match(J k, Map<String, J> cs) {
    final st = k['status'] as String?;
    final inGroup = switch (_group) {
      'running' => contractOpen.contains(st),
      'hold' => st == 'suspended',
      'done' => st == 'closed' || st == 'terminated',
      _ => true,
    };
    if (!inGroup) return false;
    if (_status != null && st != _status) return false;
    if (_health != null && k['health_flag'] != _health) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    final c = cs[k['contractor_id']];
    return [k['contract_no'], k['title'], k['site'], k['geozone'], c?['legal_name'], c?['trading_name']]
        .whereType<String>()
        .any((v) => v.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref);
    if (s == null) return const LoadingView();
    final canCreate = s.isWfrd && s.can('contract.create');
    return PageScaffold(
      title: 'Kontrak',
      subtitle: s.isWfrd ? 'Seluruh kontrak sesuai hak akses Anda · status, fase & kesehatan' : 'Kontrak ${s.contractorName ?? 'perusahaan Anda'} dengan Weatherford',
      actions: [
        IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
        if (canCreate) FilledButton.icon(onPressed: () => context.go('/contracts/new'), icon: const Icon(Icons.add_rounded), label: const Text('Kontrak baru')),
      ],
      child: AsyncView<_ListData>(
        future: _future,
        onRetry: _reload,
        builder: (context, d) {
          final all = d.contracts;
          final rows = all.where((k) => _match(k, d.contractors)).toList();
          final running = all.where((k) => contractOpen.contains(k['status'])).length;
          final red = all.where((k) => k['health_flag'] == 'red' && contractOpen.contains(k['status'])).length;
          final golive = all.where((k) => k['status'] == 'mobilization' && k['golive_requested_at'] != null).length;
          final hold = all.where((k) => k['status'] == 'suspended').length;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ResponsiveGrid(minItemWidth: 210, children: [
              StatCard(label: 'Kontrak berjalan', value: '$running', icon: Icons.handshake_rounded, onTap: () => setState(() {
                    _group = 'running';
                    _health = null;
                    _status = null;
                  })),
              StatCard(label: 'Health merah', value: '$red', icon: Icons.local_fire_department_rounded, color: Brand.red, onTap: () => setState(() {
                    _group = 'running';
                    _health = 'red';
                  })),
              StatCard(label: 'Menunggu Go-Live', value: '$golive', icon: Icons.rocket_launch_rounded, color: Brand.purple, onTap: () => setState(() {
                    _group = 'running';
                    _status = 'mobilization';
                  })),
              StatCard(label: 'On hold', value: '$hold', icon: Icons.pause_circle_rounded, color: Brand.amber, onTap: () => setState(() {
                    _group = 'hold';
                    _status = null;
                  })),
            ]),
            const SizedBox(height: 20),
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        hintText: 'Cari nomor, judul, contractor, site…',
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(_search.clear)),
                      ),
                    ),
                  ),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'running', label: Text('Berjalan'), icon: Icon(Icons.play_circle_outline_rounded)),
                      ButtonSegment(value: 'hold', label: Text('Hold'), icon: Icon(Icons.pause_circle_outline_rounded)),
                      ButtonSegment(value: 'done', label: Text('Selesai'), icon: Icon(Icons.task_alt_rounded)),
                      ButtonSegment(value: 'all', label: Text('Semua')),
                    ],
                    selected: {_group},
                    onSelectionChanged: (v) => setState(() {
                      _group = v.first;
                      _status = null;
                    }),
                  ),
                  SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<String?>(
                      key: ValueKey('st-$_group-$_status'),
                      initialValue: _status,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Status', prefixIcon: Icon(Icons.flag_outlined)),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('Semua status')),
                        for (final st in [...contractFlow, 'suspended', 'terminated'])
                          DropdownMenuItem<String?>(value: st, child: Text(StatusStyle.contract(st).$2)),
                      ],
                      onChanged: (v) => setState(() {
                        _status = v;
                        if (v != null) _group = 'all';
                      }),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('Health:', style: Theme.of(context).textTheme.labelLarge),
                  for (final h in const [null, 'normal', 'warning', 'red'])
                    ChoiceChip(
                      avatar: h == null ? null : HealthDot(h),
                      label: Text(h == null ? 'Semua' : healthLabel(h)),
                      selected: _health == h,
                      onSelected: (_) => setState(() => _health = h),
                    ),
                  const SizedBox(width: 8),
                  Text('${rows.length} dari ${all.length} kontrak', style: Theme.of(context).textTheme.bodySmall),
                ]),
              ]),
            ),
            const SizedBox(height: 16),
            if (all.isEmpty)
              SectionCard(
                child: EmptyState(
                  icon: Icons.handshake_outlined,
                  title: 'Belum ada kontrak',
                  message: s.isWfrd ? 'Kontrak hanya bisa dibuat untuk vendor dengan ASL aktif.' : 'Kontrak dari Weatherford akan muncul di sini.',
                  action: canCreate ? FilledButton.icon(onPressed: () => context.go('/contracts/new'), icon: const Icon(Icons.add_rounded), label: const Text('Buat kontrak')) : null,
                ),
              )
            else if (rows.isEmpty)
              const SectionCard(child: EmptyState(icon: Icons.filter_alt_off_rounded, title: 'Tidak ada kontrak yang cocok', message: 'Ubah filter atau kata kunci pencarian.'))
            else
              LayoutBuilder(builder: (context, c) => c.maxWidth >= 900 ? _Table(rows: rows, cs: d.contractors, showContractor: s.isWfrd) : _Cards(rows: rows, cs: d.contractors)),
          ]);
        },
      ),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({required this.rows, required this.cs, required this.showContractor});
  final List<J> rows;
  final Map<String, J> cs;
  final bool showContractor;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: DataList(
          columns: ['', 'Kontrak', if (showContractor) 'Contractor', 'Status', 'Risiko', 'Geozone / site', 'Target mob', 'Selesai'],
          rows: [
            for (final k in rows)
              [
                HealthDot(k['health_flag'] as String?),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      MonoText(str(k['contract_no'], 'CTR-…'), size: 12),
                      if (k['compressed_timeline'] == true) ...[
                        const SizedBox(width: 6),
                        const Tooltip(message: 'Timeline dipadatkan', child: Icon(Icons.compress_rounded, size: 14, color: Brand.amber)),
                      ],
                    ]),
                    Text(str(k['title']), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ),
                if (showContractor)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(str(cs[k['contractor_id']]?['legal_name']), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  StatusBadge.contract(k['status'] as String?),
                  if (k['status'] == 'mobilization' && k['golive_requested_at'] != null) const StatusBadge(Brand.purple, 'Go-Live diminta', icon: Icons.rocket_launch_rounded),
                ]),
                StatusBadge(riskClassColor(k['risk_class'] as String?), riskClassLabel[k['risk_class']] ?? '-'),
                Text('${str(k['geozone'])}${k['site'] == null ? '' : ' · ${k['site']}'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(fmtDate(k['target_mob_date'])),
                Text(fmtDate(k['end_date'])),
              ],
          ],
          onTap: (i) => context.go('/contracts/${rows[i]['id']}'),
        ),
      );
}

class _Cards extends StatelessWidget {
  const _Cards({required this.rows, required this.cs});
  final List<J> rows;
  final Map<String, J> cs;

  @override
  Widget build(BuildContext context) => Column(children: [
        for (final k in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => context.go('/contracts/${k['id']}'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      HealthDot(k['health_flag'] as String?),
                      const SizedBox(width: 8),
                      Expanded(child: MonoText(str(k['contract_no'], 'CTR-…'), size: 12)),
                      StatusBadge.contract(k['status'] as String?),
                    ]),
                    const SizedBox(height: 8),
                    Text(str(k['title']), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(str(cs[k['contractor_id']]?['legal_name']), style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      StatusBadge(riskClassColor(k['risk_class'] as String?), 'Risiko ${riskClassLabel[k['risk_class']] ?? '-'}'),
                      StatusBadge(Brand.cyan, 'Mob ${fmtDate(k['target_mob_date'])}', icon: Icons.local_shipping_outlined),
                      StatusBadge(Brand.grey, 'Selesai ${fmtDate(k['end_date'])}', icon: Icons.event_available_rounded),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
      ]);
}
