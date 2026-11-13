#!/bin/bash
#
# macROOT 1.2.0
# Strip a macOS installer (10.9 - 10.15 InstallESD layout) down to the core system
# + a root Terminal, and bundle OpenCore / OCLP / VM tooling.
# Written for bash 3.2 (stock on every macOS since 10.9).
#
# BUILD HOST (run on a Mac, as root):
#   sudo ./macROOT.sh build [--installer "/Applications/Install macOS Mojave.app"]
#                           [--out DIR] [--keep-langs "en English Base"]
#                           [--tools-dir DIR | --no-tools]
#   ./macROOT.sh fetch [DIR]        download latest OpenCore + OCLP archives
#   ./macROOT.sh info  [APP]        show installer layout and sizes
#   sudo ./macROOT.sh download      get an installer (softwareupdate / Apple page / import a .dmg)
#   sudo ./macROOT.sh import FILE.dmg   turn InstallOS.dmg / InstallMacOSX.dmg into an Install app
#   ./macROOT.sh menu               interactive menu (also the default when run in a terminal)
#   sudo ./macROOT.sh debloat [--yes] [--aggressive] [--target VOL] [--with-tools]
#   sudo ./macROOT.sh toolkit [--target VOL]   install macroot + OpenCore + OCLP + VM tools
#
# INSIDE A macROOT INSTALLER (Terminal) or on an installed macOS:
#   macroot help | root | mount | efi | where | oc [install] | oclp
#   sudo macroot vm [--tune] [--iso FILE]     (VM detection + VM tools)

VERSION="1.2.0"
KEEP_LANGS="${KEEP_LANGS:-en English Base}"
WORK=""
MOUNTS=""

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SELF_DIR/$(basename "$0")"

# ---------------------------------------------------------------- status bar
BAR_ON=0; CUR_PCT=0; STEP_START=0; STEP_END=0; STEP_LABEL=""; LAST_LOGGED=-10
clr() { [ "$BAR_ON" -eq 1 ] && printf '\r\033[K' >&2; }
draw_bar() { # pct  (draws a bar on a terminal; otherwise prints a plain "[ NN%] label" line every 2%)
  local p="$1" w=30 f i=0 bar=""
  [ "$p" -gt 100 ] && p=100
  if [ ! -t 2 ]; then
    if [ "$p" -ge $(( LAST_LOGGED + 2 )) ] || { [ "$p" -eq 100 ] && [ "$LAST_LOGGED" -ne 100 ]; }; then
      LAST_LOGGED="$p"; printf '[%3d%%] %s\n' "$p" "$STEP_LABEL" >&2
    fi
    return 0
  fi
  f=$(( p * w / 100 ))
  while [ "$i" -lt "$w" ]; do
    if [ "$i" -lt "$f" ]; then bar="$bar#"; else bar="$bar-"; fi
    i=$(( i + 1 ))
  done
  printf '\r\033[K\033[1;36m[%s]\033[0m %3d%%  %s' "$bar" "$p" "$STEP_LABEL" >&2
  BAR_ON=1
}
step() { # weight label  -> starts the next slice of the overall bar
  STEP_START=$STEP_END; STEP_END=$(( STEP_START + $1 )); STEP_LABEL="$2"; CUR_PCT=$STEP_START
  if [ -t 2 ]; then draw_bar "$CUR_PCT"; else LAST_LOGGED="$CUR_PCT"; printf '[%3d%%] %s\n' "$CUR_PCT" "$2"; fi
}
step_sub() { # 0-100 progress inside the current step
  local p="$1"
  [ "$p" -lt 0 ] && p=0
  [ "$p" -gt 100 ] && p=100
  CUR_PCT=$(( STEP_START + (STEP_END - STEP_START) * p / 100 ))
  draw_bar "$CUR_PCT"
}
progress_done() {
  CUR_PCT=100; STEP_LABEL="complete"; draw_bar 100
  [ "$BAR_ON" -eq 1 ] && printf '\n' >&2
  BAR_ON=0
}

say()  { clr; printf '\033[1;36m[macROOT]\033[0m %s\n' "$*"; [ "$BAR_ON" -eq 1 ] && draw_bar "$CUR_PCT"; return 0; }
warn() { clr; printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; [ "$BAR_ON" -eq 1 ] && draw_bar "$CUR_PCT"; return 0; }
die()  { clr; printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "This command needs root (use sudo)."; }

os_ver_ok() {
  local v maj min
  v=$(sw_vers -productVersion 2>/dev/null) || return 0
  maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  [ "$maj" -gt 10 ] || [ "$min" -ge 9 ]
}

