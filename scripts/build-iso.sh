#!/bin/bash
# Builds an x86-64 Ubuntu ISO that installs itself without prompts.
#   build-iso.sh server    Ubuntu Server   config/iso-autoinstall.yaml     + common-user-data.yaml
#   build-iso.sh desktop   Ubuntu Desktop  config/desktop-autoinstall.yaml + desktop-user-data.yaml
#
# Rather than unpacking the whole ISO, this asks xorriso to copy the official
# image with three files swapped in (autoinstall.yaml, grub.cfg, md5sum.txt) and
# to "replay" its boot setup (BIOS + UEFI). That keeps it working across Ubuntu
# releases without hardcoded partition offsets.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

VARIANT="${1:-server}"
load_config

case "$VARIANT" in
  server)
    HOSTNAME_PREFIX="$ISO_HOSTNAME_PREFIX"
    TEMPLATE="$CONFIG_DIR/iso-autoinstall.yaml"
    resolve_ssh_password false   # keys present -> SSH keys only
    USER_DATA="$CONFIG_DIR/common-user-data.yaml"
    SOURCE_ISO="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
    OUTPUT_ISO="$OUTPUT_DIR/ubuntu-${UBUNTU_VERSION}-autoinstall-amd64.iso"
    MENU_TITLE="Autoinstall Ubuntu Server"
    ;;
  desktop)
    HOSTNAME_PREFIX="$DESKTOP_HOSTNAME_PREFIX"
    TEMPLATE="$CONFIG_DIR/desktop-autoinstall.yaml"
    resolve_ssh_password true    # local VM: keep SSH passwords unless SSH_ALLOW_PASSWORD=false
    USER_DATA="$CONFIG_DIR/desktop-user-data.yaml"
    SOURCE_ISO="ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
    OUTPUT_ISO="$OUTPUT_DIR/ubuntu-${UBUNTU_VERSION}-desktop-autoinstall-amd64.iso"
    MENU_TITLE="Autoinstall Ubuntu Desktop"
    ;;
  *) die "Unknown ISO variant '$VARIANT' (expected server or desktop)." ;;
esac
SOURCE_PATH="$DOWNLOAD_DIR/$SOURCE_ISO"
WORK="$(mktemp -d "$DATA_DIR/.work-iso.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 1. Render the installer config: installer settings + shared first-boot user-data.
log "Rendering autoinstall.yaml (Ubuntu $UBUNTU_VERSION $VARIANT)..."
{ echo "#cloud-config"; render_template "$USER_DATA"; } > "$WORK/user-data.check"
validate_cloud_config "$WORK/user-data.check"
{
  render_template "$TEMPLATE"
  echo "  user-data:"
  render_template "$USER_DATA" | sed 's/^\(.\)/    \1/'
} > "$WORK/autoinstall.yaml"

# 2. Get the official ISO.
download_verified "$ISO_BASE_URL" "$SOURCE_ISO"

# 3. Pull out the files we change.
log "Extracting boot menu from the ISO..."
xorriso -osirrox on -indev "$SOURCE_PATH" -extract /boot/grub/grub.cfg "$WORK/grub.cfg" 2>/dev/null \
  || die "Could not find /boot/grub/grub.cfg in $SOURCE_ISO."
xorriso -osirrox on -indev "$SOURCE_PATH" -extract /md5sum.txt "$WORK/md5sum.txt" 2>/dev/null \
  || rm -f "$WORK/md5sum.txt"
