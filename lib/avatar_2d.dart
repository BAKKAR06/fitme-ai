import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'common.dart';
import 'i18n.dart';

class AvatarPhotoStore {
  AvatarPhotoStore._();


  static String? _cachedOriginalPath;
  static String? _cachedPreviewPath;
  static String? _cachedFor;
  static String? lastCutoutError;

  /// Bumped every time the avatar files are rewritten. The file names never
  /// change, so widgets use this in their keys to show the new picture.
  static int revision = 0;

  /// Every account on this phone has its own avatar files (a new user must not see someone else's photo).
  static String get _account {
    final id = Session.user.value?.id ?? 'guest';
    return id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  static void _checkAccount() {
    if (_cachedFor != _account) {
      _cachedFor = _account;
      _cachedOriginalPath = null;
      _cachedPreviewPath = null;
      revision++;
    }
  }

  static Future<void> _forgetCachedImages(Iterable<File> files) async {
    for (final file in files) {
      await FileImage(file).evict();
    }
  }

  static Future<Directory> _dir() => getApplicationDocumentsDirectory();

  static Future<File> _file(String name) async {
    final dir = await _dir();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  static Future<File> _originalFile() => _file('fitme_avatar_original_$_account.png');

  static Future<File> _previewFile() => _file('fitme_avatar_cutout_$_account.png');

  /// Before v5 the avatar had one name for the whole phone. Those files belonged to the
  /// creator (the only user then): they move to the creator's account, nobody else sees them.
  static Future<void> _claimSharedFiles() async {
    final shared = [
      (await _file('fitme_avatar_original.png'), await _originalFile()),
      (await _file('fitme_avatar_cutout.png'), await _previewFile()),
      (await _file('fitme_2d_avatar.jpg'), await _originalFile()),
    ];
    final isOwner = Session.user.value?.role == 'owner';
    for (final (old, target) in shared) {
      if (!await old.exists()) continue;
      if (isOwner && !await target.exists()) {
        await old.rename(target.path);
      } else if (isOwner) {
        await old.delete();
      }
    }
  }

  static Future<String?> loadPath() async {
    _checkAccount();
    if (_cachedOriginalPath != null &&
        await File(_cachedOriginalPath!).exists()) {
      return _cachedOriginalPath;
    }

    await _claimSharedFiles();
    final original = await _originalFile();
    if (await original.exists()) {
      _cachedOriginalPath = original.path;
      return _cachedOriginalPath;
    }
    return null;
  }

  static Future<String?> loadPreviewPath() async {
    _checkAccount();
    if (_cachedPreviewPath != null &&
        await File(_cachedPreviewPath!).exists()) {
      return _cachedPreviewPath;
    }

    await _claimSharedFiles();
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

    final streamed = await request.send().timeout(Duration(minutes: 3));
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
        color: FitColors.cardHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: FitColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: loading
          ? Center(child: CircularProgressIndicator())
          : path == null
          ? _EmptyAvatarPreview()
          : Stack(
              fit: StackFit.expand,
              children: [
                AvatarImage(
                  key: ValueKey('preview-${AvatarPhotoStore.revision}'),
                  path: path!,
                ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _AvatarBadge(text: 'AI CUTOUT'),
                ),
              ],
            ),
    );
  }
}

/// The avatar photo as it is (no stretching: body measurements are not used any more).
class AvatarImage extends StatelessWidget {
  const AvatarImage({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Image.file(
        File(path),
        fit: BoxFit.contain,
        alignment: Alignment.bottomCenter,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const _EmptyAvatarPreview(),
      ),
    );
  }
}

class Avatar2DScreen extends StatefulWidget {
  const Avatar2DScreen({super.key});

  @override
  State<Avatar2DScreen> createState() => _Avatar2DScreenState();
}

class _Avatar2DScreenState extends State<Avatar2DScreen> {
  final picker = ImagePicker();

  String? avatarPath;
  bool loading = true;
  bool picking = false;

  @override
  void initState() {
    super.initState();
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
      if (mounted) showMessage(context, t('Не удалось сохранить фото: {e}', {'e': e}));
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
        t('Фото сохранено, но фон не удалён: нет связи с ноутбуком. Попробуйте ещё раз позже.'),
      );
    }
  }

  Future<void> _deleteAvatar() async {
    final ok = await confirmAction(context, title: t('Удалить аватар?'));
    if (!ok) return;
    await AvatarPhotoStore.delete();
    if (!mounted) return;
    setState(() => avatarPath = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('Мой аватар')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('Готово')),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [
          Container(
            height: 470,
            decoration: BoxDecoration(
              color: FitColors.cardHigh,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: FitColors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: loading
                ? Center(child: CircularProgressIndicator())
                : avatarPath == null
                ? _CreateAvatarHint()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      AvatarImage(
                        key: ValueKey('avatar-${AvatarPhotoStore.revision}'),
                        path: avatarPath!,
                      ),
                      if (picking)
                        ColoredBox(
                          color: Color(0x99000000),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 12),
                                Text(t('AI убирает фон...'), style: const TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      Positioned(
                        left: 14,
                        bottom: 14,
                        child: _AvatarBadge(text: 'AI CUTOUT'),
                      ),
                    ],
                  ),
          ),
          SizedBox(height: 14),
          if (avatarPath == null) ...[
            FilledButton.icon(
              onPressed: picking ? null : () => _pick(ImageSource.camera),
              icon: Icon(Icons.camera_alt),
              label: Text(t('Сфотографироваться')),
            ),
            SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: picking ? null : () => _pick(ImageSource.gallery),
              icon: Icon(Icons.photo_library_outlined),
              label: Text(t('Добавить фото из галереи')),
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: picking ? null : () => _pick(ImageSource.camera),
                    icon: Icon(Icons.camera_alt_outlined),
                    label: Text(t('Новое фото')),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: picking ? null : () => _pick(ImageSource.gallery),
                    icon: Icon(Icons.photo_library_outlined),
                    label: Text(t('Галерея')),
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            TextButton.icon(
              onPressed: _deleteAvatar,
              icon: Icon(Icons.delete_outline),
              label: Text(t('Удалить аватар')),
            ),
          ],
          SizedBox(height: 14),
          Container(
            padding: EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: FitColors.card,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              t('Аватар — ваше фото в полный рост без фона. Его можно выбрать на вкладке «Примерка» '
                  'кнопкой «Аватар», чтобы не искать фото каждый раз. Лучше всего подходит снимок '
                  'при хорошем свете, лицом к камере, на простом фоне.'),
              style: TextStyle(color: FitColors.soft, height: 1.4),
            ),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_add_alt_1, size: 58, color: FitColors.accentSoft),
          SizedBox(height: 10),
          Text(
            t('Создайте аватар из своего фото'),
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 4),
          Text(
            t('AI удалит фон автоматически'),
            style: TextStyle(color: FitColors.muted),
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
    return Padding(
      padding: EdgeInsets.all(30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.accessibility_new, size: 78, color: FitColors.accentSoft),
          SizedBox(height: 18),
          Text(
            t('Создайте свой аватар'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 8),
          Text(
            t('Сфотографируйтесь в полный рост или выберите готовое фото. '
            'FitMe уберёт фон и оставит только человека.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: FitColors.muted, height: 1.4),
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
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: FitColors.accentSoft.withValues(alpha: .4)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: const Color(0xFFB9AEFF),
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
