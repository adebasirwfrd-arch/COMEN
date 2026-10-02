import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import '../core/errors/app_failure.dart';
import 'theme.dart';

// ─────────────────────────── Format ───────────────────────────
final uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

DateTime? parseDate(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

String fmtDate(dynamic v) {
  final d = parseDate(v);
  return d == null ? '-' : DateFormat('d MMM yyyy', 'id').format(d);
}

String fmtDateTime(dynamic v) {
  final d = parseDate(v);
  return d == null ? '-' : DateFormat('d MMM yyyy · HH:mm', 'id').format(d);
}

String fmtRelative(dynamic v) {
  final d = parseDate(v);
  if (d == null) return '-';
  final diff = DateTime.now().difference(d);
  if (diff.inSeconds.abs() < 60) return 'baru saja';
  if (diff.isNegative) {
    final f = diff.abs();
    if (f.inHours < 24) return 'dalam ${f.inHours} jam';
    return 'dalam ${f.inDays} hari';
  }
  if (diff.inMinutes < 60) return '${diff.inMinutes} mnt lalu';
  if (diff.inHours < 24) return '${diff.inHours} jam lalu';
  if (diff.inDays < 7) return '${diff.inDays} hari lalu';
  return fmtDate(v);
}

/// "H-3" / "H+2" / "Hari ini" relatif terhadap tanggal jatuh tempo.
String dueLabel(dynamic due) {
  final d = parseDate(due);
  if (d == null) return '-';
  final today = DateTime.now();
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(today.year, today.month, today.day)).inDays;
  if (days == 0) return 'Hari ini';
  return days > 0 ? 'H-$days' : 'H+${-days}';
}

Color dueColor(dynamic due) {
  final d = parseDate(due);
  if (d == null) return Brand.grey;
  final days = d.difference(DateTime.now()).inDays;
  if (days < 0) return Brand.red;
  if (days <= 3) return Brand.amber;
  return Brand.green;
}

String str(dynamic v, [String fallback = '-']) => (v == null || v.toString().isEmpty) ? fallback : v.toString();

// ─────────────────────────── Layout ───────────────────────────
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.child,
    this.maxWidth = 1400,
    this.scroll = true,
    this.leading,
  });
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;
  final double maxWidth;
  final bool scroll;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final pad = EdgeInsets.symmetric(horizontal: wide ? 32 : 16, vertical: wide ? 28 : 16);
    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 12,
      spacing: 12,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ]),
          ),
        ]),
        if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
    final body = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: scroll ? MainAxisSize.min : MainAxisSize.max, children: [
          header,
          const SizedBox(height: 24),
          if (scroll) child else Expanded(child: child),
        ]),
      ),
    );
    if (!scroll) return Padding(padding: pad, child: body);
    return SingleChildScrollView(padding: pad, child: body.animate().fadeIn(duration: 220.ms).slideY(begin: 0.02, end: 0));
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.subtitle, this.trailing, required this.child, this.padding = const EdgeInsets.all(20), this.icon});
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          if (title != null) ...[
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 20, color: Brand.blue), const SizedBox(width: 10)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title!, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  if (subtitle != null)
                    Text(subtitle!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ]),
              ),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: 16),
          ],
          child,
        ]),
      ),
    );
  }
}

class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({super.key, required this.children, this.minItemWidth = 260, this.spacing = 16});
  final List<Widget> children;
  final double minItemWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minItemWidth).floor().clamp(1, 6);
      final w = (c.maxWidth - spacing * (cols - 1)) / cols;
      return Wrap(spacing: spacing, runSpacing: spacing, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
    });
  }
}

class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value, required this.icon, this.color = Brand.blue, this.onTap, this.caption});
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: t.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(value, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: color)),
                if (caption != null) Text(caption!, style: t.bodySmall),
              ]),
            ),
          ]),
        ),
      ),
    ).animate().fadeIn(duration: 300.ms).scale(begin: const Offset(0.98, 0.98));
  }
}

class KeyValueGrid extends StatelessWidget {
  const KeyValueGrid(this.entries, {super.key, this.minItemWidth = 240});
  final List<(String, Widget)> entries;
  final double minItemWidth;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ResponsiveGrid(minItemWidth: minItemWidth, spacing: 12, children: [
      for (final (k, v) in entries)
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: t.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 0.4)),
          const SizedBox(height: 4),
          DefaultTextStyle.merge(style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600), child: v),
        ]),
    ]);
  }
}

