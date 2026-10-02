import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../ui/classification_badges.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../contracts/contract_common.dart';

const aslActiveStatuses = {'asl_approved', 'asl_conditional'};

/// Sisa hari ASL (negatif = kedaluwarsa); null bila belum ada tanggal.
int? aslDaysLeft(J c) {
  final d = parseDate(c['asl_expires_on']);
  if (d == null) return null;
  final now = DateTime.now();
  return DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
}

bool aslActive(J c) => aslActiveStatuses.contains(c['status']) && (aslDaysLeft(c) ?? -1) >= 0;

Color aslExpiryColor(int? days) => days == null ? Brand.grey : days < 0 ? Brand.red : days <= 60 ? Brand.amber : Brand.green;

const countryNames = {
  'ID': 'Indonesia', 'MY': 'Malaysia', 'SG': 'Singapura', 'TH': 'Thailand', 'VN': 'Vietnam', 'PH': 'Filipina', 'BN': 'Brunei',
  'AU': 'Australia', 'IN': 'India', 'CN': 'Tiongkok', 'JP': 'Jepang', 'KR': 'Korea Selatan', 'AE': 'Uni Emirat Arab', 'SA': 'Arab Saudi',
  'QA': 'Qatar', 'OM': 'Oman', 'KW': 'Kuwait', 'GB': 'Inggris', 'NL': 'Belanda', 'NO': 'Norwegia', 'US': 'Amerika Serikat', 'CA': 'Kanada',
};

String countryLabel(dynamic code) => code == null ? '-' : '${countryNames[code] ?? code} ($code)';

/// Kartu status ASL dengan cincin masa berlaku.
class AslStatusCard extends StatelessWidget {
  const AslStatusCard({super.key, required this.c, this.decidedBy, this.footer});
  final J c;
  final J? decidedBy;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final status = c['status'] as String?;
    final (color, label) = StatusStyle.vendor(status);
    final days = aslDaysLeft(c);
    final hasAsl = days != null && status != 'rejected';
    final frac = hasAsl ? (days / 730).clamp(0.0, 1.0) : 0.0;
    final t = Theme.of(context).textTheme;
    return SectionCard(
      title: 'Approved Supplier List (ASL)',
      icon: Icons.verified_user_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
            width: 92,
            height: 92,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: hasAsl ? frac : 0,
                  strokeWidth: 9,
                  strokeCap: StrokeCap.round,
                  backgroundColor: color.withValues(alpha: 0.12),
                  color: hasAsl ? aslExpiryColor(days) : color,
                ),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(hasAsl ? (days < 0 ? '${-days}' : '$days') : '—', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w900, color: hasAsl ? aslExpiryColor(days) : Brand.grey)),
                Text(hasAsl ? (days < 0 ? 'hari lewat' : 'hari lagi') : 'tanpa ASL', style: t.labelSmall?.copyWith(color: Brand.grey)),
              ]),
            ]),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              StatusBadge(color, label),
              const SizedBox(height: 8),
              Text(hasAsl ? 'Berlaku s.d. ${fmtDate(c['asl_expires_on'])}' : 'Belum ada keputusan ASL aktif', style: const TextStyle(fontWeight: FontWeight.w700)),
              if (c['asl_decided_at'] != null)
                Text('Diputuskan ${fmtDate(c['asl_decided_at'])}${decidedBy == null ? '' : ' oleh ${str(decidedBy!['full_name'])}'}', style: t.bodySmall),
              if (hasAsl && days >= 0 && days <= 60)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('Segera ajukan re-evaluasi (self-assessment tahun berjalan).', style: TextStyle(color: Brand.amber, fontWeight: FontWeight.w600, fontSize: 12)),
                ),
            ]),
          ),
        ]),
        if ((c['asl_conditions'] as String?)?.isNotEmpty ?? false) ...[
          const SizedBox(height: 14),
          InfoBanner(message: 'Syarat ASL: ${c['asl_conditions']}', color: Brand.amber, icon: Icons.rule_rounded),
        ],
        if ((c['status_reason'] as String?)?.isNotEmpty ?? false) ...[
          const SizedBox(height: 10),
          InfoBanner(
            message: 'Catatan status: ${c['status_reason']}',
            color: const {'suspended', 'blacklisted', 'rejected'}.contains(status) ? Brand.red : Brand.blue,
            icon: Icons.sticky_note_2_outlined,
          ),
        ],
        if (footer != null) ...[const SizedBox(height: 12), footer!],
      ]),
    );
  }
}

