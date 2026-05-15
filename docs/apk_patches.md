# APK Patches

APK patchpacks live under:

- `patchpacks/settings/`
- `patchpacks/systemui/`
- `patchpacks/powerkeeper/`
- `patchpacks/apps/`

Initial APK targets:

- `powerkeeper_apk`
- `settings_apk`
- `miui_systemui_apk`

`core/apk_patch_engine.py` and `core/smali_patch_engine.py` currently perform discovery, schema validation, applicability checks, workspace preparation, and dry-run reports only.

Real APK decompile/recompile, signing, resource edits, and smali mutations must be added in a later phase with explicit verification and rollback rules.
