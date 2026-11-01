#!/bin/bash
# Shared helpers for build-iso.sh and build-pi.sh. Sourced, not executed.

DATA_DIR="${DATA_DIR:-/data}"
CONFIG_DIR="$DATA_DIR/config"
DOWNLOAD_DIR="$DATA_DIR/downloads"
OUTPUT_DIR="$DATA_DIR/output"

# Settings from build.env that may be overridden from the environment
# (./build.sh passes them into the container).
CONFIG_VARS=(
  UBUNTU_VERSION ISO_BASE_URL PI_BASE_URL ADMIN_USER
  ISO_HOSTNAME_PREFIX PI_HOSTNAME_PREFIX DESKTOP_HOSTNAME_PREFIX LOCALE KEYBOARD_LAYOUT TIMEZONE
  SSH_ALLOW_PASSWORD K8S_VERSION ISO_REQUIRE_CONFIRMATION ISO_BOOT_TIMEOUT PI_KERNEL_ARGS
  PASSWORD_HASH ADMIN_PASSWORD
)

log()  { echo "## $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Source an env file, tolerating Windows line endings.
source_env() {
  # shellcheck disable=SC1090
  source <(tr -d '\r' < "$1")
}

load_config() {
  [ -f "$CONFIG_DIR/build.env" ] || die "config/build.env not found. Run ./build.sh from the project folder."

  # Remember values passed in from the environment so they win over the files.
  local name
  declare -gA _env_overrides=()
  for name in "${CONFIG_VARS[@]}"; do
    if [ -n "${!name+x}" ]; then _env_overrides[$name]="${!name}"; fi
  done

  source_env "$CONFIG_DIR/build.env"
  if [ -f "$CONFIG_DIR/secrets.env" ]; then
    source_env "$CONFIG_DIR/secrets.env"
  fi

  for name in "${!_env_overrides[@]}"; do
    printf -v "$name" '%s' "${_env_overrides[$name]}"
  done
  # Re-derive the default URLs if only UBUNTU_VERSION was overridden.
  if [ -n "${_env_overrides[UBUNTU_VERSION]+x}" ]; then
    [ -n "${_env_overrides[ISO_BASE_URL]+x}" ] || ISO_BASE_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}"
    [ -n "${_env_overrides[PI_BASE_URL]+x}" ]  || PI_BASE_URL="https://cdimage.ubuntu.com/releases/${UBUNTU_VERSION}/release"
  fi

  # A plain ADMIN_PASSWORD is hashed here with openssl (SHA-512, random salt);
  # only the hash goes into the images. It takes priority over PASSWORD_HASH,
  # so an old hash left in secrets.env can't silently override a new password.
  if [ -n "${ADMIN_PASSWORD:-}" ]; then
    [ "$ADMIN_PASSWORD" != "change-me" ] || die "config/secrets.env still has the example ADMIN_PASSWORD. Set your own password."
    command -v openssl >/dev/null 2>&1 || die "openssl is needed to hash ADMIN_PASSWORD. Run ./build.sh so the builder image is up to date, or set PASSWORD_HASH instead."
    if [ -n "${PASSWORD_HASH:-}" ]; then
      warn "Both ADMIN_PASSWORD and PASSWORD_HASH are set; using ADMIN_PASSWORD. Remove PASSWORD_HASH from config/secrets.env to silence this."
    fi
    PASSWORD_HASH="$(printf '%s' "$ADMIN_PASSWORD" | openssl passwd -6 -stdin)" \
      || die "openssl could not hash ADMIN_PASSWORD."
    log "Hashed ADMIN_PASSWORD for user '$ADMIN_USER' (SHA-512)."
  fi
  unset ADMIN_PASSWORD

  [ -n "${PASSWORD_HASH:-}" ] || die "No password set. Copy config/secrets.env.example to config/secrets.env and set ADMIN_PASSWORD (or PASSWORD_HASH)."
  case "$PASSWORD_HASH" in
    '$6$replace.me$'*) die "config/secrets.env still has the example PASSWORD_HASH. Replace it with the output of \`openssl passwd -6\`, or use ADMIN_PASSWORD." ;;
    '$6$'*|'$y$'*|'$5$'*) ;;
    '$1$'*) warn "PASSWORD_HASH is MD5-crypt (\$1\$), which is weak. Prefer \`openssl passwd -6\`." ;;
    *) die "PASSWORD_HASH doesn't look like a crypt hash. Generate one with \`openssl passwd -6\`." ;;
  esac

  check_username "$ADMIN_USER"

  load_authorized_keys
  case "$SSH_ALLOW_PASSWORD" in
    auto|true) ;;
    false) [ "$SSH_KEY_COUNT" -gt 0 ] || die "SSH_ALLOW_PASSWORD=false but config/authorized_keys has no keys; nobody could log in over SSH." ;;
    *) die "SSH_ALLOW_PASSWORD must be auto, true or false (got '$SSH_ALLOW_PASSWORD')." ;;
  esac

  mkdir -p "$DOWNLOAD_DIR" "$OUTPUT_DIR"
}

