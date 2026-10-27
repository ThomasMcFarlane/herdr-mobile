import 'release_info.dart';

/// One release's notes, as `CHANGELOG.md` has them.
class ReleaseNotes {
  const ReleaseNotes({required this.version, required this.date, required this.headline, required this.notes});

  final String version;

  /// `2026-10-27`, as written after the version.
  final String date;

  /// The first `###` heading of the section: what the release is about, in one line.
  final String headline;

  /// The section without its `## [version]` line: the same Markdown the GitHub release carries.
  final String notes;

  /// The walkthrough clip the notes lead with, or null (see [ReleaseClip]).
  ReleaseClip? get clip => ReleaseClip.find(notes, version);
}

final _section = RegExp(r'^## \[(\d+\.\d+\.\d+)\](?: - (\d{4}-\d{2}-\d{2}))?\s*$');
final _headline = RegExp(r'^### (.+?)\s*$');

/// The releases in [changelog], newest first as the file orders them. `## [Unreleased]` and any
/// heading that is not a version are not releases. A section without a heading is named by its
/// version; one without notes is kept, and says so where it is shown.
List<ReleaseNotes> parseChangelog(String changelog) {
  final out = <ReleaseNotes>[];
  String? version;
  String? date;
  final body = <String>[];

  void close() {
    final v = version;
    if (v == null) return;
    final notes = body.join('\n').trim();
    String headline = '';
    for (final line in body) {
      final m = _headline.firstMatch(line);
      if (m != null) {
        headline = m[1]!;
        break;
      }
    }
    out.add(ReleaseNotes(version: v, date: date ?? '', headline: headline, notes: notes));
  }

  for (final line in changelog.split('\n')) {
    final m = _section.firstMatch(line);
    if (m != null) {
      close();
      version = m[1];
      date = m[2];
      body.clear();
    } else if (line.startsWith('## ')) {
      close();
      version = null;
      body.clear();
    } else if (version != null) {
      body.add(line);
    }
  }
  close();
  return out;
}
