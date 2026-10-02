import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;

const _cols = 'id,task_id,base_task_id,revision,scope,kind,status,phase,title,doc_type_code,doc_label,contractor_id,'
    'contractor_name,contract_id,contract_no,subcontractor_id,due_date,review_due_at,is_mandatory,is_blocker,assigned_to,'
    'reviewer_id,expiry_date,upload_confirmed_at,email_verified,created_at,updated_at,is_overdue,review_overdue';
const _activeStatuses = ['open', 'awaiting_email', 'file_issue', 'submitted', 'under_review'];
const _openStatuses = ['open', 'awaiting_email', 'file_issue'];
const _pageSize = 25;

const _statusChips = <(String, String)>[
  ('', 'Semua aktif'),
  ('open', 'Open'),
  ('awaiting_email', 'Menunggu email'),
  ('file_issue', 'File bermasalah'),
  ('submitted', 'Submitted'),
  ('under_review', 'Under review'),
  ('approved', 'Approved'),
  ('revise', 'Revisi'),
  ('rejected', 'Ditolak'),
  ('expired', 'Kedaluwarsa'),
  ('waived', 'Waived'),
  ('cancelled', 'Dibatalkan'),
  ('superseded', 'Superseded'),
  ('all', 'Semua status'),
];

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _Filters {
  const _Filters({this.q = '', this.status = '', this.filter = '', this.contract = '', this.phase = '', this.kind = ''});
  factory _Filters.from(Map<String, String> p) => _Filters(
        q: (p['q'] ?? '').trim(),
        status: p['status'] ?? '',
        filter: const {'overdue', 'due7'}.contains(p['filter']) ? p['filter']! : '',
        contract: p['contract'] ?? '',
        phase: Labels.phase.containsKey(p['phase']) ? p['phase']! : '',
        kind: Labels.kind.containsKey(p['kind']) ? p['kind']! : '',
      );
  final String q, status, filter, contract, phase, kind;

  Map<String, String> get params => {
        if (q.isNotEmpty) 'q': q,
        if (status.isNotEmpty) 'status': status,
        if (filter.isNotEmpty) 'filter': filter,
        if (contract.isNotEmpty) 'contract': contract,
        if (phase.isNotEmpty) 'phase': phase,
        if (kind.isNotEmpty) 'kind': kind,
      };
  String get key => params.entries.map((e) => '${e.key}=${e.value}').join('&');
  bool get isDefault => params.isEmpty;

  _Filters copyWith({String? q, String? status, String? filter, String? contract, String? phase, String? kind}) => _Filters(
        q: q ?? this.q,
        status: status ?? this.status,
        filter: filter ?? this.filter,
        contract: contract ?? this.contract,
        phase: phase ?? this.phase,
        kind: kind ?? this.kind,
      );
}

class _Page {
  _Page(this.rows, this.hasNext);
  final List<J> rows;
  final bool hasNext;
}

