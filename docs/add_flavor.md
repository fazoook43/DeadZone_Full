# Add A Flavor

1. Add `flavors/<Flavor>_<Version>.yml`.
2. Include aliases if CLI input should be shorter than the full ID.
3. Define patchpack groups per patch level.
4. Add only flavor-specific operations in the flavor config.
5. Keep platform-specific behavior in platform configs or patchpacks.

Current initial flavors:

- `DeadZone_Gaming_V1`
- `DeadZone_EPiC_V1`
- `DeadZone_Legend_V1`
