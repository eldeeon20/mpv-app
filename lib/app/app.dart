import 'package:flutter/material.dart';

import 'home_page.dart';
import 'rust_init.dart';

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
      // Si Rust no inicializó, se ve el motivo real (antes solo iba a
      // debugPrint y todo fallaba después con "has not been initialized").
      builder: (context, child) => rustListo
          ? (child ?? const SizedBox.shrink())
          : Column(
              children: [
                MaterialBanner(
                  backgroundColor: const Color(0xFF7F1D1D),
                  content: Text(
                    'Rust no inicializó: ${rustErrorTexto()}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        await ensureRust();
                      },
                      child: const Text('Reintentar',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
                Expanded(child: child ?? const SizedBox.shrink()),
              ],
            ),
      home: const HomePage(),
    );
  }
}

