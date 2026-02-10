#!/bin/bash
# OVS Mirror Configuration Script
# 設定檔驅動的 OVS Mirror 管理工具
# 支援模式：--vm | --cleanup | --cleanup-dest | --cleanup-source | --all | --status | --validate

set -euo pipefail

# ============== 常數與預設值 ==============
readonly CONFIG_DIR="/etc/ovs-mirror"
readonly MIRRORS_CONF="$CONFIG_DIR/mirrors.conf"
readonly GLOBAL_CONF="$CONFIG_DIR/ovs-mirror.conf"
readonly DEFAULT_MAX_WAIT=120
readonly DEFAULT_WAIT_INTERVAL=5
readonly DEFAULT_LOG_DIR="/var/log/openvswitch"

# 載入全域設定（允許使用者覆蓋預設值）
MAX_WAIT="$DEFAULT_MAX_WAIT"
WAIT_INTERVAL="$DEFAULT_WAIT_INTERVAL"
LOG_DIR="$DEFAULT_LOG_DIR"
if [[ -f "$GLOBAL_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$GLOBAL_CONF"
fi

LOG_FILE="$LOG_DIR/ovs-mirrors.log"
mkdir -p "$LOG_DIR"

# ============== 日誌函數 ==============
log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$timestamp] [$level] $*"

    echo "$msg" >> "$LOG_FILE"
    logger -t "ovs-mirrors" -p "user.$level" "$*" 2>/dev/null || true
    echo "$msg"
}

log_info()  { log info "$@"; }
log_warn()  { log warning "$@"; }
log_error() { log err "$@"; }

# ============== 設定檔解析 ==============

# 平行陣列儲存解析結果
declare -a RULE_BRIDGE=()
declare -a RULE_SOURCE_PORT=()       # 解析後的 port 名稱（eno12419 或 tap200i0）
declare -a RULE_SOURCE_VMID=()       # 空字串表示實體 port，否則為 VM ID
declare -a RULE_DEST_VMID=()
declare -a RULE_DEST_TAP=()
declare -a RULE_DEST_NIC_INDEX=()
declare -a RULE_PROMISC=()           # "yes" 或 "no"
declare -a RULE_SELECT=()            # "both", "src", "dst"
declare -a RULE_MIRROR_NAME=()       # 自動產生的 mirror 名稱

