import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;

const _statusOrder = [
  'open', 'awaiting_email', 'file_issue', 'submitted', 'under_review', 'approved', 'revise', 'rejected', 'expired', 'waived', 'cancelled',
];

class _Agg {
  int total = 0, approved = 0, review = 0, open = 0, problem = 0, overdue = 0, na = 0, blockersOpen = 0, reviewLate = 0;

  void add(J t) {
    final s = t['status'] as String?;
    if (s == 'waived' || s == 'cancelled') {
      na++;
      return;
    }
    total++;
    switch (s) {
      case 'approved':
        approved++;
      case 'submitted' || 'under_review':
        review++;
        if (t['review_overdue'] == true) reviewLate++;
      case 'open' || 'awaiting_email' || 'file_issue':
        open++;
      default:
        problem++;
    }
    if (t['is_overdue'] == true) overdue++;
    if (t['is_blocker'] == true && s != 'approved') blockersOpen++;
  }

  double get pct => total == 0 ? 0 : approved / total;
  String get pctLabel => total == 0 ? '-' : '${(pct * 100).round()}%';
}

class _Group {
  _Group(this.key, this.contractId, this.label, this.contractor);
  final String key;
  final String? contractId;
  final String label, contractor;
  final all = _Agg();
  final phases = <String, _Agg>{};
}

Color _pctColor(double p) {
  if (p >= 0.999) return Brand.green;
  if (p >= 0.7) return const Color(0xFF32D583);
  if (p >= 0.4) return Brand.amber;
  return Brand.red;
}

class TaskTrackingPage extends ConsumerStatefulWidget {
  const TaskTrackingPage({super.key});
  @override
  ConsumerState<TaskTrackingPage> createState() => _TaskTrackingPageState();
}

class _TaskTrackingPageState extends ConsumerState<TaskTrackingPage> {
  late Future<List<J>> _future;
  String _contract = '';
  bool _mandatoryOnly = false;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _sub = ref.read(notificationBus).stream.listen((_) => _reload());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<List<J>> _load() => ref.read(apiProvider).select(
        'v_task_tracking',
        'id,status,phase,kind,scope,contract_id,contract_no,contractor_id,contractor_name,is_overdue,review_overdue,is_blocker,is_mandatory',
        build: (q) => q.neq('status', 'superseded').order('contract_no', ascending: true, nullsFirst: true).limit(10000),
      );

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(sessionProvider);
    final s = st is SessionReady ? st.s : null;
    return PageScaffold(
      title: 'Tracking task',
      subtitle: s?.isWfrd == true
          ? 'Progres kepatuhan per kontrak & fase (approved vs total, tanpa waived/dibatalkan)'
          : 'Progres kewajiban ${s?.contractorName ?? 'perusahaan'} Anda per kontrak & fase',
      actions: [
        OutlinedButton.icon(onPressed: () => context.go('/tasks'), icon: const Icon(Icons.list_alt_rounded), label: const Text('Daftar task')),
        IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
      ],
      child: AsyncView<List<J>>(
        future: _future,
        onRetry: _reload,
        builder: (context, rows) {
          if (rows.isEmpty) {
            return const SectionCard(child: EmptyState(icon: Icons.insights_rounded, title: 'Belum ada task', message: 'Task akan muncul setelah vendor/kontrak dibuat.'));
          }
          final options = <String, String>{};
          for (final r in rows) {
            final k = r['contract_id'] as String? ?? 'vendor:${r['contractor_id']}';
            options[k] = r['contract_id'] == null ? 'Vendor · ${str(r['contractor_name'])}' : '${str(r['contract_no'])} · ${str(r['contractor_name'])}';
          }
          if (_contract.isNotEmpty && !options.containsKey(_contract)) _contract = '';
          final filtered = rows.where((r) {
            if (_mandatoryOnly && r['is_mandatory'] != true) return false;
            if (_contract.isEmpty) return true;
            return (r['contract_id'] as String? ?? 'vendor:${r['contractor_id']}') == _contract;
          }).toList();
          return _TrackingView(
            rows: filtered,
            filterBar: _filterBar(options),
            onSelectGroup: (k) => setState(() => _contract = k),
          );
        },
      ),
    );
  }

  Widget _filterBar(Map<String, String> options) => SectionCard(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 700;
          return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: wide ? 420 : c.maxWidth,
              child: DropdownButtonFormField<String>(
                key: ValueKey('trk-$_contract-${options.length}'),
                initialValue: _contract,
                isExpanded: true,
                menuMaxHeight: 420,
                decoration: const InputDecoration(labelText: 'Kontrak / vendor', prefixIcon: Icon(Icons.handshake_outlined, size: 18)),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Semua kontrak & vendor')),
                  for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _contract = v ?? ''),
              ),
            ),
            FilterChip(
              selected: _mandatoryOnly,
              avatar: const Icon(Icons.priority_high_rounded, size: 16),
              label: const Text('Hanya wajib'),
              onSelected: (v) => setState(() => _mandatoryOnly = v),
            ),
            if (_contract.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() => _contract = ''),
                icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
                label: const Text('Semua'),
              ),
          ]);
        }),
      );
}

