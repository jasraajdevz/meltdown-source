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
const String _backupKey = 'meltdown_reactor_save_v2_bak';

String? rawLoad() {
  try {
    return _lsGet(_saveKey);
  } catch (_) {
    return null;
  }
}

/// The previous good save. Only read when the current one will not parse.
String? rawLoadBackup() {
  try {
    return _lsGet(_backupKey);
  } catch (_) {
    return null;
  }
}

/// Returns false when the browser refused the write.
///
/// Private browsing, a full quota and storage eviction all present the same
/// way: setItem throws, and a caller that swallows it looks exactly like a
/// game that is saving fine right up until the reload that hands the player a
/// fresh start. The result is reported so the game can say so out loud.
bool rawSave(String data) {
  try {
    final prev = _lsGet(_saveKey);
    if (prev != null && prev.isNotEmpty) {
      try {
        _lsSet(_backupKey, prev);
      } catch (_) {
        // Out of room for a backup — the save itself still matters more.
      }
    }
    _lsSet(_saveKey, data);
    // Read back rather than trusting the write: some browsers accept setItem
    // and discard the value.
    return _lsGet(_saveKey) == data;
  } catch (_) {
    return false;
  }
}

void rawWipe() {
  try {
    _lsRemove(_saveKey);
  } catch (_) {}
  try {
    _lsRemove(_backupKey);
  } catch (_) {}
}
