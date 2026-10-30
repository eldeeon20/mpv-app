/// NOSTRN+ : cuenta + perfil + bandeja + chat.
///
/// Flujo pensado para dos peers que NO se conocen:
/// 1. cada uno crea su cuenta (pub+sec visibles y copiables)
/// 2. edita su perfil kind 0 (como los perfiles que aparecen en Nostr
///    Busca)
/// 3. el que conoce al otro lo escribe; el receptor lo descubre en la
///    bandeja (el remitente viaja DENTRO del giftwrap) y fija peer
/// 4. chatean por NIP-17 (que cifra con NIP-44 adentro, doble capa:
///    seal firmado con la key real + giftwrap anónimo con key efímera)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../src/rust/api/nostrn_gestion.dart' as rust;
import '../services/blossom.dart';
import '../services/nostrn_gestion.dart';
import 'nostrn_social.dart';

class NostrnScreen extends StatefulWidget {
  const NostrnScreen({super.key});
  @override
  State<NostrnScreen> createState() => _NostrnScreenState();
}

class _NostrnScreenState extends State<NostrnScreen> {
  final _svc = NostrnGestion();

  final _nombreCtrl = TextEditingController(text: 'yo');
  final _pinCtrl = TextEditingController();
  final _dmRelaysCtrl = TextEditingController(text: 'wss://nos.lol');
  final _readRelaysCtrl = TextEditingController(text: 'wss://relay.primal.net');
  final _ventanaCtrl = TextEditingController(text: '48');
  final _limiteCtrl = TextEditingController(text: '50');
  final _perfilNameCtrl = TextEditingController();
  final _perfilDisplayCtrl = TextEditingController();
  final _perfilAboutCtrl = TextEditingController();
  final _perfilPicCtrl = TextEditingController();
  final _peerCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();

