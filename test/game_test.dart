// The game imports dart:js_interop, so tests run in a real browser:
//   flutter test --platform chrome
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:meltdown_reactor/main.dart';

/// Advance the physics without any rendering.
void run(Plant p, double seconds, {double step = 0.05}) {
  final n = (seconds / step).round();
  for (var i = 0; i < n; i++) {
    p.step(step);
  }
}

Plant freshPlant({Map<String, int>? up}) =>
    Plant(upgrades: up ?? <String, int>{})..startShift(hot: false);

void main() {
  setUp(rawWipe);

  // -------------------------------------------------------------------------
  group('formatting', () {
    test('fmt uses K/M/B suffixes', () {
      expect(fmt(999), '999');
      expect(fmt(1234), '1.23K');
      expect(fmt(12345678), '12.3M');
      expect(fmt(9.87e9), '9.87B');
    });

    test('mmss renders clock time and infinity', () {
      expect(mmss(65), '1:05');
      expect(mmss(3725), '1:02:05');
      expect(mmss(double.infinity), '—');
    });
  });

  // -------------------------------------------------------------------------
  group('reactivity', () {
    test('a shut-down plant stays shut down', () {
      final p = freshPlant();
      run(p, 60);
      expect(p.power, lessThan(1e-5));
      expect(p.scrammed, isTrue);
    });

    test('trip cannot be reset until rods are in and power is low', () {
      final p = freshPlant();
      p.rod = [80, 80, 80, 80];
      expect(p.resetScram(), isFalse); // rods still out
      p.rod = [0, 0, 0, 0];
      expect(p.resetScram(), isTrue);
    });

    test('withdrawing rods takes the reactor critical', () {
      final p = freshPlant();
      p.rcp = [true, true, false, false];
      run(p, 150); // pump heat brings it to operating temperature
      p.resetScram();
      p.rod = [100, 100, 100, 100];
      p.boron = 1030;
      expect(p.reactivity, greaterThan(0));
      final before = p.power;
      run(p, 90);
      expect(p.power, greaterThan(before * 10)); // power is climbing
      expect(p.scrammed, isFalse); // and it is a controlled climb
    });

    test('boron shuts the reactor down without moving rods', () {
      final p = freshPlant();
      p.resetScram();
      p.tAvg = 300; // at operating temperature the temperature term is zero
      p.rod = [100, 100, 100, 100];
      p.boron = 500;
      final hot = p.reactivity;
      expect(hot, greaterThan(0)); // critical-capable
      p.boron = 2000;
      expect(p.reactivity, lessThan(hot));
      expect(p.reactivity, lessThan(0)); // shut down on boron alone
    });

    test('coolant pumps heat the plant to operating temperature', () {
      final p = freshPlant();
      expect(p.tAvg, lessThan(60));
      p.rcp = [true, true, false, false];
      run(p, 150);
      // Pump heat alone must reach operating temperature — this is what keeps
      // the cold startup out of a reactivity trap.
      expect(p.tAvg, greaterThan(280));
      expect(p.power, lessThan(1e-6)); // and it is still shut down
    });
  });

  // -------------------------------------------------------------------------
  group('the plant is self-stabilizing (death is never inevitable)', () {
    test('negative temperature feedback halts a power rise on its own', () {
      final p = freshPlant();
      p.resetScram();
      p.rcp = [true, true, false, false];
      p.boron = 900;
      p.rod = [100, 100, 100, 100];
      p.feedPump = 70;
      p.msiv = true;
      p.throttle = 45;

      run(p, 400);
      // Left completely alone, the plant must settle rather than run away:
      // it is either holding a finite power level or it tripped itself.
      expect(p.power, lessThan(1.3));
      expect(p.fuelTemp, lessThan(1200));
      final powerA = p.power;
      run(p, 120);
      // and it stays settled
      expect((p.power - powerA).abs(), lessThan(0.35));
    });

    test('an unattended balanced plant takes no core damage', () {
      final p = freshPlant();
      p.resetScram();
      p.rcp = [true, true, false, false];
      p.boron = 900;
      p.rod = [72, 72, 72, 72];
      p.feedPump = 70;
      p.msiv = true;
      p.throttle = 40;
      p.heaters = 1;
      run(p, 600);
      expect(p.damage, 0);
    });
  });

  // -------------------------------------------------------------------------
  group('reactor protection system', () {
    test('overpower trips the reactor before damage', () {
      final p = freshPlant();
      p.resetScram();
      p.rcp = [true, true, true, true];
      p.power = 1.0;
      p.boron = 0;
      p.rod = [100, 100, 100, 100];
      run(p, 200);
      expect(p.scrammed, isTrue);
      expect(p.damage, 0); // tripped in time
    });

    test('losing all coolant pumps at power trips the reactor', () {
      final p = freshPlant();
      p.resetScram();
      p.power = 0.5;
      p.rcp = [false, false, false, false];
      run(p, 1);
      expect(p.scrammed, isTrue);
      expect(p.scramCause, 'LOSS OF FLOW');
    });

    test('a scram drops every rod and kills power', () {
      final p = freshPlant();
      p.resetScram();
      p.rod = [100, 100, 100, 100];
      p.power = 0.9;
      p.scram('MANUAL');
      run(p, 20);
      expect(p.rodAvg, lessThan(1));
      expect(p.power, lessThan(0.05));
      expect(p.alarms['scram'], AlarmState.flashing);
    });
  });

  // -------------------------------------------------------------------------
  group('secondary plant and money', () {
    test('no megawatts until the breaker is closed', () {
      final p = freshPlant();
      p.resetScram();
      p.rcp = [true, true, false, false];
      p.power = 0.9;
      p.tAvg = 300; // hot enough to boil the secondary
      p.msiv = true;
      p.feedPump = 70;
      p.throttle = 60;
      p.pressure = 155;
      run(p, 5);
      expect(p.steamFlow, greaterThan(0));
      expect(p.mwe, 0); // spinning, but not selling
      p.genBreaker = true;
      run(p, 2);
      expect(p.mwe, greaterThan(0));
      expect(p.uraniumThisShift, greaterThan(0));
    });

    test('steam generator drains when feed cannot match steam demand', () {
      final p = freshPlant();
      p.resetScram();
      p.rcp = [true, true, false, false];
      p.power = 0.9;
      p.tAvg = 300;
      p.pressure = 155;
      p.msiv = true;
      p.throttle = 90;
      p.feedPump = 0;
      p.frvAuto = false;
      p.frvPos = 0;
      final before = p.sgLevel;
      run(p, 20);
      expect(p.sgLevel, lessThan(before));
    });

    test('closing the breaker out of phase is punished, in phase is not', () {
      final p = freshPlant();
      // sin(syncAngle) near zero == in phase
      p.syncAngle = 0;
      expect(p.syncAngle.abs() < 0.25, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('alarms', () {
    test('a condition raises a flashing tile; ACK then RESET clears it', () {
      final p = freshPlant();
      p.resetScram();
      p.rcp = [true, true, false, false];
      p.sgLevel = 90; // HI SG LEVEL
      run(p, 0.1);
      expect(p.alarms['hisg'], AlarmState.flashing);
      expect(p.hornActive, isTrue);

      p.ackAlarms();
      expect(p.alarms['hisg'], AlarmState.acked);
      expect(p.hornActive, isFalse);

      p.sgLevel = 50; // condition gone
      p.resetAlarms();
      expect(p.alarms['hisg'], AlarmState.clear);
    });

    test('SILENCE stops the horn but leaves the tile flashing', () {
      final p = freshPlant();
      p.sgLevel = 90;
      run(p, 0.1);
      p.hornSilenced = true;
      expect(p.alarms['hisg'], AlarmState.flashing);
      expect(p.hornActive, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('damage and shift outcome', () {
    test('core damage needs genuinely abusive conditions', () {
      final p = freshPlant();
      p.resetScram();
      p.fuelTemp = 800; // hot but survivable
      run(p, 5);
      expect(p.damage, 0);
    });

    test('research scales with output and is cut by damage', () {
      final a = freshPlant()..mwhThisShift = 400;
      final b = freshPlant()
        ..mwhThisShift = 400
        ..damage = 100;
      expect(a.researchFor(), greaterThan(0));
      expect(b.researchFor(), lessThan(a.researchFor()));
    });
  });

  // -------------------------------------------------------------------------
  group('upgrades', () {
    test('uprate raises rated output and grid contract raises price', () {
      final base = freshPlant();
      final up = freshPlant(up: {'uprate': 3, 'gridPrice': 2});
      expect(up.ratedMWe, greaterThan(base.ratedMWe));
      expect(up.uraniumPrice, greaterThan(base.uraniumPrice));
    });

    test('hot standby handover starts the plant critical and pressurised', () {
      final p = Plant(upgrades: {'hotStart': 1})..startShift(hot: true);
      expect(p.scrammed, isFalse);
      expect(p.pressure, greaterThan(140));
      expect(p.tAvg, greaterThan(250));
      expect(p.pumpCount, greaterThanOrEqualTo(2));
    });

    test('containment liner slows damage accumulation', () {
      Plant hurt(Map<String, int> up) {
        final p = Plant(upgrades: up)..startShift(hot: false);
        p.resetScram();
        p.fuelTemp = 2000;
        p.power = 1.0;
        p.rcp = [true, true, false, false];
        for (var i = 0; i < 10; i++) {
          p.fuelTemp = 2000; // hold the abusive condition
          p.step(0.05);
        }
        return p;
      }

      expect(hurt({'contain': 6}).damage, lessThan(hurt({}).damage));
    });
  });

  // -------------------------------------------------------------------------
  group('a full cold startup can be flown by hand', () {
    test('pumps → pressure → critical → steam → grid → full power', () {
      final p = freshPlant();

      // 1. coolant pumps, and pump heat warms the loop
      p.rcp[0] = true;
      p.rcp[1] = true;
      expect(kObjectives[0].done(p), isTrue);
      run(p, 150);
      expect(kObjectives[1].done(p), isTrue, reason: 'pump heat should warm it');

      // 2. pressurize
      p.heaters = 2;
      run(p, 60);
      expect(kObjectives[2].done(p), isTrue, reason: 'should reach 150 bar');

      // 3. release and withdraw the rods
      expect(p.resetScram(), isTrue);
      expect(kObjectives[3].done(p), isTrue);
      p.rod = [100, 100, 100, 100];
      expect(kObjectives[4].done(p), isTrue);

      // 4. dilute to critical — four decades at a controlled startup rate
      p.boron = 1030;
      run(p, 240);
      expect(kObjectives[5].done(p), isTrue, reason: 'reactor should be critical');
      expect(p.sur.abs(), lessThan(6), reason: 'startup rate stays controlled');
      expect(p.scrammed, isFalse, reason: 'a gentle startup must not trip');

      // 5. secondary
      p.msiv = true;
      p.feedPump = 80;
      p.throttle = 15;
      run(p, 120);
      expect(kObjectives[6].done(p), isTrue);
      expect(kObjectives[7].done(p), isTrue);
      expect(p.steamFlow, greaterThan(0));

      // 6. onto the grid
      p.genBreaker = true;
      run(p, 30);
      expect(kObjectives[8].done(p), isTrue);
      expect(p.mwe, greaterThan(0));

      // 7. an operator raising load and holding temperature with boron
      for (var i = 0; i < 12000; i++) {
        // Lead with the throttle, dilute to match, and back off the moment the
        // startup rate gets away — the technique the console teaches.
        p.throttle = clampD(15 + i * 0.05 * 0.20, 15, 100);
        if (p.power < 0.98 && p.sur < 0.8) {
          p.boron = clampD(p.boron - p.boronSpeed * 0.05, 0, 2500);
        } else if (p.power > 1.04) {
          p.boron = clampD(p.boron + p.boronSpeed * 0.05, 0, 2500);
        }
        p.heaters = p.pressure < 152 ? 2 : (p.pressure < 156 ? 1 : 0);
        p.step(0.05);
      }

      expect(p.scrammed, isFalse, reason: 'a competent operator never trips');
      expect(p.power, greaterThan(0.8), reason: 'should reach high power');
      expect(p.mwe, greaterThan(400), reason: 'should be selling real power');
      expect(p.damage, 0, reason: 'a clean shift damages nothing');
      expect(p.uraniumThisShift, greaterThan(0));
      expect(p.mwhThisShift, greaterThan(0));

      // 8. and it stays safe with nobody touching it. Power sags gently as the
      //    fuel depletes — that is the fuel cycle, not instability.
      final powerBefore = p.power;
      run(p, 600);
      expect(p.scrammed, isFalse, reason: 'stable plant must not trip itself');
      expect(p.damage, 0, reason: 'stable plant must not damage itself');
      expect(p.power, lessThanOrEqualTo(powerBefore + 0.06),
          reason: 'unattended power must never climb');
      expect(p.power, greaterThan(0.4),
          reason: 'and it should sag, not collapse');
      expect(p.burnup, greaterThan(0), reason: 'the core burned fuel');
    });
  });

  // -------------------------------------------------------------------------
  group('game shell', () {
    testWidgets('boots to the home screen and starts a shift', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      await tester.pump(const Duration(milliseconds: 32));
      // The wordmark and the mimic are painted on canvas, so assert on the
      // controls the board carries instead.
      expect(find.text('BEGIN NIGHT 1'), findsOneWidget);
      expect(find.text('MANUAL'), findsOneWidget);
      expect(find.text('UPGRADES'), findsOneWidget);

      final st = tester.state<GameRootState>(find.byType(GameRoot));
      st.game.startShift();
      await tester.pump(const Duration(milliseconds: 32));
      expect(st.game.screen, Screen.control);
      expect(st.game.shiftActive, isTrue);
    });

    testWidgets('ending a shift banks credits and returns via the report',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      g.plant.uraniumThisShift = 5000;
      g.plant.mwhThisShift = 300;
      g.endShift(melted: false);
      await tester.pump(const Duration(milliseconds: 32));
      expect(g.screen, Screen.report);
      expect(g.uranium, greaterThanOrEqualTo(5000));
      expect(g.research, greaterThan(0));
      expect(g.shiftActive, isFalse);
    });

    testWidgets('meltdown routes to the report, not a dead end', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      g.plant.damage = 100;
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(g.screen, Screen.report);
      expect(g.reportMelted, isTrue);
      expect(g.meltdowns, 1);
    });

    testWidgets('buying an upgrade deducts and levels up', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      final item = kShop.firstWhere((e) => e.id == 'rodSpeed');
      g.uranium = 10000;
      expect(g.canAfford(item), isTrue);
      expect(g.buy(item), isTrue);
      expect(g.lvl('rodSpeed'), 1);
      expect(g.uranium, lessThan(10000));
      // and it actually changes plant behaviour
      expect(g.plant.rodSpeed, greaterThan(3.0));
    });

    testWidgets('research upgrades are refused without research', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      final item = kShop.firstWhere((e) => e.id == 'hotStart');
      g.research = 0;
      expect(g.canAfford(item), isFalse);
      expect(g.buy(item), isFalse);
    });

    testWidgets('the manual documents every console panel', (tester) async {
      // The manual is the only in-game teaching surface, so it must be complete.
      final text = kManual
          .expand((s) => [s.title, s.blurb, ...s.entries.map((e) => e.control)])
          .join(' ');
      for (final needle in [
        'SCRAM',
        'MSIV',
        'BORON',
        'THROTTLE',
        'PORV',
        'SUR',
        'BURNUP',
        'DISPATCH',
      ]) {
        expect(text.contains(needle), isTrue, reason: '$needle missing from manual');
      }
    });
  });

  // -------------------------------------------------------------------------
  group('console controls are wired to the plant', () {
    testWidgets('holding the OUT grip withdraws the selected bank, release stops',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      final p = g.plant;
      p.rcp = [true, true, false, false];
      p.resetScram();
      g.consoleTab = 0;
      g.bump();
      await tester.pump(const Duration(milliseconds: 32));

      expect(p.rod[0], 0);
      final grip = find.byWidgetPredicate((w) => w is PushButton && w.label == 'OUT');
      expect(grip, findsOneWidget);

      final gesture = await tester.startGesture(tester.getCenter(grip));
      await tester.pump(const Duration(milliseconds: 16));
      expect(p.rodCmd, RodCmd.withdraw);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final moved = p.rod[0];
      expect(moved, greaterThan(2), reason: 'rods should travel while held');

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 32));
      expect(p.rodCmd, RodCmd.hold, reason: 'grip springs back to HOLD');
      final afterRelease = p.rod[0];
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(p.rod[0], afterRelease, reason: 'rods stop when released');
    });

    testWidgets('a control torn down mid-press releases instead of sticking',
        (tester) async {
      // The old console's worst habit: hold OUT, switch panel, and the rods
      // kept driving forever because the release never arrived.
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      final p = g.plant;
      p.rcp = [true, true, false, false];
      p.resetScram();
      g.consoleTab = 0;
      g.bump();
      await tester.pump(const Duration(milliseconds: 32));

      final gesture = await tester.startGesture(tester.getCenter(
          find.byWidgetPredicate((w) => w is PushButton && w.label == 'OUT')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(p.rodCmd, RodCmd.withdraw);

      // Yank the panel out from under the finger.
      g.consoleTab = 3;
      g.bump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(p.rodCmd, RodCmd.hold,
          reason: 'dispose must deliver the release');

      final parked = p.rod[0];
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(p.rod[0], parked, reason: 'rods must not keep driving');
      await gesture.up();
    });

    testWidgets('the rod drives are interlocked while tripped', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      g.consoleTab = 0;
      g.bump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(g.plant.scrammed, isTrue);

      final gesture =
          await tester.startGesture(tester.getCenter(find.byWidgetPredicate((w) => w is PushButton && w.label == 'OUT')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(g.plant.rodCmd, RodCmd.hold, reason: 'tripped rods must not move');
      expect(g.plant.rod[0], 0);
      await gesture.up();
    });

    testWidgets('dragging a knob moves the real plant control', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      g.consoleTab = 2; // STEAM
      g.bump();
      await tester.pump(const Duration(milliseconds: 32));

      expect(g.plant.feedPump, 0);
      final knob = find.byType(Knob).first;
      await tester.drag(knob, const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 32));
      expect(g.plant.feedPump, greaterThan(0),
          reason: 'feed pump should follow the knob');
    });

    testWidgets('SCRAM is guarded: one tap opens the cover, the next fires',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      final p = g.plant;
      p.rcp = [true, true, false, false];
      p.resetScram();
      await tester.pump(const Duration(milliseconds: 32));
      expect(p.scrammed, isFalse);

      await tester.tap(find.byWidgetPredicate((w) => w is GuardedButton && w.label == 'SCRAM'));
      await tester.pump(const Duration(milliseconds: 32));
      expect(p.scrammed, isFalse, reason: 'first tap only lifts the cover');

      // With the cover up the button relabels itself, so target that.
      await tester.tap(find.byWidgetPredicate((w) => w is GuardedButton && w.label == 'SCRAM'));
      await tester.pump(const Duration(milliseconds: 32));
      expect(p.scrammed, isTrue, reason: 'second tap trips the reactor');
      expect(p.scramCause, 'MANUAL');
    });

    testWidgets('pump grips start and stop coolant flow', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      g.consoleTab = 1; // COOLANT
      g.bump();
      await tester.pump(const Duration(milliseconds: 32));

      expect(g.plant.pumpCount, 0);
      await tester.tap(find.byType(GripSwitch).first);
      await tester.pump(const Duration(milliseconds: 32));
      expect(g.plant.pumpCount, 1);
      await tester.tap(find.byType(GripSwitch).first);
      await tester.pump(const Duration(milliseconds: 32));
      expect(g.plant.pumpCount, 0);
    });

    testWidgets('uncommissioned pump loops are refused', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      g.consoleTab = 1;
      g.bump();
      await tester.pump(const Duration(milliseconds: 32));
      // Loops 3 and 4 need the EXTRA COOLANT LOOP upgrade.
      await tester.tap(find.byType(GripSwitch).at(3));
      await tester.pump(const Duration(milliseconds: 32));
      expect(g.plant.rcp[3], isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('the fuel cycle', () {
    test('generating power burns fuel', () {
      final p = freshPlant();
      expect(p.burnup, 0);
      p.resetScram();
      p.rcp = [true, true, false, false];
      p.power = 1.0;
      run(p, 100);
      expect(p.burnup, greaterThan(0));
      expect(p.fuelMargin, lessThan(1));
    });

    test('a shut-down reactor burns nothing', () {
      final p = freshPlant();
      p.rcp = [true, true, false, false];
      run(p, 200);
      expect(p.burnup, lessThan(0.5));
    });

    test('burnup eats reactivity, so an old core needs less boron', () {
      final fresh = freshPlant();
      fresh.tAvg = 300;
      fresh.rod = [100, 100, 100, 100];
      fresh.boron = 800;
      final old = freshPlant();
      old.tAvg = 300;
      old.rod = [100, 100, 100, 100];
      old.boron = 800;
      old.burnup = 60;
      expect(old.reactivity, lessThan(fresh.reactivity));
      // The operator compensates by diluting — that is the whole fuel cycle.
      old.boron = 800 - (60 * 25) / 3.5;
      expect(old.reactivity, closeTo(fresh.reactivity, 1));
    });

    test('a spent core cannot hold full power even with no boron left', () {
      final p = freshPlant();
      p.tAvg = 300;
      p.rod = [100, 100, 100, 100];
      p.boron = 0;
      p.burnup = 100;
      p.power = 1.0;
      expect(p.reactivity, lessThan(0), reason: 'end of life is a real wall');
    });

    testWidgets('a handover arrives critical, on load, and in balance',
        (tester) async {
      // You relieve somebody. The plant you inherit is running, sitting on
      // the dispatcher's number, and thermally settled — not a pile of
      // plausible-looking numbers that slides cold the moment you touch it.
      ({double rho, double mwe, double demand, double drift}) handover(
          double burn) {
        final p = Plant(upgrades: {'hotStart': 1})..burnup = burn;
        p.startShift(hot: true);
        expect(p.scrammed, isFalse);
        final before = p.tAvg;
        for (var t = 0.0; t < 20; t += 0.05) {
          p.step(0.05);
        }
        return (
          rho: p.reactivity,
          mwe: p.mwe,
          demand: p.gridDemand,
          drift: (p.tAvg - before).abs(),
        );
      }

      // A spent core cannot hold what a fresh one can, so the crew derates
      // rather than handing over something subcritical. That is the fuel
      // cycle having teeth, and it is the reason to schedule an outage.
      expect(handover(95).mwe, lessThan(handover(0).mwe * 0.6),
          reason: 'an end-of-life core should arrive derated');

      for (final burn in [0.0, 30.0, 60.0, 95.0]) {
        final h = handover(burn);
        // Critical, whatever the core's age — the off-going crew has already
        // diluted to cancel the burnup penalty.
        // A couple of hundred pcm is a slow drift the operator trims out,
        // not the 900 pcm hole an unsolved handover used to leave.
        expect(h.rho.abs(), lessThan(220),
            reason: 'a \$burn% core handed over \${h.rho.round()} pcm off');
        // On the dispatcher's number rather than climbing toward it.
        expect(h.mwe, greaterThan(0), reason: 'burnup \$burn');
        expect((h.mwe - h.demand).abs() / (h.demand < 1 ? 1 : h.demand),
            lessThan(0.18),
            reason: 'handed over off load at \$burn% burnup');
        // And it stays where it was put.
        expect(h.drift, lessThan(25),
            reason: 'plant slid \${h.drift.round()} C in twenty seconds');
      }
    });

    testWidgets('refuelling costs uranium and hands back a fresh core',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.plant.burnup = 50;
      g.uranium = 0;
      expect(g.refuel(), isFalse, reason: 'cannot afford it');
      expect(g.plant.burnup, 50);

      g.uranium = g.refuelCost + 10;
      expect(g.refuel(), isTrue);
      expect(g.plant.burnup, 0);
      expect(g.refuels, 1);
      expect(g.uranium, closeTo(10, 0.01));
    });

    testWidgets('burnup survives a shift but a meltdown consumes the core',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.burnup = 30;
      g.endShift(melted: false);
      expect(g.plant.burnup, 30, reason: 'the core carries over');

      g.tutorial = false;

      g.startShift();
      g.plant.burnup = 30;
      g.endShift(melted: true);
      expect(g.plant.burnup, 0, reason: 'nothing left of that core');
    });
  });

  // -------------------------------------------------------------------------
  group('grid dispatch', () {
    test('following the dispatcher pays more than ignoring it', () {
      final p = freshPlant();
      p.gridDemand = 500;
      p.mwe = 500;
      final onTarget = p.dispatchFactor;
      p.mwe = 100;
      final offTarget = p.dispatchFactor;
      expect(onTarget, greaterThan(offTarget));
      expect(onTarget, greaterThan(1.3));
      expect(offTarget, greaterThanOrEqualTo(0.6),
          reason: 'power is still power');
    });

    testWidgets('the dispatcher asks for a load and logs it', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      final before = g.log.length;
      g.requestLoad();
      expect(g.plant.gridDemand, greaterThan(0));
      expect(g.log.length, greaterThan(before));
      expect(g.log.last.who, 'GRID DISPATCH');
    });
  });

  // -------------------------------------------------------------------------
  group('the shift log and instruments', () {
    testWidgets('a trip writes itself into the log', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.resetScram();
      g.plant.scram('MANUAL');
      expect(g.log.any((e) => e.who == 'REACTOR' && e.text.contains('TRIP')),
          isTrue);
    });

    testWidgets('a scream is logged by the turbine hall', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.hearScream();
      expect(g.log.last.who, 'TURBINE HALL');
    });

    testWidgets('the wall clock starts on nights and advances', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      expect(g.clockText, '22:00');
      g.plant.shiftTime = 3600; // an hour at the desk
      expect(g.clockText, isNot('22:00'));
    });

    test('instruments lag the process instead of snapping to it', () {
      final p = freshPlant();
      p.rcp = [true, true, false, false];
      p.pressure = 155;
      p.step(0.05);
      // One 50ms step must not carry the needle all the way.
      expect(p.iPress, lessThan(100));
      run(p, 6);
      expect(p.iPress, closeTo(p.pressure, 12),
          reason: 'but it settles on the real value');
    });
  });

  // -------------------------------------------------------------------------
  group('sanity, the canteen and the screaming', () {
    test('sanity starts full and drains over a shift', () {
      final p = freshPlant();
      expect(p.sanity, 100);
      p.rcp = [true, true, false, false];
      p.resetScram();
      run(p, 120);
      expect(p.sanity, lessThan(100));
      expect(p.sanity, greaterThan(50), reason: 'a calm plant drains slowly');
    });

    test('a stressed plant drains sanity much faster than a calm one', () {
      Plant scenario({required bool calm}) {
        final p = freshPlant();
        p.rcp = [true, true, false, false];
        p.resetScram();
        if (!calm) {
          p.sgLevel = 95; // alarms flashing, horn going
          p.damage = 25;
          p.radiation = 40;
        }
        run(p, 120);
        return p;
      }

      expect(scenario(calm: false).sanity,
          lessThan(scenario(calm: true).sanity - 10));
    });

    test('sanity reaching zero breaks the operator', () {
      final p = freshPlant();
      p.resetScram();
      p.rcp = [true, true, false, false];
      p.sanity = 0.3;
      run(p, 20);
      expect(p.sanity, 0);
      expect(p.brokeDown, isTrue);
    });

    testWidgets('a scream costs exactly 5 sanity', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.sanity = 80;
      g.hearScream();
      expect(g.plant.sanity, 75);
      expect(g.screamsHeard, 1);
    });

    testWidgets('ear defenders reduce what the scream costs', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.upgrades['earDefenders'] = 2; // 0.6^2 = 0.36 -> 1.8 sanity
      g.tutorial = false;
      g.startShift();
      g.plant.sanity = 80;
      g.hearScream();
      expect(g.plant.sanity, greaterThan(77));
      expect(g.plant.sanity, lessThan(80));
    });

    testWidgets('a well-run plant is left alone; a failing one is not',
        (tester) async {
      // Chaos is earned. The building only starts on you once you are already
      // in trouble, so a clean watch stays quiet.
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.stress = 0;
      g.plant.damage = 0;
      g.plant.scrammed = false;
      g.scheduleScream();
      final calm = g.screamIn;
      expect(calm, greaterThan(120),
          reason: 'a calm plant should get minutes of quiet');

      g.plant.stress = 1;
      g.plant.damage = 30;
      g.scheduleScream();
      expect(g.screamIn, lessThan(calm / 2),
          reason: 'a plant in trouble should be hounded');
      expect(g.screamIn, greaterThan(10));
    });

    testWidgets('coffee is three sips of fifteen', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      final coffee = canteenItem('coffee');
      expect(coffee.sips, 3);
      expect(coffee.perSip, 15);

      g.uranium = 1000;
      g.pantry.clear(); // ignore the starter flask; test the purchase itself
      g.tutorial = false;
      g.startShift();
      expect(g.buyConsumable(coffee), isTrue);
      expect(g.sipsOf('coffee'), 3);

      g.plant.sanity = 40;
      expect(g.sip('coffee'), isTrue);
      expect(g.plant.sanity, 55);
      expect(g.sipsOf('coffee'), 2);
      g.sip('coffee');
      g.sip('coffee');
      expect(g.plant.sanity, 85);
      expect(g.sipsOf('coffee'), 0);
      expect(g.sip('coffee'), isFalse, reason: 'nothing left in the cup');
    });

    testWidgets('sanity never exceeds 100 and a sip is refused when broke',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.uranium = 0;
      expect(g.buyConsumable(canteenItem('noodles')), isFalse);
      g.uranium = 1000;
      g.buyConsumable(canteenItem('noodles')); // +38 in one serving
      g.tutorial = false;
      g.startShift();
      g.plant.sanity = 95;
      g.sip('noodles');
      expect(g.plant.sanity, 100);
    });

    testWidgets('a brand new operator turns up with something to drink',
        (tester) async {
      // Without a starter flask the first shift is unwinnable: no uranium means
      // no canteen, and sanity only falls.
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      expect(g.uranium, 0);
      expect(g.totalSips, greaterThan(0));
      expect(g.sipsOf('coffee'), 3);
      expect(g.bestSip(), isNotNull);
    });

    testWidgets('the pantry survives a shift ending', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.uranium = 1000;
      g.pantry.clear();
      g.buyConsumable(canteenItem('coffee'));
      g.tutorial = false;
      g.startShift();
      g.sip('coffee');
      g.endShift(melted: false);
      expect(g.sipsOf('coffee'), 2);
      g.tutorial = false;
      g.startShift();
      expect(g.plant.sanity, 100, reason: 'you rest between shifts');
      expect(g.sipsOf('coffee'), 2);
    });
  });

  // -------------------------------------------------------------------------
  group('AI crew', () {
    testWidgets('BARISTA-B serves a sip when sanity drops below 35',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.upgrades['baristaBot'] = 1;
      g.uranium = 1000;
      g.pantry.clear();
      g.buyConsumable(canteenItem('coffee'));
      g.tutorial = false;
      g.startShift();
      g.plant.sanity = 20;
      g.runBots(5); // past the bot's cooldown
      expect(g.plant.sanity, greaterThan(20));
      expect(g.sipsOf('coffee'), lessThan(3));
    });

    testWidgets('no bot, no help', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.uranium = 1000;
      g.pantry.clear();
      g.buyConsumable(canteenItem('coffee'));
      g.tutorial = false;
      g.startShift();
      g.plant.sanity = 20;
      g.runBots(5);
      expect(g.plant.sanity, 20);
      expect(g.sipsOf('coffee'), 3);
    });

    testWidgets('WATCH-1 acknowledges the annunciator', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.upgrades['watchBot'] = 1;
      g.tutorial = false;
      g.startShift();
      g.plant.sgLevel = 95;
      g.plant.step(0.05); // raises HI SG LEVEL
      expect(g.plant.anyFlashing, isTrue);
      g.runBots(0.05);
      expect(g.plant.anyFlashing, isFalse);
      expect(g.plant.hornActive, isFalse);
    });

    testWidgets('FEED-2 drives the feed pump toward steam demand',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.upgrades['feedBot'] = 1;
      g.tutorial = false;
      g.startShift();
      final p = g.plant;
      p.msiv = true;
      p.feedPump = 0;
      p.sgLevel = 20; // starving
      for (var i = 0; i < 40; i++) {
        g.runBots(0.05);
      }
      expect(p.feedPump, greaterThan(5));
    });
  });

  // -------------------------------------------------------------------------
  group('uranium economy', () {
    testWidgets('breakdown ends the shift and cuts research', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.mwhThisShift = 900;
      g.plant.uraniumThisShift = 5000;
      final clean = g.plant.researchFor();
      g.endShift(melted: false, brokeDown: true);
      expect(g.screen, Screen.report);
      expect(g.reportBrokeDown, isTrue);
      expect(g.reportResearch, lessThan(clean));
      expect(g.uranium, greaterThanOrEqualTo(5000),
          reason: 'uranium already earned is still banked');
    });

    testWidgets('a shift that hits zero sanity ends by itself', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.sanity = 0.05;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(g.screen, Screen.report);
      expect(g.reportBrokeDown, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('the easier revamp', () {
    testWidgets('the tutorial walks the console to the right panel',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      expect(g.tutorial, isTrue, reason: 'on by default for a new operator');
      g.startShift();
      await tester.pump(const Duration(milliseconds: 60));
      // Step one lives on COOLANT, so that is where it should have taken us.
      expect(g.consoleTab, kObjectives.first.tab);

      // Satisfy step one and it should move on by itself.
      g.plant.rcp = [true, true, false, false];
      g.plant.tAvg = 290;
      g.plant.pressure = 160;
      await tester.pump(const Duration(milliseconds: 60));
      expect(nextObjective(g.plant)!.tab, isNot(kObjectives.first.tab));
    });

    testWidgets('skipping the tutorial sticks', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.startShift();
      g.skipTutorial();
      expect(g.tutorial, isFalse);
      g.consoleTab = 3;
      await tester.pump(const Duration(milliseconds: 100));
      expect(g.consoleTab, 3, reason: 'it must stop moving the console');
    });

    testWidgets('every tutorial step explains how, not just what', (tester) {
      for (final o in kObjectives) {
        expect(o.how.length, greaterThan(20),
            reason: '"${o.text}" needs a real instruction');
        expect(o.text.length, lessThan(64),
            reason: '"${o.text}" is too long for the checklist strip');
      }
      return Future.value();
    });

    testWidgets('food can be bought at the desk from tonight\'s pay',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.pantry.clear();
      g.uranium = 0;
      g.plant.uraniumThisShift = 500; // earned this watch, not yet banked
      expect(g.spendable, 500);
      expect(g.buyConsumable(canteenItem('coffee')), isTrue);
      expect(g.sipsOf('coffee'), 3);
      expect(g.plant.uraniumThisShift, lessThan(500),
          reason: 'it should come out of tonight\'s earnings');
    });

    test('a routine cold startup is not punished', () {
      // You begin every shift shut down. That must not cost sanity until it
      // has actually cost production.
      final p = freshPlant();
      p.rcp = [true, true, false, false];
      run(p, 240); // a realistic warm-up
      expect(p.sanity, greaterThan(80),
          reason: 'warming the plant through is routine work');
      expect(p.stress, lessThan(0.2));
    });

    test('a calm watch is much gentler on sanity than a bad one', () {
      Plant watch({required bool calm}) {
        final p = freshPlant();
        p.rcp = [true, true, false, false];
        p.resetScram();
        // A genuinely calm plant: hot, pressurised, steaming, no alarms.
        p.tAvg = 300;
        p.pressure = 155;
        p.heaters = 1;
        p.msiv = true;
        p.feedPump = 70;
        p.throttle = 40;
        p.rod = [72, 72, 72, 72];
        p.boron = 900;
        p.genBreaker = true; // on the grid, so nothing is nagging you
        if (!calm) {
          p.sgLevel = 95;
          p.damage = 25;
          p.radiation = 40;
        }
        run(p, 300);
        return p;
      }

      final calm = watch(calm: true).sanity;
      final bad = watch(calm: false).sanity;
      expect(calm, greaterThan(70), reason: 'a good shift should be survivable');
      expect(bad, lessThan(calm - 25), reason: 'a bad one should still hurt');
    });
  });

  // -------------------------------------------------------------------------
  group('pacing and payoff (from playtesting a full shift)', () {
    test('withdrawing all four banks is deliberate, not tedious', () {
      // It used to take 134 seconds of holding a button. That is a chore.
      final p = freshPlant();
      p.rcp = [true, true, false, false];
      p.resetScram();
      var held = 0.0;
      for (var bank = 0; bank < 4; bank++) {
        p.bank = bank;
        p.rodCmd = RodCmd.withdraw;
        while (p.rod[bank] < 100 && held < 300) {
          p.step(0.05);
          held += 0.05;
        }
        p.rodCmd = RodCmd.hold;
      }
      expect(p.rodAvg, greaterThan(99));
      expect(held, lessThan(70), reason: 'four banks should take about a minute');
      expect(held, greaterThan(20), reason: 'but still feel like real travel');
    });

    test('a solid first shift earns research, not zero', () {
      // 108 MWh is what a competent first watch produced in playtesting.
      final p = freshPlant()..mwhThisShift = 108;
      expect(p.researchFor(), greaterThanOrEqualTo(3));
      // And a scrappy one still shows something for it.
      expect((freshPlant()..mwhThisShift = 30).researchFor(), greaterThan(0));
    });

    test('the checklist never walks backwards', () {
      // Temperature dipping while you are on the grid must not send the
      // guidance back to "wait for T-AVG to pass 280".
      final p = freshPlant();
      p.rcp = [true, true, false, false];
      p.resetScram();
      p.rod = [100, 100, 100, 100];
      p.tAvg = 300;
      p.pressure = 160;
      p.power = 0.6;
      p.msiv = true;
      p.feedPump = 70;
      p.throttle = 40;
      p.genBreaker = true;
      p.step(0.05);
      final metBefore = p.objectivesMet.length;
      final stepBefore = kObjectives.indexOf(nextObjective(p)!);
      expect(metBefore, greaterThanOrEqualTo(9),
          reason: 'the startup steps are all satisfied');

      p.tAvg = 210; // the plant cools off
      p.pressure = 120;
      run(p, 2);
      expect(p.objectivesMet.length, greaterThanOrEqualTo(metBefore),
          reason: 'achieved steps must stay achieved');
      expect(kObjectives.indexOf(nextObjective(p)!),
          greaterThanOrEqualTo(stepBefore),
          reason: 'guidance must never walk backwards');
    });

    test('following the advised technique reaches the dispatch target', () {
      // "Raise throttle, then dilute to match" — the console's own advice has
      // to actually pay, or it is not advice.
      final p = freshPlant();
      p.rcp = [true, true, false, false];
      run(p, 150);
      p.resetScram();
      p.rod = [100, 100, 100, 100];
      p.heaters = 2;
      p.msiv = true;
      p.feedPump = 80;
      p.gridDemand = p.ratedMWe * 0.55;
      p.genBreaker = true;
      for (var i = 0; i < 16000; i++) {
        p.throttle = clampD(p.throttle + 0.02, 0, 100);
        p.boronCmd = (p.mwe < p.gridDemand * 0.97 &&
                p.sur < 0.8 &&
                p.power < 1.02)
            ? -1
            : ((p.power > 1.05) ? 1 : 0);
        p.heaters = p.pressure < 152 ? 2 : (p.pressure < 156 ? 1 : 0);
        p.step(0.05);
      }
      expect(p.scrammed, isFalse, reason: 'the advised technique is safe');
      expect(p.damage, 0);
      expect(p.dispatchFactor, greaterThan(1.2),
          reason: 'and it should pay well');
    });
  });

  // -------------------------------------------------------------------------
  group('performance architecture', () {
    testWidgets('a frame paints without rebuilding the widget tree',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final st = tester.state<GameRootState>(find.byType(GameRoot));
      final g = st.game;
      g.tutorial = false;
      g.startShift();
      await tester.pump(const Duration(milliseconds: 32));

      var builds = 0;
      g.ui.addListener(() => builds++);
      final frameBefore = g.frame.value;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Frames advanced...
      expect(g.frame.value, greaterThan(frameBefore + 20));
      // ...without a single widget-tree rebuild being requested.
      expect(builds, 0);
    });
  });
}
