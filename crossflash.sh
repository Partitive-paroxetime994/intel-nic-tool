#!/usr/bin/env bash
# intel-nic-crossflash — safely crossflash OEM (Dell/Lenovo/HP) Intel NICs to
# generic Intel firmware, with backup gates and a flash-size brick guard.
#
# v1 targets the 700-series (X710-DA2); other cards are added as profiles/.
# No action runs unless named explicitly.
set -euo pipefail

SELF="$(basename "$0")"
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$ROOT/lib.sh"

# --- tool locations (override via env) --------------------------------------
: "${NVM_DIR:=}"        # dir with nvmupdate64e + nvmupdate.cfg
: "${BOOTUTIL_DIR:=}"   # dir with bootutil64e
: "${IQV_DIR:=}"        # extracted iqvlinux source root (inc/ + src/)
: "${WORK_DIR:=$PWD/crossflash-work}"   # backups + logs land here
ASSUME_YES=0

usage() {
cat <<EOF
$SELF — safely crossflash OEM Intel NICs to generic Intel firmware.

Usage: $SELF [-y] <action> [args]

Read-only / safe:
  inventory                  List Intel NICs: iface, MAC, PCI id, subsystem, etrack
  setup                      Build + load the iqvlinux QV driver (bootutil needs it)
  backup   <MAC> <profile>   Full NVM backup to WORK_DIR, size-checked vs profile
  verify   <MAC> <profile>   Post-flash sanity check

Writes firmware (each gated by confirmation):
  replace-orom <MAC>            bootutil -up=combo: swap OEM option-ROM for Intel's
  flash        <MAC> <profile>  Full crossflash (preflight, OROM, cfg edit, nvmupdate)
  disable-orom <MAC>            bootutil -FD: disable option-ROM (stops UEFI POST hang)
  restore      <MAC> <file>     bootutil -RESTOREIMAGE from a backup (recovery)

Options:  -y  assume yes (still runs preflight gates)   -h  help

Env:  NVM_DIR  BOOTUTIL_DIR  IQV_DIR  WORK_DIR
Profiles: profiles/<name>.conf   MAC may be given with or without separators.
EOF
}

load_profile() {
    local p="$ROOT/profiles/$1.conf"
    [ -f "$p" ] || die "no such profile: $1 (looked in $p)"
    # shellcheck disable=SC1090
    . "$p"
    [ -n "${DEVICE_ID:-}" ] || die "profile $1 missing DEVICE_ID"
    [ -n "${EXPECTED_FLASH_BYTES:-}" ] || die "profile $1 missing EXPECTED_FLASH_BYTES"
}

act_inventory() {
    need_cmd ethtool; need_cmd lspci
    printf '%-15s %-13s %-11s %-13s %-9s\n' IFACE MAC PCI-ID SUBSYSTEM ETRACK
    local ifc mac slot pciid sub et
    for ifc in $(find_intel_ifaces); do
        mac=$(mac_norm "$(cat "/sys/class/net/$ifc/address")")
        slot=$(basename "$(readlink -f "/sys/class/net/$ifc/device")")
        pciid=$(lspci -s "$slot" -n 2>/dev/null | awk '{print $3}')
        sub=$(lspci -s "$slot" -vnn 2>/dev/null | awk -F'[][]' '/Subsystem/{print $2; exit}')
        et=$(get_etrack "$ifc")
        printf '%-15s %-13s %-11s %-13s %-9s\n' "$ifc" "$mac" "${pciid:-?}" "${sub:-?}" "${et:-?}"
    done
}

