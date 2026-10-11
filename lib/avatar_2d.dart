import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'common.dart';

class AvatarBodyProfile {
  AvatarBodyProfile._();

  static final AvatarBodyProfile current = AvatarBodyProfile._();

  double _height = 178;
  double _weight = 74;
  double _chest = 96;
  double _waist = 81;
  double _hips = 94;

  double get height => _height;
  double get weight => _weight;
  double get chest => _chest;
  double get waist => _waist;
  double get hips => _hips;

  set height(double v) => _set(() => _height = v);
  set weight(double v) => _set(() => _weight = v);
  set chest(double v) => _set(() => _chest = v);
  set waist(double v) => _set(() => _waist = v);
  set hips(double v) => _set(() => _hips = v);

  void _set(void Function() change) {
    change();
    if (identical(this, current)) {
      SettingsStore.set('body', {
        'height': _height,
        'weight': _weight,
        'chest': _chest,
        'waist': _waist,
        'hips': _hips,
      });
    }
  }

  /// Restores measurements saved by a previous app run.
  static void loadSaved() {
    final saved = SettingsStore.get<Map<String, dynamic>>('body');
    if (saved == null) return;
    double read(String key, double fallback, double min, double max) {
      final value = saved[key];
      return value is num ? value.toDouble().clamp(min, max) : fallback;
    }

    current._height = read('height', 178, 145, 210);
    current._weight = read('weight', 74, 40, 140);
    current._chest = read('chest', 96, 70, 140);
    current._waist = read('waist', 81, 55, 130);
    current._hips = read('hips', 94, 70, 150);
  }

  AvatarBodyProfile snapshot() {
    final p = AvatarBodyProfile._();
    p._height = _height;
    p._weight = _weight;
    p._chest = _chest;
    p._waist = _waist;
    p._hips = _hips;
    return p;
  }

  String get signature =>
      '${height.toStringAsFixed(1)}-${weight.toStringAsFixed(1)}-'
      '${chest.toStringAsFixed(1)}-${waist.toStringAsFixed(1)}-'
      '${hips.toStringAsFixed(1)}';
}

class AvatarPhotoStore {
  AvatarPhotoStore._();


  static String? _cachedOriginalPath;
  static String? _cachedPreviewPath;
  static String? lastCutoutError;

  /// Bumped every time the avatar files are rewritten. The file names never
  /// change, so widgets use this in their keys to show the new picture.
  static int revision = 0;

  static Future<void> _forgetCachedImages(Iterable<File> files) async {
    for (final file in files) {
      await FileImage(file).evict();
    }
  }

  static Future<Directory> _dir() => getApplicationDocumentsDirectory();

  static Future<File> _legacyFile() async {
    final dir = await _dir();
    return File('${dir.path}${Platform.pathSeparator}fitme_2d_avatar.jpg');
  }

  static Future<File> _originalFile() async {
    final dir = await _dir();
    return File(
      '${dir.path}${Platform.pathSeparator}fitme_avatar_original.png',
    );
  }

  static Future<File> _previewFile() async {
    final dir = await _dir();
    return File('${dir.path}${Platform.pathSeparator}fitme_avatar_cutout.png');
  }

  static Future<String?> loadPath() async {
    if (_cachedOriginalPath != null &&
        await File(_cachedOriginalPath!).exists()) {
      return _cachedOriginalPath;
    }

    final original = await _originalFile();
    if (await original.exists()) {
      _cachedOriginalPath = original.path;
      return _cachedOriginalPath;
    }

    final legacy = await _legacyFile();
    if (await legacy.exists()) {
      _cachedOriginalPath = legacy.path;
      return _cachedOriginalPath;
    }

    return null;
  }

  static Future<String?> loadPreviewPath() async {
    if (_cachedPreviewPath != null &&
        await File(_cachedPreviewPath!).exists()) {
      return _cachedPreviewPath;
    }

    final preview = await _previewFile();
    if (await preview.exists()) {
      _cachedPreviewPath = preview.path;
      return _cachedPreviewPath;
    }

    final original = await loadPath();
    _cachedPreviewPath = original;
    return _cachedPreviewPath;
  }

