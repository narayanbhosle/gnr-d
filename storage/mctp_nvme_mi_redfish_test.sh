#!/bin/bash
###############################################################################
# TC_003: Storage_Check drive is NVMe-MI capable over Redfish
#
# HSD: 16029831611
#
# This test validates NVMe-MI capability of MCTP endpoints by querying the
# BMC's Redfish MCTP service. For each endpoint discovered via the
# MCTP_PCIe collection, it checks the SupportedMessageTypes.NVMeMgmtMsg
# property to determine NVMe Management Interface support.
#
# PASS criteria:
#   - At least one endpoint reports NVMeMgmtMsg: true
#   - Each endpoint's Redfish data is retrievable
#
# FAIL criteria:
#   - No endpoints found with NVMe-MI support
#   - Redfish API unreachable or authentication failure
###############################################################################

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
BMC_IP="${BMC_IP:-10.49.83.11}"
BMC_USER="${BMC_USER:-root}"
BMC_PASS="${BMC_PASS:-0penBmc1}"
BMC_RF_USER="${BMC_RF_USER:-debuguser}"
BMC_RF_PASS="${BMC_RF_PASS:-0penBmc1}"

REDFISH_BASE="https://${BMC_IP}"
MCTP_COLLECTION="/redfish/v1/Managers/bmc/MctpService/MCTP_PCIe"

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

# Redfish session token
RF_TOKEN=""

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

# ── Redfish Helpers ──────────────────────────────────────────────────────────

redfish_create_session() {
    local resp
    resp=$(curl -sk --noproxy '*' -X POST \
        -H "Content-Type: application/json" \
        -d "{\"UserName\":\"${BMC_RF_USER}\",\"Password\":\"${BMC_RF_PASS}\"}" \
        -D - -o /dev/null \
        "${REDFISH_BASE}/redfish/v1/SessionService/Sessions" 2>/dev/null)

    RF_TOKEN=$(echo "${resp}" | grep -i 'X-Auth-Token' | awk '{print $2}' | tr -d '\r\n')

    if [[ -z "${RF_TOKEN}" ]]; then
        return 1
    fi
    return 0
}

redfish_get() {
    local path="$1"
    curl -sk --noproxy '*' \
        -H "X-Auth-Token: ${RF_TOKEN}" \
        "${REDFISH_BASE}${path}" 2>/dev/null
}

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prerequisites() {
    log_header "Checking Prerequisites"

    if ! command -v curl &>/dev/null; then
        log_fail "curl not found — required for Redfish API access"
        echo "Install with: dnf install -y curl"
        exit 1
    fi
    log_pass "curl is available"

    if ! command -v python3 &>/dev/null; then
        log_fail "python3 not found — required for JSON parsing"
        echo "Install with: dnf install -y python3"
        exit 1
    fi
    log_pass "python3 is available"
}

# ── TC_003 ───────────────────────────────────────────────────────────────────

