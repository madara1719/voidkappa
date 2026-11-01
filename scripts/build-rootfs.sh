#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_PARTUUID="${ROOT_PARTUUID:?ROOT_PARTUUID must be supplied}"
VOID_ROOTFS_URL="${VOID_ROOTFS_URL:-https://repo-fastly.voidlinux.org/live/current/void-aarch64-ROOTFS-20250202.tar.xz}" 
VOID_ROOTFS_SHA256="${VOID_ROOTFS_SHA256:-01a30f17ae06d4d5b322cd579ca971bc479e02cc284ec1e5a4255bea6bac3ce6}"
HEXDUMP_RELEASE="${HEXDUMP_RELEASE:-6.18.34-stb-cbm+}"
HEXDUMP_KERNEL_SHA256="${HEXDUMP_KERNEL_SHA256:-d8c4bbde8eb206145aa53733d2ab2d0f985b7b983b9151a5f0543ffe0d5c83ad}"
VUR_REPOSITORY="${VUR_REPOSITORY:-https://repo.osowoso.org/aarch64}"
NOCTALIA_VERSION="${NOCTALIA_VERSION:-5.4.1}"
NOCTALIA_SOURCE_SHA256="${NOCTALIA_SOURCE_SHA256:-46fe42df052b4cee4be0b8681936d3a5db05be9df04964fbface0694f0f67cf7}"
WORK="${GITHUB_WORKSPACE:-$PWD}/work"
ROOTFS="$WORK/rootfs"
KSTAGE="$WORK/kernel"
OUT="$WORK/out"

mkdir -p "$ROOTFS" "$KSTAGE" "$OUT"

cleanup_mounts() {
  set +e
  for d in run sys proc dev/pts dev; do
    mountpoint -q "$ROOTFS/$d" && umount -lf "$ROOTFS/$d"
  done
}
trap cleanup_mounts EXIT

# Fail closed: do not let a workflow silently accept an unreviewed community repo.
if [[ "${ACCEPT_VUR_REPO:-false}" != "true" ]]; then
  echo 'VUR acceptance was not explicitly enabled in workflow_dispatch.' >&2
  exit 1
fi

# Re-check downloaded artifacts before extracting them.
echo "$VOID_ROOTFS_SHA256  $WORK/downloads/void-rootfs.tar.xz" | sha256sum --check --strict
echo "$HEXDUMP_KERNEL_SHA256  $WORK/downloads/hexdump-kernel.tar.gz" | sha256sum --check --strict
echo "$NOCTALIA_SOURCE_SHA256  $WORK/downloads/noctalia.tar.gz" | sha256sum --check --strict

echo '== Extracting Void aarch64 glibc ROOTFS =='
tar -xJf "$WORK/downloads/void-rootfs.tar.xz" -C "$ROOTFS" --numeric-owner
# Ensure required rootfs directories exist.
for dir in \
  "$ROOTFS/etc/xbps.d" \
  "$ROOTFS/var/service" \
  "$ROOTFS/etc/skel/.config/hypr" \
  "$ROOTFS/usr/local/bin" \
  "$ROOTFS/var/db/xbps/keys"
do
  if [[ -L "$dir" || -f "$dir" ]]; then
    rm -f "$dir"
  fi
  mkdir -p "$dir"
done
# Void ROOTFS is a bootstrap environment, not a complete desktop. Update XBPS
# and install only the packages required for this Chromebook profile.
# Ensure runit service directory exists as a real directory.
if [[ -L "$ROOTFS/var/service" || -f "$ROOTFS/var/service" ]]; then
  rm -f "$ROOTFS/var/service"
fi

printf 'repository=%s\n' "$VUR_REPOSITORY" > "$ROOTFS/etc/xbps.d/20-vur.conf"

# Download the VUR public signing key from its documented upstream sources.
VUR_KEY="$WORK/oco-repo-key.plist"

