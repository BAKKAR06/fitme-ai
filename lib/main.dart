import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'avatar_2d.dart';

void main() => runApp(const FitMeApp());

class CatalogItem {
  const CatalogItem({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.imageUrl,
    required this.sourceName,
    required this.sourceUrl,
  });

  final String id;
  final String name;
  final String category;
  final String description;
  final String imageUrl;
  final String sourceName;
  final String sourceUrl;

  factory CatalogItem.fromJson(Map<String, dynamic> json) {
    return CatalogItem(
      id: json['item_id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Garment',
      category: json['category']?.toString() ?? 'upper_body',
      description: json['description']?.toString() ?? '',
      imageUrl: json['image_url']?.toString() ?? '',
      sourceName: json['source_name']?.toString() ?? '',
      sourceUrl: json['source_url']?.toString() ?? '',
    );
  }
}

class FitMeApi {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$baseUrl$path');
      late HttpClientRequest request;
      if (method == 'POST') {
        request = await client.postUrl(uri);
      } else if (method == 'DELETE') {
        request = await client.deleteUrl(uri);
      } else {
        request = await client.getUrl(uri);
      }

      request.headers.contentType = ContentType.json;
      if (body != null) request.write(jsonEncode(body));

      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
      }
      if (text.isEmpty) return {};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> health() => _json('GET', '/health');
  static Future<Map<String, dynamic>> aiStatus() =>
      _json('GET', '/api/v1/ai/status');

  static Future<List<CatalogItem>> getCatalog() async {
    final data = await _json('GET', '/api/v1/catalog');
    final raw = data['items'] as List<dynamic>? ?? const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(CatalogItem.fromJson)
        .toList();
  }

  static Future<void> deleteCatalogItem(String id) async {
    await _json('DELETE', '/api/v1/catalog/$id');
  }

  static Future<CatalogItem> importCatalogItemFromUrl({
    required String sourceUrl,
    required String category,
  }) async {
    final data = await _json(
      'POST',
      '/api/v1/catalog/import-url',
      body: {'source_url': sourceUrl.trim(), 'category': category},
    );
    return CatalogItem.fromJson(data['item'] as Map<String, dynamic>);
  }

  static Future<CatalogItem> uploadCatalogItem({
    required XFile garmentPhoto,
    required String name,
    required String category,
    required String description,
    required String sourceName,
    required String sourceUrl,
  }) async {
    final data = await _multipart(
      '/api/v1/catalog/upload',
      fields: {
        'name': name,
        'category': category,
        'description': description,
        'source_name': sourceName,
        'source_url': sourceUrl,
      },
      files: {'garment_photo': garmentPhoto},
    );
    return CatalogItem.fromJson(data['item'] as Map<String, dynamic>);
  }

  static Future<Map<String, dynamic>> uploadTryOn({
    required XFile personPhoto,
    XFile? garmentPhoto,
    String? catalogItemId,
    required String category,
    required String garmentDescription,
    required String selectedColor,
    required String selectedSize,
    required String selectedFit,
    required String selectedGender,
    required double bodyHeight,
    required double bodyWeight,
    required double bodyChest,
    required double bodyWaist,
    required double bodyHips,
  }) {
    final files = <String, XFile>{'person_photo': personPhoto};
    if (garmentPhoto != null) files['garment_photo'] = garmentPhoto;

    return _multipart(
      '/api/v1/try-on/upload',
      fields: {
        'garment_description': garmentDescription,
        'category': category,
        'selected_color': selectedColor,
        'selected_size': selectedSize,
        'selected_fit': selectedFit,
        'selected_gender': selectedGender,
        'body_height': bodyHeight.toStringAsFixed(1),
        'body_weight': bodyWeight.toStringAsFixed(1),
        'body_chest': bodyChest.toStringAsFixed(1),
        'body_waist': bodyWaist.toStringAsFixed(1),
        'body_hips': bodyHips.toStringAsFixed(1),
        if (catalogItemId != null) 'catalog_item_id': catalogItemId,
      },
      files: files,
    );
  }

