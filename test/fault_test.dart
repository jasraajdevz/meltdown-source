// Malfunction suite.
//
// A fault that cannot start, or that cannot be cleared with the controls the
// hint names, is worse than no fault at all — it is an unwinnable night. Every
// one in the catalogue is driven end to end here.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:meltdown_reactor/main.dart';

/// A plant at steady full load, which is where almost everything goes wrong.
Plant atPower({int pumps = 2}) {
  final p = Plant(upgrades: {})
    ..scrammed = false
    ..scramLatched = false
    ..rod = [100, 100, 100, 100]
    ..boron = 700
    ..power = 0.9
    ..fuelTemp = 640
    ..tAvg = 302
    ..pressure = 155
    ..msiv = true
    ..feedPump = 75
    ..throttle = 70
    ..steamFlow = 0.7
    ..sgLevel = 50
    ..genBreaker = true
    ..mwe = 700
    ..mwhThisShift = 40
    ..uraniumThisShift = 5000;
  for (var i = 0; i < pumps; i++) {
    p.rcp[i] = true;
  }
  return p;
}

/// Run the plant forward without letting the operator do anything.
void run(Plant p, double seconds) {
  for (var t = 0.0; t < seconds; t += 0.05) {
    p.step(0.05);
  }
}

Fault byId(String id) => kFaults.firstWhere((f) => f.id == id);

