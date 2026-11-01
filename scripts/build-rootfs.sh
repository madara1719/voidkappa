#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_PARTUUID="${ROOT_PARTUUID:?ROOT_PARTUUID must be supplied}"

VOID_ROOTFS_URL="${VOID_ROOTFS_URL:-https://repo-fastly.voidlinux.org/live/current/void-aarch64-ROOTFS-20250202.tar.xz}"
VOID_ROOTFS_SHA256="${VOID_ROOTFS_SHA256:-01a30f17ae06d4d5b322cd579ca971bc479e02cc284ec1e5a4255bea6bac3ce6}"

HEXDUMP_RELEASE="${HEXDUMP_RELEASE:-6.18.34-stb-cbm+}"
HEXDUMP_KERNEL_SHA256="${HEXDUMP_KERNEL_SHA256:-d8c4bbde8eb206145aa53733d2ab2d0f985b7b983b9151a5f0543ffe0d5c83ad}"

VUR_REPOSITORY="${VUR_REPOSITORY:-https://repo.osowoso.org/aarch64}"

# Exact RSA fingerprint published by the VUR repository.
VUR_KEY_FINGERPRINT="df:ec:10:ef:5c:03:e9:e0:9e:86:77:08:c2:b5:a8:cb"

# ---------------------------------------------------------------------------
# Third-party Hyprland repository (Sofijacom), independent from VUR.
# It has its own RSA key and requires its own explicit acceptance.
#
# The public key file (*.plist) is published in the "Public repo-key" section
# of the repository documentation. Provide:
#   HYPRLAND_KEY_URL     - raw URL of that .plist
#   HYPRLAND_KEY_SHA256  - sha256 of the .plist you reviewed yourself
# The build fails if either is missing or the hash does not match, so the
# key is pinned by content and not trusted just because it was downloaded.
# ---------------------------------------------------------------------------
HYPRLAND_REPOSITORY="${HYPRLAND_REPOSITORY:-https://raw.githubusercontent.com/sofijacom/hyprland-void/repository-aarch64-glibc}"
HYPRLAND_KEY_FINGERPRINT="b3:21:c4:43:d9:38:6f:ec:36:64:0d:65:37:13:c1:fe"
HYPRLAND_KEY_URL="${HYPRLAND_KEY_URL:?HYPRLAND_KEY_URL must be supplied (raw URL of the repo public key .plist)}"
HYPRLAND_KEY_SHA256="${HYPRLAND_KEY_SHA256:?HYPRLAND_KEY_SHA256 must be supplied (sha256 of the reviewed key file)}"

NOCTALIA_VERSION="${NOCTALIA_VERSION:-5.4.1}"
NOCTALIA_SOURCE_SHA256="${NOCTALIA_SOURCE_SHA256:-46fe42df052b4cee4be0b8681936d3a5db05be9df04964fbface0694f0f67cf7}"

WORK="${GITHUB_WORKSPACE:-$PWD}/work"
ROOTFS="$WORK/rootfs"
KSTAGE="$WORK/kernel"
OUT="$WORK/out"
DOWNLOADS="$WORK/downloads"

VUR_KEY="$WORK/oco-repo-key.plist"
VUR_KEY_PATH="$ROOTFS/var/db/xbps/keys/${VUR_KEY_FINGERPRINT}.plist"

HYPRLAND_KEY="$WORK/hyprland-void-repo-key.plist"
HYPRLAND_KEY_PATH="$ROOTFS/var/db/xbps/keys/${HYPRLAND_KEY_FINGERPRINT}.plist"

echo "BUILD SCRIPT VERSION: KAPPA-HYPRLAND-REPO-1"

# ---------------------------------------------------------------------------
# Prepare build directories.
# ---------------------------------------------------------------------------

mkdir -p "$WORK" "$DOWNLOADS"

# Start from a clean build environment without deleting downloaded artifacts.
rm -rf "$ROOTFS" "$KSTAGE" "$OUT"

mkdir -p "$ROOTFS" "$KSTAGE" "$OUT"

# ---------------------------------------------------------------------------
# Cleanup chroot mounts on success or failure.
# ---------------------------------------------------------------------------