act_setup() {
    need_root
    [ -n "$IQV_DIR" ] || die "set IQV_DIR to the extracted iqvlinux source root"
    local ldh="$IQV_DIR/inc/linux/linuxdefs.h"
    local mk="$IQV_DIR/src/linux/driver"
    [ -f "$mk/Makefile" ] || die "no Makefile under $mk"
    if [ -f "$ldh" ] && ! grep -q 'KERNEL_VERSION(6,8,0)' "$ldh"; then
        log "patching linuxdefs.h (kernel >= 6.8 removed iommu_present)"
        sed -i '/#if LINUX_VERSION_CODE >= KERNEL_VERSION(3,2,0)/ s/$/ \&\& LINUX_VERSION_CODE < KERNEL_VERSION(6,8,0)/' "$ldh"
    fi
    log "building iqvlinux"
    make -C "$mk" NALDIR="$IQV_DIR" >/dev/null
    [ -f "$mk/iqvlinux.ko" ] || die "build failed: no iqvlinux.ko"
    lsmod | grep -q '^iqvlinux' || insmod "$mk/iqvlinux.ko"
    lsmod | grep -q '^iqvlinux' || die "insmod failed"
    log "iqvlinux loaded"
    warn "if bootutil later says 'inaccessible device memory', add kernel param"
    warn "iomem=relaxed (and reboot) so the QV driver can map device memory."
}

act_backup() {
    need_root; need_cmd stat
    local mac; mac=$(mac_norm "$1"); load_profile "$2"
    [ -n "$BOOTUTIL_DIR" ] || die "set BOOTUTIL_DIR"
    mkdir -p "$WORK_DIR"
    local nic; nic=$(bootutil_nic_for_mac "$BOOTUTIL_DIR" "$mac")
    [ -n "$nic" ] || die "bootutil can't find NIC $mac — run '$SELF setup' first (QV driver/iomem)"
    local out; out="$WORK_DIR/${mac}_$(date +%Y%m%d-%H%M%S).nvm"
    log "saving NVM image of NIC $nic ($mac) -> $out"
    ( cd "$BOOTUTIL_DIR" && ./bootutil64e -NIC="$nic" -SAVEIMAGE -FILE="$out" )
    local sz; sz=$(file_size "$out")
    log "backup size: $sz bytes (profile expects $EXPECTED_FLASH_BYTES)"
    [ "$sz" = "$EXPECTED_FLASH_BYTES" ] \
        || die "SIZE MISMATCH — card flash != profile. Wrong profile = brick risk. ABORT."
    command -v sha256sum >/dev/null && sha256sum "$out"
    log "backup verified OK"
}

act_replace_orom() {
    need_root
    local mac; mac=$(mac_norm "$1")
    [ -n "$BOOTUTIL_DIR" ] || die "set BOOTUTIL_DIR"
    local nic; nic=$(bootutil_nic_for_mac "$BOOTUTIL_DIR" "$mac")
    [ -n "$nic" ] || die "bootutil can't find NIC $mac (run setup; QV/iomem?)"
    confirm "Replace option-ROM on NIC $nic ($mac) via bootutil -up=combo?" || die "aborted"
    ( cd "$BOOTUTIL_DIR" && ./bootutil64e -NIC="$nic" -up=combo )
}

act_flash() {
    need_root
    local mac; mac=$(mac_norm "$1"); load_profile "$2"
    [ -n "$NVM_DIR" ] || die "set NVM_DIR"
    local cfg="$NVM_DIR/nvmupdate.cfg"
    [ -f "$cfg" ] || die "no nvmupdate.cfg in $NVM_DIR"
    [ -f "$NVM_DIR/$NVM_IMAGE" ] || die "target image $NVM_IMAGE not found in $NVM_DIR"

    hr; log "PREFLIGHT — $mac ($PROFILE_NAME)"
    local ifc et; ifc=$(iface_for_mac "$mac") || die "no interface with MAC $mac"
    et=$(get_etrack "$ifc"); [ -n "$et" ] || die "could not read etrack from $ifc"
    log "interface=$ifc  etrack=$et  target=$NVM_IMAGE"

    # Gate: a size-verified backup must already exist.
    local bk; bk=$(latest_backup "$mac")
    [ -n "$bk" ] || die "no backup in $WORK_DIR for $mac — run '$SELF backup $mac $2' first"
    local sz; sz=$(file_size "$bk")
    [ "$sz" = "$EXPECTED_FLASH_BYTES" ] || die "backup $bk is $sz bytes, expected $EXPECTED_FLASH_BYTES"
    log "verified backup present: $bk ($sz bytes)"

    hr
    warn "About to WRITE FIRMWARE to $mac — irreversible."
    warn "A wrong flash size could HARD-brick the card (recovery needs an SPI flasher)."
    confirm "Proceed with crossflash of $mac?" || die "aborted by user"

    log "step 1/3: replace OEM option-ROM"
    ASSUME_YES=1 act_replace_orom "$mac"

    log "step 2/3: inject etrack $et into cfg REPLACES"
    [ -f "$cfg.orig" ] || cp "$cfg" "$cfg.orig"
    append_etrack_to_cfg "$cfg" "$NVM_IMAGE" "$et" > "$cfg.new" && mv "$cfg.new" "$cfg"
    grep -q "$et" "$cfg" || die "etrack injection failed"

    log "step 3/3: nvmupdate (minutes; DO NOT interrupt or power off)"
    mkdir -p "$WORK_DIR"
    ( cd "$NVM_DIR" && ./nvmupdate64e -u -m "$mac" -rd -b -s \
        -l "$WORK_DIR/nvmupdate_$mac.log" -o "$WORK_DIR/nvmupdate_$mac.xml" )
    hr
    log "nvmupdate finished — see $WORK_DIR/nvmupdate_$mac.xml"
    warn "COLD POWER-CYCLE (full A/C off) required before the new NVM loads."
    warn "After power-cycle: '$SELF verify $mac $2' then '$SELF disable-orom $mac'."
}