# Usernames the Ubuntu installer refuses ("Username is reserved by the system").
# Copied from the reserved-usernames list that Subiquity ships (from Ubuntu's
# user-setup package); applied to both targets so they accept the same names.
RESERVED_USERNAMES=" root daemon bin sys sync games man lp mail news uucp proxy www-data backup
  list irc gnats nobody adm tty disk kmem dialout fax voice cdrom floppy tape sudo audio dip
  operator src shadow utmp video sasl plugdev staff users nogroup netplan ftn mysql tac-plus
  alias qmail qmaild qmails qmailr qmailq qmaill qmailp asterisk vpopmail vchkpw slurm
  hacluster haclient grsec-tpe grsec-sock-all grsec-sock-clt grsec-sock-srv grsec-proc ceph
  opensrf libvirt-qemu admin Debian-exim bind crontab cupsys dcc dhcp dictd dnsmasq dovecot
  fetchmail firebird ftp fuse gdm haldaemon hplilp identd input jwhois klog kvm lpadmin maas
  messagebus mythtv netdev powerdev radvd render saned sbuild scanner sgx slocate ssh sshd
  ssl-cert sslwrap statd syslog telnetd tftpd "

check_username() {
  local name="$1"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ "${#name}" -le 32 ] \
    || die "ADMIN_USER '$name' is not a valid username (lowercase letters, digits, _ and -; at most 32 characters)."
  case "$(echo $RESERVED_USERNAMES | tr ' ' '\n' | grep -Fx -- "$name")" in
    "") ;;
    *) die "ADMIN_USER '$name' is reserved by the system and the Ubuntu installer will refuse it. Pick another name for ADMIN_USER in config/secrets.env (e.g. ubuntu, ops, k8sadmin)." ;;
  esac
}

# Read config/authorized_keys (one public key per line, # comments allowed).
# Sets SSH_AUTHORIZED_KEYS to a YAML flow list ["key one", "key two"] and
# SSH_KEY_COUNT to the number of keys. Refuses private keys; skips lines that
# don't look like public keys, with a warning.
SSH_KEY_TYPES='(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)'
load_authorized_keys() {
  local file="$CONFIG_DIR/authorized_keys" line out="" sep="" n=0 lineno=0
  if [ -f "$file" ]; then
    grep -q "PRIVATE KEY" "$file" \
      && die "config/authorized_keys contains a PRIVATE key. Put only public keys there (the .pub file, e.g. ~/.ssh/id_ed25519.pub), and keep the private key secret."
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))
      line="${line%$'\r'}"
      [[ -z "${line// }" || "$line" =~ ^[[:space:]]*\# ]] && continue
      if ! [[ "$line" =~ (^|[[:space:]])$SSH_KEY_TYPES[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]]|$) ]]; then
        warn "config/authorized_keys line $lineno doesn't look like an SSH public key; skipping it."
        continue
      fi
      line="${line//\\/\\\\}"
      line="${line//\"/\\\"}"
      out+="$sep\"$line\""
      sep=", "
      n=$((n + 1))
    done < "$file"
  fi
  SSH_AUTHORIZED_KEYS="[$out]"
  SSH_KEY_COUNT=$n
}

