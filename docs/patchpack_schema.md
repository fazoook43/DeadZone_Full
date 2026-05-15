# Patchpack Schema

Every patchpack should include:

- `patch.yml`
- `verify.yml`
- `README.md`
- `files/`
- `smali/`
- `overlays/`

Required `patch.yml` fields:

```yaml
id: unique_patchpack_id
name: Human readable name
type: framework|apk|smali|prop|overlay|app|structural
platforms:
  - hyperos3
flavors:
  - DeadZone_Gaming_V1
android_api:
  min: 35
  max: 36
targets:
  - framework_jar
operations:
  - op: jar_patch
only_if: []
skip_if: []
requires_path: []
verify:
  - target_discovery
rollback_notes: Explain how to revert or why no mutation happens.
```

Supported initial operations:

- `remove_path`
- `search_remove_app`
- `move_path`
- `copy_file`
- `copy_tree`
- `set_prop`
- `delete_prop`
- `append_prop_once`
- `replace_xml_bool`
- `remove_oat`
- `inject_app`
- `replace_app`
- `overlay`
- `jar_patch`
- `apk_patch`
- `smali_patch`

In this phase, mutation-oriented operations are dry-run only.
