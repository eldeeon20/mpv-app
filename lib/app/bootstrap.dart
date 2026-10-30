import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pr_app/src/rust/frb_generated.dart';

import '../media/media_library.dart';
import '../services/settings.dart';

/// Arranque mínimo de MPV App: sin Colab, sin Tor, sin GPU.
/// Rust se inicializa igual (pkarr/nostr/shamir/unarc lo necesitan).
Future<void> initApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  try {
    await RustLib.init();
  } catch (e) {
    debugPrint('Rust init error: $e');
  }

  try {
    await Settings.instance.load().timeout(const Duration(seconds: 15));
  } catch (e) {
    debugPrint('Settings init error: $e');
  }

  try {
    await MediaLibraryStore.instance
        .load()
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    debugPrint('MediaLibrary init error: $e');
  }
}
