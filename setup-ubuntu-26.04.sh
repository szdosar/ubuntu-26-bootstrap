#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly EXPECTED_OS_ID="ubuntu"
readonly EXPECTED_OS_VERSION="26.04"
readonly FONT_REPO="szdosar/private-font-assets"
readonly FONT_RELEASE_TAG="yahei-1"
readonly FONT_ASSET="microsoft-yahei-user-fonts.tar.gz"
readonly FONT_ASSET_SHA256="3739ca437f3774741bc25dbcdf1f3e3c6c4d2fcf98e0ef47d4e0606eae3ff409"
readonly RIME_ICE_REF="75e6572bebc05b49021e842949ce947882e3e4b2"
readonly RIME_ICE_SHA256="8e0c74682e2bddf12886d0cbc20747c7ddf86a2c63015241df7637f48d04c39b"
readonly ONLYOFFICE_VERSION="9.4.0-129"
readonly ONLYOFFICE_SHA256="4271434e81be42b1559fd989d24bf6d413482f278dc6a5e328202a4fc1a18649"
readonly ONLYOFFICE_URL="https://github.com/ONLYOFFICE/DesktopEditors/releases/download/v9.4.0/onlyoffice-desktopeditors_amd64.deb"

font_dir=""
git_name="szdosar"
git_email="6078432+szdosar@users.noreply.github.com"
dry_run=false
skip_fonts=false
skip_rime=false
skip_onlyoffice=false
skip_gh_login=false
skip_ssh=false
work_dir=""
backup_dir=""
rime_existing_compatible=false

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Reproduce the validated Ubuntu 26.04 desktop setup from this repository.

Options:
  --font-dir PATH        Use local msyh.ttc, msyhbd.ttc and msyhl.ttc instead
                         of downloading the private GitHub Release
  --git-name NAME        Global Git author name (default: $git_name)
  --git-email EMAIL      Global Git author email (default: $git_email)
  --skip-fonts           Do not install or select Microsoft YaHei
  --skip-rime            Do not install IBus Rime or Rime Ice
  --skip-onlyoffice      Do not install ONLYOFFICE Desktop Editors
  --skip-gh-login        Install GitHub CLI but do not start interactive login
  --skip-ssh             Do not install or enable OpenSSH Server
  --dry-run              Validate prerequisites and show the package plan only
  -h, --help             Show this help

Run this script as your normal desktop user, not with sudo. It requests sudo
once for package and service changes. On a new system, GitHub browser login is
performed before the private font asset is downloaded.
EOF
}

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --font-dir)
      (($# >= 2)) || die "--font-dir requires a path"
      font_dir="$2"
      shift 2
      ;;
    --git-name)
      (($# >= 2)) || die "--git-name requires a value"
      git_name="$2"
      shift 2
      ;;
    --git-email)
      (($# >= 2)) || die "--git-email requires a value"
      git_email="$2"
      shift 2
      ;;
    --skip-fonts) skip_fonts=true; shift ;;
    --skip-rime) skip_rime=true; shift ;;
    --skip-onlyoffice) skip_onlyoffice=true; shift ;;
    --skip-gh-login) skip_gh_login=true; shift ;;
    --skip-ssh) skip_ssh=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ $EUID -ne 0 ]] || die "run as the desktop user, not as root or with sudo"
[[ -r /etc/os-release ]] || die "/etc/os-release is unavailable"
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == "$EXPECTED_OS_ID" ]] || die "this script supports Ubuntu only"
[[ ${VERSION_ID:-} == "$EXPECTED_OS_VERSION" ]] || \
  die "expected Ubuntu $EXPECTED_OS_VERSION, found ${PRETTY_NAME:-unknown}"