# ---------------------------------------------------------------- mount helpers
attach() { # image mountpoint
  mkdir -p "$2"
  hdiutil attach "$1" -mountpoint "$2" -nobrowse -noverify -noautoopen -owners on -quiet \
    || die "Could not attach $1"
  MOUNTS="$2
$MOUNTS"
}
detach() {
  hdiutil detach "$1" -quiet 2>/dev/null || hdiutil detach "$1" -force -quiet
  MOUNTS=$(printf '%s\n' "$MOUNTS" | grep -vxF "$1")
}
cleanup() {
  local IFS=$'\n' m
  for m in $MOUNTS; do [ -n "$m" ] && hdiutil detach "$m" -force -quiet 2>/dev/null; done
  [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  [ "$BAR_ON" -eq 1 ] && printf '\n' >&2
}
trap cleanup EXIT INT TERM

zero_fill() { # mountpoint lo hi  (progress range inside current step)
  local mp="$1" lo="${2:-0}" hi="${3:-100}" start cur pid
  start=$(free_kb "$mp")
  dd if=/dev/zero of="$mp/.macroot_zero" bs=1m 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    cur=$(free_kb "$mp")
    [ "$start" -gt 0 ] && step_sub $(( lo + (start - cur) * (hi - lo) / start ))
    sleep 1
  done
  wait "$pid" 2>/dev/null
  rm -f "$mp/.macroot_zero"; sync
}
convert_with_progress() { # lo hi hdiutil-convert-args...
  local lo="$1" hi="$2" line pct
  shift 2
  hdiutil convert "$@" -puppetstrings 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      PERCENT:*) pct=${line#PERCENT:}; pct=${pct%%.*}
                 [ "$pct" -ge 0 ] 2>/dev/null && step_sub $(( lo + pct * (hi - lo) / 100 ));;
    esac
  done
  return "${PIPESTATUS[0]}"
}
copy_with_progress() { # src dst
  local total cur pid
  total=$(size_kb "$1")
  ditto "$1" "$2" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    cur=$(size_kb "$2")
    [ "${total:-0}" -gt 0 ] && step_sub $(( ${cur:-0} * 100 / total ))
    sleep 1
  done
  wait "$pid"
}
free_kb() { df -k "$1" | awk 'NR==2{print $4}'; }
size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
human()   { awk -v k="$1" 'BEGIN{printf "%.2f GB", k/1048576}'; }

# ---------------------------------------------------------------- stripping
is_kept_lang() {
  local name="${1%.lproj}" k
  for k in $KEEP_LANGS; do
    case "$name" in "$k"|"$k"_*|"$k"-*) return 0;; esac
  done
  return 1
}
strip_lprojs() {
  local root="$1" d
  [ -d "$root" ] || return 0
  find "$root" -type d -name '*.lproj' -prune 2>/dev/null | while IFS= read -r d; do
    is_kept_lang "$(basename "$d")" || rm -rf "$d"
  done
}

strip_base() { # $1 = mounted BaseSystem
  local M="$1" p
  chflags -R norestricted "$M" 2>/dev/null \
    || warn "Could not clear 'restricted' flags (SIP on the build Mac). Some removals may be skipped."

  say "Removing non-core apps, docs, wallpapers, printers, voices"
  while IFS= read -r p; do
    [ -n "$p" ] && [ -e "$M/$p" ] && rm -rf "$M/$p"
  done <<'EOF'
Applications/Safari.app
Library/Desktop Pictures
Library/Screen Savers
System/Library/Screen Savers
Library/Printers
Library/Dictionaries
Library/Documentation
System/Library/Documentation
System/Library/Speech/Voices
usr/share/man
usr/share/doc
usr/share/info
usr/share/texinfo
EOF

  if [ -d "$M/Applications/Utilities" ]; then
    find "$M/Applications/Utilities" -mindepth 1 -maxdepth 1 \
      ! -name 'Terminal.app' ! -name 'Disk Utility.app' ! -name 'Startup Disk.app' \
      ! -name 'Reset Password.app' ! -name 'Firmware Password Utility.app' \
      ! -name 'System Information.app' \
      -exec rm -rf {} + 2>/dev/null
  fi

  say "Removing localizations (keeping: $KEEP_LANGS)"
  strip_lprojs "$M"

  say "Installing 'macroot' helper + login banner"
  mkdir -p "$M/usr/local/bin"
  cp "$SELF" "$M/usr/local/bin/macroot" && chmod 755 "$M/usr/local/bin/macroot"
  printf '\n# macROOT\n[ -x /usr/local/bin/macroot ] && echo "macROOT ready - type: macroot help"\n' \
    >> "$M/private/etc/profile" 2>/dev/null
}

# ---------------------------------------------------------------- tools download
gh_asset() { # repo regex
  curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -o '"browser_download_url": *"[^"]*"' \
    | sed 's/.*"\(https[^"]*\)"/\1/' | grep -E "$2" | head -1
}
fetch_one() { # dest repo regex...
  local dest="$1" repo="$2" url re
  shift 2
  for re in "$@"; do
    url=$(gh_asset "$repo" "$re")
    [ -n "$url" ] && break
  done
  if [ -z "$url" ]; then warn "No matching release asset in $repo (rate limit / offline / renamed). Use --tools-dir."; return 1; fi
  say "Downloading $(basename "$url")"
  curl -fL --progress-bar -o "$dest/$(basename "$url")" "$url" || { warn "Download failed: $url"; return 1; }
}
cmd_fetch() {
  local dest="${1:-./macROOT-Tools}"
  mkdir -p "$dest"
  fetch_one "$dest" acidanthera/OpenCorePkg 'OpenCore-[0-9.]+-RELEASE\.zip$'
  fetch_one "$dest" dortania/OpenCore-Legacy-Patcher \
    'OpenCore-Patcher-GUI\.app\.zip$' 'OpenCore-Patcher\.pkg$' 'OpenCore-Patcher.*\.(zip|pkg)$'
  ( cd "$dest" && shasum -a 256 -- *.zip *.pkg 2>/dev/null > SHA256SUMS )
  say "Tools in $dest (checksums in SHA256SUMS)"
}

