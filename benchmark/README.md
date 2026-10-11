# Сравнение моделей примерки

Скрипты, чтобы бесплатно сравнить модели виртуальной примерки на одних и тех же фото.

| Файл | Что делает |
|---|---|
| `bench_spaces.py` | Прогоняет FASHN, IDM-VTON, Leffa, FitDiT, OOTDiffusion через бесплатные Hugging Face Spaces (свой GPU не нужен) |
| `evaluate.py` | Автоматическая оценка: точность цвета вещи (ΔE), сохранность лица и фона (SSIM) |
| `FitMe_Model_Benchmark_Kaggle.ipynb` | Всё вместе на Kaggle + FASHN локально на GPU с разными настройками |
| `run_bench.bat` | Запуск `bench_spaces.py` на Windows в один клик |

## Быстрый старт (на компьютере, без GPU)
1. Получите бесплатный токен: huggingface.co → Settings → Access Tokens → New token (тип Read).
2. Запустите `run_bench.bat` и вставьте токен, когда скрипт попросит.
3. Готовые сравнительные картинки появятся в `results/grids/`, а лог — в `results/results.csv`.

Квота бесплатного GPU у Hugging Face (ZeroGPU) считается в минутах в день. Когда она кончается, скрипт останавливается.
Если запустить его на следующий день, он продолжит с того же места: готовые результаты не пересчитываются.

## Свои фото (важно для честного теста)
Положите фото в `test_set/` и опишите пары в `test_set/pairs.csv`:
```
person,garment,category
me/front.jpg,shop/hoodie.jpg,upper_body
me/front.jpg,shop/jeans.jpg,lower_body
```
Категории: `upper_body`, `lower_body`, `dresses`.
Возьмите 5–10 разных людей (снимки на телефон, разные позы и фоны) и 10–15 вещей, в том числе сложных: принт, блёстки, полосы, платье, джинсы.
Демо-набор (VITON-HD) даёт преимущество моделям, которые на нём обучались, поэтому итоговые выводы делайте по своим фото.

## Ручная оценка
`results/ratings.csv`: поставьте оценки от 1 до 5 по четырём критериям: вещь похожа, человек узнаваем, реализм, посадка.
Автоматические метрики не заменяют человеческий глаз.

## Модели и лицензии
| Модель | Space | Лицензия | Коммерция |
|---|---|---|---|
| FASHN VTON 1.5 | fashn-ai/fashn-vton-1.5 | Apache-2.0 | да |
| IDM-VTON | yisol/IDM-VTON | CC BY-NC-SA 4.0 | нет |
| Leffa | franciszzj/Leffa | MIT (+ условия датасетов) | проверить |
| FitDiT | BoyuanJiang/FitDiT | CC BY-NC-SA 4.0 | нет |
| OOTDiffusion | levihsu/OOTDiffusion | CC BY-NC-SA 4.0 | нет |
