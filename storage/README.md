# storage

Storage repository for GNR-D.

## MCTP NVMe-MI Automated Test Suite

Automated tests for NVMe Management Interface (NVMe-MI) over MCTP on OpenBMC platforms.

### Test Scripts

| Script | Description |
|--------|-------------|
| `mctp_nvme_mi_test.sh` | Basic test suite — endpoint discovery, classification, Get Endpoint ID, Health Status Poll |
| `mctp_nvme_mi_test_v2.sh` | Extended test suite — adds NVMe-MI spec-based tests (subsystem info, port info, controller info, controller health, config get) and NVMe Admin command passthrough for power management |
| `mctp_nvme_mi_redfish_test.sh` | Standalone TC_003 — checks NVMe-MI capability of MCTP endpoints via BMC Redfish API |

### Prerequisites

#### Hardware & BIOS Setup (all test cases)

1. Connect HSBP with NVMe-MI capable drives (HSBP can be connected to any PCIe port or all PCIe ports)
2. Enable the following BIOS settings for all ports wherever HSBP is connected:
   ```
   EDKII Menu -> Socket Configuration -> IIO config -> Socket Configuration -> PCI Express 1 -> Bifurcation <x4x4x4x4>
   ```

#### Software

- **sshpass** — for non-interactive SSH to the BMC
- **python3** — for CRC-32C computation (v2 only)
- Network access to the BMC

Install on CentOS/RHEL:
```bash
dnf install -y sshpass python3
```

Install on Debian/Ubuntu:
```bash
apt-get install -y sshpass python3
```

### Running the Tests

Run all test cases with default BMC settings (`10.49.83.11` / `root` / `0penBmc1`):
```bash
bash mctp_nvme_mi_test_v2.sh
```

Run a specific test case by ID:
```bash
bash mctp_nvme_mi_test_v2.sh TC_001
```

List all registered test cases:
```bash
bash mctp_nvme_mi_test_v2.sh --list
```

Override BMC connection parameters via environment variables:
```bash
BMC_IP=10.49.83.50 BMC_USER=root BMC_PASS=mypassword bash mctp_nvme_mi_test_v2.sh
```

### Test Cases

| TC ID | Description | HSD IDs |
|-------|-------------|---------|
| TC_001 | MCTP NVMe-MI Discovery, Health & Telemetry | 16029342694, 16029342717 |
| TC_002 | MCTP NVMe-MI Under FIO Stress | 16029342728 |
| TC_003 | Check drive is NVMe-MI capable over Redfish | 16029831611 |

To add a new test case, define a function (e.g., `tc_002`) and register it:
```bash
tc_002() {
    # your test steps here
}
register_test_case "TC_002" "tc_002" "Description" "HSD_ID_1, HSD_ID_2"
```

### Test Phases (TC_001)

| Phase | Test | MCTP/NVMe-MI Command |
|-------|------|----------------------|
| 1.1 | Discover MCTP Endpoints | `busctl tree` |
| 1.2 | Classify Endpoints (MCTP Control, NVMe-MI, PLDM) | `busctl introspect` |
| 1.2b | Verify NVMe-MI Endpoint Presence | Fails if no NVMe-MI drives found |
| 1.3 | MCTP Get Endpoint ID | Cmd 0x02 |
| 1.4 | MCTP Get Message Type Support | Cmd 0x05 |
| 1.5 | MCTP Get Version Support | Cmd 0x04 |
| 2.1 | Read NVM Subsystem Information | OpCode 0x00, DSType 0x00 |
| 2.2 | Read Port Information | OpCode 0x00, DSType 0x01 |
| 2.3 | Read Controller Information | OpCode 0x00, DSType 0x02 |
| 2.4 | NVM Subsystem Health Status Poll | OpCode 0x01 |
| 2.5 | Controller Health Status Poll | OpCode 0x06 |
| 2.6 | Configuration Get — MCTP MTU Size | OpCode 0x04, CfgID 0x03 |
| 2.7 | Configuration Get — Health Status Change | OpCode 0x04, CfgID 0x02 |
| 2.8 | Get Features — Power Management (current PS) | Admin opcode 0x0A, FID 0x02 |
| 2.9 | Get Features — APST (auto power transitions) | Admin opcode 0x0A, FID 0x0C |
| 2.10 | Get Features — Temperature Threshold | Admin opcode 0x0A, FID 0x04 |
| 2.11 | Get Features — Number of Queues (admin path) | Admin opcode 0x0A, FID 0x07 |
| 3 | Check journalctl for MCTP errors | `journalctl` |

> **Note:** Phases 2.8–2.11 use NVMe Admin commands tunneled through NVMe-MI (MT=0). These require
> the BMC's MCTP stack to support admin command passthrough. If unsupported (e.g., the BMC returns
> I/O errors for MT=0 messages), phases 2.8–2.11 are automatically **skipped** with a warning.
> Power management status (Shutdown Status / SHST) is also reported via Phase 2.4's CCS flags as a fallback.

### Test Phases (TC_003)

| Phase | Test | Method |
|-------|------|--------|
| 1 | Redfish Authentication | POST `/redfish/v1/SessionService/Sessions` |
| 2 | Enumerate MCTP PCIe Endpoints | GET `/redfish/v1/Managers/bmc/MctpService/MCTP_PCIe` |
| 3 | Check NVMe-MI Capability per Endpoint | GET per-EID URI, check `SupportedMessageTypes.NVMeMgmtMsg` |
| 4 | NVMe-MI Capability Summary | FAIL if no NVMe-MI drives found |

> TC_003 can be run standalone via `mctp_nvme_mi_redfish_test.sh` or as part of the v2 suite.
> The Redfish user defaults to `debuguser` — use `--bmc-rf-user` / `--bmc-rf-pass` to override.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BMC_IP` | `10.49.83.11` | BMC IP address |
| `BMC_USER` | `root` | BMC SSH username |
| `BMC_PASS` | `0penBmc1` | BMC SSH password |
| `FIO_RUNTIME` | `300` | FIO stress duration in seconds (TC_002) |
| `FIO_BS` | `128k` | FIO block size (TC_002) |
| `FIO_IODEPTH` | `32` | FIO I/O queue depth (TC_002) |
| `FIO_RW` | `randrw` | FIO I/O pattern (TC_002) |
| `FIO_MIXREAD` | `70` | FIO read percentage for mixed workloads (TC_002) |
| `BMC_RF_USER` | `debuguser` | BMC Redfish username (TC_003) |
| `BMC_RF_PASS` | `0penBmc1` | BMC Redfish password (TC_003) |

### Output

The scripts print color-coded results (`[PASS]`, `[FAIL]`, `[WARN]`) and a final summary with total/passed/failed/warning counts. Exit code is `0` if all tests pass, non-zero otherwise.
