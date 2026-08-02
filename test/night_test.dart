// The thousand nights.
//
// The complaint this suite exists to answer is "the levels repeat". These
// assertions are the objective form of that: a night must be reproducible from
// its number alone, consecutive nights must differ, and the ladder must still
// be climbing at night 900.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:meltdown_reactor/main.dart';

void main() {
  group('a night is a pure function of its number', () {
    test('the same night is the same night, every time', () {
      for (final n in [1, 7, 42, 199, 500, 823, 1000]) {
        final a = NightSpec.of(n);
        final b = NightSpec.of(n);
        expect(a.condition.id, b.condition.id, reason: 'night $n');
        expect(a.name, b.name);
        expect(a.faultsPlanned, b.faultsPlanned);
        expect(a.severity, b.severity);
        expect(a.lengthSeconds, b.lengthSeconds);
      }
    });

    test('every night from 1 to 1000 is well formed', () {
      for (var n = 1; n <= 1000; n++) {
        final s = NightSpec.of(n);
        expect(s.night, n);
        expect(s.tier, inInclusiveRange(0, 9), reason: 'night $n tier');
        expect(s.chapter, greaterThanOrEqualTo(1));
        expect(s.faultsPlanned, inInclusiveRange(0, 9), reason: 'night $n');
        expect(s.maxConcurrent, greaterThanOrEqualTo(1));
        expect(s.severity, greaterThanOrEqualTo(1));
        expect(s.lengthSeconds, greaterThan(60));
        expect(s.name.isNotEmpty, isTrue, reason: 'night $n has no name');
        expect(s.condition.minTier, lessThanOrEqualTo(s.tier),
            reason: 'night $n drew a condition above its tier');
      }
    });

    test('a night out of range does not throw', () {
      expect(NightSpec.of(0).night, 1);
      expect(NightSpec.of(-5).night, 1);
      expect(NightSpec.of(99999).tier, 9);
    });
  });

  group('nights do not repeat', () {
    test('the opening nights are deliberately routine', () {
      expect(NightSpec.of(1).condition.id, 'normal');
      expect(NightSpec.of(2).condition.id, 'normal');
      expect(NightSpec.of(1).faultsPlanned, lessThanOrEqualTo(1));
    });

    test('consecutive nights rarely repeat a condition', () {
      var repeats = 0;
      for (var n = 3; n < 1000; n++) {
        if (NightSpec.of(n).condition.id == NightSpec.of(n + 1).condition.id) {
          repeats++;
        }
      }
      // With sixteen conditions, chance alone gives ~6%. Anything approaching
      // half would mean the seed is not doing its job.
      expect(repeats / 997, lessThan(0.18), reason: '$repeats back-to-back');
    });

    test('the conditions are actually all used across a playthrough', () {
      final seen = <String>{};
      for (var n = 1; n <= 1000; n++) {
        seen.add(NightSpec.of(n).condition.id);
      }
      expect(seen.length, kConditions.length,
          reason: 'unused conditions: '
              '${kConditions.map((c) => c.id).toSet().difference(seen)}');
    });

    test('conditions carry real mechanical weight, not just a label', () {
      for (final c in kConditions) {
        if (c.id == 'normal') continue;
        final touches = [
          c.demandMult != 1,
          c.ratedMult != 1,
          c.faultDelta != 0,
          c.screamMult != 1,
          c.gradeMult != 1,
          c.researchMult != 1,
          c.xenonMult != 1,
          c.botsOffline,
          c.stormy,
        ].where((e) => e).length;
        expect(touches, greaterThan(0),
            reason: '${c.id} is a name with nothing behind it');
      }
    });
  });

  group('the ladder is still climbing at the far end', () {
    test('difficulty rises monotonically by tier', () {
      var last = -1;
      for (final n in [1, 3, 5, 9, 17, 33, 65, 129, 257, 513, 1000]) {
        final t = NightSpec.of(n).tier;
        expect(t, greaterThanOrEqualTo(last), reason: 'night $n');
        last = t;
      }
      expect(NightSpec.of(1000).tier, 9);
    });

    test('a late night is harder than an early one in every dimension', () {
      final early = NightSpec.of(5);
      final late = NightSpec.of(600);
      expect(late.faultsPlanned, greaterThan(early.faultsPlanned));
      expect(late.severity, greaterThan(early.severity));
      expect(late.maxConcurrent, greaterThan(early.maxConcurrent));
      expect(late.lengthSeconds, greaterThan(early.lengthSeconds));
    });

    test('every authored night and milestone is reachable and in range', () {
      for (final n in kAuthoredNights.keys) {
        expect(n, inInclusiveRange(1, 1000), reason: 'authored night $n');
        expect(NightSpec.of(n).authored, isTrue);
      }
      for (final (n, label) in kMilestones) {
        expect(n, inInclusiveRange(1, 1000));
        expect(label.isNotEmpty, isTrue);
      }
      // The ladder has to be sorted or the service record draws backwards.
      final ns = [for (final (n, _) in kMilestones) n];
      expect(ns, orderedEquals([...ns]..sort()));
    });
  });

  group('the watch has a shape', () {
    test('dispatch troughs in the small hours and peaks at dawn', () {
      // Sampled straight off the profile in requestLoad.
      double base(double f) => f < 0.62
          ? 0.46 + (0.38 - 0.46) * (f / 0.62)
          : 0.38 + (0.92 - 0.38) * ((f - 0.62) / 0.38);
      expect(base(0.0), greaterThan(base(0.6)), reason: 'overnight trough');
      expect(base(1.0), greaterThan(base(0.0)), reason: 'morning peak');
      expect(base(1.0), greaterThan(0.85));
    });

    test('the night ends on its own', () {
      final p = Plant(upgrades: {})..spec = NightSpec.of(1);
      expect(p.reliefDue, isFalse);
      p.shiftTime = p.spec.lengthSeconds + 1;
      expect(p.reliefDue, isTrue);
      expect(p.nightProgress, 1);
    });
  });
}
