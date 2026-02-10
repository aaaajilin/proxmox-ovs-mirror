#!/bin/bash
# OVS Mirror 安裝程式
# 支援互動式安裝、非互動式安裝、解除安裝

set -euo pipefail

# ============== 常數 ==============
readonly INSTALL_DIR="/usr/local/bin"
readonly SNIPPET_DIR="/var/lib/vz/snippets"
readonly CONFIG_DIR="/etc/ovs-mirror"
readonly LOGROTATE_DIR="/etc/logrotate.d"
readonly LOG_DIR="/var/log/openvswitch"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============== 顏色輸出 ==============
info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }

# ============== 輔助函數 ==============

confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local answer

    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -rp "$prompt [y/N]: " answer
        answer="${answer:-n}"
    fi

    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# 讀取使用者輸入（含預設值）
read_input() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " answer
        echo "${answer:-$default}"
    else
        read -rp "$prompt: " answer
        echo "$answer"
    fi
}

# ============== 前置檢查 ==============

preflight_check() {
    info "Checking prerequisites..."
    local failed=0

    # Root 權限
    if [[ $EUID -eq 0 ]]; then
        ok "Running as root"
    else
        error "Must run as root (use sudo)"
        ((failed++))
    fi

    # Open vSwitch
    if command -v ovs-vsctl &>/dev/null; then
        ok "Open vSwitch installed (ovs-vsctl found)"
    else
        error "ovs-vsctl not found. Please install Open vSwitch first"
        ((failed++))
    fi

    # Proxmox VE
    if [[ -d /etc/pve ]]; then
        ok "Proxmox VE detected"
    else
        warn "Proxmox VE not detected (/etc/pve not found)"
        warn "Hookscript features may not work outside Proxmox"
    fi

    # qm command
    if command -v qm &>/dev/null; then
        ok "qm command available"
    else
        warn "qm command not found (hookscript binding will be skipped)"
    fi

    # 來源檔案
    if [[ -f "$SCRIPT_DIR/configure-ovs-mirrors.sh" && -f "$SCRIPT_DIR/ovs-mirror-hook.sh" ]]; then
        ok "Source scripts found"
    else
        error "Source scripts not found in $SCRIPT_DIR"
        ((failed++))
    fi

    if (( failed > 0 )); then
        error "Preflight check failed with $failed error(s)"
        exit 1
    fi

    echo ""
}

# ============== OVS 拓撲探索 ==============

