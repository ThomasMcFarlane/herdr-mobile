import 'web_bridge.dart' show isWebPageName;

/// The kinds of file a session can have made that the person looks at, by the
/// name's extension. Source code, configuration, logs and data are not here on
/// purpose: an agent touches those all day, and they are not what anyone opens
/// to see what it did.
enum MadeFileKind { page, picture, doc }

const _pictureExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// `md`, `pdf` and the office formats a report is made in, and `csv`: a table
/// is something to look at. Not `txt`, `json`, `log` or `yaml`: those are what
/// a build prints and a project is configured with.
const _documentExtensions = {'md', 'markdown', 'pdf', 'docx', 'xlsx', 'pptx', 'csv'};

/// What [name] (a file name or a path) is, or null. HTML and SVG are pages
/// (the browser shows them); the SVG is not a picture here because the app has
/// nothing to draw it with.
MadeFileKind? madeFileKindOf(String name) {
  if (isWebPageName(name)) return MadeFileKind.page;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  if (_pictureExtensions.contains(ext)) return MadeFileKind.picture;
  if (_documentExtensions.contains(ext)) return MadeFileKind.doc;
  return null;
}