Widget kv(String k, dynamic v) => Text(str(v));

// ─────────────────────────── Badges ───────────────────────────
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.color, this.label, {super.key, this.icon});
  factory StatusBadge.task(String? s) { final (c, l) = StatusStyle.task(s); return StatusBadge(c, l); }
  factory StatusBadge.contract(String? s) { final (c, l) = StatusStyle.contract(s); return StatusBadge(c, l); }
  factory StatusBadge.vendor(String? s) { final (c, l) = StatusStyle.vendor(s); return StatusBadge(c, l); }
  factory StatusBadge.account(String? s) { final (c, l) = StatusStyle.account(s); return StatusBadge(c, l); }
  factory StatusBadge.generic(String? s) { final (c, l) = StatusStyle.generic(s); return StatusBadge(c, l); }
  final Color color;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)]
        else ...[Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)), const SizedBox(width: 6)],
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      ]),
    );
  }
}

class HealthDot extends StatelessWidget {
  const HealthDot(this.flag, {super.key});
  final String? flag;
  @override
  Widget build(BuildContext context) {
    final c = switch (flag) {
      'red' => Brand.red,
      'yellow' || 'amber' || 'warning' => Brand.amber,
      'green' || 'normal' => Brand.green,
      _ => Brand.grey,
    };
    return Tooltip(
      message: 'Health: ${flag ?? '-'}',
      child: Container(width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle, boxShadow: [BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 6)])),
    );
  }
}

// ─────────────────────────── Task ID & copy ───────────────────────────
class CopyButton extends StatelessWidget {
  const CopyButton(this.text, {super.key, this.label, this.tooltip = 'Copy'});
  final String text;
  final String? label;
  final String tooltip;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Disalin ke clipboard'), duration: Duration(seconds: 1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (label != null) {
      return OutlinedButton.icon(onPressed: () => _copy(context), icon: const Icon(Icons.copy_rounded, size: 16), label: Text(label!));
    }
    return IconButton(tooltip: tooltip, onPressed: () => _copy(context), icon: const Icon(Icons.copy_rounded, size: 18));
  }
}

class TaskIdChip extends StatelessWidget {
  const TaskIdChip(this.taskId, {super.key, this.large = false});
  final String taskId;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'monospace',
      fontWeight: FontWeight.w800,
      fontSize: large ? 22 : 13,
      letterSpacing: 0.4,
      color: Theme.of(context).colorScheme.primary,
    );
    return Container(
      padding: EdgeInsets.only(left: large ? 14 : 10, right: 2, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: Brand.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Brand.blue.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SelectableText(taskId, style: style),
        CopyButton(taskId, tooltip: 'Copy Task ID'),
      ]),
    );
  }
}

// ─────────────────────────── States ───────────────────────────
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});
  final String? message;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
            if (message != null) ...[const SizedBox(height: 16), Text(message!)],
          ]),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, this.icon = Icons.inbox_rounded, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: Brand.blue.withValues(alpha: 0.08), shape: BoxShape.circle),
            child: Icon(icon, size: 34, color: Brand.blue),
          ),
          const SizedBox(height: 16),
          Text(title, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final f = AppFailure.from(error);
    final forbidden = f.hint == Hint.forbidden;
    return EmptyState(
      icon: forbidden ? Icons.lock_outline_rounded : Icons.error_outline_rounded,
      title: forbidden ? 'Akses ditolak atau data tidak ditemukan' : 'Gagal memuat data',
      message: f.message,
      action: onRetry == null ? null : FilledButton.tonalIcon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Coba lagi')),
    );
  }
}

/// FutureBuilder dengan loading/error/retry seragam.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.future, required this.builder, this.onRetry, this.loading});
  final Future<T> future;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;
  final Widget? loading;

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: future,
        builder: (context, s) {
          if (s.hasError) return ErrorView(s.error!, onRetry: onRetry);
          if (s.connectionState != ConnectionState.done) return loading ?? const LoadingView();
          return builder(context, s.data as T);
        },
      );
}

