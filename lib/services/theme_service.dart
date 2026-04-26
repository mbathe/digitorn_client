import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';

/// Owns the active (brightness, palette) pair.
///
/// Two independent axes:
/// - `mode` — `ThemeMode.dark` / `.light` / `.system` (resolves to
///   the platform brightness).
/// - `palette` — the named visual style (`default`, `midnight`,
///   `oled`, `nord`, `solarized`).
///
/// Both are persisted in `SharedPreferences`. Widgets read the active
/// palette via `context.colors`; Flutter resolves the right
/// `AppColors` because we register BOTH brightness variants as theme
/// extensions on the MaterialApp.
class ThemeService extends ChangeNotifier {
  static const _kMode = 'theme_mode';
  static const _kPalette = 'theme_palette';

  static final ThemeService _i = ThemeService._();
  factory ThemeService() => _i;
  ThemeService._();

  ThemeMode _mode = ThemeMode.dark;
  AppPalette _palette = AppPalette.defaultTheme;

  ThemeMode get mode => _mode;
  AppPalette get palette => _palette;

  /// Reflects the *resolved* brightness — when [_mode] is `system`,
  /// asks the platform; when it's an explicit choice, returns it.
  /// UI code that renders a dark/light asset should branch on this
  /// instead of `_mode == ThemeMode.dark` directly.
  bool get isDark {
    if (_mode == ThemeMode.system) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return brightness == Brightness.dark;
    }
    return _mode == ThemeMode.dark;
  }

  /// The concrete AppColors for the current (mode, palette) pair.
  /// Rarely needed by UI code (which should go through
  /// `context.colors`) but useful for places that build a theme at
  /// init time (eg. Monaco editor background).
  AppColors get colors => AppPalettes.resolve(
        _palette,
        isDark ? Brightness.dark : Brightness.light,
      );

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = switch (prefs.getString(_kMode)) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    _palette = AppPalettes.parse(prefs.getString(_kPalette));
    notifyListeners();
  }

  /// Cycles dark → light → system → dark. Kept for the legacy
  /// "toggle" affordance in the activity bar.
  Future<void> toggle() async {
    _mode = switch (_mode) {
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.light => ThemeMode.system,
      ThemeMode.system => ThemeMode.dark,
    };
    await _saveMode();
    notifyListeners();
  }

  /// Set explicitly from the Appearance section's segmented button.
  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    await _saveMode();
    notifyListeners();
  }

  Future<void> setPalette(AppPalette palette) async {
    if (_palette == palette) return;
    _palette = palette;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPalette, palette.id);
    notifyListeners();
  }

  Future<void> _saveMode() async {
    final prefs = await SharedPreferences.getInstance();
    final code = switch (_mode) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    };
    await prefs.setString(_kMode, code);
  }

  // ─── ThemeData builders ────────────────────────────────────────────────────

  /// Build the `ThemeData` for the current palette in the given
  /// brightness. Both are registered on `MaterialApp` so Flutter can
  /// hot-swap when `themeMode` changes without a reload.
  ///
  /// [density] modulates Material widgets (buttons, list tiles,
  /// inputs…) via `VisualDensity`. Passed in by the caller because
  /// the value lives in `PreferencesService`, not here. Mirror of
  /// the web `data-density` attribute on `<html>`.
  ThemeData buildTheme(Brightness brightness, {String density = 'comfortable'}) {
    final colors = AppPalettes.resolve(_palette, brightness);
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: colors.bg,
      visualDensity: visualDensityFor(density),
      colorScheme: (brightness == Brightness.dark
              ? ColorScheme.dark(
                  surface: colors.surface,
                  primary: colors.accentPrimary,
                  secondary: colors.accentSecondary,
                  error: colors.red,
                  onPrimary: colors.onAccent,
                )
              : ColorScheme.light(
                  surface: colors.surface,
                  primary: colors.accentPrimary,
                  secondary: colors.accentSecondary,
                  error: colors.red,
                  onPrimary: colors.onAccent,
                ))
          .copyWith(
        onSurface: colors.text,
      ),
      dividerColor: colors.border,
      cardColor: colors.surfaceAlt,
      dialogTheme: DialogThemeData(backgroundColor: colors.surface),
      extensions: [colors],
    );
  }

  /// Resolve a `VisualDensity` from the `compact|comfortable|spacious`
  /// preference. Compact uses Material's built-in compact preset
  /// (-2,-2). Spacious adds +1 horizontal/vertical for breathing room.
  /// Comfortable sticks to the platform default (`adaptivePlatformDensity`)
  /// so we don't fight Flutter's own per-OS tuning.
  static VisualDensity visualDensityFor(String density) {
    switch (density) {
      case 'compact':
        return VisualDensity.compact;
      case 'spacious':
        return const VisualDensity(horizontal: 1, vertical: 1);
      default:
        return VisualDensity.adaptivePlatformDensity;
    }
  }

  /// Linear text-scale factor matching web's html font-size scaling
  /// (16 / 14.5 / 17.5). Used by `MaterialApp.builder` to wrap the
  /// child in a `MediaQuery` with this scaler so all text sizes
  /// across the tree (Material + custom widgets) react.
  static double textScaleFor(String density) {
    switch (density) {
      case 'compact':
        return 14.5 / 16;
      case 'spacious':
        return 17.5 / 16;
      default:
        return 1.0;
    }
  }

  /// Legacy accessor — prefer `buildTheme(Brightness.dark)` so the
  /// active palette is respected. Kept for any call site that still
  /// references the old constant.
  static ThemeData get darkTheme => ThemeService().buildTheme(Brightness.dark);
  static ThemeData get lightTheme => ThemeService().buildTheme(Brightness.light);
}
