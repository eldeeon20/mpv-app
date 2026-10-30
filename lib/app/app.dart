import 'package:flutter/material.dart';

import 'home_page.dart';

/// App principal: tema oscuro + HomePage.
class PrApp extends StatelessWidget {
  const PrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MPV Storage',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7DD3FC),
          brightness: Brightness.dark,
          surface: const Color(0xFF0B1422),
        ),
        scaffoldBackgroundColor: const Color(0xFF07111F),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF111D2D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}
