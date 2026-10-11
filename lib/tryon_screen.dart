import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'avatar_2d.dart';
import 'common.dart';

const int kMaxOutfitItems = 3;

/// Rough FASHN speed on the RTX 4060 laptop: seconds per diffusion step,
/// plus fixed work per garment (upload, pose, parsing, upscale, paste-back).
const double kSecondsPerStep = 1.65;
const double kSecondsPerGarment = 20;

/// Quality presets: diffusion steps sent to the server.
const kQualityPresets = <(int, String)>[(15, 'Быстро'), (30, 'Баланс'), (50, 'Максимум')];

/// Keeps the photo chosen for try-on (separate from the avatar, which it must not overwrite).
class PersonPhotoStore {
  PersonPhotoStore._();

  static const _key = 'person_path';

  static Future<String?> loadPath() async {
    final saved = SettingsStore.get<String>(_key);
    if (saved != null && await File(saved).exists()) return saved;
    return AvatarPhotoStore.loadPath();
  }

  static void remember(String path) => SettingsStore.set(_key, path);

  /// Copies a picked photo under a new unique name, so Flutter never shows a
  /// cached older picture, and removes the previous copy.
  static Future<String> save(XFile image) async {
    final dir = await getApplicationDocumentsDirectory();
    final lower = image.name.toLowerCase();
    final ext = lower.endsWith('.png') ? '.png' : '.jpg';
    final path = '${dir.path}${Platform.pathSeparator}'
        'tryon_person_${DateTime.now().millisecondsSinceEpoch}$ext';
    await image.saveTo(path);
    try {
      await for (final entity in dir.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File && name.startsWith('tryon_person_') && entity.path != path) {
          await entity.delete();
        }
      }
    } catch (_) {
      // Old copies are only a few MB; never fail the pick because of cleanup.
    }
    remember(path);
    return path;
  }
}

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
  int quality = SettingsStore.get<int>('quality') ?? 30;
  int seed = 42;
  bool pickingPerson = false;

  List<TryOnModel> models = const [TryOnModel.fallback];
  String modelId = SettingsStore.get<String>('model') ?? 'fashn';
  bool modelsLoading = false;

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
    if (!kQualityPresets.any((p) => p.$1 == quality)) quality = 30;
    _loadPerson();
    _loadModels();
  }

  TryOnModel get model =>
      models.firstWhere((m) => m.id == modelId, orElse: () => models.first);

  Future<void> _loadModels({bool refresh = false}) async {
    // Also called from initState, where setState is not allowed yet.
    modelsLoading = true;
    if (refresh && mounted) setState(() {});
    try {
      final list = await FitMeApi.models(refresh: refresh);
      if (!mounted) return;
      setState(() => models = list);
    } catch (_) {
      // Keep the laptop model; the status card already explains connection problems.
    } finally {
      if (mounted) setState(() => modelsLoading = false);
    }
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

  Future<void> _loadPerson() async {
    final path = await PersonPhotoStore.loadPath();
    if (!mounted || path == null || personPhoto != null) return;
    setState(() => personPhoto = XFile(path));
  }

  Future<void> _pickPerson(ImageSource source) async {
    XFile? image;
    try {
      image = await picker.pickImage(
        source: source,
        imageQuality: 95,
        maxWidth: 2200,
        maxHeight: 2200,
      );
    } catch (e) {
      if (mounted) showMessage(context, 'Не удалось открыть ${source == ImageSource.camera ? 'камеру' : 'галерею'}: $e');
      return;
    }
    if (image == null || !mounted) return;
    setState(() => pickingPerson = true);
    try {
      final path = await PersonPhotoStore.save(image);
      if (!mounted) return;
      setState(() {
        personPhoto = XFile(path);
        _resetResult();
      });
    } catch (e) {
      if (mounted) showMessage(context, 'Не удалось сохранить фото: $e');
    } finally {
      if (mounted) setState(() => pickingPerson = false);
    }
  }

  Future<void> _useSavedAvatar() async {
    var path = await AvatarPhotoStore.loadPath();
    if (path == null && mounted) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const Avatar2DScreen()));
      path = await AvatarPhotoStore.loadPath();
    }
    if (!mounted) return;
    if (path == null) {
      showMessage(context, 'Аватар ещё не создан');
      return;
    }
    // The avatar file keeps its name when re-shot: drop the old decoded picture.
    await FileImage(File(path)).evict();
    PersonPhotoStore.remember(path);
    if (!mounted) return;
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

  int get _etaSeconds {
    final perGarment = model.isLocal
        ? quality * kSecondsPerStep + kSecondsPerGarment
        : 60.0; // free cloud GPUs: queue + model time
    return (perGarment * math.max(1, outfit.length) + 4).round();
  }

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
    final unsupported = outfit.where((it) => !model.supports(it.category)).toList();
    if (unsupported.isNotEmpty) {
      setState(() => error =
          '${model.title} не умеет: ${unsupported.map((it) => it.label).join(', ')}. '
          'Выберите другую модель или уберите эти вещи.');
      return;
    }
    if (!model.available) {
      setState(() => error = '${model.title} сейчас недоступна: ${model.reason ?? 'нет связи'}');
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
        model: model.id,
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
        _modelSection(),
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
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(personPhoto!.path),
                          key: ValueKey(personPhoto!.path),
                          fit: BoxFit.contain,
                          alignment: Alignment.topCenter,
                          errorBuilder: (_, _, _) => const Center(
                            child: Text(
                              'Фото не открылось — выберите другое',
                              style: TextStyle(color: Colors.white54),
                            ),
                          ),
                        ),
                        if (pickingPerson)
                          const ColoredBox(
                            color: Color(0x88000000),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _PersonSourceButton(
                  icon: Icons.photo_library_outlined,
                  label: 'Галерея',
                  onTap: busy || pickingPerson ? null : () => _pickPerson(ImageSource.gallery),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _PersonSourceButton(
                  icon: Icons.photo_camera_outlined,
                  label: 'Камера',
                  onTap: busy || pickingPerson ? null : () => _pickPerson(ImageSource.camera),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _PersonSourceButton(
                  icon: Icons.person,
                  label: 'Аватар',
                  filled: true,
                  onTap: busy || pickingPerson ? null : _useSavedAvatar,
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

  Future<void> _chooseModel() async {
    if (models.length <= 1 && !modelsLoading) unawaited(_loadModels(refresh: true));
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: FitColors.card,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * .8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              const Text(
                'Модель примерки',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Облачные модели бесплатные, но дают лишь несколько минут GPU в день.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              for (final m in models)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: m.available,
                  leading: Icon(
                    m.isLocal ? Icons.laptop_chromebook : Icons.cloud_outlined,
                    color: m.available ? FitColors.accentSoft : Colors.white24,
                  ),
                  title: Text(m.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    [
                      m.where,
                      m.limit,
                      if (m.categories.length < 3)
                        'только ${m.categories.map(categoryRu).join(', ').toLowerCase()}',
                      m.available ? m.note : (m.reason ?? 'недоступна'),
                      if (m.needsToken && m.available) 'без HF-токена лимит меньше',
                    ].where((t) => t.isNotEmpty).join(' • '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: m.id == modelId
                      ? const Icon(Icons.check_circle, color: FitColors.accentSoft)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, m.id),
                ),
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _loadModels(refresh: true);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Проверить доступность заново'),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      modelId = picked;
      error = null;
    });
    SettingsStore.set('model', picked);
  }

  Widget _modelSection() {
    final m = model;
    return InkWell(
      onTap: busy ? null : _chooseModel,
      borderRadius: BorderRadius.circular(22),
      child: SectionCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            Icon(
              m.isLocal ? Icons.laptop_chromebook : Icons.cloud_outlined,
              size: 20,
              color: m.available ? FitColors.accentSoft : FitColors.warn,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Модель: ${m.title}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(
                    m.available ? '${m.where} • ${m.limit}' : (m.reason ?? 'недоступна'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: m.available ? Colors.white54 : FitColors.warn,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (modelsLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.chevron_right),
          ],
        ),
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
              segments: [
                for (final preset in kQualityPresets)
                  ButtonSegment(value: preset.$1, label: Text(preset.$2)),
              ],
              selected: {quality},
              onSelectionChanged: busy
                  ? null
                  : (s) {
                      setState(() => quality = s.first);
                      SettingsStore.set('quality', s.first);
                    },
            ),
          ),
          const SizedBox(height: 8),
          Text(
            model.isLocal
                ? '$quality шагов модели. Лицо и фон остаются из вашего фото в полном разрешении, '
                    'одежда дорисовывается и повышается в чёткости.'
                : 'Облачная модель: число шагов ограничено самим сервисом, бесплатно несколько примерок в день.',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
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
            '${model.title} • обычно ≈ ${_formatSeconds(eta)}. Можно переключать вкладки — результат не потеряется.',
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

class _PersonSourceButton extends StatelessWidget {
  const _PersonSourceButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: filled ? FitColors.accent.withValues(alpha: enabled ? .28 : .1) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: filled ? Colors.transparent : Colors.white24),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: enabled ? FitColors.accentSoft : Colors.white24),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: enabled ? Colors.white : Colors.white38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
