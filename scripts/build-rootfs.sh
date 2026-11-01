#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_PARTUUID="${ROOT_PARTUUID:?ROOT_PARTUUID must be supplied}"

VOID_ROOTFS_SHA256="${VOID_ROOTFS_SHA256:-01a30f17ae06d4d5b322cd579ca971bc479e02cc284ec1e5a4255bea6bac3ce6}"

HEXDUMP_RELEASE="${HEXDUMP_RELEASE:-6.18.34-stb-cbm+}"
HEXDUMP_KERNEL_SHA256="${HEXDUMP_KERNEL_SHA256:-d8c4bbde8eb206145aa53733d2ab2d0f985b7b983b9151a5f0543ffe0d5c83ad}"

# Third-party VUR repository: provides hyprland, noctalia and noctalia-greeter
# (aarch64-glibc). It is added only AFTER the official Void packages are
# installed, so it cannot shadow base-system packages.
VUR_REPOSITORY="${VUR_REPOSITORY:-https://repo.osowoso.org/aarch64}"
VUR_KEY_FINGERPRINT="df:ec:10:ef:5c:03:e9:e0:9e:86:77:08:c2:b5:a8:cb"
# sha256 of the reviewed VUR key file (override if the key is ever rotated).
VUR_KEY_SHA256="${VUR_KEY_SHA256:-db1606f78937d3e2f761c6ab4f6876dd2fec7d534f574189f1cbff13243ece6f}"

TIMEZONE="${TIMEZONE:-America/Santo_Domingo}"

# Optional: crypt(3) hash for user "fede" (e.g. from `openssl passwd -6`).
# Supplied through a GitHub secret. If empty, the account stays locked.
FEDE_PASSWORD_HASH="${FEDE_PASSWORD_HASH:-}"

WORK="${GITHUB_WORKSPACE:-$PWD}/work"
ROOTFS="$WORK/rootfs"
KSTAGE="$WORK/kernel"
OUT="$WORK/out"
DOWNLOADS="$WORK/downloads"

VUR_KEY="$WORK/oco-repo-key.plist"
VUR_KEY_PATH="$ROOTFS/var/db/xbps/keys/${VUR_KEY_FINGERPRINT}.plist"

echo "BUILD SCRIPT VERSION: KAPPA-MINIMAL-GREETD-1"

# ---------------------------------------------------------------------------
# Prepare build directories.
# ---------------------------------------------------------------------------

mkdir -p "$WORK" "$DOWNLOADS"
rm -rf "$ROOTFS" "$KSTAGE" "$OUT"
mkdir -p "$ROOTFS" "$KSTAGE" "$OUT"

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
# Require explicit acceptance of the third-party VUR repository.
# ---------------------------------------------------------------------------

if [[ "${ACCEPT_VUR_REPO:-false}" != "true" ]]; then
  echo "VUR acceptance was not explicitly enabled in workflow_dispatch." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Verify downloaded artifacts.
# ---------------------------------------------------------------------------

echo "== Verifying downloaded artifacts =="

test -s "$DOWNLOADS/void-rootfs.tar.xz"
test -s "$DOWNLOADS/hexdump-kernel.tar.gz"

echo "$VOID_ROOTFS_SHA256  $DOWNLOADS/void-rootfs.tar.xz" |
  sha256sum --check --strict

echo "$HEXDUMP_KERNEL_SHA256  $DOWNLOADS/hexdump-kernel.tar.gz" |
  sha256sum --check --strict

# ---------------------------------------------------------------------------
# Extract Void Linux root filesystem.
# ---------------------------------------------------------------------------

echo "== Extracting Void aarch64 glibc ROOTFS =="

tar -xJf "$DOWNLOADS/void-rootfs.tar.xz" \
  -C "$ROOTFS" \
  --numeric-owner

for dir in \
  "$ROOTFS/etc/xbps.d" \
  "$ROOTFS/etc/skel/.config/hypr" \
  "$ROOTFS/usr/local/bin" \
  "$ROOTFS/usr/share/wayland-sessions" \
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
# Chroot environment.
# ---------------------------------------------------------------------------

echo "== Preparing chroot environment =="

install -D -m 0644 /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

for d in dev dev/pts proc sys run; do
  mkdir -p "$ROOTFS/$d"
done

mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
mount --bind /run "$ROOTFS/run"

# ---------------------------------------------------------------------------
# Phase 1: official Void packages only (VUR is NOT configured yet).
# ---------------------------------------------------------------------------

chroot "$ROOTFS" /bin/sh -euc '
  export PATH=/usr/bin:/usr/sbin:/bin:/sbin

  echo "== Updating XBPS =="
  xbps-install -SMuy xbps

  echo "== Updating all repositories =="
  xbps-install -SMuy

  echo "== Installing base system =="
  xbps-install -SMuy base-system

  echo "== Installing runtime packages from official Void =="
  xbps-install -SMuy \
    NetworkManager wpa_supplicant dbus bluez elogind seatd polkit \
    greetd chrony \
    pipewire wireplumber libspa-bluetooth \
    alsa-utils alsa-ucm-conf linux-firmware \
    mesa-dri xorg-server-xwayland xdg-desktop-portal \
    foot sudo shadow curl zstd tar \
    xdg-user-dirs wl-clipboard grim slurp playerctl brightnessctl \
    pavucontrol fastfetch \
    xorg-minimal xinit xf86-input-libinput xfce4
'

# ---------------------------------------------------------------------------
# Phase 2: add VUR (pinned key) and install only Hyprland + Noctalia.
# ---------------------------------------------------------------------------

echo "== Installing VUR public signing key =="

if ! curl -fsSL --retry 3 \
  "https://codeberg.org/oSoWoSo/oco/raw/branch/OCO/oco-repo-key.plist" \
  -o "$VUR_KEY"; then
  echo "Codeberg download failed; trying GitHub mirror."
  curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/oSoWoSo/oco/OCO/oco-repo-key.plist" \
    -o "$VUR_KEY"
fi

test -s "$VUR_KEY"

echo "$VUR_KEY_SHA256  $VUR_KEY" | sha256sum --check --strict

install -m 0644 "$VUR_KEY" "$VUR_KEY_PATH"
cmp -s "$VUR_KEY" "$VUR_KEY_PATH"

printf 'repository=%s\n' "$VUR_REPOSITORY" \
  > "$ROOTFS/etc/xbps.d/20-vur.conf"

