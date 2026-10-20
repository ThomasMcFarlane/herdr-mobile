import 'package:herdr_mobile/data/models/herdr_models.dart';

/// `workspace.worktree` as herdr 0.9.3 sends it for the primary checkout and a
/// linked one of the same repo (captured from `herdr api snapshot`).
const wirePrimaryWorktree = <String, dynamic>{
  'checkout_path': '/home/u/workspace/herdr-mobile',
  'is_linked_worktree': false,
  'repo_key': '/home/u/workspace/herdr-mobile/.git',
  'repo_name': 'herdr-mobile',
  'repo_root': '/home/u/workspace/herdr-mobile',
};

const wireLinkedWorktree = <String, dynamic>{
  'checkout_path': '/home/u/.herdr/worktrees/herdr-mobile/worktree-lucky-cloud-848c',
  'is_linked_worktree': true,
  'repo_key': '/home/u/workspace/herdr-mobile/.git',
  'repo_name': 'herdr-mobile',
  'repo_root': '/home/u/workspace/herdr-mobile',
};

Map<String, dynamic> wireWorkspace(String id, {Object? worktree, String label = '', String status = 'idle', int number = 1}) => {
      'workspace_id': id,
      'number': number,
      'label': label.isEmpty ? id : label,
      'focused': false,
      'pane_count': 1,
      'tab_count': 1,
      'agent_status': status,
      'worktree': ?worktree,
    };

Map<String, dynamic> wireTab(String id, String workspace, {int number = 1, String label = ''}) => {
      'tab_id': id,
      'workspace_id': workspace,
      'number': number,
      'label': label,
      'focused': false,
      'pane_count': 1,
      'agent_status': 'idle',
    };

Map<String, dynamic> wirePaneIn(String id, String workspace, String tab, {String? cwd, String? agent, String status = 'idle'}) => {
      'pane_id': id,
      'workspace_id': workspace,
      'tab_id': tab,
      'cwd': cwd,
      'agent': agent,
      'agent_status': status,
      'terminal_title': id,
    };

Snapshot snapshotOf({
  required List<Map<String, dynamic>> workspaces,
  List<Map<String, dynamic>> tabs = const [],
  List<Map<String, dynamic>> panes = const [],
}) =>
    Snapshot.fromJson({'version': '1', 'workspaces': workspaces, 'tabs': tabs, 'panes': panes});
