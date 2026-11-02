import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'common.dart';
import 'firebase_auth.dart';
import 'i18n.dart';

/// Small JSON file in the app documents folder for settings that must survive
/// app restarts (server address, account token, theme, language).
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
    _debounce = Timer(Duration(milliseconds: 400), _flush);
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
  static Timer? _keepAlive;
  static DateTime _lastSoon = DateTime.fromMillisecondsSinceEpoch(0);

  static String get baseUrl => baseUrlNotifier.value;
  static String? get manualUrl => SettingsStore.get<String>('manual_url');

  /// Tunnel key (built into the app) + the account token after sign-in.
  static Map<String, String> get headers => {
    if (accessKey.isNotEmpty) 'X-FitMe-Key': accessKey,
    if (Session.token != null) 'Authorization': 'Bearer ${Session.token}',
  };

  static String routeLabel([String? url]) {
    final u = url ?? baseUrl;
    if (u.contains('127.0.0.1') || u.contains('localhost')) return 'USB-кабель';
    if (u.contains('trycloudflare.com') || u.contains('pinggy.link')) return 'Интернет';
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
      ..connectionTimeout = timeout ?? Duration(seconds: 4);
    try {
      final request = await client
          .getUrl(Uri.parse('$url/health'))
          .timeout(timeout ?? Duration(seconds: 6));
      final response = await request.close().timeout(
        timeout ?? Duration(seconds: 6),
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

  /// While the app is open: checks the server every minute and, when the internet address
  /// changed (the laptop's free tunnel gets a new one about every hour), switches by itself.
  static void startKeepAlive() {
    _keepAlive ??= Timer.periodic(const Duration(seconds: 60), (_) async {
      if (_running != null) return;
      if (!await isFitMe(baseUrl, timeout: _timeoutFor(baseUrl))) await discover();
    });
  }

  static void stopKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = null;
  }

  /// For failures outside API calls (a picture did not load): search again, at most every 20 s.
  static void discoverSoon() {
    final now = DateTime.now();
    if (now.difference(_lastSoon) < const Duration(seconds: 20)) return;
    _lastSoon = now;
    unawaited(discover());
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
        if (await isFitMe(candidate, timeout: _timeoutFor(candidate))) {
          _use(candidate);
          return true;
        }
      }
      final announced = await _announcedUrls();
      for (final candidate in announced) {
        if (await isFitMe(candidate, timeout: _timeoutFor(candidate))) {
          // A typed-in address that stopped working must not slow down every later search.
          if (manualUrl != null) SettingsStore.set('manual_url', null);
          _use(candidate);
          return true;
        }
      }
      return false;
    } finally {
      searching.value = false;
    }
  }

  /// Local addresses answer fast; internet tunnels may need a few seconds.
  static Duration _timeoutFor(String url) {
    final label = routeLabel(url);
    return label == 'USB-кабель' || label == 'Wi-Fi'
        ? Duration(seconds: 3)
        : Duration(seconds: 10);
  }

  static void _use(String url) {
    baseUrlNotifier.value = url;
    SettingsStore.set('last_url', url);
  }

  /// The laptop publishes {"lan": ..., "tunnel": ...} to a private ntfy.sh topic.
  static Future<List<String>> _announcedUrls() async {
    if (discoveryTopic.isEmpty) return [];
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse(
        'https://ntfy.sh/$discoveryTopic/json?poll=1&since=12h',
      );
      final request = await client.getUrl(uri).timeout(Duration(seconds: 8));
      final response = await request.close().timeout(Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      Map<String, dynamic>? latest;
      for (final line in LineSplitter().convert(body)) {
        if (line.trim().isEmpty) continue;
        final event = jsonDecode(line);
        if (event is Map && event['event'] == 'message') {
          final message = jsonDecode(event['message'].toString());
          if (message is Map<String, dynamic>) latest = message;
        }
      }
      if (latest == null) return [];
      return [
        if ((latest['lan'] ?? '').toString().isNotEmpty) latest['lan'].toString(),
        if ((latest['tunnel'] ?? '').toString().isNotEmpty)
          latest['tunnel'].toString(),
      ];
    } catch (_) {
      return [];
    } finally {
      client.close(force: true);
    }
  }
}