class TaskListPage extends ConsumerStatefulWidget {
  const TaskListPage({super.key});
  @override
  ConsumerState<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends ConsumerState<TaskListPage> {
  _Filters _f = const _Filters();
  String? _key;
  int _page = 0;
  String _sort = 'due_asc';
  Future<_Page>? _future;
  Future<J>? _stats;
  List<J> _contracts = const [];
  final _search = TextEditingController();
  Timer? _debounce;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _stats = ref.read(apiProvider).rpcMap('get_dashboard').catchError((_) => <String, dynamic>{});
    ref
        .read(apiProvider)
        .select('contracts', 'id,contract_no,title,status,contractor_id', build: (q) => q.order('contract_no', ascending: true).limit(500))
        .then((r) => mounted ? setState(() => _contracts = r) : null)
        .catchError((_) => null);
    _sub = ref.read(notificationBus).stream.listen((_) => _reload());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final f = _Filters.from(GoRouterState.of(context).uri.queryParameters);
    if (f.key != _key || _future == null) {
      _key = f.key;
      _f = f;
      _page = 0;
      if (_search.text.trim() != f.q) _search.text = f.q;
      _future = _load();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _future = _load();
      _stats = ref.read(apiProvider).rpcMap('get_dashboard').catchError((_) => <String, dynamic>{});
    });
  }

  void _go(_Filters f) {
    final p = f.params;
    context.go(Uri(path: '/tasks', queryParameters: p.isEmpty ? null : p).toString());
  }

  Future<_Page> _load() async {
    final f = _f;
    final today = DateTime.now();
    final from = _page * _pageSize;
    final rows = await ref.read(apiProvider).select('v_task_tracking', _cols, build: (q) {
      var b = q;
      if (f.status.isEmpty) {
        b = b.inFilter('status', _activeStatuses);
      } else if (f.status != 'all') {
        b = b.eq('status', f.status);
      }
      if (f.filter == 'overdue') b = b.eq('is_overdue', true);
      if (f.filter == 'due7') {
        b = b.inFilter('status', _openStatuses).gte('due_date', _ymd(today)).lte('due_date', _ymd(today.add(const Duration(days: 7))));
      }
      if (f.contract == 'none') {
        b = b.isFilter('contract_id', null);
      } else if (uuidRe.hasMatch(f.contract)) {
        b = b.eq('contract_id', f.contract);
      }
      if (f.phase.isNotEmpty) b = b.eq('phase', f.phase);
      if (f.kind.isNotEmpty) b = b.eq('kind', f.kind);
      final s = f.q.replaceAll(RegExp(r'[,()%*\\"]'), ' ').trim();
      if (s.isNotEmpty) b = b.or('task_id.ilike.%$s%,title.ilike.%$s%');
      final ordered = switch (_sort) {
        'due_desc' => b.order('due_date', ascending: false, nullsFirst: false),
        'updated' => b.order('updated_at', ascending: false),
        'review' => b.order('review_due_at', ascending: true, nullsFirst: false),
        _ => b.order('due_date', ascending: true, nullsFirst: false),
      };
      return ordered.order('task_id', ascending: true).range(from, from + _pageSize);
    });
    return _Page(rows.take(_pageSize).toList(), rows.length > _pageSize);
  }

  void _setPage(int p) => setState(() {
        _page = p;
        _future = _load();
      });

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted && v.trim() != _f.q) _go(_f.copyWith(q: v.trim()));
    });
  }

  Future<void> _openAdhoc() async {
    final r = await showDialog<J>(context: context, builder: (_) => _AdhocTaskDialog(contracts: _contracts));
    if (r != null && mounted) {
      showSnack(context, 'Task ${r['task_id']} dibuat');
      context.go('/tasks/${r['id']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(sessionProvider);
    if (st is! SessionReady) return const LoadingView();
    final s = st.s;
    final canAdhoc = s.isWfrd && s.can('task.generate');
    return PageScaffold(
      title: 'Task',
      subtitle: s.isWfrd ? 'Semua task contractor sesuai hak akses Anda' : 'Kewajiban dokumen & action ${s.contractorName ?? 'perusahaan'} Anda',
      actions: [
        if (s.isWfrd && s.can('task.view'))
          OutlinedButton.icon(onPressed: () => context.go('/tasks/tracking'), icon: const Icon(Icons.insights_rounded), label: const Text('Tracking')),
        if (s.isWfrd && s.can('task.review'))
          OutlinedButton.icon(onPressed: () => context.go('/tasks/review'), icon: const Icon(Icons.fact_check_rounded), label: const Text('Antrean review')),
        if (canAdhoc) FilledButton.icon(onPressed: _openAdhoc, icon: const Icon(Icons.add_task_rounded), label: const Text('Task ad-hoc')),
        IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _QuickStats(future: _stats!, s: s, filters: _f, onFilter: _go),
        const SizedBox(height: 16),
        _FilterBar(
          filters: _f,
          contracts: _contracts,
          search: _search,
          sort: _sort,
          showVendorScope: true,
          onSearch: _onSearch,
          onChanged: _go,
          onSort: (v) => setState(() {
            _sort = v;
            _page = 0;
            _future = _load();
          }),
        ),
        const SizedBox(height: 16),
        AsyncView<_Page>(
          future: _future!,
          onRetry: _reload,
          builder: (context, p) => _Results(
            page: p,
            pageIndex: _page,
            filtered: !_f.isDefault,
            onReset: () => _go(const _Filters()),
            onPage: _setPage,
          ),
        ),
      ]),
    );
  }
}

