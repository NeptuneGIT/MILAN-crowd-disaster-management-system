import 'package:flutter/material.dart';

/// The app's colours, in one place (taken from the approved mockup).
/// One brand colour (orange shades) on warm neutrals; oxblood only for "missing".
const kO1 = Color(0xFFFDE6C8); // tint: chips, found panel
const kO2 = Color(0xFFF9CE97); // active tab, hover
const kHeader = Color(0xFFEE8A1E); // header
const kO4 = Color(0xFFEC9533); // primary buttons
const kInk = Color(0xFF2B1600); // text on orange, headings
const kText = Color(0xFF1F1A14);
const kMuted = Color(0xFF5B5249);
const kGround = Color(0xFFF6F2EA);
const kPaper = Color(0xFFFFFCF6);
const kBorder = Color(0xFFDCD2C4);
const kChipGrey = Color(0xFFE9E4DA); // neutral badge (e.g. "not missing", stale)
const kDanger = Color(0xFF8E2417); // missing
const kDangerTint = Color(0xFFF4E4DF);
const kDangerInk = Color(0xFF5E140B);

/// Card surface: paper fill, hairline border.
BoxDecoration cardDecoration({double radius = 16}) => BoxDecoration(
  color: kPaper,
  border: Border.all(color: kBorder),
  borderRadius: BorderRadius.circular(radius),
);

/// The big, full-width action button (56 px tall, rounded). Pass as `style:` to a Filled/OutlinedButton.
const kBigButton = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size.fromHeight(56)),
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)))),
);

ThemeData milanTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kO4,
  ).copyWith(primary: kO4, onPrimary: kInk, surface: kGround, onSurface: kText, error: kDanger);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: kGround,
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: kO1,
        foregroundColor: kInk,
        side: const BorderSide(color: kO4, width: 1.5),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kPaper,
      indicatorColor: kO2,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
