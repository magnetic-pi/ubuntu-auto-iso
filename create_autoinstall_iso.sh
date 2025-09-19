#!/bin/bash
set -e

## -- CONFIGURATION --
TARGET_ISO_FILENAME="ubuntu-24.04.3-live-server-amd64.iso"
ISO_URL="https://releases.ubuntu.com/24.04.3/$TARGET_ISO_FILENAME"
DATA_DIR="/data"
SOURCE_DIR="$DATA_DIR/source-files"
# The script will now look for and download the ISO in the root project folder.
ISO_PATH="$DATA_DIR/$TARGET_ISO_FILENAME" 
OUTPUT_ISO_NAME="ubuntu-24.04.3-autoinstall.iso"
INPUT_YAML_PATH="$DATA_DIR/autoinstall.yaml"

# Get host user's UID and GID from environment variables, with a fallback.
HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}

## -- SCRIPT LOGIC --
# 1. Check for the autoinstall file.
if [ ! -f "$INPUT_YAML_PATH" ]; then
    echo "Error: autoinstall.yaml not found in the project directory."
    exit 1
fi

# 2. Set up the source directory.
echo "## Creating source directory at $SOURCE_DIR..."
mkdir -p "$SOURCE_DIR"

# 3. Find or Download the Ubuntu Server ISO.
echo "## Locating Ubuntu Server ISO..."
if [ ! -f "$ISO_PATH" ]; then
    echo "## ISO not found locally. Downloading to $ISO_PATH..."
    wget -O "$ISO_PATH" "$ISO_URL"
else
    echo "✅ Found local ISO at $ISO_PATH. Skipping download."
fi

# 4. Extract the ISO contents correctly.
echo "## Extracting ISO contents into $SOURCE_DIR..."
xorriso -indev ubuntu-24.04.3-live-server-amd64.iso -report_el_torito as_mkisofs
7z -y x ubuntu-24.04.3-live-server-amd64.iso -osource-files
# Change into the source directory to force extraction into the current path
#cd "$SOURCE_DIR"
#7z x "$ORIGINAL_ISO_PATH" -y
## Change back to the main data directory
#cd "$DATA_DIR"

# 5. Add the autoinstall configuration.
echo "## Adding autoinstall configuration..."
cp "$INPUT_YAML_PATH" "$SOURCE_DIR"
#mkdir -p "$SOURCE_DIR/server"
#cp "$INPUT_YAML_PATH" "$SOURCE_DIR/server/user-data"
#touch "$SOURCE_DIR/server/meta-data"

# 6. Modify the GRUB boot menu.
echo "## Modifying GRUB boot menu..."
GRUB_CFG_PATH="$SOURCE_DIR/boot/grub/grub.cfg"
TEMP_GRUB_CFG_PATH="$DATA_DIR/grub.cfg.tmp"
AUTOINSTALL_MENU_ENTRY="menuentry \"Autoinstall Ubuntu Server\" {
	set gfxpayload=keep
	linux   /casper/vmlinuz quiet autoinstall ds=nocloud;s=/cdrom/server/ ---
	initrd  /casper/initrd
}"
echo "$AUTOINSTALL_MENU_ENTRY" > "$TEMP_GRUB_CFG_PATH"
cat "$GRUB_CFG_PATH" >> "$TEMP_GRUB_CFG_PATH"
mv "$TEMP_GRUB_CFG_PATH" "$GRUB_CFG_PATH"

# 6.5 Verify all required boot files are present before building.
echo "## Verifying boot file paths..."
BOOT_FILES=( "boot/grub/i386-pc/eltorito.img" )
for f in "${BOOT_FILES[@]}"; do
  if [ ! -f "$SOURCE_DIR/$f" ]; then
    echo "FATAL: Boot file not found after extraction: $f"
    echo "The ISO structure may have changed. Aborting."
    exit 1
  fi
done
echo "## All boot files verified."

# 7. Rebuild the ISO.
echo "## Rebuilding the ISO file..."
xorriso -as mkisofs -r \
-V 'Ubuntu-Server 24.04.3 LTS amd64' \
-o "$OUTPUT_ISO_NAME" \
--modification-date='2025080523540700' \
--grub2-mbr source-files/\[BOOT\]/1-Boot-NoEmul.img \
--protective-msdos-label \
-partition_cyl_align off \
-partition_offset 16 \
--mbr-force-bootable \
-append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b source-files/\[BOOT\]/2-Boot-NoEmul.img \
-appended_part_as_gpt \
-iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
-c '/boot.catalog' \
-b '/boot/grub/i386-pc/eltorito.img' \
-no-emul-boot \
-boot-load-size 4 \
-boot-info-table \
--grub2-boot-info \
-eltorito-alt-boot \
-e '--interval:appended_partition_2_start_1610304s_size_10160d:all::' \
-no-emul-boot \
-boot-load-size 10160 \
source-files

# 8. Fix ownership of the output file.
chown "$HOST_UID:$HOST_GID" "$DATA_DIR/$OUTPUT_ISO_NAME"

# 9. Clean up temporary files.
#echo "## Cleaning up contents of source directory..."
find "$SOURCE_DIR" -mindepth 1 -delete

echo ""
echo "✅ Success! Your new ISO has been created in your project directory:"
echo "$OUTPUT_ISO_NAME"
