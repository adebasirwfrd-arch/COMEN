import 'dart:async';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;
J _m(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
double? _d(dynamic v) => v is num ? v.toDouble() : (v == null ? null : double.tryParse(v.toString()));

// ═══════════════════════════ Model skor (Part 11) ═══════════════════════════
const _defaultWeights = <String, double>{
  'trir': 15, 'ltir': 15, 'pvir': 5, 'hipo': 5, 'bbs': 10, 'finding_ontime': 10, 'training': 10, 'stopwork': 5,
  'task_ontime': 10, 'monrpt_ontime': 5, 'audit': 10,
};
const _componentLabels = <String, String>{
  'trir': 'TRIR',
  'ltir': 'LTIR',
  'pvir': 'PVIR',
  'hipo': 'High-potential',
  'bbs': 'BBS vs target',
  'finding_ontime': 'Finding closed on-time',
  'training': 'Training compliance',
  'stopwork': 'Stop-work culture',
  'task_ontime': 'Task on-time',
  'monrpt_ontime': 'Monthly report on-time',
  'audit': 'Audit score',
};
const _groups = <(String, IconData, List<String>)>[
  ('Lagging', Icons.trending_down_rounded, ['trir', 'ltir', 'pvir', 'hipo']),
  ('Leading', Icons.trending_up_rounded, ['bbs', 'finding_ontime', 'training', 'stopwork']),
  ('Compliance', Icons.verified_user_outlined, ['task_ontime', 'monrpt_ontime', 'audit']),
];
const _oprKeys = <String, String>{
  'compliance': 'Compliance',
  'responsiveness': 'Responsiveness',
  'reporting': 'Quality of reporting',
  'subcon_mgmt': 'Subcontractor management',
  'capability': 'Future capability',
};
const _recommendations = <String, String>{
  'renew': 'Renew',
  'renew_conditional': 'Renew conditional',
  'conditional': 'Conditional',
  'remove': 'Remove',
};

Color _scoreColor(num? s) {
  if (s == null) return Brand.grey;
  if (s >= 85) return Brand.green;
  if (s >= 70) return Brand.amber;
  return Brand.red;
}

Color _flagColor(dynamic c) => switch (c) { 'green' => Brand.green, 'yellow' => Brand.amber, 'red' => Brand.red, _ => Brand.grey };
String _flagLabel(dynamic c) => switch (c) { 'green' => 'Hijau', 'yellow' => 'Kuning', 'red' => 'Merah', _ => '-' };

Color _riskColor(int score) {
  if (score >= 20) return Brand.red;
  if (score >= 10) return const Color(0xFFDC6803);
  if (score >= 5) return Brand.amber;
  return Brand.green;
}

String _riskLabel(int score) => score >= 20 ? 'Critical' : score >= 10 ? 'High' : score >= 5 ? 'Medium' : 'Low';

String _month(dynamic v) {
  final d = parseDate(v);
  return d == null ? '-' : DateFormat('MMM yyyy', 'id').format(d);
}

String _num(dynamic v, [int dec = 2]) {
  final d = _d(v);
  if (d == null) return '-';
  return d == d.roundToDouble() ? NumberFormat.decimalPattern('id').format(d.round()) : d.toStringAsFixed(dec);
}

class _KpiData {
  _KpiData({required this.contracts, required this.snaps, required this.weights, required this.risks, required this.opr});
  final List<J> contracts, snaps, risks;
  final Map<String, double> weights;
  final J? opr;
}

// ═══════════════════════════ PAGE ═══════════════════════════
class KpiPage extends ConsumerStatefulWidget {
  const KpiPage({super.key});
  @override
  ConsumerState<KpiPage> createState() => _KpiPageState();
}

class _KpiPageState extends ConsumerState<KpiPage> {
  String _contract = '';
  int _months = 12;
  String? _period;
  Future<_KpiData>? _future;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(notificationBus).stream.listen((_) => _reload());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future != null) return;
    final c = GoRouterState.of(context).uri.queryParameters['contract'];
    if (c != null && uuidRe.hasMatch(c)) _contract = c;
    _future = _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<_KpiData> _load() async {
    final api = ref.read(apiProvider);
    final now = DateTime.now();
    final from = DateTime(now.year, now.month - _months + 1);
    final fromStr = '${from.year.toString().padLeft(4, '0')}-${from.month.toString().padLeft(2, '0')}-01';
    final contract = _contract;
    final res = await Future.wait<dynamic>([
      api.select('contracts', 'id,contract_no,title,status,contractor_id,health_flag,risk_class',
          build: (q) => q.order('contract_no', ascending: true).limit(500)),
      api.select('kpi_snapshots', 'contract_id,period_month,metrics,score,color,computed_at', build: (q) {
        var b = q.gte('period_month', fromStr);
        if (contract.isNotEmpty) b = b.eq('contract_id', contract);
        return b.order('period_month', ascending: true).limit(5000);
      }),
      api
          .select('app_settings', 'key,value', build: (q) => q.inFilter('key', ['kpi_weights']).limit(5))
          .catchError((_) => <J>[]),
      if (contract.isNotEmpty) ...[
        api
            .select('risk_items',
                'id,hazard,category,location_activity,likelihood,severity,risk_score,residual_likelihood,residual_severity,residual_score,'
                    'residual_approved_at,action_owner,due_date',
                build: (q) => q.eq('contract_id', contract).order('residual_score', ascending: false))
            .catchError((_) => <J>[]),
        api
            .select('opr_reviews', 'id,contract_id,final_hse_score,ratings,wfrd_score,final_score,recommendation,comments,status,signed_at,created_at,updated_at',
                build: (q) => q.eq('contract_id', contract).limit(1))
            .catchError((_) => <J>[]),
      ],
    ]);
    final weights = Map<String, double>.from(_defaultWeights);
    for (final s in res[2] as List<J>) {
      _m(s['value']).forEach((k, v) {
        final d = _d(v);
        if (d != null) weights[k] = d;
      });
    }
    final opr = contract.isEmpty ? null : (res[4] as List<J>).firstOrNull;
    return _KpiData(
      contracts: res[0] as List<J>,
      snaps: res[1] as List<J>,
      weights: weights,
      risks: contract.isEmpty ? const [] : res[3] as List<J>,
      opr: opr,
    );
  }

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  void _select(String c) => setState(() {
        _contract = c;
        _period = null;
        _future = _load();
      });

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(sessionProvider);
    final s = st is SessionReady ? st.s : null;
    return PageScaffold(
      title: 'KPI & scoring',
      subtitle: 'Skor HSE rolling 12 bulan per kontrak · ≥ 85 hijau · 70–84 kuning · < 70 merah',
      leading: _contract.isEmpty ? null : IconButton(tooltip: 'Semua kontrak', icon: const Icon(Icons.arrow_back_rounded), onPressed: () => _select('')),
      actions: [IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded))],
      child: AsyncView<_KpiData>(
        future: _future!,
        onRetry: _reload,
        builder: (context, d) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _filters(d),
          const SizedBox(height: 16),
          if (_contract.isEmpty)
            _Portfolio(d: d, onSelect: _select)
          else
            _ContractKpi(
              key: ValueKey('$_contract-$_months'),
              d: d,
              contract: d.contracts.where((k) => k['id'] == _contract).firstOrNull ?? {'id': _contract},
              period: _period,
              onPeriod: (p) => setState(() => _period = p),
              s: s,
              onChanged: _reload,
            ),
        ]),
      ),
    );
  }

  Widget _filters(_KpiData d) => SectionCard(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 760;
          final items = [
            const DropdownMenuItem(value: '', child: Text('Semua kontrak (portofolio)')),
            for (final k in d.contracts)
              DropdownMenuItem(value: k['id'] as String, child: Text('${str(k['contract_no'], 'CTR-…')} · ${str(k['title'])}', overflow: TextOverflow.ellipsis)),
          ];
          return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: wide ? 440 : c.maxWidth,
              child: DropdownButtonFormField<String>(
                key: ValueKey('kpi-$_contract-${d.contracts.length}'),
                initialValue: items.any((e) => e.value == _contract) ? _contract : '',
                isExpanded: true,
                menuMaxHeight: 420,
                decoration: const InputDecoration(labelText: 'Kontrak', prefixIcon: Icon(Icons.handshake_outlined, size: 18)),
                items: items,
                onChanged: (v) => _select(v ?? ''),
              ),
            ),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 6, label: Text('6 bln')),
                ButtonSegment(value: 12, label: Text('12 bln')),
                ButtonSegment(value: 24, label: Text('24 bln')),
              ],
              selected: {_months},
              onSelectionChanged: (v) => setState(() {
                _months = v.first;
                _period = null;
                _future = _load();
              }),
            ),
          ]);
        }),
      );
}

