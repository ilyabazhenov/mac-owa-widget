## What's Changed

- Added customizable in-app reminder sound selection in Preferences with instant preview.
- Added localized sound descriptions (RU/EN) and updated default in-app reminder sound to `Submarine`.
- Kept Notification Center sound behavior unchanged; customization applies only to in-app floating reminders.

## Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```