/// The signed-in account (see /api/v1/auth/*).
class AccountUser {
  const AccountUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
  });

  final String id; // Firebase uid
  final String email;
  final String name;
  final String role; // owner | admin | user

  bool get isAdmin => role == 'admin' || role == 'owner';
  bool get isOwner => role == 'owner';

  /// Name to greet with: the name, otherwise the part of the e-mail before @.
  String get displayName => name.trim().isNotEmpty ? name.trim() : email.split('@').first;

  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
    id: json['id']?.toString() ?? '',
    email: json['email']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    role: json['role']?.toString() ?? 'user',
  );

  Map<String, Object> toJson() => {'id': id, 'email': email, 'name': name, 'role': role};

  AccountUser copyWith({String? name, String? role}) =>
      AccountUser(id: id, email: email, name: name ?? this.name, role: role ?? this.role);
}

/// The signed-in Firebase account, kept on the phone between app starts.
/// ID tokens live one hour; [ensureFresh] renews them with the refresh token.
class Session {
  Session._();

  static FirebaseTokens? tokens;
  static final ValueNotifier<AccountUser?> user = ValueNotifier(null);
  static Future<void>? _refreshing;
  static Timer? _timer;

  /// Signed up / signed in, but the e-mail link is not opened yet.
  static FirebaseTokens? pending;
  static String pendingEmail = '';
  static String pendingName = '';

  static String? get token => tokens?.idToken;
  static bool get signedIn => tokens != null && user.value != null;

  static void load() {
    final t = SettingsStore.get<Map<String, dynamic>>('fb_tokens');
    final saved = SettingsStore.get<Map<String, dynamic>>('auth_user');
    if (t != null && saved != null) {
      tokens = FirebaseTokens(
        idToken: t['idToken'].toString(),
        refreshToken: t['refreshToken'].toString(),
        uid: t['uid'].toString(),
        expiresAt: DateTime.fromMillisecondsSinceEpoch((t['expiresAt'] as num?)?.toInt() ?? 0),
      );
      user.value = AccountUser.fromJson(saved);
      _startTimer();
    }
  }

  static void _saveTokens(FirebaseTokens t) {
    tokens = t;
    SettingsStore.set('fb_tokens', {
      'idToken': t.idToken,
      'refreshToken': t.refreshToken,
      'uid': t.uid,
      'expiresAt': t.expiresAt.millisecondsSinceEpoch,
    });
  }

  static void signIn(FirebaseTokens t, AccountUser u) {
    _saveTokens(t);
    pending = null;
    SettingsStore.set('auth_user', u.toJson());
    user.value = u;
    _startTimer();
  }

  static void updateTokens(FirebaseTokens t) => _saveTokens(t);

  static void updateUser(AccountUser u) {
    SettingsStore.set('auth_user', u.toJson());
    user.value = u;
  }

  static void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => ensureFresh());
  }

  /// Renews the ID token when it has less than 5 minutes left (one renewal at a time).
  static Future<void> ensureFresh() {
    final t = tokens;
    if (t == null || t.expiresAt.difference(DateTime.now()) > const Duration(minutes: 5)) {
      return Future.value();
    }
    return _refreshing ??= () async {
      try {
        _saveTokens(await FirebaseAuthApi.refresh(t.refreshToken));
      } on FirebaseAuthError catch (e) {
        // Revoked (blocked, password changed elsewhere, account deleted): sign out.
        if (e.code != 'NETWORK') clear();
      } finally {
        _refreshing = null;
      }
    }();
  }

  /// Forget the account on this phone (logout, or the server no longer accepts the token).
  static void clear() {
    _timer?.cancel();
    tokens = null;
    pending = null;
    SettingsStore.set('fb_tokens', null);
    SettingsStore.set('auth_user', null);
    user.value = null;
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

  /// Name without shop noise ("Купить … в Астане – Магазин на Kaspi.kz").
  String get displayName => cleanProductName(name);

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
      categories: (json['categories'] as List<dynamic>? ?? [])
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
  FitMeApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  /// Machine-readable reason from the server, e.g. 'not_verified'.
  final String? code;

  @override
  String toString() => message;
}

class FitMeApi {
  FitMeApi._();

  static const _jsonTimeout = Duration(seconds: 25);
  static const _uploadTimeout = Duration(seconds: 120);

  static FitMeApiException _error(int status, String body, String path) {
    String? message;
    String? code;
    try {
      final data = jsonDecode(body);
      final detail = data is Map ? data['detail'] : null;
      if (detail is Map) {
        message = detail['message']?.toString();
        code = detail['code']?.toString();
      } else if (detail != null) {
        message = detail.toString();
      }
    } catch (_) {}
    if (status == 401 && message != null && message.contains('FitMe key')) {
      message = t('Сервер не принял ключ доступа. Переустановите приложение через INSTALL_ON_PHONE.bat.');
    } else if (status == 401 && !path.startsWith('/api/v1/auth/')) {
      // The token expired, was revoked (password changed, account blocked) - sign in again.
      Session.clear();
      message = t('Сессия закончилась — войдите снова');
    }
    return FitMeApiException(
      t(message ?? 'Ошибка сервера ({code})', {'code': status}),
      statusCode: status,
      code: code,
    );
  }

