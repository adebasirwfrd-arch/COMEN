/// Label Bahasa Indonesia untuk enum database (dipakai lintas fitur).
abstract final class Labels {
  static const phase = <String, String>{
    'vendor_onboarding': 'Vendor Onboarding',
    'evaluation': 'Evaluasi',
    'post_award': 'Post-Award',
    'pre_mobilization': 'Pre-Mobilization',
    'mobilization': 'Mobilisasi',
    'execution': 'Eksekusi',
    'monitoring': 'Monitoring',
    'demobilization': 'Demobilisasi',
    'final_evaluation': 'Evaluasi Akhir',
  };
  static const kind = <String, String>{
    'document': 'Dokumen',
    'evidence': 'Bukti',
    'form': 'Form',
    'checklist': 'Checklist',
    'action': 'Action',
  };
  static const scope = <String, String>{'vendor': 'Vendor', 'contract': 'Kontrak', 'subcontractor': 'Subkontraktor'};
  static const risk = <String, String>{'low': 'Rendah', 'medium': 'Sedang', 'high': 'Tinggi'};
  static const linkType = <String, String>{'file_request': 'File Request (upload saja)', 'folder_edit': 'Folder (edit)'};
  static const taskEvent = <String, String>{
    'created': 'Task dibuat',
    'link_opened': 'Link OneDrive dibuka',
    'upload_confirmed': 'Upload dikonfirmasi',
    'email_claimed': 'Email konfirmasi dikirim',
    'email_verified': 'Email terverifikasi',
    'review_started': 'Review dimulai',
    'reviewed': 'Keputusan review',
    'approved': 'Disetujui',
    'revise': 'Perlu revisi',
    'rejected': 'Ditolak',
    'file_issue': 'File bermasalah',
    'waived': 'Dikecualikan (waive)',
    'cancelled': 'Dibatalkan',
    'superseded': 'Digantikan',
    'reopened': 'Dibuka ulang',
    'expired': 'Kedaluwarsa',
    'reminder': 'Pengingat terkirim',
    'escalated': 'Dieskalasi',
    'checklist_item': 'Item checklist diperbarui',
    'assigned': 'Ditugaskan',
  };

  static String of(Map<String, String> m, dynamic v) => m[v?.toString()] ?? (v?.toString() ?? '-');
  static String phaseOf(dynamic v) => of(phase, v);
  static String kindOf(dynamic v) => of(kind, v);
}