load_config() {
    local config_file="${1:-$MIRRORS_CONF}"
    local idx=0
    local line_num=0

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        # 去除註解和前後空白
        line="${line%%#*}"
        # 跳過空行
        [[ -z "${line// /}" ]] && continue

        local bridge source_port dest_vmid dest_nic_index rest
        read -r bridge source_port dest_vmid dest_nic_index rest <<< "$line"

        # 驗證必要欄位
        if [[ -z "$bridge" || -z "$source_port" || -z "$dest_vmid" || -z "$dest_nic_index" ]]; then
            log_error "Line $line_num: Missing required fields"
            continue
        fi

        # 驗證 dest_vmid 為數字
        if ! [[ "$dest_vmid" =~ ^[0-9]+$ ]]; then
            log_error "Line $line_num: DEST_VMID '$dest_vmid' is not numeric"
            continue
        fi

        # 驗證 dest_nic_index 為數字
        if ! [[ "$dest_nic_index" =~ ^[0-9]+$ ]]; then
            log_error "Line $line_num: DEST_NIC_INDEX '$dest_nic_index' is not numeric"
            continue
        fi

        RULE_BRIDGE[$idx]="$bridge"
        RULE_DEST_VMID[$idx]="$dest_vmid"
        RULE_DEST_NIC_INDEX[$idx]="$dest_nic_index"
        RULE_DEST_TAP[$idx]="tap${dest_vmid}i${dest_nic_index}"

        # 解析來源 port
        if [[ "$source_port" == vm*:* ]]; then
            local svmid="${source_port%%:*}"
            svmid="${svmid#vm}"
            local sidx="${source_port##*:}"

            if ! [[ "$svmid" =~ ^[0-9]+$ && "$sidx" =~ ^[0-9]+$ ]]; then
                log_error "Line $line_num: Invalid VM source format '$source_port' (expected vm<VMID>:<INDEX>)"
                continue
            fi

            RULE_SOURCE_VMID[$idx]="$svmid"
            RULE_SOURCE_PORT[$idx]="tap${svmid}i${sidx}"
            RULE_PROMISC[$idx]="no"  # VM tap 預設不開啟 promisc
        else
            RULE_SOURCE_VMID[$idx]=""
            RULE_SOURCE_PORT[$idx]="$source_port"
            RULE_PROMISC[$idx]="yes"  # 實體 port 預設開啟 promisc
        fi

        # 預設 mirror 方向
        RULE_SELECT[$idx]="both"

        # 解析可選參數
        for opt in $rest; do
            case "$opt" in
                promisc=yes|promisc=no)
                    RULE_PROMISC[$idx]="${opt#promisc=}"
                    ;;
                select=both|select=src|select=dst)
                    RULE_SELECT[$idx]="${opt#select=}"
                    ;;
                *)
                    log_warn "Line $line_num: Unknown option '$opt', ignoring"
                    ;;
            esac
        done

        # 自動產生 mirror 名稱
        local src_label="${RULE_SOURCE_PORT[$idx]}"
        src_label="${src_label//\//_}"  # 清理特殊字元
        RULE_MIRROR_NAME[$idx]="mirror_${bridge}_${src_label}_to_vm${dest_vmid}i${dest_nic_index}"

        ((idx++))
    done < "$config_file"

    if (( idx == 0 )); then
        log_warn "No mirror rules found in $config_file"
    fi

    return 0
}

# ============== 驗證函數 ==============

validate_bridge() {
    local bridge="$1"
    if ! ovs-vsctl br-exists "$bridge" 2>/dev/null; then
        log_error "Bridge '$bridge' does not exist in OVS"
        return 1
    fi
    return 0
}

validate_config() {
    local config_file="${1:-$MIRRORS_CONF}"
    local errors=0
    local -A seen_bridges=()

    # 先載入設定檔
    load_config "$config_file" || return 1

    # 驗證所有引用的 bridge
    for idx in "${!RULE_BRIDGE[@]}"; do
        seen_bridges["${RULE_BRIDGE[$idx]}"]=1
    done

    for bridge in "${!seen_bridges[@]}"; do
        if ! validate_bridge "$bridge"; then
            ((errors++))
        fi
    done

    if (( errors > 0 )); then
        log_error "Config validation failed with $errors error(s)"
        return 1
    fi

    log_info "Config validation passed (${#RULE_BRIDGE[@]} rules)"
    return 0
}

# ============== OVS 輔助函數 ==============

port_exists() {
    local bridge="$1"
    local port="$2"
    ovs-vsctl list-ports "$bridge" 2>/dev/null | grep -qx "$port"
}

wait_for_tap() {
    local bridge="$1"
    local tap="$2"
    local waited=0

    while ! port_exists "$bridge" "$tap"; do
        if (( waited >= MAX_WAIT )); then
            log_error "Timeout waiting for $tap on $bridge (waited ${MAX_WAIT}s)"
            return 1
        fi
        log_info "Waiting for $tap on $bridge... (${waited}s)"
        sleep "$WAIT_INTERVAL"
        ((waited += WAIT_INTERVAL))
    done
    log_info "Found $tap on $bridge"
    return 0
}

# 用 --bare 格式查詢 mirror UUID（修復 Bug #3）
find_mirror_uuid() {
    local name="$1"
    ovs-vsctl --bare --columns=_uuid find Mirror name="$name" 2>/dev/null || true
}

# 查找 mirror 所屬的 bridge
get_mirror_bridge() {
    local uuid="$1"
    local bridge
    for bridge in $(ovs-vsctl list-br 2>/dev/null); do
        local mirrors
        mirrors=$(ovs-vsctl --bare get Bridge "$bridge" mirrors 2>/dev/null || true)
        if [[ "$mirrors" == *"$uuid"* ]]; then
            echo "$bridge"
            return 0
        fi
    done
    return 1
}

