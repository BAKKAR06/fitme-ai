import 'package:flutter/material.dart';

import 'api.dart';
import 'common.dart';

class LooksScreen extends StatefulWidget {
  const LooksScreen({super.key});

  @override
  State<LooksScreen> createState() => _LooksScreenState();
}

class _LooksScreenState extends State<LooksScreen> {
  bool loading = true;
  List<Map<String, dynamic>> looks = const [];
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FitMeApi.getLooks();
      if (!mounted) return;
      setState(() {
        looks = result;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _delete(Map<String, dynamic> look) async {
    final id = look['look_id']?.toString() ?? '';
    if (id.isEmpty) return;
    final ok = await confirmAction(
      context,
      title: 'Удалить образ?',
      message: look['title']?.toString(),
    );
    if (!ok || !mounted) return;
    try {
      await FitMeApi.deleteLook(id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showMessage(context, 'Не удалось удалить: $e');
    }
  }

  String _date(String? value) {
    final dt = value == null ? null : DateTime.tryParse(value)?.toLocal();
    if (dt == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.day)}.${two(dt.month)} • ${two(dt.hour)}:${two(dt.minute)}';
  }

  void _open(Map<String, dynamic> look) {
    final url = look['result_url']?.toString();
    if (url == null || url.isEmpty) return;
    final items = (look['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final sourceUrl = look['source_url']?.toString() ?? '';
    final sourceName = look['source_name']?.toString() ?? '';

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(look['title']?.toString() ?? 'Образ')),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    color: Colors.black,
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: Center(child: NetImage(url, fit: BoxFit.contain)),
                    ),
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                  color: FitColors.card,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final item in items)
                            Chip(label: Text(item['label']?.toString() ?? '')),
                          if ((look['engine']?.toString() ?? '').isNotEmpty)
                            Chip(
                              avatar: const Icon(Icons.auto_awesome, size: 16),
                              label: Text(
                                look['num_timesteps'] == null
                                    ? look['engine'].toString()
                                    : '${look['engine']} • ${look['num_timesteps']} шагов',
                              ),
                            ),
                          for (final key in const ['gender', 'size', 'fit', 'color'])
                            if ((look[key]?.toString() ?? '').isNotEmpty)
                              Chip(
                                label: Text(
                                  key == 'size' ? 'Размер ${look[key]}' : look[key].toString(),
                                ),
                              ),
                        ],
                      ),
                      if (sourceUrl.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => openProductSource(context, sourceUrl),
                          icon: const Icon(Icons.open_in_new),
                          label: Text(sourceName.isEmpty ? 'Открыть товар' : sourceName),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        children: [
          ScreenTitle(
            'Мои луки',
            subtitle: 'Сохранённые результаты примерок',
            trailing: IconButton(
              onPressed: () {
                setState(() => loading = true);
                _load();
              },
              icon: const Icon(Icons.refresh),
            ),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.only(top: 120),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            SectionCard(
              child: Column(
                children: [
                  Text(error!, style: const TextStyle(color: FitColors.danger)),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() => loading = true);
                      _load();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Повторить'),
                  ),
                ],
              ),
            )
          else if (looks.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 110),
              child: Column(
                children: [
                  Icon(Icons.favorite_border, size: 80, color: Colors.white38),
                  SizedBox(height: 14),
                  Text(
                    'Пока нет сохранённых луков',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Сделайте примерку и нажмите «Сохранить»',
                    style: TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: looks.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.58,
              ),
              itemBuilder: (context, index) {
                final look = looks[index];
                final url = look['result_url']?.toString();
                final itemsCount = (look['total_steps'] as num?)?.toInt() ?? 1;
                return Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: FitColors.card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _open(look),
                          child: Container(
                            color: Colors.black,
                            child: url == null
                                ? const SizedBox()
                                : NetImage(url, fit: BoxFit.cover, alignment: Alignment.topCenter),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    look['title']?.toString() ?? 'Образ',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${itemsCount > 1 ? '$itemsCount вещи • ' : ''}'
                                    '${_date(look['created_at']?.toString())}',
                                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _delete(look),
                              icon: const Icon(Icons.delete_outline, size: 20),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
