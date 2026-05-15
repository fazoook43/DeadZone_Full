# DeadZone ROM Factory Architecture

DeadZone now has a config-driven architecture layer beside the existing shell kitchen. The current `main.sh` flow remains the production path for zircon builds, fastboot package validation, vbmeta mode handling, PixelDrain upload, Telegram logs, and final ZIP naming.

The new layer is dry-run first:

1. `core/plan_builder.py` reads device, SoC, platform, region, flavor, patch level, and target registries.
2. It writes `output/build_plan.json`.
3. `core/patch_engine.py` resolves targets against an extracted root and writes a patch report.
4. JAR, APK, smali, overlay, and app engines only validate schemas, discover targets, check applicability, and prepare workspaces.

No real framework, services.jar, signature, APK, or smali behavior changes are performed in this phase.

## Top-Level Folders

- `targets/`: logical target registry and candidate paths.
- `platforms/`: HyperOS and MIUI platform profiles.
- `devices/`: YAML device configs beside existing legacy `.conf` files.
- `soc/`: Snapdragon and MediaTek shared rules.
- `regions/`: OTA region mapping and region properties.
- `flavors/`: DeadZone flavor profiles and version-specific operation lists.
- `patchpacks/`: patch schemas, assets, smali folders, overlays, and verification metadata.
- `assets/`: shared static files.
- `manifests/`: future release manifests.
- `docs/`: architecture and contributor docs.

## Dry Run

```bash
python3 core/plan_builder.py \
  --device zircon \
  --rom-url "$ROM_URL" \
  --flavor DeadZone_Gaming \
  --version v1 \
  --platform auto \
  --region auto \
  --patch-level safe \
  --out output/build_plan.json

python3 core/patch_engine.py \
  --plan output/build_plan.json \
  --root output/patch_root \
  --dry-run \
  --report output/logs/deadzone_patch_report.txt
```

## Compatibility Rule

The architecture layer must not change legacy shell behavior until explicitly wired in. Any future integration should keep `SKIP_PATCHES=true` and `PATCH_LEVEL=none` behavior identical.