// ═══════════════════════════ PORTOFOLIO ═══════════════════════════
class _Portfolio extends StatelessWidget {
  const _Portfolio({required this.d, required this.onSelect});
  final _KpiData d;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final byContract = <String, List<J>>{};
    for (final s in d.snaps) {
      (byContract[s['contract_id'] as String] ??= []).add(s);
    }
    if (byContract.isEmpty) {
      return const SectionCard(
        child: EmptyState(
          icon: Icons.insights_rounded,
          title: 'Belum ada snapshot KPI',
          message: 'KPI dihitung otomatis setiap hari untuk kontrak berstatus mobilization, active, demobilization, final evaluation, atau suspended.',
        ),
      );
    }
    final contracts = {for (final k in d.contracts) k['id'] as String: k};
    final rows = [
      for (final e in byContract.entries)
        (contract: contracts[e.key] ?? {'id': e.key}, latest: e.value.last, prev: e.value.length > 1 ? e.value[e.value.length - 2] : null, all: e.value),
    ]..sort((a, b) => (_d(a.latest['score']) ?? 0).compareTo(_d(b.latest['score']) ?? 0));
    final avg = rows.map((r) => _d(r.latest['score']) ?? 0).fold<double>(0, (a, b) => a + b) / rows.length;
    final green = rows.where((r) => r.latest['color'] == 'green').length;
    final yellow = rows.where((r) => r.latest['color'] == 'yellow').length;
    final red = rows.where((r) => r.latest['color'] == 'red').length;

