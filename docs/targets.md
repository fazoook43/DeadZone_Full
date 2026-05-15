# Target Registry

Targets are logical IDs mapped to candidate paths. Patchpacks reference target IDs, never hardcoded filesystem paths.

Example:

```yaml
- id: settings_apk
  type: apk
  partition: system_ext
  candidate_paths:
    - system_ext/priv-app/Settings/Settings.apk
    - priv-app/Settings/Settings.apk
```

The resolver tests candidates in order under the extracted root and records the first match. Missing targets are non-fatal during dry-run reports so a single patchpack can support multiple layouts.

Initial registries:

- `targets/framework_targets.yml`
- `targets/app_targets.yml`
- `targets/overlay_targets.yml`
- `targets/prop_targets.yml`

Add new targets when a patch needs a logical destination or source that may move across platforms, regions, or device families.
