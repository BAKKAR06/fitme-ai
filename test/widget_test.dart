import 'package:flutter_test/flutter_test.dart';

import 'package:fitme_ai/api.dart';
import 'package:fitme_ai/common.dart';
import 'package:fitme_ai/tryon_screen.dart';

void main() {
  group('categoryRu', () {
    test('maps backend categories to Russian labels', () {
      expect(categoryRu('upper_body'), 'Верх');
      expect(categoryRu('lower_body'), 'Низ');
      expect(categoryRu('dresses'), 'Платье');
      expect(categoryRu('unknown'), 'Верх');
    });
  });

  group('garmentTypeFor', () {
    test('detects garment type from product title', () {
      expect(garmentTypeFor('Oversize T-Shirt Black', 'upper_body'), 'Футболка');
      expect(garmentTypeFor('Grey sweatshirt', 'upper_body'), 'Свитер');
      expect(garmentTypeFor('Джинсы прямого кроя', 'lower_body'), 'Джинсы');
      expect(garmentTypeFor('Летнее платье миди', 'dresses'), 'Платье');
      expect(garmentTypeFor('Wool coat', 'upper_body'), 'Пальто');
    });

    test('falls back to category default', () {
      expect(garmentTypeFor('Item 123', 'upper_body'), 'Футболка');
      expect(garmentTypeFor('Item 123', 'lower_body'), 'Брюки');
      expect(garmentTypeFor('Item 123', 'dresses'), 'Платье');
    });
  });

  test('every garment type choice has a valid AI category', () {
    const valid = {'upper_body', 'lower_body', 'dresses'};
    for (final choice in garmentTypeChoices) {
      expect(valid.contains(choice.aiCategory), isTrue, reason: choice.label);
    }
  });

  group('ServerConfig', () {
    test('normalizes typed addresses', () {
      expect(ServerConfig.normalize('abc.trycloudflare.com/'), 'https://abc.trycloudflare.com');
      expect(ServerConfig.normalize('192.168.1.5:8000'), 'http://192.168.1.5:8000');
      expect(ServerConfig.normalize(' http://10.0.0.2:8000// '), 'http://10.0.0.2:8000');
    });

    test('labels the route', () {
      expect(ServerConfig.routeLabel('http://127.0.0.1:8000'), 'USB-кабель');
      expect(ServerConfig.routeLabel('http://192.168.0.10:8000'), 'Wi-Fi');
      expect(ServerConfig.routeLabel('http://172.20.1.1:8000'), 'Wi-Fi');
      expect(ServerConfig.routeLabel('https://x.trycloudflare.com'), 'Интернет');
    });

    test('builds absolute urls', () {
      expect(ServerConfig.url('https://a.b/c.png'), 'https://a.b/c.png');
      expect(ServerConfig.url('/generated/x.png'), endsWith('/generated/x.png'));
    });
  });

  test('outfit item photo type', () {
    final item = OutfitItem(
      catalog: const CatalogItem(
        id: '1',
        name: 'Jeans',
        category: 'lower_body',
        description: '',
        imageUrl: '/catalog/1.jpg',
        sourceName: '',
        sourceUrl: '',
      ),
      category: 'lower_body',
      label: 'Джинсы',
    );
    expect(item.photoType, 'auto');
    item.onModel = true;
    expect(item.photoType, 'model');
    item.onModel = false;
    expect(item.photoType, 'flat-lay');
  });

  test('try-on model parsing and category support', () {
    final m = TryOnModel.fromJson({
      'id': 'idm',
      'title': 'IDM-VTON',
      'categories': ['upper_body'],
      'available': true,
      'needs_token': true,
    });
    expect(m.isLocal, isFalse);
    expect(m.supports('upper_body'), isTrue);
    expect(m.supports('lower_body'), isFalse);
    expect(m.needsToken, isTrue);
    expect(TryOnModel.fallback.isLocal, isTrue);
    expect(TryOnModel.fallback.supports('dresses'), isTrue);
  });

  test('quality presets go up to 50 steps', () {
    expect(kQualityPresets.map((p) => p.$1), [15, 30, 50]);
  });
}
