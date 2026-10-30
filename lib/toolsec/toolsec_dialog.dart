import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

import '../services/crypto_vault.dart';
import 'toolsec.dart';

/// Diálogo ToolSec: cifra/descifra archivos con XOR por semilla.
/// Modo LOTE v2 (igual que golo): `PRBX(maestro, [LOTE][len][pass][datos])`.
/// Cifrar lote pide maestro + pass del lote; abrir lote pide el maestro
/// y muestra la pass del lote + guarda el contenido.
///
/// Android (SAF): cifra SOBRE el archivo real elegido (Descargas, etc).
/// Si no puede escribir, pregunta si querés guardar una copia cifrada.
Future<void> showToolSecDialog(BuildContext context) async {
  final seedCtrl = TextEditingController();
  final maestroCtrl = TextEditingController();
  final loteCtrl = TextEditingController();
  SafDocumentFile? safDoc;
  String? filePath;
  String? fileName;
  bool processing = false;
  bool esLote = false;
  String? resultMsg;
  String? hexPreview;

  Future<void> doEncrypt(void Function(void Function()) setDlgState) async {
    setDlgState(() {
      processing = true;
      resultMsg = null;
      hexPreview = null;
    });
    try {
      final ts = ToolSec(seedCtrl.text);

      if (Platform.isAndroid && safDoc != null) {
        // ---- Android SAF: in-place sobre el archivo real ----
        try {
          final outName = await ts.encodeSafInPlace(safDoc!);
          final head =
              await SafStream().readFileBytes(safDoc!.uri, start: 0, count: 50);
          setDlgState(() {
            resultMsg = 'Cifrado sobre el archivo original:\n$outName';
            hexPreview = _toHex(head);
          });
        } on ToolSecCantWriteException catch (e) {
          // No se pudo escribir sobre el original → ofrecer copia
          if (!context.mounted) return;
          final wantsCopy = await _askForCopy(context, e.reason);
          if (wantsCopy != true) {
            setDlgState(() =>
                resultMsg = 'Cancelado: no se modificó ningún archivo');
            return;
          }
          try {
            final saved =
                await ToolSec.saveSafCopy(e.encrypted, '${safDoc!.name}.sec');
            setDlgState(() {
              resultMsg = 'Copia cifrada guardada como:\n$saved';
              hexPreview = _toHex(e.encrypted.take(50));
            });
          } catch (err) {
            setDlgState(() => resultMsg = 'Error guardando copia: $err');
          }
        }
      } else if (filePath != null) {
        // ---- Desktop / rutas directas: in-place primero ----
        final file = File(filePath!);
        final data = ts.processBytes(file.readAsBytesSync());
        try {
          file.writeAsBytesSync(data);
          setDlgState(() {
            resultMsg = 'Cifrado sobre el archivo original:\n$filePath';
            hexPreview = _toHex(data.take(50));
          });
        } catch (e) {
          // Fallback: copia en carpeta interna
          final copyPath = await _saveInternalCopy(filePath!, data);
          setDlgState(() {
            resultMsg =
                'No se pudo escribir sobre el original.\n'
                'Copia cifrada guardada en:\n$copyPath\n($e)';
            hexPreview = _toHex(data.take(50));
          });
        }
      }
    } catch (e) {
      setDlgState(() => resultMsg = 'Error: $e');
    } finally {
      setDlgState(() => processing = false);
    }
  }

  /// Lee el archivo elegido completo (SAF por tramos o ruta directa).
  Future<Uint8List?> leerElegido() async {
    if (Platform.isAndroid && safDoc != null) {
      final out = BytesBuilder();
      var start = 0;
      const paso = 1024 * 1024;
      while (true) {
        final t = await SafStream()
            .readFileBytes(safDoc!.uri, start: start, count: paso);
        final b = Uint8List.fromList(t);
        if (b.isEmpty) break;
        out.add(b);
        if (b.length < paso) break;
        start += b.length;
      }
      return out.toBytes();
    }
    if (filePath != null) {
      return await File(filePath!).readAsBytes();
    }
    return null;
  }

  /// Lote v2: pega pass + archivo y cifra con el maestro → copia .prbx.
  /// Nunca toca el original (el nombre sale del contenido en HF/golo).
  Future<void> doLoteEnc(void Function(void Function()) setDlgState) async {
    setDlgState(() {
      processing = true;
      resultMsg = null;
      hexPreview = null;
    });
    try {
      final raw = await leerElegido();
      if (raw == null || raw.isEmpty) {
        setDlgState(() => resultMsg = 'Elegí un archivo primero');
        return;
      }
      final ts = ToolSec('lote');
      final enc = await ts.processLoteStrong(
          raw, maestroCtrl.text, loteCtrl.text);
      final base = (fileName ?? 'lote').split('/').last;
      final saved = (Platform.isAndroid && safDoc != null)
          ? await ToolSec.saveSafCopy(enc, '$base.prbx')
          : await _saveInternalCopy('$base.prbx', enc);
      setDlgState(() {
        resultMsg = 'Lote v2 guardado como:\n$saved';
        hexPreview = _toHex(enc.take(50));
      });
    } catch (e) {
      setDlgState(() => resultMsg = 'Error: $e');
    } finally {
      setDlgState(() => processing = false);
    }
  }

  /// Abre lote v1/v2 con el maestro: muestra la pass del lote (v2)
  /// y guarda el contenido al lado.
  Future<void> doLoteDec(void Function(void Function()) setDlgState) async {
    setDlgState(() {
      processing = true;
      resultMsg = null;
      hexPreview = null;
    });
    try {
      final raw = await leerElegido();
      if (raw == null || raw.isEmpty) {
        setDlgState(() => resultMsg = 'Elegí un archivo primero');
        return;
      }
      final ts = ToolSec('lote');
      final LoteAbierto? ab =
          await ts.processLoteStrongDecrypt(raw, maestroCtrl.text);
      if (ab == null) {
        setDlgState(() =>
            resultMsg = 'Error: maestro mal o datos alterados');
        return;
      }
      final base = (fileName ?? 'lote').split('/').last;
      final nombreOut = base.endsWith('.prbx')
          ? '${base.substring(0, base.length - 5)}.dec'
          : '$base.dec';
      final saved = (Platform.isAndroid && safDoc != null)
          ? await ToolSec.saveSafCopy(ab.contenido, nombreOut)
          : await _saveInternalCopy(nombreOut, ab.contenido);
      setDlgState(() {
        resultMsg = 'Lote v${ab.version} abierto →\n$saved'
            '${ab.passLote.isNotEmpty ? '\npass del lote: ${ab.passLote}' : ''}';
        hexPreview = _toHex(ab.contenido.take(50));
      });
    } catch (e) {
      setDlgState(() => resultMsg = 'Error: $e');
    } finally {
      setDlgState(() => processing = false);
    }
  }

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlgState) => AlertDialog(
        title: const Text('ToolSec — archivo o lote v2'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Modo: archivo suelto (XOR) o lote v2 (igual que golo).
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: false,
                      label: Text('Archivo'),
                      icon: Icon(Icons.insert_drive_file_outlined)),
                  ButtonSegment(
                      value: true,
                      label: Text('Lote v2'),
                      icon: Icon(Icons.inventory_2_outlined)),
                ],
                selected: {esLote},
                onSelectionChanged: (s) => setDlgState(() {
                  esLote = s.first;
                  resultMsg = null;
                  hexPreview = null;
                }),
              ),
              const SizedBox(height: 12),
              if (!esLote)
                TextField(
                  controller: seedCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Semilla (clave)',
                    hintText: 'Escribí tu semilla...',
                    border: OutlineInputBorder(),
                  ),
                )
              else ...[
                TextField(
                  controller: maestroCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Pass GLOBAL (maestro)',
                    hintText: 'La que sella el lote...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: loteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Pass del lote (solo al cifrar)',
                    hintText: 'Va pegada adentro...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: processing
                    ? null
                    : () async {
                        if (Platform.isAndroid) {
                          final doc = await ToolSec.pickSafFile();
                          if (doc == null) return;
                          setDlgState(() {
                            safDoc = doc;
                            fileName = doc.name;
                            filePath = null;
                            resultMsg = null;
                            hexPreview = null;
                          });
                        } else {
                          final result =
                              await FilePicker.platform.pickFiles();
                          if (result == null ||
                              result.files.single.path == null) return;
                          setDlgState(() {
                            filePath = result.files.single.path;
                            fileName = result.files.single.name;
                            safDoc = null;
                            resultMsg = null;
                            hexPreview = null;
                          });
                        }
                      },
                icon: const Icon(Icons.folder_open),
                label: Text(fileName ?? 'Seleccionar archivo'),
              ),
              if (fileName != null) ...[
                const SizedBox(height: 8),
                Text(
                  Platform.isAndroid
                      ? 'Archivo: $fileName (se cifra sobre el original)'
                      : 'Archivo: $fileName',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
              if (processing) ...[
                const SizedBox(height: 12),
                const CircularProgressIndicator(),
              ],
              if (resultMsg != null) ...[
                const SizedBox(height: 8),
                Text(resultMsg!,
                    style: TextStyle(
                        fontSize: 12,
                        color: resultMsg!.startsWith('Error') ||
                                resultMsg!.startsWith('Cancel')
                            ? Colors.red
                            : Colors.green)),
              ],
              if (hexPreview != null) ...[
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Primeros bytes (hex):',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(hexPreview!,
                      style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Colors.greenAccent)),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
          if (!esLote)
            FilledButton(
              onPressed: ((safDoc == null && filePath == null) ||
                      processing ||
                      seedCtrl.text.isEmpty)
                  ? null
                  : () => doEncrypt(setDlgState),
              child: const Text('Cifrar / Descifrar'),
            )
          else ...[
            OutlinedButton(
              onPressed: ((safDoc == null && filePath == null) ||
                      processing ||
                      maestroCtrl.text.isEmpty)
                  ? null
                  : () => doLoteDec(setDlgState),
              child: const Text('Abrir lote'),
            ),
            FilledButton(
              onPressed: ((safDoc == null && filePath == null) ||
                      processing ||
                      maestroCtrl.text.isEmpty ||
                      loteCtrl.text.isEmpty)
                  ? null
                  : () => doLoteEnc(setDlgState),
              child: const Text('Cifrar lote'),
            ),
          ],
        ],
      ),
    ),
  );
  seedCtrl.dispose();
  maestroCtrl.dispose();
  loteCtrl.dispose();
}

String _toHex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

Future<bool?> _askForCopy(BuildContext context, String reason) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('No se pudo cifrar sobre el original'),
      content: Text('$reason\n\n¿Querés guardar una copia cifrada?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('No'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Guardar copia'),
        ),
      ],
    ),
  );
}

Future<String> _saveInternalCopy(String originalPath, Uint8List data) async {
  final dir = await getApplicationSupportDirectorySafe();
  final safeName = originalPath.split(Platform.pathSeparator).last;
  final outFile = File('$dir/$safeName.sec');
  await outFile.writeAsBytes(data);
  return outFile.path;
}

Future<String> getApplicationSupportDirectorySafe() async {
  final d = await getApplicationSupportDirectory();
  final toolsecDir = Directory('${d.path}/toolsec');
  if (!toolsecDir.existsSync()) toolsecDir.createSync(recursive: true);
  return toolsecDir.path;
}
