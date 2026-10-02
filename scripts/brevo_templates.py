#!/usr/bin/env python3
"""Buat/perbarui 47 template transaksional Brevo (12.3) dan cetak mapping JSON {comen_id: brevo_id}.

Pemakaian: python3 scripts/brevo_templates.py [--env .env.production.local] > /tmp/brevo_map.json
Idempoten: template dicocokkan berdasarkan nama "COMEN <id> · <nama>".
"""
import argparse
import json
import sys
import urllib.request

TEMPLATES = {
    1001: ('Registration Received', 'Registrasi diterima · {{ params.tracking_id }}', 'Terima kasih, registrasi perusahaan Anda sudah kami terima dan sedang diverifikasi tim WFRD.'),
    1002: ('Needs Info', 'Registrasi perlu informasi tambahan', 'Tim WFRD memerlukan informasi tambahan untuk melanjutkan verifikasi vendor Anda.'),
    1003: ('ASL Approved', 'Selamat — perusahaan Anda masuk Approved Supplier List', 'Perusahaan Anda telah disetujui masuk Approved Supplier List (ASL) WFRD.'),
    1004: ('ASL Conditional', 'ASL disetujui dengan syarat', 'Perusahaan Anda disetujui masuk ASL dengan syarat yang perlu dipenuhi.'),
    1005: ('Vendor Rejected', 'Hasil verifikasi vendor', 'Mohon maaf, pengajuan vendor Anda belum dapat disetujui saat ini.'),
    1006: ('ASL Expiry', 'Status ASL akan berakhir', 'Status Approved Supplier List perusahaan Anda akan segera berakhir. Mohon lakukan pembaruan.'),
    1007: ('Account Invite', 'Undangan bergabung ke COMEN', 'Anda diundang untuk bergabung ke COMEN — platform Contractor Management Weatherford.'),
    2001: ('Task Generated', 'Task baru: {{ params.title }}', 'Task kepatuhan baru telah dibuat untuk Anda.'),
    2002: ('Reminder', 'Pengingat task: {{ params.title }}', 'Task berikut mendekati jatuh tempo.'),
    2003: ('Overdue', 'OVERDUE · {{ params.task_id }}', 'Task berikut telah melewati jatuh tempo. Mohon segera ditindaklanjuti.'),
    2004: ('Submitted', 'Siap direview · {{ params.task_id }}', 'Contractor telah mengirimkan dokumen untuk direview.'),
    2005: ('Approved', 'Disetujui · {{ params.task_id }}', 'Dokumen Anda telah disetujui oleh reviewer WFRD.'),
    2006: ('Revision', 'Perlu revisi · {{ params.task_id }}', 'Reviewer meminta revisi atas dokumen Anda. Task revisi baru telah dibuat.'),
    2007: ('Rejected', 'Ditolak · {{ params.task_id }}', 'Dokumen Anda ditolak oleh reviewer WFRD.'),
    2008: ('File Issue', 'File bermasalah · {{ params.task_id }}', 'Reviewer tidak dapat menemukan atau memverifikasi file Anda di OneDrive. Mohon konfirmasi ulang upload.'),
    2009: ('Doc Expiry', 'Dokumen akan kedaluwarsa', 'Dokumen berikut akan segera kedaluwarsa. Task pembaruan telah dibuat.'),
    2010: ('Daily Digest', 'Ringkasan task mendekati jatuh tempo', 'Berikut task Anda yang mendekati jatuh tempo.'),
    2011: ('Review SLA', 'SLA review terlewat', 'Ada dokumen yang melewati batas waktu review (SLA).'),
    2012: ('Upload Link Missing', 'Task tanpa link OneDrive', 'Ada task dokumen yang belum memiliki link upload OneDrive. Reminder contractor ditahan sampai link tersedia.'),
    2013: ('Email Confirmation Pending', 'Email konfirmasi belum dikirim · {{ params.task_id }}', 'Anda sudah mengonfirmasi upload, tetapi email konfirmasi berisi KODE belum dikirim.'),
    2014: ('Manual Reminder', 'Pengingat dari WFRD: {{ params.title }}', 'Tim WFRD mengingatkan Anda untuk menyelesaikan task berikut.'),
    3001: ('Incident High/Critical', 'INSIDEN {{ params.severity }} · {{ params.contract_no }}', 'Insiden dengan tingkat keparahan tinggi telah dilaporkan.'),
    3002: ('Incident Report Overdue', 'Laporan insiden terlambat', 'Laporan investigasi insiden telah melewati batas waktu.'),
    3003: ('Critical Finding', 'Temuan audit kritis · {{ params.finding_no }}', 'Temuan audit dengan kategori kritis telah dicatat.'),
    3004: ('Stop-Work', 'STOP WORK · {{ params.contract_no }}', 'Stop-Work Authority telah dinyatakan.'),
    3005: ('Subcon Approval Request', 'Permintaan persetujuan subkontraktor', 'Ada permintaan persetujuan subkontraktor baru.'),
    4001: ('Awarded', 'Kontrak diberikan · {{ params.contract_no }}', 'Selamat, kontrak telah diberikan kepada perusahaan Anda.'),
    4002: ('MoM Ready to Sign', 'MoM siap ditandatangani · {{ params.contract_no }}', 'Minutes of Meeting siap untuk ditandatangani.'),
    4003: ('Pre-Mob Complete', 'Pre-mobilisasi selesai · {{ params.contract_no }}', 'Seluruh persyaratan pre-mobilisasi telah terpenuhi.'),
    4004: ('Go-Live', 'Go-Live · {{ params.contract_no }}', 'Kontrak telah resmi Go-Live.'),
    4005: ('Contract Expiry 60d', 'Kontrak berakhir dalam 60 hari', 'Kontrak berikut akan berakhir dalam 60 hari.'),
    4006: ('Demob', 'Demobilisasi dimulai', 'Fase demobilisasi kontrak telah dimulai.'),
    4007: ('OPR Complete', 'OPR selesai', 'Overall Performance Review kontrak telah selesai.'),
    4008: ('Closed', 'Kontrak ditutup', 'Kontrak telah ditutup.'),
    5001: ('Weekly KPI', 'Ringkasan KPI mingguan', 'Berikut ringkasan KPI kontrak yang Anda kelola minggu ini.'),
    5002: ('Monthly Report Reminder', 'Pengingat laporan bulanan {{ params.period }}', 'Laporan bulanan HSE perlu dikirim.'),
    6001: ('Unread Digest', 'Anda punya pesan yang belum dibaca', 'Ada pesan chat COMEN yang belum Anda baca.'),
    6002: ('Urgent Message', 'Pesan URGENT di COMEN', 'Anda menerima pesan berprioritas urgent.'),
    6003: ('Announcement', 'Pengumuman wajib dibaca', 'Ada pengumuman yang wajib Anda baca dan konfirmasi.'),
    7001: ('New User Pending', 'User baru menunggu persetujuan', 'Seorang pengguna baru mendaftar dan menunggu persetujuan Admin.'),
    7002: ('New Device Login', 'Login dari perangkat baru', 'Akun Anda baru saja digunakan untuk masuk dari perangkat baru. Jika ini bukan Anda, segera cabut perangkat tersebut.'),
    7003: ('Account Approved', 'Akun COMEN Anda aktif', 'Akun Anda telah disetujui. Anda sekarang dapat menggunakan COMEN.'),
    7004: ('Account Suspended', 'Akun ditangguhkan', 'Akun COMEN Anda ditangguhkan.'),
    7005: ('Security Alert', 'Peringatan keamanan COMEN', 'Sistem mendeteksi aktivitas keamanan yang perlu ditinjau.'),
    7006: ('Daily Audit Anchor', 'Audit anchor harian', 'Hash rantai audit harian COMEN.'),
    7007: ('Role Changed', 'Perubahan role akun', 'Role atau akses akun Anda telah berubah.'),
    7008: ('Account Rejected', 'Pendaftaran akun ditolak', 'Pendaftaran akun COMEN Anda tidak disetujui.'),
}

