// Save storage for the web build — browser localStorage through dart:js_interop.
// Selected automatically by the conditional import in main.dart.

import 'dart:js_interop';

@JS('localStorage.getItem')
external String? _lsGet(String key);
@JS('localStorage.setItem')
external void _lsSet(String key, String value);
@JS('localStorage.removeItem')
external void _lsRemove(String key);

const String _saveKey = 'meltdown_reactor_save_v2';

String? rawLoad() {
  try {
    return _lsGet(_saveKey);
  } catch (_) {
    return null;
  }
}

void rawSave(String data) {
  try {
    _lsSet(_saveKey, data);
  } catch (_) {}
}

void rawWipe() {
  try {
    _lsRemove(_saveKey);
  } catch (_) {}
}
