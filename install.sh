#!/usr/bin/env bash
# Arch post-install bootstrap for Hyprland + dotfiles
# Safe, idempotent, and tuned for Intel/AMD/NVIDIA.
# Run as root.

set -euo pipefail
IFS=$'\n\t'

### ────────────────────────────── Config ──────────────────────────────
# If running via sudo, prefer the invoking user.
USER_NAME="${USER_NAME:-${SUDO_USER:-${LOGNAME}}}"
: "${USER_NAME:?Could not determine USER_NAME. Set USER_NAME=youruser and re-run.}"

HOME_DIR="${HOME_DIR:-/home/${USER_NAME}}"
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/josiahmattern/dotfiles.git}"

# Hyprland autostart on first TTY?
ENABLE_TTY_AUTOLOGIN="${ENABLE_TTY_AUTOLOGIN:-yes}"

# Fonts: AUR package; requires AUR helper. Change if you prefer a repo font.
AUR_FONT_PKG="${AUR_FONT_PKG:-nerd-fonts-sf-mono-ligatures}"

### ───────────────────────────── Utilities ────────────────────────────
log() { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }

as_user() {
  sudo -u "$USER_NAME" --preserve-env=HOME,PATH bash -lc "$*"
}

pkg_installed() { pacman -Qi "$1" &>/dev/null; }
aur_helper() {
  if command -v paru &>/dev/null; then echo paru; return; fi
  if command -v yay  &>/dev/null; then echo yay;  return; fi
  echo ""
}

### ───────────────────────────── Preamble ─────────────────────────────
need_root
[[ -d "$HOME_DIR" ]] || die "Home dir $HOME_DIR not found."

log "Synchronizing pacman keys (if needed)…"
pacman-key --init &>/dev/null || true
pacman-key --populate archlinux &>/dev/null || true

### ─────────────────── Enable multilib & full update ──────────────────
if ! grep -Eq '^\[multilib\]' /etc/pacman.conf; then
  warn "multilib section missing in /etc/pacman.conf; adding."
  cat >>/etc/pacman.conf <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
else
  # Uncomment the multilib block
  sed -i '/^\[multilib\]/{:a;n;/^Include/!{s/^#//;ba}}' /etc/pacman.conf
fi

log "Updating system packages…"
pacman -Syyu --noconfirm

### ─────────────────────── Base toolchain & Git ───────────────────────
log "Installing base tools…"
pacman -S --noconfirm --needed \
  base-devel git stow curl wget unzip zip \
  networkmanager neovim vim zsh bash-completion

### ─────────────────────── CPU microcode install ──────────────────────
CPU_VENDOR="$(lscpu | awk -F: '/Vendor ID/ {print tolower($2)}' | tr -d '[:space:]')"
log "Detected CPU vendor: ${CPU_VENDOR:-unknown}"

case "$CPU_VENDOR" in
  *intel*)
    pacman -S --noconfirm --needed intel-ucode
    ;;
  *amd*)
    pacman -S --noconfirm --needed amd-ucode
    ;;
  *)
    warn "Unable to detect CPU vendor; skipping microcode."
    ;;
esac

### ───────────────────── GPU drivers (Wayland-friendly) ───────────────
log "Detecting GPU and installing drivers…"
if lspci -nnk | grep -iE 'vga|3d|display' | grep -qi nvidia; then
  # Stock kernel users can use nvidia; dkms variant works across kernels.
  pacman -S --noconfirm --needed nvidia nvidia-utils nvidia-settings
  # Vulkan/VAAPI helpers are provided via nvidia-utils.
  log "Configured NVIDIA stack (Wayland works with 555+)."
elif lspci -nnk | grep -iE 'vga|3d|display' | grep -qi 'intel'; then
  pacman -S --noconfirm --needed mesa vulkan-intel libva-intel-driver intel-media-driver
  # Avoid xf86-video-intel; modesetting is recommended per Arch Wiki.
  log "Configured Intel stack (modesetting + mesa)."
elif lspci -nnk | grep -iE 'vga|3d|display' | grep -qi 'amd|ati|radeon'; then
  pacman -S --noconfirm --needed mesa vulkan-radeon libva-mesa-driver
  # xf86-video-amdgpu optional; Wayland doesn't need it.
  log "Configured AMD stack."