# ---------------------------------------------------------------- build
find_installer() { ls -d /Applications/Install*.app 2>/dev/null | head -1; }

cmd_info() {
  local app="${1:-$(find_installer)}"
  [ -d "$app" ] || die "No installer app found."
  say "Installer: $app"
  say "Size: $(human "$(size_kb "$app")")"
  if [ -f "$app/Contents/SharedSupport/InstallESD.dmg" ]; then
    say "Layout: InstallESD.dmg (supported)"
  elif [ -f "$app/Contents/SharedSupport/SharedSupport.dmg" ]; then
    say "Layout: SharedSupport.dmg (macOS 11+; NOT supported by 'build')"
  else
    say "Layout: unknown"
  fi
}

cmd_build() {
  local INSTALLER="" OUT="./macROOT-out" TOOLS_DIR="" NO_TOOLS=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --installer)  INSTALLER="$2"; shift 2;;
      --out)        OUT="$2"; shift 2;;
      --keep-langs) KEEP_LANGS="$2"; shift 2;;
      --tools-dir)  TOOLS_DIR="$2"; shift 2;;
      --no-tools)   NO_TOOLS=1; shift;;
      *) die "Unknown option: $1";;
    esac
  done
  trap cleanup EXIT INT TERM
  need_root
  os_ver_ok || die "Build host must be macOS 10.9 or newer."
  if [ -z "$INSTALLER" ]; then
    if [ -t 0 ]; then
      pick_installer || die "No installer chosen."
      INSTALLER="$REPLY"
    else
      INSTALLER=$(find_installer)
    fi
  fi
  [ -d "$INSTALLER" ] || die "Installer app not found. Use --installer."
  local ESD_SRC="$INSTALLER/Contents/SharedSupport/InstallESD.dmg"
  [ -f "$ESD_SRC" ] || die "No InstallESD.dmg (macOS 11+ installers use SharedSupport.dmg; unsupported)."

  mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
  local esd_kb; esd_kb=$(( $(stat -f %z "$ESD_SRC") / 1024 ))
  [ "$(free_kb "$OUT")" -gt $(( esd_kb * 4 )) ] \
    || die "Need roughly $(human $(( esd_kb * 4 ))) free in $OUT."

  WORK=$(mktemp -d "$OUT/.work.XXXXXX") || die "mktemp failed"
  local before; before=$(size_kb "$INSTALLER")
  local APP="$OUT/macROOT-$(basename "$INSTALLER")"

  STEP_END=0

  step 10 "Copying installer"
  rm -rf "$APP"
  copy_with_progress "$INSTALLER" "$APP" || die "ditto failed"
  local ESD="$APP/Contents/SharedSupport/InstallESD.dmg"

  step 15 "Opening InstallESD.dmg"
  convert_with_progress 0 100 "$ESD" -format UDRW -o "$WORK/esd_rw.dmg" || die "convert ESD failed"
  attach "$WORK/esd_rw.dmg" "$WORK/esd"
  [ -f "$WORK/esd/BaseSystem.dmg" ] || die "BaseSystem.dmg missing inside InstallESD."

  step 8 "Opening BaseSystem.dmg"
  convert_with_progress 0 100 "$WORK/esd/BaseSystem.dmg" -format UDRW -o "$WORK/base_rw.dmg" \
    || die "convert Base failed"
  attach "$WORK/base_rw.dmg" "$WORK/base"

  step 12 "Stripping BaseSystem"
  strip_base "$WORK/base"

  step 15 "Compressing BaseSystem"
  zero_fill "$WORK/base" 0 40
  detach "$WORK/base"
  convert_with_progress 40 100 "$WORK/base_rw.dmg" -format UDZO -imagekey zlib-level=9 \
    -o "$WORK/base_new.dmg" || die "recompress Base failed"
  rm -f "$WORK/base_rw.dmg"
  cp "$WORK/base_new.dmg" "$WORK/esd/BaseSystem.dmg" || die "New BaseSystem does not fit back into ESD."
  rm -f "$WORK/base_new.dmg"

  step 25 "Compressing InstallESD"
  zero_fill "$WORK/esd" 0 25
  detach "$WORK/esd"
  rm -f "$ESD"
  convert_with_progress 25 100 "$WORK/esd_rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$ESD" \
    || die "recompress ESD failed"

  step 3 "Trimming installer localizations"
  strip_lprojs "$APP/Contents/Resources"
  strip_lprojs "$APP/Contents/Frameworks"

  step 8 "Bundling macROOT tools"
  local TD="$APP/Contents/SharedSupport/macROOT-Tools"
  mkdir -p "$TD"; cp "$SELF" "$TD/macROOT.sh"
  if [ -n "$TOOLS_DIR" ]; then
    cp -R "$TOOLS_DIR"/. "$TD"/
  elif [ "$NO_TOOLS" -eq 0 ]; then
    cmd_fetch "$TD"
  fi

  step 4 "Finalizing"
  local after; after=$(size_kb "$APP")
  progress_done
  say "Done: $(human "$before") -> $(human "$after")"
  say "Installer written to:"
  say "  $APP"
  say "Make USB media:"
  say "  sudo \"$APP/Contents/Resources/createinstallmedia\" --volume /Volumes/YOURUSB --applicationpath \"$APP\""
  say "The app signature is now invalid and BaseSystem.chunklist no longer matches - test before relying on it."
}

