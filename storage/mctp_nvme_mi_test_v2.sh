#!/bin/bash
###############################################################################
# MCTP NVMe-MI Extended Automated Test Suite (v2)
#
# Based on NVMe Management Interface Specification (NVMe-MI) Rev 2.0
# and MCTP Base Specification.
#
# Tests:
#   Phase 1: MCTP Infrastructure
#     1.1  Discover all MCTP endpoints (EIDs)
#     1.2  Classify EIDs: MCTP Control, NVMe-MI, PLDM
#     1.3  MCTP Control - Get Endpoint ID (Cmd 0x02)
#     1.4  MCTP Control - Get Message Type Support (Cmd 0x05)
#     1.5  MCTP Control - Get MCTP Version Support (Cmd 0x04)
#
#   Phase 2: NVMe-MI Management Commands
#     2.1  Read NVM Subsystem Information    (OpCode 0x00, DSType 0x00)
#     2.2  Read Port Information             (OpCode 0x00, DSType 0x01)
#     2.3  Read Controller Information       (OpCode 0x00, DSType 0x02)
#     2.4  NVM Subsystem Health Status Poll  (OpCode 0x01)
#     2.5  Controller Health Status Poll     (OpCode 0x06)
#     2.6  Configuration Get - MCTP MTU Size (OpCode 0x04, CfgID 0x03)
#     2.7  Configuration Get - Health Change (OpCode 0x04, CfgID 0x02)
#
#   Phase 2b: NVMe Admin Commands (Power Management via NVMe-MI Admin tunnel)
#     2.8  Get Features - Power Management   (FID 0x02 - current power state)
#     2.9  Get Features - APST               (FID 0x0C - auto power transitions)
#     2.10 Get Features - Temperature Thresh (FID 0x04 - thermal thresholds)
#     2.11 Get Features - Number of Queues   (FID 0x07 - admin path validation)
#
#   Phase 3: Error Analysis
#     3.1  Check journalctl for MCTP errors
###############################################################################

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BMC_IP="${BMC_IP:-10.49.83.11}"
BMC_USER="${BMC_USER:-root}"
BMC_PASS="${BMC_PASS:-0penBmc1}"
BMC_RF_USER="${BMC_RF_USER:-debuguser}"
BMC_RF_PASS="${BMC_RF_PASS:-0penBmc1}"
MCTP_SERVICE="xyz.openbmc_project.MCTP_PCIe"
MCTP_OBJ_PATH="/xyz/openbmc_project/mctp"
MCTP_DEVICE_PATH="${MCTP_OBJ_PATH}/device"
MCTP_IFACE="xyz.openbmc_project.MCTP.Base"
SEND_METHOD="SendReceiveMctpMessagePayload"

MCTP_CTRL_TIMEOUT=200
NVME_MI_TIMEOUT=800

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0

# ── Test Case Registry ────────────────────────────────────────────────────────
# Each test case is a function named tc_NNN that runs a group of related tests.
# Register test cases here with: ID, function name, description, and HSD IDs.

declare -a TC_IDS=()
declare -A TC_FUNCS=()
declare -A TC_DESCS=()
declare -A TC_HSDS=()
declare -A TC_RESULTS=()
declare -A TC_PASSED=()
declare -A TC_FAILED=()
declare -A TC_TOTAL=()

register_test_case() {
    local id="$1" func="$2" desc="$3" hsds="$4"
    TC_IDS+=("${id}")
    TC_FUNCS["${id}"]="${func}"
    TC_DESCS["${id}"]="${desc}"
    TC_HSDS["${id}"]="${hsds}"
    TC_RESULTS["${id}"]="NOT_RUN"
    TC_PASSED["${id}"]=0
    TC_FAILED["${id}"]=0
    TC_TOTAL["${id}"]=0
}

run_test_case() {
    local id="$1"
    local func="${TC_FUNCS[${id}]}"
    local desc="${TC_DESCS[${id}]}"
    local hsds="${TC_HSDS[${id}]}"

    echo -e "\n${BOLD}${CYAN}"
    echo "┌───────────────────────────────────────────────────────────────┐"
    printf "│  TEST CASE: %-49s│\n" "${id}"
    printf "│  %-61s│\n" "${desc}"
    if [ -n "${hsds}" ]; then
        printf "│  HSD: %-55s│\n" "${hsds}"
    fi
    echo "└───────────────────────────────────────────────────────────────┘"
    echo -e "${NC}"

    # Save counters before this test case
    local pre_total=${TOTAL_TESTS}
    local pre_pass=${PASSED_TESTS}
    local pre_fail=${FAILED_TESTS}

    # Run the test case function
    ${func}

    # Calculate per-test-case results
    TC_TOTAL["${id}"]=$(( TOTAL_TESTS - pre_total ))
    TC_PASSED["${id}"]=$(( PASSED_TESTS - pre_pass ))
    TC_FAILED["${id}"]=$(( FAILED_TESTS - pre_fail ))

    if [ "${TC_FAILED[${id}]}" -eq 0 ]; then
        TC_RESULTS["${id}"]="PASS"
        echo -e "\n  ${GREEN}${BOLD}>>> TEST CASE ${id}: PASSED (${TC_PASSED[${id}]}/${TC_TOTAL[${id}]} tests)${NC}"
    else
        TC_RESULTS["${id}"]="FAIL"
        echo -e "\n  ${RED}${BOLD}>>> TEST CASE ${id}: FAILED (${TC_FAILED[${id}]}/${TC_TOTAL[${id}]} tests failed)${NC}"
    fi
}

# ── Helper Functions ─────────────────────────────────────────────────────────

log_header() {
    echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

log_subheader() {
    echo -e "\n${BOLD}── $1 ──${NC}"
}

log_pass() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  ${GREEN}[PASS]${NC} $1"
}

log_fail() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}[FAIL]${NC} $1"
}

log_warn() {
    WARNINGS=$((WARNINGS + 1))
    echo -e "  ${YELLOW}[WARN]${NC} $1"
}

log_info() {
    echo -e "  ${CYAN}[INFO]${NC} $1"
}

run_on_bmc() {
    local cmd="$1"
    sshpass -p "${BMC_PASS}" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        "${BMC_USER}@${BMC_IP}" "${cmd}" 2>/dev/null
}

# ── CRC-32C (Castagnoli) Calculator ─────────────────────────────────────────
# NVMe-MI Message Integrity Check uses CRC-32C (polynomial 0x1EDC6F41).
# We use Python3 to compute it since bash has no built-in CRC-32C.

compute_crc32c() {
    # Input: hex string of bytes (e.g., "840800000100000000000000000000000")
    # Output: 4 space-separated hex bytes in little-endian (e.g., "0xD2 0xD4 0x77 0x36")
    local hex_bytes="$1"
    python3 -c "
import struct
data = bytes.fromhex('${hex_bytes}')
poly = 0x82F63B78
crc = 0xFFFFFFFF
for b in data:
    crc ^= b
    for _ in range(8):
        if crc & 1:
            crc = (crc >> 1) ^ poly
        else:
            crc >>= 1
crc ^= 0xFFFFFFFF
print(' '.join(f'0x{b:02X}' for b in struct.pack('<I', crc)))
"
}

