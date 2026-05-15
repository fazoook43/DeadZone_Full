# DeadZone ROM Kitchen

DeadZone builds Xiaomi/HyperOS payload OTAs into flashable fastboot packages. The first official test target is `zircon`.

## First Zircon Test Build

Run the GitHub Actions workflow manually with:

- `rom_url`: `https://bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com/OS3.0.303.0.WNOCNXM/zircon-ota_full-OS3.0.303.0.WNOCNXM-user-16.0-09c35a83d6.zip`
- `device_codename`: `zircon`
- `build_name`: `DeadZone_v1`
- `output_type`: `fastboot_zip`
- `fs_mode`: `erofs`
- `vbmeta_mode`: `3`
- `patch_level`: `none`
- `upload_pixeldrain`: `true`
- `notify_telegram`: `true`
- `create_github_release`: `true`

The expected release asset is:

`DeadZone_v1_zircon_fastboot.zip`

The release title/tag uses:

`DeadZone_v1 zircon OS3.0.303.0.WNOCNXM`

## Required Secrets

Configure these GitHub repository secrets for full release uploads:

- `PIXELDRAIN_API_KEY`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

The workflow uses the built-in `GITHUB_TOKEN` for GitHub Releases and has `contents: write` permissions.

Optional future secret:

- `GOFILE_TOKEN`

GoFile upload is not required for the first version.

## Workflow Inputs

- `rom_url`: OTA ZIP or payload URL.
- `device_codename`: Loads `devices/<codename>.conf`.
- `build_name`: Prefix used for output ZIP names and release tags.
- `output_type`: `super_zst`, `fastboot_zip`, or `full_release`.
- `fs_mode`: `preserve` or `erofs`. Current stock EROFS images are preserved.
- `vbmeta_mode`: `0` no patch, `1` disable dm-verity, `2` disable verification, `3` disable both.
- `patch_level`: Keep `none` for the first boot test.
- `upload_pixeldrain`: Uploads the final fastboot ZIP when `PIXELDRAIN_API_KEY` exists.
- `notify_telegram`: Sends a completion message when Telegram secrets exist.
- `create_github_release`: Creates or updates the GitHub Release.

## Output

`fastboot_zip` and `full_release` generate:

- `output_final/DeadZone_v1_zircon_fastboot.zip`
- `images/super.img` inside the ZIP
- Windows flash scripts
- Linux `flash_all.sh`
- `build_info.txt`
- `sha256sums.txt`
- `DeadZone_v1_zircon_fastboot.zip.sha256`
- build logs

`super_zst` still generates:

- `output/super.img.zst`
- `output/images/super.img`

## Safety Notes

The first build should use `patch_level=none`. Test boot first before enabling debloat, app replacement, framework patches, or property changes.

Never lock the bootloader from this package. The generated scripts do not include `fastboot flashing lock`, `fastboot oem lock`, or automatic bootloader locking.

Current placeholder folders for future work:

- `patches/`
- `replace_apps/`
- `add_apps/`
- `debloat/`
- `props/`
