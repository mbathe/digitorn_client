import 'package:flutter/material.dart';

/// Design token palette consumed via `context.colors`.
///
/// Rules:
/// - No widget should hardcode `Color(0xFF...)` or `Colors.xxx`. Use
///   `context.colors.<token>` instead.
/// - `accentPrimary` / `accentSecondary` define the brand gradient
///   (used on CTAs, highlights, halos). `onAccent` is the text/icon
///   color on top of an accent surface.
/// - `overlay` is for modal scrims; `shadow` is the raw color used in
///   `BoxShadow` (already tuned for the palette's brightness).
class AppColors extends ThemeExtension<AppColors> {
  // ── Structure ───────────────────────────────────────────────────────────────
  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color borderHover;

  // ── Text ────────────────────────────────────────────────────────────────────
  final Color text;
  final Color textBright;
  final Color textMuted;
  final Color textDim;

  // ── Semantic / status ──────────────────────────────────────────────────────
  final Color green;
  final Color red;
  final Color orange;
  final Color blue;
  final Color cyan;
  final Color purple;

  // ── Brand / accent ─────────────────────────────────────────────────────────
  final Color accentPrimary;
  final Color accentSecondary;
  final Color onAccent;
  final Color glow;

  // ── Effects ────────────────────────────────────────────────────────────────
  final Color overlay;
  final Color shadow;

  // ── Code / editor ──────────────────────────────────────────────────────────
  final Color codeBlockBg;
  final Color codeBlockHeader;
  final Color codeBg;

  // ── Chat ───────────────────────────────────────────────────────────────────
  final Color userBubbleBg;
  final Color userBubbleBorder;

  // ── Input ──────────────────────────────────────────────────────────────────
  final Color inputBg;
  final Color inputBorder;

  // ── Skeleton loader ────────────────────────────────────────────────────────
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
    required this.accentPrimary,
    required this.accentSecondary,
    required this.onAccent,
    required this.glow,
    required this.overlay,
    required this.shadow,
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

  // ─── Palettes ──────────────────────────────────────────────────────────────
  //
  // Every palette must fill the SAME token set — no exceptions. Flip
  // between them via `ThemeService.setPalette()`.

  /// Default dark — neutral greys, blue/purple accent (current brand).
  static const dark = AppColors(
    bg: Color(0xFF0D0D0D),
    surface: Color(0xFF111111),
    surfaceAlt: Color(0xFF141414),
    border: Color(0xFF1E1E1E),
    borderHover: Color(0xFF333333),
    text: Color(0xFFD4D4D4),
    textBright: Color(0xFFE6E6E6),
    textMuted: Color(0xFF8A8A8A),
    textDim: Color(0xFF5A5A5A),
    green: Color(0xFF22C55E),
    red: Color(0xFFEF4444),
    orange: Color(0xFFF59E0B),
    blue: Color(0xFF3B82F6),
    cyan: Color(0xFF06B6D4),
    purple: Color(0xFFA78BFA),
    accentPrimary: Color(0xFFA78BFA),
    accentSecondary: Color(0xFF3B82F6),
    onAccent: Color(0xFFFFFFFF),
    glow: Color(0xFF3B82F6),
    overlay: Color(0xCC000000),
    shadow: Color(0x66000000),
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

  /// VS Code Light — light defaults, indigo/purple accent.
  static const light = AppColors(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFF8F8F8),
    surfaceAlt: Color(0xFFF1F1F1),
    border: Color(0xFFE2E2E2),
    borderHover: Color(0xFFB8B8B8),
    text: Color(0xFF333333),
    textBright: Color(0xFF0B0B0B),
    textMuted: Color(0xFF6E6E6E),
    textDim: Color(0xFFA8A8A8),
    green: Color(0xFF16A34A),
    red: Color(0xFFDC2626),
    orange: Color(0xFFB45309),
    blue: Color(0xFF2563EB),
    cyan: Color(0xFF0891B2),
    purple: Color(0xFF7C3AED),
    accentPrimary: Color(0xFF7C3AED),
    accentSecondary: Color(0xFF2563EB),
    onAccent: Color(0xFFFFFFFF),
    glow: Color(0xFF7C3AED),
    overlay: Color(0x661F1F1F),
    shadow: Color(0x1A000000),
    codeBlockBg: Color(0xFFF5F5F5),
    codeBlockHeader: Color(0xFFEAEAEA),
    codeBg: Color(0xFFF0E6FF),
    userBubbleBg: Color(0xFFF0F4FA),
    userBubbleBorder: Color(0xFFDDE5F0),
    inputBg: Color(0xFFFFFFFF),
    inputBorder: Color(0xFFCECECE),
    skeleton: Color(0xFFE0E0E0),
    skeletonHighlight: Color(0xFFEEEEEE),
  );

