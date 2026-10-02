import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Daftar domain email disposable (asset statis, diperbarui CI mingguan) — risk hint di User Approval & registrasi.
final disposableDomainsProvider = FutureProvider<Set<String>>((_) async {
  final raw = await rootBundle.loadString('assets/security/disposable_domains.txt');
  return raw.split('\n').map((l) => l.trim().toLowerCase()).where((l) => l.isNotEmpty && !l.startsWith('#')).toSet();
});

bool isDisposableEmail(Set<String> domains, String email) {
  final at = email.lastIndexOf('@');
  if (at < 0) return false;
  var d = email.substring(at + 1).trim().toLowerCase();
  while (true) {
    if (domains.contains(d)) return true;
    final dot = d.indexOf('.');
    if (dot < 0 || dot == d.length - 1) return false;
    d = d.substring(dot + 1);
    if (!d.contains('.')) return false;
  }
}
