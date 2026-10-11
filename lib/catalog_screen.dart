import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'common.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.onTryOn});

  /// Adds the item to the outfit on the try-on screen.
  final ValueChanged<CatalogItem> onTryOn;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final ImagePicker picker = ImagePicker();
  bool loading = true;
  bool working = false;
  String? error;
  List<CatalogItem> items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FitMeApi.getCatalog();
      if (!mounted) return;
      setState(() {
        items = result;
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

  Future<void> _addItem() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: FitColors.card,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Добавить вещь',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('По ссылке на товар'),
                subtitle: const Text('FitMe сам найдёт фото товара'),
                onTap: () => Navigator.pop(sheetContext, 'url'),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Из галереи'),
                subtitle: const Text('Выбрать фото одежды'),
                onTap: () => Navigator.pop(sheetContext, 'photo'),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Сфотографировать'),
                subtitle: const Text('Снять вещь камерой'),
                onTap: () => Navigator.pop(sheetContext, 'camera'),
              ),
            ],
          ),
        ),
      ),
    );

    if (mode == null || !mounted) return;
    if (mode == 'url') {
      await _addFromUrl();
    } else {
      await _addFromPhoto(
        mode == 'camera' ? ImageSource.camera : ImageSource.gallery,
      );
    }
  }

  Future<void> _addFromUrl() async {
    final urlCtrl = TextEditingController();
    var category = 'upper_body';
    var garmentType = 'Футболка';

    final urlData = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Добавить по ссылке'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: urlCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Ссылка на товар',
                    hintText: 'https://...',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
                const SizedBox(height: 12),
                CompactGarmentTypeField(
                  label: garmentType,
                  enabled: true,
                  onTap: () async {
                    final selected = await showGarmentTypePicker(
                      context,
                      selectedLabel: garmentType,
                    );
                    if (selected == null) return;
                    setLocal(() {
                      garmentType = selected.label;
                      category = selected.aiCategory;
                    });
                  },
                ),
                const SizedBox(height: 10),
                const Text(
                  'Если магазин не отдаёт фото, добавьте его вручную из галереи.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                if (urlCtrl.text.trim().isEmpty) return;
                Navigator.pop(context, {
                  'url': urlCtrl.text.trim(),
                  'category': category,
                });
              },
              child: const Text('Найти фото'),
            ),
          ],
        ),
      ),
    );
    urlCtrl.dispose();
    if (urlData == null || !mounted) return;

    setState(() => working = true);
    try {
      final item = await FitMeApi.importCatalogItemFromUrl(
        sourceUrl: urlData['url']!,
        category: urlData['category']!,
      );
      await _load();
      if (!mounted) return;
      showMessage(context, 'Добавлено: ${item.name}');
    } catch (e) {
      if (!mounted) return;
      showMessage(context, 'Не удалось взять фото по ссылке: $e');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _addFromPhoto(ImageSource source) async {
    final photo = await picker.pickImage(
      source: source,
      imageQuality: 92,
      maxWidth: 1800,
    );
    if (photo == null || !mounted) return;

    final nameCtrl = TextEditingController();
    final sourceNameCtrl = TextEditingController();
    final sourceUrlCtrl = TextEditingController();
    var category = 'upper_body';
    var garmentType = 'Футболка';

    final data = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Добавить вещь'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Название',
                    hintText: 'Синие джинсы',
                  ),
                ),
                const SizedBox(height: 12),
                CompactGarmentTypeField(
                  label: garmentType,
                  enabled: true,
                  onTap: () async {
                    final selected = await showGarmentTypePicker(
                      context,
                      selectedLabel: garmentType,
                    );
                    if (selected == null) return;
                    setLocal(() {
                      garmentType = selected.label;
                      category = selected.aiCategory;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: sourceNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Магазин (необязательно)',
                    hintText: 'Zara / Wildberries / Kaspi',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: sourceUrlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Ссылка (необязательно)',
                    hintText: 'https://...',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim().isEmpty
                    ? garmentType
                    : nameCtrl.text.trim();
                Navigator.pop(context, {
                  'name': name,
                  'category': category,
                  'description': name,
                  'source_name': sourceNameCtrl.text.trim(),
                  'source_url': sourceUrlCtrl.text.trim(),
                });
              },
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    sourceNameCtrl.dispose();
    sourceUrlCtrl.dispose();
    if (data == null || !mounted) return;

    setState(() => working = true);
    try {
      await FitMeApi.uploadCatalogItem(
        garmentPhoto: photo,
        name: data['name']!,
        category: data['category']!,
        description: data['description']!,
        sourceName: data['source_name'] ?? '',
        sourceUrl: data['source_url'] ?? '',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      showMessage(context, 'Ошибка каталога: $e');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _delete(CatalogItem item) async {
    final ok = await confirmAction(
      context,
      title: 'Удалить «${item.name}»?',
      message: 'Вещь пропадёт из каталога.',
    );
    if (!ok || !mounted) return;
    try {
      await FitMeApi.deleteCatalogItem(item.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showMessage(context, 'Не удалось удалить: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        children: [
          ScreenTitle(
            'Каталог',
            subtitle: 'Ваши вещи — добавляйте в образ одним нажатием',
            trailing: working
                ? const SizedBox(
                    width: 40,
                    height: 40,
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton.filledTonal(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
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
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Column(
                children: [
                  const Icon(Icons.checkroom, size: 80, color: Colors.white38),
                  const SizedBox(height: 18),
                  const Text(
                    'Каталог пуст',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Нажмите + и добавьте фото одежды.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить вещь'),
                  ),
                ],
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.62,
              ),
              itemBuilder: (context, index) => _CatalogTile(
                item: items[index],
                onTryOn: () => widget.onTryOn(items[index]),
                onDelete: () => _delete(items[index]),
              ),
            ),
        ],
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.item,
    required this.onTryOn,
    required this.onDelete,
  });

  final CatalogItem item;
  final VoidCallback onTryOn;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  onTap: () => openZoom(
                    context,
                    NetImage(item.imageUrl, fit: BoxFit.contain),
                    title: item.name,
                  ),
                  child: Container(
                    color: Colors.white,
                    child: NetImage(item.imageUrl, fit: BoxFit.contain),
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: IconButton.filledTonal(
                    visualDensity: VisualDensity.compact,
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  categoryRu(item.category),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const Spacer(),
                if (item.sourceUrl.isNotEmpty)
                  InkWell(
                    onTap: () => openProductSource(context, item.sourceUrl),
                    child: const Icon(
                      Icons.open_in_new,
                      size: 16,
                      color: FitColors.accentSoft,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: FilledButton.icon(
              onPressed: onTryOn,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('В образ'),
            ),
          ),
        ],
      ),
    );
  }
}