// ═══════════════════════════ Quick stats ═══════════════════════════
class _QuickStats extends StatelessWidget {
  const _QuickStats({required this.future, required this.s, required this.filters, required this.onFilter});
  final Future<J> future;
  final SessionState s;
  final _Filters filters;
  final ValueChanged<_Filters> onFilter;

  int _n(dynamic v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) => FutureBuilder<J>(
        future: future,
        builder: (context, snap) {
          final d = snap.data ?? const <String, dynamic>{};
          String v(String k) => snap.hasData ? '${_n(d[k])}' : '…';
          return ResponsiveGrid(minItemWidth: 210, spacing: 12, children: [
            StatCard(
              label: 'Task terbuka',
              value: v('tasks_open'),
              icon: Icons.assignment_rounded,
              onTap: () => onFilter(const _Filters()),
            ),
            StatCard(
              label: 'Overdue',
              value: v('tasks_overdue'),
              icon: Icons.alarm_rounded,
              color: Brand.red,
              caption: filters.filter == 'overdue' ? 'Filter aktif' : null,
              onTap: () => onFilter(filters.copyWith(filter: filters.filter == 'overdue' ? '' : 'overdue', status: '')),
            ),
            StatCard(
              label: 'Jatuh tempo ≤ 7 hari',
              value: v('tasks_due_7d'),
              icon: Icons.event_rounded,
              color: Brand.amber,
              caption: filters.filter == 'due7' ? 'Filter aktif' : null,
              onTap: () => onFilter(filters.copyWith(filter: filters.filter == 'due7' ? '' : 'due7', status: '')),
            ),
            StatCard(
              label: s.isWfrd ? 'Dalam review' : 'Dalam review WFRD',
              value: v('tasks_in_review'),
              icon: Icons.fact_check_rounded,
              color: Brand.purple,
              caption: _n(d['review_overdue']) > 0 ? '${_n(d['review_overdue'])} melewati SLA' : null,
              onTap: () => s.isWfrd && s.can('task.review') ? context.go('/tasks/review') : onFilter(filters.copyWith(status: 'submitted', filter: '')),
            ),
          ]);
        },
      );
}

