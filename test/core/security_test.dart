@TestOn('browser')
library;

import 'package:comen/core/router/gate.dart';
import 'package:comen/core/security/fingerprint.dart';
import 'package:comen/core/security/url_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('safeNext (C3 anti open-redirect)', () {
    test('menolak redirect eksternal & halaman sesi', () {
      for (final bad in [
        '//evil.com',
        'https://evil.com',
        '/\\evil',
        'evil',
        '',
        '/login',
        '/auth/callback',
        '/splash',
        '/pending',
        '/device-revoked',
        '/mfa/verify',
        '/mfa/enroll',
        '/x\u0000y',
        '/${'a' * 600}',
      ]) {
        expect(safeNext(bad), isNull, reason: bad);
      }
      expect(safeNext(null), isNull);
    });

    test('menerima path internal', () {
      const id = '0f8fad5b-d9cb-469f-a165-70867728950e';
      expect(safeNext('/tasks/$id?tab=x'), '/tasks/$id?tab=x');
      expect(safeNext('/dashboard'), '/dashboard');
      expect(safeNext('/admin/users'), '/admin/users');
    });
  });

  group('UrlPolicy', () {
    test('menerima OneDrive/SharePoint https', () {
      expect(UrlPolicy.isOneDrive('https://1drv.ms/f/s!abc'), isTrue);
      expect(UrlPolicy.isOneDrive('https://onedrive.live.com/?id=1'), isTrue);
      expect(UrlPolicy.isOneDrive('https://wfrd-my.sharepoint.com/:f:/g/personal/x'), isTrue);
      expect(UrlPolicy.isPersonalOneDrive('https://1drv.ms/f/s!abc'), isTrue);
      expect(UrlPolicy.isPersonalOneDrive('https://wfrd.sharepoint.com/x'), isFalse);
    });

    test('menolak http, domain tiruan, userinfo, port', () {
      expect(UrlPolicy.isOneDrive('http://wfrd.sharepoint.com/x'), isFalse);
      expect(UrlPolicy.isOneDrive('https://sharepoint.com.evil.io/x'), isFalse);
      expect(UrlPolicy.isOneDrive('https://evil.io/wfrd.sharepoint.com'), isFalse);
      expect(UrlPolicy.isOneDrive('https://user:pw@wfrd.sharepoint.com/x'), isFalse);
      expect(UrlPolicy.isOneDrive('https://wfrd.sharepoint.com:8443/x'), isFalse);
      expect(UrlPolicy.isOneDrive('javascript:alert(1)'), isFalse);
      expect(UrlPolicy.clickable('https://evil.io'), isFalse);
    });
  });

  group('fileNameMatchesTask & taskIdRe', () {
    const id = 'CMN-00042-HSEPLN-001';
    test('format nama file', () {
      expect(fileNameMatchesTask(id, id), isTrue);
      expect(fileNameMatchesTask('$id - HSE Plan.pdf', id), isTrue);
      expect(fileNameMatchesTask('$id.pdf', id), isTrue);
      expect(fileNameMatchesTask('$id-R1 - HSE Plan.pdf', id), isFalse);
      expect(fileNameMatchesTask('HSE Plan $id.pdf', id), isFalse);
      expect(fileNameMatchesTask('${id}X.pdf', id), isFalse);
    });

    test('Task ID valid/invalid', () {
      for (final ok in ['CMN-00042-HSEPLN-001', 'CMN-V00007-ASLDOC-002', 'CMN-00042S01-INSCRT-001', 'CMN-00042-HSEPLN-001-R2']) {
        expect(taskIdRe.hasMatch(ok), isTrue, reason: ok);
      }
      for (final bad in ['CMN-0042-HSEPLN-001', 'cmn-00042-hsepln-001', 'CMN-00042-HSEPLN-1', 'CMN-00042-HSEPLN-001-R100']) {
        expect(taskIdRe.hasMatch(bad), isFalse, reason: bad);
      }
    });
  });
}
