// Audio backend for the web build: live synthesis through the Web Audio API
// via dart:js_interop. No assets, no packages.
//
// main.dart's Sfx class composes tone() and noise() into every game sound, so
// this file only has to provide the two primitives.

import 'dart:js_interop';
import 'dart:math' as math;

@JS('AudioContext')
extension type _WACtx._(JSObject _) implements JSObject {
  external _WACtx();
  external double get currentTime;
  external double get sampleRate;
  external String get state;
  external JSObject get destination;
  external JSPromise resume();
  external _WAOsc createOscillator();
  external _WAGain createGain();
  external _WAFilter createBiquadFilter();
  external _WABuffer createBuffer(
      int numberOfChannels, int length, num sampleRate);
  external _WASrc createBufferSource();
}

extension type _WAParam._(JSObject _) implements JSObject {
  external void setValueAtTime(num value, num startTime);
  external void exponentialRampToValueAtTime(num value, num endTime);
}

extension type _WAOsc._(JSObject _) implements JSObject {
  external set type(String value);
  external _WAParam get frequency;
  external void connect(JSObject destination);
  external void start(num when);
  external void stop(num when);
}

extension type _WAGain._(JSObject _) implements JSObject {
  external _WAParam get gain;
  external void connect(JSObject destination);
}

extension type _WAFilter._(JSObject _) implements JSObject {
  external set type(String value);
  external _WAParam get frequency;
  external void connect(JSObject destination);
}

extension type _WABuffer._(JSObject _) implements JSObject {
  external JSFloat32Array getChannelData(int channel);
}

extension type _WASrc._(JSObject _) implements JSObject {
  external set buffer(_WABuffer value);
  external void connect(JSObject destination);
  external void start(num when);
  external void stop(num when);
}

class AudioEngine {
  _WACtx? _ctx;
  _WAGain? _master;
  _WABuffer? _noise;
  final math.Random _rng = math.Random();

  /// True where real synthesis is possible, so the caller can lean on sound
  /// instead of haptics.
  bool get synthesizes => true;

  void _ensure() {
    if (_ctx == null) {
      final c = _WACtx();
      final m = c.createGain();
      m.gain.setValueAtTime(0.45, 0);
      m.connect(c.destination);
      final n = c.createBuffer(1, c.sampleRate.round(), c.sampleRate);
      final data = n.getChannelData(0).toDart;
      for (var i = 0; i < data.length; i++) {
        data[i] = _rng.nextDouble() * 2 - 1;
      }
      _ctx = c;
      _master = m;
      _noise = n;
    }
    if (_ctx!.state == 'suspended') _ctx!.resume();
  }

  void tone({
    required double f0,
    double? f1,
    String wave = 'square',
    double dur = 0.08,
    double vol = 0.15,
    double delay = 0,
  }) {
    try {
      _ensure();
      final c = _ctx!;
      final t0 = c.currentTime + delay;
      final o = c.createOscillator()..type = wave;
      o.frequency.setValueAtTime(f0, t0);
      if (f1 != null) o.frequency.exponentialRampToValueAtTime(f1, t0 + dur);
      final g = c.createGain();
      g.gain.setValueAtTime(vol, t0);
      g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
      o.connect(g);
      g.connect(_master!);
      o.start(t0);
      o.stop(t0 + dur + 0.03);
    } catch (_) {}
  }

  void noise({
    double dur = 0.2,
    double vol = 0.2,
    String type = 'lowpass',
    double fFrom = 6000,
    double fTo = 500,
    double delay = 0,
  }) {
    try {
      _ensure();
      final c = _ctx!;
      final t0 = c.currentTime + delay;
      final s = c.createBufferSource()..buffer = _noise!;
      final f = c.createBiquadFilter()..type = type;
      f.frequency.setValueAtTime(fFrom, t0);
      f.frequency.exponentialRampToValueAtTime(math.max(fTo, 30), t0 + dur);
      final g = c.createGain();
      g.gain.setValueAtTime(vol, t0);
      g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
      s.connect(f);
      f.connect(g);
      g.connect(_master!);
      s.start(t0);
      s.stop(t0 + dur + 0.03);
    } catch (_) {}
  }
}
