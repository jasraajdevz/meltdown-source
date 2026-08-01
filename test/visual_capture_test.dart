// Renders key screens and captures them as PNGs:
//   flutter test --platform chrome --update-goldens --dart-define=CAPTURE=true \
//     test/visual_capture_test.dart
@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meltdown_reactor/main.dart';

void main() {
  setUp(rawWipe);

  testWidgets('capture home, control room, manual and shop', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const ReactorApp());
    final st = tester.state<GameRootState>(find.byType(GameRoot));
    final g = st.game;
    g.uranium = 184000;
    g.research = 12;
    g.lifetimeMwh = 9400;
    g.bestShiftMwh = 1250;
    g.shifts = 14;
    g.trips = 9;
    g.meltdowns = 1;
    g.bump();
    await tester.pump(const Duration(milliseconds: 40));
    await expectLater(
        find.byType(ReactorApp), matchesGoldenFile('goldens/home.png'));

    // A running plant at power, mid-shift.
    g.startShift();
    final p = g.plant;
    p.resetScram();
    p.rcp = [true, true, false, false];
    p.boron = 880;
    p.rod = [74, 74, 70, 68];
    p.tAvg = 302;
    p.fuelTemp = 640;
    p.pressure = 155;
    p.power = 0.94;
    p.msiv = true;
    p.feedPump = 72;
    p.throttle = 62;
    p.sgLevel = 51;
    p.genBreaker = true;
    p.heaters = 1;
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await expectLater(
        find.byType(ReactorApp), matchesGoldenFile('goldens/control_room.png'));

    // Each console panel.
    for (var tab = 1; tab < 5; tab++) {
      g.consoleTab = tab;
      g.bump();
      await tester.pump(const Duration(milliseconds: 60));
      await expectLater(find.byType(ReactorApp),
          matchesGoldenFile('goldens/console_$tab.png'));
    }

    g.screen = Screen.manual;
    g.bump();
    await tester.pump(const Duration(milliseconds: 40));
    await expectLater(
        find.byType(ReactorApp), matchesGoldenFile('goldens/manual.png'));

    g.screen = Screen.shop;
    g.bump();
    await tester.pump(const Duration(milliseconds: 40));
    await expectLater(
        find.byType(ReactorApp), matchesGoldenFile('goldens/shop.png'));
  }, skip: !const bool.fromEnvironment('CAPTURE'));
}