void main() {
  group('the catalogue is coherent', () {
    test('every fault has a unique id and a hint that names a panel', () {
      final ids = kFaults.map((f) => f.id).toSet();
      expect(ids.length, kFaults.length, reason: 'duplicate fault id');
      for (final f in kFaults) {
        expect(f.hint.length, greaterThan(30),
            reason: '${f.id} hint is too thin to act on');
        expect(f.holdFor, greaterThan(0));
        expect(f.minShift, greaterThanOrEqualTo(0));
      }
    });

    test('every fault is ready in some reachable plant state', () {
      // Three loops: a plant that has bought itself some margin, which is the
      // only state a pump trip is fair from.
      final p = atPower(pumps: 3);
      final unready = [
        for (final f in kFaults)
          if (!f.ready(p)) f.id
      ];
      // porvStuck needs the valve shut, which it is; losp needs real output.
      expect(unready, isEmpty,
          reason: 'these can never start from steady full load: $unready');
    });

    test('difficulty is staged rather than dumped on watch one', () {
      expect(kFaults.where((f) => f.minShift <= 2).length, greaterThan(0));
      expect(kFaults.where((f) => f.minShift >= 5).length, greaterThan(1));
    });
  });

  group('each malfunction starts, bites, and can be cleared', () {
    test('rcp trip — the plant survives it, but the fuel runs hot', () {
      final p = atPower(pumps: 3);
      p.startFault(byId('rcpTrip'));
      expect(p.pumpCount, 2, reason: 'a running pump should have dropped out');
      expect(p.faultId, 'rcpTrip');

      run(p, 20);
      expect(p.scrammed, isFalse,
          reason: 'losing one of three loops must never be an automatic trip');
      expect(p.fuelTemp, greaterThan(800),
          reason: 'but it should be uncomfortable');
      expect(p.faultId, 'rcpTrip', reason: 'riding it out is not handling it');
    });

    test('rcp trip — bringing power down clears it', () {
      final p = atPower(pumps: 3);
      final f = byId('rcpTrip');
      p.startFault(f);
      for (var t = 0.0; t < f.holdFor + 4; t += 0.05) {
        p.power = 0.5; // reduced to match the flow you have left
        p.step(0.05);
      }
      expect(p.faultId, isNull, reason: 'should have cleared under 65% power');
      expect(p.faultsHandled, 1);
      expect(p.pumpLock, isEmpty, reason: 'the breaker must be released');
    });

    test('rcp trip — starting the spare loop also clears it', () {
      final p = atPower(pumps: 4);
      p.startFault(byId('rcpTrip'));
      expect(p.pumpCount, 3, reason: 'three of four still running');
      run(p, 22);
      expect(p.faultId, isNull);
      expect(p.faultsHandled, 1);
    });

    test('a scram is never a way out of a malfunction', () {
      final p = atPower(pumps: 3);
      p.startFault(byId('rcpTrip'));
      p.scram('OPERATOR');
      // Tripped, so power is far under the threshold — but that is not the
      // same as having dealt with it.
      run(p, 30);
      expect(p.faultId, 'rcpTrip');
      expect(p.faultsHandled, 0);
    });

    test('jammed bank — the locked bank will not move, boron still works', () {
      final p = atPower();
      p.bank = 1;
      p.rod = [100, 60, 100, 100];
      p.startFault(byId('stuckRod'));
      expect(p.rodLock, 1);

      p.rodCmd = RodCmd.withdraw;
      run(p, 5);
      expect(p.rod[1], closeTo(60, 0.01),
          reason: 'a jammed bank must not answer the drive');

      // A different bank is unaffected.
      p.bank = 2;
      p.rod[2] = 50;
      run(p, 2);
      expect(p.rod[2], greaterThan(50));
    });

    test('jammed bank — holding the rate steady frees it', () {
      final p = atPower();
      p.startFault(byId('stuckRod'));
      p.rodCmd = RodCmd.hold;
      // Pin the core steady, which is exactly what the hint asks for.
      for (var t = 0.0; t < 50; t += 0.05) {
        p.sur = 0.05;
        p.step(0.05);
      }
      expect(p.faultId, isNull);
      expect(p.rodLock, isNull);
    });

    test('vacuum decay — megawatts fall with the throttle untouched', () {
      final p = atPower();
      p.startFault(byId('vacuum'));
      final before = p.steamFlow;
      run(p, 12);
      expect(p.effLoss, greaterThan(0.1));
      expect(p.steamFlow, lessThan(before),
          reason: 'same throttle should now make less steam flow');

      p.throttle = 30;
      run(p, 45);
      expect(p.faultId, isNull);
      expect(p.effLoss, 0);
    });

    test('feed pump trip — the generator drains, AFW stops it', () {
      final p = atPower();
      p.startFault(byId('fwTrip'));
      expect(p.feedLock, isTrue);
      final before = p.sgLevel;
      run(p, 12);
      expect(p.sgLevel, lessThan(before), reason: 'level must be falling');

      p.afw = true;
      run(p, 34);
      expect(p.faultId, isNull);
      expect(p.feedLock, isFalse);
    });

    test('stuck porv — it opens itself and bleeds pressure until shut', () {
      final p = atPower();
      p.startFault(byId('porvStuck'));
      expect(p.porv, isTrue, reason: 'the valve lifts on its own');
      expect(p.porvStuck, isTrue);
      final before = p.pressure;
      run(p, 6);
      expect(p.pressure, lessThan(before));
      expect(p.condition('porv'), isTrue,
          reason: 'the annunciator is how you find it');

      p.porv = false;
      run(p, 6);
      expect(p.faultId, isNull);
      expect(p.porvStuck, isFalse);
    });

    test('stuck porv bleeds slower than a commanded lift', () {
      // A full lift would empty the pressuriser before anyone could react.
      final stuck = atPower()..startFault(byId('porvStuck'));
      final manual = atPower()..porv = true;
      run(stuck, 4);
      run(manual, 4);
      expect(stuck.pressure, greaterThan(manual.pressure),
          reason: 'a stuck seat is a leak, not an open valve');
    });

    test('tube leak — activity climbs and ramping down isolates it', () {
      final p = atPower();
      p.startFault(byId('tubeLeak'));
      run(p, 15);
      expect(p.radiation, greaterThan(5), reason: 'activity must show up');
      expect(p.condition('hirad'), isTrue);

      p.power = 0.15;
      for (var t = 0.0; t < 26; t += 0.05) {
        p.power = 0.15;
        p.step(0.05);
      }
      expect(p.faultId, isNull);
      expect(p.leakRate, 0);
    });

    test('flux channel — the meter lies but the core is fine', () {
      final p = atPower();
      final trueFlux = p.fluxDecades;
      p.startFault(byId('fluxFail'));
      run(p, 4);
      expect(p.fluxBias, greaterThan(0.5));
      expect(p.iFlux, greaterThan(trueFlux + 0.4),
          reason: 'the displayed value must be the one that is wrong');
      expect(p.power, closeTo(0.9, 0.35),
          reason: 'the actual core must be unaffected');
    });

    test('flux channel — holding your nerve clears it', () {
      final p = atPower();
      p.startFault(byId('fluxFail'));
      run(p, 60);
      expect(p.faultId, isNull);
      expect(p.faultsHandled, 1);
      expect(p.fluxBias, 0);
    });

    test('flux channel — chasing it with a scram fails it outright', () {
      final p = atPower();
      p.startFault(byId('fluxFail'));
      p.scram('OPERATOR');
      p.step(0.05);
      expect(p.faultId, isNull);
      expect(p.faultsFailed, 1);
      expect(p.faultsHandled, 0);
      expect(p.fluxBias, 0, reason: 'a failed fault still has to clean up');
    });

    test('blackout — the breaker locks out until the diesel is running', () {
      final p = atPower();
      p.startFault(byId('losp'));
      expect(p.genBreaker, isFalse);
      expect(p.breakerLock, isTrue);

      // You cannot simply put it back.
      p.genBreaker = true;
      run(p, 2);
      expect(p.genBreaker, isFalse, reason: 'the line is still faulted');
      expect(p.mwe, 0);

      p.edg = true;
      run(p, 20);
      expect(p.faultId, isNull);
      expect(p.breakerLock, isFalse);
      p.genBreaker = true;
      run(p, 1);
      expect(p.genBreaker, isTrue, reason: 'you can resynchronise now');
    });
  });

  group('handling things is rewarded, ignoring them is not', () {
    test('clearing pays a bonus and counts', () {
      final p = atPower(pumps: 4);
      final before = p.uraniumThisShift;
      p.startFault(byId('rcpTrip'));
      run(p, 22);
      expect(p.faultsHandled, 1);
      expect(p.uraniumThisShift, greaterThan(before + 400));
    });

    test('handing over with something still open counts against you', () {
      final p = atPower();
      p.startFault(byId('tubeLeak'));
      run(p, 6);
      final paid = p.uraniumThisShift;
      p.abandonFault();
      expect(p.faultsFailed, 1);
      expect(p.faultsHandled, 0);
      expect(p.uraniumThisShift, closeTo(paid, 0.01),
          reason: 'no bonus for walking away from it');
      expect(p.leakRate, 0, reason: 'effects must not outlive the watch');
    });

    test('backsliding loses ground but not all of it', () {
      final p = atPower(pumps: 4);
      final f = byId('rcpTrip');
      p.startFault(f);
      run(p, 10); // banking progress with three loops still turning
      final banked = p.faultHold;
      expect(banked, greaterThan(4));
      p.rcp[1] = false; // drop another loop, back under the bar
      run(p, 4);
      expect(p.faultHold, lessThan(banked));
      expect(p.faultHold, greaterThan(0),
          reason: 'progress should decay, not reset');
    });
  });

  group('a malfunction survives the app being killed', () {
    test('the fault and everything it broke come back', () {
      final p = atPower();
      p.startFault(byId('fwTrip'));
      run(p, 8);
      final saved = p.toJson();

      final q = Plant(upgrades: {})..applyJson(saved);
      expect(q.faultId, 'fwTrip');
      expect(q.feedLock, isTrue);
      expect(q.faultHold, closeTo(p.faultHold, 0.01));
      expect(q.faultsSeen, 1);
    });

    test('a save naming a fault that no longer exists is survived', () {
      final p = atPower();
      final saved = p.toJson();
      saved['fault'] = 'someRemovedFault';
      final q = Plant(upgrades: {})..applyJson(saved);
      expect(q.faultId, isNull);
      expect(q.fault, isNull);
    });

    test('starting a watch wipes the night before', () {
      final p = atPower();
      p.startFault(byId('tubeLeak'));
      run(p, 5);
      p.startShift(hot: false);
      expect(p.faultId, isNull);
      expect(p.faultsSeen, 0);
      expect(p.faultsHandled, 0);
      expect(p.leakRate, 0);
      expect(p.pumpLock, isEmpty);
      expect(p.rodLock, isNull);
      expect(p.effLoss, 0);
      expect(p.feedLock, isFalse);
      expect(p.breakerLock, isFalse);
      expect(p.fluxBias, 0);
    });
  });

  group('scheduling never makes a night unfair', () {
    setUp(rawWipe);

    testWidgets('the tutorial watch is completely clean', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = true;
      expect(g.faultsPlanned, 0);
    });

    test('difficulty climbs with nights served and never plateaus', () {
      // The old ladder was three integers and topped out on watch six, so
      // night 6, night 20 and night 200 were the same night.
      int planned(int n) => NightSpec.of(n).faultsPlanned;
      expect(planned(1), lessThanOrEqualTo(1),
          reason: 'the opening nights stay clean');
      expect(planned(2), lessThanOrEqualTo(1));
      expect(planned(20), greaterThan(planned(6)));
      expect(planned(200), greaterThan(planned(20)));
      expect(planned(900), greaterThanOrEqualTo(planned(200)));
      for (var n = 1; n <= 1000; n++) {
        expect(planned(n), inInclusiveRange(0, 9), reason: 'night \$n');
      }
    });

    testWidgets('nothing interrupts a cold start', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.shifts = 9;
      g.startShift();
      g.faultTimer = 0; // due immediately
      // The plant is cold and has generated nothing.
      for (var i = 0; i < 200; i++) {
        g.maybeStartFault(0.05);
      }
      expect(g.plant.faultId, isNull,
          reason: 'a cold startup is hard enough on its own');
    });

    testWidgets('the same failure never turns up twice in one watch',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.shifts = 20;
      g.startShift();
      final seen = <String>[];
      for (var round = 0; round < g.faultsPlanned; round++) {
        // Put the plant somewhere a fault can start from.
        final p = g.plant;
        final hot = atPower(pumps: 3);
        p.applyJson(hot.toJson());
        p.mwhThisShift = 40;
        g.faultTimer = 0;
        for (var i = 0; i < 60 && p.faultId == null; i++) {
          g.maybeStartFault(0.05);
        }
        if (p.faultId == null) break;
        seen.add(p.faultId!);
        p.abandonFault();
      }
      expect(seen.length, greaterThan(1), reason: 'should have fired several');
      expect(seen.toSet().length, seen.length, reason: 'repeats: $seen');
    });

    testWidgets('the plan is respected — no fourth fault on a three-fault watch',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.shifts = 20;
      g.startShift();
      final p = g.plant;
      for (var round = 0; round < 8; round++) {
        p.applyJson(atPower(pumps: 3).toJson());
        p.mwhThisShift = 40;
        p.faultsSeen = g.plant.faultsSeen;
        g.faultTimer = 0;
        for (var i = 0; i < 60 && p.faultId == null; i++) {
          g.maybeStartFault(0.05);
        }
        if (p.faultId != null) p.abandonFault();
      }
      expect(p.faultsSeen, lessThanOrEqualTo(g.faultsPlanned));
    });
  });

  group('the watch grade', () {
    setUp(rawWipe);

    testWidgets('a clean full watch grades well and a lost core does not',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;

      g.reportMelted = false;
      g.reportBrokeDown = false;
      g.reportMwh = 340;
      g.reportIncidents = 3;
      g.reportHandled = 3;
      g.reportDamage = 0;
      g.reportSanity = 90;
      expect(g.watchGrade, 'A');

      g.reportMelted = true;
      expect(g.watchScore, 0);
      expect(g.watchGrade, 'F');
    });

    testWidgets('ignoring malfunctions costs a grade', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.reportMelted = false;
      g.reportBrokeDown = false;
      g.reportMwh = 340;
      g.reportDamage = 0;
      g.reportSanity = 90;

      g.reportIncidents = 3;
      g.reportHandled = 3;
      final handled = g.watchScore;
      g.reportHandled = 0;
      expect(g.watchScore, lessThan(handled - 25));
    });

    testWidgets('walking out is worse than a poor watch', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.reportMelted = false;
      g.reportMwh = 200;
      g.reportIncidents = 0;
      g.reportHandled = 0;
      g.reportDamage = 0;
      g.reportSanity = 10;
      g.reportBrokeDown = false;
      final stayed = g.watchScore;
      g.reportBrokeDown = true;
      expect(g.watchScore, lessThan(stayed));
    });

    testWidgets('handling things pays research on top of megawatt-hours',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.mwhThisShift = 120;
      final plain = g.plant.researchFor();
      g.plant.faultsHandled = 2;
      g.endShift(melted: false);
      expect(g.reportResearch, plain + 2);
    });
  });
}
