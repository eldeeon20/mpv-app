import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/unarc.dart';

/// Port de Gtool `unarc_godot.rs` como pantalla de prueba: abrís un archive
/// (7z/ZIP/RAR5/tar/arj/lha/zoo). Multivolumen (.001/.z01): elegí TODAS las
/// partes juntas (el picker copia suelto al cache y los hermanos no están).
class UnarcTestScreen extends StatefulWidget {
  const UnarcTestScreen({super.key});

  @override
  State<UnarcTestScreen> createState() => _UnarcTestScreenState();
}

class _UnarcTestScreenState extends State<UnarcTestScreen> {
  final _unarc = Unarc();
  final _pwdCtrl = TextEditingController();
  final _log = <String>[];

  List<String> _paths = const [];
  UnarcPartes? _partes;
  String _formato = '';
  bool _encriptado = false;
  List<UnarcEntry> _entries = const [];
  bool _busy = false;
  bool _verPwd = false;

  void _add(String s) => setState(() {
        _log.add(s);
        if (_log.length > 60) _log.removeAt(0);
      });

  /// Carpeta destino: <docs>/unarc/<nombre archive sin extensión>/
  Future<String> _destino() async {
    final docs = await getApplicationDocumentsDirectory();
    final base =
        _paths.isEmpty ? 'sin_nombre' : _nombreBase(_paths.first);
    return '${docs.path}/unarc/$base';
  }

  static String _nombreBase(String p) {
    final f = p.split('/').last;
    // x.7z.001 → x ; x.zip → x
    var sinExt = f;
    for (final suf in const ['.tar.gz', '.tar.bz2']) {
      if (sinExt.toLowerCase().endsWith(suf)) {
        sinExt = sinExt.substring(0, sinExt.length - suf.length);
      }
    }
    final punto = sinExt.indexOf('.');
    return punto > 0 ? sinExt.substring(0, punto) : sinExt;
  }

  Future<void> _elegir() async {
    if (_busy) return;
    final res = await FilePicker.platform
        .pickFiles(allowMultiple: true, type: FileType.any);
    final rutas = <String>[
      for (final f in res?.files ?? const <PlatformFile>[])
        if (f.path != null && f.path!.isNotEmpty) f.path!,
    ];
    if (rutas.isEmpty) return;
    setState(() {
      _paths = rutas;
      _entries = const [];
      _formato = '';
      _encriptado = false;
      _partes = null;
    });
    // Contar partes ANTES de abrir: nunca más a ciegas.
    try {
      final p = await _unarc.volumenes(_paths);
      setState(() => _partes = p);
      final nombres =
          p.nombres.map((n) => n.split('/').last).join(', ');
      _add(p.total > 1
          ? '✓ ${p.total} partes: $nombres'
          : '⚠ 1 sola parte (si era multivolumen, elegí las demás también)');
    } catch (_) {}
    await _cargar();
  }