# ---------------------------------------------------------------- runtime helpers
tools_dir() {
  local d
  for d in "$MACROOT_TOOLS" "$SELF_DIR/macROOT-Tools" /usr/local/macROOT-Tools \
           /Volumes/*/*.app/Contents/SharedSupport/macROOT-Tools /Volumes/*/macROOT-Tools; do
    [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}
cmd_where() { tools_dir || die "macROOT-Tools folder not found (set MACROOT_TOOLS=path)."; }

cmd_root() {
  say "uid=$(id -u) ($(id -un))"
  csrutil status 2>/dev/null
  say "Drop to a login shell with: exec /bin/bash -l"
}

cmd_mount() {
  local d
  for d in $(diskutil list 2>/dev/null | awk '/^\/dev\/disk/{print $1}'); do
    diskutil mountDisk "$d" >/dev/null 2>&1
  done
  ls /Volumes
}

efi_mount() {
  local s v
  for s in $(diskutil list 2>/dev/null | awk '/ EFI /{print $NF}'); do
    diskutil mount "/dev/$s" >/dev/null 2>&1
  done
  v=$(ls -d /Volumes/EFI* 2>/dev/null | head -1)
  [ -n "$v" ] && echo "$v"
}
cmd_efi() { efi_mount || die "No EFI partition found."; }

cmd_oc() { # [install]
  local TD z OCD="/tmp/macROOT-OpenCore" efi
  TD=$(tools_dir) || die "macROOT-Tools folder not found."
  z=$(ls "$TD"/OpenCore-*-RELEASE.zip 2>/dev/null | head -1)
  [ -n "$z" ] || die "No OpenCore zip in $TD (run: macROOT.sh fetch)."
  rm -rf "$OCD"; mkdir -p "$OCD"; unzip -q "$z" -d "$OCD" || die "unzip failed"
  say "OpenCore staged in $OCD  (X64/EFI, Docs/Sample.plist, Utilities/)"
  if [ "$1" = "install" ]; then
    efi=$(efi_mount) || die "No EFI partition mounted."
    [ -d "$efi/EFI/OC" ] && die "$efi/EFI/OC already exists - refusing to overwrite."
    mkdir -p "$efi/EFI"
    cp -R "$OCD/X64/EFI/." "$efi/EFI/" || die "copy failed"
    say "Copied to $efi/EFI. You still need a config.plist for your hardware"
    say "(start from $OCD/Docs/Sample.plist) plus the kexts/drivers it references."
  fi
}

cmd_oclp() {
  local TD f
  TD=$(tools_dir) || die "macROOT-Tools folder not found."
  f=$(ls "$TD"/OpenCore-Patcher* 2>/dev/null | head -1)
  [ -n "$f" ] || die "No OCLP asset in $TD (run: macROOT.sh fetch)."
  case "$f" in
    *.zip) rm -rf /tmp/macROOT-OCLP; mkdir -p /tmp/macROOT-OCLP
           unzip -q "$f" -d /tmp/macROOT-OCLP && say "Unpacked to /tmp/macROOT-OCLP (run it from a booted macOS; it is not meant for Recovery).";;
    *.pkg) say "Install on a booted macOS with: installer -pkg \"$f\" -target /";;
  esac
}

