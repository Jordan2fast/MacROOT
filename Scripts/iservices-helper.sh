#!/bin/bash
#
# iservices-helper.sh
# Gets an OpenCore hackintosh ready for iMessage / FaceTime when the Wi-Fi card
# isn't supported (internet via Ethernet, USB Wi-Fi, USB tethering, etc).
#
# What it does:
#   1. Finds /EFI/OC/config.plist (mounts the EFI partition if needed)
#   2. Checks whether a custom SMBIOS is set (serial / MLB / SmUUID / ROM)
#   3. If not, downloads corpnewt/GenSMBIOS, lets you generate values, then
#      writes them into config.plist (with a timestamped backup)
#   4. Checks what iServices actually care about: en0 built-in, NVRAM ROM/MLB,
#      reachability of Apple's services
#   5. If the en0 MAC is invalid (multicast bit) or doesn't match ROM, fixes it:
#      patches the NullEthernet MAC in your ACPI .aml (checksum recomputed), or
#      sets ROM to match. Everything is backed up first.
#   6. Verifies NVRAM actually persists across a reboot (two runs), checks the
#      model against macOS 26's supported Intel list, and (--diagnose) pulls the
#      real iMessage errors out of the system log.
#
# Usage:
#   chmod +x iservices-helper.sh
#   ./iservices-helper.sh [--check] [/path/to/config.plist]
#     --check   report only, change nothing
#     --yes     don't ask for confirmation before fixing things
#     --diagnose   also collect iMessage/identity errors + Messages crash reports
#     --new-mac    regenerate the en0 MAC and ROM with an Apple-style address
#     --new-smbios regenerate serial/MLB/UUID (e.g. to move to a Tahoe-supported model)
#
# Run it on the hackintosh itself (macOS), as a normal user. It calls sudo
# only for mounting the EFI partition and editing config.plist.

set -u

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
info() { printf '%s[i]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
ask_yn() { [ "${ASSUME_YES:-0}" -eq 1 ] && return 0; local a; read -r -p "$1 [Y/n] " a; case "$a" in n|N|no|NO) return 1;; *) return 0;; esac; }

GENSMBIOS_URL="https://github.com/corpnewt/GenSMBIOS/archive/refs/heads/master.zip"
WORKDIR="$HOME/iservices-helper"
NVRAM_GUID="4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14"

CHECK_ONLY=0
ASSUME_YES=0
DIAGNOSE=0
FORCE_MAC=0
FORCE_SMBIOS=0
CONFIG=""
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --diagnose) DIAGNOSE=1 ;;
    --new-mac) FORCE_MAC=1 ;;
    --new-smbios) FORCE_SMBIOS=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) CONFIG="$a" ;;
  esac
done

