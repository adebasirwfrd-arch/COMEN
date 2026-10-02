// Blueprint v3.3 — klasifikasi kontrak (mode × durasi → tier) & level user contractor.
// Nilai `code` identik dengan enum Postgres (contract_mode, duration_category, access_tier, contractor_user_level).

enum ContractMode {
  mode1('mode_1', 'Mode 1', 'WFRD mengelola HSE penuh', 'Integral dengan workforce WFRD · seluruh standar WFRD berlaku'),
  mode2('mode_2', 'Mode 2', 'WFRD mengelola via pihak ketiga', 'Operational workforce · bridging document diperlukan'),
  mode3('mode_3', 'Mode 3', 'Contractor independen (HSE-MS sendiri)', 'Bukan bagian workforce WFRD · oversight minimal · tanpa subcontractor');

  const ContractMode(this.code, this.label, this.title, this.hint);
  final String code, label, title, hint;

  static ContractMode fromCode(String? c) => values.firstWhere((m) => m.code == c, orElse: () => mode1);
}

enum DurationCategory {
  longTerm('long_term', 'Long-term', '> 90 hari'),
  shortTerm('short_term', 'Short-term', '≤ 90 hari');

  const DurationCategory(this.code, this.label, this.description);
  final String code, label, description;

  static const thresholdDays = 90;
  static DurationCategory fromCode(String? c) => values.firstWhere((d) => d.code == c, orElse: () => longTerm);
  static DurationCategory fromDays(int days) => days > thresholdDays ? longTerm : shortTerm;
}

enum AccessTier {
  full('full', 'Full', 4, 5, 30, 'Dokumen lengkap v3.2'),
  streamlined('streamlined', 'Streamlined', 3, 2, 10, 'Dokumen inti + checklist mob/demob'),
  minimal('minimal', 'Minimal', 2, 3, 5, 'Dokumen inti, tanpa subcontractor'),
  visitor('visitor', 'Visitor', 1, 1, 0, 'Hanya acknowledgement aturan site');

  const AccessTier(this.code, this.label, this.rank, this.reviewSlaDays, this.bbsPerWeek, this.description);
  final String code, label, description;
  final int rank, reviewSlaDays, bbsPerWeek;

  static AccessTier? tryCode(String? c) => values.where((t) => t.code == c).firstOrNull;
  static AccessTier fromCode(String? c) => tryCode(c) ?? full;

  /// Sama persis dengan kolom GENERATED contracts.access_tier.
  static AccessTier resolve(ContractMode mode, int durationDays) {
    final long = DurationCategory.fromDays(durationDays) == DurationCategory.longTerm;
    return switch (mode) {
      ContractMode.mode1 || ContractMode.mode2 => long ? full : streamlined,
      ContractMode.mode3 => long ? minimal : visitor,
    };
  }
}

enum ContractorUserLevel {
  pic('pic', 'PIC', 3, 'Representative / Director — legal, profil perusahaan, Go-Live, tanda tangan'),
  supervisor('supervisor', 'Supervisor', 2, 'Site lead / HSE officer — dokumen, manning, subcontractor'),
  employee('employee', 'Employee', 1, 'Pekerja — checklist, form, BBS, briefing, Stop Work');

  const ContractorUserLevel(this.code, this.label, this.rank, this.description);
  final String code, label, description;
  final int rank;

  static ContractorUserLevel? tryCode(String? c) => values.where((l) => l.code == c).firstOrNull;
  static ContractorUserLevel fromCode(String? c) => tryCode(c) ?? employee;

  bool atLeast(ContractorUserLevel other) => rank >= other.rank;
}

/// Durasi kontrak (hari) seperti kolom duration_days: end_date − start_date.
int contractDurationDays(DateTime start, DateTime end) =>
    DateTime.utc(end.year, end.month, end.day).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
