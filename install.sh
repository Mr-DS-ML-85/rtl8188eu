#!/usr/bin/env bash
# =============================================================================
#  RTL8188EU Auto USB ID Patcher & Installer
#  Author : Mr-DS-ML-85 (https://github.com/Mr-DS-ML-85)
#  License: GPL-2.0
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DRIVER_DIR="$(cd "$(dirname "$0")" && pwd)"
USB_INTF="$DRIVER_DIR/os_dep/usb_intf.c"
OSDEP_SVC="$DRIVER_DIR/include/osdep_service.h"
RTW_LED="$DRIVER_DIR/core/rtw_led.c"
REALTEK_VID="0bda"

banner() {
    echo -e "${CYAN}"
    echo "  ██████╗ ████████╗██╗      █████╗  █████╗  █████╗  █████╗ ███████╗██╗   ██╗"
    echo "  ██╔══██╗╚══██╔══╝██║     ██╔══██╗██╔══██╗██╔══██╗██╔══██╗██╔════╝██║   ██║"
    echo "  ██████╔╝   ██║   ██║     ╚█████╔╝╚█████╔╝╚█████╔╝╚█████╔╝█████╗  ██║   ██║"
    echo "  ██╔══██╗   ██║   ██║     ██╔══██╗██╔══██╗██╔══██╗██╔══██╗██╔══╝  ██║   ██║"
    echo "  ██║  ██║   ██║   ███████╗╚█████╔╝╚█████╔╝╚█████╔╝╚█████╔╝███████╗╚██████╔╝"
    echo "  ╚═╝  ╚═╝   ╚═╝   ╚══════╝ ╚════╝  ╚════╝  ╚════╝  ╚════╝ ╚══════╝ ╚═════╝ "
    echo -e "${NC}"
    echo -e "${BOLD}  RTL8188EU Auto USB ID Patcher & Installer${NC}"
    echo -e "  Author: ${GREEN}Mr-DS-ML-85${NC} | Kernel: ${YELLOW}$(uname -r)${NC}"
    echo ""
}

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${CYAN}${BOLD}==> $1${NC}"; }

