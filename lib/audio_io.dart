// Audio backend for iOS / Android / desktop.
//
// Synthesizing waveforms on a native target would need a plugin, and this
// project ships with zero package dependencies. On a phone the better feedback
// channel is the Taptic Engine anyway, so tone() and noise() are no-ops here
// and main.dart's Sfx leans on HapticFeedback instead — see `synthesizes`.

class AudioEngine {
  /// False on native, so callers know to use haptics as the primary feedback.
  bool get synthesizes => false;

  void tone({
    required double f0,
    double? f1,
    String wave = 'square',
    double dur = 0.08,
    double vol = 0.15,
    double delay = 0,
  }) {}

  void noise({
    double dur = 0.2,
    double vol = 0.2,
    String type = 'lowpass',
    double fFrom = 6000,
    double fTo = 500,
    double delay = 0,
  }) {}
}