    final months = <String, List<double>>{};
    for (final s in d.snaps) {
      (months[s['period_month'].toString()] ??= []).add(_d(s['score']) ?? 0);
    }
    final trendKeys = months.keys.toList()..sort();
    final trend = [for (final k in trendKeys) (k, months[k]!.reduce((a, b) => a + b) / months[k]!.length)];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ResponsiveGrid(minItemWidth: 200, spacing: 12, children: [
        StatCard(label: 'Rata-rata skor terbaru', value: avg.toStringAsFixed(1), icon: Icons.speed_rounded, color: _scoreColor(avg), caption: '${rows.length} kontrak'),
        StatCard(label: 'Hijau (≥ 85)', value: '$green', icon: Icons.check_circle_rounded, color: Brand.green),
        StatCard(label: 'Kuning (70–84)', value: '$yellow', icon: Icons.error_outline_rounded, color: Brand.amber),
        StatCard(label: 'Merah (< 70 / fatality)', value: '$red', icon: Icons.dangerous_rounded, color: Brand.red),
      ]),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 1000;
        final bar = SectionCard(
          title: 'Skor terbaru per kontrak',
          icon: Icons.bar_chart_rounded,
          child: SizedBox(height: 260, child: _LatestBar(rows: [for (final r in rows) (label: str(r.contract['contract_no'], '…'), score: _d(r.latest['score']) ?? 0)])),
        );
        final line = SectionCard(
          title: 'Tren rata-rata portofolio',
          icon: Icons.show_chart_rounded,
          child: SizedBox(height: 260, child: _TrendLine(points: trend)),
        );
        return wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: bar), const SizedBox(width: 16), Expanded(child: line)])
            : Column(children: [bar, const SizedBox(height: 16), line]);
      }),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Snapshot KPI per kontrak',
        icon: Icons.table_chart_rounded,
        subtitle: 'Diurutkan dari skor terendah · klik untuk detail komponen & risk matrix',
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Column(children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) const Divider(height: 1),
            _PortfolioRow(contract: r.contract, latest: r.latest, prev: r.prev, history: r.all, onTap: () => onSelect(r.contract['id'] as String)),
          ],
        ]),
      ),
    ]);
  }
}

class _PortfolioRow extends StatelessWidget {
  const _PortfolioRow({required this.contract, required this.latest, required this.prev, required this.history, required this.onTap});
  final J contract, latest;
  final J? prev;
  final List<J> history;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final score = _d(latest['score']);
    final delta = prev == null ? null : (score ?? 0) - (_d(prev!['score']) ?? 0);
    final m = _m(latest['metrics']);
    final t = Theme.of(context).textTheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final scoreBox = Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: _flagColor(latest['color']).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        Text(score?.toStringAsFixed(1) ?? '-', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _flagColor(latest['color']))),
        Text(_flagLabel(latest['color']), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _flagColor(latest['color']))),
      ]),
    );
    final deltaW = delta == null
        ? const SizedBox(width: 60)
        : SizedBox(
            width: 60,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(delta >= 0 ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: delta >= 0 ? Brand.green : Brand.red),
              Text(delta.abs().toStringAsFixed(1), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: delta >= 0 ? Brand.green : Brand.red)),
            ]),
          );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          scoreBox,
          const SizedBox(width: 14),
          Expanded(
            flex: 4,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(str(contract['contract_no'], 'CTR-…'), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800))),
                const SizedBox(width: 8),
                if (contract['status'] != null) StatusBadge.contract(contract['status'] as String?),
              ]),
              Text(str(contract['title']), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall),
              Text('Periode ${_month(latest['period_month'])}', style: t.bodySmall),
            ]),
          ),
          if (wide) ...[
            Expanded(flex: 2, child: _MiniMetric('TRIR', _num(m['trir'], 3))),
            Expanded(flex: 2, child: _MiniMetric('LTIR', _num(m['ltir'], 3))),
            Expanded(flex: 2, child: _MiniMetric('PVIR', _num(m['pvir'], 3))),
            Expanded(flex: 2, child: _MiniMetric('Man-hours', _num(m['man_hours'], 0))),
            SizedBox(width: 110, height: 36, child: _Sparkline(values: [for (final h in history) _d(h['score']) ?? 0])),
            const SizedBox(width: 12),
          ],
          deltaW,
          const Icon(Icons.chevron_right_rounded),
        ]),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ]);
}

class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.values});
  final List<double> values;
  @override
  Widget build(BuildContext context) {
    if (values.length < 2) return const SizedBox.shrink();
    return LineChart(LineChartData(
      minY: 0,
      maxY: 100,
      lineTouchData: const LineTouchData(enabled: false),
      gridData: const FlGridData(show: false),
      titlesData: const FlTitlesData(show: false),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: [for (final (i, v) in values.indexed) FlSpot(i.toDouble(), v)],
          isCurved: true,
          barWidth: 2,
          color: _scoreColor(values.last),
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: true, color: _scoreColor(values.last).withValues(alpha: 0.1)),
        ),
      ],
    ));
  }
}

ExtraLinesData _thresholds() => ExtraLinesData(horizontalLines: [
      HorizontalLine(
        y: 85,
        color: Brand.green.withValues(alpha: 0.7),
        strokeWidth: 1,
        dashArray: [6, 4],
        label: HorizontalLineLabel(show: true, alignment: Alignment.topRight, style: const TextStyle(fontSize: 10, color: Brand.green, fontWeight: FontWeight.w700), labelResolver: (_) => '85'),
      ),
      HorizontalLine(
        y: 70,
        color: Brand.red.withValues(alpha: 0.7),
        strokeWidth: 1,
        dashArray: [6, 4],
        label: HorizontalLineLabel(show: true, alignment: Alignment.topRight, style: const TextStyle(fontSize: 10, color: Brand.red, fontWeight: FontWeight.w700), labelResolver: (_) => '70'),
      ),
    ]);