act_disable_orom() {
    need_root
    local mac; mac=$(mac_norm "$1")
    [ -n "$BOOTUTIL_DIR" ] || die "set BOOTUTIL_DIR"
    local nic; nic=$(bootutil_nic_for_mac "$BOOTUTIL_DIR" "$mac")
    [ -n "$nic" ] || die "bootutil can't find NIC $mac"
    confirm "Disable option-ROM (flash) on NIC $nic ($mac)?" || die "aborted"
    ( cd "$BOOTUTIL_DIR" && ./bootutil64e -NIC="$nic" -FD )
}

act_restore() {
    need_root
    local mac; mac=$(mac_norm "$1"); local file="$2"
    [ -f "$file" ] || die "no such backup file: $file"
    [ -n "$BOOTUTIL_DIR" ] || die "set BOOTUTIL_DIR"
    local nic; nic=$(bootutil_nic_for_mac "$BOOTUTIL_DIR" "$mac")
    [ -n "$nic" ] || die "bootutil can't find NIC $mac"
    warn "RESTORE overwrites NIC $nic ($mac) with $file"
    confirm "Proceed with restore?" || die "aborted"
    ( cd "$BOOTUTIL_DIR" && ./bootutil64e -NIC="$nic" -RESTOREIMAGE -FILE="$file" )
}

act_verify() {
    local mac; mac=$(mac_norm "$1"); load_profile "$2"
    local ifc; ifc=$(iface_for_mac "$mac") || die "no interface with MAC $mac"
    log "ethtool -i $ifc:"; ethtool -i "$ifc" | sed 's/^/    /'
    log "etrack now: $(get_etrack "$ifc")  (was Dell 80002E8D before crossflash)"
    log "full picture: '$SELF inventory'"
}

while getopts ":yh" opt; do
    case $opt in
        y) ASSUME_YES=1 ;;
        h) usage; exit 0 ;;
        *) ;;
    esac
done
shift $((OPTIND - 1))

action="${1:-}"; [ $# -gt 0 ] && shift || true
case "$action" in
    inventory)    act_inventory "$@" ;;
    setup)        act_setup "$@" ;;
    backup)       [ $# -ge 2 ] || die "usage: $SELF backup <MAC> <profile>"; act_backup "$@" ;;
    flash)        [ $# -ge 2 ] || die "usage: $SELF flash <MAC> <profile>"; act_flash "$@" ;;
    replace-orom) [ $# -ge 1 ] || die "usage: $SELF replace-orom <MAC>"; act_replace_orom "$@" ;;
    disable-orom) [ $# -ge 1 ] || die "usage: $SELF disable-orom <MAC>"; act_disable_orom "$@" ;;
    restore)      [ $# -ge 2 ] || die "usage: $SELF restore <MAC> <backup-file>"; act_restore "$@" ;;
    verify)       [ $# -ge 2 ] || die "usage: $SELF verify <MAC> <profile>"; act_verify "$@" ;;
    ""|help|--help) usage ;;
    *) die "unknown action: $action (try '$SELF help')" ;;
esac
