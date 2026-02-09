#!/bin/bash
# OVS Mirror Configuration Script for Malcolm/Claroty
# 支援模式：--vm <vmid> | --cleanup <vmid> | --all | --status

set -euo pipefail

# ============== 配置區 ==============
ZONE1_BRIDGE="ovs_zone1"
ZONE2_BRIDGE="ovs_zone2"
ZONE1_PORT="eno12419"
ZONE2_PORT="eno12429"

# VM 與 tap 介面對應
declare -A VM_TAPS_Z1=(
    [100]="tap100i1"
    [101]="tap101i1"
)
declare -A VM_TAPS_Z2=(
    [100]="tap100i2"
    [101]="tap101i2"
)

MAX_WAIT=120  # 最大等待秒數
WAIT_INTERVAL=5  # 每次等待間隔

# ============== 日誌設定 ==============
LOG_DIR="/var/log/openvswitch"
LOG_FILE="$LOG_DIR/ovs-mirrors.log"
mkdir -p "$LOG_DIR"

# ============== 日誌函數 ==============
log() {
    local level="$1"
    shift
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$timestamp] [$level] $*"

    # 輸出到獨立日誌檔案
    echo "$msg" >> "$LOG_FILE"

    # 輸出到 syslog
    logger -t "ovs-mirrors" -p "user.$level" "$*"

    # 輸出到 stdout（方便手動執行時查看）
    echo "$msg"
}

log_info()  { log info "$@"; }
log_warn()  { log warning "$@"; }
log_error() { log err "$@"; }

# ============== 輔助函數 ==============

# 檢查 port 是否存在於指定 bridge
port_exists() {
    local bridge="$1"
    local port="$2"
    ovs-vsctl list-ports "$bridge" 2>/dev/null | grep -q "^${port}$"
}

# 等待 tap 介面出現
wait_for_tap() {
    local bridge="$1"
    local tap="$2"
    local waited=0

    while ! port_exists "$bridge" "$tap"; do
        if [ $waited -ge $MAX_WAIT ]; then
            log_error "Timeout waiting for $tap on $bridge (waited ${MAX_WAIT}s)"
            return 1
        fi
        log_info "Waiting for $tap on $bridge... (${waited}s)"
        sleep $WAIT_INTERVAL
        waited=$((waited + WAIT_INTERVAL))
    done
    log_info "Found $tap on $bridge"
    return 0
}

# 設定 promiscuous mode
setup_promisc() {
    log_info "Setting promiscuous mode on $ZONE1_PORT and $ZONE2_PORT"
    ip link set "$ZONE1_PORT" promisc on || log_warn "Failed to set promisc on $ZONE1_PORT"
    ip link set "$ZONE2_PORT" promisc on || log_warn "Failed to set promisc on $ZONE2_PORT"
}

# 清理指定 VM 的 mirror
cleanup_vm_mirrors() {
    local vmid="$1"
    log_info "Cleaning up mirrors for VM $vmid"

    for mirror_name in "mirror_vm${vmid}_z1" "mirror_vm${vmid}_z2"; do
        local mirror_uuid
        # 注意：使用 || true 避免 grep 找不到時因 set -e 導致腳本退出
        mirror_uuid=$(ovs-vsctl --columns=_uuid,name find Mirror name="$mirror_name" 2>/dev/null | grep "_uuid" | awk '{print $3}' || true)
        if [ -n "$mirror_uuid" ]; then
            log_info "Removing mirror $mirror_name (UUID: $mirror_uuid)"
            ovs-vsctl remove Bridge "$ZONE1_BRIDGE" mirrors "$mirror_uuid" 2>/dev/null || true
            ovs-vsctl remove Bridge "$ZONE2_BRIDGE" mirrors "$mirror_uuid" 2>/dev/null || true
            ovs-vsctl destroy Mirror "$mirror_uuid" 2>/dev/null || true
        else
            log_info "Mirror $mirror_name not found, skipping"
        fi
    done
}