  static Future<String> saveFromXFile(XFile source) async {
    final sourceBytes = await source.readAsBytes();
    final normalizedPng = await _AvatarCutoutProcessor.normalizeOriginalPng(
      sourceBytes,
    );

    Uint8List previewPng;
    lastCutoutError = null;
    try {
      previewPng = await _requestAiCutout(sourceBytes);
    } catch (error) {
      // Important: never fall back to the old color-key algorithm.
      // It ate white clothes and created the ugly white islands seen in v8.
      previewPng = normalizedPng;
      lastCutoutError = error.toString();
    }

    final original = await _originalFile();
    final preview = await _previewFile();
    await original.writeAsBytes(normalizedPng, flush: true);
    await preview.writeAsBytes(previewPng, flush: true);

    final legacy = await _legacyFile();
    if (await legacy.exists()) {
      await legacy.delete();
    }

    await _forgetCachedImages([original, preview]);
    revision++;
    _cachedOriginalPath = original.path;
    _cachedPreviewPath = preview.path;
    return original.path;
  }

  static Future<Uint8List> _requestAiCutout(Uint8List bytes) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ServerConfig.baseUrl}/api/v1/avatar/cutout'),
    );
    request.headers.addAll(ServerConfig.headers);
    request.files.add(
      http.MultipartFile.fromBytes(
        'photo',
        bytes,
        filename: 'fitme_avatar.jpg',
      ),
    );

    final streamed = await request.send().timeout(const Duration(minutes: 3));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) {
      throw Exception(
        'AI cutout HTTP ${response.statusCode}: ${response.body}',
      );
    }
    if (response.bodyBytes.isEmpty) {
      throw Exception('AI cutout returned an empty image');
    }
    return response.bodyBytes;
  }

  static Future<void> delete() async {
    for (final file in [
      await _originalFile(),
      await _previewFile(),
      await _legacyFile(),
    ]) {
      if (await file.exists()) {
        await file.delete();
      }
      await FileImage(file).evict();
    }
    revision++;
    _cachedOriginalPath = null;
    _cachedPreviewPath = null;
  }
}

class _AvatarCutoutProcessor {
  static Future<Uint8List> normalizeOriginalPng(Uint8List sourceBytes) async {
    final codec = await ui.instantiateImageCodec(sourceBytes);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  }
}

class Avatar2DPreview extends StatefulWidget {
  const Avatar2DPreview({super.key, this.height = 250});

  final double height;

  @override
  State<Avatar2DPreview> createState() => _Avatar2DPreviewState();
}

class _Avatar2DPreviewState extends State<Avatar2DPreview> {
  String? path;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await AvatarPhotoStore.loadPreviewPath();
    if (!mounted) return;
    setState(() {
      path = saved;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF111217),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      clipBehavior: Clip.antiAlias,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : path == null
          ? const _EmptyAvatarPreview()
          : Stack(
              fit: StackFit.expand,
              children: [
                BodyWarpImage(
                  key: ValueKey('preview-${AvatarPhotoStore.revision}'),
                  path: path!,
                  profile: AvatarBodyProfile.current.snapshot(),
                ),
                const Positioned(
                  left: 12,
                  bottom: 12,
                  child: _AvatarBadge(text: 'LIVE 2D • CUTOUT'),
                ),
              ],
            ),
    );
  }
}

class BodyWarpImage extends StatefulWidget {
  const BodyWarpImage({super.key, required this.path, required this.profile});

  final String path;
  final AvatarBodyProfile profile;

  @override
  State<BodyWarpImage> createState() => _BodyWarpImageState();
}

class _BodyWarpImageState extends State<BodyWarpImage> {
  ui.Image? image;
  String? loadedPath;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant BodyWarpImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _decode();
  }

  Future<void> _decode() async {
    final bytes = await File(widget.path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      image = frame.image;
      loadedPath = widget.path;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (image == null || loadedPath != widget.path) {
      return const Center(child: CircularProgressIndicator());
    }

    return CustomPaint(
      painter: _PhotoBodyWarpPainter(image: image!, profile: widget.profile),
      size: Size.infinite,
    );
  }
}

class _PhotoBodyWarpPainter extends CustomPainter {
  _PhotoBodyWarpPainter({required this.image, required this.profile});

  final ui.Image image;
  final AvatarBodyProfile profile;

  double _c(double v, double a, double b) => v.clamp(a, b).toDouble();
  double _lerp(double a, double b, double t) => a + (b - a) * t;

