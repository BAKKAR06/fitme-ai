import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Small JSON file in the app documents folder for settings that must survive
/// app restarts (server address, body profile).
class SettingsStore {
  SettingsStore._();

  static Map<String, dynamic> _cache = {};
  static Timer? _debounce;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}fitme_settings.json');
  }

  static Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map<String, dynamic>) _cache = data;
      }
    } catch (_) {
      _cache = {};
    }
  }

  static T? get<T>(String key) {
    final value = _cache[key];
    return value is T ? value : null;
  }

  static void set(String key, Object? value) {
    if (value == null) {
      _cache.remove(key);
    } else {
      _cache[key] = value;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _flush);
  }

  static Future<void> _flush() async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(_cache), flush: true);
    } catch (_) {
      // Settings are a convenience; never crash the app because of them.
    }
  }
}

/// Where the FitMe backend lives and how the phone reaches it.
///
/// Order of attempts: manual address → last working address → USB (adb reverse)
/// → addresses announced by the laptop (Wi-Fi, then internet tunnel).
class ServerConfig {
  ServerConfig._();

  static const String accessKey = String.fromEnvironment('FITME_KEY');
  static const String discoveryTopic = String.fromEnvironment('FITME_TOPIC');
  static const String usbUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  static final ValueNotifier<String> baseUrlNotifier = ValueNotifier(usbUrl);
  static final ValueNotifier<bool> searching = ValueNotifier(false);
  static Future<bool>? _running;

  static String get baseUrl => baseUrlNotifier.value;
  static String? get manualUrl => SettingsStore.get<String>('manual_url');

  static Map<String, String> get headers =>
      accessKey.isEmpty ? const {} : {'X-FitMe-Key': accessKey};

