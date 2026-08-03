// The native audio path.
//
// All the synthesis happens in Dart so that it can be checked here rather than
// only by ear on a device. These assertions are about the buffers that cross
// the method channel: right length, right shape, in range, and never a silent
// or malformed one.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meltdown_reactor/audio_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('meltdown/audio');

  late List<MethodCall> calls;
  late bool failNext;

  setUp(() {
    calls = [];
    failNext = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (failNext) throw PlatformException(code: 'boom');
      return call.method == 'init' ? true : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Int16List samplesOf(MethodCall c) {
    final bytes = (c.arguments as Map)['pcm'] as Uint8List;
    // Copy rather than view: after a round trip through the codec the bytes
    // can sit at an odd offset in their backing buffer, which asInt16List
    // refuses — and which is the same hazard the native side has to handle.
    return Uint8List.fromList(bytes).buffer.asInt16List();
  }

  group('a tone becomes a real buffer', () {
    test('it initialises once, then just plays', () async {
      final a = AudioEngine();
      a.tone(f0: 440, dur: 0.05);
      await Future<void>.delayed(Duration.zero);
      a.tone(f0: 880, dur: 0.05);
      await Future<void>.delayed(Duration.zero);

      expect(calls.first.method, 'init');
      expect(calls.where((c) => c.method == 'init').length, 1,
          reason: 'the session is opened once, not per sound');
      expect(calls.where((c) => c.method == 'play').length, 2);
    });

    test('the buffer is the length the duration asked for', () async {
      final a = AudioEngine();
      a.tone(f0: 440, dur: 0.25);
      await Future<void>.delayed(Duration.zero);
      final s = samplesOf(calls.last);
      // 22050 Hz for a quarter second.
      expect(s.length, closeTo(22050 * 0.25, 2));
    });

    test('it is audible, in range, and decays to silence', () async {
      final a = AudioEngine();
      a.tone(f0: 440, dur: 0.2, vol: 0.5);
      await Future<void>.delayed(Duration.zero);
      final s = samplesOf(calls.last);

      var peak = 0;
      for (final v in s) {
        final m = v.abs();
        if (m > peak) peak = m;
      }
      expect(peak, greaterThan(3000), reason: 'a silent buffer is a bug');
      expect(peak, lessThanOrEqualTo(32767), reason: 'never clips past int16');

      // Loud at the head, effectively gone by the tail.
      final head = s.take(200).map((e) => e.abs()).reduce((a, b) => a + b);
      final tail = s.skip(s.length - 200).map((e) => e.abs()).reduce((a, b) => a + b);
      expect(tail, lessThan(head ~/ 10), reason: 'the envelope must decay');
    });

    test('every waveform produces something', () async {
      for (final w in ['sine', 'square', 'triangle', 'sawtooth']) {
        calls.clear();
        final a = AudioEngine();
        a.tone(f0: 300, dur: 0.05, wave: w, vol: 0.4);
        await Future<void>.delayed(Duration.zero);
        final s = samplesOf(calls.last);
        expect(s.any((e) => e.abs() > 2000), isTrue, reason: '$w was silent');
      }
    });

    test('a swept tone actually sweeps', () async {
      final a = AudioEngine();
      // A long fall from high to low: zero crossings should thin out.
      a.tone(f0: 2000, f1: 100, dur: 0.4, vol: 0.6);
      await Future<void>.delayed(Duration.zero);
      final s = samplesOf(calls.last);
      int crossings(Iterable<int> xs) {
        var n = 0;
        var prev = 0;
        for (final v in xs) {
          if (prev < 0 && v >= 0) n++;
          prev = v;
        }
        return n;
      }

      final first = crossings(s.take(s.length ~/ 4));
      final last = crossings(s.skip(s.length - s.length ~/ 4));
      expect(first, greaterThan(last * 2), reason: 'pitch should fall');
    });
  });

  group('noise', () {
    test('produces a buffer that is not a tone', () async {
      final a = AudioEngine();
      a.noise(dur: 0.2, vol: 0.5, fFrom: 6000, fTo: 400);
      await Future<void>.delayed(Duration.zero);
      final s = samplesOf(calls.last);
      expect(s.length, closeTo(22050 * 0.2, 2));
      expect(s.any((e) => e.abs() > 1000), isTrue, reason: 'silent hiss');
    });

    test('every filter type produces something', () async {
      for (final t in ['lowpass', 'highpass', 'bandpass']) {
        calls.clear();
        final a = AudioEngine();
        a.noise(dur: 0.08, vol: 0.5, type: t);
        await Future<void>.delayed(Duration.zero);
        expect(samplesOf(calls.last).any((e) => e.abs() > 500), isTrue,
            reason: '$t was silent');
      }
    });
  });

  group('arguments that would throw on the web are survived here', () {
    test('zero and negative frequencies do not produce a broken buffer',
        () async {
      final a = AudioEngine();
      a.tone(f0: 0, f1: -50, dur: 0.05);
      a.noise(dur: 0.05, fFrom: 0, fTo: -10);
      await Future<void>.delayed(Duration.zero);
      for (final c in calls.where((c) => c.method == 'play')) {
        final s = samplesOf(c);
        expect(s.isNotEmpty, isTrue);
        expect(s.every((e) => e >= -32768 && e <= 32767), isTrue);
      }
    });

    test('an absurd duration is capped rather than allocating forever',
        () async {
      final a = AudioEngine();
      a.tone(f0: 440, dur: 9999);
      await Future<void>.delayed(Duration.zero);
      expect(samplesOf(calls.last).length, lessThanOrEqualTo(22050 * 4));
    });
  });

  group('it degrades instead of breaking', () {
    test('a host with no handler stops the engine claiming it synthesises',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final a = AudioEngine();
      expect(a.synthesizes, isTrue);
      a.tone(f0: 440, dur: 0.05);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(a.synthesizes, isFalse,
          reason: 'so Sfx falls back to haptics rather than throwing forever');
    });

    test('a platform error is caught and never rethrown', () async {
      final a = AudioEngine();
      failNext = true;
      a.tone(f0: 440, dur: 0.05);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(a.synthesizes, isFalse);
      // And it stops sending after that.
      final before = calls.length;
      a.tone(f0: 440, dur: 0.05);
      await Future<void>.delayed(Duration.zero);
      expect(calls.length, before);
    });
  });
}
