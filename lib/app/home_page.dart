import 'package:flutter/material.dart';

import '../modo_sql/mediablock_screen.dart';

/// Inicio de la app: almacenamiento de MediaBlock y sus previas.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _navigationRequest = ValueNotifier<int>(-1);

  void _navigate(int tab) {
    Navigator.of(context).pop();
    _navigationRequest.value = -1;
    _navigationRequest.value = tab;
  }

  @override
  void dispose() {
    _navigationRequest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const DrawerHeader(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    'MPV · almacenamiento',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.grid_view_rounded),
                title: const Text('Previas'),
                onTap: () => _navigate(0),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('Archivos'),
                onTap: () => _navigate(1),
              ),
              ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: const Text('Moldes'),
                onTap: () => _navigate(3),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_rounded),
                title: const Text('Cuentas y servidores'),
                subtitle: const Text('Telegram Bot · Hugging Face · TDLib'),
                onTap: () => _navigate(5),
              ),
              ListTile(
                leading: const Icon(Icons.tune_rounded),
                title: const Text('Ajustes'),
                onTap: () => _navigate(4),
              ),
            ],
          ),
        ),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF10243A),
              Color(0xFF07111F),
              Color(0xFF050B14),
            ],
            stops: [0, 0.42, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const _DriveHeader(),
              Expanded(
                child: MediaBlockScreen(
                  navigationRequest: _navigationRequest,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DriveHeader extends StatelessWidget {
  const _DriveHeader();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          width < 420 ? 16 : 24, 10, width < 420 ? 16 : 24, 12),
      child: Row(
        children: [
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Abrir menú',
              onPressed: () => Scaffold.of(context).openDrawer(),
              icon: const Icon(Icons.menu_rounded),
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF67E8F9), Color(0xFF38BDF8)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.2),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.storage_rounded,
              color: Color(0xFF062033),
              size: 25,
            ),
          ),
          const SizedBox(width: 13),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mi almacenamiento',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Archivos cifrados y vistas previas',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF9BAEC2),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
