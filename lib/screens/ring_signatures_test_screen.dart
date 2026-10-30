import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/nostringer.dart';

/// Port de Gtool `test_nostringer.gd`: firmas de anillo SAG/BLSAG.
/// Generás un ring de N claves, firmás como UNA de ellas sin revelar cuál,
/// y verificás contra el ring completo. BLSAG además expone la key image.
class RingSignaturesTestScreen extends StatefulWidget {
  const RingSignaturesTestScreen({super.key});

  @override
  State<RingSignaturesTestScreen> createState() =>
      _RingSignaturesTestScreenState();
}

class _RingSignaturesTestScreenState extends State<RingSignaturesTestScreen> {
  final _nostringer = Nostringer();
  final _msgCtrl =
      TextEditingController(text: 'This is a secret message to the group.');
  final _log = <String>[];

  final _keys = <RingKeypair>[]; // el ring
  String _variant = 'blsag';
  int _signerIdx = 0;
  String? _lastSig;
  String? _lastKeyImage;
  bool _busy = false;

  Uint8List get _message => Uint8List.fromList(_msgCtrl.text.codeUnits);

  void _add(String s) => setState(() {
        _log.add(s);
        if (_log.length > 60) _log.removeAt(0);
      });

  Future<void> _generarKeys(int n) async {
    setState(() => _busy = true);
    try {
      final keys = <RingKeypair>[];
      for (var i = 0; i < n; i++) {
        // El .gd mezcla variants; acá todas con la elegida para que el
        // ring sea consistente con lo que verifica nostringer.
        keys.add(await _nostringer.generateKeypair(variant: _variant));
      }
      setState(() {
        _keys
          ..clear()
          ..addAll(keys);
        _lastSig = null;
        _lastKeyImage = null;
        if (_signerIdx >= n) _signerIdx = 0;
      });
      _add('✓ ring generado ($_variant): ${keys.length} claves');
    } catch (e) {
      _add('✗ keys: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _firmar() async {
    if (_keys.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final signer = _keys[_signerIdx];
      final ring = _keys.map((k) => k.publicKey).toList();
      final sig = await _nostringer.sign(
        message: _message,
        privateKey: signer.privateKey,
        ring: ring,
        variant: _variant,
      );
      setState(() {
        _lastSig = sig.signature;
        _lastKeyImage = sig.keyImage.isEmpty ? null : sig.keyImage;
      });
      _add('✓ firma ${_variant.toUpperCase()} por clave #${_signerIdx + 1} '
          '(${sig.signature.length} chars)');
      if (_lastKeyImage != null) {
        _add('  key image: ${_short(_lastKeyImage!)}…');
      }
    } catch (e) {
      _add('✗ firmar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verificar({bool estrictaBlsag = false}) async {
    if (_lastSig == null || _keys.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final ring = _keys.map((k) => k.publicKey).toList();
      if (estrictaBlsag) {
        final ok = await _nostringer.verifyBlsag(
          signature: _lastSig!,
          keyImage: _lastKeyImage ?? '',
          message: _message,
          ring: ring,
        );
        _add(ok
            ? '✓ verificación BLSAG ESTRICTA válida'
            : '✗ verificación BLSAG estricta inválida');
      } else {
        final r = await _nostringer.verify(
          signature: _lastSig!,
          message: _message,
          ring: ring,
        );
        _add(r.valid
            ? '✓ firma VÁLIDA dentro del ring · ki: ${_short(r.keyImage)}…'
            : '✗ firma INVÁLIDA');
      }
    } catch (e) {
      _add('✗ verificar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Firma con un mensaje DISTINTO para demostrar que falla.
  Future<void> _verificarMensajeAlterado() async {
    if (_lastSig == null || _keys.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final altered =
          Uint8List.fromList([..._message, ...'X'.codeUnits]);
      final r = await _nostringer.verify(
        signature: _lastSig!,
        message: altered,
        ring: _keys.map((k) => k.publicKey).toList(),
      );
      _add(r.valid ? '? alterado válido (MAL)' : '✓ mensaje alterado detectado (inválido)');
    } catch (e) {
      _add('✗ alterado: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _short(String s) =>
      s.length <= 12 ? s : '${s.substring(0, 12)}…';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
          backgroundColor: const Color(0xFF17212B),
          title: const Text('Nostringer · Firmas Ring')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
              children: [
            ChoiceChip(
              label: const Text('BLSAG'),
              selected: _variant == 'blsag',
              onSelected: (_) => setState(() => _variant = 'blsag'),
            ),
            ChoiceChip(
              label: const Text('SAG'),
              selected: _variant == 'sag',
              onSelected: (_) => setState(() => _variant = 'sag'),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: _busy ? null : () => _generarKeys(3),
              icon: const Icon(Icons.vpn_key_rounded, size: 18),
              label: const Text('Generar ring (3)'),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _msgCtrl,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Mensaje',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          if (_keys.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Text('Firmante:',
                        style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _signerIdx.toDouble(),
                        min: 0,
                        max: (_keys.length - 1).toDouble(),
                        divisions: _keys.length - 1,
                        label: '#${_signerIdx + 1}',
                        onChanged: (v) =>
                            setState(() => _signerIdx = v.round()),
                      ),
                    ),
                    Text('#${_signerIdx + 1}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                  for (var i = 0; i < _keys.length; i++)
                    Text(
                      '$i: ${_short(_keys[i].publicKey)}${i == _signerIdx ? '  ← firmante real' : ''}',
                      style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: i == _signerIdx
                              ? Colors.greenAccent
                              : Colors.white54),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton.icon(
              onPressed: (_keys.isEmpty || _busy) ? null : _firmar,
              icon: const Icon(Icons.draw_rounded, size: 18),
              label: const Text('Firmar'),
            ),
            OutlinedButton.icon(
              onPressed: (_lastSig == null || _busy)
                  ? null
                  : () => _verificar(),
              icon: const Icon(Icons.verified_rounded, size: 18),
              label: const Text('Verificar'),
            ),
            if (_variant == 'blsag')
              OutlinedButton.icon(
                onPressed: (_lastSig == null || _busy)
                    ? null
                    : () => _verificar(estrictaBlsag: true),
                icon: const Icon(Icons.gavel_rounded, size: 18),
                label: const Text('Verif. estricta'),
              ),
            OutlinedButton.icon(
              onPressed: (_lastSig == null || _busy)
                  ? null
                  : _verificarMensajeAlterado,
              icon: const Icon(Icons.bug_report_rounded, size: 18),
              label: const Text('Msg alterado'),
            ),
          ]),
          const SizedBox(height: 8),
          Expanded(child: _logPanel()),
        ]),
      ),
    );
  }

  Widget _logPanel() => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .45),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: .08)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Text('Registro (${_log.length})',
                style: const TextStyle(fontSize: 11, color: Colors.white38)),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: _log.length,
              itemBuilder: (_, i) => SelectableText(
                '[${i.toString().padLeft(2, '0')}] ${_log[i]}',
                style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    color: _log[i].startsWith('✓')
                        ? Colors.greenAccent
                        : _log[i].startsWith('✗')
                            ? Colors.redAccent
                            : Colors.white70),
              ),
            ),
          ),
        ]),
      );
}
