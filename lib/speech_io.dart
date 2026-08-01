// Read-aloud on iOS / Android / desktop.
//
// Native text-to-speech needs a platform plugin, and this project ships with
// zero package dependencies, so the control simply reports itself unavailable
// and the manual hides the button. Web gets the real thing.

class Speech {
  bool get available => false;
  bool get speaking => false;
  void speak(String text) {}
  void stop() {}
}
