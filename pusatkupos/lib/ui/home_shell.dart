import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/operator.dart';
import '../auth/permissions.dart';
import '../data/app_database.dart';
import '../data/feature_flags.dart';
import '../data/purchase_service.dart';
import '../data/session_service.dart';
import '../data/store_registry.dart';
import '../data/store_service.dart';
import '../state/app_state.dart';
import 'entry_gate.dart';
import 'pin_gate.dart';
import 'widgets.dart';
import 'screens/customers_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/employees_screen.dart';
import 'screens/followup_screen.dart';
import 'screens/history_screen.dart';
import 'screens/jasa_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/pos_screen.dart';
import 'screens/premium_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/stock_screen.dart';
import 'screens/supplier_screen.dart';
import 'widgets/store_switcher.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final Set<int> _built = {};
  int _position = 0;
  List<StoreRecord> _stores = const [];
  Timer? _idleTimer;
  DateTime? _pausedAt;
  int _autoLockMinutes = 0;
  bool _locking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoLockMinutes = AppState.instance.autoLockMinutes;
    AppState.instance.addListener(_syncAutoLock);
    _resetIdleTimer();
    _loadStores();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    AppState.instance.removeListener(_syncAutoLock);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
      _idleTimer?.cancel();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt != null &&
        _autoLockMinutes > 0 &&
        DateTime.now().difference(pausedAt) >=
            Duration(minutes: _autoLockMinutes)) {
      _lock();
    } else {
      _resetIdleTimer();
    }
  }

  void _syncAutoLock() {
    if (_autoLockMinutes == AppState.instance.autoLockMinutes) return;
    _autoLockMinutes = AppState.instance.autoLockMinutes;
    _resetIdleTimer();
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    if (_autoLockMinutes <= 0 || !AppState.instance.pinConfigured) return;
    _idleTimer = Timer(Duration(minutes: _autoLockMinutes), _lock);
  }

  Future<void> _lock() async {
    if (_locking || !mounted) return;
    _idleTimer?.cancel();
    final profile = await SessionService.instance.load();
    if (profile == null || !mounted) return;
    _locking = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PinGate(profile: profile, unlockOnly: true),
        ),
      );
    } finally {
      _locking = false;
      if (mounted) _resetIdleTimer();
    }
  }

  Future<void> _loadStores() async {
    try {
      final stores = await StoreService.instance.listStores();
      if (!mounted) return;
      final operator = _operator;
      setState(() {
        _stores = operator.isOwner
            ? stores
            : stores
                .where((store) => operator.storeIds.contains(store.storeId))
                .toList();
      });
    } catch (_) {
      // Registry toko belum siap; menu ganti toko tetap tersembunyi.
    }
    await _checkDebtReminders();
  }

  /// Pengingat jatuh tempo H-3 dan lewat jatuh tempo (BD-21). Ditampilkan
  /// sekali per hari per nota; log disimpan di `debt_reminder_logs`.
  Future<void> _checkDebtReminders() async {
    if (!FeatureFlagsService.instance.purchaseDebtEnabled) return;
    final operator = _operator;
    if (!operator.isOwner && !operator.can(permissionViewPurchase)) return;
    try {
      final reminders = await PurchaseService.instance.dueReminders();
      if (!mounted || reminders.isEmpty) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Pengingat utang supplier'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in reminders)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      row['level'] == 'LEWAT'
                          ? Icons.error_outline
                          : Icons.schedule_outlined,
                      color: row['level'] == 'LEWAT'
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    title: Text('${row['no_pembelian']}'),
                    subtitle: Text(
                      '${row['supplier_nama_snapshot']} · jatuh tempo '
                      '${row['jatuh_tempo']}',
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Mengerti'),
            ),
          ],
        ),
      );
    } catch (_) {
      // Pengingat tidak boleh menghalangi pembukaan aplikasi.
    }
  }

  String _activeStoreName() {
    for (final store in _stores) {
      if (store.storeId == AppDatabase.instance.activeStoreId) {
        return store.nama;
      }
    }
    return 'Pilih toko aktif';
  }

  Future<void> _openStoreSwitcher() async {
    final operator = _operator;
    if (_stores.length <= 1) return;
    final activeId = AppDatabase.instance.activeStoreId ?? 'utama';
    final selected = await showDialog<StoreRecord>(
      context: context,
      builder: (context) => StoreSwitcherDialog(
        stores: _stores,
        activeId: activeId,
      ),
    );
    if (selected == null || !mounted) return;
    if (selected.storeId == activeId) return;
    final allowed = operator.isOwner ? null : operator.storeIds.toSet();
    try {
      await StoreService.instance.switchStore(
        selected.storeId,
        allowedStoreIds: allowed,
      );
      await AppState.instance.reloadStore();
      await _loadStores();
      if (!mounted) return;
      showSnack(context, 'Toko aktif: ${selected.nama}.');
    } catch (error) {
      if (!mounted) return;
      showSnack(context, '$error', error: true);
    }
  }

  static const _allLabels = [
    'Ringkasan',
    'Kasir',
    'Riwayat',
    'Pelanggan',
    'Stok',
    'Order',
    'Jasa',
    'Laporan',
    'Supplier & Reseller',
    'Follow up',
    'Karyawan',
    'Pengaturan',
    'Premium',
  ];
  static const _allIcons = [
    Icons.dashboard_outlined,
    Icons.point_of_sale_outlined,
    Icons.history,
    Icons.people_outline,
    Icons.inventory_2_outlined,
    Icons.assignment_outlined,
    Icons.build_outlined,
    Icons.bar_chart_outlined,
    Icons.local_shipping_outlined,
    Icons.notifications_active_outlined,
    Icons.badge_outlined,
    Icons.settings_outlined,
    Icons.workspace_premium_outlined,
  ];

  /// Kunci akses untuk tiap layar sesuai urutan `_allLabels`.
  static const _screenAccess = [
    'lihat_ringkasan',
    'lihat_kasir',
    'lihat_riwayat',
    'lihat_pelanggan',
    'lihat_stok',
    'lihat_order',
    'lihat_jasa',
    'lihat_laporan',
    'lihat_supplier',
    'lihat_followup',
    'lihat_karyawan',
    'lihat_pengaturan',
    'lihat_premium',
  ];

  Operator get _operator => AppState.instance.operator ?? Operator.owner;

  /// Menu opsional disembunyikan mengikuti saklar fitur per toko. Fitur wajib
  /// tetap tampil walau data historis berasal dari masa fitur aktif.
  bool _featureAllows(int index) {
    final flags = FeatureFlagsService.instance;
    return switch (index) {
      5 => flags.isEnabled(featureOrderKerja),
      8 => flags.supplierHubEnabled,
      9 => flags.isEnabled(featureFollowup),
      _ => true,
    };
  }

  List<int> get _visible {
    final operator = _operator;
    if (operator.isOwner) {
      return [
        for (var index = 0; index < _allLabels.length; index++)
          if (_featureAllows(index)) index,
      ];
    }
    return [
      for (var index = 0; index < _screenAccess.length; index++)
        if (operator.can(_screenAccess[index]) && _featureAllows(index))
          index,
    ];
  }

  Widget _screen(int index) => switch (index) {
        0 => DashboardScreen(onNavigate: _goScreen),
        1 => const PosScreen(),
        2 => const HistoryScreen(),
        3 => const CustomersScreen(),
        4 => const StockScreen(),
        5 => const OrdersScreen(),
        6 => const JasaScreen(),
        7 => const ReportsScreen(),
        8 => const SupplierScreen(),
        9 => FollowupScreen(onOpenPremium: () => _goScreen(12)),
        10 => const EmployeesScreen(),
        11 => const SettingsScreen(),
        12 => const PremiumScreen(),
        _ => const SizedBox.shrink(),
      };

  /// Layar dibangun saat pertama dibuka agar mode ringkasan/karyawan tidak
  /// memuat seluruh layar kasir.
  List<Widget> _screens(int active) {
    _built.add(active);
    return List.generate(
      _allLabels.length,
      (index) => _built.contains(index)
          ? _screen(index)
          : const SizedBox.shrink(),
    );
  }

  void _goScreen(int screenIndex) {
    final position = _visible.indexOf(screenIndex);
    if (position >= 0) setState(() => _position = position);
  }

  Widget _buildNoAccess() {
    return Scaffold(
      appBar: AppBar(title: const Text('Akses terbatas')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Akun ini belum diberi akses menu apa pun.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Hubungi pemilik untuk mengatur menu dan tindakan yang boleh dibuka.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => signOutToOnboarding(context),
                icon: const Icon(Icons.logout),
                label: const Text('Keluar'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppState.instance;
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final visible = _visible;
        if (visible.isEmpty) {
          return _buildNoAccess();
        }
        if (_position >= visible.length) _position = 0;
        final screenIndex = visible[_position.clamp(0, visible.length - 1)];
        final wide = MediaQuery.sizeOf(context).width >= 900;
        final body = IndexedStack(
          key: ValueKey(appState.storeRevision),
          index: screenIndex,
          children: _screens(screenIndex),
        );
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _resetIdleTimer(),
          child: Scaffold(
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
                itemCount: visible.length + (_stores.length > 1 ? 1 : 0),
                itemBuilder: (context, index) {
                  if (_stores.length > 1 && index == 0) {
                    return ListTile(
                      leading: const Icon(Icons.swap_horiz),
                      title: const Text('Ganti toko'),
                      subtitle: Text(_activeStoreName()),
                      onTap: () {
                        Navigator.of(context).pop();
                        _openStoreSwitcher();
                      },
                    );
                  }
                  final itemIndex =
                      _stores.length > 1 ? index - 1 : index;
                  if (itemIndex >= visible.length) {
                    return const SizedBox.shrink();
                  }
                  final screenIndex = visible[itemIndex];
                  return ListTile(
                    selected: _position == itemIndex,
                    leading: Icon(_allIcons[screenIndex]),
                    title: Text(_allLabels[screenIndex]),
                    onTap: () {
                      setState(() => _position = itemIndex);
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
