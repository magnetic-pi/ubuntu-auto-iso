# Ubuntu Auto Image Builder

Builds prebaked Ubuntu images for repeatable, hands-off installs, from one shared configuration:

| Target | Output | How it works |
|---|---|---|
| `iso` | `output/ubuntu-26.04.1-autoinstall-amd64.iso` | x86-64 installer ISO. Boots straight into an unattended install driven by `autoinstall.yaml`. |
| `pi` | `output/ubuntu-26.04.1-autoconfig-arm64+raspi.img.xz` | Raspberry Pi disk image (Pi 3, 4, 5, 400, 500, CM3/4/5). Flash it to an SD card or SSD; cloud-init configures it on first boot. |
| `desktop` | `output/ubuntu-26.04.1-desktop-autoinstall-amd64.iso` | x86-64 Ubuntu Desktop installer ISO for local VMs. Same unattended install, with VM guest tools, everyday command-line tools and Docker. |

All targets currently use **Ubuntu 26.04.1 LTS**, and every machine gets a unique hostname derived from its MAC address on first boot.

- **Server ISO and Raspberry Pi:** set up as **Kubernetes nodes**: Docker, kubeadm, kubelet, kubectl, Helm, Ansible, containerd configured for Kubernetes, swap off and a firewall. Ready for `kubeadm init` or `kubeadm join`.
- **Desktop ISO:** a VM workstation with its own, separate first-boot setup: `vim`, `curl`, `wget`, `git`, `htop`, `tree`, `unzip`, `net-tools`, `ca-certificates`, `gnupg`, `lsb-release`, `software-properties-common`, `python3-pip`, `python3-setuptools`, `python3-wheel`, `ansible`, `ufw` (installed but left off), and Docker Engine with the Buildx and Compose plugins. No Kubernetes or Helm.

## Quick start

### 1. Set up the users (and SSH keys)

```bash
cp config/secrets.env.example config/secrets.env
# edit ADMIN_USER, ADMIN_PASSWORD and NOSSHPW_USER in config/secrets.env

# SSH public keys, one per line; use a different key for each user
cp ~/.ssh/id_ed25519.pub          config/authorized_keys           # for ADMIN_USER (ubuntu)
cp ~/.ssh/nosshpw_ed25519.pub     config/nosshpw_authorized_keys   # for nosshpw (server and Pi)
```

**Users.** The server ISO and the Raspberry Pi get two users; the desktop ISO gets only the first:

| User | Password | SSH keys | sudo |
|---|---|---|---|
| `ADMIN_USER` (default `ubuntu`, set in `secrets.env`) | `ADMIN_PASSWORD` from `secrets.env` | `config/authorized_keys` | asks for the password (desktop: no prompt, see `DESKTOP_SUDO_NOPASSWD`) |
| `NOSSHPW_USER` (default `nosshpw`, set in `secrets.env`) | none: it can only log in with its keys | `config/nosshpw_authorized_keys` | no prompt |

The two key files must hold different keys; the build stops if the same key is in both. Without any keys in `config/nosshpw_authorized_keys`, `nosshpw` can't log in at all (the build warns), but `ubuntu` can still switch to it with `sudo -iu nosshpw`. Set `NOSSHPW_USER=` (empty) in `secrets.env` for no second user.

**SSH passwords.** Only `ADMIN_USER` has a password. When `config/authorized_keys` has at least one key, the **server ISO and Raspberry Pi** turn off SSH password logins (`PasswordAuthentication no`), so `ubuntu` logs in over SSH with its key; this blocks password brute-forcing. Its password still works at the console. The desktop ISO keeps SSH passwords, since it's a local VM. Change this with `SSH_ALLOW_PASSWORD` in `config/build.env`: `auto` (default, as above), `false` (keys only on every image) or `true` (always allow passwords). On the server and Pi, the setting goes into `/etc/ssh/sshd_config` and into `/etc/ssh/sshd_config.d/01-password-auth.conf`; sshd reads the `sshd_config.d` files first and uses the first value it finds, so the `01-` file wins over anything else there.

The build checks both key files: it refuses a private key pasted by mistake and skips lines that aren't public keys, with a warning.

You don't need to generate a hash yourself: the build runs `ADMIN_PASSWORD` through `openssl passwd -6` (SHA-512, random salt) and only the hash goes into the images. If you'd rather not keep the plain password on disk, you can set `PASSWORD_HASH` to the output of `openssl passwd -6` instead; if both are set, `ADMIN_PASSWORD` wins. The username can't be a system name such as `admin`, `root` or `sudo`, because the Ubuntu installer refuses those; the build checks this for you. `secrets.env` and the key files are ignored by git, so your credentials stay out of the repository.

### 2. Build

```bash
./build.sh            # all three images
./build.sh server     # only the server ISO
./build.sh pi         # only the Raspberry Pi image
./build.sh desktop    # only the desktop ISO
```

All you need installed is Docker. `build.sh` builds the builder container image for you (a few minutes the first time, then instant unless `Dockerfile` or `scripts/` changed) and runs it as your user, so the files it creates belong to you.

The official Ubuntu images are downloaded into `downloads/` the first time (about 3 GB for the server ISO, 1.3 GB for the Pi image and 6 GB for the desktop ISO) and reused after that. Every download is checked against Ubuntu's published SHA-256 checksums. Results go to `output/`.

## Using the images

**Server and desktop ISOs:** attach the ISO to a VM as a CD-ROM, or write it to a USB stick (for example with `dd`, Rufus, or balenaEtcher) and boot from it.

> ⚠️ By default the ISO's first boot entry, **"Autoinstall Ubuntu Server"** (or **"Autoinstall Ubuntu Desktop"**), erases the largest disk *without asking* once the boot menu times out. Don't leave the stick plugged into a machine you care about. Set `ISO_REQUIRE_CONFIRMATION=true` in `config/build.env` to have the installer ask first.

