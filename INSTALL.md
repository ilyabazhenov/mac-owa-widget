# OWA Widget Installation

Install OWA Widget from the latest GitHub release:

- Latest release: https://github.com/ilyabazhenov/mac-owa-widget/releases/latest

## 1) Download the app archive

1. Open the latest release page.
2. Download the `.zip` asset for macOS.
3. Extract the archive.

## 2) Move app to Applications

Move `OWAWidget.app` to:

`/Applications/OWAWidget.app`

## 3) Remove quarantine attribute (first install only)

If macOS blocks the app on first launch, run:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

## 4) Launch the app

```bash
open /Applications/OWAWidget.app
```

After launch, OWA Widget will appear in the menu bar.

## 5) Future updates (automatic)

OWA Widget uses Sparkle for in-app updates:

- When a new version is available, you'll see an **Install** button in the app.
- Click **Install** and the app downloads, verifies, installs, and relaunches automatically.
- You do **not** need to manually download/unpack each new version anymore.

## If the menu bar icon doesn't appear

The app process may launch but its icon can be hidden by macOS (menu bar overflow on notch displays, third-party utilities, etc.). On every launch OWA Widget writes a diagnostic log to:

```text
~/Library/Application Support/OWAWidget/diagnostic.log
```

Open it directly to see what happened:

```bash
open ~/Library/Application\ Support/OWAWidget/diagnostic.log
```

If you can see the icon, right-click it → **Copy diagnostics** copies the same report to the clipboard. Attach the contents to a bug report.

---

# Установка OWA Widget

Установите OWA Widget из последнего релиза на GitHub:

- Последний релиз: https://github.com/ilyabazhenov/mac-owa-widget/releases/latest

## 1) Скачайте архив приложения

1. Откройте страницу последнего релиза.
2. Скачайте `.zip`-архив для macOS.
3. Распакуйте архив.

## 2) Переместите приложение в Applications

Переместите `OWAWidget.app` в:

`/Applications/OWAWidget.app`

## 3) Уберите quarantine-атрибут (только при первой установке)

Если macOS блокирует приложение при первом запуске, выполните:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

## 4) Запустите приложение

```bash
open /Applications/OWAWidget.app
```

После запуска OWA Widget появится в строке меню.

## 5) Дальнейшие обновления (автоматически)

OWA Widget использует Sparkle для in-app обновлений:

- Когда выйдет новая версия, в приложении появится кнопка **Установить**.
- Нажмите **Установить**, и приложение само скачает обновление, проверит подпись, установит его и перезапустится.
- Вручную скачивать и распаковывать каждый новый релиз больше не нужно.

## Если иконка в строке меню не появилась

Процесс приложения может запуститься, но иконку может скрыть macOS (переполнение строки меню на дисплеях с notch, сторонние утилиты управления menu bar и т. п.). При каждом запуске OWA Widget пишет диагностический лог:

```text
~/Library/Application Support/OWAWidget/diagnostic.log
```

Откройте файл напрямую:

```bash
open ~/Library/Application\ Support/OWAWidget/diagnostic.log
```

Если иконка всё-таки видна — правый клик по ней → **Скопировать диагностику** кладёт тот же отчёт в буфер обмена. Приложите содержимое к багрепорту.
