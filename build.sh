#!/usr/bin/env bash
# Arch-based distro builder (archiso)
# Run this ON an Arch machine (or Arch VM) — archiso only works there.
set -euo pipefail

# ==== change these ====
DISTRO_NAME="distribution"      # lowercase id, no spaces
PRETTY_NAME="Distribution."     # the dot is part of the name. respect the dot.
VERSION="0.1"
PUBLISHER="clrealy <https://github.com/clrealy>"
LIVE_USER="liveuser"
# ======================

PROFILE="./profile"
BRANDING="$(cd "$(dirname "$0")" && pwd)/branding"
LOCALREPO="$(pwd)/localrepo"

# AUR packages to bake into the ISO, in build order (deps first).
# calamares isn't in Arch's official repos, so we build it ourselves.
AUR_PKGS=(ckbcomp calamares)

if [ "$EUID" -eq 0 ]; then
  echo "run this as your normal user, not root (makepkg refuses root). it'll sudo when it needs to."
  exit 1
fi

echo "[1/6] installing archiso..."
sudo pacman -S --needed --noconfirm archiso

echo "[2/6] copying releng base profile..."
rm -rf "$PROFILE"
cp -r /usr/share/archiso/configs/releng "$PROFILE"
AIR="$PROFILE/airootfs"

echo "[3/6] branding profiledef.sh..."
sed -i \
  -e "s|^iso_name=.*|iso_name=\"${DISTRO_NAME}\"|" \
  -e "s|^iso_label=.*|iso_label=\"${DISTRO_NAME^^}_\$(date +%Y%m)\"|" \
  -e "s|^iso_publisher=.*|iso_publisher=\"${PUBLISHER}\"|" \
  -e "s|^iso_application=.*|iso_application=\"${PRETTY_NAME} Live/Rescue\"|" \
  -e "s|^iso_version=.*|iso_version=\"${VERSION}\"|" \
  "$PROFILE/profiledef.sh"

