#!/bin/bash
# Builds a Raspberry Pi image (.img.xz) from Ubuntu's preinstalled server image,
# with config/pi-user-data.yaml + config/common-user-data.yaml as its first-boot
# cloud-init config.
#
# Only the small FAT boot partition ("system-boot") is changed, using mtools, so
# no loop devices, mounting, or --privileged container are needed.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

load_config
HOSTNAME_PREFIX="$PI_HOSTNAME_PREFIX"
resolve_ssh_password false   # keys present -> SSH keys only

SOURCE_IMG="ubuntu-${UBUNTU_VERSION}-preinstalled-server-arm64+raspi.img.xz"
OUTPUT_IMG="$OUTPUT_DIR/ubuntu-${UBUNTU_VERSION}-autoconfig-arm64+raspi.img.xz"
WORK="$(mktemp -d "$DATA_DIR/.work-pi.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export MTOOLS_SKIP_CHECK=1

# Byte offset of partition 1 in an MBR-partitioned image (what Ubuntu's Pi images use).
boot_partition_offset() {
  local img="$1" sig type start
  sig="$(od -An -tx1 -j510 -N2 "$img" | tr -d ' \n')"
  [ "$sig" = "55aa" ] || die "$(basename "$img") has no MBR partition table."
  type="$(od -An -tx1 -j450 -N1 "$img" | tr -d ' \n')"
  case "$type" in
    0b|0c|0e|06|04|01) ;;
    ee) die "$(basename "$img") uses GPT; only MBR Pi images are supported." ;;
    *) die "Partition 1 of $(basename "$img") is not FAT (type 0x$type)." ;;
  esac
  start="$(od -An -tu4 -j454 -N4 "$img" | tr -d ' \n')"
  echo $((start * 512))
}

# 1. Render cloud-init user-data: Pi settings + shared first-boot user-data.
log "Rendering user-data (Ubuntu $UBUNTU_VERSION)..."
if [ -n "$NOSSHPW_USER" ]; then
  NOSSHPW_LINE="  - $NOSSHPW_USER_YAML"
  log "Users: $ADMIN_USER (password, $SSH_KEY_COUNT SSH key(s), sudo asks for the password) and $NOSSHPW_USER (no password, $NOSSHPW_KEY_COUNT SSH key(s), sudo without a prompt)."
  [ "$NOSSHPW_KEY_COUNT" -gt 0 ] || warn "config/nosshpw_authorized_keys has no keys, so $NOSSHPW_USER can't log in (no password either); use 'sudo -iu $NOSSHPW_USER' from $ADMIN_USER."
else
  NOSSHPW_LINE=""
fi
{
  # cloud-init rejects an empty key list, so drop the line when there are no keys.
  # Replace the @NOSSHPW_USER@ marker with the key-only user (ENVIRON keeps the
  # value byte-for-byte; awk -v would interpret its backslashes).
  render_template "$CONFIG_DIR/pi-user-data.yaml" \
    | sed '/^[[:space:]]*ssh_authorized_keys: \[\][[:space:]]*$/d' \
    | NOSSHPW_LINE="$NOSSHPW_LINE" awk '/@NOSSHPW_USER@/ { if (ENVIRON["NOSSHPW_LINE"] != "") print ENVIRON["NOSSHPW_LINE"]; next } { print }'
  echo
  render_template "$CONFIG_DIR/common-user-data.yaml"
} > "$WORK/user-data"
validate_cloud_config "$WORK/user-data"

# 2. Get the official image and unpack it.
download_verified "$PI_BASE_URL" "$SOURCE_IMG"
log "Decompressing $SOURCE_IMG ..."
xz -dc "$DOWNLOAD_DIR/$SOURCE_IMG" > "$WORK/pi.img"

# 3. Write our files into the boot partition.
offset="$(boot_partition_offset "$WORK/pi.img")"
boot="$WORK/pi.img@@$offset"
label="$(mlabel -i "$boot" -s :: 2>/dev/null | sed -n 's/.*Volume label is \([^ ]*\).*/\1/p')"
[ "${label,,}" = "system-boot" ] || warn "Boot partition label is '${label:-none}', expected 'system-boot'. Continuing."

log "Writing user-data to the boot partition..."
mcopy -o -i "$boot" "$WORK/user-data" ::user-data
if [ -f "$CONFIG_DIR/pi-network-config.yaml" ]; then
  log "Writing network-config from config/pi-network-config.yaml..."
  tr -d '\r' < "$CONFIG_DIR/pi-network-config.yaml" > "$WORK/network-config"
  mcopy -o -i "$boot" "$WORK/network-config" ::network-config
fi

# 4. Kernel command line. Since 25.10 it lives in current/ (A/B boot); before that, at the root.
if [ -n "${PI_KERNEL_ARGS// }" ]; then
  if mdir -i "$boot" ::current/cmdline.txt >/dev/null 2>&1; then
    cmdline_path="current/cmdline.txt"
  elif mdir -i "$boot" ::cmdline.txt >/dev/null 2>&1; then
    cmdline_path="cmdline.txt"
  else
    die "No cmdline.txt found in the boot partition."
  fi
  cmdline="$(mtype -i "$boot" "::$cmdline_path" | tr -d '\r\n')"
  for arg in $PI_KERNEL_ARGS; do
    case " $cmdline " in *" $arg "*) ;; *) cmdline="$cmdline $arg" ;; esac
  done
  log "Kernel command line ($cmdline_path): $cmdline"
  printf '%s\n' "$cmdline" > "$WORK/cmdline.txt"
  mcopy -o -i "$boot" "$WORK/cmdline.txt" "::$cmdline_path"
fi

# 5. Compress the result.
log "Compressing $(basename "$OUTPUT_IMG") (this takes a few minutes)..."
rm -f "$OUTPUT_IMG"
xz -T0 -c "$WORK/pi.img" > "$OUTPUT_IMG.part"
mv "$OUTPUT_IMG.part" "$OUTPUT_IMG"
fix_ownership "$OUTPUT_DIR" "$OUTPUT_IMG" "$DOWNLOAD_DIR" "$DOWNLOAD_DIR"/*

echo
echo "✅ Raspberry Pi image ready: output/$(basename "$OUTPUT_IMG")"
echo "   Flash it with Raspberry Pi Imager (\"Use custom\") or:"
echo "   xzcat output/$(basename "$OUTPUT_IMG") | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
echo "   Skip Imager's \"OS customisation\": it would replace this image's user-data."