  /// Obsidian Dark — signature Digitorn palette. Warm charcoal with
  /// coral + amber accent. Distinctive vs the generic blue/purple
  /// of every other AI tool. Pairs with [obsidianLight].
  static const obsidianDark = AppColors(
    bg: Color(0xFF0C0B09),
    surface: Color(0xFF131210),
    surfaceAlt: Color(0xFF1A1815),
    border: Color(0xFF24211D),
    borderHover: Color(0xFF3A342D),
    text: Color(0xFFC9C1B5),
    textBright: Color(0xFFF2EBDE),
    textMuted: Color(0xFF827A6E),
    textDim: Color(0xFF524C44),
    green: Color(0xFF5FAC87),
    red: Color(0xFFE66C5B),
    orange: Color(0xFFE8A850),
    blue: Color(0xFF689EAC),
    cyan: Color(0xFF7DB5B0),
    purple: Color(0xFFA08EA8),
    accentPrimary: Color(0xFFF26A4A),
    accentSecondary: Color(0xFFE8A850),
    onAccent: Color(0xFF0C0B09),
    glow: Color(0xFFF26A4A),
    overlay: Color(0xCC0C0B09),
    shadow: Color(0x66000000),
    codeBlockBg: Color(0xFF0F0E0C),
    codeBlockHeader: Color(0xFF181613),
    codeBg: Color(0xFF1C1815),
    userBubbleBg: Color(0xFF1A1815),
    userBubbleBorder: Color(0xFF2A2620),
    inputBg: Color(0xFF131210),
    inputBorder: Color(0xFF2A2620),
    skeleton: Color(0xFF1E1B17),
    skeletonHighlight: Color(0xFF2A2620),
  );

  /// Obsidian Light — cream/paper background, same coral accent
  /// tuned for contrast against light surfaces.
  static const obsidianLight = AppColors(
    bg: Color(0xFFFBFAF7),
    surface: Color(0xFFF6F3EC),
    surfaceAlt: Color(0xFFEFEBE1),
    border: Color(0xFFE5E0D3),
    borderHover: Color(0xFFCDC5B3),
    text: Color(0xFF3A342D),
    textBright: Color(0xFF1A1815),
    textMuted: Color(0xFF76706A),
    textDim: Color(0xFFA89F90),
    green: Color(0xFF3F8766),
    red: Color(0xFFC7432F),
    orange: Color(0xFFB8821A),
    blue: Color(0xFF4B7582),
    cyan: Color(0xFF5D8E88),
    purple: Color(0xFF7D6E87),
    accentPrimary: Color(0xFFD8553A),
    accentSecondary: Color(0xFFB8821A),
    onAccent: Color(0xFFFBFAF7),
    glow: Color(0xFFD8553A),
    overlay: Color(0x661A1815),
    shadow: Color(0x1A000000),
    codeBlockBg: Color(0xFFF4F0E5),
    codeBlockHeader: Color(0xFFEFEBE1),
    codeBg: Color(0xFFF9F6EE),
    userBubbleBg: Color(0xFFF4F0E5),
    userBubbleBorder: Color(0xFFE5E0D3),
    inputBg: Color(0xFFFBFAF7),
    inputBorder: Color(0xFFD9D3C4),
    skeleton: Color(0xFFEFEBE1),
    skeletonHighlight: Color(0xFFF6F3EC),
  );