/// Profil perusahaan (dari get_contractor_detail / Cols.contractors).
class CompanyProfileCard extends StatelessWidget {
  const CompanyProfileCard({super.key, required this.c, this.trailing});
  final J c;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    Widget email(dynamic v) => v == null ? const Text('-') : Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: SelectableText(v.toString())), CopyButton(v.toString(), tooltip: 'Copy email')]);
    return SectionCard(
      title: 'Data perusahaan',
      icon: Icons.apartment_rounded,
      trailing: trailing,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValueGrid([
          ('NAMA LEGAL', SelectableText(str(c['legal_name']))),
          ('NAMA DAGANG', Text(str(c['trading_name']))),
          ('NO. REGISTRASI (NIB)', SelectableText(str(c['registration_no']))),
          ('NPWP / TAX ID', SelectableText(str(c['tax_id']))),
          ('NEGARA', Text(countryLabel(c['country']))),
          ('DOMAIN EMAIL', Text(str(c['email_domain']))),
          ('WEBSITE', SelectableText(str(c['website']))),
          ('TERDAFTAR', Text(fmtDate(c['submitted_at'] ?? c['created_at']))),
        ]),
        const SizedBox(height: 12),
        Text('ALAMAT', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 0.4)),
        const SizedBox(height: 4),
        SelectableText(str(c['address']), style: const TextStyle(fontWeight: FontWeight.w600)),
        const Divider(height: 28),
        KeyValueGrid([
          ('KONTAK UTAMA', Text(str(c['primary_contact_name']))),
          ('EMAIL KONTAK', email(c['primary_contact_email'])),
          ('TELEPON', SelectableText(str(c['primary_contact_phone']))),
          ('HSE MANAGER', Text(str(c['hse_manager_name']))),
          ('EMAIL HSE MANAGER', email(c['hse_manager_email'])),
        ]),
      ]),
    );
  }
}

/// Riwayat self-assessment + metrik terhitung (TRIR/LTIR/PVIR).
class SelfAssessmentCard extends StatelessWidget {
  const SelfAssessmentCard({super.key, required this.items, this.trailing, this.emptyMessage});
  final List<J> items;
  final Widget? trailing;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    final submitted = items.where((e) => e['status'] == 'submitted').toList();
    final latest = submitted.isEmpty ? null : jm(submitted.first['computed']);
    String n(dynamic v) => v == null ? '—' : (v is num ? v.toStringAsFixed(2) : v.toString());
    final trir = latest?['trir_avg'] as num?;
    final perf = trir == null ? 30 : trir <= 0.5 ? 100 : trir <= 1.0 ? 80 : trir <= 2.0 ? 60 : 30;
    return SectionCard(
      title: 'HSE self-assessment',
      subtitle: 'TRIR/LTIR/PVIR dihitung sistem dari data 3 tahun terakhir',
      icon: Icons.assignment_turned_in_rounded,
      trailing: trailing,
      child: items.isEmpty
          ? EmptyState(icon: Icons.assignment_outlined, title: 'Belum ada self-assessment', message: emptyMessage)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (latest != null) ...[
                ResponsiveGrid(minItemWidth: 150, spacing: 10, children: [
                  _Metric('TRIR rata-rata', n(trir), trir == null ? Brand.grey : (trir <= 1 ? Brand.green : trir <= 2 ? Brand.amber : Brand.red)),
                  _Metric('Skor performa', '$perf', perf >= 80 ? Brand.green : perf >= 60 ? Brand.amber : Brand.red),
                  _Metric('Fatality 3 thn', n(latest['fatality_3y']), ((latest['fatality_3y'] as num?) ?? 0) > 0 ? Brand.red : Brand.green),
                ]),
                if (((latest['fatality_3y'] as num?) ?? 0) > 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: InfoBanner(message: 'Ada fatality dalam 3 tahun — persetujuan ASL hanya oleh HSE Director.', color: Brand.red, icon: Icons.warning_rounded),
                  ),
                const SizedBox(height: 14),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowHeight: 36,
                    dataRowMinHeight: 36,
                    dataRowMaxHeight: 40,
                    columns: const [DataColumn(label: Text('Tahun')), DataColumn(label: Text('TRIR')), DataColumn(label: Text('LTIR')), DataColumn(label: Text('PVIR'))],
                    rows: [
                      for (final y in const ['y1', 'y2', 'y3'])
                        DataRow(cells: [
                          DataCell(Text(y.toUpperCase().replaceFirst('Y', 'Y-'))),
                          DataCell(Text(n(jm(latest[y])['trir']))),
                          DataCell(Text(n(jm(latest[y])['ltir']))),
                          DataCell(Text(n(jm(latest[y])['pvir']))),
                        ]),
                    ],
                  ),
                ),
                const Divider(height: 24),
              ],
              for (final sa in items)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(sa['status'] == 'submitted' ? Icons.task_alt_rounded : Icons.edit_note_rounded, color: sa['status'] == 'submitted' ? Brand.green : Brand.grey),
                  title: Text('Periode ${sa['year'] ?? sa['period_year']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(sa['status'] == 'submitted' ? 'Dikirim ${fmtDate(sa['submitted_at'])}' : 'Draft'),
                  trailing: StatusBadge(sa['status'] == 'submitted' ? Brand.green : Brand.grey, sa['status'] == 'submitted' ? 'Submitted' : 'Draft'),
                ),
            ]),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.color);
  final String label, value;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.25))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color)),
        ]),
      );
}

