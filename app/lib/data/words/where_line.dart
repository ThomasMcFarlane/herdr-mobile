/// The one meta line under an agent's title, on every surface:
/// `agent · machine · folder`. Each part says something the title does not:
///
///  * the agent is dropped when it is the title;
///  * the machine is dropped when [showMachine] is false (one machine on the
///    board: it tells nothing);
///  * the folder is dropped when it is the title or the workspace; the
///    workspace is shown only when there is no folder.
///
/// Empty parts are skipped; the result may be empty.
String whereLine({
  String? agent,
  String? machine,
  String? workspace,
  String? folder,
  String? title,
  bool showMachine = true,
}) {
  final a = _keep(agent);
  final m = _keep(machine);
  final w = _keep(workspace);
  final f = _keep(folder);
  final parts = <String>[];
  if (a != null && !_same(a, title)) parts.add(a);
  if (showMachine && m != null) parts.add(m);
  if (f != null) {
    if (!_same(f, title) && !_same(f, w)) parts.add(f);
  } else if (w != null && !_same(w, title)) {
    parts.add(w);
  }
  return parts.join(' · ');
}

String? _keep(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

bool _same(String a, String? b) => b != null && a.toLowerCase() == b.trim().toLowerCase();
