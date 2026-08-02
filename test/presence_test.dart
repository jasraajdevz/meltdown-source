// The things in the building.
//
// Every presence must (a) actually do something to the plant or the operator,
// (b) have an answer the player can find and hold, and (c) let go of the plant
// completely when it leaves. A presence that fails (b) is not horror, it is a
// tax; one that fails (c) poisons every night after it.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:math' as math;

import 'package:meltdown_reactor/main.dart';

Plant atPower({int pumps = 3}) {
  final p = Plant(upgrades: {})
    ..spec = NightSpec.of(400)
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
    ..mwhThisShift = 40;
  for (var i = 0; i < pumps; i++) {
    p.rcp[i] = true;
  }
  return p;
}

void run(Plant p, double seconds) {
  for (var t = 0.0; t < seconds; t += 0.05) {
    p.step(0.05);
  }
}

Presence byId(String id) => kPresences.firstWhere((e) => e.id == id);

void main() {
  group('the roster is coherent', () {
    test('there are at least thirteen of them, all distinct', () {
      expect(kPresences.length, greaterThanOrEqualTo(13));
      expect(kPresences.map((e) => e.id).toSet().length, kPresences.length);
      expect(kPresences.map((e) => e.name).toSet().length, kPresences.length);
    });

    test('every one has a tell and an answer written down', () {
      for (final pr in kPresences) {
        expect(pr.tell.length, greaterThan(25), reason: pr.id);
        expect(pr.counter.length, greaterThan(25), reason: pr.id);
        expect(pr.line.isNotEmpty, isTrue, reason: pr.id);
        expect(pr.caller.isNotEmpty, isTrue, reason: pr.id);
        expect(pr.dread, inInclusiveRange(1, 3), reason: pr.id);
      }
    });

    test('every one does something mechanical, not just a log line', () {
      for (final pr in kPresences) {
        expect(pr.onset != null || pr.sustain != null, isTrue,
            reason: '${pr.id} is a message with nothing behind it');
      }
    });

    test('they are staged across the thousand nights', () {
      final nights = kPresences.map((e) => e.minNight).toList()..sort();
      expect(nights.first, greaterThanOrEqualTo(3),
          reason: 'nights one and two must be completely clean');
      expect(nights.last, greaterThan(100),
          reason: 'something has to be left for the far end');
      // Nothing should be reachable before the player has met the plant.
      for (final pr in kPresences) {
        expect(pr.minNight, greaterThanOrEqualTo(3), reason: pr.id);
      }
    });
  });

  group('each one bites, and each one can be answered', () {
    test('the lag makes an indication lie without moving the plant', () {
      final p = atPower();
      final trueT = p.tAvg;
      p.startPresence(byId('lag'));
      p.rodCmd = RodCmd.withdraw; // chasing it
      run(p, 20);
      expect(p.indBias, greaterThan(5));
      expect(p.iTavg, greaterThan(p.tAvg + 4),
          reason: 'the needle, not the coolant, is what is wrong');
      expect(p.tAvg, closeTo(trueT, 40), reason: 'the plant is still fine');
    });

    test('the lag leaves when you stop steering by it', () {
      final p = atPower();
      p.startPresence(byId('lag'));
      p.rodCmd = RodCmd.hold;
      p.boronCmd = 0;
      run(p, 12);
      expect(p.presenceId, isNull);
      expect(p.indBias, 0, reason: 'and it gives the needle back');
      expect(p.presencesMet, contains('lag'));
    });

    test('the listener makes malfunctions take longer to clear', () {
      final p = atPower();
      p.startPresence(byId('listener'));
      expect(p.holdStretch, greaterThan(1));
      final f = kFaults.firstWhere((e) => e.id == 'vacuum');
      p.startFault(f);
      p.throttle = 30;
      run(p, f.holdFor + 4);
      expect(p.faultId, isNotNull,
          reason: 'what would normally have cleared has not');
    });

    test('silencing the second horn costs you the horn entirely', () {
      final p = atPower();
      p.startPresence(byId('secondHorn'));
      p.scram('TEST'); // raises a flashing alarm
      expect(p.hornActive, isTrue);
      p.ackAlarms();
      expect(p.hornDead, isTrue);
      p.resetAlarms();
      p.scram('AGAIN');
      expect(p.hornActive, isFalse,
          reason: 'new alarms now arrive with no sound at all');
    });

    test('the cold spot removes heat, and boration answers it', () {
      final p = atPower();
      p.startPresence(byId('coldSpot'));
      expect(p.coldDraw, greaterThan(0));
      p.boronCmd = 1;
      run(p, 12);
      expect(p.presenceId, isNull);
      expect(p.coldDraw, 0);
    });

    test('the count charges dose for looking, and stops when you look away',
        () {
      final p = atPower()..watchedTab = 2;
      p.startPresence(byId('count'));
      run(p, 12);
      expect(p.radiation, greaterThan(5));
      final held = p.radiation;
      p.watchedTab = 4;
      run(p, 10);
      expect(p.presenceId, isNull);
      expect(p.radiation, lessThanOrEqualTo(held + 0.5),
          reason: 'no more dose once your eyes are elsewhere');
    });

    test('unit 2 takes the megawatts without breaking anything', () {
      final p = atPower();
      final before = p.mwe;
      p.startPresence(byId('unit2'));
      run(p, 3);
      expect(p.mwe, lessThan(before * 0.7));
      expect(p.scrammed, isFalse, reason: 'nothing on the plant is wrong');
    });

    test('the feed makes level swing with no flow behind it', () {
      final p = atPower();
      p.startPresence(byId('feed'));
      final samples = <double>[];
      for (var i = 0; i < 12; i++) {
        run(p, 2);
        samples.add(p.sgLevel);
      }
      final swing = samples.reduce(math.max) - samples.reduce(math.min);
      expect(swing, greaterThan(1.0), reason: 'level should be hunting');

      p.frvAuto = false; // manual feed is the answer
      run(p, 10);
      expect(p.presenceId, isNull);
      expect(p.feedHunt, 0);
    });

    test('the interlock removes the protection that keeps you alive', () {
      final p = atPower();
      p.startPresence(byId('interlock'));
      expect(p.protectionOff, isTrue);
      p.fuelTemp = 2000; // far past every trip setpoint
      p.power = 1.6;
      run(p, 2);
      expect(p.scrammed, isFalse,
          reason: 'nothing stands between you and your own mistake');

      p.scram('OPERATOR'); // refusing the gift
      run(p, 8);
      expect(p.presenceId, isNull);
      expect(p.protectionOff, isFalse);
    });

    test('the refusal holds the rods off the bottom, gravity does not', () {
      final p = atPower();
      p.startPresence(byId('refusal'));
      p.scram('TEST');
      run(p, 4);
      expect(p.rodAvg, greaterThan(10),
          reason: 'the banks have come to rest on something');

      // It can hold a motor, not gravity.
      p.rcp = [false, false, false, false];
      run(p, 4);
      expect(p.rodAvg, lessThan(2));
      expect(p.presenceId, isNull);
    });

    test('the caller declares a leak that is not happening', () {
      final p = atPower();
      p.startPresence(byId('caller'));
      expect(p.phantomFault, 'tubeLeak');
      run(p, 6);
      expect(p.radiation, lessThan(1),
          reason: 'a fault that is not happening has no signature');
      expect(p.leakRate, 0);
      expect(p.faultId, isNull, reason: 'and no malfunction behind it');

      // Obeying it throws the load away for nothing, and it leaves satisfied.
      p.throttle = 20;
      run(p, 8);
      expect(p.presenceId, isNull);
      expect(p.phantomFault, isNull);
    });

    test('the one in the glass hides a row that still latches', () {
      final p = atPower();
      p.startPresence(byId('glass'));
      expect(p.blindRow, greaterThanOrEqualTo(0));
      p.lampTest = true;
      run(p, 10);
      expect(p.presenceId, isNull, reason: 'lamp test finds it');
      expect(p.blindRow, -1);
    });
  });

  group('nothing outlives its visit', () {
    test('every presence gives the plant back exactly as it found it', () {
      for (final pr in kPresences) {
        if (pr.id == 'growth') continue; // the one that is meant to stay
        final p = atPower();
        p.startPresence(pr);
        run(p, 4);
        p.startShift(hot: false);
        expect(p.presenceId, isNull, reason: pr.id);
        expect(p.indBias, 0, reason: pr.id);
        expect(p.holdStretch, 1, reason: pr.id);
        expect(p.hornDead, isFalse, reason: pr.id);
        expect(p.coldDraw, 0, reason: pr.id);
        expect(p.stolenLoad, 0, reason: pr.id);
        expect(p.feedHunt, 0, reason: pr.id);
        expect(p.protectionOff, isFalse, reason: pr.id);
        expect(p.rodStall, 0, reason: pr.id);
        expect(p.blindRow, -1, reason: pr.id);
        expect(p.clockSlip, 0, reason: pr.id);
        expect(p.phantomFault, isNull, reason: pr.id);
      }
    });

    test('the growth is the exception and persists across nights', () {
      final p = atPower();
      p.startPresence(byId('growth'));
      run(p, 20);
      final grown = p.growth;
      expect(grown, greaterThan(0));
      p.startShift(hot: false);
      expect(p.growth, closeTo(grown, 0.001),
          reason: 'it does not leave, that is the whole idea');
    });

    test('an in-progress visit survives the app being killed', () {
      final p = atPower();
      p.startPresence(byId('coldSpot'));
      run(p, 5);
      final q = Plant(upgrades: {})..applyJson(p.toJson());
      expect(q.presenceId, 'coldSpot');
      expect(q.coldDraw, greaterThan(0),
          reason: 'effects are rebuilt from the presence, not trusted');
    });
  });

  group('the building remembers you', () {
    test('the scream pool escalates and never repeats night one', () {
      expect(kScreamLines.length, 4);
      final all = <String>{};
      for (final tierPool in kScreamLines) {
        expect(tierPool.length, greaterThanOrEqualTo(7));
        all.addAll(tierPool);
      }
      expect(all.length, greaterThanOrEqualTo(29),
          reason: 'five lines on a loop is what made it feel scripted');
      // The deep pool must not be sayable on night one.
      expect(kScreamLines[0].any((l) => l.contains('IT IS IN THE ROOM')),
          isFalse);
      expect(kScreamLines[3].any((l) => l.contains('IT IS IN THE ROOM')),
          isTrue);
    });
  });
}
