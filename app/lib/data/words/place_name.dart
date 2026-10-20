import '../models/pane_name.dart';
import '../models/places.dart';

/// What a where-line calls the folder [cwd]. A linked worktree reads
/// `worktree-a · herdr-mobile`: its own name first, so the part that tells
/// checkouts apart survives an ellipsis, then the repo it belongs to. Anything
/// else (the main checkout, a sub-folder of it, a folder git does not know)
/// keeps the last path segment: those already read as the repo or the folder.
String placeName(PlaceIndex places, String? cwd) {
  final place = places.of(cwd);
  if (place != null && place.isLinked) return '${place.checkoutName} · ${place.repoName}';
  return paneFolder(cwd);
}