if ! curl -fL --retry 3 \
  "https://codeberg.org/oSoWoSo/oco/raw/branch/OCO/oco-repo-key.plist" \
  -o "$VUR_KEY"; then
  curl -fL --retry 3 \
    "https://raw.githubusercontent.com/oSoWoSo/oco/OCO/oco-repo-key.plist" \
    -o "$VUR_KEY"
fi

mkdir -p "$ROOTFS/var/db/xbps/keys"

install -m 0644 "$VUR_KEY" \
  "$ROOTFS/var/db/xbps/keys/df:ec:10:ef:5c:03:e9:e0:86:77:08:c2:b5:a8:cb.plist"
  
# Provide DNS and the kernel interfaces required by XBPS package installation.
install -D -m 0644 /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
for d in dev dev/pts proc sys run; do mkdir -p "$ROOTFS/$d"; done
mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
mount --bind /run "$ROOTFS/run"

chroot "$ROOTFS" /bin/sh -euc ' 
  echo "== Checking fish package availability =="
  xbps-query -Rs '^fish$' || true
  export PATH=/usr/bin:/usr/sbin:/bin:/sbin
  xbps-install -Suy xbps
  # Refresh the 2025 bootstrap ROOTFS against current official Void repositories.
  xbps-install -Suy
  xbps-install -Suy base-system
  # VUR is an independent, third-party ARM64 repository. The workflow_dispatch
  # acknowledgement is the operator consent to trust its XBPS signing key.
  xbps-install -Suy \
    NetworkManager wpa_supplicant dbus bluez elogind seatd polkit \
    pipewire wireplumber alsa-utils alsa-ucm-conf linux-firmware \
    mesa-dri xorg-server-xwayland xdg-desktop-portal \
    foot sudo shadow git curl zstd tar \
    xdg-user-dirs wl-clipboard grim slurp playerctl brightnessctl \
    pavucontrol fastfetch \
    hyprland hyprlock hyprpaper hyprpicker hyprpolkitagent \
    xdg-desktop-portal-hyprland \
    gcc make just meson ninja pkgconf \
    wayland-devel wayland-protocols libepoxy-devel MesaLib-devel \
    libglvnd-devel cairo-devel pango-devel fontconfig-devel freetype-devel \
    harfbuzz-devel libxkbcommon-devel pipewire-devel wireplumber-devel \
    libsecret-devel libsodium-devel libcurl-devel pam-devel libwebp-devel \
    libjxl-devel libsndfile-devel basu-devel sdbus-c++-devel polkit-devel \
    libqalculate-devel librsvg-devel libxml2-devel libmd4c-devel \
    tomlplusplus-devel libical-devel json-c++ stb jemalloc-devel
'

# Build Noctalia from its pinned upstream source release on the native ARM64 runner.
mkdir -p "$ROOTFS/tmp/noctalia-src"
tar -xzf "$WORK/downloads/noctalia.tar.gz" -C "$ROOTFS/tmp/noctalia-src" --strip-components=1
chroot "$ROOTFS" /bin/sh -euc '
  cd /tmp/noctalia-src
  just configure release /usr
  just build release
  just install release
'
rm -rf "$ROOTFS/tmp/noctalia-src" "$ROOTFS/tmp/build-release"

# Create the local account with no embedded password. The installer guide tells
# the owner to set the password before first boot. No personal data enters GitHub.
chroot "$ROOTFS" /bin/sh -euc '
  getent group wheel >/dev/null 2>&1 || groupadd wheel
  getent group video >/dev/null 2>&1 || groupadd video
  getent group audio >/dev/null 2>&1 || groupadd audio
  getent group input >/dev/null 2>&1 || groupadd input
  getent group seat >/dev/null 2>&1 || groupadd seat
  if ! id fede >/dev/null 2>&1; then
    useradd --create-home --user-group --shell /bin/bash \
      --groups wheel,video,audio,input,seat fede
  fi
  install -d -m 0750 /etc/sudoers.d
  printf "%%wheel ALL=(ALL:ALL) ALL\\n" > /etc/sudoers.d/10-wheel
  chmod 0440 /etc/sudoers.d/10-wheel
  passwd -l fede >/dev/null 2>&1 || true