class _LatestBar extends StatelessWidget {
  const _LatestBar({required this.rows});
  final List<({String label, double score})> rows;

  @override
  Widget build(BuildContext context) {
    final shown = rows.take(20).toList();
    return BarChart(BarChartData(
      minY: 0,
      maxY: 100,
      extraLinesData: _thresholds(),
      gridData: const FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 20),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => Brand.navy,
          getTooltipItem: (g, _, rod, __) => BarTooltipItem('${shown[g.x].label}\n${rod.toY.toStringAsFixed(1)}', const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, interval: 20)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 34,
            getTitlesWidget: (v, meta) {
              final i = v.toInt();
              if (i < 0 || i >= shown.length) return const SizedBox.shrink();
              final l = shown[i].label;
              return Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.length > 8 ? '…${l.substring(l.length - 7)}' : l, style: const TextStyle(fontSize: 9)));
            },
          ),
        ),
      ),
      barGroups: [
        for (final (i, r) in shown.indexed)
          BarChartGroupData(x: i, barRods: [
            BarChartRodData(toY: r.score, color: _scoreColor(r.score), width: shown.length > 10 ? 12 : 22, borderRadius: const BorderRadius.vertical(top: Radius.circular(6))),
          ]),
      ],
    ));
  }
}

class _TrendLine extends StatelessWidget {
  const _TrendLine({required this.points, this.onTapPoint});
  final List<(String, double)> points;
  final ValueChanged<String>? onTapPoint;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const EmptyState(icon: Icons.show_chart_rounded, title: 'Belum ada data tren');
    final minY = math.max(0, (points.map((p) => p.$2).reduce(math.min) - 15) / 10).floorToDouble() * 10;
    return LineChart(LineChartData(
      minY: math.min(minY, 60),
      maxY: 100,
      extraLinesData: _thresholds(),
      gridData: const FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 10),
      borderData: FlBorderData(show: false),
      lineTouchData: LineTouchData(
        touchCallback: onTapPoint == null
            ? null
            : (e, r) {
                if (e is FlTapUpEvent && r?.lineBarSpots?.isNotEmpty == true) onTapPoint!(points[r!.lineBarSpots!.first.x.toInt()].$1);
              },
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => Brand.navy,
          getTooltipItems: (spots) => [
            for (final s in spots) LineTooltipItem('${_month(points[s.x.toInt()].$1)}\n${s.y.toStringAsFixed(1)}', const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, interval: 10)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            interval: 1,
            getTitlesWidget: (v, meta) {
              final i = v.toInt();
              if (i < 0 || i >= points.length || v != i.toDouble()) return const SizedBox.shrink();
              if (points.length > 12 && i.isOdd) return const SizedBox.shrink();
              final d = parseDate(points[i].$1);
              return Padding(padding: const EdgeInsets.only(top: 6), child: Text(d == null ? '' : DateFormat('MMM yy', 'id').format(d), style: const TextStyle(fontSize: 10)));
            },
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: [for (final (i, p) in points.indexed) FlSpot(i.toDouble(), p.$2)],
          isCurved: true,
          preventCurveOverShooting: true,
          barWidth: 3,
          color: Brand.blue,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(radius: 4.5, color: _scoreColor(spot.y), strokeWidth: 2, strokeColor: Colors.white),
          ),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Brand.blue.withValues(alpha: 0.22), Brand.blue.withValues(alpha: 0.0)]),
          ),
        ),
      ],
    ));
  }
}

// ═══════════════════════════ DETAIL KONTRAK ═══════════════════════════
class _ContractKpi extends StatelessWidget {
  const _ContractKpi({super.key, required this.d, required this.contract, required this.period, required this.onPeriod, required this.s, required this.onChanged});
  final _KpiData d;
  final J contract;
  final String? period;
  final ValueChanged<String> onPeriod;
  final SessionState? s;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final snaps = d.snaps;
    final current = snaps.where((x) => x['period_month'].toString() == period).firstOrNull ?? snaps.lastOrNull;
    final idx = current == null ? -1 : snaps.indexOf(current);
    final prev = idx > 0 ? snaps[idx - 1] : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (current == null)
        SectionCard(
          child: EmptyState(
            icon: Icons.insights_rounded,
            title: 'Belum ada snapshot KPI untuk ${str(contract['contract_no'], 'kontrak ini')}',
            message: 'Snapshot dibuat otomatis setelah kontrak memasuki fase mobilization.',
          ),
        )
      else ...[
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 1000;
          final hero = _ScoreHero(contract: contract, snap: current, prev: prev);
          final trend = SectionCard(
            title: 'Tren skor',
            icon: Icons.show_chart_rounded,
            subtitle: 'Klik titik untuk melihat komponen periode tersebut',
            child: SizedBox(
              height: 240,
              child: _TrendLine(points: [for (final x in snaps) (x['period_month'].toString(), _d(x['score']) ?? 0)], onTapPoint: onPeriod),
            ),
          );
          return wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 2, child: hero), const SizedBox(width: 16), Expanded(flex: 3, child: trend)])
              : Column(children: [hero, const SizedBox(height: 16), trend]);
        }),
        const SizedBox(height: 16),
        _Components(snap: current, weights: d.weights, periods: [for (final x in snaps) x['period_month'].toString()], onPeriod: onPeriod),
        const SizedBox(height: 16),
        _LaggingMetrics(snap: current),
      ],
      const SizedBox(height: 16),
      _RiskMatrix(risks: d.risks, s: s, onChanged: onChanged),
      const SizedBox(height: 16),
      _OprCard(contract: contract, opr: d.opr, snaps: snaps, s: s, onChanged: onChanged),
    ]);
  }
}

