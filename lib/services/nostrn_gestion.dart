import '../src/rust/api/nostrn_gestion.dart' as rust;

/// Nostrn+: cuentas con PIN, perfil kind 0, bandeja sin peer y chat
/// NIP-17. Wrapper fino sobre la API FRB.
class NostrnGestion {
  static const defaultDmRelays = ['wss://nos.lol'];
  static const defaultReadRelays = ['wss://relay.primal.net'];

  Future<bool> hayCuenta(String dir) => rust.gestionHayCuenta(dir: dir);

  Future<rust.GestionCuenta> crearCuenta({
    required String pin,
    required String dir,
    required String nombre,
  }) =>
      rust.gestionCrearCuenta(pin: pin, dir: dir, nombre: nombre);

  Future<rust.GestionCuenta> guardarCuenta({
    required String pin,
    required String dir,
    required String nombre,
    required String nsec,
  }) =>
      rust.gestionGuardarCuenta(
          pin: pin, dir: dir, nombre: nombre, nsec: nsec);

  Future<rust.GestionCuenta> cargarCuenta({
    required String pin,
    required String dir,
  }) =>
      rust.gestionCargarCuenta(pin: pin, dir: dir);

  Future<rust.GestionViva> nuevaSesion({String? nsec}) =>
      rust.gestionNew(nsec: nsec);

  Future<rust.PerfilNostrn> perfilGet({
    required String npub,
    List<String> relays = const [],
    int timeoutSecs = 10,
  }) =>
      rust.gestionPerfilGet(
        npub: npub,
        relays: relays,
        timeoutSecs: timeoutSecs,
      );
}
