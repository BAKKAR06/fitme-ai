import 'package:flutter/material.dart';

import 'api.dart';
import 'strings.dart';

/// App language. Russian is the source language: every UI text in the code is
/// written in Russian and passed through [t], which looks up the translation.
enum AppLang {
  ru('ru', 'Русский'),
  en('en', 'English'),
  kk('kk', 'Қазақша');

  const AppLang(this.code, this.title);

  final String code;
  final String title;
}

/// Theme + language chosen in the profile; saved on the phone.
class AppSettings {
  AppSettings._();

  /// Bumps on every change; FitMeApp listens and rebuilds the whole app.
  static final revision = ValueNotifier<int>(0);

  static ThemeMode get themeMode => switch (SettingsStore.get<String>('theme')) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static set themeMode(ThemeMode mode) {
    SettingsStore.set('theme', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
    revision.value++;
  }

  static AppLang get lang {
    final code = SettingsStore.get<String>('lang');
    return AppLang.values.firstWhere((l) => l.code == code, orElse: () => AppLang.ru);
  }

  static set lang(AppLang value) {
    SettingsStore.set('lang', value.code);
    revision.value++;
  }
}

/// Translates a Russian UI text into the chosen language.
/// Placeholders like `{n}` are filled from [args]: t('Шаг {n} из {all}', {'n': 1, 'all': 3}).
String t(String ru, [Map<String, Object?> args = const {}]) {
  final lang = AppSettings.lang;
  var text = switch (lang) {
    AppLang.ru => ru,
    AppLang.en => stringsEn[ru] ?? ru,
    AppLang.kk => stringsKk[ru] ?? ru,
  };
  args.forEach((key, value) => text = text.replaceAll('{$key}', '$value'));
  return text;
}
