import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'rows.dart';
import 'switch.dart';
import 'tokens.dart';

/// Shared metrics of declarative row lists.
abstract final class RowMetrics {
  /// The default [GapRow]: space between two groups of rows.
  static const gap = Gap.md;

  /// Air above a [NoteRow] (it belongs to the rows above it).
  static const noteTop = Gap.sm;

  /// Air under a [NoteRow], separating it from the next group.
  static const noteBottom = Gap.lg;

  /// Least height of a [HeaderRow].
  static const headerMin = 40.0;

  /// Opacity of a disabled row's texts (the row's controls keep theirs).
  static const disabledText = 0.5;

  /// The widest a row's [ActionRow.value] grows, as a share of the row.
  static const valueShare = 0.4;

  /// Width of the leading icon column, matching [ListRow]'s.
  static const leadingExtent = 32.0;
}

/// How an [ActionRow]'s title and icon are coloured.
enum RowKind { normal, accent, danger }

/// One entry of a [RowList]. Every spec has a stable [id] (a key for its
/// widget), and dividers are derived from neighbours: a row gets a hairline
/// only when the next spec is also a row (not a header, note or gap).
sealed class RowSpec {
  const RowSpec(this.id);

  final String id;

  /// Where this spec's divider starts, or null when it is not a row.
  double? get _dividerIndent;
}

/// A section header: [SectionLabel], at least [RowMetrics.headerMin] high.
final class HeaderRow extends RowSpec {
  const HeaderRow({required String id, required this.label, this.count, this.trailing}) : super(id);

  final String label;
  final int? count;
  final Widget? trailing;

  @override
  double? get _dividerIndent => null;
}

/// A row that does something: optional icon, title, optional value and
/// subtitle, optional chevron.
final class ActionRow extends RowSpec {
  const ActionRow({
    required String id,
    required this.title,
    this.icon,
    this.value,
    this.subtitle,
    this.kind = RowKind.normal,
    this.enabled = true,
    this.onTap,
    this.chevron = false,
  }) : super(id);

  final String title;
  final IconData? icon;
  final String? value;
  final String? subtitle;
  final RowKind kind;
  final bool enabled;
  final VoidCallback? onTap;
  final bool chevron;

  @override
  double? get _dividerIndent => ListRow.textIndent(hasLeading: icon != null);
}

/// A setting that is on or off: [SwitchRow] at the page gutter.
final class ToggleRow extends RowSpec {
  const ToggleRow({
    required String id,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  }) : super(id);

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  double? get _dividerIndent => Gap.gutter;
}

/// One choice of a list of choices: title, a check when [checked].
final class CheckRow extends RowSpec {
  const CheckRow({
    required String id,
    required this.title,
    this.subtitle,
    required this.checked,
    required this.onTap,
    this.enabled = true,
  }) : super(id);

  final String title;
  final String? subtitle;
  final bool checked;
  final VoidCallback onTap;
  final bool enabled;

  @override
  double? get _dividerIndent => Gap.gutter;
}

/// A thing (a machine, an agent): a [ListRow].
final class EntityRow extends RowSpec {
  const EntityRow({
    required String id,
    required this.title,
    this.leading,
    this.leadingExtent = RowMetrics.leadingExtent,
    this.leadingOnTitle = true,
    this.subtitle,
    this.subtitle2,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.dim = false,
    this.titleMaxLines = 2,
    this.subtitleMaxLines = 1,
    this.subtitleColor,
    this.semanticLabel,
  }) : super(id);

  final String title;
  final Widget? leading;
  final double leadingExtent;
  final bool leadingOnTitle;
  final String? subtitle;
  final String? subtitle2;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool dim;
  final int titleMaxLines;
  final int subtitleMaxLines;
  final Color? subtitleColor;
  final String? semanticLabel;

  @override
  double? get _dividerIndent => ListRow.textIndent(hasLeading: leading != null, leadingExtent: leadingExtent);
}

/// A quiet explanation under a group of rows.
final class NoteRow extends RowSpec {
  const NoteRow({required String id, required this.text}) : super(id);

  final String text;

  @override
  double? get _dividerIndent => null;
}

/// Space between groups.
final class GapRow extends RowSpec {
  const GapRow({required String id, this.height = RowMetrics.gap}) : super(id);

  final double height;

  @override
  double? get _dividerIndent => null;
}

/// Anything else. With [dividerIndent] set it counts as a row for dividers;
/// null (default) it brings its own separation.
final class CustomRow extends RowSpec {
  const CustomRow({required String id, required this.child, this.dividerIndent}) : super(id);

  final Widget child;
  final double? dividerIndent;

  @override
  double? get _dividerIndent => dividerIndent;
}

/// A list of [RowSpec]s as a sliver.
class RowList extends StatelessWidget {
  const RowList({super.key, required this.rows});

  final List<RowSpec> rows;

  @override
  Widget build(BuildContext context) => SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) => _RowEntry(rows: rows, index: i),
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          final i = rows.indexWhere((r) => r.id == key.value);
          return i < 0 ? null : i;
        },
      );
}