# -----------------------------------------------------------------------------
# 1. Detect connected Realtek USB adapters
# -----------------------------------------------------------------------------
detect_usb_ids() {
    log_section "Scanning USB devices for Realtek adapters (VID: 0x${REALTEK_VID})"

    if ! command -v lsusb &>/dev/null; then
        log_error "'lsusb' not found. Install it: sudo apt install usbutils"
        exit 1
    fi

    DETECTED_IDS=()
    while IFS= read -r line; do
        pid=$(echo "$line" | grep -oP "(?<=${REALTEK_VID}:)[0-9a-fA-F]{4}")
        if [ -n "$pid" ]; then
            DETECTED_IDS+=("$pid")
            log_info "Found Realtek USB device: ${REALTEK_VID}:${pid}  →  $line"
        fi
    done < <(lsusb | grep -i "$REALTEK_VID")

    if [ ${#DETECTED_IDS[@]} -eq 0 ]; then
        log_warn "No Realtek USB adapters detected. Plug in your device and re-run."
        log_warn "Continuing anyway — existing IDs in driver will be used."
    fi
}

# -----------------------------------------------------------------------------
# 2. Patch usb_intf.c — add missing USB IDs
# -----------------------------------------------------------------------------
patch_usb_ids() {
    log_section "Patching USB device ID table in os_dep/usb_intf.c"

    if [ ! -f "$USB_INTF" ]; then
        log_error "File not found: $USB_INTF"
        exit 1
    fi

    # Create a backup
    cp "$USB_INTF" "${USB_INTF}.bak"
    log_info "Backup saved: ${USB_INTF}.bak"

    for pid in "${DETECTED_IDS[@]}"; do
        pid_upper=$(echo "$pid" | tr '[:lower:]' '[:upper:]')
        pid_lower=$(echo "$pid" | tr '[:upper:]' '[:lower:]')

        # Check if ID already exists (case-insensitive)
        if grep -qi "USB_DEVICE(USB_VENDER_ID_REALTEK.*0x${pid_lower}\|USB_DEVICE(0x${REALTEK_VID}.*0x${pid_lower}" "$USB_INTF"; then
            log_info "ID 0x${pid_lower} already present — skipping."
        else
            # Insert before the terminating {} of the usb id table
            sed -i "/^[[:space:]]*{}[[:space:]]*$/i\\\\t{USB_DEVICE(USB_VENDER_ID_REALTEK, 0x${pid_lower})}, /* added by install.sh */" "$USB_INTF"
            log_info "Added USB ID: {USB_DEVICE(USB_VENDER_ID_REALTEK, 0x${pid_lower})}"
        fi
    done
}

# -----------------------------------------------------------------------------
# 3. Apply kernel 6.15+ API compatibility patches
# -----------------------------------------------------------------------------
patch_kernel_api() {
    log_section "Applying kernel 6.15+ API compatibility patches"

    # del_timer_sync → timer_delete_sync
    COUNT=$(grep -r "del_timer_sync" "$DRIVER_DIR" --include="*.c" --include="*.h" -l 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 0 ]; then
        grep -rl "del_timer_sync" "$DRIVER_DIR" --include="*.c" --include="*.h" | \
            xargs sed -i 's/del_timer_sync/timer_delete_sync/g'
        log_info "Patched del_timer_sync → timer_delete_sync  (${COUNT} file(s))"
    else
        log_info "del_timer_sync: already patched or not present."
    fi

    # del_timer (standalone) → timer_delete
    COUNT=$(grep -rP "\bdel_timer\b" "$DRIVER_DIR" --include="*.c" --include="*.h" -l 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 0 ]; then
        grep -rlP "\bdel_timer\b" "$DRIVER_DIR" --include="*.c" --include="*.h" | \
            xargs sed -i 's/\bdel_timer\b/timer_delete/g'
        log_info "Patched del_timer → timer_delete  (${COUNT} file(s))"
    else
        log_info "del_timer: already patched or not present."
    fi

    # from_timer → timer_container_of
    COUNT=$(grep -r "from_timer" "$DRIVER_DIR" --include="*.c" --include="*.h" -l 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 0 ]; then
        grep -rl "from_timer" "$DRIVER_DIR" --include="*.c" --include="*.h" | \
            xargs sed -i 's/from_timer/timer_container_of/g'
        log_info "Patched from_timer → timer_container_of  (${COUNT} file(s))"
    else
        log_info "from_timer: already patched or not present."
    fi
}

# -----------------------------------------------------------------------------
# 4. Blacklist conflicting in-kernel drivers
# -----------------------------------------------------------------------------
blacklist_conflicts() {
    log_section "Blacklisting conflicting drivers"

    BLACKLIST_FILE="/etc/modprobe.d/rtl8188eu-blacklist.conf"

    echo -e "# Auto-generated by rtl8188eu install.sh (Mr-DS-ML-85)\nblacklist rtl8xxxu\nblacklist r8188eu" \
        | sudo tee "$BLACKLIST_FILE" > /dev/null

    log_info "Blacklisted: rtl8xxxu, r8188eu  →  $BLACKLIST_FILE"

    # Unload if currently running
    for mod in rtl8xxxu r8188eu 8188eu; do
        if lsmod | grep -q "^$mod"; then
            sudo modprobe -r "$mod" 2>/dev/null && log_info "Unloaded module: $mod"
        fi
    done
}

# -----------------------------------------------------------------------------
# 5. Compile
# -----------------------------------------------------------------------------
compile_driver() {
    log_section "Compiling driver"

    cd "$DRIVER_DIR"
    make clean 2>/dev/null || true

    if make -j"$(nproc)"; then
        log_info "Compilation successful. Module: ${DRIVER_DIR}/8188eu.ko"
    else
        log_error "Compilation failed. Check errors above."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# 6. Install
# -----------------------------------------------------------------------------
install_driver() {
    log_section "Installing driver"

    cd "$DRIVER_DIR"
    sudo make install
    sudo depmod -a

    log_info "Driver installed to /lib/modules/$(uname -r)/kernel/drivers/staging/r8188eu/"
    log_info "Firmware copied to /lib/firmware/rtlwifi/"
}

# -----------------------------------------------------------------------------
# 7. Load & verify
# -----------------------------------------------------------------------------
load_and_verify() {
    log_section "Loading module and verifying"

    sudo modprobe 8188eu
    sleep 1

    if lsmod | grep -q "8188eu"; then
        log_info "Module loaded successfully."
    else
        log_error "Module failed to load. Run: sudo dmesg | tail -20"
        exit 1
    fi

    echo ""
    log_info "Network interfaces:"
    ip link show | grep -E "wlan|wlx|wlp" || log_warn "No wireless interface found. Check: sudo dmesg | grep 8188eu"

    echo ""
    echo -e "${GREEN}${BOLD}Done! Your RTL8188EU adapter should now be active.${NC}"
    echo -e "To connect to WiFi: ${CYAN}nmtui${NC}  or  ${CYAN}nmcli dev wifi connect 'SSID' password 'PASS'${NC}"
}

# =============================================================================
#  Main
# =============================================================================
banner

if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root: sudo ./install.sh"
    exit 1
fi

detect_usb_ids
patch_usb_ids
patch_kernel_api
blacklist_conflicts
compile_driver
install_driver
load_and_verify
