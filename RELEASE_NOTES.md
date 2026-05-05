## What's Changed

- Fixed keychain entitlement binding for release signing by deriving access groups from `$(PRODUCT_BUNDLE_IDENTIFIER)`.
- Restored stable local app launch for `make run`/`make watch` by keeping dev entitlements compatible with ad-hoc `codesign`.
- Prevented calendar sync regressions after bundle identifier updates by aligning runtime identity and keychain access behavior.