class _ScoreHero extends StatelessWidget {
  const _ScoreHero({required this.contract, required this.snap, required this.prev});
  final J contract, snap;
  final J? prev;

  @override
  Widget build(BuildContext context) {
    final score = _d(snap['score']) ?? 0;
    final c = _flagColor(snap['color']);
    final delta = prev == null ? null : score - (_d(prev!['score']) ?? 0);
    final m = _m(snap['metrics']);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Brand.navy, Brand.navyDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(str(contract['contract_no'], 'Kontrak'), style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 16)),
              Text(str(contract['title'], ''), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
            ]),
          ),
          if (contract['status'] != null) StatusBadge.contract(contract['status'] as String?),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          SizedBox(
            width: 128,
            height: 128,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 128,
                height: 128,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: score / 100),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, __) => CircularProgressIndicator(value: v, strokeWidth: 11, strokeCap: StrokeCap.round, color: c, backgroundColor: Colors.white12),
                ),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(score.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900)),
                Text('/ 100', style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11)),
              ]),
            ]),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              StatusBadge(c, 'KPI ${_flagLabel(snap['color'])}', icon: Icons.speed_rounded),
              const SizedBox(height: 10),
              Text('Periode ${_month(snap['period_month'])}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              if (delta != null)
                Row(children: [
                  Icon(delta >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded, color: delta >= 0 ? Brand.green : Brand.red, size: 18),
                  const SizedBox(width: 4),
                  Text('${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)} vs bulan lalu', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              if ((_d(m['fatality']) ?? 0) > 0)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('⚠ Fatality → otomatis MERAH', style: TextStyle(color: Color(0xFFFDA29B), fontWeight: FontWeight.w800, fontSize: 12)),
                ),
              const SizedBox(height: 6),
              Text('Dihitung ${fmtRelative(snap['computed_at'])}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Text(
          'Skor dihitung ulang otomatis setiap hari oleh sistem (rolling 12 bulan dari MONRPT, insiden, BBS, finding, manning, task & audit).',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 11),
        ),
      ]),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.03, end: 0);
  }
}

class _Components extends StatelessWidget {
  const _Components({required this.snap, required this.weights, required this.periods, required this.onPeriod});
  final J snap;
  final Map<String, double> weights;
  final List<String> periods;
  final ValueChanged<String> onPeriod;

  @override
  Widget build(BuildContext context) {
    final comps = _m(_m(snap['metrics'])['components']);
    final t = Theme.of(context).textTheme;
    return SectionCard(
      title: 'Komponen skor',
      icon: Icons.donut_small_rounded,
      subtitle: 'Nilai komponen 0–100 × bobot = kontribusi poin',
      trailing: periods.length < 2
          ? null
          : SizedBox(
              width: 170,
              child: DropdownButtonFormField<String>(
                key: ValueKey('per-${snap['period_month']}'),
                initialValue: snap['period_month'].toString(),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Periode'),
                items: [for (final p in periods.reversed) DropdownMenuItem(value: p, child: Text(_month(p)))],
                onChanged: (v) => v == null ? null : onPeriod(v),
              ),
            ),
      child: comps.isEmpty
          ? const EmptyState(icon: Icons.donut_small_rounded, title: 'Komponen tidak tersedia')
          : ResponsiveGrid(minItemWidth: 330, spacing: 16, children: [
              for (final (title, icon, keys) in _groups)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: Theme.of(context).dividerColor)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Icon(icon, size: 18, color: Brand.blue),
                      const SizedBox(width: 8),
                      Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800))),
                      Text(
                        '${keys.fold<double>(0, (a, k) => a + (_d(comps[k]) ?? 0) * (weights[k] ?? 0) / 100).toStringAsFixed(1)} / ${keys.fold<double>(0, (a, k) => a + (weights[k] ?? 0)).toStringAsFixed(0)}',
                        style: const TextStyle(fontWeight: FontWeight.w900, color: Brand.blue),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    for (final k in keys) ...[
                      Row(children: [
                        Expanded(child: Text(_componentLabels[k] ?? k, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                        Text('bobot ${(weights[k] ?? 0).toStringAsFixed(0)}', style: t.bodySmall),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 44,
                          child: Text(_num(comps[k], 1), textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w900, color: _scoreColor(_d(comps[k])))),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: ((_d(comps[k]) ?? 0) / 100).clamp(0, 1)),
                          duration: const Duration(milliseconds: 700),
                          builder: (_, v, __) => LinearProgressIndicator(
                            value: v,
                            minHeight: 8,
                            color: _scoreColor(_d(comps[k])),
                            backgroundColor: _scoreColor(_d(comps[k])).withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ]),
                ),
            ]),
    );
  }
}