[[ $(dpkg --print-architecture) == amd64 ]] || die "this script currently supports amd64 only"
[[ -n ${HOME:-} && -d $HOME ]] || die "a valid user home directory is required"
[[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || \
  die "run from a terminal inside the logged-in GNOME desktop session"
command -v gsettings >/dev/null || die "gsettings is required"
command -v apt-get >/dev/null || die "apt-get is required"
command -v dpkg-deb >/dev/null || die "dpkg-deb is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
command -v tar >/dev/null || die "tar is required"
command -v xdg-mime >/dev/null || die "xdg-mime is required"

validate_fonts() {
  local filename signature family
  for filename in msyh.ttc msyhbd.ttc msyhl.ttc; do
    [[ -f "$font_dir/$filename" && -r "$font_dir/$filename" ]] || \
      die "missing readable font: $font_dir/$filename"
    signature="$(od -An -tx1 -N4 "$font_dir/$filename" | tr -d '[:space:]')"
    [[ $signature == 74746366 ]] || \
      die "$font_dir/$filename is not a readable TTC file (Windows WOF placeholders cannot be used)"
  done
  if command -v fc-scan >/dev/null; then
    family="$(fc-scan --format '%{family}\n' "$font_dir/msyh.ttc" 2>/dev/null || true)"
    grep -q 'Microsoft YaHei' <<<"$family" || die "msyh.ttc does not contain Microsoft YaHei"
  fi
}

validate_rime_target() {
  local rime_dir="$HOME/.config/ibus/rime" installed_ref origin head_ref
  if [[ -d "$rime_dir" && -n $(find "$rime_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    if [[ -f "$rime_dir/.ubuntu-system-rime-ref" ]]; then
      installed_ref="$(<"$rime_dir/.ubuntu-system-rime-ref")"
      [[ $installed_ref == "$RIME_ICE_REF" ]] || \
        die "$rime_dir was installed from a different Rime Ice revision: $installed_ref"
      return
    fi

    # Accept the exact Git checkout used during the original manual setup. This
    # lets the script adopt that installation without overwriting learned data.
    if [[ -d "$rime_dir/.git" ]] && command -v git >/dev/null; then
      origin="$(git -C "$rime_dir" config --get remote.origin.url 2>/dev/null || true)"
      head_ref="$(git -C "$rime_dir" rev-parse HEAD 2>/dev/null || true)"
      if [[ $origin =~ ^(https://github.com/|git@github.com:|ssh://git@github.com/)iDvel/rime-ice(\.git)?$ ]] && \
         [[ $head_ref == "$RIME_ICE_REF" ]]; then
        rime_existing_compatible=true
        return
      fi
    fi

    die "$rime_dir already contains unmanaged data; back it up and use --skip-rime, or move it aside"
  fi
}

if ! $skip_fonts && [[ -n $font_dir ]]; then
  validate_fonts
fi
if ! $skip_rime; then
  validate_rime_target
fi

packages=(ca-certificates wget git fontconfig mpv gh)
if ! $skip_rime; then
  packages+=(ibus ibus-libpinyin ibus-rime)
fi
if ! $skip_ssh; then
  packages+=(openssh-server)
fi

log "Preflight passed for ${PRETTY_NAME} ($(dpkg --print-architecture))"
if ! $skip_fonts && [[ -z $font_dir ]]; then
  printf 'Font source: private GitHub Release %s@%s/%s\n' \
    "$FONT_REPO" "$FONT_RELEASE_TAG" "$FONT_ASSET"
elif ! $skip_fonts; then
  printf 'Font source: local directory %s\n' "$font_dir"
else
  printf 'Font source: skipped\n'
fi
printf 'Git identity: %s <%s>\n' "$git_name" "$git_email"
printf 'APT packages: %s\n' "${packages[*]}"

if $dry_run; then
  log "APT simulation"
  apt-get -s install "${packages[@]}"
  if ! $skip_onlyoffice; then
    log "Pinned ONLYOFFICE artifact check"
    wget --spider -q "$ONLYOFFICE_URL" || die "ONLYOFFICE download is unavailable"
    printf 'Would verify ONLYOFFICE %s with SHA-256 %s\n' \
      "$ONLYOFFICE_VERSION" "$ONLYOFFICE_SHA256"
  fi
  if ! $skip_rime; then
    printf 'Would install Rime Ice commit %s with archive SHA-256 %s\n' \
      "$RIME_ICE_REF" "$RIME_ICE_SHA256"
  fi
  if ! $skip_fonts && [[ -z $font_dir ]]; then
    if command -v gh >/dev/null && gh auth status --hostname github.com >/dev/null 2>&1; then
      gh release view "$FONT_RELEASE_TAG" --repo "$FONT_REPO" >/dev/null || \
        die "private font Release is unavailable to the authenticated GitHub account"
    else
      printf 'Private font asset access will be checked after GitHub login.\n'
    fi
    printf 'Would verify font archive with SHA-256 %s\n' "$FONT_ASSET_SHA256"
  fi
  log "Dry run complete; no files, packages or settings were changed"
  exit 0
fi

log "Requesting administrator authorization"
sudo -v

state_root="${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-system"
backup_dir="$state_root/backups/bootstrap-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$backup_dir/user-files"
chmod 700 "$state_root" "$state_root/backups" "$backup_dir" "$backup_dir/user-files"

backup_if_present() {
  local source_path="$1"
  local destination_name="$2"
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    cp -a -- "$source_path" "$backup_dir/user-files/$destination_name"
  fi
}

log "Backing up current state to $backup_dir"
{
  printf 'Captured: %s\n' "$(date --iso-8601=seconds)"
  printf 'OS: %s\n' "$PRETTY_NAME"
  printf 'User: %s (uid %s)\n' "$(id -un)" "$(id -u)"
  printf 'Desktop: %s\n' "${XDG_CURRENT_DESKTOP:-unknown}"
  printf 'Session: %s\n' "${XDG_SESSION_TYPE:-unknown}"
  printf '\nGNOME fonts before change:\n'
  gsettings get org.gnome.desktop.interface font-name 2>/dev/null || true
  gsettings get org.gnome.desktop.interface document-font-name 2>/dev/null || true
  gsettings get org.gnome.desktop.interface monospace-font-name 2>/dev/null || true
  gsettings get org.gnome.desktop.wm.preferences titlebar-font 2>/dev/null || true
  printf '\nGNOME input sources before change:\n'
  gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || true
  gsettings get org.gnome.desktop.input-sources mru-sources 2>/dev/null || true
  printf '\nGit identity before change:\n'
  git config --global --get user.name 2>/dev/null || printf '<unset>\n'
  git config --global --get user.email 2>/dev/null || printf '<unset>\n'
  printf '\nDefault handlers before change:\n'
  for mime in \
    application/msword \
    application/vnd.openxmlformats-officedocument.wordprocessingml.document \
    application/vnd.ms-excel \
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet \
    application/vnd.ms-powerpoint \
    application/vnd.openxmlformats-officedocument.presentationml.presentation \
    application/pdf \
    video/mp4 video/x-matroska video/webm video/x-msvideo; do
    printf '%s=%s\n' "$mime" "$(xdg-mime query default "$mime" 2>/dev/null || true)"
  done
  printf '\nRelevant packages before change:\n'
  dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' \
    mpv gh ibus-rime openssh-server onlyoffice-desktopeditors 2>/dev/null || true
  printf '\nUFW state before change:\n'
  sudo env LC_ALL=C ufw status verbose 2>/dev/null || true
  printf '\nSSH public host-key fingerprints before change:\n'
  for public_key in /etc/ssh/ssh_host_*_key.pub; do
    [[ -f "$public_key" ]] && ssh-keygen -lf "$public_key"
  done
} >"$backup_dir/state-before.txt"

backup_if_present "$HOME/.config/fontconfig/conf.d/99-microsoft-yahei.conf" fontconfig-99-microsoft-yahei.conf
backup_if_present "$HOME/.config/mpv/mpv.conf" mpv.conf
backup_if_present "$HOME/.config/mimeapps.list" mimeapps.list
backup_if_present "$HOME/.local/share/applications/mimeapps.list" local-mimeapps.list

if [[ -d "$HOME/.cache/ibus/libpinyin" ]]; then
  tar -C "$HOME/.cache/ibus" -czf "$backup_dir/libpinyin-user-data.tar.gz" libpinyin
fi
if [[ -d "$HOME/.config/ibus/rime" ]]; then
  tar -C "$HOME/.config/ibus" -czf "$backup_dir/rime-user-data.tar.gz" rime
fi
if [[ -d "$HOME/.local/share/fonts/microsoft-yahei" ]]; then
  tar -C "$HOME/.local/share/fonts" -czf "$backup_dir/microsoft-yahei-fonts.tar.gz" microsoft-yahei
fi
if [[ -d "$HOME/.config/onlyoffice" || -d "$HOME/.local/share/onlyoffice" ]]; then
  tar -C "$HOME" -czf "$backup_dir/onlyoffice-user-data.tar.gz" \
    --ignore-failed-read .config/onlyoffice .local/share/onlyoffice 2>/dev/null || true
fi

if [[ -f /etc/ssh/sshd_config || -d /etc/ssh/sshd_config.d ]]; then
  sudo tar -C /etc/ssh -czf "$backup_dir/sshd-config.tar.gz" \
    --ignore-failed-read sshd_config sshd_config.d 2>/dev/null || true
  sudo chown "$(id -u):$(id -g)" "$backup_dir/sshd-config.tar.gz" 2>/dev/null || true
fi

cat >"$backup_dir/README.txt" <<EOF
This snapshot was created before $SCRIPT_NAME changed the system.

It intentionally excludes GitHub tokens and SSH private host keys. Restore
individual files only after reviewing state-before.txt. Package removal is not
automated because dependencies may be shared with software installed later.
EOF

work_dir="$(mktemp -d /tmp/ubuntu-system-bootstrap.XXXXXX)"

log "Updating Ubuntu package metadata"
sudo apt-get update

log "Installing Ubuntu repository packages"
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

need_gh_auth=false
if ! $skip_gh_login; then
  need_gh_auth=true
elif ! $skip_fonts && [[ -z $font_dir ]]; then
  need_gh_auth=true
fi

if $need_gh_auth; then
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    log "GitHub CLI is already authenticated"
  elif $skip_gh_login; then
    die "the private font Release requires GitHub authentication; log in first or use --font-dir"
  else
    log "Starting GitHub browser login before private asset access"
    gh auth login --hostname github.com --git-protocol https --web
  fi
  gh auth setup-git --hostname github.com
fi

if ! $skip_fonts && [[ -z $font_dir ]]; then
  log "Downloading Microsoft YaHei from the private GitHub Release"
  font_download_dir="$work_dir/font-download"
  mkdir -p "$font_download_dir"
  gh release download "$FONT_RELEASE_TAG" \
    --repo "$FONT_REPO" \
    --pattern "$FONT_ASSET" \
    --dir "$font_download_dir"
  font_archive="$font_download_dir/$FONT_ASSET"
  [[ -f $font_archive ]] || die "GitHub did not download the expected font asset"
  printf '%s  %s\n' "$FONT_ASSET_SHA256" "$font_archive" | sha256sum -c -

  archive_listing="$(tar -tzf "$font_archive")"
  expected_listing=$'microsoft-yahei/\nmicrosoft-yahei/msyh.ttc\nmicrosoft-yahei/msyhbd.ttc\nmicrosoft-yahei/msyhl.ttc'
  [[ $archive_listing == "$expected_listing" ]] || die "font archive contains unexpected paths"
  tar -xzf "$font_archive" -C "$font_download_dir"
  font_dir="$font_download_dir/microsoft-yahei"
  validate_fonts
fi

if ! $skip_fonts; then
  log "Installing Microsoft YaHei for user $(id -un)"
  mkdir -p "$HOME/.local/share/fonts/microsoft-yahei" "$HOME/.config/fontconfig/conf.d"
  install -m 0644 "$font_dir/msyh.ttc" "$HOME/.local/share/fonts/microsoft-yahei/msyh.ttc"
  install -m 0644 "$font_dir/msyhbd.ttc" "$HOME/.local/share/fonts/microsoft-yahei/msyhbd.ttc"
  install -m 0644 "$font_dir/msyhl.ttc" "$HOME/.local/share/fonts/microsoft-yahei/msyhl.ttc"
  cat >"$work_dir/99-microsoft-yahei.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias binding="strong">
    <family>sans-serif</family>
    <prefer><family>Microsoft YaHei</family></prefer>
  </alias>
  <alias binding="strong">
    <family>system-ui</family>
    <prefer>
      <family>Microsoft YaHei UI</family>
      <family>Microsoft YaHei</family>
    </prefer>
  </alias>
  <match target="pattern">
    <test name="family" qual="any"><string>emoji</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>Noto Color Emoji</string>
    </edit>
  </match>
</fontconfig>
EOF
  install -m 0644 "$work_dir/99-microsoft-yahei.conf" \
    "$HOME/.config/fontconfig/conf.d/99-microsoft-yahei.conf"
  fc-cache -f
  gsettings set org.gnome.desktop.interface font-name 'Microsoft YaHei UI 11'
  gsettings set org.gnome.desktop.interface document-font-name 'Microsoft YaHei 11'
  gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Microsoft YaHei UI Bold 11'
  # A proportional UI font is deliberately not used for terminals and code.
  gsettings set org.gnome.desktop.interface monospace-font-name 'Ubuntu Sans Mono 11'
fi

if ! $skip_rime; then
  log "Installing pinned Rime Ice dictionary"
  rime_dir="$HOME/.config/ibus/rime"
  if $rime_existing_compatible; then
    printf '%s\n' "$RIME_ICE_REF" >"$rime_dir/.ubuntu-system-rime-ref"
  elif [[ ! -f "$rime_dir/.ubuntu-system-rime-ref" ]]; then
    rime_archive="$work_dir/rime-ice.tar.gz"
    wget -q --show-progress -O "$rime_archive" \
      "https://github.com/iDvel/rime-ice/archive/$RIME_ICE_REF.tar.gz"
    printf '%s  %s\n' "$RIME_ICE_SHA256" "$rime_archive" | sha256sum -c -
    mkdir -p "$work_dir/rime-extract" "$rime_dir"
    tar -xzf "$rime_archive" -C "$work_dir/rime-extract"
    cp -a "$work_dir/rime-extract/rime-ice-$RIME_ICE_REF/." "$rime_dir/"
    printf '%s\n' "$RIME_ICE_REF" >"$rime_dir/.ubuntu-system-rime-ref"
  fi
  rime_deployer --build "$rime_dir" /usr/share/rime-data "$rime_dir/build"
  gsettings set org.gnome.desktop.input-sources sources \
    "[('xkb', 'us'), ('ibus', 'rime'), ('ibus', 'libpinyin')]"
  gsettings set org.gnome.desktop.input-sources mru-sources \
    "[('ibus', 'rime'), ('ibus', 'libpinyin'), ('xkb', 'us')]"
  ibus restart >/dev/null 2>&1 || warn "IBus will pick up Rime after the next login"
fi

if ! $skip_onlyoffice; then
  installed_onlyoffice="$(dpkg-query -W -f='${Version}' onlyoffice-desktopeditors 2>/dev/null || true)"
  if [[ -z "$installed_onlyoffice" ]] || \
     dpkg --compare-versions "$installed_onlyoffice" lt "$ONLYOFFICE_VERSION"; then
    log "Downloading pinned ONLYOFFICE Desktop Editors $ONLYOFFICE_VERSION"
    onlyoffice_deb="$work_dir/onlyoffice-desktopeditors_amd64.deb"
    wget -q --show-progress -O "$onlyoffice_deb" "$ONLYOFFICE_URL"
    printf '%s  %s\n' "$ONLYOFFICE_SHA256" "$onlyoffice_deb" | sha256sum -c -
    [[ $(dpkg-deb -f "$onlyoffice_deb" Package) == onlyoffice-desktopeditors ]] || \
      die "unexpected ONLYOFFICE package name"
    [[ $(dpkg-deb -f "$onlyoffice_deb" Version) == "$ONLYOFFICE_VERSION" ]] || \
      die "unexpected ONLYOFFICE package version"
    [[ $(dpkg-deb -f "$onlyoffice_deb" Architecture) == amd64 ]] || \
      die "unexpected ONLYOFFICE package architecture"
    LC_ALL=C apt-get -s --no-install-recommends install "$onlyoffice_deb" \
      | tee "$backup_dir/onlyoffice-apt-simulation.txt"
    if grep -q '^Remv ' "$backup_dir/onlyoffice-apt-simulation.txt"; then
      die "ONLYOFFICE simulation would remove packages"
    fi
    sudo env DEBIAN_FRONTEND=noninteractive apt-get --no-install-recommends \
      install -y "$onlyoffice_deb"
  else
    log "ONLYOFFICE $installed_onlyoffice is already installed; leaving it in place"
  fi

  office_desktop="onlyoffice-desktopeditors.desktop"
  for mime in \
    application/msword \
    application/vnd.openxmlformats-officedocument.wordprocessingml.document \
    application/vnd.ms-excel \
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet \
    application/vnd.ms-powerpoint \
    application/vnd.openxmlformats-officedocument.presentationml.presentation; do
    xdg-mime default "$office_desktop" "$mime"
  done
fi

log "Configuring MPV resume playback"
mkdir -p "$HOME/.config/mpv"
mpv_config="$HOME/.config/mpv/mpv.conf"
touch "$mpv_config"
mpv_tmp="$work_dir/mpv.conf"
awk '
  $0 == "# BEGIN ubuntu-system: resume playback" { managed = 1; next }
  $0 == "# END ubuntu-system: resume playback" { managed = 0; next }
  !managed { print }
' "$mpv_config" >"$mpv_tmp"
cat >>"$mpv_tmp" <<'EOF'

# BEGIN ubuntu-system: resume playback
# Save the position on every normal exit and restore it for the same media.
save-position-on-quit=yes
resume-playback=yes
# END ubuntu-system: resume playback
EOF
install -m 0644 "$mpv_tmp" "$mpv_config"

for mime in \
  video/mp4 video/x-matroska video/webm video/x-msvideo video/mpeg \
  video/quicktime video/x-ms-wmv video/x-flv video/ogg video/3gpp; do
  xdg-mime default mpv.desktop "$mime"
done

log "Configuring global Git identity"
git config --global user.name "$git_name"
git config --global user.email "$git_email"

if ! $skip_ssh; then
  log "Enabling OpenSSH socket activation"
  sudo systemctl enable --now ssh.socket
  sudo /usr/sbin/sshd -t
  if sudo env LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
    sudo ufw allow OpenSSH
  else
    warn "UFW is inactive; SSH port 22 is reachable on every routed interface"
  fi
fi

log "Verifying the resulting configuration"
if ! $skip_fonts; then
  fc-match sans-serif | grep -q 'msyh.ttc' || die "Fontconfig did not select Microsoft YaHei"
  [[ $(gsettings get org.gnome.desktop.interface font-name) == "'Microsoft YaHei UI 11'" ]] || \
    die "GNOME interface font verification failed"
fi
if ! $skip_rime; then
  ibus list-engine 2>/dev/null | grep -q 'rime - Rime' || die "IBus did not register Rime"
  [[ -s "$HOME/.config/ibus/rime/build/rime_ice.table.bin" ]] || die "Rime Ice build is missing"
fi
mpv --version >/dev/null
mpv --list-options 2>/dev/null | grep -q -- '--save-position-on-quit' || \
  die "MPV resume option is unavailable"
gh --version >/dev/null
if ! $skip_onlyoffice; then
  dpkg -V onlyoffice-desktopeditors
  [[ $(xdg-mime query default application/vnd.openxmlformats-officedocument.wordprocessingml.document) == \
    onlyoffice-desktopeditors.desktop ]] || die "ONLYOFFICE MIME association failed"
fi
if ! $skip_ssh; then
  systemctl is-enabled --quiet ssh.socket || die "ssh.socket is not enabled"
  systemctl is-active --quiet ssh.socket || die "ssh.socket is not active"
  ssh-keyscan -T 5 -t ed25519 127.0.0.1 >/dev/null 2>&1 || die "local SSH handshake failed"
fi

{
  printf 'Completed: %s\n' "$(date --iso-8601=seconds)"
  printf 'Backup: %s\n' "$backup_dir"
  printf 'MPV: %s\n' "$(mpv --version | head -1)"
  printf 'GitHub CLI: %s\n' "$(gh --version | head -1)"
  printf 'Git identity: %s <%s>\n' \
    "$(git config --global --get user.name)" "$(git config --global --get user.email)"
  if ! $skip_onlyoffice; then
    printf 'ONLYOFFICE: %s\n' "$(dpkg-query -W -f='${Version}' onlyoffice-desktopeditors)"
  fi
  if ! $skip_ssh; then
    printf 'SSH address: ssh %s@%s\n' "$(id -un)" "$(hostname -I | awk '{print $1}')"
  fi
} | tee "$backup_dir/state-after.txt"

log "Setup completed successfully"
printf 'Backup and audit record: %s\n' "$backup_dir"
printf 'Log out and back in if an already-open application still uses old fonts or input sources.\n'
