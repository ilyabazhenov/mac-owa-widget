# OWA Widget Installation

Install OWA Widget from the latest GitHub release:

- Latest release: https://github.com/ilyabazhenov/mac-owa-widget/releases/tag/v1.0.26

## 1) Download the app archive

1. Open the latest release page.
2. Download the `.zip` asset for macOS.
3. Extract the archive.

## 2) Move app to Applications

Move `OWAWidget.app` to:

`/Applications/OWAWidget.app`

## 3) Remove quarantine attribute

If macOS blocks the app on first launch, run:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

## 4) Launch the app

```bash
open /Applications/OWAWidget.app
```

After launch, OWA Widget will appear in the menu bar.

---

# Установка OWA Widget

Установите OWA Widget из последнего релиза на GitHub:

- Последний релиз: https://github.com/ilyabazhenov/mac-owa-widget/releases/tag/v1.0.26

## 1) Скачайте архив приложения

1. Откройте страницу последнего релиза.
2. Скачайте `.zip`-архив для macOS.
3. Распакуйте архив.

## 2) Переместите приложение в Applications

Переместите `OWAWidget.app` в:

`/Applications/OWAWidget.app`

## 3) Уберите quarantine-атрибут

Если macOS блокирует приложение при первом запуске, выполните:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

## 4) Запустите приложение

```bash
open /Applications/OWAWidget.app
```

После запуска OWA Widget появится в строке меню.