'

if [[ ! -d "$ROOTFS/var/service" ]]; then
  echo "ERROR: runit service directory is missing or invalid." >&2
  ls -ld "$ROOTFS/var" "$ROOTFS/var/service" 2>/dev/null || true
  exit 1
fi
for service in dbus NetworkManager bluetoothd elogind seatd; do
  if [[ -d "$ROOTFS/etc/sv/$service" ]]; then
    ln -sfn "/etc/sv/$service" "$ROOTFS/var/service/$service"
  fi
done

printf 'hp-11a\n' > "$ROOTFS/etc/hostname"
printf 'PARTUUID=%s / ext4 defaults,noatime 0 1\n/swapfile none swap defaults 0 0\n' \
  "$ROOT_PARTUUID" > "$ROOTFS/etc/fstab"

# Keep the known MT8183 MAX98357 speaker-route fix available. It is idempotent
# and is called from the default Hyprland session rather than changing mixer
# state while the rootfs is being assembled.
cat > "$ROOTFS/usr/local/bin/kappa-audio-fix" <<'AUDIO'
#!/bin/sh
set -eu
amixer -c 0 sset 'I2S3_CH1 DL1_CH1' on
amixer -c 0 sset 'I2S3_CH2 DL1_CH2' on
AUDIO
chmod 0755 "$ROOTFS/usr/local/bin/kappa-audio-fix"

# Minimal starter config. The owner's backed-up Hyprland config should be
# restored separately after deployment; do not commit personal config here.
cat > "$ROOTFS/etc/skel/.config/hypr/hyprland.conf" <<'HYPR'
$mainMod = SUPER
monitor = , preferred, auto, 1
exec-once = kappa-audio-fix
exec-once = pipewire
exec-once = wireplumber
exec-once = pipewire-pulse
exec-once = hyprpolkitagent
exec-once = noctalia
bind = $mainMod, RETURN, exec, foot
bind = $mainMod, Q, killactive
bind = $mainMod SHIFT, E, exit
HYPR
FEDE_UID="$(chroot "$ROOTFS" id -u fede)"
FEDE_GID="$(chroot "$ROOTFS" id -g fede)"
chown -R "$FEDE_UID:$FEDE_GID" "$ROOTFS/home/fede/.config" 2>/dev/null || true
if [[ ! -e "$ROOTFS/home/fede/.config/hypr/hyprland.conf" ]]; then
  install -D -m 0644 "$ROOTFS/etc/skel/.config/hypr/hyprland.conf" \
    "$ROOTFS/home/fede/.config/hypr/hyprland.conf"
fi

# No zram configuration is installed: this Hexdump kernel release may not
# expose zram. The install guide creates a 1 GiB ext4-root swapfile.
rm -f "$ROOTFS/etc/xbps.d/30-zram.conf" "$ROOTFS/etc/udev/rules.d/99-zram.rules"

# Extract kernel release payload from Hexdump's official tarball.
tar -xzf "$WORK/downloads/hexdump-kernel.tar.gz" -C "$KSTAGE"
KPART="$(find "$KSTAGE" -type f -name "vmlinux.kpart-${HEXDUMP_RELEASE}" -print -quit)"
MODULES_SRC="$(find "$KSTAGE" -type d -path "*/lib/modules/${HEXDUMP_RELEASE}" -print -quit)"
if [[ -z "$KPART" || -z "$MODULES_SRC" ]]; then
  echo "Could not locate vmlinux.kpart or lib/modules/${HEXDUMP_RELEASE} in Hexdump archive." >&2
  find "$KSTAGE" -maxdepth 5 -print | head -200
  exit 1
fi

mkdir -p "$ROOTFS/usr/lib/modules/$HEXDUMP_RELEASE"
cp -a "$MODULES_SRC/." "$ROOTFS/usr/lib/modules/$HEXDUMP_RELEASE/"