  /// Runs [action]; on a connection problem looks for the server again and retries once.
  static Future<T> _withRediscovery<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on SocketException {
      if (await ServerConfig.discover()) return action();
      throw FitMeApiException(
        t('Нет связи с сервером FitMe. Проверьте, что ноутбук включён и START_LOCAL_GPU.bat запущен.'),
      );
    } on TimeoutException {
      if (await ServerConfig.discover()) return action();
      throw FitMeApiException(t('Сервер не отвечает. Попробуйте ещё раз.'));
    } on HttpException {
      if (await ServerConfig.discover()) return action();
      throw FitMeApiException(t('Связь с сервером прервалась. Попробуйте ещё раз.'));
    }
  }

  static Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    await Session.ensureFresh();
    return _withRediscovery(() async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        final uri = Uri.parse('${ServerConfig.baseUrl}$path');
        final request = await client.openUrl(method, uri).timeout(_jsonTimeout);
        ServerConfig.headers.forEach(request.headers.set);
        request.headers.contentType = ContentType.json;
        if (body != null) request.write(jsonEncode(body));
        final response = await request.close().timeout(_jsonTimeout);
        final text = await response.transform(utf8.decoder).join();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw _error(response.statusCode, text, path);
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
  }) async {
    await Session.ensureFresh();
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
          throw _error(response.statusCode, text, path);
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
    final raw = data['items'] as List<dynamic>? ?? [];
    final list = raw
        .whereType<Map<String, dynamic>>()
        .map(TryOnModel.fromJson)
        .toList();
    return list.isEmpty ? [TryOnModel.fallback] : list;
  }
  static Future<Map<String, dynamic>> aiStatus() =>
      _json('GET', '/api/v1/ai/status');

  static Future<List<CatalogItem>> getCatalog() async {
    final data = await _json('GET', '/api/v1/catalog');
    final raw = data['items'] as List<dynamic>? ?? [];
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
    required String selectedSize,
    required String selectedFit,
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
        'selected_size': selectedSize,
        'selected_fit': selectedFit,
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
    String? size,
    String? fit,
    String? color,
    String? resultUrl,
  }) {
    return _json(
      'POST',
      '/api/v1/looks/save',
      body: {
        'job_id': jobId,
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
        'size': ?size,
        'fit': ?fit,
        'color': ?color,
        'result_url': ?resultUrl,
      },
    );
  }

  // ---------------------------------------------------------------- account (Firebase)
  /// Creates the Firebase account; Firebase sends a confirmation link to the e-mail.
  static Future<void> register({required String email, required String password, required String name}) async {
    Session.pending = await FirebaseAuthApi.signUp(email, password);
    Session.pendingEmail = email.trim().toLowerCase();
    Session.pendingName = name.trim();
  }

  /// Throws FitMeApiException(code: 'not_verified') when the e-mail link was not opened yet.
  static Future<void> login({required String email, required String password}) async {
    final tokens = await FirebaseAuthApi.signIn(email, password);
    if (!await FirebaseAuthApi.isEmailVerified(tokens.idToken)) {
      Session.pending = tokens;
      Session.pendingEmail = email.trim().toLowerCase();
      throw FitMeApiException(t('Подтвердите почту: откройте ссылку из письма'), code: 'not_verified');
    }
    await _finishSignIn(tokens, email);
  }

  /// "I opened the link": checks with Firebase and finishes the sign-in.
  static Future<bool> confirmVerified() async {
    final pending = Session.pending;
    if (pending == null) return false;
    final fresh = await FirebaseAuthApi.refresh(pending.refreshToken);
    if (!await FirebaseAuthApi.isEmailVerified(fresh.idToken)) return false;
    // The token issued before the click says "not verified"; take a new one.
    final verified = await FirebaseAuthApi.refresh(fresh.refreshToken);
    await _finishSignIn(verified, Session.pendingEmail);
    return true;
  }

  static Future<void> resendVerification() async {
    final pending = Session.pending;
    if (pending == null) return;
    final fresh = await FirebaseAuthApi.refresh(pending.refreshToken);
    Session.pending = fresh;
    await FirebaseAuthApi.sendVerificationEmail(fresh.idToken);
  }

  static Future<void> forgotPassword(String email) => FirebaseAuthApi.sendPasswordReset(email);

  /// Tells the FitMe server about the sign-in (it creates the profile on the first visit).
  static Future<void> _finishSignIn(FirebaseTokens tokens, String email) async {
    final name = Session.pendingName;
    Session.tokens = tokens; // the request below must carry this token
    try {
      final data = await _json('POST', '/api/v1/auth/session');
      var user = AccountUser.fromJson(data['user'] as Map<String, dynamic>);
      if (name.isNotEmpty && user.name.isEmpty) {
        await _json('PATCH', '/api/v1/auth/me', body: {'name': name});
        user = user.copyWith(name: name);
      }
      Session.pendingName = '';
      Session.signIn(tokens, user);
    } on FitMeApiException catch (e) {
      if (e.statusCode != null) {
        Session.tokens = null;
        rethrow; // blocked, registration closed, ...
      }
      // The laptop is off: sign in anyway, the role is fetched when it is back.
      Session.signIn(tokens, AccountUser(id: tokens.uid, email: email.trim().toLowerCase(), name: name, role: 'user'));
    }
  }

  /// Account + usage; also refreshes the cached user (role may have changed).
  static Future<Map<String, dynamic>> me() async {
    final data = await _json('GET', '/api/v1/auth/me');
    Session.updateUser(AccountUser.fromJson(data['user'] as Map<String, dynamic>));
    return data;
  }

  static Future<void> updateName(String name) async {
    final data = await _json('PATCH', '/api/v1/auth/me', body: {'name': name.trim()});
    Session.updateUser(AccountUser.fromJson(data['user'] as Map<String, dynamic>));
  }

  static Future<void> changePassword(String oldPassword, String newPassword) async {
    final email = Session.user.value?.email ?? '';
    final fresh = await FirebaseAuthApi.signIn(email, oldPassword); // also checks the old password
    Session.updateTokens(await FirebaseAuthApi.changePassword(fresh.idToken, newPassword));
  }

  static Future<void> logout() async {
    SettingsStore.set('person_path', null); // pre-v5 shared key; photos are per account now
    Session.clear();
  }

  static Future<void> deleteAccount(String password) async {
    final email = Session.user.value?.email ?? '';
    Session.updateTokens(await FirebaseAuthApi.signIn(email, password)); // checks the password
    await _json('POST', '/api/v1/auth/delete-account');
    await logout();
  }

  // ---------------------------------------------------------------- admin
  static Future<Map<String, dynamic>> adminOverview() => _json('GET', '/api/v1/admin/overview');

  static Future<List<Map<String, dynamic>>> adminUsers({String query = ''}) async {
    final data = await _json('GET', '/api/v1/admin/users?q=${Uri.encodeQueryComponent(query)}');
    return (data['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
  }

  static Future<List<Map<String, dynamic>>> adminJobs() async {
    final data = await _json('GET', '/api/v1/admin/jobs?limit=100');
    return (data['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
  }

  static Future<void> adminSetRole(String userId, String role) async {
    await _json('POST', '/api/v1/admin/users/$userId/role', body: {'role': role});
  }

  static Future<void> adminSetBlocked(String userId, bool blocked) async {
    await _json('POST', '/api/v1/admin/users/$userId/block', body: {'blocked': blocked});
  }

  static Future<void> adminDeleteUser(String userId) async {
    await _json('DELETE', '/api/v1/admin/users/$userId');
  }

  static Future<Map<String, dynamic>> adminSettings() => _json('GET', '/api/v1/admin/settings');

  static Future<void> adminSaveSettings({bool? registrationOpen, int? dailyLimit}) async {
    await _json(
    'POST',
    '/api/v1/admin/settings',
    body: {'registration_open': ?registrationOpen, 'daily_tryon_limit': ?dailyLimit},
  );
  }


  static Future<List<Map<String, dynamic>>> getLooks() async {
    final data = await _json('GET', '/api/v1/looks');
    final raw = data['items'] as List<dynamic>? ?? [];
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
    // Rebuilt when the server address changes, so pictures load from the new address.
    return ValueListenableBuilder<String>(
      valueListenable: ServerConfig.baseUrlNotifier,
      builder: (context, _, _) => _image(),
    );
  }

  Widget _image() {
    return Image.network(
      ServerConfig.url(pathOrUrl),
      headers: ServerConfig.headers,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
      errorBuilder: (context, error, stack) {
        if (!pathOrUrl.startsWith('http')) ServerConfig.discoverSoon();
        return Center(
          child: Icon(Icons.image_not_supported_outlined, color: FitColors.line2, size: 34),
        );
      },
    );
  }
}