# ---------------------------------------------------------------- VM support
detect_vm() {
  local hv model feat io
  hv=$(sysctl -n kern.hv_vmm_present 2>/dev/null)
  model=$(sysctl -n hw.model 2>/dev/null)
  feat=$(sysctl -n machdep.cpu.features 2>/dev/null)
  case " $feat " in *" VMM "*) hv=1;; esac
  [ "$hv" = "1" ] || { echo none; return; }
  io=$(ioreg -l 2>/dev/null | grep -iE 'vmware|parallels|virtualbox|vbox|qemu' | head -20)
  case "$model$io" in
    *[Vv][Mm]ware*) echo vmware;;
    *[Pp]arallels*) echo parallels;;
    *[Vv]irtual[Bb]ox*|*VBOX*|*vbox*) echo virtualbox;;
    *[Qq][Ee][Mm][Uu]*) echo qemu;;
    *) echo unknown;;
  esac
}
install_tools_from() { # volume name
  local vol="/Volumes/$1" pkg
  [ -d "$vol" ] || { warn "'$1' disc is not mounted. Use your hypervisor's Install $1 command, or pass --iso FILE."; return 1; }
  pkg=$(find "$vol" -maxdepth 5 -name '*.pkg' 2>/dev/null | head -1)
  if [ -n "$pkg" ]; then
    say "Installing $pkg"
    installer -pkg "$pkg" -target / || warn "installer failed"
    say "Reboot afterwards; approve the extension in Security & Privacy if prompted."
  else
    warn "No .pkg on $vol - open the Install app on that disc by hand."
  fi
}
vm_tune() {
  local kv
  say "Applying VM-friendly power/indexing settings"
  for kv in "sleep 0" "displaysleep 0" "disksleep 0" "hibernatemode 0" "standby 0" "autopoweroff 0"; do
    pmset -a $kv >/dev/null 2>&1
  done
  mdutil -a -i off >/dev/null 2>&1   # Spotlight off
  tmutil disable   >/dev/null 2>&1   # Time Machine off
}
cmd_vm() {
  local TUNE=0 ISO="" kind
  while [ $# -gt 0 ]; do
    case "$1" in
      --tune) TUNE=1; shift;;
      --iso)  ISO="$2"; shift 2;;
      *) die "Unknown option: $1";;
    esac
  done
  kind=$(detect_vm)
  say "Virtualization: $kind"
  [ "$kind" = none ] && { say "Not running in a VM - nothing to do."; return 0; }
  need_root
  [ -n "$ISO" ] && { hdiutil attach "$ISO" -nobrowse -noverify -quiet || warn "Could not attach $ISO"; }
  case "$kind" in
    vmware)     install_tools_from "VMware Tools";;
    parallels)  install_tools_from "Parallels Tools";;
    virtualbox) warn "VirtualBox has no Guest Additions for macOS guests.";;
    *)          warn "No official macOS guest tools for this hypervisor; nothing installed.";;
  esac
  [ "$TUNE" -eq 1 ] && vm_tune
}

