import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

/// Jadwal pg_cron (UTC) dari migration 15 — tidak ada RPC untuk membaca status run, jadi ditampilkan statis.
const cronJobs = <(String, String, String, String)>[
  ('comen-notify-dispatch', '* * * * *', 'Tiap menit', 'Kirim antrian email/push (Edge notify-dispatch)'),
  ('comen-chat-scheduler', '* * * * *', 'Tiap menit', 'Pesan chat terjadwal'),
  ('comen-chat-urgent', '*/2 * * * *', 'Tiap 2 menit', 'Ulangi notifikasi pesan urgent belum dibaca'),
  ('comen-chat-digest', '*/30 * * * *', 'Tiap 30 menit', 'Digest chat belum dibaca (#6001)'),
  ('comen-security-scan', '*/15 * * * *', 'Tiap 15 menit', 'Deteksi anomali (rate limit, perangkat, signup burst)'),
  ('comen-incident-overdue', '*/15 * * * *', 'Tiap 15 menit', 'Laporan insiden lewat tenggat (#3002)'),
  ('comen-review-sla', '5 * * * *', 'Tiap jam (:05)', 'Eskalasi SLA review (#2011)'),
  ('comen-doc-expiry', '30 23 * * *', '06:30 WIB', 'Dokumen kedaluwarsa & renewal task'),
  ('comen-asl-expiry', '40 23 * * *', '06:40 WIB', 'ASL vendor kedaluwarsa (#1006)'),
  ('comen-contract-expiry', '50 23 * * *', '06:50 WIB', 'Kontrak mendekati akhir (#4005)'),
  ('comen-monthly-reports', '0 0 * * *', '07:00 WIB', 'Task laporan bulanan'),
  ('comen-task-reminders', '0 1 * * *', '08:00 WIB', 'Reminder & daily digest task'),
  ('comen-link-coverage', '0 2 * * 1-5', '09:00 WIB (Sen–Jum)', 'Task tanpa link OneDrive (#2012)'),
  ('comen-audit-anchor', '55 16 * * *', '23:55 WIB', 'Anchor hash chain harian (#7006)'),
  ('comen-kpi-recalc', '0 19 * * *', '02:00 WIB', 'Hitung ulang KPI'),
  ('comen-retention', '0 20 * * *', '03:00 WIB', 'Purge sesuai retensi (hormati legal hold)'),
  ('comen-audit-partition', '0 0 1 * *', 'Tgl 1, 07:00 WIB', 'Siapkan partisi audit_logs'),
  ('comen-cron-history-gc', '0 21 * * 0', 'Minggu 04:00 WIB', 'Bersihkan riwayat cron > 14 hari'),
];

class AdminSystemPage extends ConsumerStatefulWidget {
  const AdminSystemPage({super.key});
  @override
  ConsumerState<AdminSystemPage> createState() => _AdminSystemPageState();
}

class _AdminSystemPageState extends ConsumerState<AdminSystemPage> {
  late Future<Map<String, J>> _settings = _load();

  Future<Map<String, J>> _load() async {
    final r = await ref.read(apiProvider).select('app_settings', 'key,value,is_public,required_permission,description,updated_by,updated_at',
        build: (q) => q.inFilter('key', const ['read_only_mode', 'global_sessions_valid_after', 'email_otp_enabled', 'password_login_enabled', 'chat_key_ver', 'data_key_ver']));
    return {for (final x in r) x['key'] as String: x};
  }

  void _reload() {
    setState(() => _settings = _load());
    ref.read(sessionProvider.notifier).refresh();
  }

