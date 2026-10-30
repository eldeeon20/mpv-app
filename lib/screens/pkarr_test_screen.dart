import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../src/rust/api/pkarr.dart' as rust;

/// PKARR v8: identidad ed25519 con secret CIFRADA por PIN (AES-GCM,
/// lado Rust), publicación firmada (DHT Mainline + relays = "both")
/// y consulta de claves de terceros con listado legible.
class PkarrTestScreen extends StatefulWidget {
  const PkarrTestScreen({super.key});

  @override
  State<PkarrTestScreen> createState() => _PkarrTestScreenState();
}

class _PkarrTestScreenState extends State<PkarrTestScreen> {
  final _pinCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: 'mi_registro');
  final _valueCtrl = TextEditingController(text: 'hola=pr_app');
  final _ttlCtrl = TextEditingController(text: '300');
  final _queryCtrl = TextEditingController();
  final _relaysCtrl = TextEditingController();

  String? _pubkey;
  String? _secreto;
  bool _hasSavedKey = false;
  bool _busy = false;
  String _mode = 'both';
  String _policy = 'network_only';
  final _log = <String>[];
  List<String> _records = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final dir = await getApplicationSupportDirectory();
    final has = await rust.pkarrHasSavedKey(dir: dir.path);
    setState(() => _hasSavedKey = has);
    _say(has
        ? 'hay clave guardada · ingresá PIN y tocá Cargar'
        : 'sin clave guardada · generá una con PIN');
  }

  void _say(String m) => setState(() {
        _log.insert(0, m);
        if (_log.length > 30) _log.removeLast();
      });

  Future<void> _guard(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (e) {
      _say('ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> get _dir async =>
      (await getApplicationSupportDirectory()).path;

  Future<void> _generate() => _guard(() async {
        final id = await rust.pkarrGenerateEncrypted(
            pin: _pinCtrl.text, dir: await _dir);
        setState(() {
          _pubkey = id.pubkey;
          _secreto = id.secreto;
          _hasSavedKey = true;
        });
        _say('generada y guardada CIFRADA · pub y sec abajo');
      });

  Future<void> _load() => _guard(() async {
        final id =
            await rust.pkarrLoadEncrypted(pin: _pinCtrl.text, dir: await _dir);
        setState(() {
          _pubkey = id.pubkey;
          _secreto = id.secreto;
        });
        _say('clave descifrada OK · pub y sec abajo');
      });

  Future<void> _publish() => _guard(() async {
        final ttl = int.tryParse(_ttlCtrl.text.trim()) ?? 300;
        final res = await rust.pkarrPublish(
          pin: _pinCtrl.text,
          dir: await _dir,
          name: _nameCtrl.text.trim(),
          value: _valueCtrl.text,
          ttl: ttl.clamp(1, 86400),
          mode: _mode,
          relays: _relaysCsv(),
        );
        _say(res);
      });

  Future<void> _resolve() => _guard(() async {
        final lines = await rust.pkarrResolve(
          pubkeyZbase32: _queryCtrl.text.trim(),
          mode: _mode,
          relays: _relaysCsv(),
          policy: _policy,
        );
        setState(() => _records = lines);
        _say('resuelto: ${lines.length - 1} registro(s)');
      });

  List<String> _relaysCsv() => _relaysCtrl.text
      .split('|')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  @override
  void dispose() {
    _pinCtrl.dispose();
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    _ttlCtrl.dispose();
    _queryCtrl.dispose();
    _relaysCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(padding: const EdgeInsets.all(12), children: [
        // ---- identidad
        _card('Identidad (ed25519)', Colors.deepPurpleAccent, [
          TextField(
            controller: _pinCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            decoration:
                const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton.icon(
              onPressed: _busy || _pinCtrl.text.length < 4
                  ? null
                  : _generate,
              icon: const Icon(Icons.key_rounded, size: 18),
              label: const Text('Generar + guardar'),
            ),
            FilledButton.tonalIcon(
              onPressed:
                  _busy || !_hasSavedKey || _pinCtrl.text.isEmpty ? null : _load,
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: Text(_hasSavedKey ? 'Cargar' : 'Cargar (no hay)'),
            ),
          ]),
          if (_pubkey != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('PUB · podés compartirla',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.tealAccent)),
                Row(children: [
                  Expanded(
                      child: SelectableText(_pubkey!,
                          style: const TextStyle(
                              fontSize: 11, fontFamily: 'monospace'))),
                  IconButton(
                    tooltip: 'Copiar pubkey',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _pubkey!));
                    },
                  ),
                ]),
                if (_secreto != null) ...[
                  const Text('SEC · NUNCA compartir',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.redAccent)),
                  Row(children: [
                    Expanded(
                        child: SelectableText(_secreto!,
                            style: const TextStyle(
                                fontSize: 11, fontFamily: 'monospace'))),
                    IconButton(
                      tooltip: 'Copiar secreto',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _secreto!));
                      },
                    ),
                  ]),
                ],
              ]),
            ),
        ]),
        const SizedBox(height: 10),
        // ---- modo / relays
        _card('Red', Colors.tealAccent, [
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final m in ['both', 'dht', 'relays'])
              ChoiceChip(
                label: Text(m, style: const TextStyle(fontSize: 11)),
                selected: _mode == m,
                onSelected: (_) => setState(() => _mode = m),
              ),
          ]),
          const SizedBox(height: 6),
          TextField(
            controller: _relaysCtrl,
            style: const TextStyle(fontSize: 11),
            decoration: const InputDecoration(
                labelText: 'Relays custom (opcional, sep |)',
                hintText: 'https://relay.pkarr.org|https://d.pkarr.org',
                border: OutlineInputBorder(),
                isDense: true),
          ),
        ]),
        const SizedBox(height: 10),
        // ---- publicar
        _card('Publicar TXT firmado', Colors.amberAccent, [
          TextField(
            controller: _nameCtrl,
            style: const TextStyle(fontSize: 11),
            decoration: const InputDecoration(
                labelText: 'name', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _valueCtrl,
            style: const TextStyle(fontSize: 11),
            decoration: const InputDecoration(
                labelText: 'value (TXT público, sin cifrar)',
                border: OutlineInputBorder(),
                isDense: true),
          ),
          const SizedBox(height: 6),
          Row(children: [
            SizedBox(
              width: 90,
              child: TextField(
                controller: _ttlCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 11),
                decoration: const InputDecoration(
                    labelText: 'ttl', border: OutlineInputBorder(), isDense: true),
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed:
                  _busy || _pubkey == null || _pinCtrl.text.isEmpty ? null : _publish,
              icon: const Icon(Icons.upload_rounded, size: 18),
              label: const Text('Publicar'),
            ),
          ]),
        ]),
        const SizedBox(height: 10),
        // ---- consultar
        _card('Consultar pubkey de tercero', Colors.cyanAccent, [
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final p in ['network_only', 'cache_first', 'cache_only'])
              ChoiceChip(
                label: Text(p.replaceAll('_', ' '), style: const TextStyle(fontSize: 10)),
                selected: _policy == p,
                onSelected: (_) => setState(() => _policy = p),
              ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _queryCtrl,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                    hintText: 'pubkey zbase32…',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
            ),
            IconButton.filled(
                onPressed: _busy || _queryCtrl.text.trim().isEmpty ? null : _resolve,
                icon: const Icon(Icons.search_rounded)),
          ]),
          if (_records.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(maxHeight: 180),
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                  child: SelectableText(_records.join('\n\n'),
                      style: const TextStyle(
                          fontSize: 10.5, fontFamily: 'monospace'))),
            ),
        ]),
        const SizedBox(height: 10),
        // ---- log
        Container(
          height: 120,
          width: double.infinity,
          color: Colors.black.withValues(alpha: .5),
          padding: const EdgeInsets.all(8),
          child: ListView.builder(
            itemCount: _log.length,
            itemBuilder: (_, i) => Text(_log[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 9.5,
                    fontFamily: 'monospace',
                    color: _log[i].startsWith('ERROR')
                        ? Colors.redAccent
                        : Colors.greenAccent.withValues(alpha: .7))),
          ),
        ),
      ]),
    );
  }

  Widget _card(String title, Color color, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title.toUpperCase(),
            style: TextStyle(
                fontSize: 10, letterSpacing: 1, color: color)),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }
}