# ---------------------------------------------------------------- installer picker / download
installer_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
installer_layout() {
  if   [ -f "$1/Contents/SharedSupport/InstallESD.dmg" ];    then echo "ready"
  elif [ -f "$1/Contents/SharedSupport/SharedSupport.dmg" ]; then echo "unsupported: macOS 11+ layout"
  else echo "incomplete: no InstallESD.dmg"; fi
}
list_installers() {
  ls -d /Applications/Install*.app "$PWD"/Install*.app /Users/*/Downloads/Install*.app 2>/dev/null | awk '!seen[$0]++'
}

pick_installer() { # sets $REPLY; returns 1 if the user backs out
  local APPS=() n app v c ans
  while true; do
    APPS=(); n=0
    printf '\n\033[1;36m  Choose the installer to strip\033[0m\n'
    while IFS= read -r app; do
      [ -z "$app" ] && continue
      n=$(( n + 1 )); APPS[$n]="$app"
      v=$(installer_version "$app")
      printf '  %d) %s  [%s%s, %s]\n' "$n" "$(basename "$app")" "${v:+v}" "${v:-?}" "$(installer_layout "$app")"
      printf '       %s\n' "$app"
    done <<EOF
$(list_installers)
EOF
    if [ "$n" -eq 0 ]; then
      echo "  No Install macOS/OS X app found in /Applications, this folder or Downloads."
      read -r -p "  Would you like to download one now? [Y/n]: " ans || return 1
      case "$ans" in n|N) return 1;; *) ( cmd_download ); continue;; esac
    fi
    echo "  d) Download another installer"
    echo "  p) Enter a path to an Install app"
    echo "  b) Back"
    read -r -p "  > " c || return 1
    case "$c" in
      d|D) ( cmd_download );;
      p|P) read -r -p "  Path: " REPLY || return 1
           [ -d "$REPLY" ] && return 0
           warn "Not a folder: $REPLY";;
      b|B) return 1;;
      *[!0-9]*|"") warn "Pick a number, d, p or b";;
      *) if [ -n "${APPS[$c]}" ]; then
           case "$(installer_layout "${APPS[$c]}")" in
             ready) REPLY="${APPS[$c]}"; return 0;;
             *) warn "That installer can't be built: $(installer_layout "${APPS[$c]}")";;
           esac
         else warn "No such entry"; fi;;
    esac
  done
}

cmd_import() { # FILE.dmg  (Apple's InstallOS.dmg / InstallMacOSX.dmg for 10.10-10.12)
  local dmg="$1" dest="${2:-/Applications}" mp pkg app esd
  trap cleanup EXIT INT TERM
  need_root
  [ -f "$dmg" ] || die "File not found: $dmg"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/macroot-import.XXXXXX") || die "mktemp failed"
  say "Mounting $(basename "$dmg")"
  attach "$dmg" "$WORK/dmg"
  pkg=$(find "$WORK/dmg" -maxdepth 3 -name '*.pkg' 2>/dev/null | head -1)
  [ -n "$pkg" ] || die "No .pkg inside that disk image."
  say "Expanding $(basename "$pkg") (needs ~6 GB free in ${TMPDIR:-/tmp}; avoids the expired-certificate installer error)"
  pkgutil --expand-full "$pkg" "$WORK/exp" || die "pkgutil --expand-full failed (needs a newer macOS host)."
  app=$(find "$WORK/exp" -type d -name 'Install*.app' -prune 2>/dev/null | head -1)
  esd=$(find "$WORK/exp" -name InstallESD.dmg 2>/dev/null | head -1)
  [ -d "$app" ] || die "No Install app found in the package."
  [ -f "$esd" ] || die "No InstallESD.dmg found in the package."
  mkdir -p "$app/Contents/SharedSupport"
  mv "$esd" "$app/Contents/SharedSupport/InstallESD.dmg" || die "Could not place InstallESD.dmg"
  [ -e "$dest/$(basename "$app")" ] && die "$dest/$(basename "$app") already exists."
  say "Copying to $dest"
  ditto "$app" "$dest/$(basename "$app")" || die "ditto failed"
  say "Installer ready: $dest/$(basename "$app")"
}

cmd_download() {
  local c v u dmg
  need_root
  while true; do
    printf '\n\033[1;36m  Download a macOS installer\033[0m\n'
    echo "  1) Apple softwareupdate   (needs a Mac running 10.15+; lists what Apple still offers)"
    echo "  2) Older (10.10 - 10.12)  open Apple's download page in Safari, then import the .dmg"
    echo "  3) Import a downloaded InstallOS.dmg / InstallMacOSX.dmg"
    echo "  b) Back"
    read -r -p "  > " c || return 0
    case "$c" in
      1) if ! os_ge 10 15; then warn "This Mac is older than 10.15: softwareupdate can't fetch full installers. Use option 2."; continue; fi
         softwareupdate --list-full-installers
         read -r -p "  Version to download (e.g. 10.14.6), blank to cancel: " v || return 0
         [ -n "$v" ] || continue
         softwareupdate --fetch-full-installer --full-installer-version "$v" \
           && say "Downloaded - it should now be in /Applications." \
           || warn "softwareupdate could not fetch $v.";;
      2) u=$(stat -f %Su /dev/console 2>/dev/null)
         say "Opening Apple's page. Use Safari, download the version you want, then pick option 3."
         say "https://support.apple.com/en-us/HT211683"
         [ -n "$u" ] && [ "$u" != root ] && sudo -u "$u" open "https://support.apple.com/en-us/HT211683" 2>/dev/null;;
      3) dmg=$(ls -t /Users/*/Downloads/Install*.dmg 2>/dev/null | head -1)
         ask "Path to the .dmg" "${dmg:-}"
         [ -n "$REPLY" ] && ( cmd_import "$REPLY" );;
      b|B) return 0;;
      *) warn "Pick 1-3 or b";;
    esac
  done
}

# ---------------------------------------------------------------- DEBLOAT
DB_APPLY=0; DB_FREED=0
DB_GUI_SVCS="com.apple.photoanalysisd com.apple.mediaanalysisd com.apple.suggestd com.apple.assistantd com.apple.assistant_service com.apple.Siri.agent com.apple.parsecd com.apple.knowledge-agent com.apple.tipsd com.apple.touristd"
DB_SYS_SVCS="com.apple.analyticsd com.apple.SubmitDiagInfo"

os_ge() { # major minor
  local v maj min
  v=$(sw_vers -productVersion 2>/dev/null) || return 1
  maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  [ "$maj" -gt "$1" ] || { [ "$maj" -eq "$1" ] && [ "$min" -ge "$2" ]; }
}
db_note() { # kb path
  if [ "$DB_APPLY" -eq 1 ]; then say "removed       $(( $1 / 1024 )) MB  $2"
  else say "would remove  $(( $1 / 1024 )) MB  $2"; fi
}
db_remove() { # path
  local p="$1" kb
  [ -e "$p" ] || return 0
  kb=$(size_kb "$p"); kb=${kb:-0}
  DB_FREED=$(( DB_FREED + kb ))
  if [ "$DB_APPLY" -eq 1 ]; then
    chflags -R nouchg "$p" 2>/dev/null
    rm -rf "$p" 2>/dev/null
    [ -e "$p" ] && { warn "could not fully remove $p (protected by SIP?)"; return 0; }
  fi
  db_note "$kb" "$p"
}
db_clear() { # directory whose contents are removed
  local d="$1" kb
  [ -d "$d" ] || return 0
  kb=$(size_kb "$d"); kb=${kb:-0}
  [ "$kb" -gt 0 ] || return 0
  DB_FREED=$(( DB_FREED + kb ))
  [ "$DB_APPLY" -eq 1 ] && find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
  db_note "$kb" "$d/*"
}

