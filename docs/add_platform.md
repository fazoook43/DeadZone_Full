# Add A Platform

1. Add `platforms/<platform>.yml`.
2. Set `id`, `name`, `families`, `android_api`, `patchpacks`, and `target_groups`.
3. Add a framework patchpack folder under `patchpacks/framework/<platform>/`.
4. Register any new framework, app, overlay, or prop targets in `targets/`.
5. Update platform detection in `core/plan_builder.py` if OTA naming cannot be inferred from existing patterns.

Platform configs should select patchpacks, not hardcode target paths.