# 移除單一 mirror
remove_mirror() {
    local mirror_name="$1"
    local uuid
    uuid=$(find_mirror_uuid "$mirror_name")

    if [[ -n "$uuid" ]]; then
        local bridge
        bridge=$(get_mirror_bridge "$uuid") || true

        log_info "Removing mirror $mirror_name (UUID: $uuid)"
        if [[ -n "$bridge" ]]; then
            ovs-vsctl --if-exists remove Bridge "$bridge" mirrors "$uuid" 2>/dev/null || true
        fi
        ovs-vsctl --if-exists destroy Mirror "$uuid" 2>/dev/null || true
    fi
}

# 設定指定 port 的 promiscuous mode
setup_promisc_for_port() {
    local port="$1"
    local promisc="$2"

    if [[ "$promisc" == "yes" ]]; then
        log_info "Setting promiscuous mode on $port"
        ip link set "$port" promisc on 2>/dev/null || log_warn "Failed to set promisc on $port"
    fi
}

# ============== Mirror 管理 ==============

# 建立單一 mirror 規則
create_mirror_rule() {
    local idx="$1"
    local bridge="${RULE_BRIDGE[$idx]}"
    local src_port="${RULE_SOURCE_PORT[$idx]}"
    local dest_tap="${RULE_DEST_TAP[$idx]}"
    local mirror_name="${RULE_MIRROR_NAME[$idx]}"
    local select="${RULE_SELECT[$idx]}"

    # 驗證 bridge
    if ! validate_bridge "$bridge"; then
        return 1
    fi

    # 移除同名 mirror（冪等）
    remove_mirror "$mirror_name"

    # 等待目的 tap 介面
    if ! wait_for_tap "$bridge" "$dest_tap"; then
        log_error "Cannot create $mirror_name: destination $dest_tap not found on $bridge"
        return 1
    fi

    # 來源 port 處理
    if [[ -n "${RULE_SOURCE_VMID[$idx]}" ]]; then
        # VM tap 來源：等待 tap 出現
        if ! wait_for_tap "$bridge" "$src_port"; then
            log_error "Cannot create $mirror_name: source $src_port not found on $bridge"
            return 1
        fi
    else
        # 實體 port：確認存在
        if ! port_exists "$bridge" "$src_port"; then
            log_error "Source port $src_port does not exist on bridge $bridge"
            return 1
        fi
    fi

    # 設定 promiscuous mode
    setup_promisc_for_port "$src_port" "${RULE_PROMISC[$idx]}"

    # 構建 select 參數
    local select_args
    case "$select" in
        both) select_args="select-src-port=@src select-dst-port=@src" ;;
        src)  select_args="select-src-port=@src" ;;
        dst)  select_args="select-dst-port=@src" ;;
        *)    select_args="select-src-port=@src select-dst-port=@src" ;;
    esac

    log_info "Creating $mirror_name on $bridge ($src_port -> $dest_tap, select=$select)"

    # 使用 eval 展開 select_args（因為含有空格分隔的多個參數）
    if ! eval ovs-vsctl \
        -- --id=@src get Port "'$src_port'" \
        -- --id=@dst get Port "'$dest_tap'" \
        -- --id=@m create Mirror "'name=$mirror_name'" \
             "$select_args" \
             output-port=@dst \
        -- add Bridge "'$bridge'" mirrors @m; then
        log_error "Failed to create mirror $mirror_name"
        return 1
    fi

    return 0
}