cleanup_mounts() {
  set +e

  for d in run sys proc dev/pts dev; do
    if mountpoint -q "$ROOTFS/$d"; then
      umount -lf "$ROOTFS/$d"
    fi
  done
}

trap cleanup_mounts EXIT

# ---------------------------------------------------------------------------
# Require explicit, independent acceptance of each third-party repository.
# ---------------------------------------------------------------------------

if [[ "${ACCEPT_VUR_REPO:-false}" != "true" ]]; then
  echo "VUR acceptance was not explicitly enabled in workflow_dispatch." >&2
  exit 1
fi

if [[ "${ACCEPT_HYPRLAND_REPO:-false}" != "true" ]]; then
  echo "Hyprland repository requires separate explicit acceptance." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Verify downloaded artifacts.
# ---------------------------------------------------------------------------

echo "== Verifying downloaded artifacts =="

test -s "$DOWNLOADS/void-rootfs.tar.xz"
test -s "$DOWNLOADS/hexdump-kernel.tar.gz"
test -s "$DOWNLOADS/noctalia.tar.gz"

echo "$VOID_ROOTFS_SHA256  $DOWNLOADS/void-rootfs.tar.xz" |
  sha256sum --check --strict

echo "$HEXDUMP_KERNEL_SHA256  $DOWNLOADS/hexdump-kernel.tar.gz" |
  sha256sum --check --strict

echo "$NOCTALIA_SOURCE_SHA256  $DOWNLOADS/noctalia.tar.gz" |
  sha256sum --check --strict

# ---------------------------------------------------------------------------
# Extract Void Linux root filesystem.
# ---------------------------------------------------------------------------

echo "== Extracting Void aarch64 glibc ROOTFS =="

tar -xJf "$DOWNLOADS/void-rootfs.tar.xz" \
  -C "$ROOTFS" \
  --numeric-owner

# Ensure required directories exist and are actual directories.
for dir in \
  "$ROOTFS/etc/xbps.d" \
  "$ROOTFS/etc/skel/.config/hypr" \
  "$ROOTFS/usr/local/bin" \
  "$ROOTFS/var/db/xbps/keys"
do
  if [[ -L "$dir" || -f "$dir" ]]; then
    rm -f "$dir"
  fi

  mkdir -p "$dir"
done

# Preserve Void's standard /var/service symlink.
SERVICE_LINK="$ROOTFS/var/service"

if [[ -L "$SERVICE_LINK" ]]; then
  if [[ "$(readlink "$SERVICE_LINK")" != "../run/runit/runsvdir/current" ]]; then
    echo "ERROR: Unexpected /var/service symlink target." >&2
    exit 1
  fi
elif [[ ! -e "$SERVICE_LINK" ]]; then
  ln -s ../run/runit/runsvdir/current "$SERVICE_LINK"
else
  echo "ERROR: /var/service exists but is not a symlink." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Configure VUR repository.
# ---------------------------------------------------------------------------

printf 'repository=%s\n' "$VUR_REPOSITORY" \
  > "$ROOTFS/etc/xbps.d/20-vur.conf"

# ---------------------------------------------------------------------------
# Configure the Sofijacom Hyprland repository.
# Named 15-* so it is read before VUR (20-*) and its Hyprland stack
# (hyprland, hyprlang, hyprutils...) is not shadowed by VUR's copies.
# ---------------------------------------------------------------------------

printf 'repository=%s\n' "$HYPRLAND_REPOSITORY" \
  > "$ROOTFS/etc/xbps.d/15-hyprland-void.conf"

# ---------------------------------------------------------------------------
# Download and install the VUR public signing key.
#
# IMPORTANT:
# The filename must match the complete RSA fingerprint exactly.
# In particular, the segment "9e" after "e0" must not be omitted.
# ---------------------------------------------------------------------------

echo "== Installing VUR public signing key =="

# Remove the incorrectly named key from previous builds, if present.
rm -f \
  "$ROOTFS/var/db/xbps/keys/df:ec:10:ef:5c:03:e9:e0:86:77:08:c2:b5:a8:cb.plist"