# First verify upstream image, then repack it for KernelB (p2) -> root p4.
# Direct PARTUUID avoids the off-by-one risk of the generic Hexdump PARTNROFF.
cat > "$WORK/kernelB.cmdline" <<CMDLINE
cros_secure console=tty1 root=PARTUUID=${ROOT_PARTUUID} rootwait rw net.ifnames=0 noresume quiet loglevel=3 vt.global_cursor_default=0 modprobe.blacklist=onboard_usb_dev
CMDLINE
vbutil_kernel --verify "$KPART" --verbose
vbutil_kernel --repack "$OUT/kernelB.vboot" \
  --oldblob "$KPART" \
  --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
  --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
  --config "$WORK/kernelB.cmdline"
vbutil_kernel --verify "$OUT/kernelB.vboot" --verbose

# Validate that the packaged FIT still contains the exact kappa DTB.
vbutil_kernel --get-vmlinuz "$OUT/kernelB.vboot" --vmlinuz-out "$WORK/kernelB.fit"
dumpimage -l "$WORK/kernelB.fit" > "$WORK/fit-list.txt" || true
grep -F 'mt8183-kukui-jacuzzi-kappa' "$WORK/fit-list.txt" >/dev/null || {
  cat "$WORK/fit-list.txt"
  echo 'The FIT does not contain the kappa DTB; refusing to publish.' >&2
  exit 1
}
grep -F "root=PARTUUID=${ROOT_PARTUUID}" "$WORK/kernelB.cmdline" >/dev/null
grep -F 'modprobe.blacklist=onboard_usb_dev' "$WORK/kernelB.cmdline" >/dev/null

# Keep a record of exact package versions chosen by the live XBPS repositories.
chroot "$ROOTFS" xbps-query -l | sort > "$OUT/xbps-installed-packages.txt"
cp "$WORK/kernelB.cmdline" "$OUT/kernel-command-line.txt"

# Rootfs tarball is a filesystem payload, not a disk image and not directly flashable.
tar --numeric-owner --xattrs --acls --zstd -C "$ROOTFS" \
  -cf "$OUT/void-kappa-rootfs.tar.zst" .

cat > "$OUT/manifest.json" <<JSON
{
  "device": "HP Chromebook 11a-na0010nr",
  "board": "kappa",
  "soc": "MediaTek MT8183",
  "architecture": "aarch64-glibc",
  "init": "runit",
  "root_partuuid": "${ROOT_PARTUUID}",
  "kernel_release": "${HEXDUMP_RELEASE}",
  "kernel_source": "hexdump0815/linux-mainline-mediatek-mt81xx-kernel",
  "kernel_archive_sha256": "${HEXDUMP_KERNEL_SHA256}",
  "void_rootfs_sha256": "${VOID_ROOTFS_SHA256}",
  "noctalia_version": "${NOCTALIA_VERSION}",
  "noctalia_source_sha256": "${NOCTALIA_SOURCE_SHA256}",
  "hyprland_repository": "${VUR_REPOSITORY}",
  "notes": [
    "Hyprland and Noctalia are installed from a third-party AArch64 Void community repository.",
    "Noctalia is built from its pinned upstream source release on the ARM64 runner.",
    "The FIT is repacked for KernelB p2 to root p4 using the supplied PARTUUID.",
    "The rootfs tarball must be extracted onto an ext4 filesystem; it is not a disk image.",
    "No personal Hyprland or Noctalia configuration is embedded."
  ]
}
JSON

(
  cd "$OUT"
  sha256sum void-kappa-rootfs.tar.zst kernelB.vboot xbps-installed-packages.txt kernel-command-line.txt manifest.json > SHA256SUMS
)

# Unmount chroot bind mounts before the workflow runner archives any data.
cleanup_mounts
trap - EXIT

echo 'Build complete:'
ls -lh "$OUT"