MOUNTED_EFI=""
BACKUP=""
cleanup() {
  if [ -n "$MOUNTED_EFI" ]; then
    sudo diskutil unmount "$MOUNTED_EFI" >/dev/null 2>&1 && info "Unmounted $MOUNTED_EFI (we mounted it)"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- preflight
[ "$(uname)" = "Darwin" ] || die "Run this on the hackintosh itself (macOS)."
for t in plutil diskutil ioreg nvram curl xxd base64 unzip; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done

info "Requesting sudo (needed to mount EFI and edit config.plist)"
sudo -v || die "sudo failed"

# ------------------------------------------------------------ locate config
mount_point() {
  diskutil info -plist "$1" 2>/dev/null | plutil -extract MountPoint raw -o - - 2>/dev/null
}

find_config() {
  if [ -n "$CONFIG" ]; then
    [ -f "$CONFIG" ] || die "Not found: $CONFIG"
    return
  fi
  if [ -f /Volumes/EFI/EFI/OC/config.plist ]; then
    CONFIG="/Volumes/EFI/EFI/OC/config.plist"
    return
  fi

  info "Searching EFI partitions for EFI/OC/config.plist ..."
  local id mp mounted_now
  for id in $(diskutil list | awk '/ EFI / {print $NF}'); do
    mp=$(mount_point "$id")
    mounted_now=0
    if [ -z "$mp" ]; then
      sudo diskutil mount "$id" >/dev/null 2>&1 || continue
      mp=$(mount_point "$id")
      mounted_now=1
    fi
    if [ -n "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ]; then
      CONFIG="$mp/EFI/OC/config.plist"
      [ "$mounted_now" -eq 1 ] && MOUNTED_EFI="$id"
      ok "Found OpenCore on $id"
      return
    fi
    [ "$mounted_now" -eq 1 ] && sudo diskutil unmount "$id" >/dev/null 2>&1
  done

  warn "Couldn't find EFI/OC/config.plist automatically."
  read -r -p "Path to your config.plist: " CONFIG
  [ -f "$CONFIG" ] || die "Not found: $CONFIG"
}

# ------------------------------------------------------- read / judge SMBIOS
cfg() { plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null; }

is_placeholder() {
  local v
  v=$(printf '%s' "$1" | tr -d ' ')
  [ -z "$v" ] && return 0
  printf '%s' "$v" | grep -Eq '^[A-Za-z]?0+[0-9]?$' && return 0   # W00000000000, M00000000000001
  printf '%s' "$v" | grep -Eq '^[0-]+$' && return 0               # 0000-...-0000
  [ "$v" = "OEM" ] && return 0
  return 1
}

rom_is_placeholder() {
  case "$1" in
    ""|000000000000|112233445566|FFFFFFFFFFFF) return 0 ;;
  esac
  return 1
}

read_smbios() {
  AUTOMATIC=$(cfg PlatformInfo.Automatic)
  MODEL=$(cfg PlatformInfo.Generic.SystemProductName)
  SERIAL=$(cfg PlatformInfo.Generic.SystemSerialNumber)
  MLB=$(cfg PlatformInfo.Generic.MLB)
  SMUUID=$(cfg PlatformInfo.Generic.SystemUUID)
  ROM_B64=$(cfg PlatformInfo.Generic.ROM)
  ROM_HEX=""
  [ -n "$ROM_B64" ] && ROM_HEX=$(printf '%s' "$ROM_B64" | base64 -D 2>/dev/null | xxd -p | tr 'a-f' 'A-F')
  SMBIOS_MODE=$(cfg PlatformInfo.UpdateSMBIOSMode)
  CUSTOM_GUID=$(cfg Kernel.Quirks.CustomSMBIOSGuid)
  SPOOF=$(cfg PlatformInfo.Generic.SpoofVendor)
}

show() { [ -n "$1" ] && printf '%s' "$1" || printf '(blank)'; }

# returns 0 if everything is set, 1 otherwise
report_smbios() {
  local problems=0
  echo
  info "PlatformInfo in $CONFIG"
  printf '    Automatic          : %s\n' "$(show "$AUTOMATIC")"
  printf '    SystemProductName  : %s\n' "$(show "$MODEL")"
  printf '    SystemSerialNumber : %s\n' "$(show "$SERIAL")"
  printf '    MLB (board serial) : %s\n' "$(show "$MLB")"
  printf '    SystemUUID (SmUUID): %s\n' "$(show "$SMUUID")"
  printf '    ROM                : %s\n' "$(show "$ROM_HEX")"
  printf '    UpdateSMBIOSMode   : %s\n' "$(show "$SMBIOS_MODE")"
  printf '    CustomSMBIOSGuid   : %s\n' "$(show "$CUSTOM_GUID")"
  printf '    SpoofVendor        : %s\n' "$(show "$SPOOF")"
  echo

  if [ "$AUTOMATIC" != "true" ]; then
    warn "PlatformInfo > Automatic is not true, so the Generic values above are ignored."
    problems=1
  fi
  if is_placeholder "$SERIAL"; then warn "SystemSerialNumber is empty or a placeholder."; problems=1; fi
  if is_placeholder "$MLB";    then warn "MLB is empty or a placeholder.";                problems=1; fi
  if is_placeholder "$SMUUID"; then warn "SystemUUID is empty or a placeholder.";         problems=1; fi
  if rom_is_placeholder "$ROM_HEX"; then warn "ROM is empty or a placeholder.";           problems=1; fi
  if [ -z "$MODEL" ]; then warn "SystemProductName is empty."; problems=1; fi

  # Informational: UUID spoofing behaviour
  if [ "$SMBIOS_MODE" = "Custom" ] && [ "$CUSTOM_GUID" = "true" ]; then
    info "UUID spoof is limited to macOS (UpdateSMBIOSMode=Custom + CustomSMBIOSGuid=true)."
  else
    info "UUID spoof mode is the default. If you dual-boot Windows and want the custom SmUUID"
    info "applied to macOS only, see UpdateSMBIOSMode=Custom + Kernel>Quirks>CustomSMBIOSGuid."
  fi

  # Informational: fake built-in ethernet for machines with no supported NIC/Wi-Fi
  if grep -aq "NullEthernet.kext" "$CONFIG" 2>/dev/null; then
    info "NullEthernet.kext is listed in config.plist."
  fi
  return $problems
}

# ------------------------------------------------------------ GenSMBIOS flow
fetch_gensmbios() {
  if ! python3 --version >/dev/null 2>&1; then
    err "python3 isn't available. Run:  xcode-select --install   then re-run this script."
    exit 1
  fi
  mkdir -p "$WORKDIR"
  info "Downloading GenSMBIOS from github.com/corpnewt/GenSMBIOS ..."
  curl -fL --progress-bar -o "$WORKDIR/GenSMBIOS.zip" "$GENSMBIOS_URL" || die "Download failed (no internet?)"
  unzip -qo "$WORKDIR/GenSMBIOS.zip" -d "$WORKDIR" || die "Unzip failed"
  GEN_DIR="$WORKDIR/GenSMBIOS-master"
  [ -f "$GEN_DIR/GenSMBIOS.py" ] || die "GenSMBIOS.py not found in $GEN_DIR"
  ok "GenSMBIOS ready in $GEN_DIR"
}

run_gensmbios() {
  echo
  info "Launching GenSMBIOS. In its menu:"
  echo "      1) Install/Update MacSerial (first run only)"
  echo "      2) Generate SMBIOS -> enter the model you use (e.g. iMacPro1,1)"
  echo "      Copy the Serial, Board Serial and SmUUID it prints, then quit (Q)."
  echo
  read -r -p "Press Enter to launch GenSMBIOS... " _
  ( cd "$GEN_DIR" && python3 GenSMBIOS.py )
}

REPLY_VAL=""
prompt_valid() {  # prompt, regex, [default]
  local p="$1" re="$2" def="${3:-}" v
  while true; do
    if [ -n "$def" ]; then
      read -r -p "$p [$def]: " v
      v="${v:-$def}"
    else
      read -r -p "$p: " v
    fi
    v=$(printf '%s' "$v" | tr -d ' ')
    if printf '%s' "$v" | grep -Eq "$re"; then REPLY_VAL="$v"; return; fi
    warn "That doesn't look right, try again."
  done
}

plset() {  # keypath type value   (type: string|bool|data)
  sudo plutil -replace "$1" "-$2" "$3" "$CONFIG" 2>/dev/null \
    || sudo plutil -insert "$1" "-$2" "$3" "$CONFIG"
}

backup_config() {
  mkdir -p "$WORKDIR/backups"
  BACKUP="$WORKDIR/backups/config.plist.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG" "$BACKUP" || die "Backup failed"
  ok "Backup saved: $BACKUP"
}

EFI_BACKED=0
backup_efi() {
  [ "$EFI_BACKED" -eq 1 ] && return 0
  local efi_dir dest
  efi_dir="$(dirname "$(dirname "$CONFIG")")"
  dest="$WORKDIR/backups/EFI-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$WORKDIR/backups"
  cp -R "$efi_dir" "$dest" || { err "EFI backup failed, stopping."; return 1; }
  EFI_BACKED=1
  ok "Full EFI backup saved: $dest"
}

setup_smbios() {
  fetch_gensmbios
  run_gensmbios

  echo
  info "Now paste the values GenSMBIOS generated."
  local model serial mlb uuid rom def_rom en0_mac rom_b64

  prompt_valid "SystemProductName (e.g. iMacPro1,1)" '^[A-Za-z]+[0-9]+,[0-9]+$' "$MODEL"
  model="$REPLY_VAL"
  prompt_valid "Serial (11-12 chars)" '^[A-Za-z0-9]{11,12}$'
  serial=$(printf '%s' "$REPLY_VAL" | tr 'a-z' 'A-Z')
  prompt_valid "Board Serial / MLB (13 or 17 chars)" '^([A-Za-z0-9]{13}|[A-Za-z0-9]{17})$'
  mlb=$(printf '%s' "$REPLY_VAL" | tr 'a-z' 'A-Z')
  prompt_valid "SmUUID" '^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$'
  uuid=$(printf '%s' "$REPLY_VAL" | tr 'a-f' 'A-F')

  # ROM should be the MAC address of en0 (no colons)
  en0_mac=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2}')
  def_rom=""
  [ -n "$en0_mac" ] && def_rom=$(printf '%s' "$en0_mac" | tr -d ':' | tr 'a-f' 'A-F')
  prompt_valid "ROM = en0 MAC address, 12 hex chars, no colons" '^[0-9A-Fa-f]{12}$' "$def_rom"
  rom=$(printf '%s' "$REPLY_VAL" | tr 'a-f' 'A-F')
  rom_b64=$(printf '%s' "$rom" | xxd -r -p | base64)

  echo
  info "About to write:"
  printf '    %-18s %s\n' "ProductName" "$model" "Serial" "$serial" "MLB" "$mlb" "SmUUID" "$uuid" "ROM" "$rom"
  info "and set PlatformInfo > Automatic / UpdateDataHub / UpdateNVRAM / UpdateSMBIOS = true"
  ask_yn "Apply to $CONFIG?" || { warn "Cancelled. Nothing changed."; return; }

  backup_efi || return 1
  backup_config
  plset PlatformInfo.Automatic bool YES
  plset PlatformInfo.UpdateDataHub bool YES
  plset PlatformInfo.UpdateNVRAM bool YES
  plset PlatformInfo.UpdateSMBIOS bool YES
  plset PlatformInfo.Generic.SystemProductName string "$model"
  plset PlatformInfo.Generic.SystemSerialNumber string "$serial"
  plset PlatformInfo.Generic.MLB string "$mlb"
  plset PlatformInfo.Generic.SystemUUID string "$uuid"
  plset PlatformInfo.Generic.ROM data "$rom_b64"

  if plutil -lint "$CONFIG" >/dev/null 2>&1; then
    ok "config.plist updated and validates."
  else
    err "config.plist failed validation, restoring backup."
    sudo cp "$BACKUP" "$CONFIG" && ok "Restored $BACKUP"
    return
  fi

  read_smbios
  report_smbios >/dev/null

  echo
  info "Check that this serial isn't registered to a real Mac:"
  echo "    Apple's coverage page should say it can't check coverage / invalid serial."
  echo "    If it shows a purchase date or model, that serial is in use: generate another."
  if ask_yn "Open https://checkcoverage.apple.com now?"; then
    open "https://checkcoverage.apple.com/" >/dev/null 2>&1
  fi
}