  rust.GestionCuenta? _cuenta;
  rust.GestionViva? _gestion;
  final List<rust.BandejaItem> _bandeja = [];
  final List<String> _registro = [];
  final List<String> _chatLocal = [];
  String _estado = 'sin cuenta cargada';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final hay = await _svc.hayCuenta(dir.path);
      setState(() =>
          _estado = hay ? 'hay cuenta guardada · ingresá PIN y Cargar' : 'sin cuenta: creá una');
    } catch (e) {
      _say('ERROR init: $e');
    }
  }

  void _say(String m) => setState(() => _estado = m);

  Future<void> _guard(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      _say('ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> get _dir async => (await getApplicationSupportDirectory()).path;

  List<String> _csv(TextEditingController c) => c.text
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  // ------------------------------------------------------------- cuenta

  Future<void> _crear() => _guard(() async {
        final c = await _svc.crearCuenta(
            pin: _pinCtrl.text, dir: await _dir, nombre: _nombreCtrl.text.trim());
        setState(() => _cuenta = c);
        _say('cuenta creada y guardada${_pinCtrl.text.isEmpty ? " PLANA" : " CIFRADA"}');
      });

  Future<void> _guardarNsecExistente(String nsec) => _guard(() async {
        final c = await _svc.guardarCuenta(
            pin: _pinCtrl.text,
            dir: await _dir,
            nombre: _nombreCtrl.text.trim(),
            nsec: nsec);
        setState(() => _cuenta = c);
        _say('identidad importada y guardada');
      });

  Future<void> _cargar() => _guard(() async {
        final c = await _svc.cargarCuenta(pin: _pinCtrl.text, dir: await _dir);
        setState(() => _cuenta = c);
        _say('cuenta descifrada OK');
      });

  // ---------------------------------------------------------------- red

  Future<void> _conectar() => _guard(() async {
        if (_cuenta == null) return _say('creá o cargá una cuenta primero');
        final g = await _svc.nuevaSesion(nsec: _cuenta!.nsec);
        await g.addRelays(
            dmRelays: _csv(_dmRelaysCtrl), readRelays: _csv(_readRelaysCtrl));
        await g.subscribe(
            nSeconds:
                (int.tryParse(_ventanaCtrl.text.trim()) ?? 48) * 3600,
            nLimit: int.tryParse(_limiteCtrl.text.trim()) ?? 50);
        setState(() => _gestion = g);
        await _logs();
        _say('conectado · bandeja escuchando');
      });

  Future<void> _logs() async {
    try {
      final l = await _gestion?.takeLogs();
      if (l == null || l.isEmpty) return;
      setState(() {
        _registro.insertAll(0, l);
        if (_registro.length > 60) {
          _registro.removeRange(60, _registro.length);
        }
      });
    } catch (_) {}
  }

  String _fechaCorta(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day}/${d.month} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _poll() => _guard(() async {
        final g = _gestion;
        if (g == null) return _say('conectá primero');
        final items = await g.pollBandeja();
        await _logs();
        setState(() => _bandeja.insertAll(0, items));
        _say(items.isEmpty ? 'bandeja vacía' : '${items.length} mensaje(s) nuevo(s)');
      });

  Future<void> _fijarPeer(String npub) => _guard(() async {
        final g = _gestion ?? await _svc.nuevaSesion(nsec: _cuenta?.nsec);
        if (_gestion == null) setState(() => _gestion = g);
        await g.setPeer(npub: npub);
        setState(() => _peerCtrl.text = npub);
        _say('peer fijado: $npub');
      });

  Future<void> _enviar() => _guard(() async {
        final t = _chatCtrl.text.trim();
        if (t.isEmpty || _gestion == null) return;
        await _gestion!.send(content: t);
        _chatCtrl.clear();
        setState(() => _chatLocal.add('yo: $t'));
      });

  Future<void> _subirImagenPerfil() => _guard(() async {
        final res = await FilePicker.platform
            .pickFiles(type: FileType.image, withData: false);
        final path = res?.files.single.path;
        if (path == null) return;
        _say('subiendo imagen a Blossom…');
        final url = await Blossom().subir(path);
        setState(() => _perfilPicCtrl.text = url);
        _say('imagen lista: tocá Publicar perfil');
      });

  Future<void> _publicarPerfil() => _guard(() async {        final g = _gestion;
        if (g == null) return _say('conectá primero (el perfil se publica en relays)');
        await g.setPerfil(
          name: _perfilNameCtrl.text.trim(),
          displayName: _perfilDisplayCtrl.text.trim(),
          about: _perfilAboutCtrl.text.trim(),
          picture: _perfilPicCtrl.text.trim(),
        );
        _say('perfil publicado ✓ (puede tardar en propagarse)');
      });

  Widget _keyRow(String label, String value, Color color) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, color: color)),
      Row(children: [
        Expanded(
            child: SelectableText(value,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
        IconButton(
          tooltip: 'Copiar',
          icon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
        ),
      ]),
    ]);
  }

  Widget _card(String title, Color color, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        border: Border.all(color: color.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13, color: color)),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }

  TextField _tf(TextEditingController c, String hint, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: const TextStyle(fontSize: 12),
      decoration: InputDecoration(
          hintText: hint, isDense: true, border: const OutlineInputBorder()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conectado = _gestion != null;
    return Scaffold(
      body: ListView(children: [
        _card('1 · Cuenta', Colors.indigoAccent, [
          _tf(_nombreCtrl, 'nombre de la cuenta'),
          const SizedBox(height: 6),
          _tf(_pinCtrl, 'PIN (vacío = plano)', obscure: true),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            FilledButton.tonalIcon(
                onPressed: _busy ? null : _crear,
                icon: const Icon(Icons.key_rounded, size: 18),
                label: const Text('Crear')),
            FilledButton.tonalIcon(
                onPressed: _busy ? null : _cargar,
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: const Text('Cargar')),
          ]),
          if (_cuenta != null) ...[
            const SizedBox(height: 8),
            _keyRow('PUB · podés compartirla', _cuenta!.npub, Colors.tealAccent),
            _keyRow('SEC · NUNCA compartir', _cuenta!.nsec, Colors.redAccent),
          ],
        ]),
        _card('2 · Red', Colors.tealAccent, [
          _tf(_dmRelaysCtrl, 'relays DM separados por coma'),
          const SizedBox(height: 6),
          _tf(_readRelaysCtrl, 'relays lectura'),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
                child: _tf(_ventanaCtrl,
                    'escuchar desde horas atrás (0 = TODO)')),
            const SizedBox(width: 6),
            Expanded(child: _tf(_limiteCtrl, 'límite N')),
          ]),
          const SizedBox(height: 6),
          FilledButton.icon(
              onPressed: _busy ? null : _conectar,
              icon: const Icon(Icons.wifi_rounded, size: 18),
              label: Text(conectado ? 're-conectar' : 'Conectar y suscribir')),
        ]),
        _card('3 · Perfil kind 0', Colors.purpleAccent, [
          _tf(_perfilNameCtrl, 'name'),
          const SizedBox(height: 6),
          _tf(_perfilDisplayCtrl, 'display_name'),
          const SizedBox(height: 6),
          _tf(_perfilAboutCtrl, 'about'),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _tf(_perfilPicCtrl, 'picture URL (https://…)')),
            IconButton(
              tooltip: 'subir imagen (Blossom)',
              icon: const Icon(Icons.image_rounded, size: 20),
              onPressed: _busy ? null : _subirImagenPerfil,
            ),
          ]),
          const SizedBox(height: 6),
          FilledButton.icon(
              onPressed: !conectado || _busy ? null : _publicarPerfil,
              icon: const Icon(Icons.badge_rounded, size: 18),
              label: const Text('Publicar perfil')),
        ]),
        _card('4 · Bandeja (de cualquiera)', Colors.orangeAccent, [
          FilledButton.icon(
              onPressed: !conectado || _busy ? null : _poll,
              icon: const Icon(Icons.inbox_rounded, size: 18),
              label: const Text('Revisar bandeja')),
          const SizedBox(height: 6),
          for (final b in _bandeja.take(30))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(b.content,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(b.senderNpub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9, fontFamily: 'monospace')),
              trailing: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(_fechaCorta(b.timestampMs),
                        style:
                            const TextStyle(fontSize: 9, color: Colors.white38)),
                    TextButton(
                        onPressed: () => _fijarPeer(b.senderNpub),
                        child: const Text('fijar peer')),
                  ]),
            ),
        ]),
        _card('Registro (kinds · relays · fallos)', Colors.blueGrey, [
          if (_registro.isEmpty)
            const Text('vacío',
                style: TextStyle(fontSize: 11, color: Colors.white24)),
          for (final line in _registro.take(40))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(line,
                  style: const TextStyle(
                      fontSize: 9,
                      fontFamily: 'monospace',
                      color: Colors.white54)),
            ),
        ]),
        _card('5 · Chat con peer', Colors.cyanAccent, [
          _tf(_peerCtrl, 'npub del peer (o fijalo desde la bandeja)'),
          const SizedBox(height: 6),
          for (final line in _chatLocal.take(50))
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(line, style: const TextStyle(fontSize: 12))),
          Row(children: [
            Expanded(child: _tf(_chatCtrl, 'mensaje…')),
            IconButton(
                onPressed: !conectado || _busy ? null : _enviar,
                icon: const Icon(Icons.send_rounded)),
          ]),
        ]),
        NostrnSocial(
          gestion: _gestion,
          onLog: (l) => setState(() {
            _registro.insert(0, l);
            if (_registro.length > 60) _registro.removeRange(60, _registro.length);
          }),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(_estado,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.white38)),
        ),
      ]),
    );
  }

  @override
  void dispose() {
    try {
      _gestion?.disconnect();
    } catch (_) {}
    for (final c in [
      _nombreCtrl,
      _pinCtrl,
      _dmRelaysCtrl,
      _readRelaysCtrl,
      _ventanaCtrl,
      _limiteCtrl,
      _perfilNameCtrl,
      _perfilDisplayCtrl,
      _perfilAboutCtrl,
      _perfilPicCtrl,
      _peerCtrl,
      _chatCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }
}
