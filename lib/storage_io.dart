// Save storage for iOS / Android / desktop.
//
// Selected automatically by the conditional import in main.dart. On iOS the
// app sandbox's Documents directory is the only location that survives app
// updates and is backed up, so prefer it and fall back to temp.

import 'dart:io';

const String _fileName = 'meltdown_reactor_save_v2.json';

String get _dirPath {
  try {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final docs = Directory('$home/Documents');
      if (docs.existsSync()) return docs.path;
      docs.createSync(recursive: true);
      return docs.path;
    }
  } catch (_) {}
  return Directory.systemTemp.path;
}

File get _file => File('$_dirPath/$_fileName');
File get _backup => File('$_dirPath/$_fileName.bak');
File get _temp => File('$_dirPath/$_fileName.tmp');

String? rawLoad() {
  try {
    final f = _file;
    return f.existsSync() ? f.readAsStringSync() : null;
  } catch (_) {
    return null;
  }
}

/// The previous good save. Only read when the current one will not parse.
String? rawLoadBackup() {
  try {
    final f = _backup;
    return f.existsSync() ? f.readAsStringSync() : null;
  } catch (_) {
    return null;
  }
}

/// Write the save without ever leaving a half-written file on disk.
///
/// The obvious implementation — write straight over the save — opens the file
/// with O_TRUNC, so for the length of the write the player's entire history is
/// a zero-byte file. The OS kills backgrounded apps at exactly that moment far
/// more often than it sounds, and this runs every few seconds while a watch is
/// on. Instead the new copy goes to a temp file, is flushed to the platform,
/// and is moved into place with rename(), which is atomic. The worst a kill
/// can now do is leave yesterday's save intact.
///
/// Returns false when the write did not happen, so the game can tell the
/// player their progress is not being recorded rather than pretend it is.
bool rawSave(String data) {
  try {
    if (_file.existsSync()) {
      try {
        _file.copySync(_backup.path);
      } catch (_) {
        // A missing backup is survivable. A failed save is not — carry on.
      }
    }
    _temp.writeAsStringSync(data, flush: true);
    _temp.renameSync(_file.path);
    return true;
  } catch (_) {
    return false;
  }
}

void rawWipe() {
  for (final f in [_file, _backup, _temp]) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
