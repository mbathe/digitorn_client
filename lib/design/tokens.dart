import 'package:flutter/widgets.dart';

/// Spacing scale on a 4pt grid.
class DsSpacing {
  static const double x0 = 0;
  static const double x1 = 2;
  static const double x2 = 4;
  static const double x3 = 8;
  static const double x4 = 12;
  static const double x5 = 16;
  static const double x6 = 20;
  static const double x7 = 24;
  static const double x8 = 32;
  static const double x9 = 40;
  static const double x10 = 48;
  static const double x11 = 64;
  static const double x12 = 80;
  static const double x13 = 96;
  static const double x14 = 128;
}

/// Corner radii — four tiers only.
class DsRadius {
  static const double xs = 6;
  static const double input = 10;
  static const double card = 14;
  static const double modal = 20;
  static const double pill = 999;
}

/// Durations. Don't invent intermediate values.
class DsDuration {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 360);
  static const Duration stagger = Duration(milliseconds: 80);
  static const Duration hero = Duration(milliseconds: 640);
  static const Duration ambient = Duration(seconds: 24);
}

/// Viewport breakpoints.
class DsBreakpoint {
  static const double xs = 360;
  static const double sm = 480;
  static const double md = 720;
  static const double lg = 1024;
  static const double xl = 1280;

  static bool isCompact(BuildContext ctx) =>
      MediaQuery.of(ctx).size.width < md;
  static bool isXs(BuildContext ctx) =>
      MediaQuery.of(ctx).size.width < sm;
}

/// Shared stroke widths — rings, borders.
class DsStroke {
  static const double hairline = 1.0;
  static const double normal = 1.2;
  static const double thick = 1.6;
}