if ! curl -fsSL --retry 3 \
  "https://codeberg.org/oSoWoSo/oco/raw/branch/OCO/oco-repo-key.plist" \
  -o "$VUR_KEY"; then

  echo "Codeberg download failed; trying GitHub mirror."

  curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/oSoWoSo/oco/OCO/oco-repo-key.plist" \
    -o "$VUR_KEY"
fi

if [[ ! -s "$VUR_KEY" ]]; then
  echo "ERROR: VUR public key download is empty." >&2
  exit 1
fi

install -m 0644 "$VUR_KEY" "$VUR_KEY_PATH"

if ! cmp -s "$VUR_KEY" "$VUR_KEY_PATH"; then
  echo "ERROR: Installed VUR key differs from downloaded key." >&2
  exit 1
fi

echo "Installed VUR key:"
ls -l "$VUR_KEY_PATH"
sha256sum "$VUR_KEY_PATH"

# ---------------------------------------------------------------------------
# Download, pin and install the Hyprland repository public key.
# Independent from the VUR key: never reuse or rename one for the other.
# ---------------------------------------------------------------------------

echo "== Installing Hyprland repository public signing key =="

curl -fsSL --retry 3 "$HYPRLAND_KEY_URL" -o "$HYPRLAND_KEY"

if [[ ! -s "$HYPRLAND_KEY" ]]; then
  echo "ERROR: Hyprland public key download is empty." >&2
  exit 1
fi

echo "$HYPRLAND_KEY_SHA256  $HYPRLAND_KEY" | sha256sum --check --strict

install -m 0644 "$HYPRLAND_KEY" "$HYPRLAND_KEY_PATH"

if ! cmp -s "$HYPRLAND_KEY" "$HYPRLAND_KEY_PATH"; then
  echo "ERROR: Installed Hyprland key differs from downloaded key." >&2
  exit 1
fi

echo "Installed Hyprland key (expected fingerprint ${HYPRLAND_KEY_FINGERPRINT}):"
ls -l "$HYPRLAND_KEY_PATH"
sha256sum "$HYPRLAND_KEY_PATH"

# Verify that both exact keys are visible inside the target rootfs.
chroot "$ROOTFS" /bin/sh -euc '
  for key in \
    "/var/db/xbps/keys/df:ec:10:ef:5c:03:e9:e0:9e:86:77:08:c2:b5:a8:cb.plist" \
    "/var/db/xbps/keys/b3:21:c4:43:d9:38:6f:ec:36:64:0d:65:37:13:c1:fe.plist"
  do
    test -s "$key"
    echo "Signing key present inside chroot:"
    ls -l "$key"
  done
'

# ---------------------------------------------------------------------------
# Configure DNS and bind mounts for chroot package installation.
# ---------------------------------------------------------------------------

echo "== Preparing chroot environment =="

install -D -m 0644 /etc/resolv.conf \
  "$ROOTFS/etc/resolv.conf"

for d in dev dev/pts proc sys run; do
  mkdir -p "$ROOTFS/$d"
done

mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
mount --bind /run "$ROOTFS/run"