// ═══════════════════════════ Filter bar ═══════════════════════════
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filters,
    required this.contracts,
    required this.search,
    required this.sort,
    required this.showVendorScope,
    required this.onSearch,
    required this.onChanged,
    required this.onSort,
  });
  final _Filters filters;
  final List<J> contracts;
  final TextEditingController search;
  final String sort;
  final bool showVendorScope;
  final ValueChanged<String> onSearch;
  final ValueChanged<_Filters> onChanged;
  final ValueChanged<String> onSort;

  Widget _drop(String label, String value, List<(String, String)> items, ValueChanged<String> onChanged, {required double width, IconData? icon}) {
    final all = [...items];
    if (!all.any((e) => e.$1 == value)) all.add((value, value));
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label|$value|${items.length}'),
        initialValue: value,
        isExpanded: true,
        menuMaxHeight: 420,
        decoration: InputDecoration(labelText: label, prefixIcon: icon == null ? null : Icon(icon, size: 18)),
        items: [for (final (v, l) in all) DropdownMenuItem(value: v, child: Text(l, overflow: TextOverflow.ellipsis))],
        onChanged: (v) => onChanged(v ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 860;
        final w = wide ? 200.0 : c.maxWidth;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: wide ? (c.maxWidth - 4 * 200 - 4 * 12).clamp(220.0, 520.0) : c.maxWidth,
              child: TextField(
                controller: search,
                onChanged: onSearch,
                onSubmitted: (v) => onChanged(filters.copyWith(q: v.trim())),
                decoration: InputDecoration(
                  hintText: 'Cari Task ID atau judul…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: filters.q.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Hapus pencarian',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            search.clear();
                            onChanged(filters.copyWith(q: ''));
                          },
                        ),
                ),
              ),
            ),
            _drop(
              'Kontrak',
              filters.contract,
              [
                ('', 'Semua kontrak'),
                if (showVendorScope) ('none', 'Vendor (tanpa kontrak)'),
                for (final k in contracts) (k['id'] as String, '${str(k['contract_no'], 'CTR-…')} · ${str(k['title'])}'),
              ],
              (v) => onChanged(filters.copyWith(contract: v)),
              width: w,
              icon: Icons.handshake_outlined,
            ),
            _drop(
              'Fase',
              filters.phase,
              [('', 'Semua fase'), for (final e in Labels.phase.entries) (e.key, e.value)],
              (v) => onChanged(filters.copyWith(phase: v)),
              width: w,
              icon: Icons.timeline_rounded,
            ),
            _drop(
              'Jenis',
              filters.kind,
              [('', 'Semua jenis'), for (final e in Labels.kind.entries) (e.key, e.value)],
              (v) => onChanged(filters.copyWith(kind: v)),
              width: w,
              icon: Icons.category_outlined,
            ),
            _drop(
              'Urutkan',
              sort,
              const [('due_asc', 'Due terdekat'), ('due_desc', 'Due terjauh'), ('review', 'SLA review'), ('updated', 'Terakhir diperbarui')],
              onSort,
              width: w,
              icon: Icons.sort_rounded,
            ),
          ]),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (v, l) in _statusChips)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: filters.status == v,
                    avatar: v.isEmpty || v == 'all'
                        ? null
                        : Container(width: 8, height: 8, decoration: BoxDecoration(color: StatusStyle.task(v).$1, shape: BoxShape.circle)),
                    label: Text(l),
                    onSelected: (_) => onChanged(filters.copyWith(status: v)),
                  ),
                ),
              Container(width: 1, height: 28, color: Theme.of(context).dividerColor, margin: const EdgeInsets.symmetric(horizontal: 8)),
              FilterChip(
                selected: filters.filter == 'overdue',
                avatar: const Icon(Icons.alarm_rounded, size: 16, color: Brand.red),
                label: const Text('Overdue'),
                onSelected: (on) => onChanged(filters.copyWith(filter: on ? 'overdue' : '')),
              ),
              const SizedBox(width: 8),
              FilterChip(
                selected: filters.filter == 'due7',
                avatar: const Icon(Icons.event_rounded, size: 16, color: Brand.amber),
                label: const Text('Due ≤ 7 hari'),
                onSelected: (on) => onChanged(filters.copyWith(filter: on ? 'due7' : '')),
              ),
              if (!filters.isDefault) ...[
                const SizedBox(width: 8),
                TextButton.icon(onPressed: () => onChanged(const _Filters()), icon: const Icon(Icons.filter_alt_off_rounded, size: 18), label: const Text('Reset filter')),
              ],
            ]),
          ),
        ]);
      }),
    );
  }
}

