import 'package:url_launcher/url_launcher.dart';
import '../env.dart';
import '../errors/app_failure.dart';

abstract final class UrlPolicy {
  static final _oneDriveHost = RegExp(r'^(1drv\.ms|onedrive\.live\.com|[a-z0-9-]+\.sharepoint\.com)$');

  static Uri? _https(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null || u.scheme != 'https' || u.userInfo.isNotEmpty || u.hasPort || u.host.isEmpty) return null;
    return u;
  }
  static bool isOneDrive(String raw) => _https(raw) != null && _oneDriveHost.hasMatch(_https(raw)!.host.toLowerCase());
  static bool isComen(String raw) => _https(raw)?.host.toLowerCase() == Uri.parse(Env.appOrigin).host.toLowerCase();
  static bool isPersonalOneDrive(String raw) => RegExp(r'^(1drv\.ms|onedrive\.live\.com)$').hasMatch(_https(raw)?.host.toLowerCase() ?? '');

  /// Chat & task: hanya OneDrive/SharePoint/COMEN yang bisa diklik (anti-phishing); lainnya teks biasa
  static bool clickable(String raw) => isOneDrive(raw) || isComen(raw);

  static Future<void> open(String raw) async {
    if (!clickable(raw)) throw const AppFailure(Hint.forbidden, 'Link tidak diizinkan');
    await launchUrl(Uri.parse(raw), webOnlyWindowName: '_blank');
  }
}