class _LaggingMetrics extends StatelessWidget {
  const _LaggingMetrics({required this.snap});
  final J snap;
  @override
  Widget build(BuildContext context) {
    final m = _m(snap['metrics']);
    final w = _m(m['window']);
    Widget v(dynamic x, [int dec = 3]) => Text(_num(x, dec), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16));
    return SectionCard(
      title: 'Metrik HSE',
      icon: Icons.analytics_outlined,
      subtitle: 'Jendela ${fmtDate(w['from'])} – ${fmtDate(w['to'])} (eksklusif) · rate NULL bila man-hours/km = 0',
      child: KeyValueGrid(minItemWidth: 170, [
        ('TRIR', v(m['trir'])),
        ('LTIR', v(m['ltir'])),
        ('PVIR', v(m['pvir'])),
        ('Man-hours', v(m['man_hours'], 0)),
        ('Kilometer', v(m['km'], 0)),
        ('Recordables', v(m['recordables'], 0)),
        ('LTI + fatality', v(m['lti'], 0)),
        ('Preventable vehicle', v(m['pvi'], 0)),
        ('High-potential', v(m['hipo'], 0)),
        ('Fatality', Text(_num(m['fatality'], 0), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: (_d(m['fatality']) ?? 0) > 0 ? Brand.red : null))),
        ('BBS 4 minggu', v(m['bbs_4w'], 0)),
        ('Stop-work 90 hari', v(m['stopwork_90d'], 0)),
      ]),
    );
  }
}

// ── Risk matrix 5×5 ──
class _RiskMatrix extends ConsumerStatefulWidget {
  const _RiskMatrix({required this.risks, required this.s, required this.onChanged});
  final List<J> risks;
  final SessionState? s;
  final VoidCallback onChanged;
  @override
  ConsumerState<_RiskMatrix> createState() => _RiskMatrixState();
}

class _RiskMatrixState extends ConsumerState<_RiskMatrix> {
  bool _residual = true;
  (int, int)? _cell;

  int _l(J r) => ((_residual ? r['residual_likelihood'] : r['likelihood']) as num?)?.toInt() ?? 0;
  int _s(J r) => ((_residual ? r['residual_severity'] : r['severity']) as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final risks = widget.risks;
    final counts = <(int, int), int>{};
    for (final r in risks) {
      counts[(_l(r), _s(r))] = (counts[(_l(r), _s(r))] ?? 0) + 1;
    }
    final pending = risks.where((r) => ((r['residual_score'] as num?) ?? 0) >= 10 && r['residual_approved_at'] == null).toList();
    final selected = _cell == null ? const <J>[] : risks.where((r) => _l(r) == _cell!.$1 && _s(r) == _cell!.$2).toList();
    return SectionCard(
      title: 'Risk matrix 5×5',
      icon: Icons.grid_view_rounded,
      subtitle: risks.isEmpty ? 'Dari register JRA (risk_items) kontrak' : '${risks.length} risiko · ${pending.length} residual High/Critical menunggu approval',
      trailing: risks.isEmpty
          ? null
          : SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('Inherent')), ButtonSegment(value: true, label: Text('Residual'))],
              selected: {_residual},
              onSelectionChanged: (v) => setState(() {
                _residual = v.first;
                _cell = null;
              }),
            ),
      child: risks.isEmpty
          ? const EmptyState(icon: Icons.grid_view_rounded, title: 'Belum ada risk item', message: 'Risk register diisi melalui JRA (JRAREG) pada fase pre-mobilization.')
          : LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth > 900;
              final grid = _grid(context, counts, math.min(c.maxWidth, 460));
              final side = _side(context, selected, pending);
              return wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [grid, const SizedBox(width: 24), Expanded(child: side)])
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Center(child: grid), const SizedBox(height: 16), side]);
            }),
    );
  }

  Widget _grid(BuildContext context, Map<(int, int), int> counts, double maxW) {
    final cell = ((maxW - 40) / 5).clamp(44.0, 80.0);
    final small = Theme.of(context).textTheme.labelSmall;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        RotatedBox(quarterTurns: 3, child: SizedBox(width: cell * 5, child: Center(child: Text('LIKELIHOOD →', style: small?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1))))),
        const SizedBox(width: 4),
        Column(mainAxisSize: MainAxisSize.min, children: [
          for (var l = 5; l >= 1; l--)
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 16, child: Text('$l', style: small?.copyWith(fontWeight: FontWeight.w700))),
              for (var sv = 1; sv <= 5; sv++) _cellBox(l, sv, counts[(l, sv)] ?? 0, cell),
            ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 16),
            for (var sv = 1; sv <= 5; sv++) SizedBox(width: cell, child: Center(child: Text('$sv', style: small?.copyWith(fontWeight: FontWeight.w700)))),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2),
            child: SizedBox(width: cell * 5, child: Center(child: Text('SEVERITY →', style: small?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1)))),
          ),
        ]),
      ]),
      const SizedBox(height: 12),
      const Wrap(spacing: 6, runSpacing: 6, children: [
        StatusBadge(Brand.green, 'Low 1–4'),
        StatusBadge(Brand.amber, 'Medium 5–9'),
        StatusBadge(Color(0xFFDC6803), 'High 10–16'),
        StatusBadge(Brand.red, 'Critical 20–25'),
      ]),
    ]);
  }

  Widget _cellBox(int l, int sv, int n, double size) {
    final score = l * sv;
    final c = _riskColor(score);
    final sel = _cell == (l, sv);
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Tooltip(
        message: 'L$l × S$sv = $score (${_riskLabel(score)}) · $n risiko',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: n == 0 ? null : () => setState(() => _cell = sel ? null : (l, sv)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: size - 4,
            height: size - 4,
            decoration: BoxDecoration(
              color: c.withValues(alpha: n > 0 ? 0.85 : 0.18),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: sel ? Theme.of(context).colorScheme.onSurface : Colors.transparent, width: 2.5),
            ),
            child: Stack(children: [
              Positioned(left: 5, top: 3, child: Text('$score', style: TextStyle(fontSize: 9, color: n > 0 ? Colors.white70 : c, fontWeight: FontWeight.w700))),
              if (n > 0) Center(child: Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18))),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _side(BuildContext context, List<J> selected, List<J> pending) {
    final s = widget.s;
    final rows = selected.isNotEmpty ? selected : pending;
    final title = selected.isNotEmpty ? 'Risiko pada sel L${_cell!.$1} × S${_cell!.$2}' : 'Residual High/Critical menunggu approval';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (rows.isEmpty)
        const InfoBanner(message: 'Semua residual High/Critical sudah disetujui.', color: Brand.green, icon: Icons.verified_rounded)
      else
        for (final r in rows.take(12))
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
            child: Row(children: [
              _ScorePill(label: 'Inh', score: (r['risk_score'] as num?)?.toInt() ?? 0),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_forward_rounded, size: 14, color: Brand.grey),
              const SizedBox(width: 6),
              _ScorePill(label: 'Res', score: (r['residual_score'] as num?)?.toInt() ?? 0),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(str(r['hazard']), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text([str(r['category'], ''), str(r['location_activity'], ''), if (r['action_owner'] != null) 'PIC ${r['action_owner']}'].where((e) => e.isNotEmpty).join(' · '),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              if (r['residual_approved_at'] != null)
                const StatusBadge(Brand.green, 'Approved', icon: Icons.verified_rounded)
              else if (((r['residual_score'] as num?) ?? 0) >= 10) ...[
                if (s != null && s.isWfrd && s.can(((r['residual_score'] as num?) ?? 0) >= 20 ? 'risk.approve.critical' : 'risk.approve.high'))
                  TextButton.icon(
                    onPressed: () => _approve(r),
                    icon: const Icon(Icons.gavel_rounded, size: 18),
                    label: const Text('Approve'),
                  )
                else
                  const StatusBadge(Brand.amber, 'Butuh approval', icon: Icons.hourglass_top_rounded),
              ],
            ]),
          ),
    ]);
  }

  Future<void> _approve(J r) async {
    final reason = await showReasonDialog(
      context,
      title: 'Approve residual risk',
      message: '"${str(r['hazard'])}" — residual ${r['residual_score']} (${_riskLabel((r['residual_score'] as num).toInt())}). Persetujuan tercatat di audit log.',
      confirmLabel: 'Approve',
    );
    if (reason == null || !mounted) return;
    final ok = await runAction(context, ref, () async {
      await ref.read(apiProvider).rpc('approve_residual_risk', {'p_risk': r['id'], 'p_reason': reason});
      return true;
    }, success: 'Residual risk disetujui');
    if (ok == true) widget.onChanged();
  }
}

