// Not a test. An instrumented full night, flown by a competent operator, so
// the actual shape of a session is visible instead of assumed.
@TestOn('browser')
library;

import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:meltdown_reactor/main.dart';

/// Fly the plant properly: pumps, heat, pressure, rods, criticality, steam,
/// sync, then follow the dispatcher. Returns a log of what happened when.
Map<String, dynamic> flyNight(Game g, {double maxSeconds = 2000}) {
  final p = g.plant;
  final marks = <String, double>{};
  void mark(String k) => marks.putIfAbsent(k, () => p.shiftTime);

  var t = 0.0;
  const dt = 0.05;
  final faultsSeen = <String>[];
  final trips = <String>[];
  var wasScrammed = p.scrammed;
  final presencesSeen = <String>[];

  while (t < maxSeconds && g.shiftActive) {
    // --- the startup procedure, in order --------------------------------
    if (p.pumpCount < 2) {
      for (var i = 0; i < 2; i++) {
        if (p.pumpsAvailable > i) p.rcp[i] = true;
      }
    }
    if (p.pumpCount >= 2) mark('pumps');

    if (p.tAvg > 280) mark('hot');
    p.heaters = p.pressure < 150 ? 2 : (p.pressure < 155 ? 1 : 0);
    if (p.pressure > 150) mark('pressurised');

    if (p.pressure > 150 && p.tAvg > 280 && p.scramLatched) {
      p.resetScram();
      mark('tripReset');
    }
    if (!p.scrammed) {
      // Withdraw the banks in order — but only while genuinely shut down.
      // Pulling rods on a plant that is already critical and on load is how
      // you trip it, and a competent operator does not do that.
      var done = p.power > 0.05;
      if (!done) {
        for (var b = 0; b < 4; b++) {
          if (p.rod[b] < 99) {
            p.bank = b;
            p.rodCmd = RodCmd.withdraw;
            done = false;
            break;
          }
          done = true;
        }
      } else {
        p.rodCmd = RodCmd.hold;
      }
      if (done) {
        p.rodCmd = RodCmd.hold;
        mark('rodsOut');
        // Dilute toward criticality, then hold a controlled rate.
        if (p.power < 0.02) {
          // Source range tolerates a brisker climb than the intermediate
          // range does; a real startup is not held to one decade a minute
          // the whole way up.
          final ceiling = p.power < 1e-4 ? 3.0 : 1.2;
          p.boronCmd = p.sur > ceiling ? 0 : -1;
        } else {
          mark('critical');
          // Steam path.
          if (!p.msiv) p.msiv = true;
          p.feedPump = 75;
          // Roll the turbine, then keep opening until there is enough steam
          // to actually synchronise on.
          if (p.tAvg > 260 && p.steamFlow < 0.30 && !p.genBreaker) {
            p.throttle = clampD(p.throttle + 14 * dt, 0, 100);
          }
          if (p.steamFlow > 0.05) mark('steaming');
          // Sync.
          if (!p.genBreaker && p.steamFlow > 0.22) {
            if (math.sin(p.syncAngle).abs() < 0.12) {
              p.genBreaker = true;
              mark('onGrid');
            }
          }
          // Follow the dispatcher: throttle leads, boron matches.
          if (p.genBreaker) {
            final err = p.gridDemand - p.mwe;
            if (err > 25) {
              p.throttle = clampD(p.throttle + 12 * dt, 0, 100);
              // Lead with the throttle and let the moderator coefficient do
              // the work. Diluting as well is a double insertion and it is
              // what trips you.
              p.boronCmd = p.sur < -0.15 ? -1 : (p.sur > 0.4 ? 1 : 0);
            } else if (err < -25) {
              p.throttle = clampD(p.throttle - 12 * dt, 0, 100);
              p.boronCmd = p.sur > 0.15 ? 1 : 0;
            } else {
              p.boronCmd = p.sur.abs() < 0.2 ? 0 : (p.sur > 0 ? 1 : -1);
            }
          }
        }
      }
    }
    // Keep the operator alive.
    if (p.sanity < 45) {
      final pick = g.bestSip();
      if (pick != null) g.sip(pick);
    }
    if (p.anyFlashing) p.ackAlarms();
    // A competent operator answers the malfunction the strip is naming.
    if (p.faultId == 'fwTrip') p.afw = true;
    if (p.faultId == 'porvStuck') p.porv = false;
    if (p.faultId == 'losp') p.edg = true;

    if (p.faultId != null && !faultsSeen.any((e) => e.startsWith(p.faultId!))) {
      faultsSeen.add('${p.faultId}@${p.shiftTime.round()}s');
    }
    if (p.presenceId != null &&
        !presencesSeen.any((e) => e.startsWith(p.presenceId!))) {
      presencesSeen.add('${p.presenceId}@${p.shiftTime.round()}s');
    }

    if (p.scrammed && !wasScrammed) {
      trips.add('${p.scramCause}@${p.shiftTime.round()}s '
          '[pwr ${p.power.toStringAsFixed(2)} fuel ${p.fuelTemp.round()} '
          'tavg ${p.tAvg.round()} press ${p.pressure.round()} '
          'sg ${p.sgLevel.round()}]');
    }
    wasScrammed = p.scrammed;

    g.tick(dt);
    t += dt;
  }

  return {
    'marks': marks.map((k, v) => MapEntry(k, v.round())),
    'faults': faultsSeen,
    'trips': trips,
    'presences': presencesSeen,
    'nightLength': g.spec.lengthSeconds.round(),
    'endedAt': p.shiftTime.round(),
    'mwh': g.reportMwh.round(),
    'contract': g.reportContract.round(),
    'grade': g.watchGrade,
    'score': g.watchScore.round(),
    'sanity': g.reportSanity.round(),
    'uranium': g.reportUranium.round(),
    'condition': g.spec.condition.id,
  };
}

void main() {
  setUp(rawWipe);

  for (final night in [1, 9, 48, 300]) {
    testWidgets('PLAYTEST night $night', (tester) async {
      await tester.pumpWidget(const ReactorApp());
      final g = tester.state<GameRootState>(find.byType(GameRoot)).game;
      g.tutorial = false;
      g.shifts = night - 1;
      g.uranium = 50000;
      if (night > 20) g.upgrades.addAll({'rcpLoop': 2, 'rodSpeed': 3});
      g.startShift();
      final r = flyNight(g);
      // ignore: avoid_print
      print('NIGHT $night :: $r');
      expect(true, isTrue);
    });
  }
}