  static Future<Map<String, dynamic>> _multipart(
    String path, {
    required Map<String, String> fields,
    required Map<String, XFile> files,
  }) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$baseUrl$path');
      final request = await client.postUrl(uri);
      final boundary =
          '----FitMeBoundary${DateTime.now().microsecondsSinceEpoch}';
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );

      for (final entry in fields.entries) {
        request.add(utf8.encode('--$boundary\r\n'));
        request.add(
          utf8.encode(
            'Content-Disposition: form-data; name="${entry.key}"\r\n\r\n',
          ),
        );
        request.add(utf8.encode('${entry.value}\r\n'));
      }

      for (final entry in files.entries) {
        final file = entry.value;
        final bytes = await file.readAsBytes();
        final name = file.name.replaceAll('"', '');
        final lower = name.toLowerCase();
        final mime = lower.endsWith('.png')
            ? 'image/png'
            : lower.endsWith('.webp')
            ? 'image/webp'
            : 'image/jpeg';

        request.add(utf8.encode('--$boundary\r\n'));
        request.add(
          utf8.encode(
            'Content-Disposition: form-data; '
            'name="${entry.key}"; filename="$name"\r\n',
          ),
        );
        request.add(utf8.encode('Content-Type: $mime\r\n\r\n'));
        request.add(bytes);
        request.add(utf8.encode('\r\n'));
      }

      request.add(utf8.encode('--$boundary--\r\n'));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> getJob(String jobId) =>
      _json('GET', '/api/v1/try-on/$jobId');

  static Future<Map<String, dynamic>> saveLook(
    String jobId, {
    String? title,
    String? gender,
    String? size,
    String? fit,
    String? color,
  }) {
    return _json(
      'POST',
      '/api/v1/looks/save',
      body: {
        'job_id': jobId,
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
        if (gender != null) 'gender': gender,
        if (size != null) 'size': size,
        if (fit != null) 'fit': fit,
        if (color != null) 'color': color,
      },
    );
  }

  static Future<List<Map<String, dynamic>>> getLooks() async {
    final data = await _json('GET', '/api/v1/looks');
    final raw = data['items'] as List<dynamic>? ?? const [];
    return raw.whereType<Map<String, dynamic>>().toList();
  }

  static Future<void> deleteLook(String id) async {
    await _json('DELETE', '/api/v1/looks/$id');
  }
}

class FitMeApp extends StatelessWidget {
  const FitMeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FitMe AI',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B7CF6),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0E12),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
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

class _FitMeShellState extends State<FitMeShell> {
  int _index = 0;
  CatalogItem? _selectedCatalogItem;

