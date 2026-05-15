# Framework Patches

Framework patchpacks live under:

- `patchpacks/framework/hyperos3/`
- `patchpacks/framework/hyperos2/`
- `patchpacks/framework/hyperos1/`
- `patchpacks/framework/miui/`

Initial targets:

- `framework_jar`
- `services_jar`
- `miui_framework_jar`
- `miui_services_jar`

`core/jar_patch_engine.py` currently performs:

- target discovery
- schema validation
- applicability checks
- extraction workspace preparation
- dry-run reporting

It intentionally does not perform services.jar behavior changes, signature bypasses, bytecode rewrites, or smali edits.
