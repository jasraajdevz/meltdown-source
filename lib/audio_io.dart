// Audio backend for iOS / Android / desktop.
//
// The web build synthesises through Web Audio. There is no equivalent in the
// Flutter framework, and this project ships with zero package dependencies, so
// for a long time this file was a pair of empty methods and the whole game was
// silent on the platform it was built for.
//
// The way out is to keep the synthesis in Dart and give the platform as little
// to do as possible: render the waveform here into 16-bit PCM, hand the bytes
// over a method channel, and let ~40 lines of Swift and Kotlin do nothing but
// play a buffer. All the interesting code stays testable in Dart, and the
// native side has almost no surface to be wrong on.
//
// If the channel is missing or throws — an older build of the host, a platform
// with no handler registered — `synthesizes` goes false and main.dart's Sfx
// falls back to haptics exactly as it did before. Sound is an improvement
// here, never a dependency.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('meltdown/audio');

/// 22.05 kHz is plenty for horns, hisses and sub-bass, and it halves the
/// number of bytes crossing the channel for every sound.
const int _rate = 22050;

/// Nothing in the game is longer than this; the cap stops a bad argument
/// allocating a huge buffer.
const double _maxDur = 4.0;

class AudioEngine {
  /// Turns false the first time the platform tells us there is no handler, so
  /// a host without the native side degrades to haptics instead of throwing
  /// once per sound effect.
  bool _available = true;
  bool _sessionReady = false;

  bool get synthesizes => _available;

  void tone({
    required double f0,
    double? f1,
    String wave = 'square',
    double dur = 0.08,
    double vol = 0.15,
    double delay = 0,
  }) {
    if (!_available) return;
    final d = dur.clamp(0.005, _maxDur).toDouble();
    final n = (d * _rate).round();
    if (n <= 0) return;

    // Frequencies are ramped exponentially, matching the Web Audio path, so a
    // sound written for one backend is the same sound on the other.
    final a0 = math.max(f0, 1.0);
    final a1 = math.max(f1 ?? f0, 1.0);
    final g0 = math.max(vol, 0.0001);

    final out = Int16List(n);
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / n;
      final freq = a0 * math.pow(a1 / a0, t);
      phase += 2 * math.pi * freq / _rate;
      if (phase > 2 * math.pi) phase -= 2 * math.pi;
      // Exponential decay to near-silence, as the gain ramp does on the web.
      final env = g0 * math.pow(0.0001 / g0, t);
      out[i] = _clip(_wave(wave, phase) * env);
    }
    _send(out, delay);
  }

  void noise({
    double dur = 0.2,
    double vol = 0.2,
    String type = 'lowpass',
    double fFrom = 6000,
    double fTo = 500,
    double delay = 0,
  }) {
    if (!_available) return;
    final d = dur.clamp(0.005, _maxDur).toDouble();
    final n = (d * _rate).round();
    if (n <= 0) return;

    final c0 = math.max(fFrom, 30.0);
    final c1 = math.max(fTo, 30.0);
    final g0 = math.max(vol, 0.0001);

    final out = Int16List(n);
    // A one-pole filter is not a biquad, but for hiss, steam and horn texture
    // the ear cannot tell, and it costs one multiply per sample.
    var lp = 0.0;
    final rnd = math.Random();
    for (var i = 0; i < n; i++) {
      final t = i / n;
      final cutoff = c0 * math.pow(c1 / c0, t);
      final k = (1 - math.exp(-2 * math.pi * cutoff / _rate)).clamp(0.0, 1.0);
      final white = rnd.nextDouble() * 2 - 1;
      lp += (white - lp) * k;
      final v = switch (type) {
        'highpass' => white - lp,
        'bandpass' => (white - lp) * 0.5 + lp * 0.5,
        _ => lp,
      };
      final env = g0 * math.pow(0.0001 / g0, t);
      out[i] = _clip(v * env);
    }
    _send(out, delay);
  }

  double _wave(String wave, double phase) {
    switch (wave) {
      case 'sine':
        return math.sin(phase);
      case 'triangle':
        final x = phase / (2 * math.pi);
        return 4 * (x < 0.5 ? x : 1 - x) - 1;
      case 'sawtooth':
        return 2 * (phase / (2 * math.pi)) - 1;
      default: // square
        return phase < math.pi ? 1.0 : -1.0;
    }
  }

  int _clip(num v) {
    final s = (v * 32767).round();
    return s > 32767 ? 32767 : (s < -32768 ? -32768 : s);
  }

  void _send(Int16List pcm, double delay) {
    if (delay > 0) {
      Future<void>.delayed(
          Duration(milliseconds: (delay * 1000).round()), () => _post(pcm));
    } else {
      _post(pcm);
    }
  }

  Future<void> _post(Int16List pcm) async {
    if (!_available) return;
    try {
      if (!_sessionReady) {
        _sessionReady = true;
        await _channel.invokeMethod<void>('init', {'rate': _rate});
      }
      // Sent as raw bytes rather than a typed list: Uint8List is the one
      // buffer type every version of the standard codec agrees on.
      await _channel.invokeMethod<void>('play', {
        'pcm': pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes),
        'rate': _rate,
      });
    } on MissingPluginException {
      // No native side on this host. Stop trying and let Sfx use haptics.
      _available = false;
    } catch (e) {
      _available = false;
      if (kDebugMode) {
        debugPrint('meltdown/audio unavailable, falling back to haptics: $e');
      }
    }
  }
}