class _TrackingView extends StatelessWidget {
  const _TrackingView({required this.rows, required this.filterBar, required this.onSelectGroup});
  final List<J> rows;
  final Widget filterBar;
  final ValueChanged<String> onSelectGroup;

  @override
  Widget build(BuildContext context) {
    final all = _Agg();
    final byStatus = <String, int>{};
    final byPhase = <String, _Agg>{};
    final groups = <String, _Group>{};
    for (final r in rows) {
      all.add(r);
      final s = r['status'] as String? ?? '-';
      byStatus[s] = (byStatus[s] ?? 0) + 1;
      final ph = r['phase'] as String? ?? '-';
      (byPhase[ph] ??= _Agg()).add(r);
      final cid = r['contract_id'] as String?;
      final key = cid ?? 'vendor:${r['contractor_id']}';
      final g = groups[key] ??= _Group(
        key,
        cid,
        cid == null ? 'Vendor onboarding' : str(r['contract_no'], 'CTR-…'),
        str(r['contractor_name']),
      );
      g.all.add(r);
      (g.phases[ph] ??= _Agg()).add(r);
    }
    final phases = [for (final p in Labels.phase.keys) if (byPhase.containsKey(p)) p, for (final p in byPhase.keys) if (!Labels.phase.containsKey(p)) p];
    final groupList = groups.values.toList()..sort((a, b) => a.all.pct.compareTo(b.all.pct));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      filterBar,
      const SizedBox(height: 16),
      ResponsiveGrid(minItemWidth: 200, spacing: 12, children: [
        StatCard(label: 'Total task', value: '${all.total}', icon: Icons.assignment_rounded, caption: all.na > 0 ? '+${all.na} waived/dibatalkan' : null),
        StatCard(label: 'Approved', value: all.pctLabel, icon: Icons.verified_rounded, color: Brand.green, caption: '${all.approved} dari ${all.total}'),
        StatCard(label: 'Overdue', value: '${all.overdue}', icon: Icons.alarm_rounded, color: Brand.red, onTap: () => context.go('/tasks?filter=overdue')),
        StatCard(
          label: 'Dalam review',
          value: '${all.review}',
          icon: Icons.fact_check_rounded,
          color: Brand.purple,
          caption: all.reviewLate > 0 ? '${all.reviewLate} melewati SLA' : 'Semua dalam SLA',
        ),
        StatCard(label: 'Blocker belum approved', value: '${all.blockersOpen}', icon: Icons.block_rounded, color: Brand.amber),
      ]),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 1000;
        final pie = SectionCard(
          title: 'Distribusi status',
          icon: Icons.donut_large_rounded,
          child: _StatusPie(byStatus: byStatus),
        );
        final bar = SectionCard(
          title: 'Progres per fase',
          icon: Icons.stacked_bar_chart_rounded,
          subtitle: 'Approved · review · terbuka · bermasalah',
          child: SizedBox(height: 280, child: _PhaseBar(phases: phases, byPhase: byPhase)),
        );
        return wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 2, child: pie), const SizedBox(width: 16), Expanded(flex: 3, child: bar)])
            : Column(children: [pie, const SizedBox(height: 16), bar]);
      }),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Heatmap kontrak × fase',
        icon: Icons.grid_on_rounded,
        subtitle: 'Persentase approved per sel · titik merah = ada task overdue · klik sel untuk membuka daftar task',
        child: _Heatmap(groups: groupList, phases: phases),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Progres per kontrak',
        icon: Icons.handshake_rounded,
        subtitle: 'Diurutkan dari progres terendah',
        child: ResponsiveGrid(minItemWidth: 340, spacing: 12, children: [
          for (final g in groupList) _GroupCard(group: g, phases: phases, onFocus: () => onSelectGroup(g.key)),
        ]),
      ),
    ]);
  }
}