/// A list of [RowSpec]s as a box: for rows inside a sheet, a fold or a group
/// body, where the list is not itself a sliver.
class RowColumn extends StatelessWidget {
  const RowColumn({super.key, required this.rows});

  final List<RowSpec> rows;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [for (var i = 0; i < rows.length; i++) _RowEntry(rows: rows, index: i)],
      );
}

class _RowEntry extends StatelessWidget {
  _RowEntry({required this.rows, required this.index}) : super(key: ValueKey<String>(rows[index].id));

  final List<RowSpec> rows;
  final int index;

  @override
  Widget build(BuildContext context) {
    final spec = rows[index];
    final indent = spec._dividerIndent;
    final next = index + 1 < rows.length ? rows[index + 1] : null;
    final divided = indent != null && next?._dividerIndent != null;
    final body = _build(context, spec);
    if (!divided) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [body, Hairline(indent: indent)],
    );
  }

  static Widget _build(BuildContext context, RowSpec spec) {
    final ds = context.ds;
    switch (spec) {
      case HeaderRow():
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: RowMetrics.headerMin),
          child: Align(
            alignment: AlignmentDirectional.bottomStart,
            child: SectionLabel(label: spec.label, count: spec.count, trailing: spec.trailing),
          ),
        );
      case ActionRow():
        return _ActionRowView(spec: spec);
      case ToggleRow():
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: SwitchRow(
            title: spec.title,
            subtitle: spec.subtitle,
            value: spec.value,
            onChanged: spec.onChanged,
            enabled: spec.enabled,
          ),
        );
      case CheckRow():
        return Semantics(
          checked: spec.checked,
          enabled: spec.enabled ? null : false,
          child: PressRow(
            onTap: spec.enabled ? spec.onTap : null,
            padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - PressRow.inset, vertical: Gap.md),
            child: Row(
              children: [
                Expanded(
                  child: _Faded(
                    enabled: spec.enabled,
                    child: _TitleBlock(title: spec.title, subtitle: spec.subtitle, color: ds.text),
                  ),
                ),
                const SizedBox(width: Gap.md),
                SizedBox(
                  width: IconSize.row,
                  child: spec.checked ? Icon(LucideIcons.check, size: IconSize.row, color: ds.accentText) : null,
                ),
              ],
            ),
          ),
        );
      case EntityRow():
        return ListRow(
          title: spec.title,
          leading: spec.leading,
          leadingExtent: spec.leadingExtent,
          leadingOnTitle: spec.leadingOnTitle,
          subtitle: spec.subtitle,
          subtitle2: spec.subtitle2,
          trailing: spec.trailing,
          onTap: spec.onTap,
          onLongPress: spec.onLongPress,
          dim: spec.dim,
          titleMaxLines: spec.titleMaxLines,
          subtitleMaxLines: spec.subtitleMaxLines,
          subtitleColor: spec.subtitleColor,
          semanticLabel: spec.semanticLabel,
        );
      case NoteRow():
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.gutter, RowMetrics.noteTop, Gap.gutter, RowMetrics.noteBottom),
          child: Text(spec.text, style: Type.secondary.copyWith(color: ds.textMuted)),
        );
      case GapRow():
        return SizedBox(height: spec.height);
      case CustomRow():
        return spec.child;
    }
  }
}

class _ActionRowView extends StatelessWidget {
  const _ActionRowView({required this.spec});

  final ActionRow spec;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final color = switch (spec.kind) {
      RowKind.normal => ds.text,
      RowKind.accent => ds.accentText,
      RowKind.danger => ds.dangerText,
    };
    final icon = spec.icon;
    final value = spec.value;
    return Semantics(
      enabled: spec.enabled ? null : false,
      child: PressRow(
        onTap: spec.enabled ? spec.onTap : null,
        padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - PressRow.inset, vertical: Gap.md),
        child: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              if (icon != null) ...[
                SizedBox(
                  width: RowMetrics.leadingExtent,
                  child: _Faded(enabled: spec.enabled, child: Icon(icon, size: IconSize.bar, color: color)),
                ),
                const SizedBox(width: Gap.md),
              ],
              Expanded(
                child: _Faded(
                  enabled: spec.enabled,
                  child: _TitleBlock(title: spec.title, subtitle: spec.subtitle, color: color),
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: Gap.md),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: box.maxWidth * RowMetrics.valueShare),
                  child: _Faded(
                    enabled: spec.enabled,
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.cell.copyWith(color: ds.accentText),
                    ),
                  ),
                ),
              ],
              if (spec.chevron) ...[
                const SizedBox(width: Gap.sm),
                Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.title, required this.subtitle, required this.color});

  final String title;
  final String? subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: Type.cell.copyWith(color: color)),
        if (subtitle != null && subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.hair),
            child: Text(subtitle, style: Type.secondary.copyWith(color: context.ds.textSecondary)),
          ),
      ],
    );
  }
}

/// Fades a disabled row's text, not the whole row.
class _Faded extends StatelessWidget {
  const _Faded({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      enabled ? child : Opacity(opacity: RowMetrics.disabledText, child: child);
}
