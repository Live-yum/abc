import 'package:flutter/material.dart';

abstract final class TerraColors {
  static const bg = Color(0xff0d151d),
      sidebar = Color(0xff111b23),
      card = Color(0xff17232d),
      border = Color(0xff2b3b45),
      text = Color(0xffecf2ef),
      muted = Color(0xff8da5a9),
      mint = Color(0xff9be7c1),
      amber = Color(0xfff0bd78),
      blue = Color(0xff93b5de),
      red = Color(0xffeb978b);
}

ThemeData terraTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: TerraColors.bg,
  colorScheme: const ColorScheme.dark(
    primary: TerraColors.mint,
    onPrimary: Color(0xff173b2b),
    surface: TerraColors.card,
    onSurface: TerraColors.text,
    error: TerraColors.red,
    outline: TerraColors.border,
  ),
  fontFamilyFallback: const [
    'Noto Sans CJK SC',
    'Microsoft YaHei',
    'PingFang SC',
  ],
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 13, height: 1.5),
    bodySmall: TextStyle(fontSize: 11, color: TerraColors.muted, height: 1.5),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    headlineMedium: TextStyle(
      fontSize: 27,
      fontWeight: FontWeight.w800,
      letterSpacing: -.7,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xff101c25),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
    labelStyle: const TextStyle(color: TerraColors.muted, fontSize: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: TerraColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: TerraColors.border),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 16),
      textStyle: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        fontFamily: 'Noto Sans CJK SC',
        fontFamilyFallback: ['Microsoft YaHei', 'PingFang SC'],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: TerraColors.text,
      side: const BorderSide(color: Color(0xff334650)),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 16),
      textStyle: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        fontFamily: 'Noto Sans CJK SC',
        fontFamilyFallback: ['Microsoft YaHei', 'PingFang SC'],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
  ),
  dividerTheme: const DividerThemeData(color: TerraColors.border, space: 25),
  chipTheme: ChipThemeData(
    backgroundColor: TerraColors.card,
    selectedColor: const Color(0xff29443e),
    side: const BorderSide(color: TerraColors.border),
    labelStyle: const TextStyle(fontSize: 11),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: TerraColors.sidebar,
    indicatorColor: Color(0xff29443e),
    labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 10)),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: TerraColors.card,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  ),
  tooltipTheme: const TooltipThemeData(
    waitDuration: Duration(milliseconds: 350),
  ),
);

class TerraPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const TerraPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xff17242d), Color(0xff14202a)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      border: Border.all(color: TerraColors.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: child,
  );
}

class TerraNotice extends StatelessWidget {
  final String text;
  final bool warning;
  final IconData icon;
  const TerraNotice(
    this.text, {
    super.key,
    this.warning = false,
    this.icon = Icons.shield_outlined,
  });
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: warning ? const Color(0xff302a23) : const Color(0xff182d29),
      border: Border.all(
        color: warning ? const Color(0xff5c4930) : const Color(0xff2f4b40),
      ),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 17,
          color: warning ? TerraColors.amber : TerraColors.mint,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.65,
              color: warning ? TerraColors.amber : const Color(0xffb9d9cb),
            ),
          ),
        ),
      ],
    ),
  );
}

class TerraPill extends StatelessWidget {
  final String text;
  final Color color;
  const TerraPill(this.text, {super.key, this.color = TerraColors.mint});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );
}

class TerraEmpty extends StatelessWidget {
  final String title, detail;
  final IconData icon;
  final Widget? action;
  const TerraEmpty(
    this.title,
    this.detail, {
    super.key,
    this.icon = Icons.folder_open_rounded,
    this.action,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: TerraColors.mint.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(icon, size: 32, color: TerraColors.muted),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    ),
  );
}
