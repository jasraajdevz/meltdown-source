// Read-aloud for the operator's manual, using the browser's own speech
// synthesis. No assets, no packages.
//
// Note the shape of the interop: `speechSynthesis` is fetched as an object and
// its methods called on it. Declaring `speak` as a bare top-level external
// (`@JS('speechSynthesis.speak')`) compiles to a call with no receiver, which
// throws "Illegal invocation" at runtime.

import 'dart:js_interop';

@JS('speechSynthesis')
external _SpeechSynth get _synth;

extension type _SpeechSynth._(JSObject _) implements JSObject {
  external void speak(JSObject utterance);
  external void cancel();
  external bool get speaking;
}

@JS('SpeechSynthesisUtterance')
extension type _Utterance._(JSObject _) implements JSObject {
  external _Utterance(String text);
  external set rate(num value);
  external set pitch(num value);
  external set volume(num value);
}

class Speech {
  /// True where reading aloud is possible, so the UI can hide the control.
  bool get available {
    try {
      _synth.speaking; // touching it proves the API is really there
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get speaking {
    try {
      return _synth.speaking;
    } catch (_) {
      return false;
    }
  }

  void speak(String text) {
    try {
      _synth.cancel();
      // Slightly slow and level — this is a procedure being read out, not an
      // audiobook.
      final u = _Utterance(text)
        ..rate = 0.95
        ..pitch = 0.9
        ..volume = 1.0;
      _synth.speak(u);
    } catch (_) {}
  }

  void stop() {
    try {
      _synth.cancel();
    } catch (_) {}
  }
}