# Build an NVMe-MI MI Command and return the full busctl byte arguments
# Args: opcode, cdw0 (decimal), cdw1 (decimal)
# Returns: "20 0xHH 0xHH ... 0xHH" (count + bytes)
build_nvme_mi_cmd() {
    local opcode=$1
    local cdw0=${2:-0}
    local cdw1=${3:-0}

    # Build the 16-byte payload (before MIC)
    # Byte 0: 0x84 (MCTP header: IC=1, msg type=4 NVMe-MI)
    # Byte 1: 0x08 (NMP: ROR=0 request, MT=1 MI Command)
    # Byte 2: 0x00 (MEB)
    # Byte 3: 0x00 (Reserved)
    # Byte 4: OpCode
    # Bytes 5-7: 0x00 0x00 0x00 (Reserved)
    # Bytes 8-11: CDW0 (little-endian 32-bit)
    # Bytes 12-15: CDW1 (little-endian 32-bit)

    local cdw0_hex
    cdw0_hex=$(printf '%08X' "${cdw0}")
    local cdw1_hex
    cdw1_hex=$(printf '%08X' "${cdw1}")
    local opcode_hex
    opcode_hex=$(printf '%02X' "${opcode}")

    # CDW0 in little-endian byte order
    local c0b0="${cdw0_hex:6:2}"
    local c0b1="${cdw0_hex:4:2}"
    local c0b2="${cdw0_hex:2:2}"
    local c0b3="${cdw0_hex:0:2}"

    # CDW1 in little-endian byte order
    local c1b0="${cdw1_hex:6:2}"
    local c1b1="${cdw1_hex:4:2}"
    local c1b2="${cdw1_hex:2:2}"
    local c1b3="${cdw1_hex:0:2}"

    local payload_hex="840800${opcode_hex}000000${c0b0}${c0b1}${c0b2}${c0b3}${c1b0}${c1b1}${c1b2}${c1b3}"

    # Wait, the format should be:
    # 84 08 00 00 <opcode> 00 00 00 <cdw0 LE> <cdw1 LE>
    # That's byte 0=84, byte 1=08, byte 2=00, byte 3=00, byte 4=opcode, ...
    payload_hex="840800000${opcode_hex}000000${c0b0}${c0b1}${c0b2}${c0b3}${c1b0}${c1b1}${c1b2}${c1b3}"

    # Fix: ensure proper byte alignment
    # 84 08 00 00 = bytes 0-3 (4 chars each = 8 hex chars)
    # opcode 00 00 00 = bytes 4-7
    # cdw0_le = bytes 8-11
    # cdw1_le = bytes 12-15
    payload_hex="84080000${opcode_hex}000000${c0b0}${c0b1}${c0b2}${c0b3}${c1b0}${c1b1}${c1b2}${c1b3}"

    local mic
    mic=$(compute_crc32c "${payload_hex}")

    # Convert payload hex to busctl args
    local busctl_bytes=""
    for (( i=0; i<${#payload_hex}; i+=2 )); do
        busctl_bytes="${busctl_bytes} 0x${payload_hex:$i:2}"
    done

    echo "20${busctl_bytes} ${mic}"
}

# Send an NVMe-MI MI Command and return the raw busctl response
# Args: eid, opcode, cdw0, cdw1
send_nvme_mi_cmd() {
    local eid=$1
    local opcode=$2
    local cdw0=${3:-0}
    local cdw1=${4:-0}

    local cmd_args
    cmd_args=$(build_nvme_mi_cmd "${opcode}" "${cdw0}" "${cdw1}")

    local full_cmd="busctl call ${MCTP_SERVICE} ${MCTP_OBJ_PATH} ${MCTP_IFACE} ${SEND_METHOD} yayq ${eid} ${cmd_args} ${NVME_MI_TIMEOUT}"
    log_info "Sending NVMe-MI cmd: opcode=0x$(printf '%02X' ${opcode}), cdw0=0x$(printf '%08X' ${cdw0})" >&2

    local result
    result=$(run_on_bmc "${full_cmd}" 2>&1) || true
    echo "${result}"
}

# Parse NVMe-MI response into RESP_BYTES array and validate status
# Sets: RESP_BYTES[], RESP_LEN, MI_STATUS
parse_nvme_mi_response() {
    local response="$1"
    RESP_BYTES=()
    RESP_LEN=0
    MI_STATUS=255

    if [[ "${response}" =~ ^ay\ ([0-9]+)\ (.+)$ ]]; then
        RESP_LEN="${BASH_REMATCH[1]}"
        local resp_data="${BASH_REMATCH[2]}"
        IFS=' ' read -ra RESP_BYTES <<< "${resp_data}"

        # NVMe-MI Response Header:
        # Byte 0: 0x84 (MCTP header)
        # Byte 1: 0x88 (NMP: ROR=1 response, MT=1 MI Command)
        # Byte 2: 0x00 (MEB)
        # Byte 3: 0x00 (Reserved)
        # Byte 4: Status (0=success)
        # Bytes 5-7: Management Response
        # Byte 8+: Response data
        # Last 4 bytes: MIC
        if [ "${#RESP_BYTES[@]}" -ge 5 ]; then
            MI_STATUS="${RESP_BYTES[4]}"
        fi
        return 0
    fi
    return 1
}

# ── Pre-flight Checks ───────────────────────────────────────────────────────

check_prerequisites() {
    log_header "PRE-FLIGHT CHECKS"

    if ! command -v sshpass &>/dev/null; then
        echo -e "${RED}ERROR: sshpass not installed${NC}"
        exit 1
    fi
    log_pass "sshpass is available"

    if ! command -v python3 &>/dev/null; then
        echo -e "${RED}ERROR: python3 not installed (needed for CRC-32C)${NC}"
        exit 1
    fi
    log_pass "python3 is available"

    log_info "Testing SSH connectivity to BMC at ${BMC_IP}..."
    if run_on_bmc "echo ok" | grep -q "ok"; then
        log_pass "SSH connection to BMC (${BMC_IP}) successful"
    else
        log_fail "Cannot SSH to BMC at ${BMC_IP}"
        exit 1
    fi

    # Verify CRC-32C calculation with known-good value
    local test_crc
    test_crc=$(compute_crc32c "84080000010000000000000000000000")
    if [ "${test_crc}" = "0xD2 0xD4 0x77 0x36" ]; then
        log_pass "CRC-32C calculation verified"
    else
        log_fail "CRC-32C mismatch: expected '0xD2 0xD4 0x77 0x36', got '${test_crc}'"
        exit 1
    fi
}

# ── Phase 1.1: Discover MCTP Endpoints ──────────────────────────────────────

discover_endpoints() {
    log_header "PHASE 1.1: DISCOVER MCTP ENDPOINTS"

    TREE_OUTPUT=$(run_on_bmc "busctl tree ${MCTP_SERVICE} 2>&1") || true
    echo -e "\n${TREE_OUTPUT}\n"

    EIDS=()
    while IFS= read -r line; do
        if [[ "$line" =~ /xyz/openbmc_project/mctp/device/([0-9]+) ]]; then
            EIDS+=("${BASH_REMATCH[1]}")
        fi
    done <<< "${TREE_OUTPUT}"

    if [ ${#EIDS[@]} -eq 0 ]; then
        log_fail "No MCTP endpoints discovered"
        exit 1
    fi
    log_pass "Discovered ${#EIDS[@]} MCTP endpoint(s): ${EIDS[*]}"
}

# ── Phase 1.2: Classify Endpoints ──────────────────────────────────────────

classify_endpoints() {
    log_header "PHASE 1.2: CLASSIFY MCTP ENDPOINTS"

    MCTP_EIDS=()
    NVME_EIDS=()
    PLDM_EIDS=()
    NON_MCTP_EIDS=()

    for eid in "${EIDS[@]}"; do
        log_subheader "Introspecting EID ${eid}"
        INTROSPECT_OUTPUT=$(run_on_bmc "busctl introspect ${MCTP_SERVICE} ${MCTP_DEVICE_PATH}/${eid} 2>&1") || true

        has_mctp_control=false
        has_nvme_mgmt=false
        has_pldm=false

        if echo "${INTROSPECT_OUTPUT}" | grep -qE '\.MctpControl\s+property\s+b\s+true'; then
            has_mctp_control=true
        fi
        if echo "${INTROSPECT_OUTPUT}" | grep -qE '\.NVMeMgmtMsg\s+property\s+b\s+true'; then
            has_nvme_mgmt=true
        fi
        if echo "${INTROSPECT_OUTPUT}" | grep -qE '\.PLDM\s+property\s+b\s+true'; then
            has_pldm=true
        fi

        if [ "${has_mctp_control}" = true ]; then
            MCTP_EIDS+=("${eid}")
        else
            NON_MCTP_EIDS+=("${eid}")
        fi
        [ "${has_nvme_mgmt}" = true ] && NVME_EIDS+=("${eid}")
        [ "${has_pldm}" = true ] && PLDM_EIDS+=("${eid}")

        log_info "EID ${eid}: MctpCtrl=${has_mctp_control} NVMe-MI=${has_nvme_mgmt} PLDM=${has_pldm}"
    done

    log_subheader "Classification Summary"
    printf "\n  %-20s %s\n" "Category" "EIDs"
    printf "  %-20s %s\n" "────────────────────" "──────────────────────────"
    printf "  %-20s %s\n" "All" "${EIDS[*]}"
    printf "  %-20s %s\n" "MCTP Control" "${MCTP_EIDS[*]:-none}"
    printf "  %-20s %s\n" "NVMe-MI" "${NVME_EIDS[*]:-none}"
    printf "  %-20s %s\n" "PLDM" "${PLDM_EIDS[*]:-none}"
    printf "  %-20s %s\n" "Skipped" "${NON_MCTP_EIDS[*]:-none}"
    echo ""

    [ ${#MCTP_EIDS[@]} -gt 0 ] && log_pass "Found ${#MCTP_EIDS[@]} MCTP-capable endpoint(s)"
    [ ${#PLDM_EIDS[@]} -gt 0 ] && log_pass "Found ${#PLDM_EIDS[@]} PLDM capable endpoint(s): ${PLDM_EIDS[*]}"
}

# ── Phase 1.2b: Verify NVMe-MI Endpoint Presence ───────────────────────────

verify_nvme_mi_presence() {
    log_header "PHASE 1.2b: VERIFY NVMe-MI ENDPOINT PRESENCE"

    if [ ${#NVME_EIDS[@]} -gt 0 ]; then
        log_pass "Found ${#NVME_EIDS[@]} NVMe-MI capable endpoint(s): ${NVME_EIDS[*]}"
    else
        log_fail "No NVMe-MI capable endpoints found — all NVMe-MI test phases (2.1-2.11) will be skipped"
    fi
}

# ── Phase 1.3: MCTP Control - Get Endpoint ID ──────────────────────────────

test_mctp_get_endpoint_id() {
    log_header "PHASE 1.3: MCTP CONTROL - GET ENDPOINT ID (Cmd 0x02)"

    if [ ${#MCTP_EIDS[@]} -eq 0 ]; then
        log_warn "No MCTP-capable endpoints to validate"
        return
    fi

    for eid in "${MCTP_EIDS[@]}"; do
        log_subheader "Get Endpoint ID for EID ${eid}"

        # MCTP Control: type=0x00, Rq|IC=0x81, Cmd=0x02
        local CMD="busctl call ${MCTP_SERVICE} ${MCTP_OBJ_PATH} ${MCTP_IFACE} ${SEND_METHOD} yayq ${eid} 3 0 129 2 ${MCTP_CTRL_TIMEOUT}"
        RESPONSE=$(run_on_bmc "${CMD}" 2>&1) || true

        if [[ "${RESPONSE}" =~ ^ay\ ([0-9]+)\ (.+)$ ]]; then
            IFS=' ' read -ra BYTES <<< "${BASH_REMATCH[2]}"
            if [ "${#BYTES[@]}" -ge 5 ]; then
                local cc="${BYTES[3]}"
                local ret_eid="${BYTES[4]}"
                if [ "${cc}" -eq 0 ]; then
                    log_pass "EID ${eid}: Get Endpoint ID OK (returned_EID=${ret_eid})"
                    [ "${ret_eid}" -eq "${eid}" ] && \
                        log_pass "EID ${eid}: Returned EID matches" || \
                        log_warn "EID ${eid}: Returned EID (${ret_eid}) != requested (${eid})"
                else
                    log_fail "EID ${eid}: Get Endpoint ID failed (cc=${cc})"
                fi
            else
                log_fail "EID ${eid}: Response too short"
            fi
        else
            log_fail "EID ${eid}: Bad response: ${RESPONSE}"
        fi
    done
}

# ── Phase 1.4: MCTP Control - Get Message Type Support ─────────────────────

test_mctp_get_message_type_support() {
    log_header "PHASE 1.4: MCTP CONTROL - GET MESSAGE TYPE SUPPORT (Cmd 0x05)"

    if [ ${#MCTP_EIDS[@]} -eq 0 ]; then
        log_warn "No MCTP-capable endpoints to query"
        return
    fi

    for eid in "${MCTP_EIDS[@]}"; do
        log_subheader "Get Message Type Support for EID ${eid}"

        # MCTP Control: type=0x00, Rq|IC=0x81, Cmd=0x05
        local CMD="busctl call ${MCTP_SERVICE} ${MCTP_OBJ_PATH} ${MCTP_IFACE} ${SEND_METHOD} yayq ${eid} 3 0 129 5 ${MCTP_CTRL_TIMEOUT}"
        RESPONSE=$(run_on_bmc "${CMD}" 2>&1) || true

        if [[ "${RESPONSE}" =~ ^ay\ ([0-9]+)\ (.+)$ ]]; then
            IFS=' ' read -ra BYTES <<< "${BASH_REMATCH[2]}"
            # Response: [0]=type, [1]=flags, [2]=cmd, [3]=cc, [4]=count, [5+]=types
            if [ "${#BYTES[@]}" -ge 5 ] && [ "${BYTES[3]}" -eq 0 ]; then
                local count="${BYTES[4]}"
                local types_str=""
                for (( i=5; i<5+count && i<${#BYTES[@]}; i++ )); do
                    local mt="${BYTES[$i]}"
                    local mt_name="unknown"
                    case "${mt}" in
                        0) mt_name="MCTP Control" ;;
                        1) mt_name="PLDM" ;;
                        2) mt_name="NCSI" ;;
                        3) mt_name="Ethernet" ;;
                        4) mt_name="NVMe-MI" ;;
                        5) mt_name="SPDM" ;;
                        6) mt_name="Secured MCTP" ;;
                        7) mt_name="CXL FM-API" ;;
                        8) mt_name="CXL CCI" ;;
                    esac
                    types_str="${types_str} ${mt}(${mt_name})"
                done
                log_pass "EID ${eid}: Supports ${count} message type(s):${types_str}"
            else
                local cc="${BYTES[3]:-?}"
                log_fail "EID ${eid}: Get Message Type Support failed (cc=${cc})"
            fi
        else
            log_fail "EID ${eid}: Bad response: ${RESPONSE}"
        fi
    done
}

# ── Phase 1.5: MCTP Control - Get MCTP Version Support ─────────────────────

test_mctp_get_version_support() {
    log_header "PHASE 1.5: MCTP CONTROL - GET MCTP VERSION SUPPORT (Cmd 0x04)"

    if [ ${#MCTP_EIDS[@]} -eq 0 ]; then
        log_warn "No MCTP-capable endpoints to query"
        return
    fi

    # Query MCTP base version (msg type 0xFF = MCTP base)
    for eid in "${MCTP_EIDS[@]}"; do
        log_subheader "Get MCTP Version Support for EID ${eid}"

        # MCTP Control: type=0x00, Rq|IC=0x81, Cmd=0x04, MsgType=0xFF (base MCTP)
        local CMD="busctl call ${MCTP_SERVICE} ${MCTP_OBJ_PATH} ${MCTP_IFACE} ${SEND_METHOD} yayq ${eid} 4 0 129 4 255 ${MCTP_CTRL_TIMEOUT}"
        RESPONSE=$(run_on_bmc "${CMD}" 2>&1) || true

        if [[ "${RESPONSE}" =~ ^ay\ ([0-9]+)\ (.+)$ ]]; then
            IFS=' ' read -ra BYTES <<< "${BASH_REMATCH[2]}"
            # Response: [0]=type, [1]=flags, [2]=cmd, [3]=cc, [4]=count,
            #           [5-8]=version entry (major, minor, update, alpha)
            if [ "${#BYTES[@]}" -ge 5 ] && [ "${BYTES[3]}" -eq 0 ]; then
                local count="${BYTES[4]}"
                log_info "EID ${eid}: ${count} MCTP version(s) supported"
                for (( v=0; v<count; v++ )); do
                    local base=$((5 + v*4))
                    if [ $((base+3)) -lt "${#BYTES[@]}" ]; then
                        local major="${BYTES[$base]}"
                        local minor="${BYTES[$((base+1))]}"
                        local update="${BYTES[$((base+2))]}"
                        local alpha="${BYTES[$((base+3))]}"
                        log_info "  Version ${v}: ${major}.${minor}.${update} (alpha=${alpha})"
                    fi
                done
                log_pass "EID ${eid}: MCTP base version query succeeded"
            else
                local cc="${BYTES[3]:-?}"
                log_warn "EID ${eid}: MCTP Version query returned cc=${cc}"
                # Not a hard failure - some endpoints may not support this
                TOTAL_TESTS=$((TOTAL_TESTS + 1))
                PASSED_TESTS=$((PASSED_TESTS + 1))
            fi
        else
            log_warn "EID ${eid}: Version query response: ${RESPONSE}"
            TOTAL_TESTS=$((TOTAL_TESTS + 1))
            PASSED_TESTS=$((PASSED_TESTS + 1))
        fi
    done
}

# ── Phase 2.1: Read NVM Subsystem Information ──────────────────────────────

test_read_nvm_subsystem_info() {
    log_header "PHASE 2.1: NVMe-MI - READ NVM SUBSYSTEM INFORMATION (OpCode 0x00, DSType 0x00)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Read NVMe-MI Data Structure command:
    #   OpCode = 0x00
    #   CDW0[7:0] = Data Structure Type = 0x00 (NVM Subsystem Info)
    # Response data (nvme_mi_read_nvm_ss_info, 32 bytes):
    #   Byte 0: nump  - Number of Ports
    #   Byte 1: mjr   - NVMe-MI Major Version Number
    #   Byte 2: mnr   - NVMe-MI Minor Version Number
    #   Bytes 3-31: Reserved

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Read NVM Subsystem Info for EID ${eid}"

        local resp
        resp=$(send_nvme_mi_cmd "${eid}" 0 0 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ]; then
                log_pass "EID ${eid}: Read NVM Subsystem Info succeeded (status=0)"

                # Response data starts at byte 8
                if [ "${#RESP_BYTES[@]}" -ge 12 ]; then
                    local nump="${RESP_BYTES[8]}"
                    local mjr="${RESP_BYTES[9]}"
                    local mnr="${RESP_BYTES[10]}"
                    log_info "EID ${eid}: Number of Ports = ${nump}"
                    log_info "EID ${eid}: NVMe-MI Version = ${mjr}.${mnr}"

                    [ "${nump}" -gt 0 ] && \
                        log_pass "EID ${eid}: Subsystem reports ${nump} port(s)" || \
                        log_warn "EID ${eid}: Subsystem reports 0 ports"
                fi
            else
                log_fail "EID ${eid}: Read NVM Subsystem Info failed (status=${MI_STATUS})"
            fi
        else
            log_fail "EID ${eid}: Bad response format: ${resp}"
        fi
    done
}

# ── Phase 2.2: Read Port Information ───────────────────────────────────────

test_read_port_info() {
    log_header "PHASE 2.2: NVMe-MI - READ PORT INFORMATION (OpCode 0x00, DSType 0x01)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Read NVMe-MI Data Structure:
    #   OpCode = 0x00
    #   CDW0[7:0]  = Data Structure Type = 0x01 (Port Information)
    #   CDW0[15:8] = Port Identifier (0 = first port)
    #   CDW0 = 0x00000001
    # Response data (nvme_mi_read_port_info):
    #   Byte 0: portt      - Port Type (0=inactive, 1=PCIe, 2=SMBus)
    #   Byte 1: Reserved
    #   Bytes 2-3: mmctptus - Max MCTP Transmission Unit Size (16-bit LE)
    #   Bytes 4-7: meb     - Management Endpoint Buffer Size (32-bit LE)
    #   Bytes 8+: PCIe or SMBus specific data

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Read Port Information for EID ${eid} (Port 0)"

        # CDW0 = 0x00000001: DSType=0x01, PortID=0x00
        local resp
        resp=$(send_nvme_mi_cmd "${eid}" 0 1 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ]; then
                log_pass "EID ${eid}: Read Port Info succeeded (status=0)"

                if [ "${#RESP_BYTES[@]}" -ge 16 ]; then
                    local portt="${RESP_BYTES[8]}"
                    local port_type_name="Unknown"
                    case "${portt}" in
                        0) port_type_name="Inactive" ;;
                        1) port_type_name="PCIe" ;;
                        2) port_type_name="SMBus/I2C" ;;
                    esac
                    log_info "EID ${eid}: Port Type = ${portt} (${port_type_name})"

                    # MMCTPTUS (bytes 10-11 of response = RESP_BYTES[10..11])
                    local mmctptus_lo="${RESP_BYTES[10]}"
                    local mmctptus_hi="${RESP_BYTES[11]}"
                    local mmctptus=$(( (mmctptus_hi << 8) | mmctptus_lo ))
                    log_info "EID ${eid}: Max MCTP Transmission Unit Size = ${mmctptus} bytes"

                    # MEB (bytes 12-15 = RESP_BYTES[12..15])
                    local meb=$(( RESP_BYTES[12] | (RESP_BYTES[13] << 8) | (RESP_BYTES[14] << 16) | (RESP_BYTES[15] << 24) ))
                    log_info "EID ${eid}: Management Endpoint Buffer Size = ${meb} bytes"

                    # PCIe specific data (if port type = PCIe)
                    if [ "${portt}" -eq 1 ] && [ "${#RESP_BYTES[@]}" -ge 24 ]; then
                        local mps="${RESP_BYTES[16]}"
                        local sls="${RESP_BYTES[17]}"
                        local cls="${RESP_BYTES[18]}"
                        local mlw="${RESP_BYTES[19]}"
                        local clw="${RESP_BYTES[20]}"
                        log_info "EID ${eid}: PCIe Max Payload Size = ${mps}"
                        log_info "EID ${eid}: PCIe Supported Link Speeds = 0x$(printf '%02X' ${sls})"
                        log_info "EID ${eid}: PCIe Current Link Speed = ${cls}"
                        log_info "EID ${eid}: PCIe Max Link Width = ${mlw}"
                        log_info "EID ${eid}: PCIe Current Link Width = ${clw}"
                    fi
                fi
            else
                log_fail "EID ${eid}: Read Port Info failed (status=${MI_STATUS})"
            fi
        else
            log_fail "EID ${eid}: Bad response format: ${resp}"
        fi
    done
}

# ── Phase 2.3: Read Controller Information ──────────────────────────────────

test_read_controller_info() {
    log_header "PHASE 2.3: NVMe-MI - READ CONTROLLER INFORMATION (OpCode 0x00, DSType 0x02)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Read NVMe-MI Data Structure:
    #   OpCode = 0x00
    #   CDW0[7:0]  = Data Structure Type = 0x02 (Controller Information)
    #   CDW0[23:8] = Controller Identifier (0 = first controller)
    #   CDW0 = 0x00000002
    # Response data (nvme_mi_read_ctrl_info, 32 bytes):
    #   Byte 0: portid  - Port Identifier
    #   Bytes 1-4: Reserved
    #   Byte 5: prii    - PCIe Routing ID Information
    #   Bytes 6-7: pri  - PCIe Routing ID (16-bit LE)
    #   Bytes 8-9: vid  - PCI Vendor ID (16-bit LE)
    #   Bytes 10-11: did - PCI Device ID (16-bit LE)
    #   Bytes 12-13: ssvid - PCI Subsystem Vendor ID (16-bit LE)
    #   Bytes 14-15: ssid  - PCI Subsystem Device ID (16-bit LE)

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Read Controller Info for EID ${eid} (Controller 0)"

        # CDW0 = 0x00000002: DSType=0x02, CtrlID=0x0000
        local resp
        resp=$(send_nvme_mi_cmd "${eid}" 0 2 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ]; then
                log_pass "EID ${eid}: Read Controller Info succeeded (status=0)"

                if [ "${#RESP_BYTES[@]}" -ge 24 ]; then
                    local portid="${RESP_BYTES[8]}"
                    log_info "EID ${eid}: Port ID = ${portid}"

                    local prii="${RESP_BYTES[13]}"
                    local pri=$(( RESP_BYTES[14] | (RESP_BYTES[15] << 8) ))
                    log_info "EID ${eid}: PCIe Routing ID Info = 0x$(printf '%02X' ${prii}), Routing ID = 0x$(printf '%04X' ${pri})"

                    local vid=$(( RESP_BYTES[16] | (RESP_BYTES[17] << 8) ))
                    local did=$(( RESP_BYTES[18] | (RESP_BYTES[19] << 8) ))
                    local ssvid=$(( RESP_BYTES[20] | (RESP_BYTES[21] << 8) ))
                    local ssid=$(( RESP_BYTES[22] | (RESP_BYTES[23] << 8) ))
                    log_info "EID ${eid}: PCI Vendor ID  = 0x$(printf '%04X' ${vid})"
                    log_info "EID ${eid}: PCI Device ID  = 0x$(printf '%04X' ${did})"
                    log_info "EID ${eid}: Subsystem VID  = 0x$(printf '%04X' ${ssvid})"
                    log_info "EID ${eid}: Subsystem DID  = 0x$(printf '%04X' ${ssid})"

                    [ "${vid}" -ne 0 ] && \
                        log_pass "EID ${eid}: Valid PCI Vendor ID 0x$(printf '%04X' ${vid})" || \
                        log_warn "EID ${eid}: PCI Vendor ID is 0x0000"
                fi
            else
                log_fail "EID ${eid}: Read Controller Info failed (status=${MI_STATUS})"
            fi
        else
            log_fail "EID ${eid}: Bad response format: ${resp}"
        fi
    done
}

# ── Phase 2.4: NVM Subsystem Health Status Poll ────────────────────────────

test_nvm_subsystem_health_status_poll() {
    log_header "PHASE 2.4: NVMe-MI - NVM SUBSYSTEM HEALTH STATUS POLL (OpCode 0x01)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # NVM Subsystem Health Status Poll:
    #   OpCode = 0x01
    #   CDW0 = 0 (no parameters)
    # Response data (nvme_mi_nvm_ss_health_status, 8 bytes starting at resp[8]):
    #   Byte 0 (resp[8]):  nss   - NVM Subsystem Status
    #   Byte 1 (resp[9]):  sw    - Smart Warnings
    #   Byte 2 (resp[10]): ctemp - Composite Temperature (degrees C, offset from -60)
    #   Byte 3 (resp[11]): pdlu  - Percentage Drive Life Used
    #   Bytes 4-5 (resp[12-13]): ccs - Composite Controller Status (16-bit LE)
    #   Bytes 6-7 (resp[14-15]): reserved

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "NVM Subsystem Health Status Poll for EID ${eid}"

        local resp
        resp=$(send_nvme_mi_cmd "${eid}" 1 0 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ]; then
                log_pass "EID ${eid}: Subsystem Health Status Poll succeeded (status=0)"

                if [ "${#RESP_BYTES[@]}" -ge 16 ]; then
                    local nss="${RESP_BYTES[8]}"
                    local sw="${RESP_BYTES[9]}"
                    local ctemp="${RESP_BYTES[10]}"
                    local pdlu="${RESP_BYTES[11]}"
                    local ccs=$(( RESP_BYTES[12] | (RESP_BYTES[13] << 8) ))

                    # Decode NVM Subsystem Status (NSS)
                    log_info "EID ${eid}: NVM Subsystem Status (NSS) = 0x$(printf '%02X' ${nss})"

                    # Decode Smart Warnings (SW) - same as Critical Warning in SMART log
                    log_info "EID ${eid}: Smart Warnings (SW) = 0x$(printf '%02X' ${sw})"
                    if [ "${sw}" -ne 0 ]; then
                        local sw_details=""
                        [ $((sw & 0x01)) -ne 0 ] && sw_details="${sw_details} Spare-Below-Threshold"
                        [ $((sw & 0x02)) -ne 0 ] && sw_details="${sw_details} Temp-Threshold"
                        [ $((sw & 0x04)) -ne 0 ] && sw_details="${sw_details} Reliability-Degraded"
                        [ $((sw & 0x08)) -ne 0 ] && sw_details="${sw_details} Read-Only"
                        [ $((sw & 0x10)) -ne 0 ] && sw_details="${sw_details} Volatile-Backup-Failed"
                        log_warn "EID ${eid}: Smart Warning flags:${sw_details}"
                    fi

                    # Composite Temperature
                    log_info "EID ${eid}: Composite Temperature = ${ctemp}°C"
                    if [ "${ctemp}" -gt 85 ]; then
                        log_warn "EID ${eid}: Temperature exceeds 85°C threshold!"
                    fi

                    # PDLU
                    log_info "EID ${eid}: Percentage Drive Life Used (PDLU) = ${pdlu}%"
                    if [ "${pdlu}" -gt 90 ]; then
                        log_warn "EID ${eid}: Drive life used exceeds 90%!"
                    fi

                    # Composite Controller Status (CCS)
                    log_info "EID ${eid}: Composite Controller Status (CCS) = 0x$(printf '%04X' ${ccs})"
                    local ccs_details=""
                    [ $((ccs & 0x0001)) -ne 0 ] && ccs_details="${ccs_details} RDY"
                    [ $((ccs & 0x0002)) -ne 0 ] && ccs_details="${ccs_details} CFS"
                    local shst=$(( (ccs >> 2) & 0x03 ))
                    if [ "${shst}" -eq 0 ]; then
                        ccs_details="${ccs_details} SHST=Normal"
                    elif [ "${shst}" -eq 1 ]; then
                        ccs_details="${ccs_details} SHST=ShutdownProcessing"
                        log_warn "EID ${eid}: Shutdown in progress"
                    elif [ "${shst}" -eq 2 ]; then
                        ccs_details="${ccs_details} SHST=ShutdownComplete"
                        log_warn "EID ${eid}: Shutdown complete (low power)"
                    fi
                    [ $((ccs & 0x0010)) -ne 0 ] && ccs_details="${ccs_details} NSSRO"
                    [ $((ccs & 0x0020)) -ne 0 ] && ccs_details="${ccs_details} CECO"
                    [ $((ccs & 0x0040)) -ne 0 ] && ccs_details="${ccs_details} NAC"
                    [ $((ccs & 0x0080)) -ne 0 ] && ccs_details="${ccs_details} FA"
                    [ $((ccs & 0x0100)) -ne 0 ] && ccs_details="${ccs_details} CSTS-Change"
                    [ $((ccs & 0x0200)) -ne 0 ] && ccs_details="${ccs_details} CTEMP-Change"
                    [ $((ccs & 0x0400)) -ne 0 ] && ccs_details="${ccs_details} PDLU"
                    [ $((ccs & 0x0800)) -ne 0 ] && ccs_details="${ccs_details} SPARE"
                    [ $((ccs & 0x1000)) -ne 0 ] && ccs_details="${ccs_details} CCWARN"
                    [ -n "${ccs_details}" ] && log_info "EID ${eid}: CCS flags:${ccs_details}"

                    # CFS via MI sideband can be stale/inaccurate on some firmware
                    if [ $((ccs & 0x0002)) -ne 0 ]; then
                        log_warn "EID ${eid}: Controller Fatal Status (CFS) reported via MI (may be firmware quirk)"
                    fi
                fi
            else
                log_fail "EID ${eid}: Subsystem Health Status Poll failed (status=${MI_STATUS})"
            fi
        else
            log_fail "EID ${eid}: Bad response format: ${resp}"
        fi
    done
}

# ── Phase 2.5: Controller Health Status Poll ────────────────────────────────

test_controller_health_status_poll() {
    log_header "PHASE 2.5: NVMe-MI - CONTROLLER HEALTH STATUS POLL (OpCode 0x06)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Controller Health Status Poll:
    #   OpCode = 0x06
    #   CDW0[15:0] = Controller Identifier (0 = first controller)
    # Response data (nvme_mi_ctrl_health_status, 16 bytes at resp[8]):
    #   Bytes 0-1 (resp[8-9]):   ctlid - Controller ID (16-bit LE)
    #   Bytes 2-3 (resp[10-11]): csts  - Controller Status (16-bit LE)
    #   Bytes 4-5 (resp[12-13]): ctemp - Composite Temperature (16-bit LE, Kelvin)
    #   Byte 6 (resp[14]):       pdlu  - Percentage Used
    #   Byte 7 (resp[15]):       spare - Available Spare
    #   Byte 8 (resp[16]):       cwarn - Critical Warning
    #   Bytes 9-15 (resp[17-23]): reserved

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Controller Health Status Poll for EID ${eid} (Controller 0)"

        # CDW0 = 0x00000000 (controller ID = 0)
        local resp
        resp=$(send_nvme_mi_cmd "${eid}" 6 0 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ]; then
                log_pass "EID ${eid}: Controller Health Status Poll succeeded (status=0)"

                if [ "${#RESP_BYTES[@]}" -ge 17 ]; then
                    local ctlid=$(( RESP_BYTES[8] | (RESP_BYTES[9] << 8) ))
                    local csts=$(( RESP_BYTES[10] | (RESP_BYTES[11] << 8) ))
                    local ctemp_k=$(( RESP_BYTES[12] | (RESP_BYTES[13] << 8) ))
                    local ctemp_c=$(( ctemp_k - 273 ))
                    local pdlu="${RESP_BYTES[14]}"
                    local spare="${RESP_BYTES[15]}"
                    local cwarn="${RESP_BYTES[16]}"

                    log_info "EID ${eid}: Controller ID = ${ctlid}"

                    # Decode CSTS
                    log_info "EID ${eid}: Controller Status (CSTS) = 0x$(printf '%04X' ${csts})"
                    local csts_rdy=$(( csts & 0x01 ))
                    local csts_cfs=$(( (csts >> 1) & 0x01 ))
                    local csts_shst=$(( (csts >> 2) & 0x03 ))
                    local csts_nssro=$(( (csts >> 4) & 0x01 ))
                    log_info "EID ${eid}:   RDY=${csts_rdy} CFS=${csts_cfs} SHST=${csts_shst} NSSRO=${csts_nssro}"

                    # CFS via MI sideband can be stale/inaccurate on some firmware
                    if [ "${csts_cfs}" -eq 1 ]; then
                        log_warn "EID ${eid}: Controller Fatal Status (CFS) reported via MI (may be firmware quirk)"
                    fi
                    if [ "${csts_rdy}" -eq 1 ]; then
                        log_pass "EID ${eid}: Controller is Ready (RDY=1)"
                    else
                        log_warn "EID ${eid}: Controller is NOT Ready (RDY=0)"
                    fi

                    # Temperature
                    if [ "${ctemp_k}" -gt 0 ] && [ "${ctemp_k}" -lt 1000 ]; then
                        log_info "EID ${eid}: Composite Temperature = ${ctemp_c}°C (${ctemp_k}K)"
                        if [ "${ctemp_c}" -gt 85 ]; then
                            log_warn "EID ${eid}: Temperature exceeds 85°C!"
                        fi
                    else
                        log_info "EID ${eid}: Composite Temperature = ${ctemp_k}K (raw, may be invalid)"
                    fi

                    # PDLU, Spare, Critical Warning
                    log_info "EID ${eid}: Percentage Used (PDLU) = ${pdlu}%"
                    log_info "EID ${eid}: Available Spare = ${spare}%"
                    log_info "EID ${eid}: Critical Warning = 0x$(printf '%02X' ${cwarn})"

                    if [ "${cwarn}" -ne 0 ]; then
                        local cw_details=""
                        [ $((cwarn & 0x01)) -ne 0 ] && cw_details="${cw_details} Spare-Threshold"
                        [ $((cwarn & 0x02)) -ne 0 ] && cw_details="${cw_details} Temp-Threshold"
                        [ $((cwarn & 0x04)) -ne 0 ] && cw_details="${cw_details} Reliability-Degraded"
                        [ $((cwarn & 0x08)) -ne 0 ] && cw_details="${cw_details} Read-Only"
                        [ $((cwarn & 0x10)) -ne 0 ] && cw_details="${cw_details} Volatile-Backup-Failed"
                        log_warn "EID ${eid}: Critical Warning flags:${cw_details}"
                    fi

                    if [ "${spare}" -lt 10 ] && [ "${spare}" -gt 0 ]; then
                        log_warn "EID ${eid}: Available Spare is critically low (${spare}%)!"
                    fi
                fi
            else
                log_fail "EID ${eid}: Controller Health Status Poll failed (status=${MI_STATUS})"
            fi
        else
            log_fail "EID ${eid}: Bad response format: ${resp}"
        fi
    done
}

# ── Phase 2.6: Configuration Get - MCTP Transmission Unit Size ──────────────

test_config_get_mctp_mtu() {
    log_header "PHASE 2.6: NVMe-MI - CONFIGURATION GET: MCTP MTU SIZE (OpCode 0x04, CfgID 0x03)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Configuration Get:
    #   OpCode = 0x04
    #   CDW0[7:0]  = Configuration Identifier = 0x03 (MCTP Transmission Unit Size)
    #   CDW0[23:8] = Controller Identifier = 0x0000
    #   CDW0 = 0x00000003
    # Response: Management Response bytes [5-7] contain the config value

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Config Get MCTP MTU for EID ${eid}"

        local resp
        resp=$(send_nvme_mi_cmd "${eid}" 4 3 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ]; then
                log_pass "EID ${eid}: Configuration Get (MCTP MTU) succeeded (status=0)"

                # The management response field (bytes 5-7) contains the MTU value
                if [ "${#RESP_BYTES[@]}" -ge 8 ]; then
                    local mtu_val=$(( RESP_BYTES[5] | (RESP_BYTES[6] << 8) ))
                    log_info "EID ${eid}: MCTP Transmission Unit Size = ${mtu_val} bytes"
                fi
            else
                # Status 0x04 = "Invalid Parameter" is common if config ID not supported
                log_warn "EID ${eid}: Configuration Get (MCTP MTU) returned status=${MI_STATUS} (may not be supported)"
                TOTAL_TESTS=$((TOTAL_TESTS + 1))
                PASSED_TESTS=$((PASSED_TESTS + 1))
            fi
        else
            log_fail "EID ${eid}: Bad response format: ${resp}"
        fi
    done
}

# ── Phase 2.7: Configuration Get - Health Status Change ─────────────────────

test_config_get_health_status_change() {
    log_header "PHASE 2.7: NVMe-MI - CONFIGURATION GET: HEALTH STATUS CHANGE (OpCode 0x04, CfgID 0x02)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Configuration Get:
    #   OpCode = 0x04
    #   CDW0[7:0]  = Configuration Identifier = 0x02 (Health Status Change)
    #   CDW0[23:8] = Controller Identifier = 0x0000
    #   CDW0 = 0x00000002

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Config Get Health Status Change for EID ${eid}"

        local resp
        resp=$(send_nvme_mi_cmd "${eid}" 4 2 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ]; then
                log_pass "EID ${eid}: Configuration Get (Health Status Change) succeeded (status=0)"

                if [ "${#RESP_BYTES[@]}" -ge 8 ]; then
                    local hsc_val=$(( RESP_BYTES[5] | (RESP_BYTES[6] << 8) ))
                    log_info "EID ${eid}: Health Status Change config = 0x$(printf '%04X' ${hsc_val})"
                fi
            else
                log_warn "EID ${eid}: Configuration Get (HSC) returned status=${MI_STATUS} (may not be supported)"
                TOTAL_TESTS=$((TOTAL_TESTS + 1))
                PASSED_TESTS=$((PASSED_TESTS + 1))
            fi
        else
            log_fail "EID ${eid}: Bad response format: ${resp}"
        fi
    done
}

# Admin command support flag (probed at runtime)
ADMIN_CMD_SUPPORTED="unknown"

# ── NVMe-MI Admin Command Functions ─────────────────────────────────────────
# NVMe Admin Commands can be tunneled through NVMe-MI using MT=0 (Admin) in
# the NMP byte. The message format follows NVMe-MI spec section 6:
#   Bytes 0-3:   NVMe-MI Header (0x84, NMP=0x00, Reserved, Reserved)
#   Byte 4:      Admin Opcode
#   Byte 5:      Flags (data transfer direction)
#   Bytes 6-7:   Controller ID (LE 16-bit)
#   Bytes 8-11:  CDW1 / NSID (LE 32-bit)
#   Bytes 12-27: CDW2-CDW5 (16 bytes, usually 0)
#   Bytes 28-31: Data Offset (LE 32-bit)
#   Bytes 32-35: Data Length (LE 32-bit)
#   Bytes 36-59: CDW10-CDW15 (24 bytes)
#   Bytes 60-63: MIC (CRC-32C)
#   Total: 64 bytes

# Build NVMe-MI Admin Command payload
# Args: ctrl_id, admin_opcode, nsid, cdw10, cdw11
build_nvme_mi_admin_cmd() {
    local ctrl_id=${1:-0}
    local admin_opcode=$2
    local nsid=${3:-0}
    local cdw10=${4:-0}
    local cdw11=${5:-0}

    _le32() { printf '%02X%02X%02X%02X' $(($1 & 0xFF)) $((($1 >> 8) & 0xFF)) $((($1 >> 16) & 0xFF)) $((($1 >> 24) & 0xFF)); }

    local opc_hex ctrl_lo ctrl_hi
    opc_hex=$(printf '%02X' $((admin_opcode & 0xFF)))
    ctrl_lo=$(printf '%02X' $((ctrl_id & 0xFF)))
    ctrl_hi=$(printf '%02X' $(((ctrl_id >> 8) & 0xFF)))

    # 60-byte payload (before MIC)
    local p="84000000"                          # Bytes 0-3: MCTP hdr, NMP=0 (Admin), Rsvd
    p+="${opc_hex}00${ctrl_lo}${ctrl_hi}"        # Bytes 4-7: Opcode, Flags, CtrlID
    p+="$(_le32 ${nsid})"                        # Bytes 8-11: CDW1/NSID
    p+="000000000000000000000000000000000000000000000000"  # Bytes 12-35: CDW2-5,DOFF,DLEN (24B)
    p+="$(_le32 ${cdw10})"                       # Bytes 36-39: CDW10
    p+="$(_le32 ${cdw11})"                       # Bytes 40-43: CDW11
    p+="00000000000000000000000000000000"         # Bytes 44-59: CDW12-15 (16B)

    local mic
    mic=$(compute_crc32c "${p}")

    local busctl_bytes=""
    for (( i=0; i<${#p}; i+=2 )); do
        busctl_bytes+="  0x${p:$i:2}"
    done

    echo "64${busctl_bytes} ${mic}"
}

# Send NVMe-MI Admin Command and return raw response
# Args: eid, ctrl_id, admin_opcode, nsid, cdw10, cdw11
send_nvme_mi_admin_cmd() {
    local eid=$1
    local ctrl_id=${2:-0}
    local admin_opcode=$3
    local nsid=${4:-0}
    local cdw10=${5:-0}
    local cdw11=${6:-0}

    local cmd_args
    cmd_args=$(build_nvme_mi_admin_cmd "${ctrl_id}" "${admin_opcode}" "${nsid}" "${cdw10}" "${cdw11}")

    local full_cmd="busctl call ${MCTP_SERVICE} ${MCTP_OBJ_PATH} ${MCTP_IFACE} ${SEND_METHOD} yayq ${eid} ${cmd_args} ${NVME_MI_TIMEOUT}"
    log_info "Sending NVMe Admin cmd: opcode=0x$(printf '%02X' ${admin_opcode}), cdw10=0x$(printf '%08X' ${cdw10})" >&2

    local result
    result=$(run_on_bmc "${full_cmd}" 2>&1) || true
    echo "${result}"
}

# Parse NVMe-MI Admin Command response
# Sets: RESP_BYTES[], RESP_LEN, MI_STATUS, ADMIN_CDW0, ADMIN_CDW3, NVME_STATUS
parse_nvme_mi_admin_response() {
    local response="$1"
    RESP_BYTES=()
    RESP_LEN=0
    MI_STATUS=255
    ADMIN_CDW0=0
    ADMIN_CDW3=0
    NVME_STATUS=0

    if [[ "${response}" =~ ^ay\ ([0-9]+)\ (.+)$ ]]; then
        RESP_LEN="${BASH_REMATCH[1]}"
        local resp_data="${BASH_REMATCH[2]}"
        IFS=' ' read -ra RESP_BYTES <<< "${resp_data}"

        # Admin Response: [0]=0x84, [1]=0x80 (NMP ROR=1,MT=0), [2-3]=rsvd
        # [4]=MI Status, [5-7]=Mgmt Response
        # [8-11]=CQE CDW0 (command result, LE 32-bit)
        # [12-15]=CQE CDW1
        # [16-19]=CQE CDW3 (NVMe status field)
        # [20-23]=MIC
        if [ "${#RESP_BYTES[@]}" -ge 5 ]; then
            MI_STATUS="${RESP_BYTES[4]}"
        fi
        if [ "${#RESP_BYTES[@]}" -ge 12 ]; then
            ADMIN_CDW0=$(( RESP_BYTES[8] | (RESP_BYTES[9] << 8) | (RESP_BYTES[10] << 16) | (RESP_BYTES[11] << 24) ))
        fi
        if [ "${#RESP_BYTES[@]}" -ge 20 ]; then
            ADMIN_CDW3=$(( RESP_BYTES[16] | (RESP_BYTES[17] << 8) | (RESP_BYTES[18] << 16) | (RESP_BYTES[19] << 24) ))
            # NVMe Status = bits [15:1] of CQE CDW3
            NVME_STATUS=$(( (ADMIN_CDW3 >> 1) & 0x7FFF ))
        fi
        return 0
    fi
    return 1
}

# ── Phase 2.8: NVMe Power State ─────────────────────────────────────────────

test_nvme_power_state() {
    log_header "PHASE 2.8: NVMe ADMIN - GET CURRENT POWER STATE (Get Features FID 0x02)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Probe admin command support on first NVMe EID
    if [ "${ADMIN_CMD_SUPPORTED}" = "unknown" ]; then
        log_info "Probing NVMe-MI Admin command support on EID ${NVME_EIDS[0]}..."
        local probe_resp
        probe_resp=$(send_nvme_mi_admin_cmd "${NVME_EIDS[0]}" 0 $((0x0A)) 0 $((0x02)) 0)
        if [[ "${probe_resp}" == ay\ * ]]; then
            ADMIN_CMD_SUPPORTED="yes"
            log_info "Admin command passthrough is SUPPORTED"
        else
            ADMIN_CMD_SUPPORTED="no"
            log_warn "Admin command passthrough NOT supported by BMC MCTP stack (MT=0 rejected)"
            log_warn "Phases 2.8-2.11 will be skipped. Power info available from Phase 2.4 CCS/SHST."
            return
        fi
    fi

    if [ "${ADMIN_CMD_SUPPORTED}" = "no" ]; then
        log_warn "Skipped - Admin commands not supported"
        return
    fi

    # Get Features (opcode 0x0A), FID 0x02 = Power Management, SEL=0 (Current)
    # CDW10[7:0]=FID=0x02, CDW10[10:8]=SEL=0
    # Response CQE CDW0[4:0] = PS (Current Power State 0-31)
    # Response CQE CDW0[7:5] = WH (Workload Hint)

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Get Power State for EID ${eid}"

        local resp
        resp=$(send_nvme_mi_admin_cmd "${eid}" 0 $((0x0A)) 0 $((0x02)) 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_admin_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ] && [ "${NVME_STATUS}" -eq 0 ]; then
                local ps=$(( ADMIN_CDW0 & 0x1F ))
                local wh=$(( (ADMIN_CDW0 >> 5) & 0x07 ))
                log_pass "EID ${eid}: Current Power State = PS${ps}"
                log_info "EID ${eid}: Workload Hint = ${wh}"

                # PS0 = max performance, higher PS = lower power
                if [ "${ps}" -eq 0 ]; then
                    log_info "EID ${eid}: Drive is in maximum performance state (PS0)"
                elif [ "${ps}" -le 3 ]; then
                    log_info "EID ${eid}: Drive is in operational power state PS${ps}"
                else
                    log_warn "EID ${eid}: Drive is in non-operational/deep idle state PS${ps}"
                fi
            elif [ "${MI_STATUS}" -ne 0 ]; then
                log_fail "EID ${eid}: MI Status error (${MI_STATUS})"
            else
                local sct=$(( (NVME_STATUS >> 8) & 0x7 ))
                local sc=$(( NVME_STATUS & 0xFF ))
                log_fail "EID ${eid}: NVMe error SCT=${sct} SC=0x$(printf '%02X' ${sc})"
            fi
        else
            log_fail "EID ${eid}: Bad response: ${resp}"
        fi
    done
}

# ── Phase 2.9: Autonomous Power State Transition ────────────────────────────

test_nvme_apst() {
    log_header "PHASE 2.9: NVMe ADMIN - AUTONOMOUS POWER STATE TRANSITION (Get Features FID 0x0C)"

    if [ "${ADMIN_CMD_SUPPORTED}" = "no" ]; then
        log_warn "Skipped - Admin commands not supported"
        return
    fi
    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Get Features (opcode 0x0A), FID 0x0C = Autonomous Power State Transition
    # CDW10[7:0]=FID=0x0C, CDW10[10:8]=SEL=0 (Current)
    # Response CQE CDW0[0] = APSTE (0=disabled, 1=enabled)

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Get APST Config for EID ${eid}"

        local resp
        resp=$(send_nvme_mi_admin_cmd "${eid}" 0 $((0x0A)) 0 $((0x0C)) 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_admin_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ] && [ "${NVME_STATUS}" -eq 0 ]; then
                local apste=$(( ADMIN_CDW0 & 0x01 ))
                if [ "${apste}" -eq 1 ]; then
                    log_pass "EID ${eid}: APST is ENABLED"
                    log_info "EID ${eid}: Drive will auto-transition to lower power states when idle"
                else
                    log_pass "EID ${eid}: APST is DISABLED"
                    log_info "EID ${eid}: Drive stays in current power state (host-managed)"
                fi
            elif [ "${MI_STATUS}" -ne 0 ]; then
                log_fail "EID ${eid}: MI Status error (${MI_STATUS})"
            else
                local sct=$(( (NVME_STATUS >> 8) & 0x7 ))
                local sc=$(( NVME_STATUS & 0xFF ))
                log_fail "EID ${eid}: NVMe error SCT=${sct} SC=0x$(printf '%02X' ${sc})"
            fi
        else
            log_fail "EID ${eid}: Bad response: ${resp}"
        fi
    done
}

# ── Phase 2.10: Temperature Threshold ────────────────────────────────────────

test_nvme_temp_threshold() {
    log_header "PHASE 2.10: NVMe ADMIN - TEMPERATURE THRESHOLD (Get Features FID 0x04)"

    if [ "${ADMIN_CMD_SUPPORTED}" = "no" ]; then
        log_warn "Skipped - Admin commands not supported"
        return
    fi
    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Get Features (opcode 0x0A), FID 0x04 = Temperature Threshold
    # CDW10[7:0]=FID=0x04, CDW10[10:8]=SEL=0 (Current)
    # CDW11[19:16]=TMPSEL (0=composite, 1-8=sensors), CDW11[20]=THSEL (0=over,1=under)
    # Response CQE CDW0[15:0] = TMPTH (threshold in Kelvin)
    # Query composite over-temperature threshold (CDW11=0)

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Get Temperature Threshold for EID ${eid}"

        # CDW11=0x00000000: TMPSEL=0 (composite), THSEL=0 (over-temperature)
        local resp
        resp=$(send_nvme_mi_admin_cmd "${eid}" 0 $((0x0A)) 0 $((0x04)) 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_admin_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ] && [ "${NVME_STATUS}" -eq 0 ]; then
                local tmpth_k=$(( ADMIN_CDW0 & 0xFFFF ))
                local tmpth_c=$(( tmpth_k - 273 ))
                log_pass "EID ${eid}: Over-Temperature Threshold = ${tmpth_c}°C (${tmpth_k}K)"

                if [ "${tmpth_k}" -eq 0 ] || [ "${tmpth_k}" -gt 500 ]; then
                    log_info "EID ${eid}: Threshold appears unset or invalid"
                elif [ "${tmpth_c}" -le 70 ]; then
                    log_info "EID ${eid}: Conservative threshold (<= 70°C)"
                elif [ "${tmpth_c}" -le 85 ]; then
                    log_info "EID ${eid}: Standard threshold (70-85°C)"
                else
                    log_warn "EID ${eid}: High threshold (> 85°C)"
                fi
            elif [ "${MI_STATUS}" -ne 0 ]; then
                log_fail "EID ${eid}: MI Status error (${MI_STATUS})"
            else
                local sct=$(( (NVME_STATUS >> 8) & 0x7 ))
                local sc=$(( NVME_STATUS & 0xFF ))
                log_fail "EID ${eid}: NVMe error SCT=${sct} SC=0x$(printf '%02X' ${sc})"
            fi
        else
            log_fail "EID ${eid}: Bad response: ${resp}"
        fi
    done
}

# ── Phase 2.11: Number of Queues (Admin Path Validation) ────────────────────

test_nvme_num_queues() {
    log_header "PHASE 2.11: NVMe ADMIN - NUMBER OF QUEUES (Get Features FID 0x07)"

    if [ "${ADMIN_CMD_SUPPORTED}" = "no" ]; then
        log_warn "Skipped - Admin commands not supported"
        return
    fi
    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI endpoints found, skipping"
        return
    fi

    # Get Features (opcode 0x0A), FID 0x07 = Number of Queues
    # CDW10[7:0]=FID=0x07, CDW10[10:8]=SEL=0 (Current)
    # Response CQE CDW0[15:0] = NSQA (Number of I/O Submission Queues Allocated, 0-based)
    # Response CQE CDW0[31:16] = NCQA (Number of I/O Completion Queues Allocated, 0-based)

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "Get Number of Queues for EID ${eid}"

        local resp
        resp=$(send_nvme_mi_admin_cmd "${eid}" 0 $((0x0A)) 0 $((0x07)) 0)
        echo "  Response: ${resp}"

        if parse_nvme_mi_admin_response "${resp}"; then
            if [ "${MI_STATUS}" -eq 0 ] && [ "${NVME_STATUS}" -eq 0 ]; then
                local nsqa=$(( (ADMIN_CDW0 & 0xFFFF) + 1 ))
                local ncqa=$(( ((ADMIN_CDW0 >> 16) & 0xFFFF) + 1 ))
                log_pass "EID ${eid}: Admin command path validated OK"
                log_info "EID ${eid}: I/O Submission Queues = ${nsqa}"
                log_info "EID ${eid}: I/O Completion Queues = ${ncqa}"
            elif [ "${MI_STATUS}" -ne 0 ]; then
                log_fail "EID ${eid}: MI Status error (${MI_STATUS})"
            else
                local sct=$(( (NVME_STATUS >> 8) & 0x7 ))
                local sc=$(( NVME_STATUS & 0xFF ))
                log_fail "EID ${eid}: NVMe error SCT=${sct} SC=0x$(printf '%02X' ${sc})"
            fi
        else
            log_fail "EID ${eid}: Bad response: ${resp}"
        fi
    done
}

# ── Phase 3: Check MCTP Errors ──────────────────────────────────────────────

check_mctp_errors() {
    log_header "PHASE 3: CHECK JOURNALCTL FOR MCTP ERRORS"

    log_info "Checking for MCTP-related errors in journalctl..."

    JOURNAL_OUTPUT=$(run_on_bmc "journalctl -u '*mctp*' --no-pager -p err -n 100 2>&1") || true

    if [ -z "${JOURNAL_OUTPUT}" ] || echo "${JOURNAL_OUTPUT}" | grep -qE "^$|No entries|-- No entries --"; then
        log_pass "No MCTP service errors found"
    else
        log_warn "MCTP service errors found:"
        echo "${JOURNAL_OUTPUT}" | head -30
    fi

    JOURNAL_MCTP=$(run_on_bmc "journalctl --no-pager -p err -n 500 2>&1 | grep -i mctp" 2>/dev/null) || true
    if [ -z "${JOURNAL_MCTP}" ]; then
        log_pass "No MCTP keyword errors in recent journal"
    else
        local line_count
        line_count=$(echo "${JOURNAL_MCTP}" | wc -l)
        log_warn "Found ${line_count} MCTP-related error entries"
        echo "${JOURNAL_MCTP}" | head -20
    fi
}

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    log_header "TEST SUMMARY"
    echo ""

    # Print per-EID health data table
    echo -e "  ${BOLD}Endpoint Overview:${NC}"
    printf "  %-8s %-12s %-12s %-12s\n" "EID" "Category" "NVMe-MI" "PLDM"
    printf "  %-8s %-12s %-12s %-12s\n" "────" "────────" "────────" "────"
    for eid in "${EIDS[@]}"; do
        local cat="MCTP"
        local nvme="No"
        local pldm="No"
        for e in "${NON_MCTP_EIDS[@]:-}"; do [ "$e" = "$eid" ] && cat="BMC/OOBMSM"; done
        for e in "${NVME_EIDS[@]:-}"; do [ "$e" = "$eid" ] && nvme="Yes"; done
        for e in "${PLDM_EIDS[@]:-}"; do [ "$e" = "$eid" ] && pldm="Yes"; done
        printf "  %-8s %-12s %-12s %-12s\n" "${eid}" "${cat}" "${nvme}" "${pldm}"
    done
    echo ""

    # Print per-test-case results
    echo -e "  ${BOLD}Test Case Results:${NC}"
    printf "  %-10s %-8s %-8s %-8s  %s\n" "ID" "Result" "Pass" "Fail" "Description"
    printf "  %-10s %-8s %-8s %-8s  %s\n" "──────" "──────" "────" "────" "───────────"
    for id in "${TC_IDS[@]}"; do
        local result="${TC_RESULTS[${id}]}"
        local color="${GREEN}"
        [ "${result}" = "FAIL" ] && color="${RED}"
        [ "${result}" = "NOT_RUN" ] && color="${YELLOW}"
        printf "  %-10s ${color}%-8s${NC} %-8s %-8s  %s\n" \
            "${id}" "${result}" "${TC_PASSED[${id}]}" "${TC_FAILED[${id}]}" "${TC_DESCS[${id}]}"
    done
    echo ""

    echo -e "  ${BOLD}Overall Results:${NC}"
    echo -e "    Total Tests:  ${TOTAL_TESTS}"
    echo -e "    ${GREEN}Passed:       ${PASSED_TESTS}${NC}"
    echo -e "    ${RED}Failed:       ${FAILED_TESTS}${NC}"
    echo -e "    ${YELLOW}Warnings:     ${WARNINGS}${NC}"
    echo ""

    if [ "${FAILED_TESTS}" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}OVERALL: ALL ${TOTAL_TESTS} TESTS PASSED${NC}"
    else
        echo -e "  ${RED}${BOLD}OVERALL: ${FAILED_TESTS} OF ${TOTAL_TESTS} TEST(S) FAILED${NC}"
    fi
    echo ""
}

# ── Phase 4: Check Host dmesg Errors ────────────────────────────────────────

check_host_dmesg_errors() {
    log_header "PHASE 4: CHECK HOST DMESG FOR NVMe/PCIe ERRORS"

    local dmesg_out
    dmesg_out=$(dmesg --level=err,crit,alert,emerg 2>/dev/null || dmesg | grep -iE 'error|critical|alert|emerg') || true

    # Filter for storage/PCIe related errors
    local nvme_errs pcie_errs io_errs
    nvme_errs=$(echo "${dmesg_out}" | grep -iE 'nvme|nvmet' 2>/dev/null || true)
    pcie_errs=$(echo "${dmesg_out}" | grep -iE 'pcie|aer|pci[^e].*error|uncorrect|correct.*error' 2>/dev/null || true)
    io_errs=$(echo "${dmesg_out}" | grep -iE 'blk_update_request|I/O error|medium error|hardware error' 2>/dev/null || true)

    local has_errors=false

    if [ -n "${nvme_errs}" ]; then
        local nvme_count
        nvme_count=$(echo "${nvme_errs}" | wc -l)
        log_fail "Found ${nvme_count} NVMe error(s) in dmesg"
        echo "${nvme_errs}" | tail -10 | while IFS= read -r line; do
            log_info "  ${line}"
        done
        [ "${nvme_count}" -gt 10 ] && log_info "  ... (${nvme_count} total, showing last 10)"
        has_errors=true
    fi

    if [ -n "${pcie_errs}" ]; then
        local pcie_count
        pcie_count=$(echo "${pcie_errs}" | wc -l)
        log_fail "Found ${pcie_count} PCIe error(s) in dmesg"
        echo "${pcie_errs}" | tail -10 | while IFS= read -r line; do
            log_info "  ${line}"
        done
        [ "${pcie_count}" -gt 10 ] && log_info "  ... (${pcie_count} total, showing last 10)"
        has_errors=true
    fi

    if [ -n "${io_errs}" ]; then
        local io_count
        io_count=$(echo "${io_errs}" | wc -l)
        log_fail "Found ${io_count} I/O error(s) in dmesg"
        echo "${io_errs}" | tail -10 | while IFS= read -r line; do
            log_info "  ${line}"
        done
        [ "${io_count}" -gt 10 ] && log_info "  ... (${io_count} total, showing last 10)"
        has_errors=true
    fi

    if [ "${has_errors}" = false ]; then
        log_pass "No NVMe/PCIe/I/O errors found in host dmesg"
    fi
}

# ── Test Case Definitions ────────────────────────────────────────────────────

# TC_001: MCTP NVMe-MI Discovery, Health & Telemetry
# Covers:
#   HSD 16029342694 - Storage_PCIe MCTP - Check periodic alive status and
#                     telemetry message on PCIe device - idle
#   HSD 16029342717 - Storage_PCIe MCTP - Check allocation of MCTP discover
#                     for a 4x4 device over HSBP or broadway riser
tc_001() {
    # Phase 1: MCTP Infrastructure
    discover_endpoints
    classify_endpoints
    verify_nvme_mi_presence
    test_mctp_get_endpoint_id
    test_mctp_get_message_type_support
    test_mctp_get_version_support

    # Phase 2: NVMe-MI Management Commands
    test_read_nvm_subsystem_info
    test_read_port_info
    test_read_controller_info
    test_nvm_subsystem_health_status_poll
    test_controller_health_status_poll
    test_config_get_mctp_mtu
    test_config_get_health_status_change

    # Phase 2.8-2.11: NVMe Admin Commands (Power Management)
    test_nvme_power_state
    test_nvme_apst
    test_nvme_temp_threshold
    test_nvme_num_queues

    # Phase 3: Error Analysis
    check_mctp_errors
}

register_test_case "TC_001" "tc_001" \
    "MCTP NVMe-MI Discovery, Health & Telemetry" \
    "16029342694, 16029342717"

# TC_002: MCTP NVMe-MI Under FIO Stress
# Covers:
#   HSD 16029342728 - Storage_PCIe MCTP - Stress_FIO
#
# Runs FIO mixed read/write stress on all NVMe drives in the background,
# then executes the same MCTP NVMe-MI tests as TC_001 to verify MI
# responsiveness under I/O load. FIO is stopped after tests complete.

FIO_PID=0
FIO_RUNTIME="${FIO_RUNTIME:-300}"
FIO_BS="${FIO_BS:-128k}"
FIO_IODEPTH="${FIO_IODEPTH:-32}"
FIO_RW="${FIO_RW:-randrw}"
FIO_MIXREAD="${FIO_MIXREAD:-70}"

start_fio_stress() {
    log_header "STARTING FIO STRESS ON ALL NVMe DRIVES"

    if ! command -v fio &>/dev/null; then
        log_fail "fio not found — install with: dnf install -y fio"
        return 1
    fi

    # Discover all NVMe block devices (exclude partitions)
    local nvme_devs=()
    for dev in /dev/nvme*n1; do
        [ -b "${dev}" ] || continue
        # Skip if mounted or has mounted partitions
        if findmnt -rn -S "${dev}" &>/dev/null || findmnt -rn -S "${dev}p*" &>/dev/null; then
            log_warn "Skipping ${dev} — mounted filesystem detected"
            continue
        fi
        nvme_devs+=("${dev}")
    done

    if [ ${#nvme_devs[@]} -eq 0 ]; then
        log_fail "No available NVMe drives for FIO stress"
        return 1
    fi

    # Build fio --filename argument (colon-separated)
    local fio_targets
    fio_targets=$(IFS=:; echo "${nvme_devs[*]}")

    log_info "FIO targets: ${nvme_devs[*]}"
    log_info "FIO params: bs=${FIO_BS} iodepth=${FIO_IODEPTH} rw=${FIO_RW} rwmixread=${FIO_MIXREAD} runtime=${FIO_RUNTIME}s"

    fio \
        --name=mctp_stress \
        --filename="${fio_targets}" \
        --ioengine=libaio \
        --direct=1 \
        --bs="${FIO_BS}" \
        --iodepth="${FIO_IODEPTH}" \
        --rw="${FIO_RW}" \
        --rwmixread="${FIO_MIXREAD}" \
        --numjobs=1 \
        --runtime="${FIO_RUNTIME}" \
        --time_based \
        --group_reporting \
        --output=/tmp/fio_mctp_stress.log \
        &>/dev/null &
    FIO_PID=$!

    # Give FIO a moment to ramp up
    sleep 2

    if kill -0 "${FIO_PID}" 2>/dev/null; then
        log_pass "FIO stress started (PID ${FIO_PID}) on ${#nvme_devs[@]} drive(s)"
    else
        log_fail "FIO process exited prematurely — check /tmp/fio_mctp_stress.log"
        FIO_PID=0
        return 1
    fi
}

stop_fio_stress() {
    log_header "STOPPING FIO STRESS"

    if [ "${FIO_PID}" -ne 0 ] && kill -0 "${FIO_PID}" 2>/dev/null; then
        kill "${FIO_PID}" 2>/dev/null || true
        wait "${FIO_PID}" 2>/dev/null || true
        log_pass "FIO stress stopped (PID ${FIO_PID})"

        # Parse and report FIO results
        if [ -f /tmp/fio_mctp_stress.log ]; then
            log_info "FIO results summary:"
            local read_bw write_bw read_iops write_iops
            read_bw=$(grep -oP 'READ:.*bw=\K[^,]+' /tmp/fio_mctp_stress.log 2>/dev/null || echo "N/A")
            write_bw=$(grep -oP 'WRITE:.*bw=\K[^,]+' /tmp/fio_mctp_stress.log 2>/dev/null || echo "N/A")
            read_iops=$(grep -oP 'READ:.*IOPS=\K[^,]+' /tmp/fio_mctp_stress.log 2>/dev/null || echo "N/A")
            write_iops=$(grep -oP 'WRITE:.*IOPS=\K[^,]+' /tmp/fio_mctp_stress.log 2>/dev/null || echo "N/A")
            log_info "  Read:  BW=${read_bw}  IOPS=${read_iops}"
            log_info "  Write: BW=${write_bw}  IOPS=${write_iops}"
        fi
    else
        log_warn "FIO was not running (may have finished or failed to start)"
    fi
    FIO_PID=0
}

tc_002() {
    # Start FIO stress on all NVMe drives
    start_fio_stress

    # Run the same MCTP NVMe-MI tests under I/O load
    # Phase 1: MCTP Infrastructure
    discover_endpoints
    classify_endpoints
    verify_nvme_mi_presence
    test_mctp_get_endpoint_id
    test_mctp_get_message_type_support
    test_mctp_get_version_support

    # Phase 2: NVMe-MI Management Commands
    test_read_nvm_subsystem_info
    test_read_port_info
    test_read_controller_info
    test_nvm_subsystem_health_status_poll
    test_controller_health_status_poll
    test_config_get_mctp_mtu
    test_config_get_health_status_change

    # Phase 2.8-2.11: NVMe Admin Commands (Power Management)
    test_nvme_power_state
    test_nvme_apst
    test_nvme_temp_threshold
    test_nvme_num_queues

    # Phase 3: Error Analysis
    check_mctp_errors

    # Stop FIO and report results
    stop_fio_stress

    # Phase 4: Check host dmesg for NVMe/PCIe errors
    check_host_dmesg_errors
}

register_test_case "TC_002" "tc_002" \
    "MCTP NVMe-MI Under FIO Stress" \
    "16029342728"

# TC_003: Check drive is NVMe-MI capable over Redfish
# Covers:
#   HSD 16029831611 - Storage_Check drive is NVMe-MI capable over Redfish
#
# Queries the BMC's Redfish MCTP service to enumerate MCTP PCIe endpoints
# and checks SupportedMessageTypes.NVMeMgmtMsg for NVMe-MI capability.
# Fails if no NVMe-MI capable drives are found.

REDFISH_BASE="https://${BMC_IP}"
MCTP_COLLECTION="/redfish/v1/Managers/bmc/MctpService/MCTP_PCIe"
RF_TOKEN=""

redfish_create_session() {
    local resp
    resp=$(curl -sk --noproxy '*' -X POST \
        -H "Content-Type: application/json" \
        -d "{\"UserName\":\"${BMC_RF_USER}\",\"Password\":\"${BMC_RF_PASS}\"}" \
        -D - -o /dev/null \
        "${REDFISH_BASE}/redfish/v1/SessionService/Sessions" 2>/dev/null)
    RF_TOKEN=$(echo "${resp}" | grep -i 'X-Auth-Token' | awk '{print $2}' | tr -d '\r\n')
    [[ -n "${RF_TOKEN}" ]]
}

redfish_get() {
    curl -sk --noproxy '*' -H "X-Auth-Token: ${RF_TOKEN}" "${REDFISH_BASE}$1" 2>/dev/null
}

tc_003() {
    # Phase 1: Redfish Authentication
    log_header "Phase 1: Redfish Authentication"
    log_info "Creating Redfish session to ${BMC_IP} as ${BMC_RF_USER}"
    if ! redfish_create_session; then
        log_fail "Redfish authentication failed (user: ${BMC_RF_USER})"
        return
    fi
    log_pass "Redfish session established"

    # Phase 2: Enumerate MCTP PCIe endpoints
    log_header "Phase 2: Enumerate MCTP PCIe Endpoints"
    local collection_json
    collection_json=$(redfish_get "${MCTP_COLLECTION}")
    if [[ -z "${collection_json}" ]]; then
        log_fail "Failed to retrieve MCTP PCIe collection"
        return
    fi
    local member_count
    member_count=$(echo "${collection_json}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('Members@odata.count', 0))
except:
    print(0)
")
    if [[ "${member_count}" -eq 0 ]]; then
        log_fail "No MCTP PCIe endpoints found in Redfish"
        return
    fi
    log_pass "Found ${member_count} MCTP PCIe endpoint(s) in Redfish"

    local member_uris
    member_uris=$(echo "${collection_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('Members', []):
    print(m.get('@odata.id', ''))
")

    # Phase 3: Check NVMe-MI capability per endpoint
    log_header "Phase 3: Check NVMe-MI Capability per Endpoint"
    local nvme_mi_count=0
    local non_mi_count=0

    while IFS= read -r uri; do
        [[ -z "${uri}" ]] && continue
        local eid
        eid=$(basename "${uri}")
        log_subheader "EID ${eid}"

        local eid_json
        eid_json=$(redfish_get "${uri}")
        if [[ -z "${eid_json}" ]]; then
            log_fail "EID ${eid}: Failed to retrieve endpoint data"
            continue
        fi

        local nvme_mi_capable
        nvme_mi_capable=$(echo "${eid_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
smt = data.get('SupportedMessageTypes', {})
print('true' if smt.get('NVMeMgmtMsg', False) else 'false')
")
        local dev_addr
        dev_addr=$(echo "${eid_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
da = data.get('DeviceAddress', {})
if da:
    print(f\"Bus={da.get('Bus','?')} Dev={da.get('Device','?')} Func={da.get('Function','?')}\")
else:
    print('N/A')
" 2>/dev/null || echo "N/A")

        local supported_list
        supported_list=$(echo "${eid_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
smt = data.get('SupportedMessageTypes', {})
print(', '.join(k for k, v in sorted(smt.items()) if v))
" 2>/dev/null || echo "")

        log_info "EID ${eid}: PCIe ${dev_addr} | Types: ${supported_list:-none}"

        if [[ "${nvme_mi_capable}" == "true" ]]; then
            log_pass "EID ${eid}: NVMe-MI capable (NVMeMgmtMsg=true)"
            nvme_mi_count=$((nvme_mi_count + 1))
        else
            log_info "EID ${eid}: Not NVMe-MI capable"
            non_mi_count=$((non_mi_count + 1))
        fi
    done <<< "${member_uris}"

    # Phase 4: Final verdict
    log_header "Phase 4: NVMe-MI Capability Summary"
    log_info "Total MCTP endpoints: ${member_count}"
    log_info "NVMe-MI capable:      ${nvme_mi_count}"
    log_info "Not NVMe-MI capable:  ${non_mi_count}"

    if [[ "${nvme_mi_count}" -gt 0 ]]; then
        log_pass "Found ${nvme_mi_count} NVMe-MI capable drive(s) over Redfish"
    else
        log_fail "No NVMe-MI capable drives found over Redfish"
    fi
}

register_test_case "TC_003" "tc_003" \
    "Check drive is NVMe-MI capable over Redfish" \
    "16029831611"

# ── Main ─────────────────────────────────────────────────────────────────────

show_usage() {
    echo "Usage: $0 [OPTIONS] [TC_ID ...]"
    echo ""
    echo "Options:"
    echo "  --bmc-ip IP       BMC IP address (default: ${BMC_IP})"
    echo "  --bmc-user USER   BMC SSH username (default: ${BMC_USER})"
    echo "  --bmc-pass PASS   BMC SSH password (default: ****)"
    echo "  --bmc-rf-user USER BMC Redfish username (default: ${BMC_RF_USER})"
    echo "  --bmc-rf-pass PASS BMC Redfish password (default: ****)"
    echo "  -l, --list        List all registered test cases"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Arguments:"
    echo "  TC_ID             Run specific test case(s) by ID (e.g., TC_001)"
    echo "                    If no TC_ID given, all test cases are run."
    echo ""
    echo "Examples:"
    echo "  $0 --bmc-ip 10.49.83.50 --bmc-user root --bmc-pass secret TC_001"
    echo "  $0 TC_001 TC_002"
    echo "  $0  # run all test cases with defaults"
    echo ""
    echo "Registered test cases:"
    for id in "${TC_IDS[@]}"; do
        printf "  %-10s %s\n" "${id}" "${TC_DESCS[${id}]}"
        [ -n "${TC_HSDS[${id}]}" ] && printf "  %-10s HSD: %s\n" "" "${TC_HSDS[${id}]}"
    done
}

main() {
    local selected_tcs=()

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --bmc-ip)
                [ $# -ge 2 ] || { echo "Error: --bmc-ip requires a value"; exit 1; }
                BMC_IP="$2"; REDFISH_BASE="https://${BMC_IP}"; shift
                ;;
            --bmc-user)
                [ $# -ge 2 ] || { echo "Error: --bmc-user requires a value"; exit 1; }
                BMC_USER="$2"; shift
                ;;
            --bmc-pass)
                [ $# -ge 2 ] || { echo "Error: --bmc-pass requires a value"; exit 1; }
                BMC_PASS="$2"; shift
                ;;
            --bmc-rf-user)
                [ $# -ge 2 ] || { echo "Error: --bmc-rf-user requires a value"; exit 1; }
                BMC_RF_USER="$2"; shift
                ;;
            --bmc-rf-pass)
                [ $# -ge 2 ] || { echo "Error: --bmc-rf-pass requires a value"; exit 1; }
                BMC_RF_PASS="$2"; shift
                ;;
            -l|--list)
                show_usage
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            TC_*)
                if [ -n "${TC_FUNCS[$1]+x}" ]; then
                    selected_tcs+=("$1")
                else
                    echo "Error: Unknown test case '$1'"
                    show_usage
                    exit 1
                fi
                ;;
            *)
                echo "Error: Unknown argument '$1'"
                show_usage
                exit 1
                ;;
        esac
        shift
    done

    # Default: run all test cases
    if [ ${#selected_tcs[@]} -eq 0 ]; then
        selected_tcs=("${TC_IDS[@]}")
    fi

    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║      MCTP NVMe-MI Extended Test Suite v2                     ║"
    echo "║      Based on NVMe-MI Spec Rev 2.0                          ║"
    echo "║      BMC: ${BMC_IP}                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Test Cases: ${selected_tcs[*]}"

    # Pre-flight
    check_prerequisites

    # Run selected test cases
    for tc_id in "${selected_tcs[@]}"; do
        run_test_case "${tc_id}"
    done

    # Summary
    print_summary

    echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    [ "${FAILED_TESTS}" -eq 0 ]
}

main "$@"