// ═══════════════════════════ Results ═══════════════════════════
class _Results extends StatelessWidget {
  const _Results({required this.page, required this.pageIndex, required this.filtered, required this.onReset, required this.onPage});
  final _Page page;
  final int pageIndex;
  final bool filtered;
  final VoidCallback onReset;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    if (page.rows.isEmpty) {
      return SectionCard(
        child: EmptyState(
          icon: filtered ? Icons.filter_alt_off_rounded : Icons.task_alt_rounded,
          title: filtered ? 'Tidak ada task yang cocok' : 'Tidak ada task aktif',
          message: filtered ? 'Coba ubah atau reset filter.' : 'Semua kewajiban sudah terpenuhi.',
          action: filtered ? OutlinedButton.icon(onPressed: onReset, icon: const Icon(Icons.filter_alt_off_rounded), label: const Text('Reset filter')) : null,
        ),
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final from = pageIndex * _pageSize + 1;
    final to = pageIndex * _pageSize + page.rows.length;
    final pager = Row(children: [
      Text('Menampilkan $from–$to', style: Theme.of(context).textTheme.bodySmall),
      const Spacer(),
      IconButton.outlined(tooltip: 'Sebelumnya', onPressed: pageIndex > 0 ? () => onPage(pageIndex - 1) : null, icon: const Icon(Icons.chevron_left_rounded)),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('Hal. ${pageIndex + 1}', style: const TextStyle(fontWeight: FontWeight.w700))),
      IconButton.outlined(tooltip: 'Berikutnya', onPressed: page.hasNext ? () => onPage(pageIndex + 1) : null, icon: const Icon(Icons.chevron_right_rounded)),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (wide) _TaskTable(rows: page.rows) else for (final t in page.rows) Padding(padding: const EdgeInsets.only(bottom: 12), child: _TaskCard(t: t)),
      const SizedBox(height: 12),
      pager,
    ]);
  }
}

bool _isOpen(String? s) => _openStatuses.contains(s);
bool _inReview(String? s) => s == 'submitted' || s == 'under_review';

class _DueCell extends StatelessWidget {
  const _DueCell({required this.t});
  final J t;
  @override
  Widget build(BuildContext context) {
    final status = t['status'] as String?;
    final small = Theme.of(context).textTheme.bodySmall;
    if (_inReview(status) && t['review_due_at'] != null) {
      final late = t['review_overdue'] == true;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(late ? 'SLA lewat' : 'SLA ${fmtRelative(t['review_due_at'])}',
            style: TextStyle(fontWeight: FontWeight.w800, color: late ? Brand.red : Brand.purple, fontSize: 13)),
        Text('Due ${fmtDate(t['due_date'])}', style: small),
      ]);
    }
    if (t['due_date'] == null) return const Text('-');
    final open = _isOpen(status);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(open ? dueLabel(t['due_date']) : fmtDate(t['due_date']),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: open ? dueColor(t['due_date']) : Brand.grey)),
      if (open) Text(fmtDate(t['due_date']), style: small),
    ]);
  }
}

class _Flags extends StatelessWidget {
  const _Flags({required this.t});
  final J t;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        if (t['is_blocker'] == true) const StatusBadge(Brand.red, 'Blocker', icon: Icons.block_rounded),
        if (t['is_overdue'] == true) const StatusBadge(Brand.red, 'Overdue', icon: Icons.alarm_rounded),
        if ((t['revision'] as num? ?? 0) > 0) StatusBadge(Brand.amber, 'Rev ${t['revision']}', icon: Icons.history_rounded),
        if (t['email_verified'] == true && _inReview(t['status'] as String?)) const StatusBadge(Brand.green, 'Email ✓', icon: Icons.mark_email_read_rounded),
      ]);
}