  /// Midnight — deep navy, cyan accent. Moodier than default dark.
  static const midnight = AppColors(
    bg: Color(0xFF0A0E1A),
    surface: Color(0xFF0F1524),
    surfaceAlt: Color(0xFF141C30),
    border: Color(0xFF1C2542),
    borderHover: Color(0xFF2C3A5E),
    text: Color(0xFFCBD5E1),
    textBright: Color(0xFFE8EEF9),
    textMuted: Color(0xFF7B8BA8),
    textDim: Color(0xFF4F5E7A),
    green: Color(0xFF34D399),
    red: Color(0xFFF87171),
    orange: Color(0xFFFBBF24),
    blue: Color(0xFF60A5FA),
    cyan: Color(0xFF22D3EE),
    purple: Color(0xFFC4B5FD),
    accentPrimary: Color(0xFF22D3EE),
    accentSecondary: Color(0xFF6366F1),
    onAccent: Color(0xFF0A0E1A),
    glow: Color(0xFF22D3EE),
    overlay: Color(0xCC05080F),
    shadow: Color(0x80050810),
    codeBlockBg: Color(0xFF0C1120),
    codeBlockHeader: Color(0xFF121A2C),
    codeBg: Color(0xFF12172B),
    userBubbleBg: Color(0xFF111A2E),
    userBubbleBorder: Color(0xFF1B2848),
    inputBg: Color(0xFF0C1220),
    inputBorder: Color(0xFF1D2742),
    skeleton: Color(0xFF14203A),
    skeletonHighlight: Color(0xFF1E2C4A),
  );

  /// OLED black — true black for OLED displays, pink/violet accent.
  static const oled = AppColors(
    bg: Color(0xFF000000),
    surface: Color(0xFF070707),
    surfaceAlt: Color(0xFF0C0C0C),
    border: Color(0xFF1A1A1A),
    borderHover: Color(0xFF2E2E2E),
    text: Color(0xFFD8D8D8),
    textBright: Color(0xFFFFFFFF),
    textMuted: Color(0xFF7A7A7A),
    textDim: Color(0xFF4A4A4A),
    green: Color(0xFF22D78C),
    red: Color(0xFFFF5A5A),
    orange: Color(0xFFFFB020),
    blue: Color(0xFF4FA3FF),
    cyan: Color(0xFF22E5F2),
    purple: Color(0xFFC084FC),
    accentPrimary: Color(0xFFF472B6),
    accentSecondary: Color(0xFFC084FC),
    onAccent: Color(0xFF000000),
    glow: Color(0xFFF472B6),
    overlay: Color(0xD9000000),
    shadow: Color(0x80000000),
    codeBlockBg: Color(0xFF050505),
    codeBlockHeader: Color(0xFF0C0C0C),
    codeBg: Color(0xFF120818),
    userBubbleBg: Color(0xFF0B0B0B),
    userBubbleBorder: Color(0xFF1A1A1A),
    inputBg: Color(0xFF050505),
    inputBorder: Color(0xFF181818),
    skeleton: Color(0xFF141414),
    skeletonHighlight: Color(0xFF242424),
  );

  /// Nord — arctic, frost palette. Calm and low-contrast.
  static const nord = AppColors(
    bg: Color(0xFF2E3440),
    surface: Color(0xFF3B4252),
    surfaceAlt: Color(0xFF434C5E),
    border: Color(0xFF4C566A),
    borderHover: Color(0xFF5E6A82),
    text: Color(0xFFD8DEE9),
    textBright: Color(0xFFECEFF4),
    textMuted: Color(0xFF9AA5B8),
    textDim: Color(0xFF6B7586),
    green: Color(0xFFA3BE8C),
    red: Color(0xFFBF616A),
    orange: Color(0xFFD08770),
    blue: Color(0xFF81A1C1),
    cyan: Color(0xFF88C0D0),
    purple: Color(0xFFB48EAD),
    accentPrimary: Color(0xFF88C0D0),
    accentSecondary: Color(0xFF81A1C1),
    onAccent: Color(0xFF2E3440),
    glow: Color(0xFF88C0D0),
    overlay: Color(0xCC1F242E),
    shadow: Color(0x802E3440),
    codeBlockBg: Color(0xFF2B313C),
    codeBlockHeader: Color(0xFF353B47),
    codeBg: Color(0xFF353B47),
    userBubbleBg: Color(0xFF3B4252),
    userBubbleBorder: Color(0xFF4C566A),
    inputBg: Color(0xFF2B313C),
    inputBorder: Color(0xFF434C5E),
    skeleton: Color(0xFF3B4252),
    skeletonHighlight: Color(0xFF4C566A),
  );