FIELDS = [
    ('task_id', 'Task ID'), ('contract_no', 'Kontrak'), ('company', 'Perusahaan'), ('phase', 'Fase'), ('due', 'Jatuh tempo'),
    ('count', 'Jumlah'), ('tracking_id', 'Tracking ID'), ('incident_no', 'No. insiden'), ('severity', 'Severity'),
    ('finding_no', 'No. temuan'), ('mom_no', 'No. MoM'), ('period', 'Periode'), ('role', 'Role'), ('action', 'Aksi'),
    ('label', 'Perangkat'), ('at', 'Waktu'), ('name', 'Nama'), ('email', 'Email'), ('key', 'Kategori'),
    ('expires_on', 'Berlaku s/d'), ('days', 'Sisa hari'), ('escalation', 'Eskalasi'),
]


def html(cid, intro):
    rows = ''.join(
        f'{{% if params.{k} %}}<tr><td style="padding:6px 0;color:#667085;width:140px">{label}</td>'
        f'<td style="padding:6px 0;color:#0A1F44;font-weight:600">{{{{ params.{k} }}}}</td></tr>{{% endif %}}'
        for k, label in FIELDS)
    items = ''
    if cid == 2010:
        items = ('{% if params.items %}<table width="100%" style="border-collapse:collapse;margin-top:12px">'
                 '{% for it in params.items %}<tr><td style="padding:8px 0;border-top:1px solid #EAECF0;font-family:monospace;color:#0B5FFF">{{ it.task_id }}</td>'
                 '<td style="padding:8px 0;border-top:1px solid #EAECF0">{{ it.title }}</td>'
                 '<td style="padding:8px 0;border-top:1px solid #EAECF0;text-align:right;color:#F79009">H-{{ it.days }}</td></tr>{% endfor %}</table>{% endif %}')
    elif cid == 5001:
        items = ('{% if params.items %}<table width="100%" style="border-collapse:collapse;margin-top:12px">'
                 '{% for it in params.items %}<tr><td style="padding:8px 0;border-top:1px solid #EAECF0;font-family:monospace">{{ it.contract_no }}</td>'
                 '<td style="padding:8px 0;border-top:1px solid #EAECF0;text-align:right;font-weight:700">{{ it.score }}</td>'
                 '<td style="padding:8px 0;border-top:1px solid #EAECF0;text-align:right">{{ it.color }}</td></tr>{% endfor %}</table>{% endif %}')
    return f'''<!DOCTYPE html><html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:#F2F4F7;font-family:Segoe UI,Helvetica,Arial,sans-serif;color:#101828">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#F2F4F7;padding:24px 12px"><tr><td align="center">
<table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden">
<tr><td style="background:linear-gradient(135deg,#0A1F44,#0B5FFF);background-color:#0A1F44;padding:24px 28px">
<div style="color:#ffffff;font-size:22px;font-weight:800;letter-spacing:2px">COMEN</div>
<div style="color:#B2CCFF;font-size:12px">Contractor Management · Weatherford</div></td></tr>
<tr><td style="padding:28px">
<h1 style="margin:0 0 12px;font-size:20px;color:#0A1F44">{{{{ params.title }}}}</h1>
<p style="margin:0 0 16px;line-height:1.6;color:#344054">{intro}</p>
{{% if params.message %}}<p style="margin:0 0 16px;padding:12px 16px;background:#F5F8FF;border-left:4px solid #0B5FFF;border-radius:8px">{{{{ params.message }}}}</p>{{% endif %}}
{{% if params.notes %}}<p style="margin:0 0 16px;padding:12px 16px;background:#FFFAEB;border-left:4px solid #F79009;border-radius:8px"><b>Catatan:</b> {{{{ params.notes }}}}</p>{{% endif %}}
{{% if params.reason %}}<p style="margin:0 0 16px;padding:12px 16px;background:#FEF3F2;border-left:4px solid #F04438;border-radius:8px"><b>Alasan:</b> {{{{ params.reason }}}}</p>{{% endif %}}
<table width="100%" style="border-collapse:collapse">{rows}</table>
{items}
{{% if params.link %}}<p style="margin:24px 0 0"><a href="{{{{ params.app_url }}}}{{{{ params.link }}}}" style="display:inline-block;background:#0B5FFF;color:#ffffff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:10px">Buka di COMEN</a></p>{{% endif %}}
</td></tr>
<tr><td style="padding:16px 28px;background:#F9FAFB;color:#667085;font-size:11px;line-height:1.5">
Email otomatis COMEN #{cid}. Jangan membalas email ini. COMEN tidak pernah meminta password atau kode OTP Anda.<br>
Tautan hanya mengarah ke {{{{ params.app_url }}}} — abaikan email yang mengarah ke domain lain.</td></tr>
</table></td></tr></table></body></html>'''


