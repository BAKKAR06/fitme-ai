import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shared colours of the FitMe dark theme.
class FitColors {
  FitColors._();

  static const background = Color(0xFF0D0E12);
  static const card = Color(0xFF17181E);
  static const cardHigh = Color(0xFF1F2028);
  static const accent = Color(0xFF8B7CF6);
  static const accentSoft = Color(0xFFB9AEFF);
  static const ok = Color(0xFF5FD39A);
  static const warn = Color(0xFFF2B35B);
  static const danger = Color(0xFFFF6B6B);
}

String categoryRu(String value) {
  switch (value) {
    case 'lower_body':
      return 'Низ';
    case 'dresses':
      return 'Платье';
    default:
      return 'Верх';
  }
}

class GarmentTypeChoice {
  const GarmentTypeChoice(this.label, this.aiCategory);

  final String label;
  final String aiCategory;
}

const garmentTypeChoices = <GarmentTypeChoice>[
  GarmentTypeChoice('Футболка', 'upper_body'),
  GarmentTypeChoice('Топ', 'upper_body'),
  GarmentTypeChoice('Рубашка', 'upper_body'),
  GarmentTypeChoice('Блузка', 'upper_body'),
  GarmentTypeChoice('Худи', 'upper_body'),
  GarmentTypeChoice('Свитер', 'upper_body'),
  GarmentTypeChoice('Куртка', 'upper_body'),
  GarmentTypeChoice('Пиджак', 'upper_body'),
  GarmentTypeChoice('Пальто', 'upper_body'),
  GarmentTypeChoice('Джинсы', 'lower_body'),
  GarmentTypeChoice('Брюки', 'lower_body'),
  GarmentTypeChoice('Шорты', 'lower_body'),
  GarmentTypeChoice('Юбка', 'lower_body'),
  GarmentTypeChoice('Платье', 'dresses'),
];

String garmentTypeFor(String text, String aiCategory) {
  final q = text.toLowerCase();

  // Order matters: 'sweatshirt' contains 'tshirt' and 'shirt'; 't-shirt' must win over 'shirt'.
  const keywords = <String, String>{
    'sweatshirt': 'Свитер',
    'свитшот': 'Свитер',
    'футбол': 'Футболка',
    't-shirt': 'Футболка',
    'tshirt': 'Футболка',
    'shirt': 'Рубашка',
    'рубаш': 'Рубашка',
    'hood': 'Худи',
    'худи': 'Худи',
    'sweater': 'Свитер',
    'свит': 'Свитер',
    'jacket': 'Куртка',
    'куртк': 'Куртка',
    'blazer': 'Пиджак',
    'пидж': 'Пиджак',
    'coat': 'Пальто',
    'пальто': 'Пальто',
    'jean': 'Джинсы',
    'джинс': 'Джинсы',
    'trouser': 'Брюки',
    'pant': 'Брюки',
    'брюк': 'Брюки',
    'short': 'Шорты',
    'шорт': 'Шорты',
    'skirt': 'Юбка',
    'юбк': 'Юбка',
    'dress': 'Платье',
    'плать': 'Платье',
  };

  for (final entry in keywords.entries) {
    if (q.contains(entry.key)) return entry.value;
  }

  switch (aiCategory) {
    case 'lower_body':
      return 'Брюки';
    case 'dresses':
      return 'Платье';
    default:
      return 'Футболка';
  }
}

GarmentTypeChoice garmentChoiceFor(String label) {
  return garmentTypeChoices.firstWhere(
    (c) => c.label == label,
    orElse: () => garmentTypeChoices.first,
  );
}

Future<GarmentTypeChoice?> showGarmentTypePicker(
  BuildContext context, {
  required String selectedLabel,
}) {
  return showModalBottomSheet<GarmentTypeChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: FitColors.card,
    builder: (sheetContext) {
      var query = '';

      return StatefulBuilder(
        builder: (context, setLocalState) {
          final items = garmentTypeChoices
              .where(
                (item) =>
                    item.label.toLowerCase().contains(query.toLowerCase()),
              )
              .toList();

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                0,
                18,
                18 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .58,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Что это за вещь?',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (value) {
                        setLocalState(() => query = value.trim());
                      },
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Например: джинсы',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: Colors.white10),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final selected = item.label == selectedLabel;
                          return ListTile(
                            dense: true,
                            title: Text(item.label),
                            subtitle: Text(
                              categoryRu(item.aiCategory),
                              style: const TextStyle(color: Colors.white38),
                            ),
                            trailing: selected
                                ? const Icon(
                                    Icons.check_circle,
                                    color: FitColors.accentSoft,
                                  )
                                : null,
                            onTap: () => Navigator.pop(sheetContext, item),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class CompactGarmentTypeField extends StatelessWidget {
  const CompactGarmentTypeField({
    super.key,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: OutlinedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: const Icon(Icons.search, size: 19),
        label: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down),
          ],
        ),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          side: const BorderSide(color: Colors.white24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
      ),
    );
  }
}

class MeasurementSlider extends StatelessWidget {
  const MeasurementSlider({
    super.key,
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
    return Column(
      children: [
        Row(
          children: [
            Text(label),
            const Spacer(),
            Text(
              '${value.round()} $unit',
              style: const TextStyle(fontWeight: FontWeight.w700),
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
    );
  }
}

/// Rounded dark card used across all screens.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: FitColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white10),
      ),
      child: child,
    );
  }
}

class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: const TextStyle(color: Colors.white60)),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  String confirm = 'Удалить',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return result ?? false;
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

Future<void> openProductSource(BuildContext context, String rawUrl) async {
  var value = rawUrl.trim();
  if (value.isEmpty) return;
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'https://$value';
  }

  final uri = Uri.tryParse(value);
  if (uri == null ||
      !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (!context.mounted) return;
    showMessage(context, 'Не удалось открыть ссылку товара');
  }
}

/// Fullscreen zoomable image (pinch to zoom).
void openZoom(BuildContext context, Widget image, {String? title}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: title == null ? null : Text(title),
        ),
        body: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(child: image),
        ),
      ),
    ),
  );
}