class _ScorePill extends StatelessWidget {
  const _ScorePill({required this.label, required this.score});
  final String label;
  final int score;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: _riskColor(score), borderRadius: BorderRadius.circular(8)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 8, fontWeight: FontWeight.w700)),
          Text('$score', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13)),
        ]),
      );
}

// ── OPR / final evaluation (save_opr_review) ──
class _OprCard extends ConsumerWidget {
  const _OprCard({required this.contract, required this.opr, required this.snaps, required this.s, required this.onChanged});
  final J contract;
  final J? opr;
  final List<J> snaps;
  final SessionState? s;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = opr?['status'] as String?;
    final canEdit = s != null && s!.isWfrd && s!.can('opr.conduct') && contract['status'] == 'final_evaluation' && (opr == null || status == 'draft');
    final ratings = _m(opr?['ratings']);
    final finalScore = _d(opr?['final_score']);
    return SectionCard(
      title: 'OPR — evaluasi akhir',
      icon: Icons.workspace_premium_rounded,
      subtitle: 'Final = 50% rata-rata KPI 12 bulan + 50% penilaian WFRD · ≥85 Renew · 70–84 Renew conditional · 55–69 Conditional · <55 Remove',
      trailing: canEdit
          ? FilledButton.icon(
              onPressed: () async {
                final saved = await showDialog<bool>(context: context, builder: (_) => _OprDialog(contractId: contract['id'] as String, opr: opr, snaps: snaps));
                if (saved == true) onChanged();
              },
              icon: Icon(opr == null ? Icons.add_rounded : Icons.edit_rounded),
              label: Text(opr == null ? 'Isi OPR' : 'Ubah draft'),
            )
          : null,
      child: opr == null
          ? EmptyState(
              icon: Icons.workspace_premium_outlined,
              title: 'OPR belum dibuat',
              message: contract['status'] == 'final_evaluation'
                  ? 'Kontrak dalam fase final evaluation — WFRD dapat mengisi OPR.'
                  : 'OPR diisi saat kontrak memasuki fase final evaluation.',
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(color: _scoreColor(finalScore).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                  child: Column(children: [
                    Text(finalScore?.toStringAsFixed(1) ?? '-', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: _scoreColor(finalScore))),
                    const Text('Final score', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                  ]),
                ),
                _MiniMetric('HSE (KPI)', _num(opr!['final_hse_score'], 2)),
                _MiniMetric('WFRD', _num(opr!['wfrd_score'], 2)),
                StatusBadge(
                  switch (opr!['recommendation']) { 'renew' => Brand.green, 'renew_conditional' => const Color(0xFF32D583), 'conditional' => Brand.amber, _ => Brand.red },
                  _recommendations[opr!['recommendation']] ?? str(opr!['recommendation']),
                  icon: Icons.recommend_rounded,
                ),
                StatusBadge.generic(status),
                if (opr!['signed_at'] != null) StatusBadge(Brand.green, 'Ditandatangani ${fmtDate(opr!['signed_at'])}', icon: Icons.draw_rounded),
              ]),
              const SizedBox(height: 16),
              ResponsiveGrid(minItemWidth: 260, spacing: 12, children: [
                for (final e in _oprKeys.entries)
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: Text(e.value, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(_num(ratings[e.key], 0), style: TextStyle(fontWeight: FontWeight.w900, color: _scoreColor(_d(ratings[e.key])))),
                    ]),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: ((_d(ratings[e.key]) ?? 0) / 100).clamp(0, 1),
                        minHeight: 7,
                        color: _scoreColor(_d(ratings[e.key])),
                        backgroundColor: Theme.of(context).dividerColor,
                      ),
                    ),
                  ]),
              ]),
              if (opr!['comments'] != null) ...[
                const SizedBox(height: 16),
                Text(str(opr!['comments']), style: const TextStyle(height: 1.45)),
              ],
            ]),
    );
  }
}

