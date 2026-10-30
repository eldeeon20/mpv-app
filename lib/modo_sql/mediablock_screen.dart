import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pr_app/services/app_db.dart';

import 'admin/panel_admin.dart';
import 'preview/dialogo_video.dart';
import 'app/claves_app.dart';
import 'cache/previa_cache.dart';
import 'cache/sesion_cache.dart';
import 'cache/trozo_cache.dart';
import 'db/caja_sql.dart';
import 'indice/indice.dart';
import 'comun/archivos_fs.dart';
import 'comun/campos.dart';
import 'lista/borrar_entrada.dart';
import 'lista/descargar_archivo.dart';
import 'lista/explorador.dart';
import 'lista/lista_archivos.dart';
import 'lista/pedir_rango.dart';
import 'lista/rango_logica.dart';
import 'moldes/form_crear.dart';
import 'moldes/indexar_dialog.dart';
import 'moldes/lista_moldes.dart';
import 'moldes/tags_dialog.dart';
import 'media_server/media_server.dart';
import 'minis/mini_cache.dart';
import 'minis/mini_grid.dart';
import 'preview/cargar_completo.dart';
import 'preview/visor_preview.dart';
import 'preview/vista_archivo.dart';
import 'preview_molde.dart';
import 'puente_hf.dart';
import '../services/hf.dart';
import '../services/telegram_bot_storage.dart';
import '../services/telegram_mld_manifest_store.dart';
import '../services/telegram_user_account.dart';
import 'tool/create_molde_sql.dart';

part 'mediablock/estado_previas.dart';
part 'mediablock/escaner_sql.dart';
part 'mediablock/ajustes.dart';
part 'mediablock/moldes_crud.dart';
part 'mediablock/indice_moldes.dart';
part 'mediablock/archivos.dart';
part 'mediablock/hf_flujos.dart';
part 'mediablock/hf_config.dart';

/// MediaBlock: crear molde desde una carpeta (recursiva, todo
/// cifrado en UN solo .mld), abrirlo, listar archivos y pedir rangos.
/// Pantalla dividida en partes equilibradas (`mediablock/`): cada
/// mixin agrupa una zona (previas, ajustes, escáner, CRUD de moldes,
/// índice, archivos, flujos HF y config HF).
class MediaBlockScreen extends StatefulWidget {
  const MediaBlockScreen({super.key});

  @override
  State<MediaBlockScreen> createState() => _MediaBlockScreenState();
}