# ------------------------------------------------------------ live checks
system_checks() {
  echo
  info "Live system checks"

  local en0_mac iface code h live_serial k issuer
  en0_mac=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2}')
  if [ -z "$en0_mac" ]; then
    warn "No en0 interface found."
  elif ioreg -rn en0 2>/dev/null | grep -Eq '"IOBuiltin" = (Yes|true)'; then
    ok "en0 is flagged built-in (MAC $en0_mac)."
  else
    warn "en0 is NOT flagged built-in (MAC $en0_mac). iMessage/FaceTime require this."
    echo "      - No built-in NIC? Use NullEthernet.kext + SSDT-RMNE (fake built-in en0)."
    echo "      - A USB adapter grabbed en0? Unplug it, delete"
    echo "        /Library/Preferences/SystemConfiguration/NetworkInterfaces.plist and preferences.plist,"
    echo "        reboot, and plug it back in after en0 is assigned."
    echo "      (This check is best-effort; double-check in Hackintool > Peripherals/Network.)"
  fi

  if [ -n "$en0_mac" ]; then
    local mac_hex first
    mac_hex=$(printf '%s' "$en0_mac" | tr -d ':' | tr 'a-f' 'A-F')
    first=$((16#${mac_hex:0:2}))
    if [ $((first & 1)) -eq 1 ]; then
      warn "en0 MAC $en0_mac has the multicast bit set (odd first byte): not a valid unicast MAC."
      echo "      With NullEthernet, change the MAC bytes in SSDT-RMNE to an even first byte."
    fi
    if [ -n "$ROM_HEX" ]; then
      if [ "$ROM_HEX" = "$mac_hex" ]; then
        ok "ROM matches the en0 MAC."
      else
        warn "ROM ($ROM_HEX) doesn't match the en0 MAC ($mac_hex). Recommended: make them identical."
      fi
    fi
  fi

  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  if [ -n "$iface" ]; then ok "Internet is going out via $iface."; else warn "No default route: no internet?"; fi

  for h in albert.apple.com identity.ess.apple.com gsa.apple.com; do
    # -k: Apple's identity/auth hosts chain to Apple's own root, which curl's
    # bundled CA list doesn't trust, so verify the issuer ourselves below.
    code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "https://$h" 2>/dev/null)
    if [ -z "$code" ] || [ "$code" = "000" ]; then
      warn "Can't reach $h (firewall/DNS/VPN?)"
      continue
    fi
    issuer=$(echo | openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null)
    if printf '%s' "$issuer" | grep -qi 'apple'; then
      ok "Reachable, Apple-issued certificate: $h"
    else
      warn "$h is reachable but its certificate issuer isn't Apple (${issuer:-unknown})."
      echo "      Something may be intercepting HTTPS: proxy, antivirus, router filtering, VPN."
    fi
  done

  for k in ROM MLB; do
    if nvram "$NVRAM_GUID:$k" >/dev/null 2>&1; then
      ok "NVRAM has $k."
    else
      warn "NVRAM is missing $k (check UpdateNVRAM, and that NVRAM works / emulated NVRAM is set up)."
    fi
  done

  local wf marker boot saved
  wf=$(cfg NVRAM.WriteFlash)
  if [ "$wf" = "true" ]; then ok "NVRAM > WriteFlash is true."; else warn "NVRAM > WriteFlash is '$wf' (should be true so iMessage keys survive reboots)."; fi
  marker="$WORKDIR/nvram-test-pending"
  boot=$(sysctl -n kern.boottime 2>/dev/null)
  if [ -f "$marker" ]; then
    saved=$(cat "$marker")
    if [ "$saved" = "$boot" ]; then
      info "NVRAM test variable is waiting for a reboot. Reboot, then re-run to verify persistence."
    elif nvram iservicestest >/dev/null 2>&1; then
      ok "NVRAM persisted across a reboot (iMessage keys can be stored)."
      sudo nvram -d iservicestest; rm -f "$marker"
    else
      warn "NVRAM did NOT persist across the reboot. iMessage can't keep its keys, which causes sign-in loops."
      echo "      Check NVRAM > WriteFlash, your emulated NVRAM setup (OpenVariableRuntimeDxe / LogoutHook), and BIOS."
      rm -f "$marker"
    fi
  elif [ "$CHECK_ONLY" -eq 0 ]; then
    mkdir -p "$WORKDIR"
    if sudo nvram iservicestest=ok 2>/dev/null; then
      printf '%s' "$boot" > "$marker"
      info "Set an NVRAM test variable. Reboot once, then re-run this script to verify NVRAM persistence."
    fi
  fi

  live_serial=$(ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/{print $4}')
  if [ -n "$live_serial" ]; then
    if [ -n "$SERIAL" ] && [ "$live_serial" != "$SERIAL" ]; then
      warn "Running serial ($live_serial) differs from config.plist ($SERIAL): reboot to apply."
    else
      ok "Running serial matches config.plist ($live_serial)."
    fi
  fi
}

# ------------------------------------------------- fix en0 MAC / ROM mismatch
is_unicast() { local f=$((16#${1:0:2})); [ $((f & 1)) -eq 0 ]; }

# 00:16:CB is a real Apple OUI (the one Dortania's iServices guide uses)
rand_apple_mac() {
  printf '0016CB%s' "$(openssl rand -hex 3 | tr 'a-f' 'A-F')"
}

is_apple_oui() {
  case "${1:0:6}" in
    0016CB|0017F2|001B63|001CB3|001EC2|001FF3|001F5B|001E52|001D4F|002241|0023DF|002500|0026BB|00254B|0025BC|002608|00264A|0026B0|002312|002332|00236C|002436|0021E9|001124|000A95|000A27|000393|000502|000D93|001451|0019E3) return 0 ;;
  esac
  return 1
}

# Small perl helper: finds/replaces a 6-byte MAC inside an ACPI .aml and
# recomputes the table checksum (byte 9) so the table stays valid.
#   patch_mac.pl <exact|struct|count-exact|count-struct> <OLDHEX|-> <NEWHEX> <file>
write_patcher() {
  mkdir -p "$WORKDIR"
  cat > "$WORKDIR/patch_mac.pl" <<'PERL'
use strict; use warnings;
my ($mode, $old, $new, $file) = @ARGV;
open(my $in, '<:raw', $file) or die "open $file: $!";
local $/; my $d = <$in>; close $in;
my $dry  = ($mode =~ /^count/) ? 1 : 0;
my $newb = pack("H12", $new);
my $n = 0;
if ($mode =~ /exact/) {
  my $oldb = pack("H12", $old);
  $n = ($d =~ s/\Q$oldb\E/$newb/g);
} else {
  # AML:  Name (MAC, Buffer (6) { b0..b5 })  ->  "MAC_" 11 09 0A 06 <6 bytes>
  $n = ($d =~ s/(MAC_\x11\x09\x0a\x06).{6}/$1$newb/s);
}
$n = 0 unless $n;
if ($n && !$dry) {
  my $len = unpack("V", substr($d, 4, 4));
  substr($d, 9, 1) = "\0";
  my $sum = unpack("%32C*", substr($d, 0, $len));
  substr($d, 9, 1) = chr((256 - ($sum % 256)) % 256);
  open(my $out, '>:raw', $file) or die "write $file: $!";
  print $out $d; close $out;
}
print "$n\n";
PERL
}

set_rom() {  # $1 = 12 hex chars
  local b64
  backup_config
  b64=$(printf '%s' "$1" | xxd -r -p | base64)
  plset PlatformInfo.Generic.ROM data "$b64"
  if plutil -lint "$CONFIG" >/dev/null 2>&1; then
    ok "ROM set to $1 in config.plist."
    ROM_HEX="$1"
  else
    err "config.plist failed validation, restoring backup."
    sudo cp "$BACKUP" "$CONFIG"
    return 1
  fi
}

fix_mac() {
  local en0 mac_hex target ts f n acpi mode hits old_arg pretty
  local invalid=0 mismatch=0 nonapple=0
  en0=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2}')
  [ -n "$en0" ] || return 0
  mac_hex=$(printf '%s' "$en0" | tr -d ':' | tr 'a-f' 'A-F')

  is_unicast "$mac_hex" || invalid=1
  is_apple_oui "$mac_hex" || nonapple=1
  if [ -n "$ROM_HEX" ] && [ "$ROM_HEX" != "$mac_hex" ]; then mismatch=1; fi
  if [ $invalid -eq 0 ] && [ $mismatch -eq 0 ] && [ $nonapple -eq 0 ] && [ "$FORCE_MAC" -eq 0 ]; then return 0; fi

  echo
  info "en0 MAC / ROM fix"
  [ $nonapple -eq 1 ] && info "en0 MAC $mac_hex doesn't use an Apple OUI. Dortania recommends one (e.g. 00:16:CB)."
  if [ "$CHECK_ONLY" -eq 1 ]; then
    info "--check given: not changing anything."
    return 0
  fi

  # Case A: en0 MAC is a valid Apple-style address, so just make ROM match it.
  if [ $invalid -eq 0 ] && [ $nonapple -eq 0 ] && [ "$FORCE_MAC" -eq 0 ]; then
    if ask_yn "en0 MAC $mac_hex is valid. Set ROM in config.plist to match it?"; then
      set_rom "$mac_hex" && REBOOT_NEEDED=1
    fi
    return 0
  fi

  # Case B: invalid, non-Apple or forced. Change the MAC NullEthernet hands out.
  target=$(rand_apple_mac)
  pretty=$(printf '%s' "$target" | sed 's/../&:/g; s/:$//' | tr 'A-F' 'a-f')
  info "New en0 MAC will be $pretty (Apple OUI); ROM will be set to match."

  acpi="$(dirname "$CONFIG")/ACPI"
  if [ ! -d "$acpi" ]; then
    warn "No ACPI folder at $acpi, can't patch automatically."
    return 0
  fi
  command -v perl >/dev/null 2>&1 || { warn "perl not found, can't patch automatically."; return 0; }
  write_patcher

  # 1) look for the exact bytes of the current MAC in the SSDTs
  mode=exact; hits=""
  for f in "$acpi"/*.aml; do
    [ -f "$f" ] || continue
    n=$(perl "$WORKDIR/patch_mac.pl" count-exact "$mac_hex" "$target" "$f" 2>/dev/null)
    if [ "${n:-0}" -gt 0 ]; then hits="$hits$f"$'\n'; fi
  done
  # 2) otherwise look for a  Name (MAC, Buffer (6) {...})  in the SSDTs
  if [ -z "$hits" ]; then
    mode=struct
    for f in "$acpi"/*.aml; do
      [ -f "$f" ] || continue
      n=$(perl "$WORKDIR/patch_mac.pl" count-struct - "$target" "$f" 2>/dev/null)
      if [ "${n:-0}" -gt 0 ]; then hits="$hits$f"$'\n'; fi
    done
  fi

  if [ -z "$hits" ]; then
    warn "Couldn't find the en0 MAC in any .aml under $acpi."
    echo "      NullEthernet may be generating it at boot, or it lives in another SSDT/kext."
    echo "      Manual fix: set the MAC bytes in your SSDT-RMNE to: $(printf '%s' "$target" | sed 's/../& /g')"
    echo "      and keep ROM = $target in config.plist."
    return 0
  fi

  info "These files contain the MAC and will be patched (backups: $WORKDIR/backups):"
  printf '%s' "$hits" | sed 's/^/      /'
  ask_yn "Patch them to $pretty and set ROM to match?" || { warn "Cancelled. Nothing changed."; return 0; }
  backup_efi || return 1

  mkdir -p "$WORKDIR/backups"
  ts=$(date +%Y%m%d-%H%M%S)
  old_arg="$mac_hex"; [ "$mode" = "struct" ] && old_arg="-"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cp "$f" "$WORKDIR/backups/$(basename "$f").$ts" || { err "Backup of $f failed, stopping."; return 1; }
    n=$(sudo perl "$WORKDIR/patch_mac.pl" "$mode" "$old_arg" "$target" "$f" </dev/null)
    ok "Patched $(basename "$f") ($n change(s), ACPI checksum recomputed)"
  done <<EOF_HITS
$hits
EOF_HITS

  if [ "$ROM_HEX" != "$target" ]; then set_rom "$target"; fi
  REBOOT_NEEDED=1
  ok "Done. After a reboot, 'ifconfig en0 | grep ether' should show $pretty"
}

# ------------------------------------------------ model / diagnostics
tahoe_model_check() {
  local major
  major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
  [ "${major:-0}" -ge 26 ] 2>/dev/null || return 0
  case "$MODEL" in
    MacBookPro16,1|MacBookPro16,4|MacBookPro16,2|iMac20,1|iMac20,2|MacPro7,1)
      ok "$MODEL is one of macOS 26's supported Intel models." ;;
    *)
      warn "$MODEL isn't one of the few Intel Macs macOS 26 officially supports."
      echo "      (MacBookPro16,1/16,2/16,4, iMac20,1/20,2, MacPro7,1.) This may or may not matter for iMessage."
      echo "      To try one: ./iservices-helper.sh --new-smbios   (full EFI backup is made first;"
      echo "      you'll be signed out of iCloud/iMessage, and power management may need re-checking)." ;;
  esac
}

diagnose() {
  local ts out secs pid i f
  ts=$(date +%Y%m%d-%H%M%S)
  secs=90
  mkdir -p "$WORKDIR"
  out="$WORKDIR/diagnose-$ts.txt"
  echo
  info "Live capture: the script will record iMessage/account logs for ${secs}s."
  info "When you press Enter, switch to Messages and sign in (let it bounce if it does)."
  read -r -p "Press Enter to start recording... " _
  {
    echo "== $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "== model: $MODEL  serial: $SERIAL  ROM: $ROM_HEX"
    echo "== en0: $(ifconfig en0 2>/dev/null | awk '/ether/{print $2}')"
    echo "== live log"
  } > "$out"
  sudo log stream --style compact --level debug \
    --predicate 'process == "imagent" OR process == "identityservicesd" OR process == "Messages" OR process == "accountsd" OR process == "akd" OR process == "apsd"' \
    >> "$out" 2>/dev/null &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9; do sleep $((secs / 9)); printf '.'; done; echo
  sudo kill "$pid" >/dev/null 2>&1
  sudo pkill -f 'log stream --style compact --level debug' >/dev/null 2>&1
  wait "$pid" 2>/dev/null

  echo
  info "Error/fault-level entries (these are the real errors):"
  awk '$3 ~ /^[EF]/' "$out" | grep -vE 'ACDAccountStore was invalidated|invalidated because' | tail -30 | cut -c1-230
  echo
  info "Sign-out / auth / token related lines:"
  grep -iE 'sign.?out|signed out|log.?out|logged out|unauthor|authenticat|token|expired|rejected|denied|deregist|unregist|[^a-z]40[13][^0-9]' "$out" \
    | grep -vE 'ACDAccountStore was invalidated|invalidated because|^==' | tail -30 | cut -c1-230
  echo
  info "What Messages itself logged on the way out:"
  grep -E ' Messages\[' "$out" | grep -iE 'exit|terminat|quit|crash|signal|abort|sign' | tail -10 | cut -c1-230
  echo
  for f in $(ls -t "$HOME"/Library/Logs/DiagnosticReports/* /Library/Logs/DiagnosticReports/* 2>/dev/null \
             | grep -iE 'Messages|imagent|identityservices' | head -3); do
    info "Crash report: $f"
    grep -iE 'exception|termination|signal|reason|namespace' "$f" | head -8 | cut -c1-200
  done
  ok "Full log saved to $out"
  info "Paste the three sections above if you want help reading them."
}

# ------------------------------------------------------------------ main
find_config
ok "Using $CONFIG"

read_smbios
SMBIOS_COMPLETE=0
if report_smbios; then
  ok "Custom SMBIOS is set."
  SMBIOS_COMPLETE=1
else
  warn "Custom SMBIOS is NOT fully set."
fi
tahoe_model_check

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ "$SMBIOS_COMPLETE" -eq 0 ] && info "--check given: not changing anything."
elif [ "$FORCE_SMBIOS" -eq 1 ]; then
  warn "--new-smbios replaces serial/MLB/UUID: you'll be signed out of iCloud/iMessage."
  ask_yn "Continue?" && setup_smbios
elif [ "$SMBIOS_COMPLETE" -eq 0 ]; then
  ask_yn "Download GenSMBIOS and set one up now?" && setup_smbios
fi

REBOOT_NEEDED=0
system_checks
fix_mac
[ "$DIAGNOSE" -eq 1 ] && diagnose

echo
info "Next steps"
if [ "$REBOOT_NEEDED" -eq 1 ]; then
  echo "    1. REBOOT NOW (config.plist/ACPI changed), then re-run this script with --check."
else
  echo "    1. Reboot if config.plist or ACPI files changed (and make sure you're booting this EFI)."
fi
echo "    2. System Settings > sign in to your Apple ID, then open Messages and FaceTime."
echo "    3. Use a unique serial per machine, and never one belonging to a real Mac."
echo "    4. If sign-in still fails: re-check en0 built-in, NVRAM ROM/MLB, then sign out of"
echo "       iCloud, reboot, and sign back in."
