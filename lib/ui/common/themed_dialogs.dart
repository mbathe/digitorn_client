/// Themed dialog helpers that actually respect `AppColors` in both
/// dark and light modes. Material's default `AlertDialog` relies on
/// `ColorScheme` + `DefaultTextStyle` inheritance, which is fragile
/// once we sprinkle `GoogleFonts.inter()` styles on top — the font
/// style merges in and strips the default color, leaving invisible
/// text on some screens.
///
/// These helpers always pass an explicit colour so a title stays
/// bright and body text stays on `c.text` regardless of theme.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';

/// Shared titlebar text style — always uses `c.textBright`.
TextStyle dialogTitleStyle(BuildContext context) {
  final c = context.colors;
  return GoogleFonts.inter(
    fontSize: 14,
    fontWeight: FontWeight.w700,
    color: c.textBright,
  );
}

/// Shared body text style — always uses `c.text`.
TextStyle dialogBodyStyle(BuildContext context) {
  final c = context.colors;
  return GoogleFonts.inter(
    fontSize: 12.5,
    color: c.text,
    height: 1.5,
  );
}

/// Themed label style for input fields.
TextStyle dialogLabelStyle(BuildContext context) {
  final c = context.colors;
  return GoogleFonts.inter(fontSize: 12, color: c.textMuted);
}

/// Themed input decoration that properly respects dark/light mode.
/// Use this instead of plain `InputDecoration(labelText: ...)` in
/// any dialog / form you want to behave correctly.
InputDecoration themedInputDecoration(
  BuildContext context, {
  String? labelText,
  String? hintText,
  Widget? prefixIcon,
  Widget? suffixIcon,
}) {
  final c = context.colors;
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    labelStyle: GoogleFonts.inter(fontSize: 12, color: c.textMuted),
    hintStyle: GoogleFonts.inter(fontSize: 12, color: c.textDim),
    filled: true,
    fillColor: c.surfaceAlt,
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.blue, width: 1.4),
    ),
  );
}

/// Build a themed [AlertDialog] with explicit colours everywhere.
/// Use this over raw `AlertDialog()` in new code.
AlertDialog themedAlertDialog(
  BuildContext context, {
  required String title,
  required Widget content,
  required List<Widget> actions,
}) {
  final c = context.colors;
  return AlertDialog(
    backgroundColor: c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: c.border),
    ),
    title: Text(title, style: dialogTitleStyle(context)),
    content: DefaultTextStyle.merge(
      style: dialogBodyStyle(context),
      child: content,
    ),
    actions: actions,
  );
}

/// Prompt the user for a single text value. Returns the trimmed
/// value or null if they cancel.
Future<String?> showThemedPromptDialog(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
  String confirmLabel = 'Save',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final c = ctx.colors;
      return themedAlertDialog(
        ctx,
        title: title,
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: GoogleFonts.inter(fontSize: 13, color: c.textBright),
          decoration: themedInputDecoration(ctx, hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.blue,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: Text(confirmLabel,
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      );
    },
  );
}

/// Ask the user a yes/no question. Returns true if confirmed,
/// false or null otherwise.
Future<bool?> showThemedConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = ctx.colors;
      return themedAlertDialog(
        ctx,
        title: title,
        content: Text(body, style: dialogBodyStyle(ctx)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelLabel,
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: destructive ? c.red : c.blue,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: Text(confirmLabel,
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      );
    },
  );
}