  /// Solarized Light — warm beige background, teal/cyan accent.
  static const solarized = AppColors(
    bg: Color(0xFFFDF6E3),
    surface: Color(0xFFFAF2DC),
    surfaceAlt: Color(0xFFEEE8D5),
    border: Color(0xFFE2DBC2),
    borderHover: Color(0xFFC4BCA1),
    text: Color(0xFF586E75),
    textBright: Color(0xFF073642),
    textMuted: Color(0xFF93A1A1),
    textDim: Color(0xFFB8B39A),
    green: Color(0xFF859900),
    red: Color(0xFFDC322F),
    orange: Color(0xFFCB4B16),
    blue: Color(0xFF268BD2),
    cyan: Color(0xFF2AA198),
    purple: Color(0xFF6C71C4),
    accentPrimary: Color(0xFF2AA198),
    accentSecondary: Color(0xFF268BD2),
    onAccent: Color(0xFFFDF6E3),
    glow: Color(0xFF2AA198),
    overlay: Color(0x66073642),
    shadow: Color(0x1F073642),
    codeBlockBg: Color(0xFFF5EFD8),
    codeBlockHeader: Color(0xFFEEE8D5),
    codeBg: Color(0xFFF5EFD8),
    userBubbleBg: Color(0xFFF5EFD8),
    userBubbleBorder: Color(0xFFE2DBC2),
    inputBg: Color(0xFFFDF6E3),
    inputBorder: Color(0xFFD5CEB4),
    skeleton: Color(0xFFEEE8D5),
    skeletonHighlight: Color(0xFFF5EFD8),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceAlt,
    Color? border,
    Color? borderHover,
    Color? text,
    Color? textBright,
    Color? textMuted,
    Color? textDim,
    Color? green,
    Color? red,
    Color? orange,
    Color? blue,
    Color? cyan,
    Color? purple,
    Color? accentPrimary,
    Color? accentSecondary,
    Color? onAccent,
    Color? glow,
    Color? overlay,
    Color? shadow,
    Color? codeBlockBg,
    Color? codeBlockHeader,
    Color? codeBg,
    Color? userBubbleBg,
    Color? userBubbleBorder,
    Color? inputBg,
    Color? inputBorder,
    Color? skeleton,
    Color? skeletonHighlight,
  }) =>
      AppColors(
        bg: bg ?? this.bg,
        surface: surface ?? this.surface,
        surfaceAlt: surfaceAlt ?? this.surfaceAlt,
        border: border ?? this.border,
        borderHover: borderHover ?? this.borderHover,
        text: text ?? this.text,
        textBright: textBright ?? this.textBright,
        textMuted: textMuted ?? this.textMuted,
        textDim: textDim ?? this.textDim,
        green: green ?? this.green,
        red: red ?? this.red,
        orange: orange ?? this.orange,
        blue: blue ?? this.blue,
        cyan: cyan ?? this.cyan,
        purple: purple ?? this.purple,
        accentPrimary: accentPrimary ?? this.accentPrimary,
        accentSecondary: accentSecondary ?? this.accentSecondary,
        onAccent: onAccent ?? this.onAccent,
        glow: glow ?? this.glow,
        overlay: overlay ?? this.overlay,
        shadow: shadow ?? this.shadow,
        codeBlockBg: codeBlockBg ?? this.codeBlockBg,
        codeBlockHeader: codeBlockHeader ?? this.codeBlockHeader,
        codeBg: codeBg ?? this.codeBg,
        userBubbleBg: userBubbleBg ?? this.userBubbleBg,
        userBubbleBorder: userBubbleBorder ?? this.userBubbleBorder,
        inputBg: inputBg ?? this.inputBg,
        inputBorder: inputBorder ?? this.inputBorder,
        skeleton: skeleton ?? this.skeleton,
        skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
      );

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
      accentPrimary: Color.lerp(accentPrimary, other.accentPrimary, t)!,
      accentSecondary:
          Color.lerp(accentSecondary, other.accentSecondary, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      glow: Color.lerp(glow, other.glow, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      codeBlockBg: Color.lerp(codeBlockBg, other.codeBlockBg, t)!,
      codeBlockHeader: Color.lerp(codeBlockHeader, other.codeBlockHeader, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      userBubbleBg: Color.lerp(userBubbleBg, other.userBubbleBg, t)!,
      userBubbleBorder:
          Color.lerp(userBubbleBorder, other.userBubbleBorder, t)!,
      inputBg: Color.lerp(inputBg, other.inputBg, t)!,
      inputBorder: Color.lerp(inputBorder, other.inputBorder, t)!,
      skeleton: Color.lerp(skeleton, other.skeleton, t)!,
      skeletonHighlight:
          Color.lerp(skeletonHighlight, other.skeletonHighlight, t)!,
    );
  }
}