class _MediaBlockScreenState extends State<MediaBlockScreen>
    with SingleTickerProviderStateMixin {
  /// Controller propio (el DefaultTabController.of con el contexto del
  /// State daba null y reventaba al crear: "Null check operator…").
  late final TabController _tabs;
  // Crear molde (clave ÚNICA: abre tu SQL y deriva el molde).
  final _nombreCtrl = TextEditingController();
  final _carpetaCtrl = TextEditingController();
  // Carpeta DESTINO en el índice (el molde nace anidado ahí).
  final _carpetaIndiceCtrl = TextEditingController();
  final _claveCtrl = TextEditingController();
  final _tagsCtrl = TextEditingController();
  bool _creando = false;

  // Moldes + abierto (server tonto + filas de TU sql).
  List<MoldeInfo> _moldes = [];
  MoldeInfo? _infoAbierta;
  List<FichaArchivo> _filas = [];

  /// Filas ya filtradas EN SQL (LIKE). null = sin filtro o fallback RAM.
  List<FichaArchivo>? _filasTag;
  final _tagFiltroCtrl = TextEditingController();

  /// Minis en RAM (clase) + caché local cifrada de trozos (LRU 512KB).
  final _minis = MiniCache();

  /// Captura de video (surface oculta mientras se crea).
  final _captura = CapturaVideo();
  TrozoCache? _cache;

  /// Caché de previas en disco (no re-abrir originales).
  PreviaCache? _previaCache;

  /// Ajustes: topes de caché (viven en app.db, clave `ajustes_modo`).
  /// Previas 50MB..8GB, trozos por molde 1MB..memoria libre,
  /// global evicta por LRU entre moldes al pasarlo.
  /// El viejo `ajustes_modo.json` no importa: se borra sin migrar.
  int _limiteTrozosKb = 512;
  int _limitePreviasMb = 256;
  int _limiteGlobalMb = 1024;
  int _memLibreMb = 2048;

  /// Tope RAM total (previas+stash+minis) según memoria libre.
  int _topeRamBytes = 1024 * 1024 * 1024;

  /// Recordar clave cifrada en la SQL local de la app.
  bool _recordar = true;

  /// Bytes completos memoizados para el visor (clase).
  final _completos = CargadorCompleto();

  // Rango.
  String? _selArchivo;
  final _desdeCtrl = TextEditingController(text: '0');
  final _hastaCtrl = TextEditingController();
  String _rangoInfo = '';

  final List<String> _log = [];
  bool _cargando = false;

  /// HF: repo (dir/user) + token por molde + puente.
  final _hfRepoCtrl = TextEditingController();
  final _hfTokenCtrl = TextEditingController();
  final _hfSqlCtrl = TextEditingController();

  /// HF del ÍNDICE: repo+token propios, independientes del molde.
  final _hfIndiceRepoCtrl = TextEditingController();
  final _hfIndiceTokenCtrl = TextEditingController();
  final _telegramBotTokenCtrl = TextEditingController();
  final _telegramBotChatCtrl = TextEditingController();
  final _telegramApiIdCtrl = TextEditingController();
  final _telegramApiHashCtrl = TextEditingController();
  final _telegramPhoneCtrl = TextEditingController();
  final _telegramCodeCtrl = TextEditingController();
  final _telegramPasswordCtrl = TextEditingController();
  final _telegramBot = TelegramBotStorage();
  final _telegramUser = TelegramUserAccount();
  StreamSubscription<TelegramUserAuth>? _telegramAuthSub;
  TelegramUserAuthStep _telegramUserStep = TelegramUserAuthStep.disconnected;
  String? _telegramUserError;
  final _puenteHf = PuenteHf();
  bool _hfOcupado = false;
  bool _telegramBotOcupado = false;
  bool _telegramIndexPendiente = true;

  /// HF: si va con tilde, subir molde(s) sube el índice junto
  /// (respaldo en el repo del molde). Sin tilde, no sube.
  bool _hfConIndice = true;

  /// ---- estado (vive acá; la lógica está en mediablock/) ----
  /// Zona: previas/unos en RAM (ver mediablock/estado_previas.dart).
  /// Previas guardadas por archivo (memo, se llena solo).
  /// Tope RAM 1GB (512MB en suave): lo viejo sale primero.
  /// SOBREVIVE al cambio de molde: al abrir otro se guarda el mapa
  /// en el stash y se restaura al volver (máx 3 moldes; volver no
  /// re-descifra nada).
  final _previas = <String, List<Uint8List>>{};
  int _previasBytes = 0;
  int _unoBytes = 0;

  /// Stash de previas por molde (mapa + bytes).
  final _previasStash = <String, Map<String, List<Uint8List>>>{};
  final _previasBytesStash = <String, int>{};

  /// Primer frame por archivo (solo grid de videos: 1 en vez de 17).
  /// Vive en RAM con el mismo stash por molde que `_previas`.
  final _uno = <String, Uint8List>{};
  final _unoFut = <String, Future<Uint8List?>>{};
  final _unoStash = <String, Map<String, Uint8List>>{};
  final _unoBytesStash = <String, int>{};

  /// Futuros memoizados: el MISMO future por archivo (si se crea uno
  /// nuevo en cada build, el FutureBuilder reconsulta SQL y
  /// redescifra en cada rebuild: eso frenaba el grid).
  final _previasFut = <String, Future<List<Uint8List>>>{};

  /// Zona: escáner SQL (ver mediablock/escaner_sql.dart).
  /// Rutas SQL extra para el escáner (una por línea, sin pass: todas
  /// se intentan con la misma pass de moldes). Viven en `ajustes_modo`.
  List<String> _sqlRutas = [];

  /// Pass por ruta SQL pedida a mano en el escáner (solo sesión, no se
  /// guarda: en Ajustes las rutas van sin pass, por orden explícita).
  final Map<String, String> _passPorRuta = {};

  /// Zona: ajustes de caché (ver mediablock/ajustes.dart).
  /// Zona: crear moldes (ver mediablock/moldes_crud.dart).
  /// Estado visible EN Crear (antes el resultado solo iba a la
  /// bitácora de Moldes y parecía que "no hacía nada").
  String _crearEstado = '';

  /// Zona: explorador del molde (ver mediablock/archivos.dart).
  /// Ruta dentro del molde (explorador). Se limpia al abrir.
  List<String> _rutaExp = const [];

  @override
  void dispose() {
    _filtroT?.cancel();
    _tagFiltroCtrl.removeListener(_filtroCambio);
    _tabs.removeListener(_alCambiarTab);
    _tabs.dispose();
    CajaSql.log = null;
    Indice.log = null;
    _captura.cerrar();
    _nombreCtrl.dispose();
    _carpetaCtrl.dispose();
    _carpetaIndiceCtrl.dispose();
    _claveCtrl.dispose();
    _tagsCtrl.dispose();
    _filtroMoldesCtrl.dispose();
    _tagFiltroCtrl.dispose();
    _desdeCtrl.dispose();
    _hastaCtrl.dispose();
    _indiceCtrl.dispose();
    _hfRepoCtrl.dispose();
    _hfTokenCtrl.dispose();
    _hfSqlCtrl.dispose();
    _hfIndiceRepoCtrl.dispose();
    _hfIndiceTokenCtrl.dispose();
    _telegramBotTokenCtrl.dispose();
    _telegramBotChatCtrl.dispose();
    _telegramBot.close();
    _telegramApiIdCtrl.dispose();
    _telegramApiHashCtrl.dispose();
    _telegramPhoneCtrl.dispose();
    _telegramCodeCtrl.dispose();
    _telegramPasswordCtrl.dispose();
    _telegramAuthSub?.cancel();
    _telegramUser.cerrar();
    _sesionCache.cerrar();
    super.dispose();
  }

  void _add(String s) {
    if (!mounted) return;
    setState(() => _log.add(s));
  }

  String get _clave => _claveCtrl.text;

  Future<void> _elegirCarpeta() async {
    final p = await elegirCarpeta();
    if (p != null && mounted) setState(() => _carpetaCtrl.text = p);
  }

  /// Sesión de caché (se desbloquea con la pass del índice).
  final _sesionCache = SesionCache();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _tabs.addListener(_alCambiarTab);
    // Filtro de tag en vivo con debounce: sin esto solo filtraba
    // cuando otro rebuild lo arrastraba (ej. al abrir una imagen).
    _tagFiltroCtrl.addListener(_filtroCambio);
    // Avisos de formato (lo viejo sale en rojo en la bitácora).
    CajaSql.log = _add;
    Indice.log = _add;
    _cargarAjustes();
    _telegramAuthSub = _telegramUser.authChanges.listen((auth) {
      if (!mounted) return;
      setState(() {
        _telegramUserStep = auth.step;
        _telegramUserError = auth.error;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _preguntarIndice());
  }

  /// Debounce de búsqueda de archivos/tags sobre las filas ya cargadas.
  Timer? _filtroT;
  void _filtroCambio() {
    _filtroT?.cancel();
    _filtroT = Timer(const Duration(milliseconds: 300), () async {
      final m = _infoAbierta?.nombre;
      final t = _tagFiltroCtrl.text.trim();
      if (m == null || t.isEmpty) {
        if (mounted) setState(() => _filasTag = null);
        return;
      }
      try {
        final q = t.toLowerCase();
        final filas = _filas
            .where((f) =>
                f.nombre.toLowerCase().contains(q) ||
                f.tags.any((tag) => tag.toLowerCase().contains(q)))
            .toList(growable: false);
        if (!mounted) return;
        // El filtro cambió mientras consultaba: se descarta.
        if (_tagFiltroCtrl.text.trim() != t) return;
        setState(() => _filasTag = filas);
      } catch (e) {
        _add('✗ búsqueda: $e');
      }
    });
  }

  /// Clave del ÍNDICE (propia, se pide al iniciar, NO se guarda).
  final _indiceCtrl = TextEditingController();

  /// Clave del índice: solo la escrita (nunca recordada).
  Future<String> _passIndice() async => _indiceCtrl.text;

  /// Pass de cada molde según el índice (liviano: qué sql + su pass).
  final Map<String, String> _passPorMolde = {};

  /// Entradas crudas del índice (para el panel admin).
  /// + en HF por molde (repo+versión: lo que ya está subido).
  final Map<String, ({String repo, int version})> _hfInfo = {};
  final Set<String> _telegramBotMoldes = {};
  final Map<String, Map<String, Object?>> _entradas = {};
  final Map<String, String> _carpetaPorMolde = {};

  /// Selección múltiple para subir a HF (tap largo en un molde).
  final Set<String> _selSubir = {};

  /// Filtro por nombre/carpeta en Moldes.
  final _filtroMoldesCtrl = TextEditingController();

  /// Server mira el MOLDE, user mira la SQL: la SQL (tool) da info +
  /// filas y con eso se abre el server (sin pass SQL en el server).

  @override
  Widget build(BuildContext context) {
    final archivos = _filtrados();
    // Atrás del celu navega: subcarpeta → raíz del molde → moldes.
    final dentro = _infoAbierta != null || _rutaExp.isNotEmpty;
    return PopScope(
      canPop: !dentro,
      onPopInvokedWithResult: (salio, _) {
        if (salio) return;
        if (_rutaExp.isNotEmpty) {
          setState(() => _rutaExp = _rutaExp.sublist(0, _rutaExp.length - 1));
        } else if (_infoAbierta != null) {
          _cerrarMolde();
        }
      },
      child: Stack(children: [
        Column(children: [
          Expanded(
            child: TabBarView(
              controller: _tabs,
              // Sin deslizar: las pestañas solo cambian tocando arriba.
              // El dedo horizontal ya no te saca del grid/lista.
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _tabCuadricula(archivos),
                _tabLista(archivos),
                _tabCrear(),
                _tabMoldes(),
                _tabAdmin(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF152438).withValues(alpha: 0.76),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                  child: TabBar(
                    controller: _tabs,
                    dividerColor: Colors.transparent,
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicator: BoxDecoration(
                      color: const Color(0xFF67E8F9).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    labelColor: const Color(0xFF9BEAF5),
                    unselectedLabelColor: const Color(0xFF9BAEC2),
                    labelStyle: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    ),
                    labelPadding: EdgeInsets.zero,
                    tabs: const [
                      Tab(icon: Icon(Icons.grid_view_rounded), text: 'Previas'),
                      Tab(
                          icon: Icon(Icons.folder_open_rounded),
                          text: 'Archivos'),
                      Tab(
                          icon: Icon(Icons.add_circle_outline_rounded),
                          text: 'Crear'),
                      Tab(
                          icon: Icon(Icons.inventory_2_outlined),
                          text: 'Moldes'),
                      Tab(icon: Icon(Icons.tune_rounded), text: 'Ajustes'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ]),
        // Surface oculta para capturas de video al crear (1px,
        // sin esto el mpv no renderiza y no hay frames).
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: _captura.vista(),
        ),
      ]),
    );
  }

  /// Modo suave: 2 hilos de descifrado (scroll libre, en orden).
  bool _suave = false;

  /// Caché visible en Admin (bytes por molde + hits/miss).
  final Map<String, int> _cacheBytes = {};
  String _cacheResumen = '';

  /// Total SIEMPRE visible (disco trozos+previas todos los moldes +
  /// RAM previas + RAM minis). Sin esto eras adivino.
  String _cacheTotalStr = '';

  /// Al entrar a Admin se mide de verdad (antes nadie llamaba esto).
  void _alCambiarTab() {
    if (_tabs.index == 4) _medirCache();
  }

  Future<void> _medirCache() async {
    try {
      final totalDisco = await _cacheTotal();
      final totalRam = _previasBytes + _stashBytes() + _minis.bytesEnRam;
      final total = totalDisco + totalRam;
      if (!mounted) return;
      setState(() {
        _cacheTotalStr = 'Total caché: ${fmtBytes(total)} '
            '(disco ${fmtBytes(totalDisco)} + RAM ${fmtBytes(totalRam)})';
      });
      final c = _cache;
      final molde = _infoAbierta?.nombre;
      if (c == null || molde == null) return;
      final b = await c.bytesEnCache();
      if (!mounted) return;
      setState(() {
        _cacheBytes[molde] = b;
        _cacheResumen = c.resumen();
      });
      await _chequearGlobal();
    } catch (_) {}
  }

  Future<void> _vaciarCache() async {
    try {
      await TrozoCache.limpiarTodo(_sesionCache);
      await PreviaCache.limpiarTodo(_sesionCache);
      if (!mounted) return;
      setState(() {
        _cacheBytes.clear();
        _cacheResumen = 'vacía';
      });
      _add('✓ cachés vaciadas (trozos + previas, se reconstruyen solas)');
    } catch (e) {
      _add('✗ vaciar cachés: $e');
    }
  }

  /// Ajustes: cachés (trozos + previas) + admin clásico abajo.
  /// (PanelAdmin ya es ListView: va en Expanded, no anidado.)
  Widget _tabAdmin() {
    final lista = _entradas.values.toList()
      ..sort((a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Cachés (sqlite cifradas, misma pass del índice)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Trozos por molde: ${fmtBytes(_limiteTrozosKb * 1024)} '
                  '(tope: memoria libre ${fmtBytes(_memLibreMb * 1024 * 1024)})'),
              Slider(
                min: 1024,
                max: (_memLibreMb * 1024).toDouble(),
                divisions: 40,
                value: _limiteTrozosKb
                    .toDouble()
                    .clamp(1024, (_memLibreMb * 1024).toDouble()),
                label: fmtBytes(_limiteTrozosKb * 1024),
                onChanged: (v) {
                  final tope = _memLibreMb * 1024;
                  setState(() => _limiteTrozosKb = v.toInt().clamp(1024, tope));
                  final c = _cache;
                  if (c != null) c.limiteBytes = _limiteTrozosKb * 1024;
                  _guardarAjustes();
                },
              ),
              Text(
                  'Previas por molde: ${fmtBytes(_limitePreviasMb * 1024 * 1024)} '
                  '(libres: miles de previas mínimas)'),
              Slider(
                min: 50,
                max: 8192,
                divisions: 80,
                value: _limitePreviasMb.toDouble().clamp(50, 8192),
                label: fmtBytes(_limitePreviasMb * 1024 * 1024),
                onChanged: (v) {
                  setState(() => _limitePreviasMb = v.toInt().clamp(50, 8192));
                  final p = _previaCache;
                  if (p != null) {
                    p.limiteBytes = _limitePreviasMb * 1024 * 1024;
                  }
                  _guardarAjustes();
                },
              ),
              Text('Límite global: ${fmtBytes(_limiteGlobalMb * 1024 * 1024)} '
                  '(evicta lo más viejo entre moldes al pasarlo)'),
              Slider(
                min: 100,
                max: 16384,
                divisions: 80,
                value: _limiteGlobalMb.toDouble().clamp(100, 16384),
                label: fmtBytes(_limiteGlobalMb * 1024 * 1024),
                onChanged: (v) {
                  setState(() => _limiteGlobalMb = v.toInt().clamp(100, 16384));
                  _guardarAjustes();
                  _chequearGlobal();
                },
              ),
              const Text(
                  'SQL a escanear (misma pass de moldes, sin pass por ruta)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Row(children: [
                Expanded(
                  child: Text(
                      _sqlRutas.isEmpty
                          ? 'Sin rutas extra (se escanean temp + carpeta de moldes)'
                          : '${_sqlRutas.length} ruta(s): ${_sqlRutas.take(2).join(' · ')}${_sqlRutas.length > 2 ? ' …' : ''}',
                      style: const TextStyle(fontSize: 12)),
                ),
                TextButton(
                    onPressed: _editarSqlRutas, child: const Text('Editar')),
              ]),
              Text(
                  _cacheTotalStr.isEmpty
                      ? 'Total caché: sin medir (entrá a Admin para medir)'
                      : _cacheTotalStr,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(_cacheResumen.isEmpty
                  ? 'Sin medición todavía'
                  : _cacheResumen),
              const Divider(height: 12),
            ],
          ),
        ),
        Expanded(
          child: PanelAdmin(
            entradas: lista,
            onMover: _moverMolde,
            onEditarRutas: _editarRutas,
            cacheBytes: _cacheBytes,
            cacheResumen: _cacheResumen,
            cacheLimiteKb: _limiteTrozosKb,
            onVaciarCache: _vaciarCache,
            suave: _suave,
            onSuave: (v) => setState(() {
              _suave = v;
              _minis.maxEnVuelo = v ? 2 : 6;
              // El tope RAM lo pone la memoria libre (suave recorta).
              _aplicarTopeRam();
              _minis.limpiar();
            }),
            hilosEnUso: _minis.enVuelo,
            maxHilos: _minis.maxEnVuelo,
          ),
        ),
      ],
    );
  }

  /// Principal: visor en cuadrícula con scroll LIBRE (un solo
  /// scroll sliver, sin caja anidada que trabe el dedo).
  /// Carpetas de moldes (para grid y lista cuando no hay abierto).
  Widget _carpetasMoldes() {
    return ListaMoldes(
      moldes: _moldes,
      abierta: _infoAbierta?.nombre,
      cargando: _cargando,
      onRecargar: _refrescarMoldes,
      onAbrir: _abrirMolde,
      onBorrar: _borrarMolde,
      hfInfo: _hfInfo,
      telegramBotMoldes: _telegramBotMoldes,
      // Grid/lista no borran: eso es de la pestaña Moldes.
      conBorrar: false,
      // Pero SÍ muestran el árbol del índice (mover solo en Moldes).
      carpetas: _carpetaPorMolde,
    );
  }

  Widget _tabCuadricula(List<FichaArchivo> archivos) {
    if (_infoAbierta == null) {
      // Grid y lista también muestran los moldes como carpetas.
      if (_moldes.isEmpty) {
        return VacioConMas(
          texto: 'No hay moldes cargados',
          boton: 'Crear molde',
          onMas: () => _tabs.animateTo(2),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('Moldes (tocá la carpeta para abrir)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _carpetasMoldes(),
        ],
      );
    }
    // Explorador también en grid: carpetas + imágenes de la ruta.
    final hijos = hijosDe(archivos, _rutaExp);
    return MiniGrid(
      imagenes: ArchivosMbExt._soloImgs(hijos.directos),
      otros: [
        for (final f in hijos.directos)
          if (!ArchivosMbExt._imgs.contains(f.formato.toLowerCase())) f
      ],
      minis: _minis.minis,
      // Previas en RAM (lo que el grid muestra sin tocar original).
      minisEnRam: _previas.length + _uno.length,
      selNombre: _selArchivo,
      previas: _previas,
      previasDe: _previasDe,
      previaUno: _uno,
      previaUnoDe: _previaUnoDe,
      esVideo: (f) => PreviewMolde.esVideo(f.formato),
      dirs: hijos.subdirs,
      onEntrarDir: (d) => _entrarDir([..._rutaExp, d]),
      encabezado: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Visor (tocá para pantalla completa)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          campoTexto(_tagFiltroCtrl, 'buscar archivo o tag…'),
          const SizedBox(height: 6),
          migasRuta(
            molde: _infoAbierta!.nombre,
            ruta: _rutaExp,
            onRuta: _entrarDir,
            onSalir: _cerrarMolde,
          ),
        ],
      ),
      onTap: (f) {
        setState(() {
          _selArchivo = f.nombre;
          _hastaCtrl.text = '${f.tamano}';
          _rangoInfo = '';
        });
        // Videos: visor de sus 17 previas + reproducir/guardar.
        // El resto: flujo normal (visor o recuperar).
        if (PreviewMolde.esVideo(f.formato)) {
          _verVideo(f);
        } else {
          _recuperar(f);
        }
      },
    );
  }

  /// Explorador del molde (sus carpetas nativas, se entra y sale).
  Widget _tabLista(List<FichaArchivo> archivos) {
    if (_infoAbierta == null) {
      if (_moldes.isEmpty) {
        return VacioConMas(
          texto: 'No hay moldes cargados',
          boton: 'Crear molde',
          onMas: () => _tabs.animateTo(2),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('Moldes (tocá la carpeta para abrir)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          _carpetasMoldes(),
        ],
      );
    }
    // Un solo scroll libre + filas perezosas (solo lo visible).
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('Lista de "${_infoAbierta!.nombre}"',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    tooltip: 'Papelera y restauración',
                    onPressed: _mostrarPapelera,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                  TextButton(
                    onPressed: _quitarDuplicados,
                    child: const Text('Quitar duplicados',
                        style: TextStyle(fontSize: 11)),
                  ),
                ]),
                const SizedBox(height: 6),
                campoTexto(_tagFiltroCtrl, 'buscar archivo o tag…'),
              ],
            ),
          ),
        ),
        ...sliversExplorador(
          molde: _infoAbierta!.nombre,
          archivos: archivos,
          ruta: _rutaExp,
          onRuta: _entrarDir,
          sel: _selArchivo,
          onSel: (f) {
            setState(() {
              _selArchivo = f.nombre;
              _hastaCtrl.text = '${f.tamano}';
              _rangoInfo = '';
            });
            // Tap = preview directo (visor si es imagen, video si es
            // video, si no abre).
            if (PreviewMolde.esVideo(f.formato)) {
              _verVideo(f);
            } else {
              _recuperar(f);
            }
          },
          onTags: _editarTags,
          onRecuperar: _descargarArchivo,
          onBorrar: _borrarEntrada,
          onSalir: _cerrarMolde,
        ),
        if (_selArchivo != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: PedirRango(
                desde: _desdeCtrl,
                hasta: _hastaCtrl,
                info: _rangoInfo,
                onRango: _pedirRango,
                onEntero: _pedirArchivo,
              ),
            ),
          ),
      ],
    );
  }

  /// Crear: solo el formulario.
  Widget _tabCrear() {
    return FormCrear(
      nombre: _nombreCtrl,
      carpeta: _carpetaCtrl,
      clave: _claveCtrl,
      tags: _tagsCtrl,
      carpetaIndice: _carpetaIndiceCtrl,
      creando: _creando,
      estado: _crearEstado,
      onElegir: _elegirCarpeta,
      onCrear: _crear,
    );
  }

  /// Moldes: clave + recordar + historial + bitácora.
  Widget _tabMoldes() {
    // Buscador por nombre/carpeta (filtra la lista, no toca nada).
    final f = _filtroMoldesCtrl.text.trim().toLowerCase();
    final vistos = f.isEmpty
        ? _moldes
        : [
            for (final m in _moldes)
              if (m.nombre.toLowerCase().contains(f) ||
                  (_carpetaPorMolde[m.nombre] ?? '').toLowerCase().contains(f))
                m
          ];
    // La selección muerta (molde filtrado/borrado) se limpia sola.
    _selSubir.removeWhere((n) => !_moldes.any((m) => m.nombre == n));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        campoTexto(_indiceCtrl, 'clave del ÍNDICE (propia)', oculto: true),
        const SizedBox(height: 6),
        campoTexto(_claveCtrl, 'clave ÚNICA (tu SQL + molde)', oculto: true),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Recordar clave (cifrada, app local)',
              style: TextStyle(fontSize: 12)),
          value: _recordar,
          onChanged: (v) => setState(() => _recordar = v ?? true),
        ),
        FilledButton.tonalIcon(
          onPressed: _indexarCarpeta,
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('Indexar carpeta…'),
        ),
        const SizedBox(height: 6),
        campoTexto(_filtroMoldesCtrl, 'buscar molde o carpeta…',
            onChanged: (_) {
          if (mounted) setState(() {});
        }),
        // Selección para subir (tap largo en un molde): por hash
        // salta lo que ya está arriba.
        if (_selSubir.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: Text('${_selSubir.length} elegido(s)',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            TextButton(
              onPressed: () => setState(() => _selSubir.clear()),
              child: const Text('Limpiar'),
            ),
            FilledButton.icon(
              onPressed: _hfOcupado ? null : _subirSeleccionados,
              icon: const Icon(Icons.cloud_upload_rounded, size: 18),
              label: const Text('Subir'),
            ),
          ]),
        ],
        const SizedBox(height: 6),
        ListaMoldes(
          moldes: vistos,
          abierta: _infoAbierta?.nombre,
          cargando: _cargando,
          onRecargar: _refrescarMoldes,
          onAbrir: _abrirMolde,
          onBorrar: _borrarMolde,
          hfInfo: _hfInfo,
          telegramBotMoldes: _telegramBotMoldes,
          carpetas: _carpetaPorMolde,
          onMover: _moverMoldeCarpeta,
          onHf: _hfDeMolde,
          seleccion: _selSubir,
          onToggleSel: (n) => setState(() {
            if (!_selSubir.remove(n)) _selSubir.add(n);
          }),
          onToggleCarpeta: (dentro) => setState(() {
            if (dentro.every(_selSubir.contains)) {
              _selSubir.removeAll(dentro);
            } else {
              _selSubir.addAll(dentro);
            }
          }),
        ),
        const Divider(height: 20),
        const Text('HuggingFace (repo + token del molde abierto)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        campoTexto(_hfRepoCtrl, 'repo dir/user (ej. miuser/mis-moldes)'),
        const SizedBox(height: 6),
        campoTexto(_hfTokenCtrl, 'token HF (write para subir)', oculto: true),
        const SizedBox(height: 6),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Subir índice junto al molde',
              style: TextStyle(fontSize: 12)),
          value: _hfConIndice,
          onChanged: (v) => setState(() => _hfConIndice = v ?? true),
        ),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: _hfOcupado ? null : _hfGuardar,
            icon: const Icon(Icons.save_rounded, size: 18),
            label: const Text('Guardar HF'),
          ),
          FilledButton.tonalIcon(
            onPressed: _hfOcupado ? null : _hfSubir,
            icon: const Icon(Icons.cloud_upload_rounded, size: 18),
            label: const Text('Subir molde+SQL'),
          ),
          FilledButton.tonalIcon(
            onPressed: _hfOcupado ? null : _hfBajarSql,
            icon: const Icon(Icons.cloud_download_rounded, size: 18),
            label: const Text('Bajar SQL'),
          ),
        ]),
        const Divider(height: 20),
        const Text('Índice (repo propio, independiente del molde)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        campoTexto(_hfIndiceRepoCtrl,
            'repo del ÍNDICE dir/user (ej. miuser/mi-indice)'),
        const SizedBox(height: 6),
        campoTexto(_hfIndiceTokenCtrl, 'token del ÍNDICE (write para subir)',
            oculto: true),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: _hfOcupado ? null : _hfGuardarIndice,
            icon: const Icon(Icons.save_rounded, size: 18),
            label: const Text('Guardar HF índice'),
          ),
          FilledButton.tonalIcon(
            onPressed: _hfOcupado ? null : _hfSubirIndice,
            icon: const Icon(Icons.cloud_upload_rounded, size: 18),
            label: const Text('Subir índice'),
          ),
          FilledButton.tonalIcon(
            onPressed: _hfOcupado ? null : _hfBajarIndice,
            icon: const Icon(Icons.cloud_download_rounded, size: 18),
            label: const Text('Bajar índice'),
          ),
        ]),
        const Divider(height: 20),
        const Text('Telegram Bot API (subida automática por partes)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'El bot no permite buscar el historial. MediaBlock guarda las partes '
          'de 17 MB y un hash.db cifrado con la clave del molde; index.db '
          'conserva el file_id para encontrarlas. El .mld no se cifra otra vez.',
          style: TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 6),
        campoTexto(_telegramBotTokenCtrl, 'token de BotFather', oculto: true),
        const SizedBox(height: 6),
        campoTexto(_telegramBotChatCtrl,
            'chat ID (iniciá el bot o agregalo al grupo primero)'),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: _telegramBotOcupado ? null : _telegramBotGuardar,
            icon: const Icon(Icons.verified_user_rounded, size: 18),
            label: const Text('Validar y guardar bot'),
          ),
          FilledButton.tonalIcon(
            onPressed: _telegramBotOcupado ? null : _telegramBotSubirMolde,
            icon: _telegramBotOcupado
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_rounded, size: 18),
            label: const Text('Subir molde por bot'),
          ),
        ]),
        const Divider(height: 20),
        const Text('Cuenta Telegram personal (TDLib)',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'Esta cuenta usa Mensajes guardados para buscar y respaldar index.db. '
          'En Android inicia sesión con teléfono, código y la clave 2FA si la '
          'cuenta la solicita. Las credenciales y la clave TDLib quedan dentro '
          'del index.db cifrado.',
          style: TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 6),
        campoTexto(_telegramApiIdCtrl, 'API ID de my.telegram.org'),
        const SizedBox(height: 6),
        campoTexto(_telegramApiHashCtrl, 'API Hash', oculto: true),
        const SizedBox(height: 6),
        FilledButton.tonalIcon(
          onPressed: _telegramCuentaGuardar,
          icon: const Icon(Icons.login_rounded, size: 18),
          label: const Text('Guardar credenciales e iniciar TDLib'),
        ),
        if (_telegramUserStep == TelegramUserAuthStep.waitingPhone) ...[
          const SizedBox(height: 6),
          campoTexto(_telegramPhoneCtrl, 'teléfono internacional (+...)'),
          FilledButton.tonal(
            onPressed: _telegramEnviarPasoAuth,
            child: const Text('Enviar teléfono'),
          ),
        ],
        if (_telegramUserStep == TelegramUserAuthStep.waitingCode) ...[
          const SizedBox(height: 6),
          campoTexto(_telegramCodeCtrl, 'código recibido de Telegram'),
          FilledButton.tonal(
            onPressed: _telegramEnviarPasoAuth,
            child: const Text('Enviar código'),
          ),
        ],
        if (_telegramUserStep == TelegramUserAuthStep.waitingPassword) ...[
          const SizedBox(height: 6),
          campoTexto(_telegramPasswordCtrl, 'contraseña 2FA', oculto: true),
          FilledButton.tonal(
            onPressed: _telegramEnviarPasoAuth,
            child: const Text('Enviar contraseña'),
          ),
        ],
        if (_telegramUserStep == TelegramUserAuthStep.ready)
          const ListTile(
            dense: true,
            leading: Icon(Icons.verified_rounded, color: Colors.greenAccent),
            title: Text('Cuenta Telegram autorizada'),
            subtitle: Text('Preparando Mensajes guardados…'),
          ),
        if (_telegramUserError != null)
          Text(
            _telegramUserError!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ListTile(
          dense: true,
          leading: Icon(
            _telegramIndexPendiente
                ? Icons.cloud_off_rounded
                : Icons.cloud_done_rounded,
            color: _telegramIndexPendiente
                ? Colors.amberAccent
                : Colors.greenAccent,
          ),
          title: Text(_telegramIndexPendiente
              ? 'index.db: respaldo pendiente'
              : 'index.db: respaldado'),
          subtitle: Text(_telegramIndexPendiente
              ? 'El último respaldo no contiene los cambios locales.'
              : 'El hash local coincide con el último respaldo registrado.'),
        ),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: _telegramUser.isReady ? _telegramSubirIndice : null,
            icon: const Icon(Icons.backup_rounded, size: 18),
            label: const Text('Respaldar index.db'),
          ),
          FilledButton.tonalIcon(
            onPressed: _telegramUser.isReady ? _telegramBajarIndice : null,
            icon: const Icon(Icons.restore_rounded, size: 18),
            label: const Text('Restaurar último respaldo'),
          ),
        ]),
        const SizedBox(height: 6),
        campoTexto(_hfSqlCtrl, 'ruta .db suelta para escanear'),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: _hfEscanearSql,
            icon: const Icon(Icons.find_in_page_rounded, size: 18),
            label: const Text('Escanear SQL'),
          ),
        ]),
        const Divider(height: 20),
        Row(children: [
          const Text('Bitácora', style: TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: 'Copiar toda (para pegar el error)',
            onPressed: () async {
              final todo = _log.join('\n');
              if (todo.isEmpty) return;
              await Clipboard.setData(ClipboardData(text: todo));
              _add('· bitácora copiada (${_log.length} líneas)');
            },
          ),
        ]),
        for (final l in _log)
          if (l.startsWith('⚠'))
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade900,
                border: Border.all(color: Colors.redAccent, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.yellowAccent, size: 32),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      l,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            SelectableText(l, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