# ---------------------------------------------------------------------------
# Update XBPS and install required packages.
# ---------------------------------------------------------------------------
chroot "$ROOTFS" /bin/sh -euc '
  export PATH=/usr/bin:/usr/sbin:/bin:/sbin

  HYPR_REPO="https://raw.githubusercontent.com/sofijacom/hyprland-void/repository-aarch64-glibc"

  echo "== Updating XBPS =="

  xbps-install -SMuy xbps

  echo "== Updating all repositories =="

  xbps-install -SMuy

  echo "== Installing base system =="

  xbps-install -SMuy base-system

  echo "== Checking repository availability =="

  xbps-query -L -v

  echo "== Checking Sofijacom Hyprland repository =="

  xbps-query -Rs hyprland

  echo "== Verifying Hyprland package in its repository =="

  xbps-query -R --repository="$HYPR_REPO" hyprland

  echo "== Installing Hyprland packages =="

  xbps-install -SMuy \
    hyprland \
    hyprlock \
    hyprpaper \
    hyprpicker \
    hyprpolkitagent \
    xdg-desktop-portal-hyprland

  echo "== Installing official Void desktop packages =="

  xbps-install -SMuy \
    NetworkManager wpa_supplicant dbus bluez elogind seatd polkit \
    pipewire wireplumber alsa-utils alsa-ucm-conf linux-firmware \
    mesa-dri xorg-server-xwayland xdg-desktop-portal \
    foot sudo shadow git curl zstd tar \
    xdg-user-dirs wl-clipboard grim slurp playerctl brightnessctl \
    pavucontrol fastfetch \
    gcc make just meson ninja pkgconf \
    wayland-devel wayland-protocols libepoxy-devel MesaLib-devel \
    libglvnd-devel cairo-devel pango-devel fontconfig-devel freetype-devel \
    harfbuzz-devel libxkbcommon-devel pipewire-devel wireplumber-devel \
    libsecret-devel libsodium-devel libcurl-devel pam-devel libwebp-devel \
    libjxl-devel libsndfile-devel basu-devel sdbus-c++-devel polkit-devel \
    libqalculate-devel librsvg-devel libxml2-devel libmd4c-devel \
    tomlplusplus-devel libical-devel json-c++ stb jemalloc-devel
'

# ---------------------------------------------------------------------------
# Build Noctalia from its pinned upstream source release.
# ---------------------------------------------------------------------------

echo "== Building Noctalia =="

mkdir -p "$ROOTFS/tmp/noctalia-src"

tar -xzf "$DOWNLOADS/noctalia.tar.gz" \
  -C "$ROOTFS/tmp/noctalia-src" \
  --strip-components=1

chroot "$ROOTFS" /bin/sh -euc '
  cd /tmp/noctalia-src

  just configure release /usr
  just build release
  just install release
'

rm -rf \
  "$ROOTFS/tmp/noctalia-src" \
  "$ROOTFS/tmp/build-release"

# ---------------------------------------------------------------------------
# Create local user and groups.
# ---------------------------------------------------------------------------

echo "== Creating local user =="

chroot "$ROOTFS" /bin/sh -euc '
  getent group wheel >/dev/null 2>&1 || groupadd wheel
  getent group video >/dev/null 2>&1 || groupadd video
  getent group audio >/dev/null 2>&1 || groupadd audio
  getent group input >/dev/null 2>&1 || groupadd input
  getent group seat >/dev/null 2>&1 || groupadd seat

  if ! id fede >/dev/null 2>&1; then
    useradd \
      --create-home \
      --user-group \
      --shell /bin/bash \
      --groups wheel,video,audio,input,seat \
      fede
  fi

  install -d -m 0750 /etc/sudoers.d

  printf "%%wheel ALL=(ALL:ALL) ALL\n" \
    > /etc/sudoers.d/10-wheel

  chmod 0440 /etc/sudoers.d/10-wheel

  passwd -l fede >/dev/null 2>&1 || true
'

# ---------------------------------------------------------------------------
# Enable runit services in the default runsvdir.
# The rootfs is not booted during image construction.
# Do not modify /var/service: it is normally a symlink in Void Linux.
# ---------------------------------------------------------------------------

echo "== Configuring runit services =="

RUNSVDIR="$ROOTFS/etc/runit/runsvdir/default"

if [[ ! -d "$RUNSVDIR" ]]; then
  echo "ERROR: Void runit default runsvdir was not installed." >&2
  ls -ld "$ROOTFS/etc/runit" \
         "$ROOTFS/etc/runit/runsvdir" 2>/dev/null || true
  exit 1
fi

echo "Using runsvdir:"
ls -ld "$RUNSVDIR"

for service in dbus NetworkManager bluetoothd elogind seatd; do
  SERVICE_DIR="$ROOTFS/etc/sv/$service"
  SERVICE_ENABLE_LINK="$RUNSVDIR/$service"

  if [[ -d "$SERVICE_DIR" ]]; then

    if [[ -e "$SERVICE_ENABLE_LINK" && ! -L "$SERVICE_ENABLE_LINK" ]]; then
      echo "ERROR: $SERVICE_ENABLE_LINK exists and is not a symlink." >&2
      exit 1
    fi

    ln -sfn "/etc/sv/$service" "$SERVICE_ENABLE_LINK"

    echo "Enabled service: $service"
  else
    echo "Service not installed, skipping: $service"
  fi
