import 'dart:async';
import 'dart:io';

import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/remote_file_staging.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

/// A staging that copies nothing: it says how far it got and hands back a path.
/// [hold] keeps a copy half done until it completes.
class FakeStaging extends RemoteFileStaging {
  static final _folder = Directory.systemTemp.createTempSync('fake_staging');

  final fetched = <String>[];
  Completer<void>? hold;
  RemoteFileException? failWith;

  @override
  Future<File> fetch(
    RemoteFiles files,
    RemoteStat stat, {
    void Function(int written)? onProgress,
    ReadCancel? cancel,
  }) async {
    fetched.add(stat.name);
    onProgress?.call(stat.size! ~/ 2);
    if (hold case final gate?) {
      await gate.future;
      if (cancel?.cancelled ?? false) throw const ReadCancelled();
    }
    if (failWith case final e?) throw e;
    onProgress?.call(stat.size!);
    // A real (empty) file: the model hands over only copies that still exist.
    final file = File('${_folder.path}/${stat.name}');
    if (!file.existsSync()) file.writeAsBytesSync(const []);
    return file;
  }
}
