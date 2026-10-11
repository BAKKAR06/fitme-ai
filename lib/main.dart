import 'package:flutter/material.dart';

import 'api.dart';
import 'avatar_2d.dart';
import 'catalog_screen.dart';
import 'common.dart';
import 'looks_screen.dart';
import 'tryon_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsStore.load();
  await ServerConfig.init();
  AvatarBodyProfile.loadSaved();
  runApp(const FitMeApp());
}

class FitMeApp extends StatelessWidget {
  const FitMeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: FitColors.accent,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FitMe AI',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: scheme,
        scaffoldBackgroundColor: FitColors.background,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: FitColors.card,
          indicatorColor: FitColors.accent.withValues(alpha: .28),
        ),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      home: const FitMeShell(),
    );
  }
}

class FitMeShell extends StatefulWidget {
  const FitMeShell({super.key});

  @override
  State<FitMeShell> createState() => _FitMeShellState();
}

class _FitMeShellState extends State<FitMeShell> with WidgetsBindingObserver {
  final _tryOnKey = GlobalKey<TryOnScreenState>();
  int _index = 0;
  int _catalogVisit = 0;
  int _looksVisit = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ServerConfig.discover();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the background (e.g. after switching Wi-Fi ↔ mobile data).
    if (state == AppLifecycleState.resumed) ServerConfig.discover();
  }

  void _select(int value) {
    setState(() {
      if (value == 1 && _index != 1) _catalogVisit++;
      if (value == 3 && _index != 3) _looksVisit++;
      _index = value;
    });
  }

  void _addToOutfit(CatalogItem item) {
    _select(2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryOnKey.currentState?.addCatalogItem(item);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: [
            HomeScreen(onNavigate: _select),
            CatalogScreen(key: ValueKey('catalog-$_catalogVisit'), onTryOn: _addToOutfit),
            TryOnScreen(key: _tryOnKey),
            LooksScreen(key: ValueKey('looks-$_looksVisit')),
            const ProfileScreen(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Главная',
          ),
          NavigationDestination(
            icon: Icon(Icons.checkroom_outlined),
            selectedIcon: Icon(Icons.checkroom),
            label: 'Каталог',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'Примерка',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: 'Луки',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Профиль',
          ),
        ],
      ),
    );
  }
}

/// Live status of the connection to the laptop / GPU.
class ServerStatusCard extends StatefulWidget {
  const ServerStatusCard({super.key, this.showActions = true});

  final bool showActions;

  @override
  State<ServerStatusCard> createState() => _ServerStatusCardState();
}

class _ServerStatusCardState extends State<ServerStatusCard> {
  bool checking = true;
  bool online = false;
  bool aiReady = false;
  String detail = 'Ищу сервер...';

  @override
  void initState() {
    super.initState();
    ServerConfig.baseUrlNotifier.addListener(_onUrl);
    _check();
  }

  @override
  void dispose() {
    ServerConfig.baseUrlNotifier.removeListener(_onUrl);
    super.dispose();
  }

  void _onUrl() => _check();

