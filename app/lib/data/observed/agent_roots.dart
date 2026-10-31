import 'dart:convert';

import '../models/remote_file.dart';
import '../services/remote_files.dart';

/// Where an agent keeps its files can be moved with an environment variable
/// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). The running process knows its own
/// value; for a session found by id alone, the folders a person listed on the
/// machine are tried after the default. Nothing here knows an agent's layout:
/// callers append their own subfolder to a root.

/// The most bytes of `/proc/<pid>/environ` read.
const maxEnvironBytes = 256 * 1024;

/// The most folders one `/*` entry stands for.
const maxGlobRoots = 50;

/// [value] as a root folder, or null when it cannot be used: absolute, no
/// control character, no `..` segment, at most 1024 characters. A relative or
/// `~` value is not expanded by the agents either, so it is unusable. A
/// trailing slash is dropped.
String? validRoot(String? value) {
  if (value == null || value.isEmpty || value.length > 1024) return null;
  if (!RemotePath.isAbsolute(value)) return null;
  if (value.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return null;
  if (value.split('/').contains('..')) return null;
  var out = value;
  while (out.length > 1 && out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out == '/' ? null : out;
}

/// The value of [variable] in the environment of process [pid], through SFTP
/// (`/proc/<pid>/environ`, never a shell), or null when the file cannot be
/// read, the variable is unset or its value is not a usable root.
Future<String?> processEnvRoot(RemoteFiles files, int pid, String variable) async {
  if (pid < 1) return null;
  final Iterable<int> bytes;
  try {
    bytes = await files.read('/proc/$pid/environ', length: maxEnvironBytes);
  } on RemoteFileException catch (e) {
    return switch (e.kind) {
      RemoteFileErrorKind.notFound ||
      RemoteFileErrorKind.permission ||
      RemoteFileErrorKind.notAFile ||
      RemoteFileErrorKind.notADirectory => null,
      _ => throw e,
    };
  }
  final prefix = '$variable=';
  String? found;
  for (final entry in utf8.decode(bytes.toList(), allowMalformed: true).split('\u0000')) {
    // The last assignment wins, as it does in a shell.
    if (entry.startsWith(prefix)) found = entry.substring(prefix.length);
  }
  return validRoot(found);
}

/// [defaultRoot] first, then each of [extras] ([MachineProfile.agentRoots]
/// entries: absolute, or starting with `~/`; one ending in `/*` stands for
/// every folder in that folder, by name). Unusable entries are skipped and a
/// folder appears once.
Future<List<String>> candidateRoots(RemoteFiles files, String defaultRoot, List<String> extras) async {
  final out = <String>[defaultRoot];
  void add(String? root) {
    if (root != null && !out.contains(root)) out.add(root);
  }

  if (extras.isEmpty) return out;
  final home = await files.home();
  for (final raw in extras) {
    var entry = raw.trim();
    if (entry == '~') entry = home;
    if (entry.startsWith('~/')) entry = '$home${entry.substring(1)}';
    if (entry.endsWith('/*')) {
      final parent = validRoot(entry.substring(0, entry.length - 2));
      if (parent == null) continue;
      try {
        final names = [
          for (final e in await files.list(parent))
            if (e.isDirectory) e.name,
        ]..sort();
        for (final name in names.take(maxGlobRoots)) {
          add(validRoot('$parent/$name'));
        }
      } on RemoteFileException catch (e) {
        switch (e.kind) {
          case RemoteFileErrorKind.notFound || RemoteFileErrorKind.permission || RemoteFileErrorKind.notADirectory:
            continue;
          default:
            rethrow;
        }
      }
    } else {
      add(validRoot(entry));
    }
  }
  return out;
}