done

echo "Configured default runit services:"
ls -la "$RUNSVDIR"

# ---------------------------------------------------------------------------
# System identity and filesystem configuration.
# ---------------------------------------------------------------------------

printf 'hp-11a\n' > "$ROOTFS/etc/hostname"

printf \
  'PARTUUID=%s / ext4 defaults,noatime 0 1\n/swapfile none swap defaults 0 0\n' \
  "$ROOT_PARTUUID" \
  > "$ROOTFS/etc/fstab"

# ---------------------------------------------------------------------------
# Chromebook audio helper.
# ---------------------------------------------------------------------------

cat > "$ROOTFS/usr/local/bin/kappa-audio-fix" <<'AUDIO'
#!/bin/sh
set -eu

amixer -c 0 sset 'I2S3_CH1 DL1_CH1' on
amixer -c 0 sset 'I2S3_CH2 DL1_CH2' on
AUDIO

chmod 0755 "$ROOTFS/usr/local/bin/kappa-audio-fix"

# ---------------------------------------------------------------------------
# Minimal Hyprland configuration.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Install the starter configuration into fede's home directory.
# ---------------------------------------------------------------------------

echo "== Installing Hyprland user configuration =="

install -D -m 0644 \
  "$ROOTFS/etc/skel/.config/hypr/hyprland.conf" \
  "$ROOTFS/home/fede/.config/hypr/hyprland.conf"

FEDE_UID="$(chroot "$ROOTFS" id -u fede)"
FEDE_GID="$(chroot "$ROOTFS" id -g fede)"

chown -R "$FEDE_UID:$FEDE_GID" \
  "$ROOTFS/home/fede/.config"

# ---------------------------------------------------------------------------
# Remove unused zram configuration.
# ---------------------------------------------------------------------------

rm -f \
  "$ROOTFS/etc/xbps.d/30-zram.conf" \
  "$ROOTFS/etc/udev/rules.d/99-zram.rules"

# ---------------------------------------------------------------------------
# Extract Hexdump kernel release payload.
# ---------------------------------------------------------------------------

echo "== Extracting Hexdump kernel =="

tar -xzf "$DOWNLOADS/hexdump-kernel.tar.gz" \
  -C "$KSTAGE"

KPART="$(
  find "$KSTAGE" \
    -type f \
    -name "vmlinux.kpart-${HEXDUMP_RELEASE}" \
    -print -quit
)"

MODULES_SRC="$(
  find "$KSTAGE" \
    -type d \
    -path "*/lib/modules/${HEXDUMP_RELEASE}" \
    -print -quit
)"

if [[ -z "$KPART" || -z "$MODULES_SRC" ]]; then
  echo "ERROR: Could not locate kernel image or modules." >&2

  find "$KSTAGE" -maxdepth 5 -print | head -200

  exit 1
fi

mkdir -p "$ROOTFS/usr/lib/modules/$HEXDUMP_RELEASE"

cp -a \
  "$MODULES_SRC/." \
  "$ROOTFS/usr/lib/modules/$HEXDUMP_RELEASE/"

# ---------------------------------------------------------------------------
# Configure and repack kernel for KernelB.
# ---------------------------------------------------------------------------

echo "== Repacking kernel for kappa =="

cat > "$WORK/kernelB.cmdline" <<CMDLINE
cros_secure console=tty1 root=PARTUUID=${ROOT_PARTUUID} rootwait rw net.ifnames=0 noresume quiet loglevel=3 vt.global_cursor_default=0 modprobe.blacklist=onboard_usb_dev
CMDLINE

# Verify upstream image before repacking.
vbutil_kernel --verify "$KPART" --verbose

vbutil_kernel --repack "$OUT/kernelB.vboot" \
  --oldblob "$KPART" \
  --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
  --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
  --config "$WORK/kernelB.cmdline"