class _TaskTable extends StatelessWidget {
  const _TaskTable({required this.rows});
  final List<J> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final head = t.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 0.3);
    Widget h(String s, int flex) => Expanded(flex: flex, child: Text(s.toUpperCase(), style: head));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(children: [h('Task ID', 26), h('Dokumen', 30), h('Kontrak / Vendor', 22), h('Status', 14), h('Due', 12), h('Tanda', 16)]),
        ),
        for (final (i, r) in rows.indexed) ...[
          if (i > 0) const Divider(height: 1),
          InkWell(
            onTap: () => context.go('/tasks/${r['id']}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(children: [
                Expanded(
                  flex: 26,
                  child: Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, child: TaskIdChip(str(r['task_id'])))),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 30,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(str(r['title']), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text('${str(r['doc_label'])} · ${Labels.kindOf(r['kind'])} · ${Labels.phaseOf(r['phase'])}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 22,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (r['contract_no'] != null)
                      Text(str(r['contract_no']), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700, fontSize: 12))
                    else
                      Text(Labels.of(Labels.scope, r['scope']), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Brand.cyan)),
                    Text(str(r['contractor_name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall),
                  ]),
                ),
                Expanded(flex: 14, child: Align(alignment: Alignment.centerLeft, child: StatusBadge.task(r['status'] as String?))),
                Expanded(flex: 12, child: _DueCell(t: r)),
                Expanded(flex: 16, child: _Flags(t: r)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.t});
  final J t;
  @override
  Widget build(BuildContext context) {
    final blocker = t['is_blocker'] == true;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go('/tasks/${t['id']}'),
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: StatusStyle.task(t['status'] as String?).$1, width: 4))),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: TaskIdChip(str(t['task_id'])))),
              const SizedBox(width: 8),
              if (blocker) const Tooltip(message: 'Gate blocker', child: Icon(Icons.block_rounded, color: Brand.red, size: 20)),
            ]),
            const SizedBox(height: 10),
            Text(str(t['title']), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              [str(t['contract_no'] ?? Labels.of(Labels.scope, t['scope'])), str(t['contractor_name']), Labels.phaseOf(t['phase'])].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  StatusBadge.task(t['status'] as String?),
                  StatusBadge(Brand.blue, Labels.kindOf(t['kind']), icon: Icons.category_outlined),
                  _Flags(t: t),
                ]),
              ),
              const SizedBox(width: 8),
              _DueCell(t: t),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════ Ad-hoc task (create_adhoc_task) ═══════════════════════════
class _AdhocTaskDialog extends ConsumerStatefulWidget {
  const _AdhocTaskDialog({required this.contracts});
  final List<J> contracts;
  @override
  ConsumerState<_AdhocTaskDialog> createState() => _AdhocTaskDialogState();
}

class _AdhocTaskDialogState extends ConsumerState<_AdhocTaskDialog> {
  String _scope = 'contract';
  String? _contract, _contractor, _sub, _docType, _assignee;
  DateTime? _due;
  bool _blocker = false, _busy = false, _titleTouched = false;
  final _title = TextEditingController();
  final _sourceRef = TextEditingController();
  final _desc = TextEditingController();
  List<J> _docTypes = const [], _contractors = const [], _subs = const [], _people = const [];
  bool _loading = true;

