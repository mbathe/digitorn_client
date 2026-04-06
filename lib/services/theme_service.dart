import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';

class ThemeService extends ChangeNotifier {
  static final ThemeService _i = ThemeService._();
  factory ThemeService() => _i;
  ThemeService._();

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;
  bool get isDark => _mode == ThemeMode.dark;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('theme_mode');
    _mode = v == 'light' ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
  }

  Future<void> toggle() async {
    _mode = isDark ? ThemeMode.light : ThemeMode.dark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', isDark ? 'dark' : 'light');
    notifyListeners();
  }

  static final darkTheme = ThemeData.dark(useMaterial3: true).copyWith(
    scaffoldBackgroundColor: AppColors.dark.bg,
    colorScheme: const ColorScheme.dark(
      surface: Color(0xFF111111),
      primary: Color(0xFF5769F7),
      error: Color(0xFFEF4444),
    ),
    dividerColor: AppColors.dark.border,
    cardColor: AppColors.dark.surfaceAlt,
    dialogBackgroundColor: const Color(0xFF161616),
    extensions: const [AppColors.dark],
  );

  static final lightTheme = ThemeData.light(useMaterial3: true).copyWith(
    scaffoldBackgroundColor: AppColors.light.bg,
    colorScheme: const ColorScheme.light(
      surface: Color(0xFFFFFFFF),
      primary: Color(0xFF4F46E5),
      error: Color(0xFFDC2626),
    ),
    dividerColor: AppColors.light.border,
    cardColor: AppColors.light.surfaceAlt,
    dialogBackgroundColor: const Color(0xFFFFFFFF),
    extensions: const [AppColors.light],
  );
}