else
  warn "No recognized GPU found; skipping driver install."
fi

### ─────────────────────── Wayland / Hyprland stack ───────────────────
log "Installing Hyprland and Wayland essentials…"
pacman -S --noconfirm --needed \
  hyprland waybar \
  swww hyprpaper hyprlock \
  mako wofi \
  xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-hyprland \
  wlroots xorg-xwayland \
  alacritty kitty \
  pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack \
  grim slurp wl-clipboard \
  brightnessctl playerctl \
  ttf-nerd-fonts-symbols ttf-jetbrains-mono ttf-fira-code

# NOTE: Do NOT install elogind on Arch (systemd provides logind).
# If you previously installed elogind, remove it before proceeding.

### ───────────────────────── NetworkManager ────────────────────────────
log "Enabling NetworkManager…"
pacman -S --noconfirm --needed networkmanager
systemctl enable --now NetworkManager

### ─────────────────────── AUR helper (paru/yay) ──────────────────────
HELPER="$(aur_helper)"
if [[ -z "$HELPER" ]]; then
  log "Bootstrapping paru (AUR helper)…"
  as_user "cd ~ && rm -rf paru-bin && git clone --depth=1 https://aur.archlinux.org/paru-bin.git"
  as_user "cd ~/paru-bin && makepkg -si --noconfirm"
  HELPER="paru"
else
  log "Using existing AUR helper: $HELPER"
fi

### ───────────────────────── Optional AUR bits ────────────────────────
log "Installing AUR font package: ${AUR_FONT_PKG}"
as_user "$HELPER -S --noconfirm --needed ${AUR_FONT_PKG}"

### ─────────────────────── Dotfiles via GNU Stow ──────────────────────
if [[ ! -d "${HOME_DIR}/.git" && ! -d "${HOME_DIR}/dotfiles/.git" ]]; then
  log "Cloning dotfiles into ${HOME_DIR}/dotfiles…"
  as_user "git clone --depth=1 '${DOTFILES_REPO}' '${HOME_DIR}/dotfiles'"
else
  log "Dotfiles repo already present; pulling latest…"
  as_user "cd '${HOME_DIR}/dotfiles' && git pull --rebase --autostash || true"
fi

log "Applying dotfiles with stow…"
as_user "cd '${HOME_DIR}/dotfiles' && stow --restow --verbose ."

### ────────────────────── Autologin & autostart ───────────────────────
if [[ "${ENABLE_TTY_AUTOLOGIN}" == "yes" ]]; then
  log "Configuring TTY autologin for ${USER_NAME} on tty1…"
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USER_NAME} --noclear %I \$TERM
EOF

  # Autostart Hyprland on TTY1:
  SHELL_BIN="$(getent passwd "$USER_NAME" | cut -d: -f7)"
  # zsh users: .zprofile. bash users: .bash_profile
  if [[ "$SHELL_BIN" == *zsh ]]; then
    PROFILE_FILE="${HOME_DIR}/.zprofile"
    as_user "touch '$PROFILE_FILE'"
    if ! grep -q 'exec Hyprland' "$PROFILE_FILE" 2>/dev/null; then
      cat >>"$PROFILE_FILE" <<'EOF'

# Auto-start Hyprland on first TTY
if [[ -z "$DISPLAY" && -z "$WAYLAND_DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOF
    fi
  else
    PROFILE_FILE="${HOME_DIR}/.bash_profile"
    as_user "touch '$PROFILE_FILE'"
    if ! grep -q 'exec Hyprland' "$PROFILE_FILE" 2>/dev/null; then
      cat >>"$PROFILE_FILE" <<'EOF'

# Auto-start Hyprland on first TTY
if [[ -z "$DISPLAY" && -z "$WAYLAND_DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOF
    fi
  fi
fi

### ─────────────────────────── Final notes ────────────────────────────
log "Setup complete!"
echo " - User: ${USER_NAME}"
echo " - Home: ${HOME_DIR}"
echo " - Dotfiles: ${DOTFILES_REPO}"
echo " - Reboot recommended to load microcode & GPU drivers."
