// Persistence suite.
//
// The save has to survive the app being closed at any moment — on a phone the
// OS kills a backgrounded app without warning, usually mid-shift.
@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meltdown_reactor/main.dart';

/// Tear the app down and build a fresh one, exactly as relaunching would.
Future<Game> relaunch(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pumpWidget(const ReactorApp());
  await tester.pump(const Duration(milliseconds: 20));
  return tester.state<GameRootState>(find.byType(GameRoot)).game;
}

void main() {
  setUp(rawWipe);

  group('progress survives a relaunch', () {
    testWidgets('currencies, upgrades, pantry and core all come back',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      var g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.uranium = 12345.5;
      g.research = 9;
      g.upgrades['rodSpeed'] = 4;
      g.upgrades['baristaBot'] = 1;
      g.pantry['coffee'] = 2;
      g.plant.burnup = 61.25;
      g.refuels = 3;
      g.lifetimeMwh = 4321;
      g.bestShiftMwh = 999;
      g.shifts = 7;
      g.trips = 4;
      g.meltdowns = 1;
      g.sfx.muted = true;
      g.tutorial = false;
      g.save();

      g = await relaunch(tester);
      expect(g.uranium, closeTo(12345.5, 0.01));
      expect(g.research, 9);
      expect(g.lvl('rodSpeed'), 4);
      expect(g.lvl('baristaBot'), 1);
      expect(g.sipsOf('coffee'), 2);
      expect(g.plant.burnup, closeTo(61.25, 0.01));
      expect(g.refuels, 3);
      expect(g.lifetimeMwh, 4321);
      expect(g.bestShiftMwh, 999);
      expect(g.shifts, 7);
      expect(g.trips, 4);
      expect(g.meltdowns, 1);
      expect(g.sfx.muted, isTrue);
      expect(g.tutorial, isFalse);
    });
  });

  group('a shift in progress survives being killed', () {
    testWidgets('the whole watch comes back, not just the banked total',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      var g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.uranium = 1000;
      g.startShift();

      // Fly it somewhere specific.
      final p = g.plant;
      p.rcp = [true, true, false, false];
      p.resetScram();
      p.rod = [100, 96, 92, 88];
      p.boron = 742.5;
      p.tAvg = 301.5;
      p.fuelTemp = 655;
      p.pressure = 154.5;
      p.power = 0.87;
      p.msiv = true;
      p.feedPump = 71;
      p.throttle = 63;
      p.genBreaker = true;
      p.sgLevel = 49.5;
      p.sanity = 62.5;
      p.burnup = 33.5;
      p.uraniumThisShift = 4200; // earned tonight, NOT yet banked
      p.mwhThisShift = 512;
      p.shiftTime = 930;
      p.gridDemand = 810;
      g.save();

      g = await relaunch(tester);
      expect(g.shiftActive, isTrue, reason: 'the watch should still be on');
      expect(g.screen, Screen.control, reason: 'and you should be at the desk');

      final q = g.plant;
      expect(q.uraniumThisShift, closeTo(4200, 0.01),
          reason: "tonight's pay must not vanish");
      expect(q.mwhThisShift, closeTo(512, 0.01));
      expect(q.scrammed, isFalse);
      expect(q.rod, [100, 96, 92, 88]);
      expect(q.boron, closeTo(742.5, 0.01));
      expect(q.tAvg, closeTo(301.5, 0.01));
      expect(q.pressure, closeTo(154.5, 0.01));
      expect(q.power, closeTo(0.87, 0.001));
      expect(q.rcp, [true, true, false, false]);
      expect(q.msiv, isTrue);
      expect(q.genBreaker, isTrue);
      expect(q.feedPump, closeTo(71, 0.01));
      expect(q.throttle, closeTo(63, 0.01));
      expect(q.sanity, closeTo(62.5, 0.01));
      expect(q.burnup, closeTo(33.5, 0.01));
      expect(q.shiftTime, closeTo(930, 0.01));
      expect(q.gridDemand, closeTo(810, 0.01));
    });

    testWidgets('a resumed shift can still be ended and banked',
        (tester) async {
      await tester.pumpWidget(const ReactorApp());
      var g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.uraniumThisShift = 2500;
      g.plant.mwhThisShift = 300;
      g.save();

      g = await relaunch(tester);
      final before = g.uranium;
      g.endShift(melted: false);
      expect(g.uranium, closeTo(before + 2500, 0.01));
      expect(g.shiftActive, isFalse);
    });

    testWidgets('ending a shift clears the stored watch', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      var g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.startShift();
      g.plant.uraniumThisShift = 100;
      g.endShift(melted: false);

      g = await relaunch(tester);
      expect(g.shiftActive, isFalse);
      expect(g.screen, Screen.home,
          reason: 'a finished shift must not reopen the control room');
    });
  });

  group('the save cannot brick the game', () {
    testWidgets('garbage in storage falls back to a fresh start',
        (tester) async {
      rawSave('this is not json at all {{{');
      final g = await relaunch(tester);
      expect(g.uranium, 0);
      expect(g.shiftActive, isFalse);
      expect(g.totalSips, greaterThan(0), reason: 'still gets a starter kit');
    });

    testWidgets('a save with wrong types is survived field by field',
        (tester) async {
      rawSave('{"v":3,"ur":"lots","rs":null,"up":"broken","pan":42,'
          '"sh":true,"bu":"x"}');
      final g = await relaunch(tester);
      expect(g.uranium, 0);
      expect(g.research, 0);
      expect(g.shifts, 0);
      expect(g.plant.burnup, 0);
      expect(g.upgrades, isEmpty);
    });

    testWidgets('a save from an older version still loads', (tester) async {
      // v2 had no shift state at all. It must still restore progress.
      rawSave('{"v":2,"ur":5000,"rs":4,"up":{"rodSpeed":2},'
          '"pan":{"coffee":1},"bu":20,"sh":3,"mwh":100}');
      final g = await relaunch(tester);
      expect(g.uranium, 5000);
      expect(g.research, 4);
      expect(g.lvl('rodSpeed'), 2);
      expect(g.sipsOf('coffee'), 1);
      expect(g.plant.burnup, 20);
      expect(g.shifts, 3);
      expect(g.shiftActive, isFalse);
    });

    testWidgets('infinities and NaN never reach storage', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      var g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.uranium = double.infinity;
      g.lifetimeMwh = double.nan;
      g.save();
      g = await relaunch(tester);
      expect(g.uranium.isFinite, isTrue);
      expect(g.lifetimeMwh.isFinite, isTrue);
    });
  });
}