class _StatusPie extends StatelessWidget {
  const _StatusPie({required this.byStatus});
  final Map<String, int> byStatus;

  @override
  Widget build(BuildContext context) {
    final keys = [for (final s in _statusOrder) if ((byStatus[s] ?? 0) > 0) s];
    final total = keys.fold<int>(0, (a, k) => a + byStatus[k]!);
    if (total == 0) return const EmptyState(icon: Icons.donut_large_rounded, title: 'Tidak ada data');
    final chart = SizedBox(
      height: 200,
      width: 200,
      child: Stack(alignment: Alignment.center, children: [
        PieChart(PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 58,
          sections: [
            for (final k in keys)
              PieChartSectionData(
                value: byStatus[k]!.toDouble(),
                color: StatusStyle.task(k).$1,
                radius: 34,
                showTitle: byStatus[k]! / total >= 0.08,
                title: '${(byStatus[k]! * 100 / total).round()}%',
                titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11),
              ),
          ],
        )),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$total', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
          Text('task', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ]),
    );
    final legend = Wrap(spacing: 8, runSpacing: 8, children: [
      for (final k in keys)
        GestureDetector(
          onTap: () => context.go('/tasks?status=$k'),
          child: StatusBadge(StatusStyle.task(k).$1, '${StatusStyle.task(k).$2} · ${byStatus[k]}'),
        ),
    ]);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 460) return Column(children: [chart, const SizedBox(height: 16), legend]);
      return Row(children: [chart, const SizedBox(width: 20), Expanded(child: legend)]);
    });
  }
}

class _PhaseBar extends StatelessWidget {
  const _PhaseBar({required this.phases, required this.byPhase});
  final List<String> phases;
  final Map<String, _Agg> byPhase;

  static const _cReview = Brand.purple, _cOpen = Brand.blue, _cProblem = Brand.red;