discover_ovs_topology() {
    info "Discovering OVS topology..."
    echo ""

    local -a bridges=()
    mapfile -t bridges < <(ovs-vsctl list-br 2>/dev/null)

    if (( ${#bridges[@]} == 0 )); then
        warn "No OVS bridges found"
        return 1
    fi

    for bridge in "${bridges[@]}"; do
        local ports
        ports=$(ovs-vsctl list-ports "$bridge" 2>/dev/null | tr '\n' ', ')
        ports="${ports%,}"  # 去除尾部逗號
        echo "  Bridge: $bridge"
        echo "    Ports: ${ports:-none}"
    done

    echo ""
    return 0
}

# ============== 互動式設定檔建立 ==============

interactive_setup() {
    info "=== Interactive Mirror Rule Setup ==="
    echo ""
    echo "We will guide you through setting up mirror rules."
    echo "Each rule mirrors traffic from a source port to a destination VM's NIC."
    echo ""

    local -a rules=()

    while true; do
        echo "--- New Mirror Rule ---"

        # 選擇 Bridge
        local -a bridges=()
        mapfile -t bridges < <(ovs-vsctl list-br 2>/dev/null)

        if (( ${#bridges[@]} == 0 )); then
            error "No OVS bridges available"
            break
        fi

        echo "Available bridges:"
        for i in "${!bridges[@]}"; do
            echo "  $((i+1))) ${bridges[$i]}"
        done
        local bridge_idx
        bridge_idx=$(read_input "Select bridge number" "1")
        bridge_idx=$((bridge_idx - 1))

        if (( bridge_idx < 0 || bridge_idx >= ${#bridges[@]} )); then
            error "Invalid selection"
            continue
        fi
        local bridge="${bridges[$bridge_idx]}"

        # 列出 bridge 上的 port
        echo ""
        echo "Ports on $bridge:"
        local -a ports=()
        mapfile -t ports < <(ovs-vsctl list-ports "$bridge" 2>/dev/null)
        for i in "${!ports[@]}"; do
            echo "  $((i+1))) ${ports[$i]}"
        done

        # 選擇來源類型
        echo ""
        echo "Source type:"
        echo "  1) Physical port (e.g., eno12419)"
        echo "  2) VM tap interface (mirror another VM's NIC)"
        local source_type
        source_type=$(read_input "Select source type" "1")

        local source_port=""
        local promisc="yes"

        if [[ "$source_type" == "1" ]]; then
            source_port=$(read_input "Enter source port name")
            promisc="yes"
        elif [[ "$source_type" == "2" ]]; then
            local src_vmid src_nic
            src_vmid=$(read_input "Source VM ID")
            src_nic=$(read_input "Source NIC index" "0")
            source_port="vm${src_vmid}:${src_nic}"
            promisc="no"
            echo "  Source will be: tap${src_vmid}i${src_nic}"
        else
            error "Invalid selection"
            continue
        fi

        # 選擇目的 VM
        echo ""
        local dest_vmids
        dest_vmids=$(read_input "Destination VM ID(s) (space-separated, e.g., '100 101')")

        for dest_vmid in $dest_vmids; do
            if ! [[ "$dest_vmid" =~ ^[0-9]+$ ]]; then
                warn "Skipping invalid VM ID: $dest_vmid"
                continue
            fi

            # 自動偵測或手動輸入 NIC index
            local dest_nic=""
            local -a detected_taps=()
            for port in "${ports[@]}"; do
                if [[ "$port" =~ ^tap${dest_vmid}i([0-9]+)$ ]]; then
                    detected_taps+=("${BASH_REMATCH[1]}")
                fi
            done

            if (( ${#detected_taps[@]} == 1 )); then
                echo "  Detected tap${dest_vmid}i${detected_taps[0]} on $bridge"
                if confirm "  Use NIC index ${detected_taps[0]}?"; then
                    dest_nic="${detected_taps[0]}"
                fi
            elif (( ${#detected_taps[@]} > 1 )); then
                echo "  Detected NICs for VM $dest_vmid on $bridge:"
                for i in "${!detected_taps[@]}"; do
                    echo "    $((i+1))) NIC ${detected_taps[$i]} (tap${dest_vmid}i${detected_taps[$i]})"
                done
                local tap_choice
                tap_choice=$(read_input "  Select NIC number" "1")
                tap_choice=$((tap_choice - 1))
                if (( tap_choice >= 0 && tap_choice < ${#detected_taps[@]} )); then
                    dest_nic="${detected_taps[$tap_choice]}"
                fi
            fi

            if [[ -z "$dest_nic" ]]; then
                dest_nic=$(read_input "  NIC index for VM $dest_vmid" "1")
            fi

            # 組裝規則行
            local rule_line="$bridge  $source_port  $dest_vmid  $dest_nic"
            if [[ "$promisc" == "no" ]]; then
                rule_line="$rule_line  promisc=no"
            fi

            rules+=("$rule_line")
            ok "Added: $rule_line"
        done

        echo ""
        if ! confirm "Add another mirror rule?" "n"; then
            break
        fi
        echo ""
    done

    if (( ${#rules[@]} == 0 )); then
        warn "No rules configured"
        return 1
    fi

    # 顯示摘要
    echo ""
    info "=== Mirror Rules Summary ==="
    printf "  %-4s %-15s %-18s %-10s %-8s %s\n" "#" "Bridge" "Source" "Dest VM" "NIC Idx" "Options"
    printf "  %-4s %-15s %-18s %-10s %-8s %s\n" "---" "---------------" "------------------" "----------" "--------" "---"
    for i in "${!rules[@]}"; do
        local parts
        read -r b s d n opts <<< "${rules[$i]}"
        printf "  %-4d %-15s %-18s %-10s %-8s %s\n" "$((i+1))" "$b" "$s" "VM$d" "$n" "${opts:-}"
    done

    echo ""
    if ! confirm "Proceed with these rules?"; then
        warn "Aborted by user"
        return 1
    fi

    # 寫入設定檔
    mkdir -p "$CONFIG_DIR"
    {
        echo "# /etc/ovs-mirror/mirrors.conf"
        echo "# Generated by install.sh on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# BRIDGE  SOURCE_PORT  DEST_VMID  DEST_NIC_INDEX  [OPTIONS...]"
        echo ""
        for rule in "${rules[@]}"; do
            echo "$rule"
        done
    } > "$CONFIG_DIR/mirrors.conf"

    ok "Written $CONFIG_DIR/mirrors.conf (${#rules[@]} rules)"

    # 寫入全域設定（如果不存在）
    if [[ ! -f "$CONFIG_DIR/ovs-mirror.conf" ]]; then
        cp "$SCRIPT_DIR/examples/ovs-mirror.conf.example" "$CONFIG_DIR/ovs-mirror.conf"
        ok "Written $CONFIG_DIR/ovs-mirror.conf (default settings)"
    fi

    # 收集需要綁定 hookscript 的 VM
    echo ""
    HOOKSCRIPT_VMIDS=()
    local -A vm_set=()
    for rule in "${rules[@]}"; do
        read -r b s d n opts <<< "$rule"
        vm_set["$d"]=1
        # 如果來源是 VM tap，也需要綁定
        if [[ "$s" == vm*:* ]]; then
            local svmid="${s%%:*}"
            svmid="${svmid#vm}"
            vm_set["$svmid"]=1
        fi
    done
    for vmid in "${!vm_set[@]}"; do
        HOOKSCRIPT_VMIDS+=("$vmid")
    done

    return 0
}

# ============== 設定檔輔助函數 ==============

# 從設定檔收集所有涉及的 VM ID（dest + source）
_collect_vmids_from_config() {
    local conf="$1"
    local -A vm_set=()
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ -z "${line// /}" ]] && continue
        local b s d n rest
        read -r b s d n rest <<< "$line"
        vm_set["$d"]=1
        if [[ "$s" == vm*:* ]]; then
            local svmid="${s%%:*}"
            svmid="${svmid#vm}"
            vm_set["$svmid"]=1
        fi
    done < "$conf"
    HOOKSCRIPT_VMIDS=()
    for vmid in "${!vm_set[@]}"; do
        HOOKSCRIPT_VMIDS+=("$vmid")
    done
}

# 讀取設定檔的有效規則到陣列（跳過註解和空行）
# 同時保留原始行到 _ALL_LINES 陣列（含註解）
_load_rules_from_config() {
    local conf="$1"
    _RULES=()
    _ALL_LINES=()
    while IFS= read -r line; do
        _ALL_LINES+=("$line")
        local stripped="${line%%#*}"
        [[ -z "${stripped// /}" ]] && continue
        _RULES+=("$line")
    done < "$conf"
}

# 帶編號顯示有效規則
_display_rules() {
    local conf="$1"
    _load_rules_from_config "$conf"

    if (( ${#_RULES[@]} == 0 )); then
        warn "Config file exists but contains no rules"
        return 1
    fi

    printf "  %-4s %-15s %-18s %-10s %-8s %s\n" "#" "Bridge" "Source" "Dest VM" "NIC Idx" "Options"
    printf "  %-4s %-15s %-18s %-10s %-8s %s\n" "---" "---------------" "------------------" "----------" "--------" "---"
    for i in "${!_RULES[@]}"; do
        local b s d n opts
        read -r b s d n opts <<< "${_RULES[$i]}"
        printf "  %-4d %-15s %-18s %-10s %-8s %s\n" "$((i+1))" "$b" "$s" "VM$d" "$n" "${opts:-}"
    done
    echo "  Total: ${#_RULES[@]} rules"
}

# 用規則陣列重寫設定檔（保留頭部註解）
_rewrite_config() {
    local conf="$1"
    shift
    local -n rules_ref="$1"
    local tmpfile
    tmpfile=$(mktemp "${conf}.tmp.XXXXXX")

    {
        echo "# /etc/ovs-mirror/mirrors.conf"
        echo "# Modified by install.sh on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# BRIDGE  SOURCE_PORT  DEST_VMID  DEST_NIC_INDEX  [OPTIONS...]"
        echo ""
        for rule in "${rules_ref[@]}"; do
            echo "$rule"
        done
    } > "$tmpfile"

    mv "$tmpfile" "$conf"
}

# ============== 既有設定管理 ==============

manage_existing_config() {
    local conf="$CONFIG_DIR/mirrors.conf"

    info "=== Existing Configuration Detected ==="
    echo ""

    _display_rules "$conf" || true

    echo ""
    echo "Options:"
    echo "  1) Keep existing config (skip setup)"
    echo "  2) Add new rules"
    echo "  3) Edit a rule"
    echo "  4) Delete rules"
    echo "  5) Replace all (backup & fresh setup)"

    local choice
    choice=$(read_input "Select option" "1")

    case "$choice" in
        1)
            info "Keeping existing config unchanged"
            _collect_vmids_from_config "$conf"
            return 0
            ;;
        2)
            _config_add_rules "$conf"
            return $?
            ;;
        3)
            _config_edit_rule "$conf"
            return $?
            ;;
        4)
            _config_delete_rules "$conf"
            return $?
            ;;
        5)
            _config_replace_all "$conf"
            return $?
            ;;
        *)
            error "Invalid option: $choice"
            return 1
            ;;
    esac
}

# 新增規則（append 到設定檔末尾）
_config_add_rules() {
    local conf="$1"
    local -a new_rules=()

    echo ""
    info "Add new rules (existing rules will be preserved)"
    echo ""

    while true; do
        echo "--- New Mirror Rule ---"

        local -a bridges=()
        mapfile -t bridges < <(ovs-vsctl list-br 2>/dev/null)

        if (( ${#bridges[@]} == 0 )); then
            error "No OVS bridges available"
            break
        fi

        echo "Available bridges:"
        for i in "${!bridges[@]}"; do
            echo "  $((i+1))) ${bridges[$i]}"
        done
        local bridge_idx
        bridge_idx=$(read_input "Select bridge number" "1")
        bridge_idx=$((bridge_idx - 1))

        if (( bridge_idx < 0 || bridge_idx >= ${#bridges[@]} )); then
            error "Invalid selection"
            continue
        fi
        local bridge="${bridges[$bridge_idx]}"

        echo ""
        echo "Ports on $bridge:"
        local -a ports=()
        mapfile -t ports < <(ovs-vsctl list-ports "$bridge" 2>/dev/null)
        for i in "${!ports[@]}"; do
            echo "  $((i+1))) ${ports[$i]}"
        done

        echo ""
        echo "Source type:"
        echo "  1) Physical port (e.g., eno12419)"
        echo "  2) VM tap interface (mirror another VM's NIC)"
        local source_type
        source_type=$(read_input "Select source type" "1")

        local source_port="" promisc="yes"
        if [[ "$source_type" == "1" ]]; then
            source_port=$(read_input "Enter source port name")
            promisc="yes"
        elif [[ "$source_type" == "2" ]]; then
            local src_vmid src_nic
            src_vmid=$(read_input "Source VM ID")
            src_nic=$(read_input "Source NIC index" "0")
            source_port="vm${src_vmid}:${src_nic}"
            promisc="no"
            echo "  Source will be: tap${src_vmid}i${src_nic}"
        else
            error "Invalid selection"
            continue
        fi

        echo ""
        local dest_vmids
        dest_vmids=$(read_input "Destination VM ID(s) (space-separated, e.g., '100 101')")

        for dest_vmid in $dest_vmids; do
            if ! [[ "$dest_vmid" =~ ^[0-9]+$ ]]; then
                warn "Skipping invalid VM ID: $dest_vmid"
                continue
            fi

            local dest_nic=""
            local -a detected_taps=()
            for port in "${ports[@]}"; do
                if [[ "$port" =~ ^tap${dest_vmid}i([0-9]+)$ ]]; then
                    detected_taps+=("${BASH_REMATCH[1]}")
                fi
            done

            if (( ${#detected_taps[@]} == 1 )); then
                echo "  Detected tap${dest_vmid}i${detected_taps[0]} on $bridge"
                if confirm "  Use NIC index ${detected_taps[0]}?"; then
                    dest_nic="${detected_taps[0]}"
                fi
            elif (( ${#detected_taps[@]} > 1 )); then
                echo "  Detected NICs for VM $dest_vmid on $bridge:"
                for i in "${!detected_taps[@]}"; do
                    echo "    $((i+1))) NIC ${detected_taps[$i]} (tap${dest_vmid}i${detected_taps[$i]})"
                done
                local tap_choice
                tap_choice=$(read_input "  Select NIC number" "1")
                tap_choice=$((tap_choice - 1))
                if (( tap_choice >= 0 && tap_choice < ${#detected_taps[@]} )); then
                    dest_nic="${detected_taps[$tap_choice]}"
                fi
            fi

            if [[ -z "$dest_nic" ]]; then
                dest_nic=$(read_input "  NIC index for VM $dest_vmid" "1")
            fi

            local rule_line="$bridge  $source_port  $dest_vmid  $dest_nic"
            if [[ "$promisc" == "no" ]]; then
                rule_line="$rule_line  promisc=no"
            fi

            new_rules+=("$rule_line")
            ok "Added: $rule_line"
        done

        echo ""
        if ! confirm "Add another mirror rule?" "n"; then
            break
        fi
        echo ""
    done

    if (( ${#new_rules[@]} == 0 )); then
        warn "No new rules added"
        _collect_vmids_from_config "$conf"
        return 0
    fi

    # 顯示摘要
    echo ""
    info "New rules to be appended:"
    for i in "${!new_rules[@]}"; do
        echo "  $((i+1))) ${new_rules[$i]}"
    done

    echo ""
    if ! confirm "Append these rules to existing config?"; then
        warn "Aborted by user"
        _collect_vmids_from_config "$conf"
        return 0
    fi

    # Append 到設定檔
    {
        echo ""
        echo "# Added by install.sh on $(date '+%Y-%m-%d %H:%M:%S')"
        for rule in "${new_rules[@]}"; do
            echo "$rule"
        done
    } >> "$conf"

    ok "Appended ${#new_rules[@]} rule(s) to $conf"
    _collect_vmids_from_config "$conf"
    return 0
}

# 編輯單一規則
_config_edit_rule() {
    local conf="$1"

    echo ""
    _display_rules "$conf" || return 1

    echo ""
    local edit_idx
    edit_idx=$(read_input "Enter rule number to edit")

    if ! [[ "$edit_idx" =~ ^[0-9]+$ ]] || (( edit_idx < 1 || edit_idx > ${#_RULES[@]} )); then
        error "Invalid rule number: $edit_idx"
        return 1
    fi

    local old_rule="${_RULES[$((edit_idx-1))]}"
    echo ""
    echo "Current rule: $old_rule"
    echo ""
    echo "Enter new values (press Enter to keep current value):"

    local b s d n opts
    read -r b s d n opts <<< "$old_rule"

    local new_b new_s new_d new_n new_opts
    new_b=$(read_input "  Bridge" "$b")
    new_s=$(read_input "  Source port" "$s")
    new_d=$(read_input "  Dest VM ID" "$d")
    new_n=$(read_input "  Dest NIC index" "$n")
    new_opts=$(read_input "  Options (e.g., promisc=no)" "${opts:-}")

    local new_rule="$new_b  $new_s  $new_d  $new_n"
    [[ -n "$new_opts" ]] && new_rule="$new_rule  $new_opts"

    echo ""
    echo "  Old: $old_rule"
    echo "  New: $new_rule"
    if ! confirm "Apply this change?"; then
        warn "Edit cancelled"
        _collect_vmids_from_config "$conf"
        return 0
    fi

    _RULES[$((edit_idx-1))]="$new_rule"
    _rewrite_config "$conf" _RULES
    ok "Updated rule #$edit_idx"
    _collect_vmids_from_config "$conf"
    return 0
}

# 刪除規則（支援多選）
_config_delete_rules() {
    local conf="$1"

    echo ""
    _display_rules "$conf" || return 1

    echo ""
    local del_input
    del_input=$(read_input "Enter rule number(s) to delete (comma-separated, e.g., '1,3')")

    # 解析要刪除的索引
    local -A del_set=()
    IFS=',' read -ra parts <<< "$del_input"
    for part in "${parts[@]}"; do
        part="${part// /}"  # 去除空白
        if [[ "$part" =~ ^[0-9]+$ ]] && (( part >= 1 && part <= ${#_RULES[@]} )); then
            del_set["$((part-1))"]=1
        else
            warn "Skipping invalid number: $part"
        fi
    done

    if (( ${#del_set[@]} == 0 )); then
        warn "No valid rules selected for deletion"
        _collect_vmids_from_config "$conf"
        return 0
    fi

    echo ""
    echo "Rules to delete:"
    for idx in $(echo "${!del_set[@]}" | tr ' ' '\n' | sort -n); do
        echo "  $((idx+1))) ${_RULES[$idx]}"
    done

    if ! confirm "Delete these ${#del_set[@]} rule(s)?"; then
        warn "Delete cancelled"
        _collect_vmids_from_config "$conf"
        return 0
    fi

    # 建立新規則陣列（排除被刪的）
    local -a remaining=()
    for i in "${!_RULES[@]}"; do
        if [[ -z "${del_set[$i]:-}" ]]; then
            remaining+=("${_RULES[$i]}")
        fi
    done

    _rewrite_config "$conf" remaining
    ok "Deleted ${#del_set[@]} rule(s), ${#remaining[@]} remaining"
    _collect_vmids_from_config "$conf"
    return 0
}

# 全部取代（備份後重建）
_config_replace_all() {
    local conf="$1"
    local backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"

    cp "$conf" "$backup"
    ok "Backed up existing config to $backup"
    echo ""

    interactive_setup
    return $?
}

# ============== 安裝檔案 ==============

install_files() {
    info "Installing files..."

    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$SNIPPET_DIR"

    # 安裝主腳本
    cp "$SCRIPT_DIR/configure-ovs-mirrors.sh" "$INSTALL_DIR/configure-ovs-mirrors.sh"
    chmod 755 "$INSTALL_DIR/configure-ovs-mirrors.sh"
    ok "Installed configure-ovs-mirrors.sh -> $INSTALL_DIR/"

    # 安裝 hookscript
    cp "$SCRIPT_DIR/ovs-mirror-hook.sh" "$SNIPPET_DIR/ovs-mirror-hook.sh"
    chmod 755 "$SNIPPET_DIR/ovs-mirror-hook.sh"
    ok "Installed ovs-mirror-hook.sh -> $SNIPPET_DIR/"

    # 安裝 logrotate
    if [[ -f "$SCRIPT_DIR/ovs-mirror" ]]; then
        cp "$SCRIPT_DIR/ovs-mirror" "$LOGROTATE_DIR/ovs-mirror"
        ok "Installed logrotate config -> $LOGROTATE_DIR/ovs-mirror"
    fi

    echo ""
}

# ============== 綁定 Hookscript ==============

attach_hookscripts() {
    if ! command -v qm &>/dev/null; then
        warn "qm not available, skipping hookscript attachment"
        return 0
    fi

    if (( ${#HOOKSCRIPT_VMIDS[@]} == 0 )); then
        warn "No VMs to attach hookscript to"
        return 0
    fi

    info "=== Hookscript Setup ==="
    echo ""
    echo "The following VMs need the hookscript attached:"
    for vmid in "${HOOKSCRIPT_VMIDS[@]}"; do
        echo "  VM $vmid"
    done
    echo ""

    if ! confirm "Attach hookscript to all listed VMs?"; then
        warn "Skipping hookscript attachment"
        return 0
    fi

    for vmid in "${HOOKSCRIPT_VMIDS[@]}"; do
        if qm set "$vmid" --hookscript local:snippets/ovs-mirror-hook.sh 2>/dev/null; then
            ok "qm set $vmid --hookscript local:snippets/ovs-mirror-hook.sh"
        else
            warn "Failed to attach hookscript to VM $vmid (VM may not exist)"
        fi
    done

    echo ""
}

# ============== 解除安裝 ==============

do_uninstall() {
    info "=== Uninstalling OVS Mirror ==="
    echo ""

    # 清除所有 mirror
    if [[ -f "$INSTALL_DIR/configure-ovs-mirrors.sh" && -f "$CONFIG_DIR/mirrors.conf" ]]; then
        info "Cleaning up active mirrors..."
        "$INSTALL_DIR/configure-ovs-mirrors.sh" --status 2>/dev/null || true
        echo ""
        if confirm "Remove all active mirrors?"; then
            # 取得所有 destination VM ID
            local -a vmids=()
            mapfile -t vmids < <(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print $3 }' "$CONFIG_DIR/mirrors.conf" 2>/dev/null | sort -u)
            for vmid in "${vmids[@]}"; do
                "$INSTALL_DIR/configure-ovs-mirrors.sh" --cleanup "$vmid" 2>/dev/null || true
            done
            ok "Active mirrors cleaned up"
        fi
    fi

    # 解除 hookscript 綁定
    if command -v qm &>/dev/null && [[ -f "$CONFIG_DIR/mirrors.conf" ]]; then
        echo ""
        info "Detaching hookscripts..."
        local -A vm_set=()
        while IFS= read -r line; do
            line="${line%%#*}"
            [[ -z "${line// /}" ]] && continue
            read -r b s d n rest <<< "$line"
            vm_set["$d"]=1
            if [[ "$s" == vm*:* ]]; then
                local svmid="${s%%:*}"
                svmid="${svmid#vm}"
                vm_set["$svmid"]=1
            fi
        done < "$CONFIG_DIR/mirrors.conf"

        for vmid in "${!vm_set[@]}"; do
            qm set "$vmid" --delete hookscript 2>/dev/null && \
                ok "Detached hookscript from VM $vmid" || \
                warn "Could not detach from VM $vmid"
        done
    fi

    # 移除檔案
    echo ""
    if confirm "Remove installed files?"; then
        rm -f "$INSTALL_DIR/configure-ovs-mirrors.sh"
        rm -f "$SNIPPET_DIR/ovs-mirror-hook.sh"
        rm -f "$LOGROTATE_DIR/ovs-mirror"
        ok "Removed installed scripts"

        if confirm "Also remove config files ($CONFIG_DIR)?"; then
            rm -rf "$CONFIG_DIR"
            ok "Removed config directory"
        fi

        if confirm "Also remove log files ($LOG_DIR/ovs-mirror*.log)?"; then
            rm -f "$LOG_DIR"/ovs-mirror*.log
            ok "Removed log files"
        fi
    fi

    echo ""
    ok "Uninstall completed"
}

# ============== 主程式 ==============

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Options:
  (no options)             Interactive installation
  --non-interactive        Non-interactive install (requires --config)
  --config FILE            Path to mirrors.conf for non-interactive install
  --activate               Activate mirrors after installation
  --uninstall              Uninstall OVS Mirror
  -h, --help               Show this help message

Examples:
  sudo ./install.sh                                # Interactive install
  sudo ./install.sh --non-interactive --config mirrors.conf --activate
  sudo ./install.sh --uninstall
EOF
    exit "${1:-1}"
}

main() {
    local mode="interactive"
    local config_file=""
    local activate=false

    while (( $# > 0 )); do
        case "$1" in
            --non-interactive)
                mode="non-interactive"
                shift
                ;;
            --config)
                config_file="${2:-}"
                [[ -z "$config_file" ]] && { error "--config requires a file path"; usage; }
                shift 2
                ;;
            --activate)
                activate=true
                shift
                ;;
            --uninstall)
                mode="uninstall"
                shift
                ;;
            -h|--help)
                usage 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                ;;
        esac
    done

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║   OVS Mirror Installer                  ║"
    echo "║   Proxmox VE + Open vSwitch             ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    HOOKSCRIPT_VMIDS=()

    case "$mode" in
        uninstall)
            preflight_check
            do_uninstall
            ;;

        non-interactive)
            preflight_check

            if [[ -z "$config_file" ]]; then
                error "Non-interactive mode requires --config"
                exit 1
            fi

            if [[ ! -f "$config_file" ]]; then
                error "Config file not found: $config_file"
                exit 1
            fi

            # 複製設定檔（如果存在則先備份）
            mkdir -p "$CONFIG_DIR"
            if [[ -f "$CONFIG_DIR/mirrors.conf" ]]; then
                local backup="$CONFIG_DIR/mirrors.conf.bak.$(date +%Y%m%d%H%M%S)"
                cp "$CONFIG_DIR/mirrors.conf" "$backup"
                info "Backed up existing config to $backup"
            fi
            cp "$config_file" "$CONFIG_DIR/mirrors.conf"
            ok "Installed $config_file -> $CONFIG_DIR/mirrors.conf"

            if [[ ! -f "$CONFIG_DIR/ovs-mirror.conf" ]]; then
                cp "$SCRIPT_DIR/examples/ovs-mirror.conf.example" "$CONFIG_DIR/ovs-mirror.conf"
                ok "Written $CONFIG_DIR/ovs-mirror.conf (default settings)"
            fi

            # 收集 VM IDs for hookscript
            _collect_vmids_from_config "$CONFIG_DIR/mirrors.conf"

            install_files
            attach_hookscripts

            if $activate; then
                echo ""
                info "Activating mirrors..."
                "$INSTALL_DIR/configure-ovs-mirrors.sh" --all || warn "Some mirrors failed to activate"
            fi
            ;;

        interactive)
            preflight_check
            discover_ovs_topology || true
            if [[ -f "$CONFIG_DIR/mirrors.conf" ]]; then
                manage_existing_config || exit 1
            else
                interactive_setup || exit 1
            fi
            install_files
            attach_hookscripts

            echo ""
            if confirm "Activate mirrors now?"; then
                info "Activating mirrors..."
                "$INSTALL_DIR/configure-ovs-mirrors.sh" --all || warn "Some mirrors failed to activate"
            fi
            ;;
    esac

    echo ""
    ok "Installation completed!"
    echo ""
    echo "Useful commands:"
    echo "  configure-ovs-mirrors.sh --status     # Show mirror status"
    echo "  configure-ovs-mirrors.sh --validate   # Validate config"
    echo "  configure-ovs-mirrors.sh --all        # Activate all mirrors"
    echo ""
    echo "Config files:"
    echo "  $CONFIG_DIR/mirrors.conf              # Mirror rules"
    echo "  $CONFIG_DIR/ovs-mirror.conf           # Global settings"
    echo ""
}

main "$@"
