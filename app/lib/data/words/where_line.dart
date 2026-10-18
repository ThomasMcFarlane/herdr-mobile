/// The one meta line under an agent's title, on every surface:
/// `agent · machine · folder`. Each part says something the title does not:
///
///  * the agent is dropped when it is the title;
///  * the machine is dropped when [showMachine] is false (one machine on the
///    board: it tells nothing);
///  * the place is the folder, else the workspace (a folder named like its
///    workspace is said once); it is dropped when it is the title.
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
  // The folder, else the workspace; when the two are the same it is said once.
  final place = f ?? w;
  if (place != null && !_same(place, title)) parts.add(place);
  return parts.join(' · ');
}

String? _keep(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

bool _same(String a, String? b) => b != null && a.toLowerCase() == b.trim().toLowerCase();
