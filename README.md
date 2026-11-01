# Void Linux ARM64 for HP Chromebook 11a-na0010nr (`kappa`)

This repository assembles a Void Linux **aarch64/glibc + runit** root filesystem in GitHub Actions and pairs it with Hexdump's prebuilt MediaTek Chromebook kernel release. The workflow runs on a native GitHub-hosted ARM64 runner; no ROOTFS build or kernel compilation happens on the Chromebook.

## What it produces

A manual `workflow_dispatch` run publishes an Actions artifact containing:

- `void-kappa-rootfs.tar.zst` — root filesystem payload for an ext4 root partition; **not** a raw disk image.
- `kernelB.vboot` — Hexdump FIT repacked for ChromeOS KernelB (partition 2) to boot the selected root PARTUUID (normally `mmcblk0p4`).
- `SHA256SUMS`, `manifest.json`, `kernel-command-line.txt`, and the XBPS package manifest.

## Pinned inputs

| Input | Value |
|---|---|
| Board / SoC | `kappa` / MT8183 |
| Void ROOTFS | `void-aarch64-ROOTFS-20250202.tar.xz` (official mirror; refreshed through current XBPS repositories during build) |
| ROOTFS SHA-256 | `01a30f17ae06d4d5b322cd579ca971bc479e02cc284ec1e5a4255bea6bac3ce6` |
| Hexdump kernel | `6.18.34-stb-cbm+` |
| Kernel archive SHA-256 | `d8c4bbde8eb206145aa53733d2ab2d0f985b7b983b9151a5f0543ffe0d5c83ad` |
| Hyprland packages | Void Community Repository (VUR), AArch64 (`repo.osowoso.org/aarch64`) — currently 0.56.2 in the checked index |
| Noctalia source | upstream v5.4.1 release, SHA-256 pinned and built on ARM64 Actions runner |

The Hexdump release archive is downloaded from its published release asset, not built from source. Its `vmlinux.kpart` is verified, repacked with the Ubuntu `vboot-kernel-utils` development keys, and checked to contain the `mt8183-kukui-jacuzzi-kappa` DTB. The command line uses a direct PARTUUID rather than the generic Hexdump `PARTNROFF` default, preventing an off-by-one root partition when booting from KernelB.

## Important trust boundary

Hyprland and its related packages are fetched from **VUR, an independent third-party Void community repository**, not the official Void repositories. Noctalia is built from its pinned upstream v5.4.1 source release on the ARM64 Actions runner. Review its maintainer, package metadata and signing-key fingerprint before accepting it. The workflow refuses to run unless `accept_vur_repo=true` is explicitly selected in `workflow_dispatch`; `xbps-install` then accepts the repository key inside the disposable build environment. The public repo should not contain passwords, SSH keys, personal configuration files or secrets.

The upstream Void ARM64 ROOTFS is an older bootstrap snapshot; the workflow updates XBPS and installs packages from the current Void repositories. This is not a reproducible snapshot of every package: `manifest.json` and `xbps-installed-packages.txt` record the exact package versions resolved at build time. Kernel and ROOTFS input archives are SHA-256 pinned.

## Build in GitHub

1. Create a **public** empty GitHub repository (for example `void-kappa`).
2. Push this project to its default branch, including `.github/workflows/build.yml`.
3. Open **Actions → Build Void Linux for HP Chromebook 11a-na0010nr (kappa) → Run workflow**.
4. Leave `root_partuuid` as `94cc72f9-f583-4146-b033-54fda2decd89` for the current main Chromebook layout (`mmcblk0p4`), unless you have re-created the partition table.
5. Select `accept_vur_repo=true` only after reviewing the VUR repository. The repo is third-party.
6. Wait for every workflow step to succeed, then download the `void-kappa-N` artifact. Keep the artifact and `SHA256SUMS` together.

The workflow uses `ubuntu-24.04-arm`, so the aarch64 rootfs and its package operations run natively on ARM64. It does not emulate a Chromebook boot and does not flash any disk.

## Before installing to the eMMC

**Do not run a destructive install until you have copied all files off the current Fedora eMMC.** In particular, the current backup at `/home/fede/respaldo-hypr-noctalia/hypr/` is inside the current root filesystem and will be lost when that partition is formatted. Copy it to another computer, external drive or the Fedora test Chromebook first. Do not upload personal configuration to this public repository.

Read [`docs/INSTALL.md`](docs/INSTALL.md) completely before extracting the rootfs or writing KernelB. The main Chromebook must remain in Developer Mode. Keep the Fedora test Chromebook and a working recovery microSD available.

## Known limitations

- The workflow creates a rootfs payload and a KernelB image; it is not a full ChromeOS recovery image and does not change GPT attributes.
- The rootfs contains a minimal starter Hyprland configuration. Restore the user's own Hyprland config from a separate backup after the first successful boot.
- Noctalia v5 is installed fresh. The old Noctalia v4 Lua configuration is retained as a backup only; v4 settings are not automatically migrated into v5.
- The `kappa-audio-fix` helper re-enables the two ALSA mixer routes that were required for the MT8183 internal speakers (`I2S3_CH1 DL1_CH1` and `I2S3_CH2 DL1_CH2`).
- The current Hexdump kernel has no working zram module in the tested Fedora setup. This image does not configure zram; the install guide uses an optional 1 GiB swapfile.
- This workflow scaffold has not yet completed a real GitHub Actions run or a Void first boot on the Chromebook. Treat the first build as a staging artifact; validate it before replacing Fedora.