chroot "$ROOTFS" /bin/sh -euc '
  export PATH=/usr/bin:/usr/sbin:/bin:/sbin

  echo "== Checking packages exist in VUR (aarch64) =="
  for p in hyprland noctalia noctalia-greeter hyprpolkitagent xdg-desktop-portal-hyprland; do
    xbps-query -R --repository="'"$VUR_REPOSITORY"'" "$p" >/dev/null \
      || { echo "ERROR: $p missing from VUR aarch64" >&2; exit 1; }
  done

  echo "== Installing Hyprland, Noctalia and the greeter from VUR =="
  xbps-install -SMy \
    hyprland hyprpolkitagent xdg-desktop-portal-hyprland \
    noctalia noctalia-greeter

  echo "== Cleaning package cache =="
  xbps-remove -yO || true
  rm -rf /var/cache/xbps/*
'

# Record where the key packages came from.
chroot "$ROOTFS" /bin/sh -euc '
  for p in hyprland noctalia noctalia-greeter; do
    printf "%s  %s  %s\n" "$p" \
      "$(xbps-query -p pkgver "$p")" \
      "$(xbps-query -p repository "$p")"
  done
' | tee "$OUT/vur-packages.txt"

# ---------------------------------------------------------------------------
# ALSA -> PipeWire bridge (shipped inside the pipewire package; Void needs
# the config snippets linked into /etc/alsa/conf.d).
# ---------------------------------------------------------------------------

mkdir -p "$ROOTFS/etc/alsa/conf.d"
for conf in 50-pipewire.conf 99-pipewire-default.conf; do
  if [[ -e "$ROOTFS/usr/share/alsa/alsa.conf.d/$conf" ]]; then
    ln -sf "/usr/share/alsa/alsa.conf.d/$conf" "$ROOTFS/etc/alsa/conf.d/$conf"
    echo "Linked ALSA config: $conf"
  else
    echo "WARNING: /usr/share/alsa/alsa.conf.d/$conf not found; skipping." >&2
  fi
done

# ---------------------------------------------------------------------------
# Users and groups.
# ---------------------------------------------------------------------------

echo "== Creating local user =="

chroot "$ROOTFS" /bin/sh -euc '
  for g in wheel video audio input seat bluetooth network; do
    getent group "$g" >/dev/null 2>&1 || groupadd "$g"
  done

  if ! id fede >/dev/null 2>&1; then
    useradd \
      --create-home \
      --user-group \
      --shell /bin/bash \
      --groups wheel,video,audio,input,seat,bluetooth,network \
      fede
  fi

  install -d -m 0750 /etc/sudoers.d
  printf "%%wheel ALL=(ALL:ALL) ALL\n" > /etc/sudoers.d/10-wheel
  chmod 0440 /etc/sudoers.d/10-wheel
'

if [[ -n "$FEDE_PASSWORD_HASH" ]]; then
  printf 'fede:%s\n' "$FEDE_PASSWORD_HASH" | chroot "$ROOTFS" chpasswd -e
  echo "Password hash applied to user fede."
else
  chroot "$ROOTFS" passwd -l fede >/dev/null 2>&1 || true
  echo "WARNING: FEDE_PASSWORD_HASH not set; account fede is LOCKED." >&2
  echo "WARNING: set a password from another system before first boot," >&2
  echo "WARNING: otherwise the greeter cannot log you in." >&2
fi

# ---------------------------------------------------------------------------
# greetd + Noctalia Greeter.
# ---------------------------------------------------------------------------

echo "== Configuring greetd with Noctalia Greeter =="

GREETER_SESSION=/usr/bin/noctalia-greeter-session
test -x "$ROOTFS$GREETER_SESSION" || {
  echo "ERROR: $GREETER_SESSION not found in the rootfs." >&2
  find "$ROOTFS/usr" -name 'noctalia-greeter*' -maxdepth 3 >&2 || true
  exit 1
}

# User that greetd runs the greeter as: read it from the package default
# config, falling back to well-known names.
GREETD_USER="$(awk -F'"' '/^[[:space:]]*user[[:space:]]*=/ {print $2; exit}' \
  "$ROOTFS/etc/greetd/config.toml" 2>/dev/null || true)"

if [[ -z "$GREETD_USER" ]] || ! chroot "$ROOTFS" id "$GREETD_USER" >/dev/null 2>&1; then
  GREETD_USER=""
  for candidate in _greeter greeter _greetd greetd; do
    if chroot "$ROOTFS" id "$candidate" >/dev/null 2>&1; then
      GREETD_USER="$candidate"
      break
    fi
  done
fi

if [[ -z "$GREETD_USER" ]]; then
  echo "ERROR: could not determine the greetd user." >&2
  exit 1
fi

echo "greetd user: $GREETD_USER"

mkdir -p "$ROOTFS/etc/greetd"
cat > "$ROOTFS/etc/greetd/config.toml" <<GREETD
[terminal]
vt = 1

[default_session]
command = "${GREETER_SESSION}"
user = "${GREETD_USER}"
GREETD

chroot "$ROOTFS" usermod -aG video "$GREETD_USER"

# State and log paths owned by the greetd user (documented in the greeter's
# troubleshooting guide). Created explicitly so no first-boot setup is needed.
GREETD_UID="$(chroot "$ROOTFS" id -u "$GREETD_USER")"
GREETD_GID="$(chroot "$ROOTFS" id -g "$GREETD_USER")"

install -d -m 0755 "$ROOTFS/var/lib/noctalia-greeter"
touch "$ROOTFS/var/log/noctalia-greeter.log" \
      "$ROOTFS/var/lib/noctalia-greeter/greeter.log"
chown -R "$GREETD_UID:$GREETD_GID" \
  "$ROOTFS/var/lib/noctalia-greeter" \
  "$ROOTFS/var/log/noctalia-greeter.log"

# Best-effort official helper; the explicit setup above is the safety net.
if ! chroot "$ROOTFS" env GREETER_USER="$GREETD_USER" \
     /usr/bin/noctalia-greeter-apply-appearance --setup-system; then
  echo "NOTE: noctalia-greeter-apply-appearance --setup-system failed in chroot." >&2
  echo "NOTE: run it once on the booted system if the greeter looks wrong." >&2
fi

# ---------------------------------------------------------------------------
# Extra session: XFCE on Xorg, exposed to the greeter as a session entry.
# (The greeter lists wayland-sessions entries; this one wraps startx.)
# ---------------------------------------------------------------------------

cat > "$ROOTFS/usr/local/bin/start-xfce-x11" <<'XFCE'
#!/bin/sh
# Launch XFCE on Xorg from a greetd session.
vt=""
[ -n "${XDG_VTNR:-}" ] && vt="vt${XDG_VTNR}"
exec startx /usr/bin/startxfce4 -- $vt
XFCE
chmod 0755 "$ROOTFS/usr/local/bin/start-xfce-x11"

cat > "$ROOTFS/usr/share/wayland-sessions/xfce-x11.desktop" <<'DESKTOP'
[Desktop Entry]
Name=XFCE (X11)
Comment=XFCE desktop on Xorg (startx)
Exec=/usr/local/bin/start-xfce-x11
Type=Application
DESKTOP

# ---------------------------------------------------------------------------
# Enable runit services.
# greetd takes over tty1, so agetty-tty1 is removed; tty2-6 stay as a
# fallback console (Ctrl+Alt+F2).
# ---------------------------------------------------------------------------

echo "== Configuring runit services =="

RUNSVDIR="$ROOTFS/etc/runit/runsvdir/default"

if [[ ! -d "$RUNSVDIR" ]]; then
  echo "ERROR: Void runit default runsvdir was not installed." >&2
  exit 1
fi

for service in dbus NetworkManager bluetoothd elogind seatd chronyd greetd; do
  SERVICE_DIR="$ROOTFS/etc/sv/$service"
  SERVICE_ENABLE_LINK="$RUNSVDIR/$service"

  if [[ -d "$SERVICE_DIR" ]]; then
    if [[ -e "$SERVICE_ENABLE_LINK" && ! -L "$SERVICE_ENABLE_LINK" ]]; then
      echo "ERROR: $SERVICE_ENABLE_LINK exists and is not a symlink." >&2
      exit 1
    fi
    ln -sfn "/etc/sv/$service" "$SERVICE_ENABLE_LINK"
    echo "Enabled service: $service"
  elif [[ "$service" == "greetd" ]]; then
    echo "ERROR: /etc/sv/greetd is missing; cannot enable the greeter." >&2
    exit 1
  else
    echo "Service not installed, skipping: $service"
  fi
done

rm -f "$RUNSVDIR/agetty-tty1"

echo "Configured default runit services:"
ls -la "$RUNSVDIR"

# ---------------------------------------------------------------------------
# System identity and filesystem configuration.
# ---------------------------------------------------------------------------

printf 'hp-11a\n' > "$ROOTFS/etc/hostname"

# No swapfile entry: a missing /swapfile drops the system into emergency mode.
printf 'PARTUUID=%s / ext4 defaults,noatime 0 1\n' "$ROOT_PARTUUID" \
  > "$ROOTFS/etc/fstab"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "$ROOTFS/etc/localtime"

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
# Minimal Hyprland configuration (idempotent audio autostart).
# ---------------------------------------------------------------------------

cat > "$ROOTFS/etc/skel/.config/hypr/hyprland.conf" <<'HYPR'
$mainMod = SUPER

monitor = , preferred, auto, 1

exec-once = kappa-audio-fix
exec-once = sh -c 'pgrep -x pipewire >/dev/null || pipewire'
exec-once = sh -c 'pgrep -x wireplumber >/dev/null || wireplumber'
exec-once = sh -c 'pgrep -x pipewire-pulse >/dev/null || pipewire-pulse'
exec-once = hyprpolkitagent
exec-once = noctalia

bind = $mainMod, RETURN, exec, foot
bind = $mainMod, Q, killactive
bind = $mainMod SHIFT, E, exit
HYPR

echo "== Installing Hyprland user configuration =="

install -D -m 0644 \
  "$ROOTFS/etc/skel/.config/hypr/hyprland.conf" \
  "$ROOTFS/home/fede/.config/hypr/hyprland.conf"

FEDE_UID="$(chroot "$ROOTFS" id -u fede)"
FEDE_GID="$(chroot "$ROOTFS" id -g fede)"

chown -R "$FEDE_UID:$FEDE_GID" "$ROOTFS/home/fede/.config"

rm -f \
  "$ROOTFS/etc/xbps.d/30-zram.conf" \
  "$ROOTFS/etc/udev/rules.d/99-zram.rules"

# ---------------------------------------------------------------------------
# Extract Hexdump kernel release payload.
# ---------------------------------------------------------------------------

echo "== Extracting Hexdump kernel =="

tar -xzf "$DOWNLOADS/hexdump-kernel.tar.gz" -C "$KSTAGE"

KPART="$(find "$KSTAGE" -type f -name "vmlinux.kpart-${HEXDUMP_RELEASE}" -print -quit)"
MODULES_SRC="$(find "$KSTAGE" -type d -path "*/lib/modules/${HEXDUMP_RELEASE}" -print -quit)"

