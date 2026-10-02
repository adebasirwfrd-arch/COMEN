// lib/core/security/browser_info.dart
import 'package:web/web.dart' as web;

abstract final class BrowserInfo {
  static String label() {
    final ua = web.window.navigator.userAgent;
    final browser = ua.contains('Edg/') ? 'Edge'
        : ua.contains('Firefox/') ? 'Firefox'
        : ua.contains('Chrome/') ? 'Chrome'
        : ua.contains('Safari/') ? 'Safari' : 'Browser';
    final os = ua.contains('Windows') ? 'Windows'
        : (ua.contains('iPhone') || ua.contains('iPad')) ? 'iOS'
        : ua.contains('Android') ? 'Android'
        : ua.contains('Mac OS X') ? 'macOS'
        : ua.contains('Linux') ? 'Linux' : 'OS';
    return '$browser · $os';
  }
}