  Future<void> _cargar() async {
    if (_paths.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final soportado = await _unarc.soportado(_paths);
      _add(soportado
          ? '✓ extensión soportada'
          : '⚠ extensión no estándar, igual intento abrir');
      final formato = await _unarc.formato(_paths);
      final pwd = _pwdCtrl.text;
      final entries = await _unarc.listar(_paths, password: pwd);
      final encriptado = entries.any((e) => e.encrypted) && pwd.isEmpty;
      setState(() {
        _formato = formato;
        _encriptado = encriptado;
        _entries = entries;
      });
      _add('✓ ${entries.length} entradas · formato: ${formato.isEmpty ? '?' : formato}'
          '${encriptado ? ' · PIDE PASSWORD' : ''}');
    } catch (e) {
      setState(() => _entries = const []);
      final msg = '$e';
      _add('✗ listar: $msg');
      if (msg.contains('password') ||
          msg.toLowerCase().contains('encrypt') ||
          msg.toLowerCase().contains('crc')) {
        _add('  ↳ probá poner la contraseña y recargar');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _extraerTodo() async {
    if (_paths.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final dest = await _destino();
      final r = await _unarc.extraerTodo(
        _paths,
        dest,
        password: _pwdCtrl.text,
      );
      _add('✓ ${r.files} archivos (${_humano(r.bytes)}) → $dest');
    } catch (e) {
      _add('✗ extraer todo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _extraerUna(UnarcEntry e) async {
    if (_paths.isEmpty || _busy || e.isDir) return;
    setState(() => _busy = true);
    try {
      final destDir = await _destino();
      final nombre = e.name.replaceAll('\\', '/').split('/').last;
      final dest = '$destDir/$nombre';
      final bytes = await _unarc.extraerEntrada(
        _paths,
        e.name,
        dest,
        password: _pwdCtrl.text,
      );
      _add('✓ ${e.name} (${_humano(bytes)}) → $dest');
    } catch (err) {
      _add('✗ ${e.name}: $err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _humano(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// ¿Pinta como texto plano? → tap = preview en RAM (sin disco).
  bool _esTexto(UnarcEntry e) {
    if (e.isDir || e.size > 2 * 1024 * 1024) return false;
    const exts = [
      'txt', 'md', 'json', 'csv', 'log', 'ini', 'cfg', 'conf', 'xml',
      'html', 'htm', 'js', 'ts', 'py', 'sh', 'bat', 'yml', 'yaml',
      'srt', 'nfo', 'lua', 'toml', 'url',
    ];
    final n = e.name.toLowerCase();
    return exts.any(n.endsWith);
  }

  /// Lee la entrada DIRECTO a memoria (leerEntrada): nada toca el disco.
  Future<void> _preview(UnarcEntry e) async {
    if (_paths.isEmpty || _busy || e.isDir) return;
    setState(() => _busy = true);
    try {
      final data = await _unarc.leerEntrada(
        _paths,
        e.name,
        password: _pwdCtrl.text,
        maxBytes: 256 * 1024,
      );
      final texto = utf8.decode(data, allowMalformed: true);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(e.name,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(texto,
                  style:
                      const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
      _add('✓ preview en RAM: ${e.name} (${data.length} B, sin tocar disco)');
    } catch (err) {
      _add('✗ ${e.name}: $err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _paths.isEmpty
                      ? 'Elegí el archive o TODAS sus partes…'
                      : ('${_paths.first.split('/').last}'
                          '${_paths.length > 1 ? ' (+${_paths.length - 1})' : ''}'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontFamily: 'monospace'),
                ),
              ),
              if (_partes != null)
                Chip(
                  avatar: Icon(
                    _partes!.total > 1
                        ? Icons.done_all_rounded
                        : Icons.warning_amber_rounded,
                    size: 14,
                    color: _partes!.total > 1
                        ? Colors.greenAccent
                        : Colors.redAccent,
                  ),
                  label: Text('${_partes!.total} parte(s)',
                      style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                ),
              if (_formato.isNotEmpty)
                Chip(
                  label: Text(_formato,
                      style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                ),
              IconButton(
                onPressed: _busy ? null : _elegir,
                icon: const Icon(Icons.folder_open_rounded),
                tooltip: 'Abrir archive',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TextField(
            controller: _pwdCtrl,
            obscureText: !_verPwd,
            decoration: InputDecoration(
              isDense: true,
              hintText: _encriptado
                  ? 'contraseña REQUERIDA'
                  : 'contraseña (opcional)',
              prefixIcon: Icon(
                Icons.lock_rounded,
                size: 18,
                color: _encriptado ? Colors.redAccent : null,
              ),
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: Icon(_verPwd
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded),
                  onPressed: () => setState(() => _verPwd = !_verPwd),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Recargar con esta contraseña',
                  onPressed: _busy ? null : _cargar,
                ),
              ]),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed:
                  (_busy || _entries.isEmpty) ? null : _extraerTodo,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.unarchive_rounded),
              label: Text(_entries.isEmpty
                  ? 'Sin entradas cargadas'
                  : 'Extraer todo (${_entries.length})'),
            ),
          ),
        ),
        Expanded(
          child: _entries.isEmpty
              ? Center(
                  child: Text(
                    _paths.isEmpty
                        ? 'Abrí un .zip/.7z/.rar/…\nmultivolumen: elegí TODAS\nlas partes juntas'
                        : (_busy ? 'Leyendo…' : 'Sin entradas'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _entries.length,
                  itemBuilder: (_, i) {
                    final e = _entries[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        e.isDir
                            ? Icons.folder_rounded
                            : (e.encrypted
                                ? Icons.lock_outline_rounded
                                : (_esTexto(e)
                                    ? Icons.plagiarism_outlined
                                    : Icons.description_outlined)),
                        color: e.isDir
                            ? Colors.amberAccent
                            : (e.encrypted
                                ? Colors.redAccent
                                : Colors.white54),
                      ),
                      title: Text(e.name,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: e.isDir
                          ? null
                          : Text(_humano(e.size),
                              style: const TextStyle(fontSize: 11)),
                      // tap = preview en RAM (solo textos); botón = extraer a disco
                      onTap: _esTexto(e) ? () => _preview(e) : null,
                      trailing: e.isDir
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.save_alt_rounded,
                                  size: 18),
                              tooltip: 'Extraer a disco',
                              onPressed: () => _extraerUna(e),
                            ),
                    );
                  },
                ),
        ),
        Container(
          height: 130,
          width: double.infinity,
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF061021),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white10),
          ),
          child: ListView.builder(
            itemCount: _log.length,
            itemBuilder: (_, i) => Text(
              _log[i],
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: _log[i].startsWith('✗')
                    ? Colors.redAccent
                    : (_log[i].startsWith('✓')
                        ? Colors.greenAccent
                        : Colors.white60),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }
}

extension _SingleOrNull<T> on List<T> {
  T? get singleOrNull => length == 1 ? first : null;
}
