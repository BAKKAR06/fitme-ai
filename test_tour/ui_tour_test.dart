// Renders the main screens to PNG files for a visual check (not part of the normal tests):
//   flutter test test_tour --update-goldens
// Pictures land in test_tour/goldens/. Real fonts are loaded so Cyrillic text is readable.
// A tiny local HTTP server plays the FitMe backend with the demo data in test_tour/fixtures.
import 'dart:convert';
import 'dart:io';

import 'package:fitme_ai/admin_screen.dart';
import 'package:fitme_ai/api.dart';
import 'package:fitme_ai/common.dart';
import 'package:fitme_ai/firebase_auth.dart';
import 'package:fitme_ai/i18n.dart';
import 'package:fitme_ai/main.dart';
import 'package:fitme_ai/tryon_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var any = false;
  for (final path in paths) {
    final file = File(path);
    if (file.existsSync()) {
      loader.addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer)));
      any = true;
    }
  }
  if (any) await loader.load();
}

Future<void> _fonts() async {
  const win = r'C:\Windows\Fonts';
  await _loadFont('Roboto', ['$win\\segoeui.ttf', '$win\\segoeuib.ttf', '$win\\seguisb.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\flutter';
  await _loadFont('MaterialIcons', [
    '$flutterRoot\\bin\\cache\\artifacts\\material_fonts\\MaterialIcons-Regular.otf',
  ]);
}

const fixtures = 'test_tour/fixtures';

/// Fake backend: canned JSON for the API, demo pictures for /generated and /catalog.
Future<HttpServer> _fakeBackend() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  String fixture(String name) => File('$fixtures/$name').readAsStringSync();
  server.listen((request) async {
    final path = request.uri.path;
    final response = request.response;
    Object? json;
    if (path == '/health') {
      json = {'app': 'FitMe AI', 'status': 'online', 'version': '4.0.0', 'accounts': true};
    } else if (path == '/api/v1/ai/status') {
      json = {
        'online': true,
        'ai': {'gpu': 'NVIDIA GeForce RTX 4060 Laptop GPU', 'upscaler': true},
        'queue': {'active': 0, 'waiting': 0},
      };
    } else if (path == '/api/v1/models') {
      json = {
        'items': [
          {
            'id': 'fashn', 'title': 'FASHN VTON 1.5', 'where': 'Ноутбук (ваша видеокарта)',
            'categories': ['upper_body', 'lower_body', 'dresses'], 'limit': 'без лимита',
            'note': 'Основная модель', 'license': 'Apache-2.0', 'available': true,
          },
        ],
      };
    } else if (path == '/api/v1/auth/me') {
      json = jsonDecode(fixture('me.json'));
    } else if (path.startsWith('/api/v1/admin/')) {
      json = jsonDecode(fixture('admin_${path.split('/').last}.json'));
    } else if (path == '/api/v1/catalog' || path == '/api/v1/looks') {
      json = {'items': <Object>[]};
    } else if (path.startsWith('/generated/')) {
      response.headers.contentType = ContentType('image', 'png');
      response.add(File('$fixtures/result.png').readAsBytesSync());
      await response.close();
      return;
    }
    if (json == null) {
      response.statusCode = 404;
      json = {'detail': 'not found'};
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(json));
    await response.close();
  });
  return server;
}

void main() {
  late HttpServer backend;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // talk to the fake backend for real
    final docs = Directory.systemTemp.createTempSync('fitme_tour');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => docs.path,
    );
    await _fonts();
    backend = await _fakeBackend();
    FirebaseAuthApi.apiKey = 'demo-key'; // looks configured; the tour never signs in for real
  });

  tearDownAll(() => backend.close(force: true));

  void signIn(bool yes) {
    if (yes) {
      Session.tokens = FirebaseTokens(
        idToken: 'demo-token',
        refreshToken: 'demo-refresh',
        uid: 'demoowner',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );
      Session.user.value = const AccountUser(id: 'demoowner', email: 'owner@fitme.kz', name: 'Бакдаулет', role: 'owner');
    } else {
      Session.tokens = null;
      Session.user.value = null;
    }
  }

  Future<void> settle(WidgetTester tester, [int ms = 700]) async {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> prepare(WidgetTester tester, ThemeMode theme, AppLang lang) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    AppSettings.themeMode = theme;
    AppSettings.lang = lang;
    FitColors.dark = theme == ThemeMode.dark;
    ServerConfig.baseUrlNotifier.value = 'http://127.0.0.1:${backend.port}';
  }

  Future<void> finish(WidgetTester tester, String name) async {
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  Future<void> shot(
    WidgetTester tester,
    String name, {
    required int tab,
    ThemeMode theme = ThemeMode.dark,
    AppLang lang = AppLang.ru,
    bool signedIn = true,
    String? tapText,
  }) async {
    await prepare(tester, theme, lang);
    signIn(signedIn);
    await tester.runAsync(() async {
      await tester.pumpWidget(const FitMeApp());
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(seconds: 1));
    // Taps inside runAsync: screens start real HTTP requests to the fake backend in initState.
    await tester.runAsync(() async {
      if (signedIn && tab != 0) {
        final labels = ['Главная', 'Каталог', 'Примерка', 'Луки', 'Профиль'];
        await tester.tap(find.text(t(labels[tab])).last);
        await tester.pump();
      }
      if (tapText != null) {
        await tester.tap(find.text(t(tapText)).first);
        await tester.pump();
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await settle(tester);
    await finish(tester, name);
  }

  Future<void> page(WidgetTester tester, String name, Widget child, {ThemeMode theme = ThemeMode.dark, int tab = 0}) async {
    await prepare(tester, theme, AppLang.ru);
    signIn(true);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: theme,
        home: child,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(seconds: 1));
    if (tab != 0) {
      await tester.runAsync(() async {
        await tester.tap(find.byType(Tab).at(tab));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      });
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);
    await finish(tester, name);
  }

  testWidgets('login dark', (t) => shot(t, 'login_dark', tab: 0, signedIn: false));
  testWidgets('register light', (t) => shot(t, 'register_light', tab: 0, signedIn: false, theme: ThemeMode.light, tapText: 'Регистрация'));
  testWidgets('home dark', (t) => shot(t, 'home_dark', tab: 0));
  testWidgets('home light', (t) => shot(t, 'home_light', tab: 0, theme: ThemeMode.light));
  testWidgets('tryon dark', (t) => shot(t, 'tryon_dark', tab: 2));
  testWidgets('catalog light', (t) => shot(t, 'catalog_light', tab: 1, theme: ThemeMode.light));
  testWidgets('profile dark', (t) => shot(t, 'profile_dark', tab: 4));
  testWidgets('profile light en', (t) => shot(t, 'profile_light_en', tab: 4, theme: ThemeMode.light, lang: AppLang.en));
  testWidgets('home dark kk', (t) => shot(t, 'home_dark_kk', tab: 0, lang: AppLang.kk));
  testWidgets('admin overview dark', (t) => page(t, 'admin_overview_dark', const AdminScreen()));
  testWidgets('admin users dark', (t) => page(t, 'admin_users_dark', const AdminScreen(), tab: 1));
  testWidgets('admin settings light', (t) => page(t, 'admin_settings_light', const AdminScreen(), theme: ThemeMode.light, tab: 3));

  testWidgets('result', (tester) async {
    final key = GlobalKey<TryOnScreenState>();
    await prepare(tester, ThemeMode.dark, AppLang.ru);
    signIn(true);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: Scaffold(body: SafeArea(child: TryOnScreen(key: key))),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    final s = key.currentState!;
    // ignore: invalid_use_of_protected_member
    s.setState(() {
      s.personPhoto = XFile('$fixtures/person.png');
      s.outfit.add(OutfitItem(photo: XFile('$fixtures/garment.png'), category: 'upper_body', label: 'Футболка'));
      s.jobId = 'demo';
      s.status = 'completed';
      s.resultUrl = '/generated/demo_step1.png';
      s.shownUrl = s.resultUrl;
    });
    await tester.runAsync(() async {
      for (final image in <ImageProvider>[
        FileImage(File('$fixtures/person.png')),
        FileImage(File('$fixtures/garment.png')),
        NetworkImage(ServerConfig.url(s.resultUrl!)),
      ]) {
        final ctx = key.currentContext;
        if (ctx == null || !ctx.mounted) return;
        await precacheImage(image, ctx);
      }
    });
    await settle(tester);
    // The result card is far below the form: scroll until the list builds it.
    await tester.dragUntilVisible(find.text(t('Сохранить')), find.byType(ListView).first, const Offset(0, -500));
    await tester.ensureVisible(find.text(t('Сохранить')));
    await settle(tester, 900);
    await finish(tester, 'result_dark');
  });
}