  Future<void> _danger({required String title, required String message, required String success, required Future<dynamic> Function(String) action}) async {
    final ok = await withDanger(context, ref, title: title, message: message, success: success, action: action);
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    final canKeys = s?.can('admin.security.manage') ?? false;
    return AdminScaffold(
      title: 'System & Danger Zone',
      subtitle: 'Kontrol darurat seluruh aplikasi · setiap aksi wajib frasa konfirmasi, alasan, dan step-up MFA',
      actions: [OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang'))],
      child: AsyncView<Map<String, J>>(
        future: _settings,
        onRetry: _reload,
        builder: (context, m) {
          final readOnly = m['read_only_mode']?['value'] == true || (s?.readOnly ?? false);
          final otp = m.containsKey('email_otp_enabled') ? m['email_otp_enabled']!['value'] == true : (s?.emailOtpEnabled ?? true);
          final pwd = m['password_login_enabled']?['value'] == true;
          final gsva = m['global_sessions_valid_after']?['value'];
          num ver(String k) => (m[k]?['value'] as num?) ?? 1;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const InfoBanner(
              message: 'Semua aksi di halaman ini tercatat sebagai security event CRITICAL dan memberi notifikasi (#7005) ke pemegang admin.security.manage.',
              color: Brand.red,
              icon: Icons.warning_amber_rounded,
            ),
            const SizedBox(height: 16),
            ResponsiveGrid(minItemWidth: 220, children: [
              StatCard(label: 'Read-only mode', value: readOnly ? 'AKTIF' : 'Nonaktif', icon: Icons.lock_clock_rounded, color: readOnly ? Brand.red : Brand.green),
              StatCard(label: 'Login email OTP', value: otp ? 'Aktif' : 'Nonaktif', icon: Icons.mark_email_read_outlined, color: otp ? Brand.green : Brand.amber),
              StatCard(label: 'Login password', value: pwd ? 'Aktif' : 'Nonaktif', icon: Icons.password_rounded, color: pwd ? Brand.amber : Brand.green, caption: pwd ? 'Matikan sebelum go-live' : null),
              StatCard(label: 'Global logout terakhir', value: gsva == null ? 'Belum pernah' : fmtRelative(gsva), icon: Icons.logout_rounded, color: Brand.navy),
            ]),
            const SizedBox(height: 24),
            const GroupLabel('Danger Zone', color: Brand.red),
            DangerCard(
              title: 'Read-only mode',
              description: 'Tolak semua mutasi data untuk seluruh pengguna (kecuali pemegang admin.system.danger). Untuk insiden, migrasi, atau investigasi.',
              icon: Icons.lock_clock_rounded,
              status: readOnly ? const StatusBadge(Brand.red, 'AKTIF') : const StatusBadge(Brand.green, 'Nonaktif'),
              action: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: readOnly ? Brand.green : Brand.red),
                onPressed: () => _danger(
                  title: readOnly ? 'Matikan read-only mode' : 'Aktifkan read-only mode',
                  message: readOnly ? 'Pengguna dapat kembali mengubah data.' : 'Semua pengguna tidak bisa mengubah data sampai mode ini dimatikan.',
                  success: readOnly ? 'Read-only mode dimatikan' : 'Read-only mode aktif',
                  action: (r) => ref.read(apiProvider).rpc('admin_set_read_only', {'p_on': !readOnly, 'p_reason': r}),
                ),
                icon: Icon(readOnly ? Icons.lock_open_rounded : Icons.lock_rounded),
                label: Text(readOnly ? 'Matikan' : 'Aktifkan'),
              ),
            ),
            const SizedBox(height: 12),
            DangerCard(
              title: 'Global logout',
              description: 'Akhiri SEMUA sesi pengguna (termasuk Anda). Semua orang harus login ulang. Gunakan bila ada dugaan kebocoran token.',
              icon: Icons.logout_rounded,
              status: gsva == null ? null : StatusBadge(Brand.grey, 'Terakhir ${fmtDateTime(gsva)}'),
              action: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Brand.red),
                onPressed: () => _danger(
                  title: 'Global logout',
                  message: 'Seluruh sesi aktif akan dicabut sekarang, termasuk sesi Anda sendiri.',
                  success: 'Semua sesi dicabut',
                  action: (r) => ref.read(apiProvider).rpc('admin_global_logout', {'p_reason': r}),
                ),
                icon: const Icon(Icons.power_settings_new_rounded),
                label: const Text('Logout semua'),
              ),
            ),
            const SizedBox(height: 12),
            DangerCard(
              title: 'Login email OTP',
              description: 'Izinkan login dengan kode OTP via email (selain Google). Matikan bila ada serangan OTP / spam pendaftaran.',
              icon: Icons.mark_email_read_outlined,
              color: Brand.amber,
              status: otp ? const StatusBadge(Brand.green, 'Aktif') : const StatusBadge(Brand.amber, 'Nonaktif'),
              action: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: otp ? Brand.red : Brand.green),
                onPressed: () => _danger(
                  title: otp ? 'Matikan login email OTP' : 'Aktifkan login email OTP',
                  message: otp ? 'Pengguna hanya bisa login dengan Google.' : 'Pengguna dapat login dengan kode OTP email.',
                  success: otp ? 'Email OTP dimatikan' : 'Email OTP diaktifkan',
                  action: (r) => ref.read(apiProvider).rpc('admin_set_email_otp', {'p_on': !otp, 'p_reason': r}),
                ),
                icon: Icon(otp ? Icons.toggle_off_outlined : Icons.toggle_on_outlined),
                label: Text(otp ? 'Matikan' : 'Aktifkan'),
              ),
            ),
            const SizedBox(height: 12),
            DangerCard(
              title: 'Login password',
              description: 'Hanya untuk pengembangan. Tidak dapat diubah dari aplikasi — ubah lewat migration / SQL saat go-live.',
              icon: Icons.password_rounded,
              color: Brand.grey,
              status: pwd ? const StatusBadge(Brand.amber, 'Aktif') : const StatusBadge(Brand.green, 'Nonaktif'),
              action: const Tooltip(message: 'Tidak ada RPC untuk setting ini', child: Icon(Icons.lock_outline_rounded, color: Brand.grey)),
            ),
            const SizedBox(height: 24),
            const GroupLabel('Rotasi kunci enkripsi', color: Brand.purple),
            if (!canKeys) const PermissionNote('admin.security.manage', what: 'merotasi kunci enkripsi'),
            for (final k in const [('chat', 'Kunci chat', 'Isi pesan chat & pesan terjadwal'), ('data', 'Kunci data', 'Telepon profil/vendor & secret push')])
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: DangerCard(
                  title: '${k.$2} · v${ver('${k.$1}_key_ver')}',
                  description: '${k.$3}. Prasyarat: secret versi v${ver('${k.$1}_key_ver') + 1} sudah ditambahkan di Supabase Vault (jika belum, rotasi ditolak). '
                      'Data baru memakai versi baru; data lama tetap terbaca selama secret lama ada. Re-enkripsi data lama (svc_rekey) dijalankan manual oleh DBA.',
                  icon: Icons.key_rounded,
                  color: Brand.purple,
                  status: m['${k.$1}_key_ver'] == null ? null : StatusBadge(Brand.grey, 'Diperbarui ${fmtRelative(m['${k.$1}_key_ver']!['updated_at'])}'),
                  action: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Brand.purple),
                    onPressed: !canKeys || m['${k.$1}_key_ver'] == null
                        ? null
                        : () => _danger(
                              title: 'Rotasi ${k.$2.toLowerCase()} ke v${ver('${k.$1}_key_ver') + 1}',
                              message: 'Pastikan secret v${ver('${k.$1}_key_ver') + 1} sudah ada di Vault. Jangan hapus secret lama sebelum re-enkripsi selesai.',
                              success: '${k.$2} dirotasi',
                              action: (r) => ref.read(apiProvider).rpc('admin_upsert_setting', {
                                'p_key': '${k.$1}_key_ver',
                                'p_value': ver('${k.$1}_key_ver').toInt() + 1,
                                'p_reason': r,
                              }),
                            ),
                    icon: const Icon(Icons.autorenew_rounded),
                    label: const Text('Rotasi'),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            TableCard(
              title: 'Jadwal cron',
              subtitle: 'pg_cron (UTC, WIB = UTC+7) · status run tidak tersedia via API — cek dashboard Supabase',
              icon: Icons.schedule_rounded,
              count: cronJobs.length,
              trailing: s?.can('admin.security.manage') ?? false
                  ? TextButton.icon(onPressed: () => context.go('/admin/security'), icon: const Icon(Icons.security_rounded, size: 18), label: const Text('Security events'))
                  : null,
              child: DataList(
                columns: const ['Job', 'Cron (UTC)', 'Waktu', 'Fungsi'],
                rows: [
                  for (final j in cronJobs)
                    [
                      MonoText(j.$1, size: 12),
                      MonoText(j.$2, size: 12),
                      Text(j.$3),
                      CellText(j.$4, maxWidth: 360),
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