# 配置指定 VM（作為目的地）的所有 mirror（含 rollback）
configure_vm() {
    local vmid="$1"
    local -a created=()
    local found=0

    for idx in "${!RULE_DEST_VMID[@]}"; do
        if [[ "${RULE_DEST_VMID[$idx]}" == "$vmid" ]]; then
            ((found++))
            if create_mirror_rule "$idx"; then
                created+=("${RULE_MIRROR_NAME[$idx]}")
            else
                # Rollback：移除此 VM 已建立的 mirror
                log_warn "Rolling back ${#created[@]} mirror(s) due to failure"
                for name in "${created[@]}"; do
                    remove_mirror "$name"
                done
                return 1
            fi
        fi
    done

    if (( found == 0 )); then
        log_warn "No mirror rules found for VM $vmid"
        return 1
    fi

    log_info "Successfully configured ${#created[@]} mirror(s) for VM $vmid"
    return 0
}

# 清除 VM 作為目的地的 mirror
cleanup_dest_vm() {
    local vmid="$1"
    log_info "Cleaning up mirrors where VM $vmid is a destination"
    for idx in "${!RULE_DEST_VMID[@]}"; do
        if [[ "${RULE_DEST_VMID[$idx]}" == "$vmid" ]]; then
            remove_mirror "${RULE_MIRROR_NAME[$idx]}"
        fi
    done
}

# 清除 VM 作為來源的 mirror
cleanup_source_vm() {
    local vmid="$1"
    log_info "Cleaning up mirrors where VM $vmid is a source"
    for idx in "${!RULE_SOURCE_VMID[@]}"; do
        if [[ "${RULE_SOURCE_VMID[$idx]}" == "$vmid" ]]; then
            remove_mirror "${RULE_MIRROR_NAME[$idx]}"
        fi
    done
}

# 清除 VM 的所有 mirror（作為來源或目的地）
cleanup_vm_all() {
    local vmid="$1"
    cleanup_dest_vm "$vmid"
    cleanup_source_vm "$vmid"
}

# 配置所有 mirror
configure_all() {
    log_info "Configuring all mirrors from config"
    local failed=0

    # 收集需要 promisc 的 port（去重）
    local -A promisc_ports=()
    for idx in "${!RULE_SOURCE_PORT[@]}"; do
        if [[ "${RULE_PROMISC[$idx]}" == "yes" ]]; then
            promisc_ports["${RULE_SOURCE_PORT[$idx]}"]=1
        fi
    done
    for port in "${!promisc_ports[@]}"; do
        setup_promisc_for_port "$port" "yes"
    done

    for idx in "${!RULE_BRIDGE[@]}"; do
        if ! create_mirror_rule "$idx"; then
            ((failed++))
        fi
    done

    if (( failed > 0 )); then
        log_warn "Completed with $failed failure(s) out of ${#RULE_BRIDGE[@]} rules"
        return 1
    fi

    log_info "All ${#RULE_BRIDGE[@]} mirrors configured successfully"
    return 0
}

# ============== 狀態顯示 ==============

