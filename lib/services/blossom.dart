import 'dart:convert';

import 'package:http/http.dart' as http;

/// Subida de imágenes vía Blossom (PUT /upload → URL pública).
/// Sin auth en servidores que lo permiten; si uno exige NIP-98 se
/// agrega después el helper de firma.
class Blossom {
  static const defaultServer = 'https://blossom.primal.net';

  /// Sube el archivo y devuelve la URL pública del blob.
  Future<String> subir(String filePath, {String server = defaultServer}) async {
    final req = http.MultipartRequest('PUT', Uri.parse('$server/upload'))
      ..files.add(await http.MultipartFile.fromPath('file', filePath));
    final res = await http.Response.fromStream(await req.send().timeout(
        const Duration(seconds: 60)));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw 'Blossom HTTP ${res.statusCode}: ${res.body}';
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final sha = j['sha256']?.toString() ?? '';
    if (sha.isEmpty) throw 'respuesta sin sha256: ${res.body}';
    return '$server/$sha';
  }
}
