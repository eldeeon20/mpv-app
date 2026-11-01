import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pr_app/src/rust/frb_generated.dart';

bool _rustListo = false;
String _rustError = '';

/// Inicializa flutter_rust_bridge una sola vez y deja reintentar.
///
/// En Android la `.so` de Rust necesita `libc++_shared.so` (se empaqueta en
/// jniLibs/arm64-v8a): se precarga antes y, si falla, se intenta abrir la
/// propia librería con `DynamicLibrary.open` para tener el error real de
/// dlopen en vez del genérico "has not been initialized".
Future<bool> ensureRust() async {
  if (_rustListo) return true;

  if (Platform.isAndroid) {
    try {
      DynamicLibrary.open('libc++_shared.so');
    } catch (e) {
      debugPrint('libc++_shared.so: $e');
    }
  }

  try {
    await RustLib.init();
    _rustListo = true;
    _rustError = '';
    return true;
  } catch (e, s) {
    _rustError = '$e';
    debugPrint('Rust init error: $e');
    debugPrint('$s');

    // Segundo intento con apertura explícita: así el mensaje dice
    // exactamente qué falló (dlopen, símbolo, ABI, etc.).
    if (Platform.isAndroid) {
      try {
        DynamicLibrary.open('librust_lib_pr_app.so');
      } catch (e2) {
        _rustError = '$e\n$e2';
        debugPrint('dlopen librust_lib_pr_app.so: $e2');
      }
    }
    return false;
  }
}

bool get rustListo => _rustListo;

String rustErrorTexto() => _rustError;