  Future<void> _check({bool search = false}) async {
    if (!mounted) return;
    setState(() => checking = true);
    if (search || !await ServerConfig.isFitMe(ServerConfig.baseUrl)) {
      await ServerConfig.discover();
    }
    var ok = await ServerConfig.isFitMe(ServerConfig.baseUrl);
    var ai = false;
    var text = 'Сервер не найден';
    if (ok) {
      try {
        final status = await FitMeApi.aiStatus();
        ai = status['online'] == true;
        final details = status['ai'];
        final upscaler = details is Map && details['upscaler'] == true;
        final gpu = details is Map ? details['gpu']?.toString() : null;
        text = ai
            ? 'FASHN VTON 1.5 готов${gpu == null ? '' : ' • $gpu'}'
                '${upscaler ? ' • улучшение чёткости' : ''}'
            : 'Сервер есть, но GPU не отвечает';
      } catch (e) {
        ok = false;
        text = e.toString();
      }
    }
    if (!mounted) return;
    setState(() {
      checking = false;
      online = ok;
      aiReady = ai;
      detail = text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = checking
        ? Colors.white54
        : aiReady
        ? FitColors.ok
        : online
        ? FitColors.warn
        : FitColors.danger;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              checking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.circle, size: 14, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  checking
                      ? 'Подключение...'
                      : aiReady
                      ? 'AI готов • ${ServerConfig.routeLabel()}'
                      : online
                      ? 'Сервер найден • ${ServerConfig.routeLabel()}'
                      : 'Нет связи с ноутбуком',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Обновить',
                onPressed: checking ? null : () => _check(search: true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Text(detail, style: const TextStyle(color: Colors.white60, fontSize: 13)),
          if (!checking && !online) ...[
            const SizedBox(height: 8),
            const Text(
              'Запустите START_LOCAL_GPU.bat на ноутбуке и проверьте интернет. '
              'Ноутбук должен быть включён.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _avatarVersion = 0;

  @override
  Widget build(BuildContext context) {
    final profile = AvatarBodyProfile.current;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        const ScreenTitle('FitMe AI', subtitle: 'Виртуальная примерочная'),
        const ServerStatusCard(),
        const SizedBox(height: 14),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Мой аватар',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Avatar2DPreview(
                key: ValueKey('home-avatar-$_avatarVersion-${profile.signature}'),
                height: 250,
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  '${profile.height.round()} см • ${profile.weight.round()} кг • '
                  'Г ${profile.chest.round()} / Т ${profile.waist.round()} / Б ${profile.hips.round()}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const Avatar2DScreen()),
                    );
                    if (!mounted) return;
                    setState(() => _avatarVersion++);
                  },
                  icon: const Icon(Icons.accessibility_new),
                  label: const Text('Настроить аватар и мерки'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _QuickAction(
                icon: Icons.auto_awesome,
                title: 'Примерить',
                subtitle: 'до 3 вещей',
                onTap: () => widget.onNavigate(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickAction(
                icon: Icons.checkroom,
                title: 'Каталог',
                subtitle: 'мои вещи',
                onTap: () => widget.onNavigate(1),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: FitColors.accentSoft),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  AvatarBodyProfile get p => AvatarBodyProfile.current;

  Future<void> _manualAddress() async {
    final ctrl = TextEditingController(text: ServerConfig.manualUrl ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Адрес сервера'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://....trycloudflare.com',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Обычно не нужно: приложение само находит ноутбук. '
              'Оставьте пустым, чтобы вернуть автопоиск.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, ctrl.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (value == null || !mounted) return;
    ServerConfig.setManualUrl(value);
    final found = await ServerConfig.discover();
    if (!mounted) return;
    showMessage(
      context,
      found ? 'Подключено: ${ServerConfig.routeLabel()}' : 'Сервер по этому адресу не найден',
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        const ScreenTitle('Профиль', subtitle: 'Мерки сохраняются на телефоне'),
        SectionCard(
          child: Column(
            children: [
              MeasurementSlider(
                label: 'Рост',
                value: p.height,
                min: 145,
                max: 210,
                unit: 'см',
                onChanged: (v) => setState(() => p.height = v),
              ),
              MeasurementSlider(
                label: 'Вес',
                value: p.weight,
                min: 40,
                max: 140,
                unit: 'кг',
                onChanged: (v) => setState(() => p.weight = v),
              ),
              MeasurementSlider(
                label: 'Грудь',
                value: p.chest,
                min: 70,
                max: 140,
                unit: 'см',
                onChanged: (v) => setState(() => p.chest = v),
              ),
              MeasurementSlider(
                label: 'Талия',
                value: p.waist,
                min: 55,
                max: 130,
                unit: 'см',
                onChanged: (v) => setState(() => p.waist = v),
              ),
              MeasurementSlider(
                label: 'Бёдра',
                value: p.hips,
                min: 70,
                max: 150,
                unit: 'см',
                onChanged: (v) => setState(() => p.hips = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const Avatar2DScreen()),
              );
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.accessibility_new),
            label: const Text('Мой 2D-аватар'),
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'Подключение',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        const ServerStatusCard(),
        const SizedBox(height: 10),
        ValueListenableBuilder<String>(
          valueListenable: ServerConfig.baseUrlNotifier,
          builder: (context, url, _) => SectionCard(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                const Icon(Icons.dns_outlined, color: Colors.white54),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                TextButton(onPressed: _manualAddress, child: const Text('Изменить')),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Дома телефон подключается к ноутбуку по Wi-Fi, вне дома — через интернет '
          '(Cloudflare-туннель). Ноутбук должен быть включён с запущенным START_LOCAL_GPU.bat.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }
}