  void _tryCatalogItem(CatalogItem item) {
    setState(() {
      _selectedCatalogItem = item;
      _index = 2;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const HomeScreen(),
      CatalogScreen(onTryOn: _tryCatalogItem),
      TryOnScreen(
        key: ValueKey(_selectedCatalogItem?.id ?? 'manual'),
        catalogItem: _selectedCatalogItem,
        onCatalogCleared: () {
          setState(() => _selectedCatalogItem = null);
        },
      ),
      LooksScreen(key: ValueKey('looks-$_index')),
      const ProfileScreen(),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
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
            label: 'Примерить',
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

String categoryRu(String value) {
  switch (value) {
    case 'lower_body':
      return 'Низ';
    case 'dresses':
      return 'Платье';
    default:
      return 'Верх';
  }
}

String engineForCategory(String value) {
  return 'FASHN VTON 1.5';
}

Future<void> openProductSource(BuildContext context, String rawUrl) async {
  var value = rawUrl.trim();
  if (value.isEmpty) return;
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'https://$value';
  }

  final uri = Uri.tryParse(value);
  if (uri == null ||
      !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Не удалось открыть ссылку товара')),
    );
  }
}

class GarmentTypeChoice {
  const GarmentTypeChoice(this.label, this.aiCategory);

  final String label;
  final String aiCategory;
}

const garmentTypeChoices = <GarmentTypeChoice>[
  GarmentTypeChoice('Футболка', 'upper_body'),
  GarmentTypeChoice('Топ', 'upper_body'),
  GarmentTypeChoice('Рубашка', 'upper_body'),
  GarmentTypeChoice('Блузка', 'upper_body'),
  GarmentTypeChoice('Худи', 'upper_body'),
  GarmentTypeChoice('Свитер', 'upper_body'),
  GarmentTypeChoice('Куртка', 'upper_body'),
  GarmentTypeChoice('Пиджак', 'upper_body'),
  GarmentTypeChoice('Пальто', 'upper_body'),
  GarmentTypeChoice('Джинсы', 'lower_body'),
  GarmentTypeChoice('Брюки', 'lower_body'),
  GarmentTypeChoice('Шорты', 'lower_body'),
  GarmentTypeChoice('Юбка', 'lower_body'),
  GarmentTypeChoice('Платье', 'dresses'),
];

String garmentTypeFor(String text, String aiCategory) {
  final q = text.toLowerCase();

  const keywords = <String, String>{
    'футбол': 'Футболка',
    't-shirt': 'Футболка',
    'tshirt': 'Футболка',
    'shirt': 'Рубашка',
    'рубаш': 'Рубашка',
    'hood': 'Худи',
    'худи': 'Худи',
    'sweater': 'Свитер',
    'свит': 'Свитер',
    'jacket': 'Куртка',
    'куртк': 'Куртка',
    'blazer': 'Пиджак',
    'пидж': 'Пиджак',
    'coat': 'Пальто',
    'пальто': 'Пальто',
    'jean': 'Джинсы',
    'джинс': 'Джинсы',
    'trouser': 'Брюки',
    'pant': 'Брюки',
    'брюк': 'Брюки',
    'short': 'Шорты',
    'шорт': 'Шорты',
    'skirt': 'Юбка',
    'юбк': 'Юбка',
    'dress': 'Платье',
    'плать': 'Платье',
  };

  for (final entry in keywords.entries) {
    if (q.contains(entry.key)) return entry.value;
  }

  switch (aiCategory) {
    case 'lower_body':
      return 'Брюки';
    case 'dresses':
      return 'Платье';
    default:
      return 'Футболка';
  }
}

Future<GarmentTypeChoice?> showGarmentTypePicker(
  BuildContext context, {
  required String selectedLabel,
}) {
  return showModalBottomSheet<GarmentTypeChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF17181E),
    builder: (sheetContext) {
      var query = '';

      return StatefulBuilder(
        builder: (context, setLocalState) {
          final items = garmentTypeChoices
              .where(
                (item) =>
                    item.label.toLowerCase().contains(query.toLowerCase()),
              )
              .toList();

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                0,
                18,
                18 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .58,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Что примеряем?',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      autofocus: true,
                      onChanged: (value) {
                        setLocalState(() => query = value.trim());
                      },
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Например: джинсы',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: Colors.white10),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final selected = item.label == selectedLabel;
                          return ListTile(
                            dense: true,
                            title: Text(item.label),
                            subtitle: Text(
                              categoryRu(item.aiCategory),
                              style: const TextStyle(color: Colors.white38),
                            ),
                            trailing: selected
                                ? const Icon(
                                    Icons.check_circle,
                                    color: Color(0xFFB9AEFF),
                                  )
                                : null,
                            onTap: () => Navigator.pop(sheetContext, item),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class CompactGarmentTypeField extends StatelessWidget {
  const CompactGarmentTypeField({
    super.key,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: OutlinedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: const Icon(Icons.search, size: 19),
        label: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down),
          ],
        ),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          side: const BorderSide(color: Colors.white24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  double height = 178;
  double weight = 74;
  String status = 'Проверка backend...';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final health = await FitMeApi.health();
      final ai = await FitMeApi.aiStatus();
      if (!mounted) return;
      setState(() {
        final engine =
            ai['engine']?.toString() ??
            health['engine']?.toString() ??
            'FASHN VTON 1.5';
        final online = ai['online'] == true;
        final steps = ai['steps']?.toString();
        status = online
            ? 'AI готов • $engine${steps == null ? '' : ' • Турбо $steps шагов'}'
            : 'Backend ${health['version']} • AI offline';
      });
    } catch (_) {
      if (mounted) setState(() => status = 'Backend offline');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        Text(
          'FitMe AI',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        const Text(
          'Виртуальная примерочная',
          style: TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 14),
        InkWell(
          onTap: _check,
          borderRadius: BorderRadius.circular(99),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_done_outlined, size: 17),
                const SizedBox(width: 8),
                Expanded(child: Text(status)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF191A20),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Мой аватар',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 14),
              Column(
                children: [
                  Avatar2DPreview(
                    key: ValueKey(
                      'home-avatar-${height.round()}-${weight.round()}-'
                      '${AvatarBodyProfile.current.chest.round()}-'
                      '${AvatarBodyProfile.current.waist.round()}-'
                      '${AvatarBodyProfile.current.hips.round()}',
                    ),
                    height: 250,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => Avatar2DScreen(
                              initialHeight: height,
                              initialWeight: weight,
                            ),
                          ),
                        );
                        if (!mounted) return;
                        setState(() {
                          height = AvatarBodyProfile.current.height;
                          weight = AvatarBodyProfile.current.weight;
                        });
                      },
                      icon: const Icon(Icons.accessibility_new),
                      label: const Text('Настроить 2D-аватар'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              MeasurementSlider(
                label: 'Рост',
                value: height,
                min: 145,
                max: 210,
                unit: 'см',
                onChanged: (v) {
                  AvatarBodyProfile.current.height = v;
                  setState(() => height = v);
                },
              ),
              MeasurementSlider(
                label: 'Вес',
                value: weight,
                min: 40,
                max: 140,
                unit: 'кг',
                onChanged: (v) {
                  AvatarBodyProfile.current.weight = v;
                  setState(() => weight = v);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class MeasurementSlider extends StatelessWidget {
  const MeasurementSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(label),
            const Spacer(),
            Text(
              '${value.round()} $unit',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        Slider(value: value, min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.onTryOn});

  final ValueChanged<CatalogItem> onTryOn;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final ImagePicker picker = ImagePicker();
  bool loading = true;
  String? error;
  List<CatalogItem> items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FitMeApi.getCatalog();
      if (!mounted) return;
      setState(() {
        items = result;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _addItem() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF17181E),
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Добавить вещь',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('По ссылке на товар'),
                subtitle: const Text('FitMe попробует найти фото товара сам'),
                onTap: () => Navigator.pop(sheetContext, 'url'),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Из галереи'),
                subtitle: const Text('Выбрать фото одежды вручную'),
                onTap: () => Navigator.pop(sheetContext, 'photo'),
              ),
            ],
          ),
        ),
      ),
    );

    if (mode == null || !mounted) return;

    if (mode == 'url') {
      final urlCtrl = TextEditingController();
      String category = 'upper_body';
      String garmentType = 'Футболка';

      final urlData = await showDialog<Map<String, String>>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: const Text('Добавить по ссылке'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: urlCtrl,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Ссылка на товар',
                      hintText: 'https://...',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  CompactGarmentTypeField(
                    label: garmentType,
                    enabled: true,
                    onTap: () async {
                      final selected = await showGarmentTypePicker(
                        context,
                        selectedLabel: garmentType,
                      );
                      if (selected == null) return;
                      setLocal(() {
                        garmentType = selected.label;
                        category = selected.aiCategory;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'FitMe возьмёт фото из og:image / карточки товара. '
                    'Если магазин блокирует загрузку, можно добавить фото вручную.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  if (urlCtrl.text.trim().isEmpty) return;
                  Navigator.pop(context, {
                    'url': urlCtrl.text.trim(),
                    'category': category,
                  });
                },
                child: const Text('Найти фото'),
              ),
            ],
          ),
        ),
      );

      if (urlData == null) return;

      try {
        final item = await FitMeApi.importCatalogItemFromUrl(
          sourceUrl: urlData['url']!,
          category: urlData['category']!,
        );
        if (!mounted) return;
        await _load();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Добавлено: ${item.name}')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Не удалось взять фото по ссылке. '
              'Попробуй другой магазин или добавь фото вручную.\n$e',
            ),
          ),
        );
      }
      return;
    }

    final photo = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 94,
      maxWidth: 2000,
    );
    if (photo == null || !mounted) return;

    final nameCtrl = TextEditingController();
    final sourceNameCtrl = TextEditingController();
    final sourceUrlCtrl = TextEditingController();
    String category = 'upper_body';
    String garmentType = 'Футболка';

    final data = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              title: const Text('Добавить вещь'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Название',
                        hintText: 'Blue jeans',
                      ),
                    ),
                    const SizedBox(height: 12),
                    CompactGarmentTypeField(
                      label: garmentType,
                      enabled: true,
                      onTap: () async {
                        final selected = await showGarmentTypePicker(
                          context,
                          selectedLabel: garmentType,
                        );
                        if (selected == null) return;
                        setLocal(() {
                          garmentType = selected.label;
                          category = selected.aiCategory;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: sourceNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Источник',
                        hintText: 'Zara / Wildberries / Kaspi',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: sourceUrlCtrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Ссылка на товар',
                        hintText: 'https://...',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    if (nameCtrl.text.trim().isEmpty) return;
                    Navigator.pop(context, {
                      'name': nameCtrl.text.trim(),
                      'category': category,
                      'description': nameCtrl.text.trim(),
                      'source_name': sourceNameCtrl.text.trim(),
                      'source_url': sourceUrlCtrl.text.trim(),
                    });
                  },
                  child: const Text('Добавить'),
                ),
              ],
            );
          },
        );
      },
    );

    if (data == null) return;

    try {
      await FitMeApi.uploadCatalogItem(
        garmentPhoto: photo,
        name: data['name']!,
        category: data['category']!,
        description: data['description']!,
        sourceName: data['source_name'] ?? '',
        sourceUrl: data['source_url'] ?? '',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка каталога: $e')));
    }
  }

  Future<void> _delete(CatalogItem item) async {
    await FitMeApi.deleteCatalogItem(item.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Каталог',
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton.filledTonal(
                onPressed: _addItem,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 5),
          const Text(
            'Добавь свои вещи и примеряй одним нажатием',
            style: TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 18),
          if (loading)
            const Padding(
              padding: EdgeInsets.only(top: 120),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            Text(error!, style: const TextStyle(color: Colors.redAccent))
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 100),
              child: Column(
                children: [
                  const Icon(Icons.checkroom, size: 80),
                  const SizedBox(height: 18),
                  const Text(
                    'Каталог пуст',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Нажми + и добавь фото одежды.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить вещь'),
                  ),
                ],
              ),
            )
          else
            ...items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF17181E),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.white10),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 1,
                        child: Image.network(
                          '${FitMeApi.baseUrl}${item.imageUrl}',
                          fit: BoxFit.cover,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${categoryRu(item.category)} • '
                                    '${engineForCategory(item.category)}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                    ),
                                  ),
                                  if (item.sourceUrl.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    InkWell(
                                      onTap: () => openProductSource(
                                        context,
                                        item.sourceUrl,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.open_in_new,
                                            size: 15,
                                            color: Color(0xFFB9AEFF),
                                          ),
                                          const SizedBox(width: 5),
                                          Flexible(
                                            child: Text(
                                              item.sourceName.isEmpty
                                                  ? 'Открыть источник'
                                                  : item.sourceName,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Color(0xFFB9AEFF),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => _delete(item),
                              icon: const Icon(Icons.delete_outline),
                            ),
                            FilledButton(
                              onPressed: () => widget.onTryOn(item),
                              child: const Text('Примерить'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class TryOnScreen extends StatefulWidget {
  const TryOnScreen({
    super.key,
    this.catalogItem,
    required this.onCatalogCleared,
  });

  final CatalogItem? catalogItem;
  final VoidCallback onCatalogCleared;

  @override
  State<TryOnScreen> createState() => _TryOnScreenState();
}

class _TryOnScreenState extends State<TryOnScreen> {
  final picker = ImagePicker();
  late final TextEditingController descriptionCtrl;

  XFile? personPhoto;
  XFile? garmentPhoto;
  CatalogItem? catalogItem;
  String category = 'upper_body';
  String garmentType = 'Футболка';

  String gender = 'Унисекс';
  String size = 'M';
  String fit = 'Regular';
  String color = 'Как на фото';

  String status = 'idle';
  String? jobId;
  String? resultUrl;
  String? error;
  String? engine;
  bool busy = false;
  bool showBefore = false;
  bool saved = false;

  @override
  void initState() {
    super.initState();
    catalogItem = widget.catalogItem;
    category = catalogItem?.category ?? 'upper_body';
    descriptionCtrl = TextEditingController(
      text:
          catalogItem?.description ??
          (category == 'lower_body'
              ? 'blue jeans'
              : category == 'dresses'
              ? 'dress'
              : 'black leather jacket'),
    );
    garmentType = garmentTypeFor(
      '${catalogItem?.name ?? ''} ${catalogItem?.description ?? ''}',
      category,
    );
    descriptionCtrl.text = garmentType;
    _loadSavedAvatar();
  }

  @override
  void dispose() {
    descriptionCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedAvatar() async {
    final path = await AvatarPhotoStore.loadPath();
    if (!mounted || path == null || personPhoto != null) return;
    setState(() {
      personPhoto = XFile(path);
      _resetResult();
    });
  }

  Future<void> _pickPersonFromCamera() async {
    final image = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 92,
      maxWidth: 2000,
    );
    if (image == null || !mounted) return;

    final savedPath = await AvatarPhotoStore.saveFromXFile(image);
    if (!mounted) return;

    setState(() {
      personPhoto = XFile(savedPath);
      _resetResult();
    });
  }

  Future<void> _useSavedAvatar() async {
    var path = await AvatarPhotoStore.loadPath();

    if (path == null && mounted) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const Avatar2DScreen()));
      path = await AvatarPhotoStore.loadPath();
    }

    if (!mounted || path == null) return;

    setState(() {
      personPhoto = XFile(path!);
      _resetResult();
    });
  }

  Future<void> _pickPerson() async {
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
      maxWidth: 2000,
    );
    if (image == null || !mounted) return;

    final savedPath = await AvatarPhotoStore.saveFromXFile(image);
    if (!mounted) return;

    setState(() {
      personPhoto = XFile(savedPath);
      _resetResult();
    });
  }

  Future<void> _pickGarment() async {
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 94,
      maxWidth: 2000,
    );
    if (image == null || !mounted) return;
    setState(() {
      garmentPhoto = image;
      catalogItem = null;
      widget.onCatalogCleared();
      _resetResult();
    });
  }

  Future<void> _pickGarmentFromUrl() async {
    final urlCtrl = TextEditingController();

    final sourceUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ссылка на товар'),
        content: TextField(
          controller: urlCtrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://...',
            prefixIcon: Icon(Icons.link),
          ),
          onSubmitted: (_) {
            final value = urlCtrl.text.trim();
            if (value.isNotEmpty) Navigator.pop(dialogContext, value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final value = urlCtrl.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('Найти фото'),
          ),
        ],
      ),
    );

    if (sourceUrl == null || !mounted) return;

    setState(() {
      busy = true;
      error = null;
      status = 'uploading';
    });

    try {
      final item = await FitMeApi.importCatalogItemFromUrl(
        sourceUrl: sourceUrl,
        category: category,
      );

      if (!mounted) return;
      setState(() {
        catalogItem = item;
        garmentPhoto = null;
        category = item.category;
        garmentType = garmentTypeFor(
          '${item.name} ${item.description}',
          item.category,
        );
        descriptionCtrl.text = garmentType;
        busy = false;
        _resetResult();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        busy = false;
        status = 'error';
        error =
            'Не удалось найти фото товара по этой ссылке. '
            'Попробуй другую ссылку или выбери фото вручную.';
      });
    }
  }

  void _resetResult() {
    status = 'ready';
    jobId = null;
    resultUrl = null;
    error = null;
    engine = null;
    saved = false;
    showBefore = false;
  }

  Future<void> _start() async {
    if (personPhoto == null) {
      setState(() => error = 'Сначала выбери фото человека.');
      return;
    }
    if (garmentPhoto == null && catalogItem == null) {
      setState(() => error = 'Выбери фото одежды или вещь из каталога.');
      return;
    }

    setState(() {
      busy = true;
      status = 'uploading';
      error = null;
      resultUrl = null;
      saved = false;
    });

    try {
      final ai = await FitMeApi.aiStatus();
      if (ai['online'] != true) {
        if (!mounted) return;
        setState(() {
          busy = false;
          status = 'error';
          error = 'FASHN сервер не готов. Запусти Kaggle notebook и START_FITME.bat.';
        });
        return;
      }

      final created = await FitMeApi.uploadTryOn(
        personPhoto: personPhoto!,
        garmentPhoto: garmentPhoto,
        catalogItemId: catalogItem?.id,
        category: category,
        garmentDescription: descriptionCtrl.text.trim(),
        selectedColor: color,
        selectedSize: size,
        selectedFit: fit,
        selectedGender: gender,
        bodyHeight: AvatarBodyProfile.current.height,
        bodyWeight: AvatarBodyProfile.current.weight,
        bodyChest: AvatarBodyProfile.current.chest,
        bodyWaist: AvatarBodyProfile.current.waist,
        bodyHips: AvatarBodyProfile.current.hips,
      );

      final id = created['job_id'] as String;
      if (!mounted) return;
      setState(() {
        jobId = id;
        status = created['status']?.toString() ?? 'queued';
        engine = created['engine']?.toString();
      });
      await _poll(id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        busy = false;
        status = 'error';
        error = 'Ошибка отправки: $e';
      });
    }
  }

  Future<void> _poll(String id) async {
    for (var i = 0; i < 240; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        final job = await FitMeApi.getJob(id);
        if (!mounted) return;
        final s = job['status']?.toString() ?? 'unknown';
        setState(() {
          status = s;
          engine = job['engine']?.toString() ?? engine;
        });

        if (s == 'completed') {
          final relative = job['result_url']?.toString();
          setState(() {
            busy = false;
            resultUrl = relative == null
                ? null
                : '${FitMeApi.baseUrl}$relative';
          });
          return;
        }

        if (s == 'failed' || s == 'not_found') {
          final rawError = job['error']?.toString() ?? '';
          var friendly = 'AI не смог завершить примерку.';
          if (rawError.contains('524') ||
              rawError.toLowerCase().contains('timeout')) {
            friendly =
                'Kaggle всё ещё генерировал, но старый туннель оборвал долгий запрос. '
                'В CLEAN MVP v2 генерация идёт через фоновые job-запросы; '
                'если ошибка повторилась — перезапусти Kaggle notebook.';
          } else if (rawError.toLowerCase().contains('offline')) {
            friendly = 'FASHN сервер недоступен. Перезапусти Kaggle notebook и START_FITME.bat.';
          } else if (rawError.isNotEmpty) {
            friendly = rawError.length > 280
                ? '${rawError.substring(0, 280)}…'
                : rawError;
          }
          setState(() {
            busy = false;
            error = friendly;
          });
          return;
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          busy = false;
          status = 'error';
          error = 'Ошибка статуса: $e';
        });
        return;
      }
    }

    if (mounted) {
      setState(() {
        busy = false;
        status = 'error';
        error = 'Превышено время ожидания.';
      });
    }
  }

  Future<void> _saveLook() async {
    if (jobId == null || saved) return;
    try {
      await FitMeApi.saveLook(
        jobId!,
        title: descriptionCtrl.text.trim(),
        gender: gender,
        size: size,
        fit: fit,
        color: color,
      );
      if (!mounted) return;
      setState(() => saved = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Лук сохранён ❤️')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка сохранения: $e')));
    }
  }

  String get statusLabel {
    switch (status) {
      case 'uploading':
        return 'Загрузка...';
      case 'queued':
        return 'В очереди...';
      case 'processing':
        return '${engine ?? engineForCategory(category)} генерирует • $color • $size • $fit...';
      case 'completed':
        return 'Готово';
      case 'error':
      case 'failed':
        return 'Ошибка';
      default:
        return 'Готово к примерке';
    }
  }

  Widget _extraParameters() {
    const genders = ['Мужской', 'Женский', 'Унисекс'];
    const sizes = ['XS', 'S', 'M', 'L', 'XL', 'XXL'];
    const fits = ['Slim', 'Regular', 'Oversize'];
    const colors = <(String, Color)>[
      ('Как на фото', Color(0xFF777777)),
      ('Чёрный', Color(0xFF111111)),
      ('Белый', Color(0xFFF2F2F2)),
      ('Серый', Color(0xFF777777)),
      ('Синий', Color(0xFF3156A6)),
      ('Красный', Color(0xFFB33434)),
      ('Жёлтый', Color(0xFFD5AD32)),
      ('Зелёный', Color(0xFF3E7A52)),
      ('Бежевый', Color(0xFFC7AA83)),
    ];

    Widget section(String title, List<Widget> children) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: children),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF17181E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.tune),
        title: const Text(
          'Доп. параметры',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '$gender • $size • $fit • $color',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        children: [
          section(
            'Для кого',
            genders
                .map(
                  (value) => ChoiceChip(
                    label: Text(value),
                    selected: gender == value,
                    onSelected: busy
                        ? null
                        : (_) => setState(() => gender = value),
                  ),
                )
                .toList(),
          ),
          section(
            'Размер',
            sizes
                .map(
                  (value) => ChoiceChip(
                    label: Text(value),
                    selected: size == value,
                    onSelected: busy
                        ? null
                        : (_) => setState(() => size = value),
                  ),
                )
                .toList(),
          ),
          section(
            'Посадка',
            fits
                .map(
                  (value) => ChoiceChip(
                    label: Text(value),
                    selected: fit == value,
                    onSelected: busy
                        ? null
                        : (_) => setState(() => fit = value),
                  ),
                )
                .toList(),
          ),
          section(
            'Цвет',
            colors
                .map(
                  (entry) => ChoiceChip(
                    avatar: CircleAvatar(radius: 8, backgroundColor: entry.$2),
                    label: Text(entry.$1),
                    selected: color == entry.$1,
                    onSelected: busy
                        ? null
                        : (_) => setState(() => color = entry.$1),
                  ),
                )
                .toList(),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Text(
              'Цвет реально применяется к фото вещи перед AI. '
              'Размер и посадка меняют силуэт приблизительно: '
              'это визуальная MVP-симуляция, а не точная размерная сетка бренда.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _personCard() {
    return _imageCard(
      child: personPhoto == null
          ? const _EmptyImage(
              icon: Icons.person_add_alt_1,
              title: 'Ваш 2D-аватар',
            )
          : Image.file(
              File(personPhoto!.path),
              fit: BoxFit.contain,
              alignment: Alignment.topCenter,
            ),
      onTap: _pickPerson,
    );
  }

  Widget _garmentCard() {
    Widget child;
    if (catalogItem != null) {
      child = Image.network(
        '${FitMeApi.baseUrl}${catalogItem!.imageUrl}',
        fit: BoxFit.cover,
      );
    } else if (garmentPhoto != null) {
      child = Image.file(File(garmentPhoto!.path), fit: BoxFit.cover);
    } else {
      child = const _EmptyImage(icon: Icons.checkroom, title: 'Фото одежды');
    }
    return _imageCard(child: child, onTap: _pickGarment);
  }

  Widget _imageCard({required Widget child, required VoidCallback onTap}) {
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 250,
        width: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF17181E),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white10),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              top: 12,
              right: 12,
              child: IconButton.filledTonal(
                onPressed: busy ? null : onTap,
                icon: const Icon(Icons.edit),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedEngine = engine ?? engineForCategory(category);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
      children: [
        Text(
          'AI-примерочная',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          '$garmentType • $selectedEngine',
          style: const TextStyle(color: Colors.greenAccent),
        ),
        if (catalogItem != null) ...[
          const SizedBox(height: 8),
          Text(
            'Из каталога: ${catalogItem!.name}',
            style: const TextStyle(color: Colors.white60),
          ),
          if (catalogItem!.sourceUrl.isNotEmpty)
            TextButton.icon(
              onPressed: () =>
                  openProductSource(context, catalogItem!.sourceUrl),
              icon: const Icon(Icons.open_in_new, size: 17),
              label: Text(
                catalogItem!.sourceName.isEmpty
                    ? 'Открыть товар'
                    : catalogItem!.sourceName,
              ),
            ),
        ],
        const SizedBox(height: 18),
        _personCard(),
        const SizedBox(height: 6),
        Text(
          'Профиль тела: ${AvatarBodyProfile.current.height.round()} см • '
          '${AvatarBodyProfile.current.weight.round()} кг • '
          'Г ${AvatarBodyProfile.current.chest.round()} / '
          'Т ${AvatarBodyProfile.current.waist.round()} / '
          'Б ${AvatarBodyProfile.current.hips.round()}',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _pickPerson,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Галерея'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _pickPersonFromCamera,
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Камера'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : _useSavedAvatar,
                icon: const Icon(Icons.person),
                label: const Text('Аватар'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _garmentCard(),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _pickGarment,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Фото'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : _pickGarmentFromUrl,
                icon: const Icon(Icons.link),
                label: const Text('Ссылка'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        CompactGarmentTypeField(
          label: garmentType,
          enabled: !busy,
          onTap: () async {
            final selected = await showGarmentTypePicker(
              context,
              selectedLabel: garmentType,
            );
            if (selected == null || !mounted) return;
            setState(() {
              garmentType = selected.label;
              category = selected.aiCategory;
              descriptionCtrl.text = selected.label;
              _resetResult();
            });
          },
        ),
        const SizedBox(height: 8),
        const Text(
          'Выбери тип вещи — FitMe сам передаст нужную категорию в AI.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 12),
        _extraParameters(),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy ? null : _start,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(busy ? statusLabel : 'Сгенерировать примерку'),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          jobId == null ? statusLabel : '$statusLabel • job $jobId',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white60),
        ),
        if (error != null) ...[
          const SizedBox(height: 14),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ],
        if (resultUrl != null && personPhoto != null) ...[
          const SizedBox(height: 28),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Результат',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('До')),
                  ButtonSegment(value: false, label: Text('После')),
                ],
                selected: {showBefore},
                onSelectionChanged: (selection) {
                  setState(() => showBefore = selection.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            constraints: const BoxConstraints(minHeight: 380),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF17181E),
              borderRadius: BorderRadius.circular(24),
            ),
            child: showBefore
                ? Image.file(File(personPhoto!.path), fit: BoxFit.contain)
                : Image.network(resultUrl!, fit: BoxFit.contain),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: saved ? null : _saveLook,
            icon: Icon(saved ? Icons.favorite : Icons.favorite_border),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(saved ? 'Сохранено в луках' : 'Сохранить в луки'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Сгенерировано: ${engine ?? selectedEngine}',
            style: const TextStyle(color: Colors.white54),
          ),
        ],
      ],
    );
  }
}

class _EmptyImage extends StatelessWidget {
  const _EmptyImage({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 58),
        const SizedBox(height: 12),
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class LooksScreen extends StatefulWidget {
  const LooksScreen({super.key});

  @override
  State<LooksScreen> createState() => _LooksScreenState();
}

class _LooksScreenState extends State<LooksScreen> {
  bool loading = true;
  List<Map<String, dynamic>> looks = const [];
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FitMeApi.getLooks();
      if (!mounted) return;
      setState(() {
        looks = result;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _delete(String id) async {
    await FitMeApi.deleteLook(id);
    await _load();
  }

  void _openLook(Map<String, dynamic> look) {
    final url = look['result_url']?.toString();
    if (url == null || url.isEmpty) return;

    final title = look['title']?.toString() ?? 'AI Look';
    final gender = look['gender']?.toString();
    final size = look['size']?.toString();
    final fit = look['fit']?.toString();
    final color = look['color']?.toString();
    final sourceName = look['source_name']?.toString();
    final sourceUrl = look['source_url']?.toString();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    color: Colors.black,
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: Image.network(
                          '${FitMeApi.baseUrl}$url',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                  decoration: const BoxDecoration(
                    color: Color(0xFF17181E),
                    border: Border(top: BorderSide(color: Colors.white10)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (gender != null && gender.isNotEmpty)
                            Chip(label: Text(gender)),
                          if (size != null && size.isNotEmpty)
                            Chip(label: Text('Размер $size')),
                          if (fit != null && fit.isNotEmpty)
                            Chip(label: Text(fit)),
                          if (color != null && color.isNotEmpty)
                            Chip(label: Text(color)),
                        ],
                      ),
                      if (sourceUrl != null && sourceUrl.isNotEmpty)
                        TextButton.icon(
                          onPressed: () =>
                              openProductSource(context, sourceUrl),
                          icon: const Icon(Icons.open_in_new),
                          label: Text(
                            sourceName == null || sourceName.isEmpty
                                ? 'Открыть товар'
                                : sourceName,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _date(String? value) {
    final dt = value == null ? null : DateTime.tryParse(value)?.toLocal();
    if (dt == null) return '';
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day.$month • $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Мои луки',
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            ],
          ),
          const SizedBox(height: 18),
          if (loading)
            const Center(child: CircularProgressIndicator())
          else if (error != null)
            Text(error!, style: const TextStyle(color: Colors.redAccent))
          else if (looks.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 130),
              child: Column(
                children: [
                  Icon(Icons.favorite_border, size: 82),
                  SizedBox(height: 14),
                  Text(
                    'Пока нет сохранённых луков',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            )
          else
            ...looks.map((look) {
              final url = look['result_url']?.toString();
              final id = look['look_id']?.toString() ?? '';
              final title = look['title']?.toString() ?? 'AI Look';
              final engine =
                  look['engine']?.toString() ??
                  look['provider']?.toString() ??
                  '';
              final category = look['category']?.toString();

              return Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: const Color(0xFF17181E),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (url != null)
                        GestureDetector(
                          onTap: () => _openLook(look),
                          child: AspectRatio(
                            aspectRatio: 2 / 3,
                            child: Container(
                              color: Colors.black,
                              alignment: Alignment.center,
                              child: Image.network(
                                '${FitMeApi.baseUrl}$url',
                                fit: BoxFit.contain,
                                width: double.infinity,
                                height: double.infinity,
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${category == null ? '' : '${categoryRu(category)} • '}'
                                    '${_date(look['created_at']?.toString())} • $engine',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      if ((look['gender']?.toString() ?? '')
                                          .isNotEmpty)
                                        Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            look['gender'].toString(),
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      if ((look['size']?.toString() ?? '')
                                          .isNotEmpty)
                                        Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            'Размер ${look['size']}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      if ((look['fit']?.toString() ?? '')
                                          .isNotEmpty)
                                        Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            look['fit'].toString(),
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      if ((look['color']?.toString() ?? '')
                                          .isNotEmpty)
                                        Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            look['color'].toString(),
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: id.isEmpty ? null : () => _delete(id),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
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
  double chest = 96;
  double waist = 81;
  double hips = 94;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        Text(
          'Профиль',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 24),
        const Center(
          child: CircleAvatar(radius: 44, child: Icon(Icons.person, size: 44)),
        ),
        const SizedBox(height: 14),
        const Center(
          child: Text(
            'FitMe User',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Avatar2DScreen(
                    initialChest: chest,
                    initialWaist: waist,
                    initialHips: hips,
                  ),
                ),
              );
              if (!mounted) return;
              setState(() {
                chest = AvatarBodyProfile.current.chest;
                waist = AvatarBodyProfile.current.waist;
                hips = AvatarBodyProfile.current.hips;
              });
            },
            icon: const Icon(Icons.accessibility_new),
            label: const Text('Мой 2D-аватар'),
          ),
        ),
        const SizedBox(height: 28),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF17181E),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              MeasurementSlider(
                label: 'Грудь',
                value: chest,
                min: 70,
                max: 140,
                unit: 'см',
                onChanged: (v) {
                  AvatarBodyProfile.current.chest = v;
                  setState(() => chest = v);
                },
              ),
              MeasurementSlider(
                label: 'Талия',
                value: waist,
                min: 55,
                max: 130,
                unit: 'см',
                onChanged: (v) {
                  AvatarBodyProfile.current.waist = v;
                  setState(() => waist = v);
                },
              ),
              MeasurementSlider(
                label: 'Бёдра',
                value: hips,
                min: 70,
                max: 150,
                unit: 'см',
                onChanged: (v) {
                  AvatarBodyProfile.current.hips = v;
                  setState(() => hips = v);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
