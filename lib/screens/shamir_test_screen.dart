import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/shamir.dart';

/// Test de Shamir Secret Sharing (mejorado del ejemplo Godot):
/// repartí el secreto en N tarjetas, tocá las que se "pierden" y
/// reconstruí. Verde = restaurado, rojo = partes insuficientes.
class ShamirTestScreen extends StatefulWidget {
  const ShamirTestScreen({super.key});

  @override
  State<ShamirTestScreen> createState() => _ShamirTestScreenState();
}

class _ShamirTestScreenState extends State<ShamirTestScreen> {
  final _secretCtrl = TextEditingController(text: 'mi secreto super seguro');
  final _shamir = Shamir();

  int _count = 5;
  int _threshold = 3;
  List<_ShareCard> _cards = [];
  String _resultText = '';
  Color _resultColor = Colors.transparent;
  IconData? _resultIcon;

  @override
  void dispose() {
    _secretCtrl.dispose();
    super.dispose();
  }

  Uint8List _encode(String text) {
    // mismo padding a 64 bytes que el ejemplo Godot (ascii + zeros)
    final bytes = latin1.encode(text);
    final out = Uint8List(bytes.length < 64 ? 64 : bytes.length);
    out.setAll(0, bytes);
    return out;
  }

  String _decode(Uint8List? bytes) {
    if (bytes == null) return '';
    return latin1.decode(bytes.where((b) => b != 0).toList());
  }

  Future<void> _split() async {
    setState(() {
      _resultText = '';
      _resultIcon = null;
      _resultColor = Colors.transparent;
    });
    try {
      final data = _encode(_secretCtrl.text);
      final shares = await _shamir.split(data, _count, _threshold);
      if (!mounted) return;
      setState(() {
        _cards = [
          for (var i = 0; i < shares.length; i++)
            _ShareCard(index: i + 1, bytes: shares[i], lost: false),
        ];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cards = [];
        _showResult('Error al dividir: $e', Colors.redAccent, Icons.error);
      });
    }
  }

  Future<void> _combine() async {
    if (_cards.isEmpty) return;
    final alive =
        _cards.where((c) => !c.lost).map((c) => c.bytes).toList();
    String? resultText;
    Color resultColor = Colors.transparent;
    IconData? resultIcon;
    try {
      final restoredRaw = await _shamir.combine(alive);
      final same = () {
        if (restoredRaw == null) return false;
        final original = _encode(_secretCtrl.text);
        final r = Uint8List.fromList(restoredRaw);
        if (r.length < original.length) return false;
        for (var i = 0; i < original.length; i++) {
          if (original[i] != r[i]) return false;
        }
        return true;
      }();
      if (same) {
        resultText =
            'Restaurado OK con ${alive.length}/$_count partes '
            '(umbral $_threshold): "${_decode(restoredRaw)}"';
        resultColor = Colors.greenAccent;
        resultIcon = Icons.check_circle_rounded;
      } else {
        resultText =
            'Falló con ${alive.length} partes '
            '(necesitás >= $_threshold). Secreto irrecuperable.';
        resultColor = Colors.redAccent;
        resultIcon = Icons.cancel_rounded;
      }
    } catch (e) {
      resultText = 'Error: $e';
      resultColor = Colors.redAccent;
      resultIcon = Icons.cancel_rounded;
    }
    if (!mounted) return;
    setState(() {
      _resultText = resultText ?? '';
      _resultColor = resultColor;
      _resultIcon = resultIcon;
    });
  }

  void _showResult(String text, Color color, IconData icon) {
    _resultText = text;
    _resultColor = color;
    _resultIcon = icon;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _secretCtrl,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            labelText: 'Secreto',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _sliderCount()),
          Expanded(child: _sliderThreshold()),
        ]),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _split,
              icon: const Icon(Icons.call_split_rounded, size: 16),
              label: const Text('Repartir'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _cards.isEmpty ? null : _combine,
              icon: const Icon(Icons.merge_type_rounded, size: 16),
              label: const Text('Reconstruir'),
            ),
          ),
        ]),
        ..._cardsSection(),
        ..._resultSection(),
      ],
    );
  }

  Widget _sliderCount() {
    return Column(children: [
      Text('Partes totales: $_count',
          style: const TextStyle(fontSize: 12)),
      Slider(
        value: _count.toDouble(),
        min: 2,
        max: 8,
        divisions: 6,
        onChanged: (v) => setState(() {
          _count = v.round();
          if (_threshold > _count) _threshold = _count;
        }),
      ),
    ]);
  }

  Widget _sliderThreshold() {
    return Column(children: [
      Text('Umbral: $_threshold', style: const TextStyle(fontSize: 12)),
      Slider(
        value: _threshold.toDouble(),
        min: 2,
        max: _count.toDouble(),
        divisions: _count - 2,
        activeColor: Colors.orangeAccent,
        onChanged: (v) => setState(() => _threshold = v.round()),
      ),
    ]);
  }

  List<Widget> _cardsSection() {
    if (_cards.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      Center(
        child: Text('tocá una tarjeta para marcarla como PERDIDA',
            style: TextStyle(
                fontSize: 10, color: Colors.white.withValues(alpha: .4))),
      ),
      const SizedBox(height: 8),
      GridView.count(
        crossAxisCount: MediaQuery.of(context).size.width > 500 ? 4 : 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.1,
        children: [for (final card in _cards) _shareTile(card)],
      ),
    ];
  }

  Widget _shareTile(_ShareCard card) {
    final hex = _toHex(card.bytes);
    return GestureDetector(
      onTap: () => setState(() => card.lost = !card.lost),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: card.lost
              ? Colors.red.withValues(alpha: .08)
              : Colors.cyanAccent.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: card.lost
                ? Colors.redAccent.withValues(alpha: .7)
                : Colors.cyanAccent.withValues(alpha: .5),
          ),
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              card.lost ? Icons.key_off_rounded : Icons.vpn_key_rounded,
              color: card.lost ? Colors.redAccent : Colors.cyanAccent,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text('Share #${card.index}',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: card.lost ? Colors.redAccent : Colors.white70)),
            Text(
              card.lost ? 'perdida' : hex.substring(0, 10),
              style: TextStyle(
                  fontSize: 8,
                  fontFamily: 'monospace',
                  color: card.lost ? Colors.redAccent : Colors.white38,
                  decoration:
                      card.lost ? TextDecoration.lineThrough : null),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _resultSection() {
    if (_resultText.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _resultColor.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _resultColor.withValues(alpha: .5)),
        ),
        child: Row(children: [
          Icon(_resultIcon, color: _resultColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child:
                Text(_resultText, style: TextStyle(fontSize: 11, color: _resultColor)),
          ),
        ]),
      ),
    ];
  }
}

class _ShareCard {
  final int index;
  final Uint8List bytes;
  bool lost;
  _ShareCard({required this.index, required this.bytes, required this.lost});
}

String _toHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
