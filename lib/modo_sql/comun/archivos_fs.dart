import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'campos.dart';

/// Sistema de archivos: permisos, elegir carpeta y guardar copia.

/// Sin esto Android devuelve la carpeta VACÍA ("no trae archivos").
Future<bool> accesoCarpeta() async {
  if (!Platform.isAndroid) return true;
  try {
    var st = await Permission.manageExternalStorage.status;
    if (!st.isGranted) {
      st = await Permission.manageExternalStorage.request();
    }
    if (st.isGranted) return true;
    var s2 = await Permission.storage.status;
    if (!s2.isGranted) {
      s2 = await Permission.storage.request();
    }
    return s2.isGranted;
  } catch (_) {
    return false;
  }
}

/// Abre Ajustes de la app (para dar "todos los archivos" a mano).
Future<void> abrirAjustes() async {
  try {
    await openAppSettings();
  } catch (_) {}
}

/// Carpeta elegida o null.
Future<String?> elegirCarpeta() async {
  try {
    final p = await FilePicker.platform.getDirectoryPath();
    if (p != null && p.isNotEmpty) return p;
    return null;
  } catch (_) {
    return null;
  }
}

/// Guarda bytes ya descifrados en Descargas (no re-pide al molde).
Future<void> guardarCopia({
  required String nombre,
  required Uint8List datos,
  required void Function(String s) log,
}) async {
  try {
    if (!await accesoCarpeta()) {
      log('✗ sin permiso de almacenamiento para la copia');
      return;
    }
    Directory dir;
    if (Platform.isAndroid) {
      final descargas = Directory('/storage/emulated/0/Download');
      if (await descargas.exists()) {
        dir = descargas;
      } else {
        dir = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
      }
    } else {
      dir = await getApplicationDocumentsDirectory();
    }
    final base = nombre.split('/').last;
    final dest = File('${dir.path}/$base');
    await dest.writeAsBytes(datos, flush: true);
    log('✓ copia de "$base" en ${dest.path} (${fmtBytes(datos.length)})');
  } catch (e) {
    log('✗ guardar copia: $e');
  }
}
