import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

abstract final class Brand {
  static const navy = Color(0xFF0A1F44);
  static const navyDeep = Color(0xFF06142E);
  static const blue = Color(0xFF0B5FFF);
  static const cyan = Color(0xFF00B8D9);
  static const green = Color(0xFF12B76A);
  static const amber = Color(0xFFF79009);
  static const red = Color(0xFFF04438);
  static const purple = Color(0xFF7A5AF8);
  static const grey = Color(0xFF667085);

  static const sidebarGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [navy, navyDeep],
  );
  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0B5FFF), Color(0xFF00B8D9)],
  );
  static const adminGradient = LinearGradient(colors: [Color(0xFFB42318), Color(0xFFF04438), Color(0xFFB42318)]);
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: Brand.blue,
      brightness: b,
      primary: Brand.blue,
      error: Brand.red,
      surface: dark ? const Color(0xFF0F1729) : Colors.white,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b);
    final text = GoogleFonts.plusJakartaSansTextTheme(base.textTheme);
    final bg = dark ? const Color(0xFF0B1220) : const Color(0xFFF4F6FB);
    final border = dark ? const Color(0xFF1E2A44) : const Color(0xFFE4E7EC);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      textTheme: text,
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: border)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF121C30) : const Color(0xFFF9FAFB),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Brand.blue, width: 1.6)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        isDense: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: border),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        side: BorderSide(color: border),
      ),
      dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: border,
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
        dividerThickness: 0.6,
      ),
    );
  }
}

/// Warna & label status — selalu berwarna **dan** berlabel (WCAG, Part 17).
abstract final class StatusStyle {
  static const _task = <String, (Color, String)>{
    'open': (Brand.blue, 'Open'),
    'awaiting_email': (Brand.purple, 'Menunggu email'),
    'submitted': (Color(0xFF444CE7), 'Submitted'),
    'under_review': (Brand.cyan, 'Direview'),
    'file_issue': (Brand.amber, 'File bermasalah'),
    'approved': (Brand.green, 'Approved'),
    'revise': (Color(0xFFDC6803), 'Revisi'),
    'rejected': (Brand.red, 'Ditolak'),
    'expired': (Color(0xFFB42318), 'Kedaluwarsa'),
    'superseded': (Brand.grey, 'Superseded'),
    'waived': (Brand.grey, 'Waived'),
    'cancelled': (Brand.grey, 'Dibatalkan'),
  };
  static const _contract = <String, (Color, String)>{
    'awarded': (Brand.blue, 'Awarded'),
    'post_award': (Color(0xFF444CE7), 'Post-Award'),
    'pre_mobilization': (Brand.purple, 'Pre-Mobilization'),
    'mobilization': (Brand.cyan, 'Mobilization'),
    'active': (Brand.green, 'Active'),
    'demobilization': (Brand.amber, 'Demobilization'),
    'final_evaluation': (Color(0xFFDC6803), 'Final Evaluation'),
    'closed': (Brand.grey, 'Closed'),
    'suspended': (Brand.red, 'Suspended'),
    'terminated': (Color(0xFF912018), 'Terminated'),
  };
  static const _vendor = <String, (Color, String)>{
    'draft': (Brand.grey, 'Draft'),
    'under_review': (Brand.blue, 'Under Review'),
    'asl_approved': (Brand.green, 'ASL Approved'),
    'asl_conditional': (Brand.amber, 'ASL Conditional'),
    'rejected': (Brand.red, 'Rejected'),
    'asl_expired': (Color(0xFFB42318), 'ASL Expired'),
    'suspended': (Brand.red, 'Suspended'),
    'blacklisted': (Color(0xFF912018), 'Blacklisted'),
  };
  static const _account = <String, (Color, String)>{
    'pending': (Brand.amber, 'Pending'),
    'active': (Brand.green, 'Active'),
    'suspended': (Brand.red, 'Suspended'),
    'rejected': (Color(0xFF912018), 'Rejected'),
    'deactivated': (Brand.grey, 'Deactivated'),
  };
  static const _generic = <String, (Color, String)>{
    'green': (Brand.green, 'Hijau'),
    'yellow': (Brand.amber, 'Kuning'),
    'red': (Brand.red, 'Merah'),
    'low': (Brand.green, 'Low'),
    'medium': (Brand.amber, 'Medium'),
    'high': (Color(0xFFDC6803), 'High'),
    'critical': (Brand.red, 'Critical'),
    'info': (Brand.blue, 'Info'),
    'warning': (Brand.amber, 'Warning'),
    'minor': (Brand.amber, 'Minor'),
    'major': (Color(0xFFDC6803), 'Major'),
    'closed': (Brand.grey, 'Closed'),
    'draft': (Brand.grey, 'Draft'),
    'final': (Brand.green, 'Final'),
    'signed': (Brand.green, 'Signed'),
    'pending': (Brand.amber, 'Pending'),
    'approved': (Brand.green, 'Approved'),
    'rejected': (Brand.red, 'Rejected'),
    'open': (Brand.blue, 'Open'),
    'queued': (Brand.blue, 'Queued'),
    'sending': (Brand.cyan, 'Sending'),
    'sent': (Brand.green, 'Sent'),
    'failed': (Brand.red, 'Failed'),
    'skipped': (Brand.grey, 'Skipped'),
  };

  static (Color, String) task(String? s) => _task[s] ?? (Brand.grey, s ?? '-');
  static (Color, String) contract(String? s) => _contract[s] ?? (Brand.grey, s ?? '-');
  static (Color, String) vendor(String? s) => _vendor[s] ?? (Brand.grey, s ?? '-');
  static (Color, String) account(String? s) => _account[s] ?? (Brand.grey, s ?? '-');
  static (Color, String) generic(String? s) => _generic[s] ?? (Brand.grey, s ?? '-');
}
