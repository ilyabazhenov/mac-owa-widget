## What's Changed

- Switched the production bundle identifier to `com.owawidget.MacOwaWidget` for proper reverse-DNS semantics and improved LaunchServices compatibility.
- Synced bundle identifier configuration across `Info.plist`, `Makefile`, and `project.yml` so local packaging and generated Xcode projects use the same app identity.
- Kept local development launch flow isolated via `.dev` suffix while preserving stable release packaging behavior.
