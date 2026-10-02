import 'package:comen/core/router/route_rules.dart';
import 'package:comen/core/session/contract_classification.dart';
import 'package:comen/core/session/session_state.dart';
import 'package:comen/ui/classification_badges.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SessionState _contractor(List<String> tiers, {String? level = 'employee'}) => SessionState.fromJson({
      'user_id': '0f8fad5b-d9cb-469f-a165-70867728950e',
      'email': 'c@x.com',
      'status': 'active',
      'is_wfrd': false,
      'contractor_id': '1f8fad5b-d9cb-469f-a165-70867728950e',
      'device_state': 'ok',
      'contractor_level': level,
      'active_contracts': [
        for (final t in tiers) {'id': t, 'access_tier': t},
      ],
    });

void main() {
  group('AccessTier.resolve (= kolom GENERATED contracts.access_tier)', () {
    test('matriks mode × durasi', () {
      expect(AccessTier.resolve(ContractMode.mode1, 365), AccessTier.full);
      expect(AccessTier.resolve(ContractMode.mode2, 365), AccessTier.full);
      expect(AccessTier.resolve(ContractMode.mode1, 60), AccessTier.streamlined);
      expect(AccessTier.resolve(ContractMode.mode2, 90), AccessTier.streamlined);
      expect(AccessTier.resolve(ContractMode.mode3, 200), AccessTier.minimal);
      expect(AccessTier.resolve(ContractMode.mode3, 30), AccessTier.visitor);
    });

    test('batas 90 hari: 90 = short, 91 = long', () {
      expect(DurationCategory.fromDays(90), DurationCategory.shortTerm);
      expect(DurationCategory.fromDays(91), DurationCategory.longTerm);
      expect(AccessTier.resolve(ContractMode.mode3, 90), AccessTier.visitor);
      expect(AccessTier.resolve(ContractMode.mode3, 91), AccessTier.minimal);
    });

    test('durasi hari = end − start (abaikan jam & DST)', () {
      expect(contractDurationDays(DateTime(2026, 1, 1, 23), DateTime(2026, 4, 1, 1)), 90);
      expect(contractDurationDays(DateTime(2026, 3, 1), DateTime(2026, 3, 1)), 0);
    });

    test('SLA & BBS per tier sesuai DB', () {
      expect([for (final t in AccessTier.values) t.reviewSlaDays], [5, 2, 3, 1]);
      expect([for (final t in AccessTier.values) t.bbsPerWeek], [30, 10, 5, 0]);
    });
  });

  group('kode enum', () {
    test('kode identik dengan enum Postgres & fallback aman', () {
      expect(ContractMode.values.map((m) => m.code), ['mode_1', 'mode_2', 'mode_3']);
      expect(AccessTier.values.map((t) => t.code), ['full', 'streamlined', 'minimal', 'visitor']);
      expect(ContractorUserLevel.values.map((l) => l.code), ['pic', 'supervisor', 'employee']);
      expect(ContractMode.fromCode('x'), ContractMode.mode1);
      expect(AccessTier.tryCode(null), isNull);
      expect(ContractorUserLevel.tryCode('admin'), isNull);
    });

    test('hierarki level', () {
      expect(ContractorUserLevel.pic.atLeast(ContractorUserLevel.supervisor), isTrue);
      expect(ContractorUserLevel.supervisor.atLeast(ContractorUserLevel.supervisor), isTrue);
      expect(ContractorUserLevel.employee.atLeast(ContractorUserLevel.supervisor), isFalse);
    });
  });

  group('SessionState v3.3', () {
    test('level & tier tertinggi', () {
      final s = _contractor(['visitor', 'minimal'], level: 'supervisor');
      expect(s.contractorLevel, ContractorUserLevel.supervisor);
      expect(s.maxTier, AccessTier.minimal);
      expect(s.onlyVisitorContracts, isFalse);
    });

    test('menu KPI disembunyikan bila semua kontrak visitor', () {
      final kpi = RouteRules.match('/kpi')!;
      expect(kpi.allows(_contractor(['visitor'])), isFalse);
      expect(kpi.allows(_contractor(['visitor', 'full'])), isTrue);
      expect(kpi.allows(_contractor([])), isTrue);
    });

    test('field lama tanpa data v3.3 tetap aman', () {
      final s = _contractor([], level: null);
      expect(s.contractorLevel, isNull);
      expect(s.maxTier, isNull);
      expect(s.onlyVisitorContracts, isFalse);
    });
  });

  testWidgets('ClassificationBadges menampilkan mode · durasi · tier', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ClassificationBadges({'contract_mode': 'mode_3', 'duration_category': 'short_term', 'duration_days': 30, 'access_tier': 'visitor'}),
      ),
    ));
    expect(find.text('MODE 3'), findsOneWidget);
    expect(find.text('SHORT-TERM'), findsOneWidget);
    expect(find.text('VISITOR'), findsOneWidget);
  });

  testWidgets('ClassificationBadges kosong bila tier tidak ada', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ClassificationBadges({}))));
    expect(find.byType(Wrap), findsNothing);
  });
}
