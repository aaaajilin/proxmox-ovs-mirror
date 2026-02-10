#!/bin/bash
# Proxmox VM Hookscript for OVS Mirror Configuration
# 當設定檔中定義的 VM 啟動/關閉時，自動配置或清理 OVS Mirror
# 支援 destination VM 和 source VM 的生命週期管理

VMID="$1"
PHASE="$2"

readonly CONFIG_DIR="/etc/ovs-mirror"
readonly MIRRORS_CONF="$CONFIG_DIR/mirrors.conf"
readonly CONFIGURE_SCRIPT="/usr/local/bin/configure-ovs-mirrors.sh"

# 日誌設定
LOG_DIR="/var/log/openvswitch"
LOG_FILE="$LOG_DIR/ovs-mirror-hook.log"
mkdir -p "$LOG_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [VM$VMID] [$PHASE] $1"
    echo "$msg" >> "$LOG_FILE"
    logger -t "ovs-mirror-hook[VM$VMID]" "$1" 2>/dev/null || true
}

# 設定檔不存在則直接退出
if [[ ! -f "$MIRRORS_CONF" ]]; then
    exit 0
fi

# 從設定檔判斷 VM 角色
# 欄位 3 = DEST_VMID → 此 VM 是 destination
vm_is_destination() {
    local vmid="$1"
    awk -v vmid="$vmid" '
        !/^[[:space:]]*#/ && !/^[[:space:]]*$/ {
            line = $0; sub(/#.*/, "", line)
            split(line, f)
            if (f[3] == vmid) { found=1; exit }
        }
        END { exit !found }
    ' "$MIRRORS_CONF"
}

# 欄位 2 = vm<N>:<idx> → 此 VM 是 source
vm_is_source() {
    local vmid="$1"
    awk -v vmid="$vmid" '
        !/^[[:space:]]*#/ && !/^[[:space:]]*$/ {
            line = $0; sub(/#.*/, "", line)
            split(line, f)
            if (f[2] ~ /^vm[0-9]+:/) {
                sub(/^vm/, "", f[2])
                sub(/:.*/, "", f[2])
                if (f[2] == vmid) { found=1; exit }
            }
        }
        END { exit !found }
    ' "$MIRRORS_CONF"
}

# 判斷此 VM 的角色
is_dest=false
is_source=false
vm_is_destination "$VMID" && is_dest=true
vm_is_source "$VMID" && is_source=true

# 此 VM 不在設定檔中，不處理
if ! $is_dest && ! $is_source; then
    exit 0
fi

log "Hook triggered (is_dest=$is_dest, is_source=$is_source)"

# 執行 configure 腳本並擷取日誌，保留 exit code（修復 Bug #1）
# 使用 process substitution 取代 pipe，避免 exit code 在子 shell 中遺失
run_configure() {
    local rc=0
    "$CONFIGURE_SCRIPT" "$@" > >(while IFS= read -r line; do log "[configure] $line"; done) 2>&1 || rc=$?
    return $rc
}

case "$PHASE" in
    post-start)
        if $is_dest; then
            log "VM $VMID started (destination), configuring mirrors..."
            sleep 3  # 短暫等待 tap 介面建立，後續由 wait_for_tap() 處理
            if ! run_configure --vm "$VMID"; then
                log "WARNING: Mirror configuration failed for destination VM $VMID"
            fi
        fi
        if $is_source; then
            # Source VM 開機，重建引用其 tap 的 mirror
            log "VM $VMID started (source), reconfiguring mirrors that use its taps..."
            sleep 3
            if ! run_configure --all; then
                log "WARNING: Mirror reconfiguration failed after source VM $VMID start"
            fi
        fi
        ;;

    pre-stop)
        # 在 tap 介面被刪除之前清理 mirror，避免 OVS 報錯
        if $is_source; then
            log "VM $VMID stopping (source), cleaning mirrors referencing its taps..."
            run_configure --cleanup-source "$VMID" || true
        fi
        if $is_dest; then
            log "VM $VMID stopping (destination), cleaning mirrors targeting it..."
            run_configure --cleanup-dest "$VMID" || true
        fi
        ;;

    post-stop)
        # 備用清理：確保 mirror 已被清除（正常情況下 pre-stop 已處理）
        log "VM $VMID stopped, verifying mirror cleanup (post-stop)..."
        run_configure --cleanup "$VMID" || true
        ;;

    *)
        log "Ignoring phase: $PHASE"
        ;;
esac

exit 0
