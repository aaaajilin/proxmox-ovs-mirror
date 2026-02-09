#!/bin/bash
# Proxmox VM Hookscript for OVS Mirror Configuration
# 當 VM 100 或 101 啟動/關閉時，自動配置或清理 OVS Mirror

VMID="$1"
PHASE="$2"

# 日誌設定
LOG_DIR="/var/log/openvswitch"
LOG_FILE="$LOG_DIR/ovs-mirror-hook.log"
mkdir -p "$LOG_DIR"

# 日誌函數（同時輸出到檔案和 syslog）
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [VM$VMID] [$PHASE] $1"
    echo "$msg" >> "$LOG_FILE"
    logger -t "ovs-mirror-hook[VM$VMID]" "$1"
}

# 只處理 VM 100 和 101
case "$VMID" in
    100|101) ;;
    *) exit 0 ;;
esac

log "Hook triggered for VM $VMID, phase: $PHASE"

case "$PHASE" in
    post-start)
        log "VM $VMID started, triggering mirror configuration..."
        # 等待 tap 介面建立
        sleep 5
        log "Calling configure-ovs-mirrors.sh --vm $VMID"
        /usr/local/bin/configure-ovs-mirrors.sh --vm "$VMID" 2>&1 | while read line; do
            log "[configure] $line"
        done
        log "Mirror configuration completed for VM $VMID"
        ;;
    pre-stop)
        # 在 tap 介面被刪除之前清理 mirror，避免 OVS 報錯
        log "VM $VMID stopping, cleaning up mirrors (pre-stop)..."
        /usr/local/bin/configure-ovs-mirrors.sh --cleanup "$VMID" 2>&1 | while read line; do
            log "[cleanup] $line"
        done
        log "Mirror cleanup completed for VM $VMID"
        ;;
    post-stop)
        # 備用清理：確保 mirror 已被清除（正常情況下 pre-stop 已處理）
        log "VM $VMID stopped, verifying mirror cleanup (post-stop)..."
        /usr/local/bin/configure-ovs-mirrors.sh --cleanup "$VMID" 2>&1 | while read line; do
            log "[cleanup] $line"
        done
        ;;
    *)
        log "Ignoring phase: $PHASE"
        ;;
esac

exit 0