  static String routeLabel([String? url]) {
    final u = url ?? baseUrl;
    if (u.contains('127.0.0.1') || u.contains('localhost')) return 'USB-кабель';
    if (u.contains('trycloudflare.com')) return 'Интернет';
    if (u.contains('hf.space')) return 'Облако';
    final host = Uri.tryParse(u)?.host ?? '';
    if (host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host)) {
      return 'Wi-Fi';
    }
    return 'Свой адрес';
  }

  /// Absolute URL for a backend path like `/generated/x.png`.
  static String url(String pathOrUrl) {
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      return pathOrUrl;
    }
    return '$baseUrl$pathOrUrl';
  }

  static Future<void> init() async {
    final saved = SettingsStore.get<String>('last_url');
    if (saved != null && saved.isNotEmpty) baseUrlNotifier.value = saved;
  }

  static String normalize(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = value.contains('trycloudflare.com') || value.contains('hf.space')
          ? 'https://$value'
          : 'http://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static void setManualUrl(String? raw) {
    final value = raw == null ? null : normalize(raw);
    SettingsStore.set('manual_url', value == null || value.isEmpty ? null : value);
  }

  static Future<bool> isFitMe(String url, {Duration? timeout}) async {
    final client = HttpClient()
      ..connectionTimeout = timeout ?? const Duration(seconds: 4);
    try {
      final request = await client
          .getUrl(Uri.parse('$url/health'))
          .timeout(timeout ?? const Duration(seconds: 6));
      final response = await request.close().timeout(
        timeout ?? const Duration(seconds: 6),
      );
      if (response.statusCode != 200) return false;
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      return data is Map && data['app'] == 'FitMe AI';
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Finds a working backend. Safe to call often: concurrent calls share one search.
  static Future<bool> discover() {
    return _running ??= _discover().whenComplete(() => _running = null);
  }

  static Future<bool> _discover() async {
    searching.value = true;
    try {
      final candidates = <String>[
        ?manualUrl,
        baseUrl,
        usbUrl,
      ];
      for (final candidate in candidates.toSet()) {
        if (await isFitMe(candidate, timeout: const Duration(seconds: 3))) {
          _use(candidate);
          return true;
        }
      }
      final announced = await _announcedUrls();
      for (final candidate in announced) {
        final timeout = candidate.contains('trycloudflare.com')
            ? const Duration(seconds: 10)
            : const Duration(seconds: 3);
        if (await isFitMe(candidate, timeout: timeout)) {
          _use(candidate);
          return true;
        }
      }
      return false;
    } finally {
      searching.value = false;
    }
  }

  static void _use(String url) {
    baseUrlNotifier.value = url;
    SettingsStore.set('last_url', url);
  }

  /// The laptop publishes {"lan": ..., "tunnel": ...} to a private ntfy.sh topic.
  static Future<List<String>> _announcedUrls() async {
    if (discoveryTopic.isEmpty) return const [];
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse(
        'https://ntfy.sh/$discoveryTopic/json?poll=1&since=12h',
      );
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      Map<String, dynamic>? latest;
      for (final line in const LineSplitter().convert(body)) {
        if (line.trim().isEmpty) continue;
        final event = jsonDecode(line);
        if (event is Map && event['event'] == 'message') {
          final message = jsonDecode(event['message'].toString());
          if (message is Map<String, dynamic>) latest = message;
        }
      }
      if (latest == null) return const [];
      return [
        if ((latest['lan'] ?? '').toString().isNotEmpty) latest['lan'].toString(),
        if ((latest['tunnel'] ?? '').toString().isNotEmpty)
          latest['tunnel'].toString(),
      ];
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }
}

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

/// One garment of an outfit on the try-on screen.
class OutfitItem {
  OutfitItem({
    this.photo,
    this.catalog,
    required this.category,
    required this.label,
    this.onModel,
  }) : assert(photo != null || catalog != null);

  final XFile? photo;
  final CatalogItem? catalog;
  String category;
  String label;
  /// null = let the server decide (it checks whether a person is on the photo).
  bool? onModel;

  String get photoType => switch (onModel) {
    null => 'auto',
    true => 'model',
    false => 'flat-lay',
  };
}

/// A try-on model the server can run (see GET /api/v1/models).
class TryOnModel {
  const TryOnModel({
    required this.id,
    required this.title,
    required this.where,
    required this.categories,
    required this.limit,
    required this.note,
    required this.license,
    required this.available,
    this.reason,
    this.needsToken = false,
  });

  final String id;
  final String title;
  final String where;
  final List<String> categories;
  final String limit;
  final String note;
  final String license;
  final bool available;
  final String? reason;
  final bool needsToken;

  bool get isLocal => id == 'fashn';

  bool supports(String category) => categories.contains(category);

  /// Used before the server answered: the laptop model.
  static const fallback = TryOnModel(
    id: 'fashn',
    title: 'FASHN VTON 1.5',
    where: 'Ноутбук (ваша видеокарта)',
    categories: ['upper_body', 'lower_body', 'dresses'],
    limit: 'без лимита',
    note: 'Основная модель',
    license: 'Apache-2.0',
    available: true,
  );

  factory TryOnModel.fromJson(Map<String, dynamic> json) {
    return TryOnModel(
      id: json['id']?.toString() ?? 'fashn',
      title: json['title']?.toString() ?? 'Модель',
      where: json['where']?.toString() ?? '',
      categories: (json['categories'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      limit: json['limit']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
      license: json['license']?.toString() ?? '',
      available: json['available'] == true,
      reason: json['reason']?.toString(),
      needsToken: json['needs_token'] == true,
    );
  }
}

class FitMeApiException implements Exception {
  FitMeApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class FitMeApi {
  FitMeApi._();

  static const _jsonTimeout = Duration(seconds: 25);
  static const _uploadTimeout = Duration(seconds: 120);

  static String _friendly(int status, String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map && data['detail'] != null) return data['detail'].toString();
    } catch (_) {}
    if (status == 401) {
      return 'Сервер не принял ключ доступа. Переустановите приложение через INSTALL_ON_PHONE.bat.';
    }
    return 'Ошибка сервера ($status)';
  }

  /// Runs [action]; on a connection problem looks for the server again and retries once.
  static Future<T> _withRediscovery<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on SocketException {
      if (await ServerConfig.discover()) return action();
      throw FitMeApiException(
        'Нет связи с сервером FitMe. Проверьте, что ноутбук включён и START_LOCAL_GPU.bat запущен.',
      );
    } on TimeoutException {
      if (await ServerConfig.discover()) return action();
      throw FitMeApiException('Сервер не отвечает. Попробуйте ещё раз.');
    } on HttpException {
      if (await ServerConfig.discover()) return action();
      throw FitMeApiException('Связь с сервером прервалась. Попробуйте ещё раз.');
    }
  }

  static Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) {
    return _withRediscovery(() async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        final uri = Uri.parse('${ServerConfig.baseUrl}$path');
        final request = await (method == 'POST'
                ? client.postUrl(uri)
                : method == 'DELETE'
                ? client.deleteUrl(uri)
                : client.getUrl(uri))
            .timeout(_jsonTimeout);
        ServerConfig.headers.forEach(request.headers.set);
        request.headers.contentType = ContentType.json;
        if (body != null) request.write(jsonEncode(body));
        final response = await request.close().timeout(_jsonTimeout);
        final text = await response.transform(utf8.decoder).join();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw FitMeApiException(
            _friendly(response.statusCode, text),
            statusCode: response.statusCode,
          );
        }
        if (text.isEmpty) return <String, dynamic>{};
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    });
  }

  static Future<Map<String, dynamic>> _multipart(
    String path, {
    required Map<String, String> fields,
    required List<MapEntry<String, XFile>> files,
  }) {
    return _withRediscovery(() async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final uri = Uri.parse('${ServerConfig.baseUrl}$path');
        final request = await client.postUrl(uri).timeout(_jsonTimeout);
        ServerConfig.headers.forEach(request.headers.set);
        final boundary = '----FitMe${DateTime.now().microsecondsSinceEpoch}';
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

        for (final entry in files) {
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
        final response = await request.close().timeout(_uploadTimeout);
        final text = await response.transform(utf8.decoder).join();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw FitMeApiException(
            _friendly(response.statusCode, text),
            statusCode: response.statusCode,
          );
        }
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    });
  }

  static Future<Map<String, dynamic>> health() => _json('GET', '/health');

  static Future<List<TryOnModel>> models({bool refresh = false}) async {
    final data = await _json('GET', '/api/v1/models${refresh ? '?refresh=true' : ''}');
    final raw = data['items'] as List<dynamic>? ?? const [];
    final list = raw
        .whereType<Map<String, dynamic>>()
        .map(TryOnModel.fromJson)
        .toList();
    return list.isEmpty ? const [TryOnModel.fallback] : list;
  }
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
      files: [MapEntry('garment_photo', garmentPhoto)],
    );
    return CatalogItem.fromJson(data['item'] as Map<String, dynamic>);
  }

  /// Try on 1-3 garments at once (the server puts them on one after another).
  static Future<Map<String, dynamic>> uploadOutfit({
    required XFile personPhoto,
    required List<OutfitItem> items,
    required String title,
    required String selectedColor,
    required String selectedSize,
    required String selectedFit,
    required String selectedGender,
    required double bodyHeight,
    required double bodyWeight,
    required double bodyChest,
    required double bodyWaist,
    required double bodyHips,
    required int numSteps,
    required int seed,
    String model = 'fashn',
  }) {
    final files = <MapEntry<String, XFile>>[
      MapEntry('person_photo', personPhoto),
    ];
    final described = <Map<String, Object>>[];
    for (final item in items) {
      final entry = <String, Object>{
        'category': item.category,
        'photo_type': item.photoType,
        'label': item.label,
      };
      if (item.catalog != null) {
        entry['catalog_item_id'] = item.catalog!.id;
      } else {
        entry['upload_index'] = files.length - 1;
        files.add(MapEntry('garment_photos', item.photo!));
      }
      described.add(entry);
    }

    return _multipart(
      '/api/v1/try-on/outfit',
      fields: {
        'items': jsonEncode(described),
        'title': title,
        'selected_color': selectedColor,
        'selected_size': selectedSize,
        'selected_fit': selectedFit,
        'selected_gender': selectedGender,
        'body_height': bodyHeight.toStringAsFixed(1),
        'body_weight': bodyWeight.toStringAsFixed(1),
        'body_chest': bodyChest.toStringAsFixed(1),
        'body_waist': bodyWaist.toStringAsFixed(1),
        'body_hips': bodyHips.toStringAsFixed(1),
        'num_steps': '$numSteps',
        'seed': '$seed',
        'model': model,
      },
      files: files,
    );
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
        'gender': ?gender,
        'size': ?size,
        'fit': ?fit,
        'color': ?color,
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

/// Network image from the FitMe backend: sends the access key, shows a spinner
/// while loading and a neat placeholder when the server is unreachable.
class NetImage extends StatelessWidget {
  const NetImage(
    this.pathOrUrl, {
    super.key,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
  });

  final String pathOrUrl;
  final BoxFit fit;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      ServerConfig.url(pathOrUrl),
      headers: ServerConfig.headers,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return const Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
      errorBuilder: (context, error, stack) => const Center(
        child: Icon(Icons.image_not_supported_outlined, color: Colors.white24, size: 34),
      ),
    );
  }
}
