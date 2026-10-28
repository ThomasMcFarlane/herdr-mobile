/// One checkout of a repo, as `worktree.list` reports it. Unlike a workspace's
/// provenance this includes checkouts herdr has not opened, and the branch.
class WorktreeInfo {
  const WorktreeInfo({
    required this.path,
    required this.label,
    required this.isLinked,
    this.branch,
    this.isDetached = false,
    this.isBare = false,
    this.isPrunable = false,
    this.openWorkspaceId,
  });

  /// Null for anything that is not a map with a path: one odd row must not
  /// hide the others.
  static WorktreeInfo? tryParse(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    if (path is! String || !path.startsWith('/')) return null;
    final branch = json['branch'];
    final open = json['open_workspace_id'];
    final label = json['label'];
    return WorktreeInfo(
      path: path,
      label: label is String ? label : '',
      isLinked: json['is_linked_worktree'] == true,
      branch: branch is String && branch.isNotEmpty ? branch : null,
      isDetached: json['is_detached'] == true,
      isBare: json['is_bare'] == true,
      isPrunable: json['is_prunable'] == true,
      openWorkspaceId: open is String && open.isNotEmpty ? open : null,
    );
  }

  /// The usable checkouts of a `worktree.list` answer: a bare repo has nothing
  /// to work in and a prunable one is a folder that is already gone.
  static List<WorktreeInfo> parseList(Object? json) => [
    if (json is List)
      for (final row in json)
        if (tryParse(row) case final w? when !w.isBare && !w.isPrunable) w,
  ];

  final String path;
  final String label;
  final bool isLinked;
  final String? branch;
  final bool isDetached;
  final bool isBare;
  final bool isPrunable;

  /// The herdr workspace this checkout is open in; null when herdr has it
  /// closed (or never opened it).
  final String? openWorkspaceId;

  /// The folder's own name.
  String get name {
    final parts = path.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? '/' : parts.last;
  }
}

/// What `worktree.create` made: the checkout and the shell workspace herdr
/// opened in it.
class CreatedWorktree {
  const CreatedWorktree({
    required this.worktree,
    required this.workspaceId,
    required this.tabId,
    required this.rootPaneId,
  });

  final WorktreeInfo worktree;
  final String workspaceId;
  final String tabId;
  final String rootPaneId;
}
