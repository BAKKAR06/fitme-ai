import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'avatar_2d.dart';
import 'common.dart';

const int kMaxOutfitItems = 3;

/// Rough FASHN speed on the RTX 4060 laptop: seconds per diffusion step.
const double kSecondsPerStep = 2.3;

class TryOnScreen extends StatefulWidget {
  const TryOnScreen({super.key});

  @override
  State<TryOnScreen> createState() => TryOnScreenState();
}

class TryOnScreenState extends State<TryOnScreen> {
  final picker = ImagePicker();

  XFile? personPhoto;
  final List<OutfitItem> outfit = [];

  String gender = 'Унисекс';
  String size = 'M';
  String fit = 'Regular';
  String color = 'Как на фото';
  int quality = 20;
  int seed = 42;

  bool busy = false;
  String status = 'idle';
  String? jobId;
  int step = 0;
  int totalSteps = 1;
  String? stepLabel;
  DateTime? startedAt;
  Duration elapsed = Duration.zero;
  Timer? _ticker;

  String? resultUrl;
  String? error;
  bool showBefore = false;
  bool saved = false;

  @override
  void initState() {
    super.initState();
    _loadSavedAvatar();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ public

  /// Called from the catalog tab ("В образ").
  void addCatalogItem(CatalogItem item) {
    if (busy) {
      showMessage(context, 'Дождитесь окончания текущей примерки');
      return;
    }
    if (outfit.any((it) => it.catalog?.id == item.id)) {
      showMessage(context, '«${item.name}» уже в образе');
      return;
    }
    if (outfit.length >= kMaxOutfitItems) {
      showMessage(context, 'В образе максимум $kMaxOutfitItems вещи');
      return;
    }
    setState(() {
      outfit.add(
        OutfitItem(
          catalog: item,
          category: item.category,
          label: garmentTypeFor('${item.name} ${item.description}', item.category),
        ),
      );
      _resetResult();
    });
    showMessage(context, 'Добавлено в образ: ${item.name}');
  }

  // ------------------------------------------------------------------ person

  Future<void> _loadSavedAvatar() async {
    final path = await AvatarPhotoStore.loadPath();
    if (!mounted || path == null || personPhoto != null) return;
    setState(() => personPhoto = XFile(path));
  }

  Future<void> _pickPerson(ImageSource source) async {
    final image = await picker.pickImage(
      source: source,
      imageQuality: 92,
      maxWidth: 1800,
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
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const Avatar2DScreen()));
      path = await AvatarPhotoStore.loadPath();
    }
    if (!mounted || path == null) return;
    setState(() {
      personPhoto = XFile(path!);
      _resetResult();
    });
  }

  // ------------------------------------------------------------------ outfit

  Future<void> _addGarment() async {
    if (outfit.length >= kMaxOutfitItems) {
      showMessage(context, 'В образе максимум $kMaxOutfitItems вещи');
      return;
    }
    final mode = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: FitColors.card,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Добавить вещь в образ',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 8),
              for (final option in const [
                ('gallery', Icons.photo_library_outlined, 'Фото из галереи'),
                ('camera', Icons.photo_camera_outlined, 'Сфотографировать'),
                ('catalog', Icons.checkroom, 'Из каталога'),
                ('url', Icons.link, 'По ссылке на товар'),
              ])
                ListTile(
                  leading: Icon(option.$2),
                  title: Text(option.$3),
                  onTap: () => Navigator.pop(sheetContext, option.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (mode == null || !mounted) return;
    switch (mode) {
      case 'gallery':
      case 'camera':
        await _addPhotoGarment(
          mode == 'camera' ? ImageSource.camera : ImageSource.gallery,
        );
      case 'catalog':
        await _addFromCatalog();
      case 'url':
        await _addFromUrl();
    }
  }

  Future<void> _addPhotoGarment(ImageSource source) async {
    final image = await picker.pickImage(
      source: source,
      imageQuality: 92,
      maxWidth: 1800,
    );
    if (image == null || !mounted) return;
    final choice = await showGarmentTypePicker(context, selectedLabel: '');
    if (choice == null || !mounted) return;
    setState(() {
      outfit.add(
        OutfitItem(
          photo: image,
          category: choice.aiCategory,
          label: choice.label,
        ),
      );
      _resetResult();
    });
  }

  Future<void> _addFromCatalog() async {
    List<CatalogItem> items;
    try {
      items = await FitMeApi.getCatalog();
    } catch (e) {
      if (!mounted) return;
      showMessage(context, 'Каталог недоступен: $e');
      return;
    }
    if (!mounted) return;
    if (items.isEmpty) {
      showMessage(context, 'Каталог пуст — добавьте вещи на вкладке «Каталог»');
      return;
    }
    final picked = await showModalBottomSheet<CatalogItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: FitColors.card,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .7,
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: items.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.72,
          ),
          itemBuilder: (context, index) {
            final item = items[index];
            return InkWell(
              onTap: () => Navigator.pop(sheetContext, item),
              borderRadius: BorderRadius.circular(14),
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: NetImage(item.imageUrl, fit: BoxFit.contain),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (picked != null && mounted) addCatalogItem(picked);
  }

  Future<void> _addFromUrl() async {
    final urlCtrl = TextEditingController();
    var choice = garmentTypeChoices.first;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('Ссылка на товар'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://...',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 12),
              CompactGarmentTypeField(
                label: choice.label,
                enabled: true,
                onTap: () async {
                  final selected = await showGarmentTypePicker(
                    dialogContext,
                    selectedLabel: choice.label,
                  );
                  if (selected != null) setLocal(() => choice = selected);
                },
              ),
            ],
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
      ),
    );
    urlCtrl.dispose();
    if (result == null || !mounted) return;

    showMessage(context, 'Ищу фото товара...');
    try {
      final item = await FitMeApi.importCatalogItemFromUrl(
        sourceUrl: result,
        category: choice.aiCategory,
      );
      if (!mounted) return;
      addCatalogItem(item);
    } catch (e) {
      if (!mounted) return;
      showMessage(
        context,
        'Не удалось найти фото по ссылке. Добавьте фото вручную. ($e)',
      );
    }
  }

  Future<void> _editGarment(OutfitItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: FitColors.card,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setLocal) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.category_outlined),
                  title: Text('Тип: ${item.label}'),
                  subtitle: Text(categoryRu(item.category)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(sheetContext, 'type'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Как снята вещь',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 0, label: Text('Авто')),
                            ButtonSegment(value: 1, label: Text('Отдельно')),
                            ButtonSegment(value: 2, label: Text('На человеке')),
                          ],
                          selected: {
                            item.onModel == null ? 0 : (item.onModel! ? 2 : 1),
                          },
                          onSelectionChanged: (s) {
                            setLocal(() {
                              item.onModel = switch (s.first) {
                                1 => false,
                                2 => true,
                                _ => null,
                              };
                            });
                            setState(_resetResult);
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Авто — сервер сам увидит, надета ли вещь на человека, и вырежет только её '
                        '(без рук и лица модели).',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: FitColors.danger),
                  title: const Text('Убрать из образа'),
                  onTap: () => Navigator.pop(sheetContext, 'remove'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'remove') {
      setState(() {
        outfit.remove(item);
        _resetResult();
      });
    } else if (action == 'type') {
      final choice = await showGarmentTypePicker(
        context,
        selectedLabel: item.label,
      );
      if (choice == null || !mounted) return;
      setState(() {
        item
          ..label = choice.label
          ..category = choice.aiCategory;
        _resetResult();
      });
    }
  }

  // ------------------------------------------------------------------ job

  void _resetResult() {
    status = 'idle';
    jobId = null;
    resultUrl = null;
    error = null;
    saved = false;
    showBefore = false;
    step = 0;
  }

  int get _etaSeconds =>
      (quality * kSecondsPerStep * math.max(1, outfit.length) + 6).round();

  String _formatSeconds(int s) =>
      s < 60 ? '$s с' : '${s ~/ 60} мин ${(s % 60).toString().padLeft(2, '0')} с';

  Future<void> _start({bool newVariant = false}) async {
    if (personPhoto == null) {
      setState(() => error = 'Сначала выберите фото человека.');
      return;
    }
    if (outfit.isEmpty) {
      setState(() => error = 'Добавьте в образ хотя бы одну вещь.');
      return;
    }
    if (newVariant) seed = math.Random().nextInt(1 << 30);

    setState(() {
      busy = true;
      status = 'uploading';
      error = null;
      resultUrl = null;
      saved = false;
      showBefore = false;
      step = 0;
      totalSteps = outfit.length;
      stepLabel = null;
      startedAt = DateTime.now();
      elapsed = Duration.zero;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || startedAt == null) return;
      setState(() => elapsed = DateTime.now().difference(startedAt!));
    });

    try {
      final profile = AvatarBodyProfile.current;
      final created = await FitMeApi.uploadOutfit(
        personPhoto: personPhoto!,
        items: List.of(outfit),
        title: outfit.map((it) => it.label).join(' + '),
        selectedColor: outfit.length == 1 ? color : 'Как на фото',
        selectedSize: size,
        selectedFit: fit,
        selectedGender: gender,
        bodyHeight: profile.height,
        bodyWeight: profile.weight,
        bodyChest: profile.chest,
        bodyWaist: profile.waist,
        bodyHips: profile.hips,
        numSteps: quality,
        seed: seed,
      );
      if (!mounted) return;
      setState(() {
        jobId = created['job_id'] as String;
        status = created['status']?.toString() ?? 'queued';
        totalSteps = (created['total_steps'] as num?)?.toInt() ?? outfit.length;
      });
      await _poll(jobId!);
    } catch (e) {
      _finish(error: e.toString());
    }
  }

  void _finish({String? error, String? result}) {
    _ticker?.cancel();
    if (!mounted) return;
    setState(() {
      busy = false;
      if (error != null) {
        status = 'failed';
        this.error = error;
      } else {
        status = 'completed';
        resultUrl = result;
      }
    });
  }

  Future<void> _poll(String id) async {
    var failures = 0;
    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final job = await FitMeApi.getJob(id);
        failures = 0;
        if (!mounted) return;
        final s = job['status']?.toString() ?? 'unknown';
        setState(() {
          status = s;
          step = (job['step'] as num?)?.toInt() ?? step;
          totalSteps = (job['total_steps'] as num?)?.toInt() ?? totalSteps;
          stepLabel = job['step_label']?.toString() ?? stepLabel;
        });
        if (s == 'completed') {
          _finish(result: job['result_url']?.toString());
          return;
        }
        if (s == 'failed' || s == 'not_found') {
          final raw = job['error']?.toString() ?? '';
          _finish(
            error: s == 'not_found'
                ? 'Сервер перезапускался — запустите примерку ещё раз.'
                : raw.isEmpty
                ? 'AI не смог завершить примерку.'
                : raw,
          );
          return;
        }
      } catch (e) {
        failures++;
        if (failures >= 6) {
          _finish(error: e.toString());
          return;
        }
      }
    }
    _finish(error: 'Превышено время ожидания. Проверьте окно «FitMe GPU» на ноутбуке.');
  }

  Future<void> _saveLook() async {
    if (jobId == null || saved) return;
    try {
      await FitMeApi.saveLook(
        jobId!,
        title: outfit.map((it) => it.label).join(' + '),
        gender: gender,
        size: size,
        fit: fit,
        color: outfit.length == 1 ? color : null,
      );
      if (!mounted) return;
      setState(() => saved = true);
      showMessage(context, 'Образ сохранён в «Луки»');
    } catch (e) {
      if (!mounted) return;
      showMessage(context, 'Ошибка сохранения: $e');
    }
  }

  void _newOutfit() {
    setState(() {
      outfit.clear();
      _resetResult();
    });
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
      children: [
        const ScreenTitle(
          'Примерка',
          subtitle: 'Соберите образ до 3 вещей — AI наденет их по очереди',
        ),
        _personSection(),
        const SizedBox(height: 14),
        _outfitSection(),
        const SizedBox(height: 14),
        _qualitySection(),
        const SizedBox(height: 14),
        _extraParameters(),
        const SizedBox(height: 18),
        if (busy) _progressCard() else _generateButton(),
        if (error != null) ...[
          const SizedBox(height: 14),
          SectionCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: FitColors.danger),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    error!,
                    style: const TextStyle(color: FitColors.danger),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (resultUrl != null && personPhoto != null) ...[
          const SizedBox(height: 22),
          _resultSection(),
        ],
      ],
    );
  }

  Widget _personSection() {
    final profile = AvatarBodyProfile.current;
    return SectionCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_outline, size: 20),
              const SizedBox(width: 8),
              const Text('Кто примеряет', style: TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              Text(
                '${profile.height.round()} см • ${profile.weight.round()} кг',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: personPhoto == null
                ? null
                : () => openZoom(context, Image.file(File(personPhoto!.path))),
            child: Container(
              height: 230,
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: FitColors.cardHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              child: personPhoto == null
                  ? const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_add_alt_1, size: 54, color: Colors.white38),
                        SizedBox(height: 8),
                        Text(
                          'Фото в полный рост, лицом к камере',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ],
                    )
                  : Image.file(
                      File(personPhoto!.path),
                      fit: BoxFit.contain,
                      alignment: Alignment.topCenter,
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => _pickPerson(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('Галерея'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => _pickPerson(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  label: const Text('Камера'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: busy ? null : _useSavedAvatar,
                  icon: const Icon(Icons.person, size: 18),
                  label: const Text('Аватар'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _outfitSection() {
    return SectionCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.checkroom, size: 20),
              const SizedBox(width: 8),
              Text(
                'Образ • ${outfit.length}/$kMaxOutfitItems',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              if (outfit.isNotEmpty && !busy)
                TextButton(onPressed: _newOutfit, child: const Text('Очистить')),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 150,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final item in outfit)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _GarmentTile(
                      item: item,
                      onTap: busy ? null : () => _editGarment(item),
                    ),
                  ),
                if (outfit.length < kMaxOutfitItems)
                  _AddTile(onTap: busy ? null : _addGarment),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            outfit.length > 1
                ? 'Порядок: сначала низ, потом платье, потом верх и верхняя одежда.'
                : 'Например: джинсы + футболка + куртка. Нажмите на вещь, чтобы изменить тип.',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _qualitySection() {
    return SectionCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.high_quality_outlined, size: 20),
              const SizedBox(width: 8),
              const Text('Качество', style: TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              Text(
                '≈ ${_formatSeconds(_etaSeconds)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 10, label: Text('Быстро')),
                ButtonSegment(value: 20, label: Text('Баланс')),
                ButtonSegment(value: 30, label: Text('Максимум')),
              ],
              selected: {quality},
              onSelectionChanged: busy
                  ? null
                  : (s) => setState(() => quality = s.first),
            ),
          ),
        ],
      ),
    );
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
    final colorEnabled = outfit.length <= 1;

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

    ChoiceChip chip(String value, String current, ValueChanged<String> onPick, {Widget? avatar, bool enabled = true}) {
      return ChoiceChip(
        avatar: avatar,
        label: Text(value),
        selected: current == value,
        onSelected: busy || !enabled ? null : (_) => setState(() => onPick(value)),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: FitColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white10),
      ),
      child: ExpansionTile(
        shape: const Border(),
        leading: const Icon(Icons.tune),
        title: const Text(
          'Размер, посадка, цвет',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '$gender • $size • $fit${colorEnabled ? ' • $color' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        children: [
          section('Для кого', [for (final g in genders) chip(g, gender, (v) => gender = v)]),
          section('Размер', [for (final s in sizes) chip(s, size, (v) => size = v)]),
          section('Посадка', [for (final f in fits) chip(f, fit, (v) => fit = v)]),
          section(
            colorEnabled ? 'Цвет' : 'Цвет (только для одной вещи)',
            [
              for (final entry in colors)
                chip(
                  entry.$1,
                  color,
                  (v) => color = v,
                  avatar: CircleAvatar(radius: 8, backgroundColor: entry.$2),
                  enabled: colorEnabled,
                ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Text(
              'Цвет перекрашивает фото вещи перед AI. Размер и посадка меняют силуэт '
              'приблизительно — это визуальная подсказка, а не размерная сетка бренда.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _generateButton() {
    final ready = personPhoto != null && outfit.isNotEmpty;
    return FilledButton.icon(
      onPressed: ready ? _start : null,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      icon: const Icon(Icons.auto_awesome),
      label: Text(
        ready
            ? (outfit.length == 1 ? 'Примерить' : 'Примерить образ (${outfit.length} вещи)')
            : 'Выберите фото и вещь',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _progressCard() {
    final seconds = elapsed.inSeconds;
    final eta = _etaSeconds;
    final progress = (seconds / math.max(eta, 1)).clamp(0.02, 0.97).toDouble();
    final stepText = status == 'uploading'
        ? 'Отправляю фото на сервер...'
        : status == 'queued' || step == 0
        ? 'В очереди...'
        : totalSteps > 1
        ? 'Шаг $step из $totalSteps: ${stepLabel ?? ''}'
        : 'Надеваю ${stepLabel?.toLowerCase() ?? 'вещь'}...';
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(stepText, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Text(
                _formatSeconds(seconds),
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: progress, minHeight: 8),
          ),
          const SizedBox(height: 8),
          Text(
            'Обычно ≈ ${_formatSeconds(eta)}. Можно переключать вкладки — результат не потеряется.',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _resultSection() {
    final image = showBefore
        ? Image.file(File(personPhoto!.path), fit: BoxFit.contain)
        : NetImage(resultUrl!, fit: BoxFit.contain);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              onSelectionChanged: (s) => setState(() => showBefore = s.first),
            ),
          ],
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () => openZoom(
            context,
            showBefore
                ? Image.file(File(personPhoto!.path))
                : NetImage(resultUrl!, fit: BoxFit.contain),
            title: outfit.map((it) => it.label).join(' + '),
          ),
          child: Container(
            height: 460,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: FitColors.card,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                const Positioned(
                  right: 12,
                  bottom: 12,
                  child: Icon(Icons.zoom_out_map, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: saved ? null : _saveLook,
                icon: Icon(saved ? Icons.favorite : Icons.favorite_border),
                label: Text(saved ? 'В луках' : 'Сохранить'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => _start(newVariant: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Другой вариант'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: busy ? null : _newOutfit,
          icon: const Icon(Icons.add),
          label: const Text('Новый образ'),
        ),
      ],
    );
  }
}

class _GarmentTile extends StatelessWidget {
  const _GarmentTile({required this.item, required this.onTap});

  final OutfitItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget image = item.catalog != null
        ? NetImage(item.catalog!.imageUrl, fit: BoxFit.contain)
        : Image.file(File(item.photo!.path), fit: BoxFit.cover);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 108,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: FitColors.accent.withValues(alpha: .6)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                color: Colors.black.withValues(alpha: .62),
                child: Text(
                  item.onModel == true ? '${item.label} • на человеке' : item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const Positioned(
              top: 6,
              right: 6,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: Colors.black54,
                child: Icon(Icons.edit, size: 13, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 108,
        decoration: BoxDecoration(
          color: FitColors.cardHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white24),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline, size: 32, color: FitColors.accentSoft),
            SizedBox(height: 6),
            Text('Добавить\nвещь', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
