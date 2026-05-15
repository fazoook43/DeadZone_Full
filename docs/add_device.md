# Add A Device

1. Keep the existing shell `.conf` file if the device uses the legacy build flow.
2. Add `devices/<codename>.yml`.
3. Set `soc`, `default_platform`, `default_region`, dynamic partition names, and quirks.
4. Add SoC defaults in `soc/` if the device family is new.
5. Run `core/plan_builder.py` with the device and inspect `output/build_plan.json`.
6. Run `core/patch_engine.py --dry-run` against an extracted root and inspect target resolution.

Do not delete working legacy profiles while migrating a device.