chmod u+w "$WORK"/*

# 4. Boot menu. The installer uses /autoinstall.yaml on its own, but asks for
#    confirmation unless the kernel command line contains "autoinstall".
if [ "$ISO_REQUIRE_CONFIRMATION" = "true" ]; then
  log "ISO_REQUIRE_CONFIRMATION=true: leaving the boot menu unchanged; the installer will ask before erasing disks."
else
  log "Adding default '$MENU_TITLE' boot entry..."
  # Copy the first menu entry (the normal installer), rename it, add "autoinstall"
  # to its kernel line, and put the copy first so it becomes the default.
  awk -v title="$MENU_TITLE" '
    function autoinstall_copy(block,   n, i, lines, out) {
      n = split(block, lines, "\n")
      for (i = 1; i < n; i++) {
        if (i == 1) sub(/"[^"]*"|\047[^\047]*\047/, "\"" title "\"", lines[i])
        else if (lines[i] ~ /^[ \t]*linux[ \t]/) {
          if (!sub(/ ---/, " autoinstall ---", lines[i])) lines[i] = lines[i] " autoinstall"
        }
        out = out lines[i] "\n"
      }
      return out
    }
    state == 0 && /^menuentry / { state = 1 }
    state == 1 {
      block = block $0 "\n"
      if ($0 ~ /^}/) { printf "%s", autoinstall_copy(block); printf "%s", block; state = 2 }
      next
    }
    { print }
    END { if (state != 2) exit 1 }
  ' "$WORK/grub.cfg" > "$WORK/grub.cfg.new" || die "Could not find a menuentry in grub.cfg; the ISO layout may have changed."
  mv "$WORK/grub.cfg.new" "$WORK/grub.cfg"
fi

# How long the boot menu waits before starting the first entry (Ubuntu's default is 30s).
if [ -n "${ISO_BOOT_TIMEOUT:-}" ]; then
  [[ "$ISO_BOOT_TIMEOUT" =~ ^[0-9]+$ ]] || die "ISO_BOOT_TIMEOUT must be a number of seconds (0 = start immediately)."
  log "Boot menu timeout: ${ISO_BOOT_TIMEOUT}s"
  if grep -q '^set timeout=' "$WORK/grub.cfg"; then
    sed -i "s/^set timeout=.*/set timeout=$ISO_BOOT_TIMEOUT/" "$WORK/grub.cfg"
  else
    sed -i "1i set timeout=$ISO_BOOT_TIMEOUT" "$WORK/grub.cfg"
  fi
fi

# 5. Keep the ISO's "Check disc for defects" option passing.
MAP_ARGS=(-map "$WORK/autoinstall.yaml" /autoinstall.yaml -map "$WORK/grub.cfg" /boot/grub/grub.cfg)
if [ -f "$WORK/md5sum.txt" ]; then
  grub_md5="$(md5sum < "$WORK/grub.cfg" | cut -d' ' -f1)"
  yaml_md5="$(md5sum < "$WORK/autoinstall.yaml" | cut -d' ' -f1)"
  awk -v g="$grub_md5" '$2 == "./boot/grub/grub.cfg" {$1 = g; print $1 "  " $2; next} $2 != "./autoinstall.yaml"' \
    "$WORK/md5sum.txt" > "$WORK/md5sum.txt.new"
  echo "$yaml_md5  ./autoinstall.yaml" >> "$WORK/md5sum.txt.new"
  mv "$WORK/md5sum.txt.new" "$WORK/md5sum.txt"
  MAP_ARGS+=(-map "$WORK/md5sum.txt" /md5sum.txt)
fi

# 6. Write the new ISO, reproducing the original's BIOS and UEFI boot setup.
log "Writing $(basename "$OUTPUT_ISO")..."
rm -f "$OUTPUT_ISO" "$OUTPUT_ISO.part"
xorriso -indev "$SOURCE_PATH" -outdev "$OUTPUT_ISO.part" \
  "${MAP_ARGS[@]}" \
  -boot_image any replay
mv "$OUTPUT_ISO.part" "$OUTPUT_ISO"
fix_ownership "$OUTPUT_DIR" "$OUTPUT_ISO" "$DOWNLOAD_DIR" "$DOWNLOAD_DIR"/*

echo
echo "✅ ISO ready: output/$(basename "$OUTPUT_ISO")"
if [ "$ISO_REQUIRE_CONFIRMATION" != "true" ]; then
  echo "   Warning: booting it erases the largest disk without asking."
fi