tc_003() {
    # Phase 1: Authenticate to Redfish
    log_header "Phase 1: Redfish Authentication"

    log_info "Creating Redfish session to ${BMC_IP} as ${BMC_RF_USER}"
    if ! redfish_create_session; then
        log_fail "Redfish authentication failed (user: ${BMC_RF_USER})"
        log_info "Check BMC_RF_USER and BMC_RF_PASS or --bmc-rf-user / --bmc-rf-pass"
        return
    fi
    log_pass "Redfish session established"

    # Phase 2: Enumerate MCTP PCIe endpoints
    log_header "Phase 2: Enumerate MCTP PCIe Endpoints"

    local collection_json
    collection_json=$(redfish_get "${MCTP_COLLECTION}")

    if [[ -z "${collection_json}" ]]; then
        log_fail "Failed to retrieve MCTP PCIe collection from ${MCTP_COLLECTION}"
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
        log_fail "No MCTP PCIe endpoints found in Redfish collection"
        return
    fi
    log_pass "Found ${member_count} MCTP PCIe endpoint(s) in Redfish"

    # Extract member URIs
    local member_uris
    member_uris=$(echo "${collection_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('Members', []):
    print(m.get('@odata.id', ''))
")

    # Phase 3: Check NVMe-MI capability for each endpoint
    log_header "Phase 3: Check NVMe-MI Capability per Endpoint"

    local nvme_mi_count=0
    local non_mi_count=0
    local eid

    while IFS= read -r uri; do
        [[ -z "${uri}" ]] && continue
        eid=$(basename "${uri}")

        log_subheader "EID ${eid}"

        local eid_json
        eid_json=$(redfish_get "${uri}")

        if [[ -z "${eid_json}" ]]; then
            log_fail "EID ${eid}: Failed to retrieve endpoint data"
            continue
        fi

        # Parse supported message types
        local msg_types
        msg_types=$(echo "${eid_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
smt = data.get('SupportedMessageTypes', {})
for k, v in sorted(smt.items()):
    print(f'{k}={v}')
")

        local nvme_mi_capable
        nvme_mi_capable=$(echo "${eid_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
smt = data.get('SupportedMessageTypes', {})
print('true' if smt.get('NVMeMgmtMsg', False) else 'false')
")

        # Get device address info if available
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

        local uuid
        uuid=$(echo "${eid_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('UUID', 'N/A'))
" 2>/dev/null || echo "N/A")

        log_info "EID ${eid}: PCIe ${dev_addr} | UUID: ${uuid}"

        # Show all supported message types
        local supported_list=""
        while IFS= read -r line; do
            local key val
            key="${line%%=*}"
            val="${line##*=}"
            if [[ "${val}" == "True" ]]; then
                supported_list="${supported_list}${supported_list:+, }${key}"
            fi
        done <<< "${msg_types}"
        log_info "EID ${eid}: Supported types: ${supported_list:-none}"

        if [[ "${nvme_mi_capable}" == "true" ]]; then
            log_pass "EID ${eid}: NVMe-MI capable (NVMeMgmtMsg=true)"
            nvme_mi_count=$((nvme_mi_count + 1))
        else
            log_info "EID ${eid}: Not NVMe-MI capable (NVMeMgmtMsg=false)"
            non_mi_count=$((non_mi_count + 1))
        fi
    done <<< "${member_uris}"

    # Phase 4: Final verdict
    log_header "Phase 4: NVMe-MI Capability Summary"

    log_info "Total MCTP endpoints:     ${member_count}"
    log_info "NVMe-MI capable:          ${nvme_mi_count}"
    log_info "Not NVMe-MI capable:      ${non_mi_count}"

    if [[ "${nvme_mi_count}" -gt 0 ]]; then
        log_pass "Found ${nvme_mi_count} NVMe-MI capable drive(s) over Redfish"
    else
        log_fail "No NVMe-MI capable drives found — all ${member_count} endpoints lack NVMeMgmtMsg support"
    fi
}

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    echo -e "\n${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                      TEST SUMMARY                           ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    printf "║  TC_003  %-10s  %3d total  %3d pass  %3d fail            ║\n" \
        "$( [[ ${FAILED_TESTS} -eq 0 ]] && echo "PASS" || echo "FAIL" )" \
        "${TOTAL_TESTS}" "${PASSED_TESTS}" "${FAILED_TESTS}"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    printf "║  Total: %-3d  Passed: %-3d  Failed: %-3d  Warnings: %-3d      ║\n" \
        "${TOTAL_TESTS}" "${PASSED_TESTS}" "${FAILED_TESTS}" "${WARNINGS}"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [ "${FAILED_TESTS}" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}Overall: ALL TESTS PASSED${NC}"
    else
        echo -e "  ${RED}${BOLD}Overall: SOME TESTS FAILED${NC}"
    fi
}

# ── CLI ──────────────────────────────────────────────────────────────────────

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "TC_003: Check drive is NVMe-MI capable over Redfish (HSD 16029831611)"
    echo ""
    echo "Options:"
    echo "  --bmc-ip IP           BMC IP address (default: ${BMC_IP})"
    echo "  --bmc-user USER       BMC SSH username (default: ${BMC_USER})"
    echo "  --bmc-pass PASS       BMC SSH password (default: ****)"
    echo "  --bmc-rf-user USER    BMC Redfish username (default: ${BMC_RF_USER})"
    echo "  --bmc-rf-pass PASS    BMC Redfish password (default: ****)"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  BMC_IP        BMC IP address"
    echo "  BMC_USER      BMC SSH username"
    echo "  BMC_PASS      BMC SSH/Redfish password"
    echo "  BMC_RF_USER   BMC Redfish username (if different from SSH user)"
    echo "  BMC_RF_PASS   BMC Redfish password (if different from SSH password)"
}

main() {
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --bmc-ip)
                [ $# -ge 2 ] || { echo "Error: --bmc-ip requires a value"; exit 1; }
                BMC_IP="$2"; shift
                REDFISH_BASE="https://${BMC_IP}"
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
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "Error: Unknown argument '$1'"
                show_usage
                exit 1
                ;;
        esac
        shift
    done

    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  TC_003: Check drive is NVMe-MI capable over Redfish         ║"
    echo "║  HSD: 16029831611                                            ║"
    echo "║  BMC: ${BMC_IP}                                        ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"

    # Pre-flight
    check_prerequisites

    # Run TC_003
    tc_003

    # Summary
    print_summary

    echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    [ "${FAILED_TESTS}" -eq 0 ]
}

main "$@"