def api(key, method, path, body=None):
    req = urllib.request.Request(f'https://api.brevo.com/v3{path}', method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'api-key': key, 'accept': 'application/json', 'content-type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--env', default='.env.production.local')
    a = ap.parse_args()
    env = {}
    for line in open(a.env):
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            env[k] = v.strip().strip('"')
    key, sender = env['BREVO_API_KEY'], env['BREVO_SENDER_EMAIL']

    existing = {}
    offset = 0
    while True:
        r = api(key, 'GET', f'/smtp/templates?templateStatus=true&limit=1000&offset={offset}')
        for t in r.get('templates', []) or []:
            existing[t['name']] = t['id']
        if len(r.get('templates', []) or []) < 1000:
            break
        offset += 1000

    mapping = {}
    for cid, (name, subject, intro) in TEMPLATES.items():
        tname = f'COMEN {cid} · {name}'
        body = {'templateName': tname, 'subject': subject, 'htmlContent': html(cid, intro),
                'sender': {'name': 'COMEN WFRD', 'email': sender}, 'isActive': True, 'tag': f'comen-{cid}'}
        if tname in existing:
            api(key, 'PUT', f'/smtp/templates/{existing[tname]}', body)
            mapping[str(cid)] = existing[tname]
        else:
            mapping[str(cid)] = api(key, 'POST', '/smtp/templates', body)['id']
        print(f'✓ {cid} → {mapping[str(cid)]}', file=sys.stderr)
    print(json.dumps(mapping))


if __name__ == '__main__':
    main()