if [[ -z "$KPART" || -z "$MODULES_SRC" ]]; then
  echo "ERROR: Could not locate kernel image or modules." >&2
  find "$KSTAGE" -maxdepth 5 -print | head -200
  exit 1
fi

mkdir -p "$ROOTFS/usr/lib/modules/$HEXDUMP_RELEASE"
cp -a "$MODULES_SRC/." "$ROOTFS/usr/lib/modules/$HEXDUMP_RELEASE/"

# ---------------------------------------------------------------------------
# Configure and repack kernel for KernelB.
# ---------------------------------------------------------------------------

echo "== Repacking kernel for kappa =="

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

echo "== Verifying kappa device tree =="

vbutil_kernel \
  --get-vmlinuz "$OUT/kernelB.vboot" \
  --vmlinuz-out "$WORK/kernelB.fit"

dumpimage -l "$WORK/kernelB.fit" > "$WORK/fit-list.txt"

if ! grep -F 'mt8183-kukui-jacuzzi-kappa' "$WORK/fit-list.txt" >/dev/null; then
  cat "$WORK/fit-list.txt"
  echo "ERROR: FIT does not contain the kappa DTB." >&2
  exit 1
fi

grep -F "root=PARTUUID=${ROOT_PARTUUID}" "$WORK/kernelB.cmdline" >/dev/null
grep -F 'modprobe.blacklist=onboard_usb_dev' "$WORK/kernelB.cmdline" >/dev/null

