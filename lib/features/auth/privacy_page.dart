import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../ui/theme.dart';
import '../status/status_pages.dart';

/// Privacy Notice publik (19.3) — wajib disetujui saat submit registrasi.
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  static const _sections = <(IconData, String, String)>[
    (Icons.business_rounded, 'Pengendali Data',
        'Weatherford (WFRD) Indonesia adalah pengendali data pribadi yang diproses melalui COMEN. '
            'Kerangka: UU No. 27/2022 tentang Pelindungan Data Pribadi (UU PDP) sebagai baseline, dengan prinsip GDPR untuk contractor lintas negara.'),
    (Icons.flag_rounded, 'Tujuan Pemrosesan',
        'Pengelolaan siklus hidup contractor: registrasi & verifikasi vendor, kontrak, kewajiban dokumen (Task), review, KPI, insiden HSE, '
            'komunikasi kerja (chat), notifikasi, serta keamanan sistem (audit & deteksi penyalahgunaan).'),
    (Icons.gavel_rounded, 'Dasar Hukum',
        'Pelaksanaan kontrak, kewajiban hukum (rekaman HSE & kepatuhan), dan kepentingan sah WFRD dalam keamanan serta tata kelola contractor. '
            'Persetujuan eksplisit diminta saat registrasi.'),
    (Icons.dataset_rounded, 'Kategori Data',
        'Nama, email, foto profil (dari Google), jabatan, telepon (terenkripsi AES-256), identitas perusahaan, identitas perangkat (hash SHA-256), '
            'hash IP (HMAC — IP mentah tidak disimpan), isi chat (terenkripsi AES-256), koordinat lokasi insiden (hanya saat melapor, dengan izin browser), '
            'serta metadata email konfirmasi (tanpa isi). COMEN TIDAK menyimpan file dokumen — file tersimpan di OneDrive/SharePoint milik WFRD.'),
    (Icons.hub_rounded, 'Penerima & Sub-pemroses',
        'Supabase (database/auth, region Singapore) · Vercel (hosting statis) · Brevo (email transaksional, EU) · Cloudflare Turnstile (verifikasi manusia) · '
            'Google (login OAuth) · Microsoft OneDrive/SharePoint tenant WFRD (file dokumen) · Sentry opsional (error tanpa PII).'),
    (Icons.public_rounded, 'Transfer Lintas Negara',
        'Sebagian sub-pemroses berada di luar Indonesia (Singapura, Uni Eropa, global). Transfer dilindungi perjanjian pemrosesan data, enkripsi saat transit (TLS) dan saat disimpan.'),
    (Icons.schedule_rounded, 'Retensi',
        'Profil: selama akun aktif. Notifikasi: 180–365 hari. Outbox email: 90–180 hari. Chat: default 7 tahun per channel (dapat legal hold). '
            'Rekaman HSE ≥ 5 tahun. Security events: 2 tahun. Audit log: permanen (kewajiban hukum, hash-chain anti-tamper).'),
    (Icons.how_to_reg_rounded, 'Hak Subjek Data',
        'Akses & portabilitas (ekspor JSON maks 30 hari), koreksi (Pengaturan → Profil / Perusahaan saya), penghapusan melalui anonimisasi '
            '(rekaman kepatuhan dipertahankan sebagai "Pengguna Terhapus"), keberatan/pembatasan (suspend akun). Ajukan ke kontak di bawah.'),
    (Icons.cookie_outlined, 'Cookie & Penyimpanan Lokal',
        'Tanpa cookie pelacak atau analytics pihak ketiga. Penyimpanan lokal hanya untuk sesi terenkripsi, PKCE verifier, identitas perangkat, '
            'dan draft chat — semuanya AES-256-GCM di IndexedDB (kategori strictly necessary).'),
    (Icons.support_agent_rounded, 'Kontak Pelindungan Data (DPO)',
        'Email: ade.basirwfrd@gmail.com — subjek "COMEN Privacy". Insiden data pribadi diberitahukan sesuai UU PDP (≤ 3×24 jam).'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return BrandBackdrop(
      maxWidth: 820,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.privacy_tip_rounded, color: Brand.blue, size: 30),
          const SizedBox(width: 12),
          Expanded(child: Text('Privacy Notice COMEN', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 4),
        Text('Versi 3.2 · berlaku sejak 1 Januari 2026', style: t.bodySmall),
        const SizedBox(height: 20),
        for (final (icon, title, body) in _sections)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Brand.blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 20, color: Brand.blue),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(body, style: t.bodyMedium?.copyWith(height: 1.5)),
                ]),
              ),
            ]),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonal(
            onPressed: () => context.canPop() ? context.pop() : context.go('/login'),
            child: const Text('Kembali'),
          ),
        ),
      ]),
    );
  }
}