  List<J> get _openContracts => widget.contracts.where((k) => !const {'closed', 'terminated'}.contains(k['status'])).toList();

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiProvider);
    Future.wait([
      api.select('doc_type_catalog', 'code,label,kind,phase,allowed_scopes,is_mob_gate,requirement',
          build: (q) => q.eq('active', true).order('label', ascending: true)),
      api.select('contractors', Cols.contractors, build: (q) => q.order('legal_name', ascending: true).limit(500)),
    ]).then((r) {
      if (mounted) {
        setState(() {
          _docTypes = r[0];
          _contractors = r[1];
          _loading = false;
        });
      }
    }).catchError((Object e) {
      if (mounted) {
        setState(() => _loading = false);
        handleFailure(context, ref, e);
      }
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _sourceRef.dispose();
    _desc.dispose();
    super.dispose();
  }

  String get _taskScope => _scope == 'vendor' ? 'vendor' : (_sub == null ? 'contract' : 'subcontractor');

  List<J> get _allowedDocs =>
      _docTypes.where((d) => ((d['allowed_scopes'] as List?) ?? const []).map((e) => e.toString()).contains(_taskScope)).toList();

  J? get _doc => _docTypes.where((d) => d['code'] == _docType).firstOrNull;

  Future<void> _onContract(String? id) async {
    final k = widget.contracts.where((c) => c['id'] == id).firstOrNull;
    setState(() {
      _contract = id;
      _contractor = k?['contractor_id'] as String?;
      _sub = null;
      _subs = const [];
      _assignee = null;
      _people = const [];
    });
    if (id == null) return;
    final api = ref.read(apiProvider);
    final r = await Future.wait([
      api.select('subcontractors', 'id,legal_name,sub_seq,status',
          build: (q) => q.eq('contract_id', id).inFilter('status', ['pending', 'approved']).order('sub_seq', ascending: true)).catchError((_) => <J>[]),
      _loadPeople(_contractor),
    ]);
    if (mounted && _contract == id) {
      setState(() {
        _subs = r[0];
        _people = r[1];
      });
    }
  }

  Future<List<J>> _loadPeople(String? contractorId) {
    if (contractorId == null) return Future.value(const <J>[]);
    return ref
        .read(apiProvider)
        .rpcList('list_contractor_users', {'p_contractor': contractorId})
        .then((l) => l.where((u) => u['status'] == 'active').toList())
        .catchError((_) => <J>[]);
  }

  Future<void> _onContractor(String? id) async {
    setState(() {
      _contractor = id;
      _assignee = null;
      _people = const [];
    });
    final p = await _loadPeople(id);
    if (mounted && _contractor == id) setState(() => _people = p);
  }

  void _onDoc(String? code) {
    setState(() {
      _docType = code;
      if (!_titleTouched) _title.text = str(_doc?['label'], '');
      if (_assignee == 'me' && _doc?['kind'] != 'action') _assignee = null;
    });
  }

  bool get _valid =>
      !_busy &&
      _docType != null &&
      _title.text.trim().isNotEmpty &&
      _due != null &&
      (_scope == 'vendor' ? _contractor != null : _contract != null);

  Future<void> _submit() async {
    final uid = ref.read(apiProvider).uid;
    setState(() => _busy = true);
    final r = await runAction<J>(
      context,
      ref,
      () => ref.read(apiProvider).rpcMap('create_adhoc_task', {
        'p_contractor': _scope == 'vendor' ? _contractor : null,
        'p_contract': _scope == 'vendor' ? null : _contract,
        'p_subcontractor': _scope == 'vendor' ? null : _sub,
        'p_doc_type': _docType,
        'p_title': _title.text.trim(),
        'p_due': _ymd(_due!),
        'p_is_blocker': _blocker,
        'p_assigned_to': _assignee == 'me' ? uid : _assignee,
        'p_source_ref': _sourceRef.text.trim().isEmpty ? null : _sourceRef.text.trim(),
        'p_description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) Navigator.pop(context, r);
  }

  @override
  Widget build(BuildContext context) {
    final docs = _allowedDocs;
    if (_docType != null && !docs.any((d) => d['code'] == _docType)) _docType = null;
    final isAction = _doc?['kind'] == 'action';
    return AlertDialog(
      icon: const Icon(Icons.add_task_rounded, color: Brand.blue, size: 36),
      title: const Text('Task ad-hoc'),
      content: SizedBox(
        width: 620,
        child: _loading
            ? const LoadingView(message: 'Memuat katalog dokumen…')
            : SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'contract', label: Text('Kontrak'), icon: Icon(Icons.handshake_outlined)),
                      ButtonSegment(value: 'vendor', label: Text('Vendor'), icon: Icon(Icons.apartment_rounded)),
                    ],
                    selected: {_scope},
                    onSelectionChanged: (v) => setState(() {
                      _scope = v.first;
                      _contract = null;
                      _contractor = null;
                      _sub = null;
                      _subs = const [];
                      _assignee = null;
                      _people = const [];
                    }),
                  ),
                  const SizedBox(height: 16),
                  if (_scope == 'contract') ...[
                    DropdownButtonFormField<String>(
                      key: const ValueKey('adhoc-contract'),
                      initialValue: _contract,
                      isExpanded: true,
                      menuMaxHeight: 420,
                      decoration: const InputDecoration(labelText: 'Kontrak *', prefixIcon: Icon(Icons.handshake_outlined)),
                      items: [
                        for (final k in _openContracts)
                          DropdownMenuItem(value: k['id'] as String, child: Text('${str(k['contract_no'], 'CTR-…')} · ${str(k['title'])}', overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: _onContract,
                    ),
                    if (_subs.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String?>(
                        key: ValueKey('adhoc-sub-$_contract'),
                        initialValue: _sub,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Subcontractor (opsional)', prefixIcon: Icon(Icons.account_tree_outlined)),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('— Kontraktor utama —')),
                          for (final sc in _subs)
                            DropdownMenuItem<String?>(
                              value: sc['id'] as String,
                              child: Text('S${(sc['sub_seq'] as num).toInt().toString().padLeft(2, '0')} · ${str(sc['legal_name'])}', overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) => setState(() => _sub = v),
                      ),
                    ],
                  ] else
                    DropdownButtonFormField<String>(
                      key: const ValueKey('adhoc-contractor'),
                      initialValue: _contractor,
                      isExpanded: true,
                      menuMaxHeight: 420,
                      decoration: const InputDecoration(labelText: 'Contractor *', prefixIcon: Icon(Icons.apartment_rounded)),
                      items: [
                        for (final c in _contractors)
                          DropdownMenuItem(value: c['id'] as String, child: Text(str(c['legal_name']), overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: _onContractor,
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('adhoc-doc-$_taskScope'),
                    initialValue: _docType,
                    isExpanded: true,
                    menuMaxHeight: 420,
                    decoration: InputDecoration(
                      labelText: 'Jenis dokumen *',
                      prefixIcon: const Icon(Icons.description_outlined),
                      helperText: docs.isEmpty ? 'Tidak ada jenis dokumen untuk scope ini' : '${docs.length} jenis untuk scope ${Labels.of(Labels.scope, _taskScope)}',
                    ),
                    items: [
                      for (final d in docs)
                        DropdownMenuItem(
                          value: d['code'] as String,
                          child: Text('${d['code']} · ${str(d['label'])} (${Labels.kindOf(d['kind'])})', overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _onDoc,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _title,
                    maxLength: 200,
                    onChanged: (_) => setState(() => _titleTouched = true),
                    decoration: const InputDecoration(labelText: 'Judul *', prefixIcon: Icon(Icons.title_rounded)),
                  ),
                  ResponsiveGrid(minItemWidth: 260, spacing: 12, children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        final now = DateTime.now();
                        final d = await showDatePicker(
                          context: context,
                          firstDate: DateTime(now.year, now.month, now.day),
                          lastDate: now.add(const Duration(days: 730)),
                          initialDate: _due ?? now.add(const Duration(days: 7)),
                        );
                        if (d != null) setState(() => _due = d);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'Due date *', prefixIcon: Icon(Icons.event_rounded), suffixIcon: Icon(Icons.calendar_month_rounded)),
                        child: Text(_due == null ? 'Pilih tanggal' : fmtDate(_due!.toIso8601String())),
                      ),
                    ),
                    DropdownButtonFormField<String?>(
                      key: ValueKey('adhoc-assignee-$_contractor-$isAction-${_people.length}'),
                      initialValue: _assignee,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Assignee (opsional)', prefixIcon: Icon(Icons.person_outline_rounded)),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('— Tanpa assignee —')),
                        if (isAction) const DropdownMenuItem<String?>(value: 'me', child: Text('Saya sendiri (WFRD)')),
                        for (final p in _people)
                          DropdownMenuItem<String?>(value: p['id'] as String, child: Text(str(p['full_name'] ?? p['email']), overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (v) => setState(() => _assignee = v),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    value: _blocker,
                    onChanged: (v) => setState(() => _blocker = v),
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(Icons.block_rounded, color: _blocker ? Brand.red : Brand.grey),
                    title: const Text('Gate blocker', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Task wajib selesai sebelum transisi fase kontrak.'),
                  ),
                  const SizedBox(height: 4),
                  TextField(controller: _sourceRef, maxLength: 200, decoration: const InputDecoration(labelText: 'Referensi sumber (opsional)', hintText: 'mis. MoM-12, temuan inspeksi')),
                  TextField(controller: _desc, maxLines: 3, maxLength: 4000, decoration: const InputDecoration(labelText: 'Deskripsi / instruksi (opsional)')),
                  if (_people.isEmpty && _contractor != null)
                    Text('Contractor ini belum punya pengguna aktif — task tetap terlihat oleh semua pengguna contractor.',
                        style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: _valid ? _submit : null,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_rounded),
          label: const Text('Buat task'),
        ),
      ],
    );
  }
}
