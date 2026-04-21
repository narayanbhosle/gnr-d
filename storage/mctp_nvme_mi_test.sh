#!/bin/bash
###############################################################################
# MCTP NVMe-MI Automated Test Script
#
# Tests MCTP communication with NVMe-MI capable devices on a BMC.
# Steps:
#   1. Discover all MCTP endpoints (EIDs)
#   2. Classify EIDs: General MCTP, NVMe-MI, PLDM
#   3. Validate MCTP communication via Get Endpoint ID command
#   4. Query NVMe-MI device health status for NVMe-MI endpoints
#   5. Check journalctl for MCTP errors
###############################################################################

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BMC_IP="${BMC_IP:-10.49.83.11}"
BMC_USER="${BMC_USER:-root}"
BMC_PASS="${BMC_PASS:-0penBmc1}"
MCTP_SERVICE="xyz.openbmc_project.MCTP_PCIe"
MCTP_OBJ_PATH="/xyz/openbmc_project/mctp"
MCTP_DEVICE_PATH="${MCTP_OBJ_PATH}/device"
MCTP_IFACE="xyz.openbmc_project.MCTP.Base"
SEND_METHOD="SendReceiveMctpMessagePayload"

# Timeout values (ms) for busctl calls
MCTP_CTRL_TIMEOUT=100
NVME_MI_TIMEOUT=600

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0

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

# Run a command on the BMC via SSH
# Uses sshpass for non-interactive password auth
run_on_bmc() {
    local cmd="$1"
    sshpass -p "${BMC_PASS}" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        "${BMC_USER}@${BMC_IP}" "${cmd}" 2>/dev/null
}

# ── Pre-flight Checks ───────────────────────────────────────────────────────

check_prerequisites() {
    log_header "PRE-FLIGHT CHECKS"

    # Check sshpass
    if ! command -v sshpass &>/dev/null; then
        echo -e "${RED}ERROR: sshpass is not installed. Install it with:${NC}"
        echo "  apt-get install -y sshpass   (Debian/Ubuntu)"
        echo "  yum install -y sshpass       (RHEL/CentOS)"
        exit 1
    fi
    log_pass "sshpass is available"

    # Check SSH connectivity
    log_info "Testing SSH connectivity to BMC at ${BMC_IP}..."
    if run_on_bmc "echo ok" | grep -q "ok"; then
        log_pass "SSH connection to BMC (${BMC_IP}) successful"
    else
        log_fail "Cannot SSH to BMC at ${BMC_IP}"
        exit 1
    fi
}

# ── Step 1: Discover MCTP Endpoints ─────────────────────────────────────────

