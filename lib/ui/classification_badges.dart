import 'package:flutter/material.dart';
import '../core/session/contract_classification.dart';
import 'theme.dart';

class _GradientChip extends StatelessWidget {
  const _GradientChip({required this.icon, required this.label, required this.colors, this.tooltip});
  final IconData icon;
  final String label;
  final List<Color> colors;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: colors.first.withValues(alpha: 0.30), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: Colors.white),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11.5, letterSpacing: 0.4)),
      ]),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

class ModeBadge extends StatelessWidget {
  const ModeBadge(this.mode, {super.key});
  final ContractMode mode;

  @override
  Widget build(BuildContext context) => _GradientChip(
        icon: switch (mode) {
          ContractMode.mode1 => Icons.verified_user_rounded,
          ContractMode.mode2 => Icons.handshake_rounded,
          ContractMode.mode3 => Icons.person_outline_rounded,
        },
        label: mode.label.toUpperCase(),
        colors: switch (mode) {
          ContractMode.mode1 => const [Brand.navy, Brand.blue],
          ContractMode.mode2 => const [Color(0xFF027A48), Brand.cyan],
          ContractMode.mode3 => const [Color(0xFFDC6803), Color(0xFFFDB022)],
        },
        tooltip: mode.title,
      );
}

class DurationBadge extends StatelessWidget {
  const DurationBadge(this.duration, {super.key, this.days});
  final DurationCategory duration;
  final int? days;

  @override
  Widget build(BuildContext context) => _GradientChip(
        icon: duration == DurationCategory.longTerm ? Icons.calendar_month_rounded : Icons.timelapse_rounded,
        label: duration.label.toUpperCase(),
        colors: duration == DurationCategory.longTerm ? const [Color(0xFF344054), Color(0xFF667085)] : const [Color(0xFF667085), Color(0xFF98A2B3)],
        tooltip: days == null ? duration.description : '$days hari (${duration.description})',
      );
}

class TierBadge extends StatelessWidget {
  const TierBadge(this.tier, {super.key});
  final AccessTier tier;

  @override
  Widget build(BuildContext context) => _GradientChip(
        icon: switch (tier) {
          AccessTier.full => Icons.shield_rounded,
          AccessTier.streamlined => Icons.bolt_rounded,
          AccessTier.minimal => Icons.remove_moderator_outlined,
          AccessTier.visitor => Icons.visibility_rounded,
        },
        label: tier.label.toUpperCase(),
        colors: switch (tier) {
          AccessTier.full => const [Brand.blue, Brand.cyan],
          AccessTier.streamlined => const [Brand.green, Color(0xFF66D9FF)],
          AccessTier.minimal => const [Brand.amber, Color(0xFFFDB022)],
          AccessTier.visitor => const [Color(0xFF475467), Color(0xFF98A2B3)],
        },
        tooltip: 'Kategori ${tier.label}: ${tier.description} · SLA review ${tier.reviewSlaDays} hari kerja',
      );
}

class LevelBadge extends StatelessWidget {
  const LevelBadge(this.level, {super.key});
  final ContractorUserLevel level;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      ContractorUserLevel.pic => Brand.purple,
      ContractorUserLevel.supervisor => Brand.blue,
      ContractorUserLevel.employee => Brand.grey,
    };
    return Tooltip(
      message: level.description,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(level == ContractorUserLevel.pic ? Icons.star_rounded : Icons.person_rounded, size: 13, color: color),
          const SizedBox(width: 4),
          Text(level.label.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11.5)),
        ]),
      ),
    );
  }
}

/// Badge mode · durasi · tier dari baris kontrak (kolom contract_mode, duration_category, duration_days, access_tier).
class ClassificationBadges extends StatelessWidget {
  const ClassificationBadges(this.contract, {super.key, this.compact = false});
  final Map<String, dynamic> contract;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tier = AccessTier.tryCode(contract['access_tier'] as String?);
    if (tier == null) return const SizedBox.shrink();
    if (compact) return TierBadge(tier);
    return Wrap(spacing: 6, runSpacing: 6, children: [
      ModeBadge(ContractMode.fromCode(contract['contract_mode'] as String?)),
      DurationBadge(DurationCategory.fromCode(contract['duration_category'] as String?), days: (contract['duration_days'] as num?)?.toInt()),
      TierBadge(tier),
    ]);
  }
}