class _OprDialog extends ConsumerStatefulWidget {
  const _OprDialog({required this.contractId, required this.opr, required this.snaps});
  final String contractId;
  final J? opr;
  final List<J> snaps;
  @override
  ConsumerState<_OprDialog> createState() => _OprDialogState();
}

class _OprDialogState extends ConsumerState<_OprDialog> {
  late final Map<String, double> _r = {for (final k in _oprKeys.keys) k: _d(_m(widget.opr?['ratings'])[k]) ?? 75};
  String? _rec;
  late final _comments = TextEditingController(text: widget.opr?['comments'] as String?);
  bool _finalize = false, _busy = false;

  @override
  void dispose() {
    _comments.dispose();
    super.dispose();
  }

  double get _wfrd => _r.values.reduce((a, b) => a + b) / _r.length;
  double get _hse {
    final now = DateTime.now();
    final from = DateTime(now.year - 1, now.month, now.day);
    final xs = widget.snaps.where((s) => (parseDate(s['period_month']) ?? now).isAfter(from)).map((s) => _d(s['score']) ?? 0).toList();
    return xs.isEmpty ? 100 : xs.reduce((a, b) => a + b) / xs.length;
  }

  String _auto(double f) => f >= 85 ? 'renew' : f >= 70 ? 'renew_conditional' : f >= 55 ? 'conditional' : 'remove';

  Future<void> _save() async {
    if (_finalize) {
      final ok = await showConfirm(context, title: 'Finalisasi OPR?', message: 'OPR final tidak dapat diubah lagi dan siap ditandatangani.', confirmLabel: 'Finalisasi');
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    final id = await runAction(
      context,
      ref,
      () => ref.read(apiProvider).rpc('save_opr_review', {
        'p_contract': widget.contractId,
        'p_ratings': {for (final e in _r.entries) e.key: e.value.round()},
        'p_recommendation': _rec,
        'p_comments': _comments.text.trim().isEmpty ? null : _comments.text.trim(),
        'p_finalize': _finalize,
      }),
      success: _finalize ? 'OPR difinalisasi' : 'Draft OPR tersimpan',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final finalScore = 0.5 * _hse + 0.5 * _wfrd;
    return AlertDialog(
      icon: const Icon(Icons.workspace_premium_rounded, color: Brand.blue, size: 36),
      title: const Text('Penilaian OPR'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final e in _oprKeys.entries) ...[
              Row(children: [
                Expanded(child: Text(e.value, style: const TextStyle(fontWeight: FontWeight.w700))),
                Text(_r[e.key]!.round().toString(), style: TextStyle(fontWeight: FontWeight.w900, color: _scoreColor(_r[e.key]))),
              ]),
              Slider(value: _r[e.key]!, min: 0, max: 100, divisions: 20, label: _r[e.key]!.round().toString(), onChanged: (v) => setState(() => _r[e.key] = v)),
            ],
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: _scoreColor(finalScore).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Expanded(
                  child: Text(
                    'Perkiraan: HSE ${_hse.toStringAsFixed(1)} · WFRD ${_wfrd.toStringAsFixed(1)} → final ${finalScore.toStringAsFixed(1)} (${_recommendations[_auto(finalScore)]})',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 4),
            Text('Angka final dihitung ulang di server dari snapshot KPI 12 bulan.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _rec,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Rekomendasi'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Otomatis dari skor final')),
                for (final e in _recommendations.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _rec = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: _comments, maxLines: 3, maxLength: 4000, decoration: const InputDecoration(labelText: 'Komentar')),
            CheckboxListTile(
              value: _finalize,
              onChanged: (v) => setState(() => _finalize = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Finalisasi OPR (tidak bisa diubah lagi)', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_finalize ? 'Simpan & finalisasi' : 'Simpan draft')),
      ],
    );
  }
}