The boot menu waits `ISO_BOOT_TIMEOUT` seconds (default 5) before starting. For VMs, set `ISO_BOOT_TIMEOUT=0` to go straight into the install, or try it for one build with `ISO_BOOT_TIMEOUT=0 ./build.sh desktop`.

**Desktop in a KVM VM:** give it at least 4 GB of RAM, 2 CPUs and a 30 GB disk, and attach the ISO as a CD-ROM so the boot menu is used:

```bash
virt-install --name ubuntu-desktop --memory 8192 --vcpus 4 --disk size=40,bus=virtio \
  --cdrom "$(pwd)/output/ubuntu-26.04.1-desktop-autoinstall-amd64.iso" \
  --os-variant ubuntu24.04 --network network=default --graphics spice --video virtio --boot uefi
```

After the install it reboots to the login screen, without GNOME's welcome wizard. `qemu-guest-agent` and `spice-vdagent` are installed, so `virsh domifaddr ubuntu-desktop` shows the VM's IP address, and clipboard sharing and automatic screen resizing work in virt-manager.

**Raspberry Pi:** flash `output/ubuntu-26.04.1-autoconfig-arm64+raspi.img.xz` with Raspberry Pi Imager ("Use custom"), or:

```bash
xzcat output/ubuntu-26.04.1-autoconfig-arm64+raspi.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Skip Raspberry Pi Imager's "OS customisation" step: it replaces the image's cloud-init config with its own. The Pi needs a network connection on first boot to install packages (wired Ethernet works out of the box; for Wi-Fi, see `config/pi-network-config.yaml` below).

**After first boot (all):** setup continues in the background for a few minutes after you can log in. Check progress with:

```bash
cloud-init status --long             # "status: done" when finished
less /var/log/provision-node.log     # server and Pi: Docker / Kubernetes / Helm install log
less /var/log/setup-desktop.log      # desktop: tools and Docker install log
```

The server and Pi nodes are then ready for `kubeadm init` or `kubeadm join`. On all three, the `docker` group is created and your user added to it during the install, so `docker` works without `sudo` from your first login once the first-boot setup has finished.

## Configuration

| File | What it controls |
|---|---|
| `config/build.env` | Ubuntu version, hostname prefixes, locale, timezone, SSH password logins, the key-only user's name, desktop passwordless sudo, Kubernetes version, ISO confirmation and boot-menu timeout, Pi kernel arguments |
| `config/secrets.env` | Usernames and password: `ADMIN_USER`, `ADMIN_PASSWORD` (or `PASSWORD_HASH`) and `NOSSHPW_USER` (not in git) |
| `config/authorized_keys` | SSH public keys for `ADMIN_USER`, one per line (not in git). With keys present, the server ISO and Pi allow SSH logins with keys only |
| `config/nosshpw_authorized_keys` | SSH public keys for the key-only `NOSSHPW_USER` on the server ISO and Pi, one per line (not in git) |
| `config/common-user-data.yaml` | First-boot setup **shared by the server ISO and the Pi**: packages, Docker, Kubernetes, Helm, firewall, hostname |
| `config/iso-autoinstall.yaml` | Server ISO installer settings: disk layout, keyboard, user |
| `config/desktop-autoinstall.yaml` | Desktop ISO installer settings: disk layout, keyboard, user, VM guest tools |
| `config/desktop-user-data.yaml` | Desktop ISO first-boot setup: the tool list and Docker install (edit the `tools=(...)` list to change packages) |
| `config/pi-user-data.yaml` | Pi-only settings: user and SSH |
| `config/pi-network-config.yaml` | *Optional, not in git.* Copy from `pi-network-config.yaml.example`. If present, replaces the Pi's [netplan network config](https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v2.html), e.g. for Wi-Fi or a static IP |

The YAML files are templates: `${ADMIN_USER}`, `${K8S_VERSION}` and similar placeholders are filled in from `build.env` and `secrets.env` at build time. Any `build.env` setting can also be overridden for a single run, for example `K8S_VERSION=v1.36 ./build.sh server`. When `cloud-init` is available in the builder (it is in the Docker image), the generated configs are validated before the slow image steps, so typos fail fast.

### Upgrading Ubuntu

Change `UBUNTU_VERSION` in `config/build.env`. All targets follow it. The ISO build reads the boot layout from the official ISO instead of hardcoding it, so it keeps working across releases. When a point release is superseded, Ubuntu moves it to `old-releases.ubuntu.com`; point `ISO_BASE_URL` / `PI_BASE_URL` there to keep building it.

### Raspberry Pi notes

- `PI_KERNEL_ARGS` (default `cgroup_enable=memory cgroup_memory=1`) is appended to the kernel command line, because Raspberry Pi kernels disable the memory cgroup that kubelet needs. Ubuntu 25.10 and later keep the command line in `current/cmdline.txt` on the boot partition; older releases keep it in `cmdline.txt`. The build handles both.
- The build only edits the image's FAT boot partition (using mtools), so it doesn't need loop devices or a `--privileged` container, and it works on x86 hosts.

## Project layout

```
build.sh                 run this: builds the container image, then the images [server|pi|desktop|all]
Dockerfile               the builder container (xorriso, mtools, xz, cloud-init, openssl)
scripts/entrypoint.sh    entry point inside the container
scripts/lib.sh           config loading, templating, verified downloads
scripts/build-iso.sh     server and desktop ISO targets
scripts/build-pi.sh      Raspberry Pi target
config/                  everything you're expected to edit
downloads/  output/      created on first run, ignored by git
```