  double _widthFactor(double y) {
    final weight = _c(
      math.pow(profile.weight / 74.0, 0.14).toDouble(),
      0.92,
      1.12,
    );
    final chest = _c(
      weight * math.pow(profile.chest / 96.0, 0.34).toDouble(),
      0.88,
      1.16,
    );
    final waist = _c(
      weight * math.pow(profile.waist / 81.0, 0.38).toDouble(),
      0.86,
      1.18,
    );
    final hips = _c(
      weight * math.pow(profile.hips / 94.0, 0.36).toDouble(),
      0.88,
      1.18,
    );
    final legs = _c(
      1.0 + (weight - 1.0) * 0.55 + (hips - 1.0) * 0.22,
      0.92,
      1.12,
    );

    const ys = <double>[0, .16, .30, .45, .60, .78, 1];
    final fs = <double>[1, 1, chest, waist, hips, legs, legs * .96];

    for (var i = 0; i < ys.length - 1; i++) {
      if (y >= ys[i] && y <= ys[i + 1]) {
        final t = (y - ys[i]) / (ys[i + 1] - ys[i]);
        return _lerp(fs[i], fs[i + 1], t);
      }
    }
    return fs.last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final srcW = image.width.toDouble();
    final srcH = image.height.toDouble();
    final heightFactor = _c(profile.height / 178.0, 0.86, 1.14);
    final drawHeight = size.height * .80 * heightFactor;
    final baseWidth = drawHeight * (srcW / srcH);
    final top = (size.height - drawHeight) / 2;
    final cx = size.width / 2;

    final shadowPath = Path()
      ..addOval(
        Rect.fromCenter(
          center: Offset(cx, size.height - 16),
          width: baseWidth * .58,
          height: 12,
        ),
      );
    canvas.drawShadow(shadowPath, Colors.black, 12, false);

    const bands = 72;
    final srcBand = srcH / bands;
    final dstBand = drawHeight / bands + 1;

    for (var i = 0; i < bands; i++) {
      final y = (i + .5) / bands;
      final factor = _widthFactor(y);
      final src = Rect.fromLTWH(0, i * srcBand, srcW, srcBand + .8);
      final w = baseWidth * factor;
      final dst = Rect.fromLTWH(
        cx - w / 2,
        top + i * drawHeight / bands,
        w,
        dstBand,
      );
      canvas.drawImageRect(
        image,
        src,
        dst,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PhotoBodyWarpPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.profile.signature != profile.signature;
  }
}

class Avatar2DScreen extends StatefulWidget {
  const Avatar2DScreen({
    super.key,
    this.initialHeight,
    this.initialWeight,
    this.initialChest,
    this.initialWaist,
    this.initialHips,
  });

  final double? initialHeight;
  final double? initialWeight;
  final double? initialChest;
  final double? initialWaist;
  final double? initialHips;

  @override
  State<Avatar2DScreen> createState() => _Avatar2DScreenState();
}

class _Avatar2DScreenState extends State<Avatar2DScreen> {
  final picker = ImagePicker();

  String? avatarPath;
  bool loading = true;
  bool picking = false;

  late double height;
  late double weight;
  late double chest;
  late double waist;
  late double hips;

  @override
  void initState() {
    super.initState();
    final p = AvatarBodyProfile.current;
    height = widget.initialHeight ?? p.height;
    weight = widget.initialWeight ?? p.weight;
    chest = widget.initialChest ?? p.chest;
    waist = widget.initialWaist ?? p.waist;
    hips = widget.initialHips ?? p.hips;
    _save();
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    final path = await AvatarPhotoStore.loadPreviewPath();
    if (!mounted) return;
    setState(() {
      avatarPath = path;
      loading = false;
    });
  }

  void _save() {
    final p = AvatarBodyProfile.current;
    p.height = height;
    p.weight = weight;
    p.chest = chest;
    p.waist = waist;
    p.hips = hips;
  }

  void _change(VoidCallback fn) {
    setState(() {
      fn();
      _save();
    });
  }

  Future<void> _pick(ImageSource source) async {
    final image = await picker.pickImage(
      source: source,
      imageQuality: 94,
      maxWidth: 2200,
    );
    if (image == null || !mounted) return;
    setState(() {
      picking = true;
      loading = avatarPath == null;
    });
    try {
      await AvatarPhotoStore.saveFromXFile(image);
      final saved = await AvatarPhotoStore.loadPreviewPath();
      if (!mounted) return;
      setState(() => avatarPath = saved);
    } catch (e) {
      if (mounted) showMessage(context, 'Не удалось сохранить фото: $e');
    } finally {
      if (mounted) {
        setState(() {
          picking = false;
          loading = false;
        });
      }
    }

    if (!mounted) return;
    if (AvatarPhotoStore.lastCutoutError != null) {
      showMessage(
        context,
        'Фото сохранено, но фон не удалён: нет связи с ноутбуком. Попробуйте ещё раз позже.',
      );
    }
  }

  Future<void> _deleteAvatar() async {
    final ok = await confirmAction(context, title: 'Удалить аватар?');
    if (!ok) return;
    await AvatarPhotoStore.delete();
    if (!mounted) return;
    setState(() => avatarPath = null);
  }

  @override
  Widget build(BuildContext context) {
    final live = AvatarBodyProfile.current.snapshot();

    return Scaffold(
      appBar: AppBar(
        title: const Text('2D-аватар'),
        actions: [
          TextButton(
            onPressed: () {
              _save();
              Navigator.pop(context);
            },
            child: const Text('Готово'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [
          Container(
            height: 470,
            decoration: BoxDecoration(
              color: const Color(0xFF111217),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white10),
            ),
            clipBehavior: Clip.antiAlias,
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : avatarPath == null
                ? const _CreateAvatarHint()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      BodyWarpImage(
                        key: ValueKey('avatar-${AvatarPhotoStore.revision}'),
                        path: avatarPath!,
                        profile: live,
                      ),
                      if (picking)
                        const ColoredBox(
                          color: Color(0x99000000),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 12),
                                Text('AI убирает фон...'),
                              ],
                            ),
                          ),
                        ),
                      const Positioned(
                        left: 14,
                        bottom: 14,
                        child: _AvatarBadge(text: 'LIVE 2D • AI CUTOUT'),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 14),
          if (avatarPath == null) ...[
            FilledButton.icon(
              onPressed: picking ? null : () => _pick(ImageSource.camera),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Сфотографироваться'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: picking ? null : () => _pick(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Добавить фото из галереи'),
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: picking ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Новое фото'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: picking ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Галерея'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _deleteAvatar,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Удалить аватар'),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: const Color(0xFF17181E),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Text(
              'Теперь фон удаляет отдельная AI-модель сегментации человека, а не цветовой фильтр. '
              'Ползунки меняют именно силуэт человека: рост — высоту, вес — общую ширину, '
              'грудь / талия / бёдра — свои зоны. Лучше всего работает на фото в полный рост '
              'с хорошим освещением и простым фоном.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Параметры тела',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          _ProfileSlider(
            label: 'Рост',
            value: height,
            min: 145,
            max: 210,
            unit: 'см',
            onChanged: (v) => _change(() => height = v),
          ),
          _ProfileSlider(
            label: 'Вес',
            value: weight,
            min: 40,
            max: 140,
            unit: 'кг',
            onChanged: (v) => _change(() => weight = v),
          ),
          _ProfileSlider(
            label: 'Грудь',
            value: chest,
            min: 70,
            max: 140,
            unit: 'см',
            onChanged: (v) => _change(() => chest = v),
          ),
          _ProfileSlider(
            label: 'Талия',
            value: waist,
            min: 55,
            max: 130,
            unit: 'см',
            onChanged: (v) => _change(() => waist = v),
          ),
          _ProfileSlider(
            label: 'Бёдра',
            value: hips,
            min: 70,
            max: 150,
            unit: 'см',
            onChanged: (v) => _change(() => hips = v),
          ),
        ],
      ),
    );
  }
}

class _ProfileSlider extends StatelessWidget {
  const _ProfileSlider({
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        children: [
          Row(
            children: [
              Text(label),
              const Spacer(),
              Text(
                '${value.round()} $unit',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _EmptyAvatarPreview extends StatelessWidget {
  const _EmptyAvatarPreview();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_add_alt_1, size: 58, color: Color(0xFFB9AEFF)),
          SizedBox(height: 10),
          Text(
            'Создай 2D-аватар из своего фото',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 4),
          Text(
            'AI удалит фон автоматически',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class _CreateAvatarHint extends StatelessWidget {
  const _CreateAvatarHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.accessibility_new, size: 78, color: Color(0xFFB9AEFF)),
          SizedBox(height: 18),
          Text(
            'Создай свой 2D-аватар',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 8),
          Text(
            'Сфотографируйся в полный рост или выбери готовое фото. '
            'FitMe уберёт фон и оставит только человека.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _AvatarBadge extends StatelessWidget {
  const _AvatarBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: const Color(0x66B9AEFF)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFB9AEFF),
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