/// Task dokumen vendor (scope vendor, v_task_tracking).
class VendorTasksCard extends StatefulWidget {
  const VendorTasksCard({super.key, required this.tasks, this.footer});
  final List<J> tasks;
  final Widget? footer;
  @override
  State<VendorTasksCard> createState() => _VendorTasksCardState();
}

class _VendorTasksCardState extends State<VendorTasksCard> {
  String _f = 'open';

  static const _openSt = {'open', 'awaiting_email', 'file_issue', 'revise'};
  static const _reviewSt = {'submitted', 'under_review'};
  static const _doneSt = {'approved', 'waived'};

  @override
  Widget build(BuildContext context) {
    final live = widget.tasks.where((t) => !const {'superseded', 'cancelled'}.contains(t['status'])).toList();
    final mandatory = live.where((t) => t['is_mandatory'] == true).toList();
    final done = mandatory.where((t) => _doneSt.contains(t['status'])).length;
    final frac = mandatory.isEmpty ? 0.0 : done / mandatory.length;
    final rows = live.where((t) {
      final s = t['status'] as String?;
      return switch (_f) {
        'open' => _openSt.contains(s),
        'review' => _reviewSt.contains(s),
        'done' => _doneSt.contains(s),
        _ => true,
      };
    }).toList();
    int count(Set<String> st) => live.where((t) => st.contains(t['status'])).length;
    return SectionCard(
      title: 'Dokumen legal vendor',
      subtitle: 'Task scope vendor — wajib approved/waived sebelum keputusan ASL',
      icon: Icons.folder_special_rounded,
      child: live.isEmpty
          ? EmptyState(
              icon: Icons.hourglass_empty_rounded,
              title: 'Task vendor belum dibuat',
              message: 'Task dibuat otomatis saat akun kontraktor aktif dan registrasi sudah dikirim.',
              action: widget.footer,
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(value: frac, minHeight: 10, color: frac >= 1 ? Brand.green : Brand.blue, backgroundColor: Brand.blue.withValues(alpha: 0.1)),
                  ),
                ),
                const SizedBox(width: 12),
                Text('$done/${mandatory.length} wajib selesai', style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 14),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: 'open', label: Text('Perlu aksi (${count(_openSt)})')),
                    ButtonSegment(value: 'review', label: Text('Direview (${count(_reviewSt)})')),
                    ButtonSegment(value: 'done', label: Text('Selesai (${count(_doneSt)})')),
                    ButtonSegment(value: 'all', label: Text('Semua (${live.length})')),
                  ],
                  selected: {_f},
                  onSelectionChanged: (v) => setState(() => _f = v.first),
                ),
              ),
              const SizedBox(height: 8),
              if (rows.isEmpty)
                const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: Text('Tidak ada task di filter ini.', style: TextStyle(color: Brand.grey))))
              else
                for (final t in rows) TaskRow(t: t, onTap: () => context.go('/tasks/${t['id']}')),
              if (widget.footer != null) ...[const SizedBox(height: 8), widget.footer!],
            ]),
    );
  }
}

/// Daftar kontrak ringkas (get_contractor_detail.contracts).
class ContractMiniList extends StatelessWidget {
  const ContractMiniList({super.key, required this.contracts, this.emptyMessage = 'Belum ada kontrak.'});
  final List<J> contracts;
  final String emptyMessage;
  @override
  Widget build(BuildContext context) => SectionCard(
        title: 'Kontrak',
        icon: Icons.handshake_rounded,
        trailing: StatusBadge(Brand.blue, '${contracts.length}'),
        child: contracts.isEmpty
            ? Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(emptyMessage, style: const TextStyle(color: Brand.grey)))
            : Column(children: [
                for (final k in contracts)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    onTap: () => context.go('/contracts/${k['id']}'),
                    leading: HealthDot(k['health_flag'] as String?),
                    title: Row(children: [
                      MonoText(str(k['contract_no']), size: 12),
                      const SizedBox(width: 8),
                      StatusBadge.contract(k['status'] as String?),
                      const SizedBox(width: 6),
                      ClassificationBadges(k, compact: true),
                    ]),
                    subtitle: Text(str(k['title']), maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
              ]),
      );
}
