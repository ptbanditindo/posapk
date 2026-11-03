import 'package:flutter/material.dart';

import '../auth/operator.dart';
import '../state/app_state.dart';
import 'screens/customers_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/history_screen.dart';
import 'screens/jasa_screen.dart';
import 'screens/pos_screen.dart';
import 'screens/premium_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/stock_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _position = 0;

  static const _allLabels = [
    'Ringkasan',
    'Kasir',
    'Riwayat',
    'Pelanggan',
    'Stok',
    'Jasa',
    'Laporan',
    'Pengaturan',
    'Premium',
  ];
  static const _allIcons = [
    Icons.dashboard_outlined,
    Icons.point_of_sale_outlined,
    Icons.history,
    Icons.people_outline,
    Icons.inventory_2_outlined,
    Icons.build_outlined,
    Icons.bar_chart_outlined,
    Icons.settings_outlined,
    Icons.workspace_premium_outlined,
  ];

  Operator get _operator => AppState.instance.operator ?? Operator.owner;

  List<int> get _visible {
    final operator = _operator;
    if (operator.isOwner) {
      return List.generate(_allLabels.length, (index) => index);
    }
    final screens = <int>[0, 2, 3, 4];
    if (operator.canWriteMoney) screens.add(1);
    if (operator.can('lihat_laporan')) screens.add(6);
    screens.sort();
    return screens;
  }

  List<Widget> _screens() => [
        DashboardScreen(onNavigate: _goScreen),
        const PosScreen(),
        const HistoryScreen(),
        const CustomersScreen(),
        const StockScreen(),
        const JasaScreen(),
        const ReportsScreen(),
        const SettingsScreen(),
        const PremiumScreen(),
      ];

  void _goScreen(int screenIndex) {
    final position = _visible.indexOf(screenIndex);
    if (position >= 0) setState(() => _position = position);
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppState.instance;
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final visible = _visible;
        if (_position >= visible.length) _position = 0;
        final screenIndex = visible[_position.clamp(0, visible.length - 1)];
        final wide = MediaQuery.sizeOf(context).width >= 900;
        final body = IndexedStack(index: screenIndex, children: _screens());
        return Scaffold(
          key: _scaffoldKey,
          drawer: _buildDrawer(context, visible),
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _allLabels[screenIndex],
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${appState.operator?.label ?? 'Pemilik'} · '
                  '${appState.storeAddress.isEmpty ? appState.storeName : appState.storeAddress}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Ganti tema',
                onPressed: () {
                  final dark = Theme.of(context).brightness == Brightness.dark;
                  appState.setThemeMode(
                    dark ? ThemeMode.light : ThemeMode.dark,
                  );
                },
                icon: Icon(
                  Theme.of(context).brightness == Brightness.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: wide
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _position,
                      extended: MediaQuery.sizeOf(context).width >= 1180,
                      labelType: MediaQuery.sizeOf(context).width >= 1180
                          ? NavigationRailLabelType.none
                          : NavigationRailLabelType.all,
                      onDestinationSelected: (value) =>
                          setState(() => _position = value),
                      leading: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 12),
                        child: Icon(
                          Icons.storefront_outlined,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      destinations: [
                        for (final index in visible)
                          NavigationRailDestination(
                            icon: Icon(_allIcons[index]),
                            selectedIcon: Icon(
                              _allIcons[index],
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            label: Text(_allLabels[index]),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: body),
                  ],
                )
              : body,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _position < 3 ? _position : 3,
                  onDestinationSelected: (value) {
                    if (value == 3) {
                      _scaffoldKey.currentState?.openDrawer();
                    } else {
                      setState(() => _position = value);
                    }
                  },
                  destinations: [
                    for (var i = 0; i < 3 && i < visible.length; i++)
                      NavigationDestination(
                        icon: Icon(_allIcons[visible[i]]),
                        selectedIcon: Icon(_allIcons[visible[i]]),
                        label: _allLabels[visible[i]],
                      ),
                    const NavigationDestination(
                      icon: Icon(Icons.menu),
                      label: 'Menu',
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildDrawer(BuildContext context, List<int> visible) {
    final appState = AppState.instance;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    child: Icon(
                      Icons.storefront_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          appState.storeName,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '${appState.operator?.label ?? 'Pemilik'} · '
                          '${appState.storeAddress.isEmpty ? 'PusatkuPOS' : appState.storeAddress}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final screenIndex = visible[index];
                  return ListTile(
                    selected: _position == index,
                    leading: Icon(_allIcons[screenIndex]),
                    title: Text(_allLabels[screenIndex]),
                    onTap: () {
                      setState(() => _position = index);
                      Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'PusatkuPOS · mode lokal',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