# Decide whether SSH accepts passwords on this image. SSH_ALLOW_PASSWORD=auto
# (the default) means: with keys in config/authorized_keys, use $1 (false for
# the server ISO and Pi, true for the desktop); without keys, allow passwords so
# nobody is locked out. Sets SSH_ALLOW_PASSWORD (true/false) and
# SSH_PASSWORD_AUTH (yes/no, for sshd_config).
resolve_ssh_password() {
  if [ "$SSH_ALLOW_PASSWORD" = auto ]; then
    if [ "$SSH_KEY_COUNT" -gt 0 ]; then SSH_ALLOW_PASSWORD="$1"; else SSH_ALLOW_PASSWORD=true; fi
  fi
  if [ "$SSH_ALLOW_PASSWORD" = true ]; then SSH_PASSWORD_AUTH=yes; else SSH_PASSWORD_AUTH=no; fi
  if [ "$SSH_PASSWORD_AUTH" = no ]; then
    log "SSH: $SSH_KEY_COUNT key(s) added; password logins over SSH disabled (keys only)."
  elif [ "$SSH_KEY_COUNT" -gt 0 ]; then
    log "SSH: $SSH_KEY_COUNT key(s) added; password logins over SSH still allowed."
  else
    log "SSH: no keys in config/authorized_keys; password logins over SSH allowed."
  fi
}

# Replace ${NAME} placeholders in a template with the values of these variables.
# Anything else that looks like a variable (e.g. $foo, ${foo:-bar}) is left alone.
TEMPLATE_VARS=(
  ADMIN_USER HOSTNAME_PREFIX LOCALE KEYBOARD_LAYOUT TIMEZONE
  SSH_ALLOW_PASSWORD SSH_PASSWORD_AUTH SSH_AUTHORIZED_KEYS PASSWORD_HASH K8S_VERSION
)
render_template() {
  local content name
  content="$(tr -d '\r' < "$1")"
  shopt -u patsub_replacement 2>/dev/null || true   # treat & in values literally
  for name in "${TEMPLATE_VARS[@]}"; do
    content="${content//"\${$name}"/"${!name}"}"
  done
  printf '%s\n' "$content"
}

# Validate a rendered cloud-config file, if cloud-init is installed in the builder.
validate_cloud_config() {
  if command -v cloud-init >/dev/null 2>&1; then
    log "Validating $(basename "$1") with cloud-init schema..."
    local out rc=0
    out="$(cloud-init schema --config-file "$1" 2>&1)" || rc=$?
    # Outside a real boot cloud-init warns that it has no datasource; that's expected here.
    grep -v -e 'DataSourceNone' -e 'datasource not detected' <<< "$out" || true
    [ "$rc" = 0 ] || die "$(basename "$1") failed cloud-init schema validation (see above)."
  fi
}

# download_verified <base-url> <filename>
# Downloads <filename> into downloads/ unless it's already there, then checks it
# against the release's SHA256SUMS. Set SKIP_CHECKSUM=true to skip the check
# (e.g. when building offline from a file you already trust).
download_verified() {
  local base="$1" file="$2" sums
  local path="$DOWNLOAD_DIR/$file"
  sums="$DOWNLOAD_DIR/SHA256SUMS-$(echo "$base" | tr -c 'A-Za-z0-9.\n' '_')"

  if [ -f "$path" ]; then
    log "Found $file in downloads/, skipping download."
  else
    log "Downloading $base/$file ..."
    wget --progress=dot:giga -c -O "$path.part" "$base/$file" || die "Download failed: $base/$file"
    mv "$path.part" "$path"
  fi

  if [ "${SKIP_CHECKSUM:-false}" = "true" ]; then
    warn "SKIP_CHECKSUM=true, not verifying $file."
    return
  fi
  if [ ! -s "$sums" ]; then
    wget -q -O "$sums" "$base/SHA256SUMS" || { rm -f "$sums"; die "Could not download $base/SHA256SUMS to verify $file. Set SKIP_CHECKSUM=true to build anyway."; }
  fi
  local expected
  expected="$(awk -v f="$file" '{n=$2; sub(/^\*/, "", n)} n==f {print $1}' "$sums")"
  [ -n "$expected" ] || die "$file is not listed in $base/SHA256SUMS. Check UBUNTU_VERSION."
  log "Verifying SHA-256 of $file ..."
  echo "$expected  $path" | sha256sum -c --quiet - \
    || die "$file does not match the official checksum. Delete downloads/$file and try again."
}

# If the container runs as root (no --user flag), hand outputs back to the host user.
fix_ownership() {
  if [ "$(id -u)" = 0 ] && [ -n "${HOST_UID:-}" ]; then
    chown "$HOST_UID:${HOST_GID:-$HOST_UID}" "$@"
  fi
}