show_status() {
    echo "=== OVS Bridges ==="
    ovs-vsctl show 2>/dev/null || echo "(ovs-vsctl not available)"

    echo ""
    echo "=== Active Mirrors ==="
    if ! ovs-vsctl list Mirror 2>/dev/null; then
        echo "(no mirrors or ovs-vsctl not available)"
    fi

    echo ""
    echo "=== Config File Rules ==="
    if (( ${#RULE_BRIDGE[@]} == 0 )); then
        echo "(no rules loaded)"
    else
        printf "  %-4s %-15s %-18s %-10s %-12s %s\n" "#" "Bridge" "Source" "Dest VM" "Dest TAP" "Mirror Name"
        printf "  %-4s %-15s %-18s %-10s %-12s %s\n" "---" "---------------" "------------------" "----------" "------------" "---"
        for idx in "${!RULE_BRIDGE[@]}"; do
            local src_label="${RULE_SOURCE_PORT[$idx]}"
            if [[ -n "${RULE_SOURCE_VMID[$idx]}" ]]; then
                src_label="vm${RULE_SOURCE_VMID[$idx]}:${src_label}"
            fi
            printf "  %-4d %-15s %-18s %-10s %-12s %s\n" \
                "$((idx + 1))" "${RULE_BRIDGE[$idx]}" "$src_label" \
                "VM${RULE_DEST_VMID[$idx]}" "${RULE_DEST_TAP[$idx]}" "${RULE_MIRROR_NAME[$idx]}"
        done
        echo "  Total: ${#RULE_BRIDGE[@]} rules"
    fi

    echo ""
    echo "=== Mirror Health Check ==="
    if (( ${#RULE_MIRROR_NAME[@]} == 0 )); then
        echo "(no rules to check)"
    else
        local ok_count=0 miss_count=0
        for idx in "${!RULE_MIRROR_NAME[@]}"; do
            local name="${RULE_MIRROR_NAME[$idx]}"
            local uuid
            uuid=$(find_mirror_uuid "$name")
            if [[ -n "$uuid" ]]; then
                echo "  [OK]   $name"
                ((ok_count++))
            else
                echo "  [MISS] $name (not active in OVS)"
                ((miss_count++))
            fi
        done
        echo "  Result: $ok_count active, $miss_count missing"
    fi
}

# ============== 主程式 ==============

usage() {
    cat <<'EOF'
Usage: configure-ovs-mirrors.sh [OPTIONS]

Options:
  --vm VMID              Configure mirrors for a specific destination VM
  --cleanup VMID         Remove all mirrors for VM (source and destination)
  --cleanup-dest VMID    Remove mirrors where VM is a destination
  --cleanup-source VMID  Remove mirrors where VM is a source
  --all                  Configure all mirrors (default)
  --status               Show current mirror status and health check
  --validate             Validate config file without making changes
  --config FILE          Use alternate config file
  -h, --help             Show this help message

Config files:
  /etc/ovs-mirror/mirrors.conf    Mirror rules
  /etc/ovs-mirror/ovs-mirror.conf Global settings
EOF
    exit "${1:-1}"
}

main() {
    local mode="all"
    local target_vmid=""
    local config_file="$MIRRORS_CONF"

    while (( $# > 0 )); do
        case "$1" in
            --vm)
                mode="vm"
                target_vmid="${2:-}"
                [[ -z "$target_vmid" ]] && { log_error "--vm requires a VMID"; usage; }
                shift 2
                ;;
            --cleanup)
                mode="cleanup"
                target_vmid="${2:-}"
                [[ -z "$target_vmid" ]] && { log_error "--cleanup requires a VMID"; usage; }
                shift 2
                ;;
            --cleanup-dest)
                mode="cleanup-dest"
                target_vmid="${2:-}"
                [[ -z "$target_vmid" ]] && { log_error "--cleanup-dest requires a VMID"; usage; }
                shift 2
                ;;
            --cleanup-source)
                mode="cleanup-source"
                target_vmid="${2:-}"
                [[ -z "$target_vmid" ]] && { log_error "--cleanup-source requires a VMID"; usage; }
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
            --validate)
                mode="validate"
                shift
                ;;
            --config)
                config_file="${2:-}"
                [[ -z "$config_file" ]] && { log_error "--config requires a file path"; usage; }
                shift 2
                ;;
            -h|--help)
                usage 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # 載入設定檔
    if ! load_config "$config_file"; then
        exit 1
    fi

    log_info "Script started: mode=$mode, config=$config_file, rules=${#RULE_BRIDGE[@]}"

    local rc=0
    case "$mode" in
        vm)
            configure_vm "$target_vmid" || rc=$?
            ;;
        cleanup)
            cleanup_vm_all "$target_vmid" || rc=$?
            ;;
        cleanup-dest)
            cleanup_dest_vm "$target_vmid" || rc=$?
            ;;
        cleanup-source)
            cleanup_source_vm "$target_vmid" || rc=$?
            ;;
        all)
            configure_all || rc=$?
            ;;
        status)
            show_status || rc=$?
            ;;
        validate)
            validate_config "$config_file" || rc=$?
            if (( rc == 0 )); then
                echo "Config validation passed (${#RULE_BRIDGE[@]} rules)"
            fi
            ;;
    esac

    log_info "Script finished (exit code $rc)"
    exit "$rc"
}

main "$@"
