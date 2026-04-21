import 'package:flutter/widgets.dart';
import 'package:google_fonts/google_fonts.dart';

/// Typography scale. Three families, one purpose each:
///   - display = Fraunces (variable serif) for hero titles
///   - ui      = Inter for every label / body / caption
///   - mono    = JetBrains Mono for code / numbers / kbd
///
/// Feature code must use these builders — never call GoogleFonts
/// directly.
class DsType {
  static TextStyle display({
    double size = 56,
    Color? color,
    double? height,
    FontWeight weight = FontWeight.w500,
  }) =>
      GoogleFonts.fraunces(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: -1.6,
        height: height ?? 1.02,
      );

  static TextStyle display2({
    double size = 32,
    Color? color,
    FontWeight weight = FontWeight.w600,
  }) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: -0.8,
        height: 1.18,
      );

  static TextStyle h1({Color? color}) => GoogleFonts.inter(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
        height: 1.25,
        color: color,
      );

  static TextStyle h2({Color? color}) => GoogleFonts.inter(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        height: 1.3,
        color: color,
      );

  static TextStyle h3({Color? color}) => GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
        height: 1.35,
        color: color,
      );

  static TextStyle body({Color? color}) => GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: color,
      );

  static TextStyle bodySm({Color? color}) => GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: color,
      );

  static TextStyle caption({Color? color}) => GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        height: 1.4,
        color: color,
      );

  static TextStyle micro({Color? color}) => GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        color: color,
      );

  static TextStyle label({Color? color}) => GoogleFonts.inter(
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        color: color,
      );

  static TextStyle button({Color? color}) => GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.05,
        color: color,
      );

  /// Uppercase, extra-tracked tag — used for "STEP 01 / 04" and
  /// section eyebrows. Copy should always be uppercase at source.
  static TextStyle eyebrow({Color? color}) => GoogleFonts.inter(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.6,
        color: color,
      );

  static TextStyle mono({double size = 13, Color? color}) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        color: color,
      );
}
