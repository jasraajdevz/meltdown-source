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

String? rawLoad() {
  try {
    final f = _file;
    return f.existsSync() ? f.readAsStringSync() : null;
  } catch (_) {
    return null;
  }
}

void rawSave(String data) {
  try {
    _file.writeAsStringSync(data, flush: false);
  } catch (_) {}
}

void rawWipe() {
  try {
    final f = _file;
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}