chroot "$ROOTFS" xbps-query -l | sort > "$OUT/xbps-installed-packages.txt"
cp "$WORK/kernelB.cmdline" "$OUT/kernel-command-line.txt"

# ---------------------------------------------------------------------------
# Neutral DNS config (the runner's resolv.conf must not ship in the image),
# then unmount pseudo-filesystems before archiving.
# ---------------------------------------------------------------------------

rm -f "$ROOTFS/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$ROOTFS/etc/resolv.conf"

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
# Manifest and checksums.
# ---------------------------------------------------------------------------

PKG_HYPRLAND="$(awk '$1=="hyprland"{print $2}' "$OUT/vur-packages.txt")"
PKG_NOCTALIA="$(awk '$1=="noctalia"{print $2}' "$OUT/vur-packages.txt")"
PKG_GREETER="$(awk '$1=="noctalia-greeter"{print $2}' "$OUT/vur-packages.txt")"

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
  "vur_repository": "${VUR_REPOSITORY}",
  "vur_key_fingerprint": "${VUR_KEY_FINGERPRINT}",
  "vur_key_sha256": "${VUR_KEY_SHA256}",
  "hyprland": "${PKG_HYPRLAND}",
  "noctalia": "${PKG_NOCTALIA}",
  "noctalia_greeter": "${PKG_GREETER}",
  "greetd_user": "${GREETD_USER}",
  "sessions": ["hyprland", "xfce-x11"],
  "notes": [
    "Hyprland, Noctalia and Noctalia Greeter are installed from the third-party VUR aarch64 repository.",
    "VUR is configured only after all official Void packages are installed.",
    "greetd owns tty1; tty2-6 keep agetty as a fallback console.",
    "The FIT is repacked for the supplied root PARTUUID.",
    "The rootfs tarball must be extracted onto an ext4 filesystem; it is not a disk image.",
    "If FEDE_PASSWORD_HASH was not provided, the fede account is locked."
  ]
}
JSON

(
  cd "$OUT"
  sha256sum \
    void-kappa-rootfs.tar.zst \
    kernelB.vboot \
    xbps-installed-packages.txt \
    kernel-command-line.txt \
    vur-packages.txt \
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