  @override
  Widget build(BuildContext context) {
    if (phases.isEmpty) return const EmptyState(icon: Icons.stacked_bar_chart_rounded, title: 'Tidak ada data');
    final maxY = phases.map((p) => byPhase[p]!.total).fold<int>(1, (a, b) => a > b ? a : b).toDouble();
    return Column(children: [
      Expanded(
        child: BarChart(BarChartData(
          maxY: maxY * 1.15,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => Brand.navy,
              getTooltipItem: (g, _, rod, __) {
                final a = byPhase[phases[g.x]]!;
                return BarTooltipItem(
                  '${Labels.phaseOf(phases[g.x])}\nApproved ${a.approved} · Review ${a.review}\nTerbuka ${a.open} · Bermasalah ${a.problem}\nOverdue ${a.overdue}',
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i < 0 || i >= phases.length) return const SizedBox.shrink();
                  final l = Labels.phaseOf(phases[i]);
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(l.length > 11 ? '${l.substring(0, 10)}…' : l, style: const TextStyle(fontSize: 10)),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < phases.length; i++)
              () {
                final a = byPhase[phases[i]]!;
                final s1 = a.approved.toDouble(), s2 = s1 + a.review, s3 = s2 + a.open, s4 = s3 + a.problem;
                return BarChartGroupData(x: i, barRods: [
                  BarChartRodData(
                    toY: s4,
                    width: 26,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                    rodStackItems: [
                      BarChartRodStackItem(0, s1, Brand.green),
                      BarChartRodStackItem(s1, s2, _cReview),
                      BarChartRodStackItem(s2, s3, _cOpen),
                      BarChartRodStackItem(s3, s4, _cProblem),
                    ],
                  ),
                ]);
              }(),
          ],
        )),
      ),
      const SizedBox(height: 10),
      const Wrap(spacing: 8, runSpacing: 6, children: [
        StatusBadge(Brand.green, 'Approved'),
        StatusBadge(_cReview, 'Review'),
        StatusBadge(_cOpen, 'Terbuka'),
        StatusBadge(_cProblem, 'Ditolak/kedaluwarsa'),
      ]),
    ]);
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.groups, required this.phases});
  final List<_Group> groups;
  final List<String> phases;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) return const EmptyState(icon: Icons.grid_on_rounded, title: 'Tidak ada data');
    const cellW = 96.0, labelW = 220.0;
    final small = Theme.of(context).textTheme.bodySmall;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(width: labelW),
          for (final p in phases)
            SizedBox(
              width: cellW,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(Labels.phaseOf(p), textAlign: TextAlign.center, maxLines: 2, style: small?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ),
          SizedBox(width: cellW, child: Text('TOTAL', textAlign: TextAlign.center, style: small?.copyWith(fontWeight: FontWeight.w900))),
        ]),
        for (final g in groups)
          Row(children: [
            SizedBox(
              width: labelW,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 12)),
                  Text(g.contractor, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                ]),
              ),
            ),
            for (final p in phases) _cell(context, g, p, g.phases[p], cellW),
            _cell(context, g, null, g.all, cellW),
          ]),
      ]),
    );
  }

  Widget _cell(BuildContext context, _Group g, String? phase, _Agg? a, double w) {
    if (a == null || a.total == 0) {
      return Container(
        width: w - 6,
        height: 44,
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).dividerColor)),
        alignment: Alignment.center,
        child: Text(a != null && a.na > 0 ? 'N/A' : '–', style: const TextStyle(color: Brand.grey, fontSize: 12)),
      );
    }
    final c = _pctColor(a.pct);
    final params = <String, String>{
      'status': 'all',
      'contract': g.contractId ?? 'none',
      if (phase != null) 'phase': phase,
    };
    return Tooltip(
      message: '${phase == null ? 'Total' : Labels.phaseOf(phase)}: ${a.approved}/${a.total} approved · ${a.review} review · ${a.open} terbuka · ${a.overdue} overdue',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.go(Uri(path: '/tasks', queryParameters: params).toString()),
        child: Container(
          width: w - 6,
          height: 44,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.14 + 0.5 * a.pct),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.withValues(alpha: 0.6), width: phase == null ? 1.6 : 1),
          ),
          child: Stack(children: [
            Center(
              child: Text(a.pctLabel, style: TextStyle(fontWeight: FontWeight.w900, color: a.pct > 0.6 ? Colors.white : c, fontSize: 13)),
            ),
            if (a.overdue > 0)
              Positioned(
                top: 4,
                right: 4,
                child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Brand.red, shape: BoxShape.circle)),
              ),
          ]),
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.phases, required this.onFocus});
  final _Group group;
  final List<String> phases;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    final a = group.all;
    final c = _pctColor(a.pct);
    final t = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => context.go('/tasks?contract=${group.contractId ?? 'none'}&status=all'),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: Theme.of(context).dividerColor)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(group.label, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 13)),
                Text(group.contractor, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall),
              ]),
            ),
            Text(a.pctLabel, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: c)),
            IconButton(tooltip: 'Fokus ke kontrak ini', onPressed: onFocus, icon: const Icon(Icons.center_focus_strong_rounded, size: 20)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(value: a.pct, minHeight: 10, color: c, backgroundColor: c.withValues(alpha: 0.12)),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            StatusBadge(Brand.green, '${a.approved}/${a.total} approved'),
            if (a.review > 0) StatusBadge(Brand.purple, '${a.review} review'),
            if (a.open > 0) StatusBadge(Brand.blue, '${a.open} terbuka'),
            if (a.overdue > 0) StatusBadge(Brand.red, '${a.overdue} overdue', icon: Icons.alarm_rounded),
            if (a.blockersOpen > 0) StatusBadge(Brand.amber, '${a.blockersOpen} blocker', icon: Icons.block_rounded),
          ]),
          const SizedBox(height: 12),
          for (final p in phases)
            if (group.phases[p] != null && group.phases[p]!.total > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  SizedBox(width: 120, child: Text(Labels.phaseOf(p), style: t.bodySmall, overflow: TextOverflow.ellipsis)),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: group.phases[p]!.pct,
                        minHeight: 6,
                        color: _pctColor(group.phases[p]!.pct),
                        backgroundColor: Theme.of(context).dividerColor,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text('${group.phases[p]!.approved}/${group.phases[p]!.total}', textAlign: TextAlign.right, style: t.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
        ]),
      ),
    );
  }
}