// ─────────────────────────── Dialogs ───────────────────────────
/// Dialog alasan wajib (aksi admin & keputusan; min 5 karakter, Part 6).
Future<String?> showReasonDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Lanjutkan',
  String fieldLabel = 'Alasan',
  int minLength = 5,
  bool destructive = false,
  String? initial,
}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final ok = ctl.text.trim().length >= minLength;
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (message != null) ...[Text(message), const SizedBox(height: 16)],
            TextField(
              controller: ctl,
              autofocus: true,
              maxLines: 3,
              maxLength: 1000,
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(labelText: '$fieldLabel *', helperText: 'Minimal $minLength karakter · tercatat di audit log'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            style: destructive ? FilledButton.styleFrom(backgroundColor: Brand.red) : null,
            onPressed: ok ? () => Navigator.pop(ctx, ctl.text.trim()) : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    }),
  );
}

/// Danger Zone: ketik ulang frasa konfirmasi + alasan.
Future<String?> showConfirmPhraseDialog(BuildContext context, {required String title, required String message, String phrase = 'SAYA PAHAM'}) {
  final phraseCtl = TextEditingController();
  final reasonCtl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final ok = phraseCtl.text.trim() == phrase && reasonCtl.text.trim().length >= 5;
      return AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Brand.red, size: 40),
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(message),
            const SizedBox(height: 16),
            TextField(controller: reasonCtl, onChanged: (_) => set(() {}), maxLines: 2, decoration: const InputDecoration(labelText: 'Alasan *')),
            const SizedBox(height: 12),
            TextField(controller: phraseCtl, onChanged: (_) => set(() {}), decoration: InputDecoration(labelText: 'Ketik "$phrase" untuk konfirmasi')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.red),
            onPressed: ok ? () => Navigator.pop(ctx, reasonCtl.text.trim()) : null,
            child: const Text('Saya mengerti, lanjutkan'),
          ),
        ],
      );
    }),
  );
}

Future<bool> showConfirm(BuildContext context, {required String title, String? message, String confirmLabel = 'Ya', bool destructive = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Brand.red) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return r == true;
}

// ─────────────────────────── Misc ───────────────────────────
class Avatar extends StatelessWidget {
  const Avatar({super.key, this.name, this.url, this.radius = 18});
  final String? name;
  final String? url;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final initials = (name ?? '?').trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).take(2).map((s) => s[0].toUpperCase()).join();
    final hue = ((name ?? '').hashCode % 360).abs().toDouble();
    final bg = HSLColor.fromAHSL(1, hue, 0.55, 0.45).toColor();
    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      foregroundImage: (url != null && url!.startsWith('https://')) ? NetworkImage(url!) : null,
      child: Text(initials.isEmpty ? '?' : initials, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: radius * 0.75)),
    );
  }
}

/// Tabel data responsif (scroll horizontal), baris bisa diklik.
class DataList extends StatelessWidget {
  const DataList({super.key, required this.columns, required this.rows, this.onTap, this.empty = 'Belum ada data'});
  final List<String> columns;
  final List<List<Widget>> rows;
  final void Function(int index)? onTap;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return EmptyState(title: empty);
    return LayoutBuilder(builder: (context, c) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: c.maxWidth),
          child: DataTable(
            showCheckboxColumn: false,
            columnSpacing: 24,
            headingRowHeight: 44,
            dataRowMinHeight: 52,
            dataRowMaxHeight: 72,
            columns: [for (final col in columns) DataColumn(label: Text(col))],
            rows: [
              for (var i = 0; i < rows.length; i++)
                DataRow(onSelectChanged: onTap == null ? null : (_) => onTap!(i), cells: [for (final cell in rows[i]) DataCell(cell)]),
            ],
          ),
        ),
      );
    });
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.message, this.color = Brand.blue, this.icon = Icons.info_outline_rounded, this.action});
  final String message;
  final Color color;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: TextStyle(color: color.withValues(alpha: 0.95), fontWeight: FontWeight.w600))),
          if (action != null) action!,
        ]),
      );
}

class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.size = 13});
  final String text;
  final double size;
  @override
  Widget build(BuildContext context) => SelectableText(text, style: TextStyle(fontFamily: 'monospace', fontSize: size, fontWeight: FontWeight.w600));
}
