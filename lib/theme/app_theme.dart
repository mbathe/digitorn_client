import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Custom color extension for Digitorn theme
class AppColors extends ThemeExtension<AppColors> {
  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color borderHover;
  final Color text;
  final Color textBright;
  final Color textMuted;
  final Color textDim;
  final Color green;
  final Color red;
  final Color orange;
  final Color blue;
  final Color cyan;
  final Color purple;
  final Color codeBlockBg;
  final Color codeBlockHeader;
  final Color codeBg;
  final Color userBubbleBg;
  final Color userBubbleBorder;
  final Color inputBg;
  final Color inputBorder;
  final Color skeleton;
  final Color skeletonHighlight;

  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.borderHover,
    required this.text,
    required this.textBright,
    required this.textMuted,
    required this.textDim,
    required this.green,
    required this.red,
    required this.orange,
    required this.blue,
    required this.cyan,
    required this.purple,
    required this.codeBlockBg,
    required this.codeBlockHeader,
    required this.codeBg,
    required this.userBubbleBg,
    required this.userBubbleBorder,
    required this.inputBg,
    required this.inputBorder,
    required this.skeleton,
    required this.skeletonHighlight,
  });

  static const dark = AppColors(
    bg: Color(0xFF0D0D0D),
    surface: Color(0xFF111111),
    surfaceAlt: Color(0xFF141414),
    border: Color(0xFF1E1E1E),
    borderHover: Color(0xFF333333),
    text: Color(0xFFD4D4D4),
    textBright: Color(0xFFE6E6E6),
    textMuted: Color(0xFF555555),
    textDim: Color(0xFF3A3A3A),
    green: Color(0xFF22C55E),
    red: Color(0xFFEF4444),
    orange: Color(0xFFF59E0B),
    blue: Color(0xFF3B82F6),
    cyan: Color(0xFF06B6D4),
    purple: Color(0xFFA78BFA),
    codeBlockBg: Color(0xFF0F0F0F),
    codeBlockHeader: Color(0xFF161616),
    codeBg: Color(0xFF1A1020),
    userBubbleBg: Color(0xFF151515),
    userBubbleBorder: Color(0xFF1E1E1E),
    inputBg: Color(0xFF111111),
    inputBorder: Color(0xFF222222),
    skeleton: Color(0xFF1A1A1A),
    skeletonHighlight: Color(0xFF2A2A2A),
  );

  // VS Code Light theme colors
  static const light = AppColors(
    bg: Color(0xFFFFFFFF),        // editor.background
    surface: Color(0xFFF3F3F3),    // sideBar.background
    surfaceAlt: Color(0xFFE8E8E8), // list.hoverBackground
    border: Color(0xFFE0E0E0),     // panel.border
    borderHover: Color(0xFFB8B8B8),
    text: Color(0xFF333333),       // editor.foreground
    textBright: Color(0xFF000000), // foreground
    textMuted: Color(0xFF717171),  // descriptionForeground
    textDim: Color(0xFFC5C5C5),
    green: Color(0xFF388A34),      // terminal.ansiGreen
    red: Color(0xFFCD3131),        // terminal.ansiRed
    orange: Color(0xFFBF8803),     // terminal.ansiYellow
    blue: Color(0xFF0451A5),       // terminal.ansiBlue
    cyan: Color(0xFF0598BC),
    purple: Color(0xFF7C3AED),
    codeBlockBg: Color(0xFFF5F5F5),
    codeBlockHeader: Color(0xFFEAEAEA),
    codeBg: Color(0xFFF0E6FF),
    userBubbleBg: Color(0xFFF0F4FA),
    userBubbleBorder: Color(0xFFDDE5F0),
    inputBg: Color(0xFFFFFFFF),    // input.background
    inputBorder: Color(0xFFCECECE), // input.border
    skeleton: Color(0xFFE0E0E0),
    skeletonHighlight: Color(0xFFEEEEEE),
  );

  @override
  AppColors copyWith({Color? bg, Color? surface}) => this;

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderHover: Color.lerp(borderHover, other.borderHover, t)!,
      text: Color.lerp(text, other.text, t)!,
      textBright: Color.lerp(textBright, other.textBright, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      green: Color.lerp(green, other.green, t)!,
      red: Color.lerp(red, other.red, t)!,
      orange: Color.lerp(orange, other.orange, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      cyan: Color.lerp(cyan, other.cyan, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      codeBlockBg: Color.lerp(codeBlockBg, other.codeBlockBg, t)!,
      codeBlockHeader: Color.lerp(codeBlockHeader, other.codeBlockHeader, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      userBubbleBg: Color.lerp(userBubbleBg, other.userBubbleBg, t)!,
      userBubbleBorder: Color.lerp(userBubbleBorder, other.userBubbleBorder, t)!,
      inputBg: Color.lerp(inputBg, other.inputBg, t)!,
      inputBorder: Color.lerp(inputBorder, other.inputBorder, t)!,
      skeleton: Color.lerp(skeleton, other.skeleton, t)!,
      skeletonHighlight: Color.lerp(skeletonHighlight, other.skeletonHighlight, t)!,
    );
  }
}

/// Helper to get AppColors from context
extension AppColorsExt on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>() ?? AppColors.dark;
}
