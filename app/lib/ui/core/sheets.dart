import 'dart:async';

import 'package:flutter/material.dart';

import 'press.dart';
import 'buttons.dart';
import 'motion.dart';
import 'tokens.dart';

/// Modal bottom sheet in the app's style: rounded top, grabber, safe-area aware.
///
/// Colours come from the theme (`bottomSheetTheme`, `modalBarrierColor`), so a
/// light/dark switch while a sheet is open restyles it. The body scrolls when
/// it does not fit (large text, landscape). A tall sheet stops below the
/// status bar: the session overview used to grow under the clock, its grabber
/// and title drawn over the status icons. Its height is capped rather than
/// `useSafeArea` set, which also takes the side insets off the sheet itself,
/// so a landscape phone with a side navigation bar showed the page in a strip
/// beside it. The cap reads the top inset from the navigator that hosts the
/// sheet (inside the route the sheet's own top padding is already removed);
/// the size dependency rebuilds it on rotation. Under reduced motion the
/// sheet appears and goes without sliding (drag to dismiss still works).
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  isDismissible: dismissible,
  sheetAnimationStyle: Motion.reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          curve: Motion.easeOut,
          reverseCurve: Motion.easeOut,
          duration: Motion.sheetIn,
          reverseDuration: Motion.sheetOut,
        ),
  builder: (ctx) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(ctx).height - MediaQuery.paddingOf(Navigator.of(ctx).context).top,
    ),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: ctx.ds.textTertiary.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Flexible(child: SingleChildScrollView(child: builder(ctx))),
        ],
      ),
    ),
  ),
);

class SheetAction {
  const SheetAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
    this.unavailable,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  /// Why the action cannot be used now. The row stays, dimmed and inert, and
  /// says this under its label.
  final String? unavailable;
}

/// One row of an action sheet: [onTap] runs when the action is available.
class SheetActionRow extends StatelessWidget {
  const SheetActionRow({super.key, required this.action, required this.onTap});

  final SheetAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final reason = action.unavailable;
    final inert = reason != null;
    return PressBuilder(
      onTap: inert ? null : onTap,
      // A dimmed row is still read as a button, a disabled one.
      button: inert ? true : null,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: inert ? null : 52,
        constraints: inert ? const BoxConstraints(minHeight: 52) : null,
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: inert ? 6 : 0),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.row),
        ),
        child: Row(
          children: [
            Icon(
              action.icon,
              size: 20,
              color: inert
                  ? ds.textTertiary
                  : action.destructive
                  ? ds.dangerText
                  : ds.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                // Shrink-wrapped, so the row centres the label with its icon
                // (a full-height column pinned the label to the top).
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.row.copyWith(
                      color: inert
                          ? ds.textMuted
                          : action.destructive
                          ? ds.dangerText
                          : ds.text,
                    ),
                  ),
                  if (reason != null)
                    Text(
                      reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.caption.copyWith(color: ds.textSecondary),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A list of actions in a sheet (replaces popup menus).
Future<void> showActionSheet(
  BuildContext context, {
  String? title,
  required List<SheetAction> actions,
}) => showAppSheet<void>(
  context,
  builder: (ctx) {
    final ds = ctx.ds;
    // Outer inset 4 + row padding 16: icons and titles sit on the 20 gutter.
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: Type.label.copyWith(color: ds.textSecondary),
                ),
              ),
            ),
          for (final a in actions)
            SheetActionRow(
              action: a,
              onTap: () {
                Navigator.of(ctx).pop();
                a.onTap();
              },
            ),
        ],
      ),
    );
  },
);

/// Confirmation in a sheet. Returns true if confirmed.
Future<bool> showConfirmSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = true,
}) async {
  final result = await showAppSheet<bool>(
    context,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(
        Gap.gutter,
        Gap.xl,
        Gap.gutter,
        Gap.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: Type.title.copyWith(color: ctx.ds.text)),
          ),
          const SizedBox(height: Gap.sm),
          Text(
            message,
            style: Type.compact.copyWith(color: ctx.ds.textSecondary),
          ),
          const SizedBox(height: Gap.xl),
          AppButton(
            label: confirmLabel,
            kind: destructive ? AppButtonKind.danger : AppButtonKind.primary,
            expand: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
          const SizedBox(height: Gap.sm),
          AppButton(
            label: 'Cancel',
            kind: AppButtonKind.secondary,
            expand: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}