# 為指定 VM 配置 mirror
configure_vm_mirrors() {
    local vmid="$1"
    local tap_z1="${VM_TAPS_Z1[$vmid]:-}"
    local tap_z2="${VM_TAPS_Z2[$vmid]:-}"

    if [ -z "$tap_z1" ] || [ -z "$tap_z2" ]; then
        log_error "Unknown VM ID: $vmid"
        return 1
    fi

    log_info "Configuring mirrors for VM $vmid (Zone1: $tap_z1, Zone2: $tap_z2)"

    # 先清理舊的 mirror
    cleanup_vm_mirrors "$vmid"

    # 等待 tap 介面
    if ! wait_for_tap "$ZONE1_BRIDGE" "$tap_z1"; then
        log_error "Cannot configure Zone1 mirror for VM $vmid: tap not found"
        return 1
    fi
    if ! wait_for_tap "$ZONE2_BRIDGE" "$tap_z2"; then
        log_error "Cannot configure Zone2 mirror for VM $vmid: tap not found"
        return 1
    fi

    # Zone1 Mirror
    log_info "Creating mirror_vm${vmid}_z1 on $ZONE1_BRIDGE"
    if ! ovs-vsctl \
        -- --id=@src get Port "$ZONE1_PORT" \
        -- --id=@dst get Port "$tap_z1" \
        -- --id=@m create Mirror "name=mirror_vm${vmid}_z1" \
             select-src-port=@src \
             select-dst-port=@src \
             output-port=@dst \
        -- add Bridge "$ZONE1_BRIDGE" mirrors @m; then
        log_error "Failed to create mirror_vm${vmid}_z1"
        return 1
    fi

    # Zone2 Mirror
    log_info "Creating mirror_vm${vmid}_z2 on $ZONE2_BRIDGE"
    if ! ovs-vsctl \
        -- --id=@src get Port "$ZONE2_PORT" \
        -- --id=@dst get Port "$tap_z2" \
        -- --id=@m create Mirror "name=mirror_vm${vmid}_z2" \
             select-src-port=@src \
             select-dst-port=@src \
             output-port=@dst \
        -- add Bridge "$ZONE2_BRIDGE" mirrors @m; then
        log_error "Failed to create mirror_vm${vmid}_z2"
        return 1
    fi

    log_info "Successfully configured mirrors for VM $vmid"
    return 0
}

# 配置所有 VM 的 mirror
configure_all_mirrors() {
    log_info "Configuring mirrors for all VMs"
    setup_promisc

    local failed=0
    for vmid in "${!VM_TAPS_Z1[@]}"; do
        if ! configure_vm_mirrors "$vmid"; then
            ((failed++))
        fi
    done

    if [ $failed -gt 0 ]; then
        log_warn "Completed with $failed failure(s)"
        return 1
    fi

    log_info "All mirrors configured successfully"
    return 0
}

# 顯示目前狀態
show_status() {
    echo "=== OVS Bridges ==="
    ovs-vsctl show

    echo ""
    echo "=== Mirror Status ==="
    ovs-vsctl list Mirror
}

# ============== 主程式 ==============
usage() {
    echo "Usage: $0 [--vm <vmid>] [--cleanup <vmid>] [--all] [--status]"
    echo "  --vm <vmid>      Configure mirrors for specific VM"
    echo "  --cleanup <vmid> Remove mirrors for specific VM"
    echo "  --all            Configure mirrors for all VMs (default)"
    echo "  --status         Show current mirror status"
    exit 1
}

main() {
    local mode="all"
    local target_vmid=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --vm)
                mode="vm"
                target_vmid="$2"
                shift 2
                ;;
            --cleanup)
                mode="cleanup"
                target_vmid="$2"
                shift 2
                ;;
            --all)
                mode="all"
                shift
                ;;
            --status)
                mode="status"
                shift
                ;;
            *)
                usage
                ;;
        esac
    done

    log_info "Script started with mode=$mode"

    case "$mode" in
        vm)
            setup_promisc
            configure_vm_mirrors "$target_vmid"
            ;;
        cleanup)
            cleanup_vm_mirrors "$target_vmid"
            ;;
        all)
            configure_all_mirrors
            ;;
        status)
            show_status
            ;;
    esac

    local exit_code=$?
    log_info "Script finished with exit code $exit_code"
    exit $exit_code
}

main "$@"