# give the live user ownership of their home + safe sudoers perms
sed -i "/^file_permissions=(/a\\
  [\"/home/${LIVE_USER}\"]=\"1000:1000:750\"\\
  [\"/etc/sudoers.d/${LIVE_USER}\"]=\"0:0:440\"\\
  [\"/usr/local/bin/gurt\"]=\"0:0:755\"\\
  [\"/usr/local/bin/gurt-pacman\"]=\"0:0:755\"\\
  [\"/usr/local/bin/distribution-first-login\"]=\"0:0:755\"\\
  [\"/home/${LIVE_USER}/Desktop\"]=\"1000:1000:755\"\\
  [\"/home/${LIVE_USER}/Desktop/install-distribution.desktop\"]=\"1000:1000:755\"" "$PROFILE/profiledef.sh"

echo "[4/6] adding packages (KDE desktop)..."
cat >> "$PROFILE/packages.x86_64" <<'EOF'
# ---- desktop ----
plasma-meta
sddm
konsole
dolphin
kate
networkmanager
plasma-nm
sudo
git
base-devel
firefox
fastfetch
# ---- gurt deps ----
curl
python
zstd
libarchive
flatpak
# ---- boot splash ----
plymouth
# ---- installer ----
calamares
grub
efibootmgr
os-prober
EOF

# ===== build AUR packages (calamares) into a local repo =====
echo "   -> building AUR packages: ${AUR_PKGS[*]} (calamares is a big C++ build, this takes a while)"
sudo pacman -S --needed --noconfirm base-devel git
mkdir -p "$LOCALREPO" ./aur-build
for pkg in "${AUR_PKGS[@]}"; do
  if ls "$LOCALREPO/${pkg}"-[0-9]*.pkg.tar.zst >/dev/null 2>&1; then
    echo "      $pkg already built, skipping (delete localrepo/ to rebuild)"
    continue
  fi
  rm -rf "./aur-build/$pkg"
  git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "./aur-build/$pkg"
  # -s pulls official-repo deps, -i installs it here so the next AUR pkg can depend on it
  ( cd "./aur-build/$pkg" && makepkg -si --needed --noconfirm )
  cp "./aur-build/$pkg"/*.pkg.tar.zst "$LOCALREPO/"
done
rm -f "$LOCALREPO"/distribution-local.db* "$LOCALREPO"/distribution-local.files*
repo-add "$LOCALREPO/distribution-local.db.tar.gz" "$LOCALREPO"/*.pkg.tar.zst

# let mkarchiso install from it (build-time only, the ISO doesn't keep this repo)
cat >> "$PROFILE/pacman.conf" <<EOF

[distribution-local]
SigLevel = Optional TrustAll
Server = file://${LOCALREPO}
EOF

echo "[5/6] configuring live system..."
# os-release = what makes it YOUR distro
cat > "$AIR/etc/os-release" <<EOF
NAME="${PRETTY_NAME}"
PRETTY_NAME="${PRETTY_NAME} ${VERSION}"
ID=${DISTRO_NAME}
ID_LIKE=arch
VERSION_ID=${VERSION}
BUILD_ID=rolling
HOME_URL="https://github.com/clrealy"
LOGO=archlinux-logo
EOF

echo "${DISTRO_NAME}" > "$AIR/etc/hostname"

# live user (SDDM won't log in as root)
echo "${LIVE_USER}:x:1000:1000::/home/${LIVE_USER}:/bin/bash" >> "$AIR/etc/passwd"
echo "${LIVE_USER}::14871::::::"                             >> "$AIR/etc/shadow"
echo "${LIVE_USER}:x:1000:"                                    >> "$AIR/etc/group"
echo "${LIVE_USER}:!*::"                                       >> "$AIR/etc/gshadow"
mkdir -p "$AIR/home/${LIVE_USER}"
mkdir -p "$AIR/etc/sudoers.d"
echo "${LIVE_USER} ALL=(ALL) NOPASSWD: ALL" > "$AIR/etc/sudoers.d/${LIVE_USER}"

# autologin straight into Plasma
mkdir -p "$AIR/etc/sddm.conf.d"
cat > "$AIR/etc/sddm.conf.d/autologin.conf" <<EOF
[Autologin]
User=${LIVE_USER}
Session=plasma
EOF

# enable services
mkdir -p "$AIR/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/sddm.service \
  "$AIR/etc/systemd/system/display-manager.service"
ln -sf /usr/lib/systemd/system/NetworkManager.service \
  "$AIR/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
# releng uses iwd + systemd-networkd; turn those off so they don't fight NM
rm -f "$AIR/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
      "$AIR/etc/systemd/system/multi-user.target.wants/iwd.service"

# ===== GURT: the package manager now 🦆 =====
# pacman stays as the engine (gurt calls it for system updates + desktops),
# but every human types gurt. typing "pacman" gets translated to gurt.
echo "   -> baking in gurt..."
rm -rf ./gurt-src
git clone --depth 1 https://github.com/clrealy/GURT.git ./gurt-src
mkdir -p "$AIR/usr/local/bin" "$AIR/usr/local/share"
install -m 755 ./gurt-src/gurt      "$AIR/usr/local/bin/gurt"
install -m 644 ./gurt-src/gurt.conf "$AIR/etc/gurt.conf"
# keep the whole repo around too (gui, deps.map, etc.)
cp -r ./gurt-src "$AIR/usr/local/share/gurt"
rm -rf "$AIR/usr/local/share/gurt/.git"

# pacman -> gurt translator
cat > "$AIR/usr/local/bin/gurt-pacman" <<'EOF'
#!/usr/bin/env bash
# you typed pacman. we don't do that here. 🦆
# gurt builds as your user, so if this ran under sudo, drop back to the real user
if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  exec sudo -u "$SUDO_USER" "$0" "$@"
fi
op="${1:-}"; shift || true
case "$op" in
  -Syu|-Syyu|-Su|-Suy) exec gurt upgrade ;;
  -Sy|-Syy)            exec gurt update ;;
  -S)                  exec gurt install "$@" --scanrepos ;;
  -Ss)                 exec gurt search -a "$@" ;;
  -Si|-Qi)             exec gurt info "$@" ;;
  -R|-Rs|-Rns|-Rsn)    exec gurt remove "$@" ;;
  -Q|-Qe)              exec gurt list ;;
  -Ql)                 exec gurt files "$@" ;;
  -Qo)                 exec gurt owns "$@" ;;
  -Qdt|-Qdtq)          exec gurt autoremove ;;
  *)
    echo "🦆 pacman? in THIS economy? use gurt."
    echo "   (real pacman still lives at /usr/bin/pacman if you're desperate)"
    exit 1 ;;
esac
EOF

# alias only hits humans in a terminal — scripts + gurt itself still reach real pacman
cat > "$AIR/etc/profile.d/gurt.sh" <<'EOF'
alias sudo='sudo '
alias pacman='gurt-pacman'
EOF
echo '[ -f /etc/profile.d/gurt.sh ] && . /etc/profile.d/gurt.sh' >> "$AIR/home/${LIVE_USER}/.bashrc"

# ===== boot splash: the period drops 🟠⬇️ =====
echo "   -> installing the Distribution. boot splash..."
mkdir -p "$AIR/usr/share/plymouth/themes"
cp -r "$BRANDING/plymouth/distribution" "$AIR/usr/share/plymouth/themes/distribution"
mkdir -p "$AIR/etc/plymouth"
cat > "$AIR/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=distribution
ShowDelay=0
EOF

# add the plymouth hook to the live initramfs (right after kms)
for f in "$AIR"/etc/mkinitcpio.conf.d/*.conf "$AIR/etc/mkinitcpio.conf"; do
  [ -f "$f" ] && grep -q '^HOOKS=' "$f" && sed -i '/^HOOKS=/{/plymouth/!s/\bkms\b/kms plymouth/}' "$f"
done

# quiet splash on every boot entry so plymouth actually shows
for f in "$PROFILE"/efiboot/loader/entries/*.conf "$PROFILE"/grub/*.cfg "$PROFILE"/syslinux/*.cfg; do
  [ -f "$f" ] && sed -i '/archisobasedir=/{/ splash/!s/$/ quiet splash/}' "$f"
done

# static version for the bootloader menu background
[ -d "$PROFILE/syslinux" ] && cp "$BRANDING/syslinux/splash.png" "$PROFILE/syslinux/splash.png"

# ===== fastfetch: the dot in your terminal 🟠 =====
mkdir -p "$AIR/usr/share/distribution" "$AIR/etc/xdg/fastfetch"
cp "$BRANDING/fastfetch/logo.txt"     "$AIR/usr/share/distribution/fastfetch-logo.txt"
cp "$BRANDING/fastfetch/config.jsonc" "$AIR/etc/xdg/fastfetch/config.jsonc"

# ===== wallpaper: the dot landed 🟠 =====
mkdir -p "$AIR/usr/share/wallpapers" "$AIR/etc/xdg/autostart"
cp -r "$BRANDING/wallpaper/Distribution" "$AIR/usr/share/wallpapers/Distribution"
install -m 755 "$BRANDING/wallpaper/distribution-first-login" "$AIR/usr/local/bin/distribution-first-login"
cat > "$AIR/etc/xdg/autostart/distribution-first-login.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Distribution. first login
Exec=/usr/local/bin/distribution-first-login
OnlyShowIn=KDE;
NoDisplay=true
X-KDE-autostart-phase=2
EOF

# ===== installer: Calamares =====
mkdir -p "$AIR/etc/calamares" "$AIR/usr/share/applications" "$AIR/home/${LIVE_USER}/Desktop" "$AIR/usr/share/distribution"
cp    "$BRANDING/calamares/settings.conf" "$AIR/etc/calamares/settings.conf"
cp -r "$BRANDING/calamares/modules"       "$AIR/etc/calamares/modules"
cp -r "$BRANDING/calamares/branding"      "$AIR/etc/calamares/branding"
cp    "$BRANDING/distribution-files/linux.preset" "$AIR/usr/share/distribution/linux.preset"
# installer icon in the app menu + on the live desktop
cp "$BRANDING/calamares/install-distribution.desktop" "$AIR/usr/share/applications/install-distribution.desktop"
cp "$BRANDING/calamares/install-distribution.desktop" "$AIR/home/${LIVE_USER}/Desktop/install-distribution.desktop"

echo "[6/6] building ISO (takes a while, go touch grass)..."
sudo mkarchiso -v -w ./work -o ./out "$PROFILE"

echo "done 🔥 your ISO is in ./out"