/// Named palette identifiers — each maps to a dark + light pair via
/// `AppPalettes.resolve()`. Persisted as a string in prefs.
enum AppPalette {
  defaultTheme,
  obsidian,
  midnight,
  oled,
  nord,
  solarized,
}

extension AppPaletteX on AppPalette {
  String get id => switch (this) {
        AppPalette.defaultTheme => 'default',
        AppPalette.obsidian => 'obsidian',
        AppPalette.midnight => 'midnight',
        AppPalette.oled => 'oled',
        AppPalette.nord => 'nord',
        AppPalette.solarized => 'solarized',
      };

  String get label => switch (this) {
        AppPalette.defaultTheme => 'Default',
        AppPalette.obsidian => 'Obsidian',
        AppPalette.midnight => 'Midnight',
        AppPalette.oled => 'OLED Black',
        AppPalette.nord => 'Nord',
        AppPalette.solarized => 'Solarized',
      };

  String get description => switch (this) {
        AppPalette.defaultTheme => 'Neutral greys with indigo/blue accent',
        AppPalette.obsidian => 'Warm charcoal with coral + amber accent',
        AppPalette.midnight => 'Deep navy with cyan accent',
        AppPalette.oled => 'True black, pink/violet accent',
        AppPalette.nord => 'Arctic frost, low contrast',
        AppPalette.solarized => 'Warm beige, teal accent (light only)',
      };

  /// Whether this palette provides a meaningful dark variant. Some
  /// palettes (Solarized Light) only ship a light look.
  bool get hasDark => this != AppPalette.solarized;

  /// Whether this palette provides a meaningful light variant.
  bool get hasLight => this == AppPalette.defaultTheme ||
      this == AppPalette.obsidian ||
      this == AppPalette.solarized;
}

class AppPalettes {
  static AppPalette parse(String? id) {
    return switch (id) {
      'obsidian' => AppPalette.obsidian,
      'midnight' => AppPalette.midnight,
      'oled' => AppPalette.oled,
      'nord' => AppPalette.nord,
      'solarized' => AppPalette.solarized,
      _ => AppPalette.defaultTheme,
    };
  }

  /// Resolve the concrete [AppColors] for a (palette, brightness) pair.
  /// Falls back to `AppColors.dark` / `AppColors.light` whenever a
  /// palette doesn't define that brightness.
  static AppColors resolve(AppPalette palette, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (palette) {
      AppPalette.defaultTheme => dark ? AppColors.dark : AppColors.light,
      AppPalette.obsidian =>
        dark ? AppColors.obsidianDark : AppColors.obsidianLight,
      AppPalette.midnight => dark ? AppColors.midnight : AppColors.light,
      AppPalette.oled => dark ? AppColors.oled : AppColors.light,
      AppPalette.nord => dark ? AppColors.nord : AppColors.light,
      AppPalette.solarized =>
        dark ? AppColors.dark : AppColors.solarized,
    };
  }
}

/// Helper to get AppColors from context. Falls back to the default
/// dark palette if the theme extension is missing (tests, errors).
extension AppColorsExt on BuildContext {
  AppColors get colors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.dark;
}

/// Returns a foreground color (dark or light) that reads well on top
/// of [bg]. Picks between this palette's `textBright` (high contrast
/// on its own surfaces) and `onAccent` (designed to sit on accent
/// surfaces) based on [bg]'s perceived luminance. Use this for any
/// widget whose background is a semantic color (red error banner,
/// orange warning pill) so it still reads in every palette.
extension ColorContrastExt on AppColors {
  Color contrastOn(Color bg) {
    return bg.computeLuminance() > 0.5 ? textBright : onAccent;
  }
}
