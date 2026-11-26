# Сторонние компоненты

- pdf-lib 1.17.1, MIT. Источник `https://unpkg.com/pdf-lib@1.17.1/dist/pdf-lib.min.js`, лицензия в `pdf-lib-LICENSE`.
- @pdf-lib/fontkit 1.1.1, MIT. Источник `https://unpkg.com/@pdf-lib/fontkit@1.1.1/dist/fontkit.umd.min.js`, исходный README с указанием MIT в `fontkit-README.md`.
- Noto Sans Regular, SIL Open Font License 1.1. Источник `https://github.com/notofonts/noto-fonts/blob/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf`, лицензия в `NotoSans-LICENSE`.

Эти файлы обслуживаются вместе с приложением. Сторонний CDN не используется для генерации PDF.

## Справочник автомобилей

Названия, русские варианты написания и страны марок взяты из базового файла [carsBase](https://github.com/blanzh/carsBase/blob/master/cars.json) 26.11.2026. SHA-256 исходного JSON `a0a564020a8f38ad1ec5d37079d93cdc092a12c26445d26fb8a0f48f60373943`. Для обновления скачайте cars.json и выполните `python3 tools/import-vehicle-catalog.py путь/к/cars.json`.