# Verify repacked image.
vbutil_kernel --verify "$OUT/kernelB.vboot" --verbose

# ---------------------------------------------------------------------------
# Verify exact MT8183 kappa device tree.
# ---------------------------------------------------------------------------

echo "== Verifying kappa device tree =="

vbutil_kernel \
  --get-vmlinuz "$OUT/kernelB.vboot" \
  --vmlinuz-out "$WORK/kernelB.fit"

dumpimage -l "$WORK/kernelB.fit" \
  > "$WORK/fit-list.txt"

if ! grep -F 'mt8183-kukui-jacuzzi-kappa' \
  "$WORK/fit-list.txt" >/dev/null; then

  cat "$WORK/fit-list.txt"

  echo "ERROR: FIT does not contain the kappa DTB." >&2
  exit 1
fi

grep -F "root=PARTUUID=${ROOT_PARTUUID}" \
  "$WORK/kernelB.cmdline" >/dev/null

grep -F 'modprobe.blacklist=onboard_usb_dev' \
  "$WORK/kernelB.cmdline" >/dev/null

# Keep a record of exact package versions chosen by the live XBPS repositories.
chroot "$ROOTFS" xbps-query -l | sort > "$OUT/xbps-installed-packages.txt"
cp "$WORK/kernelB.cmdline" "$OUT/kernel-command-line.txt"

# ---------------------------------------------------------------------------
# Unmount host pseudo-filesystems before creating the rootfs archive.
# Never package the runner's live /sys, /proc, /dev or /run.
# ---------------------------------------------------------------------------

echo "== Unmounting chroot filesystems =="

cleanup_mounts
set -e

for d in run sys proc dev/pts dev; do
  if mountpoint -q "$ROOTFS/$d"; then
    echo "ERROR: $ROOTFS/$d is still mounted." >&2
    exit 1
  fi
done

trap - EXIT

echo "All chroot mounts successfully removed."

# ---------------------------------------------------------------------------
# Create rootfs archive.
# ---------------------------------------------------------------------------

echo "== Creating rootfs archive =="

tar \
  --numeric-owner \
  --xattrs \
  --acls \
  --zstd \
  --exclude='./proc/*' \
  --exclude='./sys/*' \
  --exclude='./dev/*' \
  --exclude='./run/*' \
  -C "$ROOTFS" \
  -cf "$OUT/void-kappa-rootfs.tar.zst" \
  .

# ---------------------------------------------------------------------------
# Generate build manifest.
# ---------------------------------------------------------------------------

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
  "vur_repository": "${VUR_REPOSITORY}",
  "vur_key_fingerprint": "${VUR_KEY_FINGERPRINT}",
  "hyprland_repository": "${HYPRLAND_REPOSITORY}",
  "hyprland_key_fingerprint": "${HYPRLAND_KEY_FINGERPRINT}",
  "hyprland_key_sha256": "${HYPRLAND_KEY_SHA256}",
  "notes": [
    "Hyprland packages are installed from the third-party Sofijacom hyprland-void AArch64 repository.",
    "The VUR repository remains configured as a lower-priority secondary source.",
    "Noctalia is built from its pinned upstream source release on the ARM64 runner.",
    "The FIT is repacked for KernelB p2 to root p4 using the supplied PARTUUID.",
    "The rootfs tarball must be extracted onto an ext4 filesystem; it is not a disk image.",
    "No personal Hyprland or Noctalia configuration is embedded.",
    "The owner must set the fede account password before first boot."
  ]
}
JSON

# ---------------------------------------------------------------------------
# Generate artifact checksums.
# ---------------------------------------------------------------------------

(
  cd "$OUT"

  sha256sum \
    void-kappa-rootfs.tar.zst \
    kernelB.vboot \
    xbps-installed-packages.txt \
    kernel-command-line.txt \
    manifest.json \
    > SHA256SUMS
)

cleanup_mounts
trap - EXIT

echo
echo "============================================"
echo "KAPPA BUILD COMPLETE"
echo "============================================"

ls -lh "$OUT"