discover_endpoints() {
    log_header "STEP 1: DISCOVER MCTP ENDPOINTS"

    log_info "Running: busctl tree ${MCTP_SERVICE}"
    TREE_OUTPUT=$(run_on_bmc "busctl tree ${MCTP_SERVICE} 2>&1") || true
    echo -e "\n${TREE_OUTPUT}\n"

    # Extract EIDs from the tree output
    EIDS=()
    while IFS= read -r line; do
        # Match lines like /xyz/openbmc_project/mctp/device/NNN
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

# ── Step 2: Classify Endpoints ──────────────────────────────────────────────

classify_endpoints() {
    log_header "STEP 2: CLASSIFY MCTP ENDPOINTS"

    MCTP_EIDS=()       # General MCTP Control devices
    NVME_EIDS=()       # NVMe-MI capable devices
    PLDM_EIDS=()       # PLDM capable devices
    NON_MCTP_EIDS=()   # Devices without MctpControl (likely BMC/OOBMSM)

    for eid in "${EIDS[@]}"; do
        log_subheader "Introspecting EID ${eid}"
        log_info "Running: busctl introspect ${MCTP_SERVICE} ${MCTP_DEVICE_PATH}/${eid}"

        INTROSPECT_OUTPUT=$(run_on_bmc "busctl introspect ${MCTP_SERVICE} ${MCTP_DEVICE_PATH}/${eid} 2>&1") || true
        echo "${INTROSPECT_OUTPUT}"

        # Check properties
        has_mctp_control=false
        has_nvme_mgmt=false
        has_pldm=false

        # Check .MctpControl property
        if echo "${INTROSPECT_OUTPUT}" | grep -qE '\.MctpControl\s+property\s+b\s+true'; then
            has_mctp_control=true
        fi

        # Check .NVMeMgmtMsg property
        if echo "${INTROSPECT_OUTPUT}" | grep -qE '\.NVMeMgmtMsg\s+property\s+b\s+true'; then
            has_nvme_mgmt=true
        fi

        # Check .PLDM property
        if echo "${INTROSPECT_OUTPUT}" | grep -qE '\.PLDM\s+property\s+b\s+true'; then
            has_pldm=true
        fi

        # Classify
        if [ "${has_mctp_control}" = true ]; then
            MCTP_EIDS+=("${eid}")
            log_info "EID ${eid}: MctpControl=true"
        else
            NON_MCTP_EIDS+=("${eid}")
            log_info "EID ${eid}: MctpControl=false (likely BMC/OOBMSM, will be skipped)"
        fi

        if [ "${has_nvme_mgmt}" = true ]; then
            NVME_EIDS+=("${eid}")
            log_info "EID ${eid}: NVMeMgmtMsg=true (NVMe-MI capable)"
        fi

        if [ "${has_pldm}" = true ]; then
            PLDM_EIDS+=("${eid}")
            log_info "EID ${eid}: PLDM=true"
        fi
    done

    # Summary
    log_subheader "Endpoint Classification Summary"
    echo ""
    printf "  %-20s %s\n" "Category" "EIDs"
    printf "  %-20s %s\n" "────────────────────" "──────────────────────────"
    printf "  %-20s %s\n" "All EIDs" "${EIDS[*]}"
    printf "  %-20s %s\n" "MCTP Control (EID)" "${MCTP_EIDS[*]:-none}"
    printf "  %-20s %s\n" "NVMe-MI (NVMeEid)" "${NVME_EIDS[*]:-none}"
    printf "  %-20s %s\n" "PLDM (PLDMEid)" "${PLDM_EIDS[*]:-none}"
    printf "  %-20s %s\n" "Skipped (BMC/OOBMSM)" "${NON_MCTP_EIDS[*]:-none}"
    echo ""

    if [ ${#MCTP_EIDS[@]} -gt 0 ]; then
        log_pass "Found ${#MCTP_EIDS[@]} MCTP-capable endpoint(s)"
    else
        log_warn "No MCTP-capable endpoints found (all may be BMC/OOBMSM)"
    fi

    if [ ${#NVME_EIDS[@]} -gt 0 ]; then
        log_pass "Found ${#NVME_EIDS[@]} NVMe-MI capable endpoint(s): ${NVME_EIDS[*]}"
    else
        log_warn "No NVMe-MI capable endpoints found"
    fi

    if [ ${#PLDM_EIDS[@]} -gt 0 ]; then
        log_pass "Found ${#PLDM_EIDS[@]} PLDM capable endpoint(s): ${PLDM_EIDS[*]}"
    fi
}

# ── Step 3: Validate MCTP Communication (Get Endpoint ID) ───────────────────

validate_mctp_communication() {
    log_header "STEP 3: VALIDATE MCTP COMMUNICATION (Get Endpoint ID)"

    if [ ${#MCTP_EIDS[@]} -eq 0 ]; then
        log_warn "No MCTP-capable endpoints to validate"
        return
    fi

    # MCTP Control Message: Get Endpoint ID
    # Message type 0 = MCTP Control, Command 0x02 = Get Endpoint ID
    # Format: busctl call ... SendReceiveMctpMessagePayload yayq {EID} 3 0 129 2 {timeout}
    #   Payload bytes: 0=MCTP msg type (control), 129(0x81)=Rq bit set|Instance0|IC=0,
    #                  2=Get Endpoint ID command code

    for eid in "${MCTP_EIDS[@]}"; do
        log_subheader "Get Endpoint ID for EID ${eid}"

        CMD="busctl call ${MCTP_SERVICE} ${MCTP_OBJ_PATH} ${MCTP_IFACE} ${SEND_METHOD} yayq ${eid} 3 0 129 2 ${MCTP_CTRL_TIMEOUT}"
        log_info "Running: ${CMD}"

        RESPONSE=$(run_on_bmc "${CMD}" 2>&1) || true
        echo "  Response: ${RESPONSE}"

        # Parse response: expected format "ay N 0 1 2 0 {EID} 0 0"
        # The response completion code is at position after the length.
        # Byte layout (0-indexed after "ay N"):
        #   [0]=msg type, [1]=instance/flags, [2]=cmd code, [3]=completion code,
        #   [4]=EID, [5]=EID type, [6]=medium specific info
        if [[ "${RESPONSE}" =~ ^ay\ ([0-9]+)\ (.+)$ ]]; then
            resp_len="${BASH_REMATCH[1]}"
            resp_bytes="${BASH_REMATCH[2]}"

            # Convert to array
            IFS=' ' read -ra BYTES <<< "${resp_bytes}"

            if [ "${#BYTES[@]}" -ge 5 ]; then
                completion_code="${BYTES[3]}"
                returned_eid="${BYTES[4]}"

                if [ "${completion_code}" -eq 0 ]; then
                    log_pass "EID ${eid}: Get Endpoint ID succeeded (completion_code=0, returned_EID=${returned_eid})"
                    if [ "${returned_eid}" -eq "${eid}" ]; then
                        log_pass "EID ${eid}: Returned EID matches requested EID"
                    else
                        log_warn "EID ${eid}: Returned EID (${returned_eid}) does not match requested EID (${eid})"
                    fi
                else
                    log_fail "EID ${eid}: Get Endpoint ID failed (completion_code=${completion_code})"
                fi
            else
                log_fail "EID ${eid}: Response too short (got ${#BYTES[@]} bytes, expected >= 5)"
            fi
        else
            log_fail "EID ${eid}: Unexpected response format: ${RESPONSE}"
        fi
    done
}

# ── Step 4: NVMe-MI Health Status Poll ──────────────────────────────────────

query_nvme_mi_health() {
    log_header "STEP 4: NVMe-MI DEVICE HEALTH STATUS (NVMe-MI Health Status Poll)"

    if [ ${#NVME_EIDS[@]} -eq 0 ]; then
        log_warn "No NVMe-MI capable endpoints found, skipping health status check"
        return
    fi

    # NVMe-MI Health Status Poll command (per NVMe-MI spec):
    # Message type 4 (NVMe-MI), OpCode 0x08 (Health Status Poll)
    # Payload: 0x84 0x08 0x00 0x00 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00
    #          0x00 0x00 0x00 0x00 0xD2 0xD4 0x77 0x36
    #
    # Breakdown:
    #   0x84 = NVMe-MI message header (msg type 4 with IC bit)
    #   0x08 = OpCode: Health Status Poll
    #   Remaining bytes: command-specific fields per NVMe-MI spec
    #   Last 4 bytes (0xD2 0xD4 0x77 0x36): Message Integrity Check (CRC)

    for eid in "${NVME_EIDS[@]}"; do
        log_subheader "NVMe-MI Health Status Poll for EID ${eid}"

        CMD="busctl call ${MCTP_SERVICE} ${MCTP_OBJ_PATH} ${MCTP_IFACE} ${SEND_METHOD} yayq ${eid} 20 0x84 0x08 0x00 0x00 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0xD2 0xD4 0x77 0x36 ${NVME_MI_TIMEOUT}"
        log_info "Running: ${CMD}"

        RESPONSE=$(run_on_bmc "${CMD}" 2>&1) || true
        echo "  Response: ${RESPONSE}"

        if [[ "${RESPONSE}" =~ ^ay\ ([0-9]+)\ (.+)$ ]]; then
            resp_len="${BASH_REMATCH[1]}"
            resp_bytes="${BASH_REMATCH[2]}"

            IFS=' ' read -ra BYTES <<< "${resp_bytes}"

            if [ "${#BYTES[@]}" -ge 8 ]; then
                # NVMe-MI response header:
                # [0] = Message header (0x84 echo)
                # [1] = OpCode echo (0x08 = 136 decimal)
                # [2-3] = Reserved / Status
                # Remaining bytes contain health data per NVMe-MI spec:
                #   Composite Temperature, PDLU, Spare, CWarning, CTEMP, etc.

                mi_header="${BYTES[0]}"
                mi_opcode="${BYTES[1]}"
                mi_status="${BYTES[2]}"

                log_info "Response length: ${resp_len} bytes"
                log_info "MI Header: ${mi_header}, OpCode: ${mi_opcode}, Status: ${mi_status}"

                if [ "${mi_status}" -eq 0 ]; then
                    log_pass "EID ${eid}: NVMe-MI Health Status Poll succeeded (status=0)"

                    # Parse health data fields (NVMe-MI spec section 6.2)
                    if [ "${#BYTES[@]}" -ge 20 ]; then
                        # Composite Temperature (bytes 8-9, little-endian Kelvin)
                        comp_temp_raw="${BYTES[8]}"
                        if [ "${#BYTES[@]}" -ge 10 ]; then
                            comp_temp_high="${BYTES[9]}"
                            comp_temp_k=$(( (comp_temp_high << 8) | comp_temp_raw ))
                            comp_temp_c=$(( comp_temp_k - 273 ))
                            log_info "Composite Temperature: ${comp_temp_c}°C (${comp_temp_k}K)"
                        fi

                        # Percentage Drive Life Used (byte 10)
                        if [ "${#BYTES[@]}" -ge 11 ]; then
                            pdlu="${BYTES[10]}"
                            log_info "Percentage Drive Life Used (PDLU): ${pdlu}%"
                        fi

                        # Available Spare (byte 11)
                        if [ "${#BYTES[@]}" -ge 12 ]; then
                            spare="${BYTES[11]}"
                            log_info "Available Spare: ${spare}%"
                        fi

                        # Critical Warning (byte 12)
                        if [ "${#BYTES[@]}" -ge 13 ]; then
                            cwarning="${BYTES[12]}"
                            log_info "Critical Warning: ${cwarning}"
                            if [ "${cwarning}" -ne 0 ]; then
                                log_warn "EID ${eid}: Critical Warning is non-zero (${cwarning})!"
                            fi
                        fi
                    fi
                else
                    log_fail "EID ${eid}: NVMe-MI Health Status Poll failed (status=${mi_status})"
                fi
            else
                log_fail "EID ${eid}: Response too short (got ${#BYTES[@]} bytes)"
            fi
        else
            log_fail "EID ${eid}: Unexpected response format: ${RESPONSE}"
        fi
    done
}

# ── Step 5: Check journalctl for MCTP Errors ────────────────────────────────

check_mctp_errors() {
    log_header "STEP 5: CHECK JOURNALCTL FOR MCTP ERRORS"

    log_info "Checking journalctl for MCTP-related errors..."

    # Search for MCTP errors in journal (last 500 lines or recent entries)
    JOURNAL_OUTPUT=$(run_on_bmc "journalctl -u '*mctp*' --no-pager -p err -n 100 2>&1") || true

    if [ -z "${JOURNAL_OUTPUT}" ] || echo "${JOURNAL_OUTPUT}" | grep -qE "^$|No entries|-- No entries --"; then
        log_pass "No MCTP errors found in journalctl"
    else
        log_warn "MCTP errors found in journalctl:"
        echo "${JOURNAL_OUTPUT}" | head -50
        echo ""
        line_count=$(echo "${JOURNAL_OUTPUT}" | wc -l)
        if [ "${line_count}" -gt 50 ]; then
            log_info "(Showing first 50 of ${line_count} lines)"
        fi
    fi

    # Also search for general MCTP keyword errors
    log_info "Checking for MCTP keyword in recent error logs..."
    JOURNAL_MCTP=$(run_on_bmc "journalctl --no-pager -p err -n 500 2>&1 | grep -i mctp" 2>/dev/null) || true

    if [ -z "${JOURNAL_MCTP}" ]; then
        log_pass "No MCTP-related errors in recent journal entries"
    else
        log_warn "MCTP-related error entries found:"
        echo "${JOURNAL_MCTP}" | head -30
        echo ""
    fi
}

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    log_header "TEST SUMMARY"

    echo ""
    printf "  %-25s %s\n" "BMC IP:" "${BMC_IP}"
    printf "  %-25s %s\n" "Total EIDs Discovered:" "${#EIDS[@]}"
    printf "  %-25s %s\n" "MCTP Control Endpoints:" "${#MCTP_EIDS[@]} (${MCTP_EIDS[*]:-none})"
    printf "  %-25s %s\n" "NVMe-MI Endpoints:" "${#NVME_EIDS[@]} (${NVME_EIDS[*]:-none})"
    printf "  %-25s %s\n" "PLDM Endpoints:" "${#PLDM_EIDS[@]} (${PLDM_EIDS[*]:-none})"
    printf "  %-25s %s\n" "Skipped (BMC/OOBMSM):" "${#NON_MCTP_EIDS[@]} (${NON_MCTP_EIDS[*]:-none})"
    echo ""
    echo -e "  ${BOLD}Test Results:${NC}"
    echo -e "    Total Tests: ${TOTAL_TESTS}"
    echo -e "    ${GREEN}Passed: ${PASSED_TESTS}${NC}"
    echo -e "    ${RED}Failed: ${FAILED_TESTS}${NC}"
    echo -e "    ${YELLOW}Warnings: ${WARNINGS}${NC}"
    echo ""

    if [ "${FAILED_TESTS}" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}OVERALL RESULT: ALL TESTS PASSED${NC}"
    else
        echo -e "  ${RED}${BOLD}OVERALL RESULT: ${FAILED_TESTS} TEST(S) FAILED${NC}"
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║          MCTP NVMe-MI Automated Test Suite                   ║"
    echo "║          BMC: ${BMC_IP}                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"

    check_prerequisites
    discover_endpoints
    classify_endpoints
    validate_mctp_communication
    query_nvme_mi_health
    check_mctp_errors
    print_summary

    echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # Exit with failure if any tests failed
    [ "${FAILED_TESTS}" -eq 0 ]
}

main "$@"
