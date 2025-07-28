#!/usr/bin/env bash
# Arch post-install bootstrap for Hyprland + dotfiles + zsh/oh-my-zsh
# Run as root.

set -euo pipefail
IFS=$'\n\t'

### ────────────────────────────── Config ──────────────────────────────
USER_NAME="${USER_NAME:-${SUDO_USER:-${LOGNAME}}}"
: "${USER_NAME:?Could not determine USER_NAME. Set USER_NAME=youruser and re-run.}"

HOME_DIR="${HOME_DIR:-/home/${USER_NAME}}"
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/josiahmattern/dotfiles.git}"

ENABLE_TTY_AUTOLOGIN="${ENABLE_TTY_AUTOLOGIN:-yes}"

# AUR packages to build & install non-interactively:
AUR_FONT_PKG="${AUR_FONT_PKG:-nerd-fonts-sf-mono-ligatures}"
AUR_HELPER_PKG="${AUR_HELPER_PKG:-paru-bin}"   # Build & install so you can use paru later.

AUR_BUILD_DIR="${AUR_BUILD_DIR:-$HOME_DIR/.cache/aurbuild}"

### ───────────────────────────── Utilities ────────────────────────────
log()  { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }

as_user() {
  sudo -u "$USER_NAME" --preserve-env=HOME,PATH bash -lc "$*"
}

pkg_installed() { pacman -Qi "$1" &>/dev/null; }

ensure_dir_owner() {
  local path="$1"
  chown -R "$USER_NAME:$USER_NAME" "$path"
}

# Build an AUR package as the user, then install with pacman as root.
aur_build_install() {
  local pkg="$1"
  if pkg_installed "$pkg"; then
    log "AUR package '$pkg' already installed."
    return 0
  fi
  log "Building AUR package '$pkg' in $AUR_BUILD_DIR…"
  as_user "mkdir -p '$AUR_BUILD_DIR' && cd '$AUR_BUILD_DIR' && rm -rf '$pkg' \
           && git clone --depth=1 https://aur.archlinux.org/$pkg.git \
           && cd '$pkg' && makepkg -sf --noconfirm"
  # Find the built package file
  local built
  built=$(ls -t "$AUR_BUILD_DIR/$pkg"/*.pkg.tar.* 2>/dev/null | head -n1 || true)
  [[ -n "${built:-}" ]] || die "Failed to locate built package for $pkg."
  log "Installing $pkg -> $built"
  pacman -U --noconfirm --needed "$built"
}

# Append text to a file owned by the user (avoids permission funkiness)
append_user_file() {
  local file="$1"
  shift
  as_user "mkdir -p \"\$(dirname \"$file\")\" && touch \"$file\" && cat >> \"$file\" <<'EOF'
$*
EOF"
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
  networkmanager neovim vim zsh bash-completion \
  git-credential-libsecret libsecret

# Let git store HTTPS creds if you use them occasionally
if ! pkg_installed libsecret; then :
else
  as_user "git config --global credential.helper /usr/lib/git-core/git-credential-libsecret || true"
fi

### ─────────────────────── CPU microcode install ──────────────────────
CPU_VENDOR="$(lscpu | awk -F: '/Vendor ID/ {print tolower($2)}' | tr -d '[:space:]')"
log "Detected CPU vendor: ${CPU_VENDOR:-unknown}"

case "$CPU_VENDOR" in
  *intel*) pacman -S --noconfirm --needed intel-ucode ;;
  *amd*)   pacman -S --noconfirm --needed amd-ucode ;;
  *)       warn "Unable to detect CPU vendor; skipping microcode." ;;
esac

### ───────────────────── GPU drivers (Wayland-friendly) ───────────────
log "Detecting GPU and installing drivers…"
if lspci -nnk | grep -iE 'vga|3d|display' | grep -qi nvidia; then
  pacman -S --noconfirm --needed nvidia nvidia-utils nvidia-settings
  log "Configured NVIDIA stack."
elif lspci -nnk | grep -iE 'vga|3d|display' | grep -qi 'intel'; then
  pacman -S --noconfirm --needed mesa vulkan-intel libva-intel-driver intel-media-driver
  log "Configured Intel stack (modesetting + mesa)."
elif lspci -nnk | grep -iE 'vga|3d|display' | grep -qi 'amd|ati|radeon'; then
  pacman -S --noconfirm --needed mesa vulkan-radeon libva-mesa-driver
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
  xorg-xwayland \
  alacritty kitty \
  pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack \
  wl-clipboard grim slurp \
  brightnessctl playerctl \
  ttf-nerd-fonts-symbols ttf-jetbrains-mono ttf-fira-code

# NOTE: Do NOT install elogind on Arch (systemd provides logind).

### ───────────────────────── NetworkManager ────────────────────────────
log "Enabling NetworkManager…"
pacman -S --noconfirm --needed networkmanager
systemctl enable --now NetworkManager

### ───────────────────── Zsh + Oh My Zsh (non-interactive) ────────────
log "Setting default shell to zsh for ${USER_NAME}…"
chsh -s /bin/zsh "$USER_NAME" || warn "chsh failed; continuing."

# Install Oh My Zsh without touching .zshrc (your dotfiles will provide it)
if [[ ! -d "${HOME_DIR}/.oh-my-zsh" ]]; then
  log "Installing Oh My Zsh (no .zshrc overwrite)…"
  as_user "git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git '${HOME_DIR}/.oh-my-zsh'"
  ensure_dir_owner "${HOME_DIR}/.oh-my-zsh"
else
  log "Oh My Zsh already present; updating…"
  as_user "cd '${HOME_DIR}/.oh-my-zsh' && git pull --ff-only || true"
fi

# Popular plugins (optional; remove if your dotfiles handle them)
pacman -S --noconfirm --needed zsh-autosuggestions zsh-syntax-highlighting

# Ensure your .zprofile triggers Hyprland on tty1; .zshrc comes from dotfiles.
ZPROFILE="${HOME_DIR}/.zprofile"
append_user_file "$ZPROFILE" '
# Auto-start Hyprland on first TTY
if [[ -z "$DISPLAY" && -z "$WAYLAND_DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
'

### ─────────────────────── AUR (build → install) ──────────────────────
log "Preparing AUR build dir $AUR_BUILD_DIR"
mkdir -p "$AUR_BUILD_DIR"
ensure_dir_owner "$AUR_BUILD_DIR"

# Install paru-bin so you can use paru later interactively
aur_build_install "$AUR_HELPER_PKG"

# Install your preferred font via AUR, non-interactively
aur_build_install "$AUR_FONT_PKG"

### ─────────────────────── Dotfiles via GNU Stow ──────────────────────
if [[ ! -d "${HOME_DIR}/dotfiles/.git" ]]; then
  log "Cloning dotfiles into ${HOME_DIR}/dotfiles…"
  as_user "git clone --depth=1 '${DOTFILES_REPO}' '${HOME_DIR}/dotfiles'"
else
  log "Dotfiles repo already present; pulling latest…"
  as_user "cd '${HOME_DIR}/dotfiles' && git pull --rebase --autostash || true"
fi
ensure_dir_owner "${HOME_DIR}/dotfiles"

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
fi

### ─────────────────────────── Final notes ────────────────────────────
log "Setup complete!"
echo " - User: ${USER_NAME}"
echo " - Home: ${HOME_DIR}"
echo " - Dotfiles: ${DOTFILES_REPO}"
echo " - Default shell: $(getent passwd "$USER_NAME" | cut -d: -f7)"
echo " - Reboot recommended to load microcode & GPU drivers."
