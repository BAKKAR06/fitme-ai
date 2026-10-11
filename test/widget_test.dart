import 'package:flutter_test/flutter_test.dart';

import 'package:fitme_ai/main.dart';

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
}
