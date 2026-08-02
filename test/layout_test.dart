// Layout regression suite.
//
// Renders every screen and every console panel at every iPhone size and fails
// on ANY Flutter layout overflow. This is the objective check for "things
// overlap" — eyeballing screenshots misses cases.
@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meltdown_reactor/main.dart';

/// Logical sizes this ships on. The SE is where things break first.
const devices = <String, Size>{
  'SE1 320x568': Size(320, 568),
  'SE3 375x667': Size(375, 667),
  'mini 375x812': Size(375, 812),
  'i15 393x852': Size(393, 852),
  'max 430x932': Size(430, 932),
};

/// Pump a few frames, then surface any layout error the framework recorded.
Future<void> check(WidgetTester tester, String where) async {
  final errs = <String>[];
  // Take the exception after every single pump: the framework merges several
  // into one opaque "Multiple exceptions" wrapper otherwise.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 40));
    final e = tester.takeException();
    if (e != null) {
      final m = e.toString().replaceAll('\n', ' ');
      errs.add(m.substring(0, m.length > 150 ? 150 : m.length));
    }
  }
  if (errs.isEmpty) return;
  // Print each one: the framework collapses several into an opaque
  // "Multiple exceptions" wrapper, which hides what actually overflowed.
  for (final e in errs) {
    // ignore: avoid_print
    print('OVERFLOW@ $where :: $e');
  }
  fail('$where overflowed — see OVERFLOW@ lines above');
}

Future<void> withSize(WidgetTester tester, Size size, Future<void> Function() body) async {
  await tester.binding.setSurfaceSize(size);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  try {
    await body();
  } finally {
    await tester.binding.setSurfaceSize(null);
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  }
}

/// Put the plant in the busiest possible state: at power, damaged, every
/// safety system engaged and every annunciator tile lit.
void stressPlant(Game g) {
  final p = g.plant;
  p.rcp = [true, true, true, true];
  p.resetScram();
  p.rod = [100, 100, 100, 100];
  p.boron = 850;
  p.tAvg = 305;
  p.fuelTemp = 880;
  p.pressure = 158;
  p.power = 1.02;
  p.msiv = true;
  p.feedPump = 88;
  p.throttle = 96;
  p.genBreaker = true;
  p.sgLevel = 52;
  p.damage = 12.5;
  p.radiation = 33;
  p.si = true;
  p.contIso = true;
  p.contSpray = true;
  p.afw = true;
  p.edg = true;
  p.porv = true;
  p.lampTest = true;
}

void main() {
  setUp(rawWipe);

  for (final entry in devices.entries) {
    testWidgets('${entry.key} — menus do not overflow', (tester) async {
      await withSize(tester, entry.value, () async {
        await tester.pumpWidget(const ReactorApp());
        final g = tester.state<GameRootState>(find.byType(GameRoot)).game;

        // Numbers long enough to stress every row.
        g.uranium = 987654321;
        g.research = 128;
        g.lifetimeMwh = 1234567;
        g.bestShiftMwh = 98765;
        g.shifts = 1234;
        g.trips = 567;
        g.meltdowns = 89;
        g.offlineGain = 45678;
        g.offlineAway = 86400 * 3;
        g.bump();
        await check(tester, '${entry.key} HOME');

        g.screen = Screen.shop;
        for (var tab = 0; tab < 4; tab++) {
          g.shopTab = tab;
          g.bump();
          await check(tester, '${entry.key} SHOP tab $tab');
        }

        g.screen = Screen.manual;
        g.bump();
        await check(tester, '${entry.key} MANUAL');

        g.reportUranium = 123456;
        g.reportMwh = 7890;
        g.reportResearch = 42;
        g.reportTime = 3725;
        g.reportIncidents = 3;
        g.reportHandled = 2;
        g.reportDamage = 18.5;
        g.reportSanity = 41;
        // Every stamp variant, because each one is a different width and the
        // grade note underneath changes with it.
        for (final outcome in ['complete', 'melted', 'walked']) {
          g.reportMelted = outcome == 'melted';
          g.reportBrokeDown = outcome == 'walked';
          g.bump();
          g.screen = Screen.report;
          await check(tester, '${entry.key} REPORT $outcome');
        }
      });
    });

    testWidgets('${entry.key} — control room does not overflow', (tester) async {
      await withSize(tester, entry.value, () async {
        await tester.pumpWidget(const ReactorApp());
        final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
        // Everything unlocked: the widest possible panels.
        g.upgrades.addAll({
          'rcpLoop': 2,
          'autoRod': 1,
          'autoPzr': 1,
          'autoTurb': 1,
          'feedBot': 1,
          'watchBot': 1,
          'baristaBot': 1,
          'earDefenders': 3,
        });
        for (final c in kCanteen) {
          g.pantry[c.id] = c.sips * 2; // CREW panel at its most crowded
        }
        g.tutorial = false;
        g.startShift();
        stressPlant(g);
        for (var tab = 0; tab < 6; tab++) {
          g.consoleTab = tab;
          g.bump();
          await check(tester, '${entry.key} PANEL $tab');
        }

        // A malfunction opens the strip up to two lines plus a progress bar.
        // Every hint is a different length, so every one gets rendered.
        for (final f in kFaults) {
          g.plant.abandonFault();
          g.plant.startFault(f);
          g.plant.faultHold = f.holdFor * 0.5;
          g.bump();
          await check(tester, '${entry.key} FAULT ${f.id}');
        }
        g.plant.abandonFault();
      });
    });
  }

  testWidgets('no control group is wider than the console', (tester) async {
    await withSize(tester, const Size(320, 568), () async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.upgrades.addAll({
        'rcpLoop': 2,
        'autoRod': 1,
        'autoPzr': 1,
        'autoTurb': 1,
        'feedBot': 1,
        'watchBot': 1,
        'baristaBot': 1,
      });
      for (final c in kCanteen) {
        g.pantry[c.id] = c.sips * 2;
      }
      g.tutorial = false;
      g.startShift();
      stressPlant(g);

      for (var tab = 0; tab < 6; tab++) {
        g.consoleTab = tab;
        g.bump();
        await check(tester, 'panel $tab');

        final groups = find.byType(ControlGroup);
        expect(groups, findsWidgets);
        final inner = tester.getSize(find.byType(ControlConsole).first).width - 18;
        for (var i = 0; i < tester.widgetList(groups).length; i++) {
          final w = tester.getSize(groups.at(i)).width;
          expect(w, lessThanOrEqualTo(inner + 0.5),
              reason: 'panel $tab group $i is ${w}pt, console allows $inner');
        }
      }
    });
  });
}