cmd_debloat() {
  local T="" AGGR=0 WITH_TOOLS=0 p h s u uid d n
  DB_APPLY=0; DB_FREED=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)     T="${2%/}"; shift 2;;
      --yes)        DB_APPLY=1; shift;;
      --aggressive) AGGR=1; shift;;
      --with-tools) WITH_TOOLS=1; shift;;
      *) die "Unknown option: $1";;
    esac
  done
  [ "$DB_APPLY" -eq 1 ] && need_root
  [ -d "$T/Applications" ] || [ -d "$T/Library" ] || die "No macOS found at '${T:-/}'."
  if [ "$DB_APPLY" -eq 1 ]; then say "DEBLOAT: APPLYING to '${T:-/}'"; else say "DEBLOAT: preview only (add --yes to apply) for '${T:-/}'"; fi

  say "Optional Apple apps"
  for p in GarageBand iMovie Keynote Numbers Pages; do db_remove "$T/Applications/$p.app"; done
  say "Content libraries"
  db_remove "$T/Library/Application Support/GarageBand"
  db_remove "$T/Library/Application Support/Logic"
  db_remove "$T/Library/Audio/Apple Loops"

  say "Caches, logs, stale updates"
  db_clear "$T/Library/Caches"
  db_clear "$T/Library/Logs/DiagnosticReports"
  db_clear "$T/Library/Updates"
  for h in "$T"/Users/*; do
    [ -d "$h/Library" ] || continue
    db_clear "$h/Library/Caches"
    db_clear "$h/Library/Logs"
  done

  if [ "$AGGR" -eq 1 ]; then
    say "Aggressive: printer drivers, wallpapers, screen savers, sleepimage"
    db_remove "$T/Library/Printers"
    db_remove "$T/Library/Desktop Pictures"
    db_remove "$T/Library/Screen Savers"
    db_remove "$T/private/var/vm/sleepimage"
    [ -z "$T" ] && [ "$DB_APPLY" -eq 1 ] && pmset -a hibernatemode 0 >/dev/null 2>&1
  fi

  if [ -z "$T" ]; then
    u=$(stat -f %Su /dev/console 2>/dev/null)
    uid=$(id -u "$u" 2>/dev/null)

    say "Time Machine local snapshots"
    if command -v tmutil >/dev/null 2>&1; then
      if tmutil listlocalsnapshotdates / >/dev/null 2>&1; then
        n=0
        for d in $(tmutil listlocalsnapshotdates / 2>/dev/null | grep -E '^[0-9]{4}-'); do
          n=$(( n + 1 ))
          [ "$DB_APPLY" -eq 1 ] && tmutil deletelocalsnapshots "$d" >/dev/null 2>&1
        done
        say "$n local snapshot(s) $( [ "$DB_APPLY" -eq 1 ] && echo deleted || echo found )"
      elif [ "$DB_APPLY" -eq 1 ]; then
        tmutil disablelocal >/dev/null 2>&1 && say "Mobile Time Machine backups disabled"
      fi
    fi

    if os_ge 10 10; then
      say "Background services (reversible with: launchctl enable <domain>/<label>)"
      if [ "$DB_APPLY" -eq 1 ]; then
        [ -n "$uid" ] && [ "$u" != "root" ] && for s in $DB_GUI_SVCS; do launchctl disable "gui/$uid/$s" 2>/dev/null; done
        for s in $DB_SYS_SVCS; do launchctl disable "system/$s" 2>/dev/null; done
        say "Disabled: $DB_GUI_SVCS $DB_SYS_SVCS"
      else
        say "would disable: $DB_GUI_SVCS $DB_SYS_SVCS"
      fi
    else
      warn "Service disabling needs macOS 10.10+; skipped."
    fi

    if [ "$DB_APPLY" -eq 1 ] && [ -n "$u" ] && [ "$u" != "root" ]; then
      say "Per-user tweaks for $u (Siri off, no crash dialog, no Photos auto-open)"
      sudo -u "$u" defaults write com.apple.assistant.support "Assistant Enabled" -bool false 2>/dev/null
      sudo -u "$u" defaults write com.apple.CrashReporter DialogType -string none 2>/dev/null
      sudo -u "$u" defaults -currentHost write com.apple.ImageCapture disableHotPlug -bool YES 2>/dev/null
    fi
  else
    say "Target is not the running system: skipping services, snapshots and per-user tweaks."
  fi

  say "$( [ "$DB_APPLY" -eq 1 ] && echo Reclaimed || echo Reclaimable ): ~$(( DB_FREED / 1024 )) MB"
  [ "$DB_APPLY" -eq 1 ] || say "Nothing was changed. Re-run with --yes to apply."
  say "System apps under SIP (Safari, Mail, ...) can't be removed by any script; they are left alone."

  if [ "$WITH_TOOLS" -eq 1 ] && [ "$DB_APPLY" -eq 1 ]; then
    cmd_toolkit ${T:+--target "$T"}
  fi
}

# Installs "the same stuff" the installer gets: macroot helper, OpenCore, OCLP, VM tools
cmd_toolkit() {
  local T="" dest src
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) T="${2%/}"; shift 2;;
      *) die "Unknown option: $1";;
    esac
  done
  need_root
  dest="$T/usr/local/macROOT-Tools"
  mkdir -p "$T/usr/local/bin" "$dest" || die "Cannot create $dest"
  cp "$SELF" "$T/usr/local/bin/macroot" && chmod 755 "$T/usr/local/bin/macroot"
  cp "$SELF" "$dest/macROOT.sh"
  say "Installed $T/usr/local/bin/macroot"
  src=$(tools_dir) && [ "$src" != "$dest" ] && cp -R "$src"/. "$dest"/
  ls "$dest"/OpenCore-*-RELEASE.zip >/dev/null 2>&1 || cmd_fetch "$dest"
  say "OpenCore / OCLP archives are in $dest (use: macroot oc, macroot oclp)"
  if [ -z "$T" ]; then ( cmd_vm ); fi
}

# ---------------------------------------------------------------- menu
ask() { # prompt default  -> $REPLY
  local a
  read -r -p "$1 [$2]: " a || a=""
  REPLY="${a:-$2}"
}
pause() { local _; read -r -p "Press Enter to return to the menu..." _; }

cmd_menu() {
  local c out tgt aggr
  while true; do
    printf '\n\033[1;36m  macROOT %s\033[0m\n' "$VERSION"
    echo "  1) Build stripped installer"
    echo "  2) DEBLOAT macOS (preview, then apply)"
    echo "  3) DEBLOAT macOS + install toolkit"
    echo "  4) Install toolkit only (macroot, OpenCore, OCLP, VM tools)"
    echo "  5) VM tools (+ optional VM tuning)"
    echo "  6) Mount all volumes / EFI"
    echo "  7) Installer info"
    echo "  8) Download / import an installer"
    echo "  q) Quit"
    read -r -p "  > " c || return 0
    case "$c" in
      1) ask "Output folder" "$PWD/macROOT-out"; out="$REPLY"
         ( cmd_build --out "$out" ); pause;;
      2|3) ask "Target macOS volume ('/' = running system)" "/"; tgt="$REPLY"
         ask "Aggressive mode (printers, wallpapers, sleepimage)? y/n" "n"; aggr=""
         [ "$REPLY" = "y" ] && aggr="--aggressive"
         ( cmd_debloat --target "$tgt" $aggr )
         ask "Apply these changes? yes/no" "no"
         if [ "$REPLY" = "yes" ]; then
           if [ "$c" = "3" ]; then ( cmd_debloat --yes --with-tools --target "$tgt" $aggr )
           else ( cmd_debloat --yes --target "$tgt" $aggr ); fi
         fi
         pause;;
      4) ask "Target macOS volume ('/' = running system)" "/"
         ( cmd_toolkit --target "$REPLY" ); pause;;
      5) ask "Also apply VM tuning (no sleep, Spotlight/Time Machine off)? y/n" "n"
         if [ "$REPLY" = "y" ]; then ( cmd_vm --tune ); else ( cmd_vm ); fi
         pause;;
      6) cmd_mount; cmd_efi; pause;;
      7) ( cmd_info ); pause;;
      8) ( cmd_download ); pause;;
      q|Q) return 0;;
      *) warn "Pick 1-8 or q";;
    esac
  done
}

# ---------------------------------------------------------------- main
usage() {
  cat <<EOF
macROOT $VERSION
  build  [--installer APP] [--out DIR] [--keep-langs "en English Base"] [--tools-dir DIR|--no-tools]
  fetch  [DIR]            download latest OpenCore + OCLP
  info   [APP]            installer layout / size
  root                    show root/SIP status
  mount                   mount every volume
  efi                     mount EFI partition(s)
  where                   locate bundled macROOT-Tools
  oc     [install]        stage OpenCore (install = copy into EFI if no EFI/OC yet)
  oclp                    unpack bundled OpenCore Legacy Patcher
  vm     [--tune] [--iso FILE]   detect VM, install hypervisor tools
  menu                    interactive menu
  download                get an installer (softwareupdate / Apple page / import)
  import FILE.dmg         expand InstallOS.dmg / InstallMacOSX.dmg into an Install app
  debloat [--yes] [--aggressive] [--target VOL] [--with-tools]
                          remove bloat (preview unless --yes)
  toolkit [--target VOL]  install macroot + OpenCore + OCLP + VM tools
Default output of 'build': ./macROOT-out/macROOT-<Install app name>.app
EOF
}

case "${1:-menu}" in
  build) shift; cmd_build "$@";;
  fetch) shift; cmd_fetch "$@";;
  info)  shift; cmd_info "$@";;
  root|shell) cmd_root;;
  mount) cmd_mount;;
  efi)   cmd_efi;;
  where) cmd_where;;
  oc)    shift; cmd_oc "$@";;
  oclp)  cmd_oclp;;
  vm)    shift; cmd_vm "$@";;
  download) shift; cmd_download "$@";;
  import) shift; cmd_import "$@";;
  menu)  if [ -t 0 ]; then cmd_menu; else usage; fi;;
  debloat) shift; cmd_debloat "$@";;
  toolkit) shift; cmd_toolkit "$@";;
  *)     usage;;
esac
