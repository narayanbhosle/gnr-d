#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class FeatureStatus:
    name: str
    supported: bool
    enabled: bool
    details: list[str] = field(default_factory=list)


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="ignore").strip()
    except OSError:
        return None


def get_cpu_flags() -> set[str]:
    cpuinfo = read_text(Path("/proc/cpuinfo"))
    if not cpuinfo:
        return set()

    flags: set[str] = set()
    for line in cpuinfo.splitlines():
        if not line.startswith(("flags", "Features")):
            continue
        _, _, values = line.partition(":")
        flags.update(values.strip().split())
    return flags


def existing_paths(paths: list[str]) -> list[str]:
    return [path for path in paths if os.path.exists(path)]


def check_sgx(cpu_flags: set[str]) -> FeatureStatus:
    details: list[str] = []
    cpu_support = "sgx" in cpu_flags
    if cpu_support:
        details.append("CPU flag 'sgx' is present")
    else:
        details.append("CPU flag 'sgx' is not present")

    sgx_lc = "sgx_lc" in cpu_flags
    if sgx_lc:
        details.append("CPU flag 'sgx_lc' is present")

    sgx_devices = existing_paths(
        [
            "/dev/sgx_enclave",
            "/dev/sgx_provision",
            "/dev/sgx/enclave",
            "/dev/sgx/provision",
        ]
    )
    if sgx_devices:
        details.append("SGX device nodes found: " + ", ".join(sgx_devices))
    else:
        details.append("No SGX device nodes found")

    sgx_sysfs = existing_paths(
        [
            "/sys/kernel/x86/sgx",
            "/sys/module/intel_sgx",
            "/sys/module/sgx",
        ]
    )
    if sgx_sysfs:
        details.append("SGX kernel/sysfs paths found: " + ", ".join(sgx_sysfs))

    epc_paths = existing_paths(
        [
            "/sys/kernel/x86/sgx/total_bytes",
            "/sys/kernel/x86/sgx_nr_total_epc_sections",
        ]
    )
    for path in epc_paths:
        value = read_text(Path(path))
        if value:
            details.append(f"{path}: {value}")

    enabled = cpu_support and bool(sgx_devices or sgx_sysfs or epc_paths)
    return FeatureStatus(name="SGX", supported=cpu_support, enabled=enabled, details=details)


def check_tdx(cpu_flags: set[str]) -> FeatureStatus:
    details: list[str] = []

    tdx_cpu_flags = sorted(flag for flag in cpu_flags if flag.startswith("tdx"))
    cpu_support = bool(tdx_cpu_flags)
    if tdx_cpu_flags:
        details.append("CPU TDX-related flags present: " + ", ".join(tdx_cpu_flags))
    else:
        details.append("No TDX-related CPU flags found in /proc/cpuinfo")

    guest_paths = existing_paths(
        [
            "/sys/firmware/tdx",
            "/sys/module/tdx_guest",
            "/dev/tdx_guest",
        ]
    )
    if guest_paths:
        details.append("TDX guest paths found: " + ", ".join(guest_paths))

    kvm_tdx_param = Path("/sys/module/kvm_intel/parameters/tdx")
    kvm_tdx_value = read_text(kvm_tdx_param)
    host_enabled = False
    if kvm_tdx_value is not None:
        details.append(f"{kvm_tdx_param}: {kvm_tdx_value}")
        host_enabled = kvm_tdx_value.lower() in {"y", "1", "yes", "true"}
    else:
        details.append("KVM Intel TDX parameter not found")

    seam_paths = existing_paths(
        [
            "/sys/firmware/acpi/tables/TDVF",
            "/sys/firmware/acpi/tables/TDEL",
        ]
    )
    if seam_paths:
        details.append("TDX-related ACPI tables found: " + ", ".join(seam_paths))

    enabled = bool(guest_paths) or host_enabled or (cpu_support and bool(seam_paths))
    supported = cpu_support or host_enabled or bool(guest_paths)
    return FeatureStatus(name="TDX", supported=supported, enabled=enabled, details=details)


def print_status(status: FeatureStatus) -> None:
    state = "ENABLED" if status.enabled else "DISABLED"
    support = "supported" if status.supported else "not supported"
    print(f"{status.name}: {state} ({support})")
    for detail in status.details:
        print(f"  - {detail}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check whether Intel SGX and TDX appear to be enabled on this Linux system."
    )
    parser.add_argument(
        "--require",
        choices=["sgx", "tdx", "both"],
        help="Return exit code 1 unless the selected feature set is enabled.",
    )
    args = parser.parse_args()

    cpu_flags = get_cpu_flags()
    sgx = check_sgx(cpu_flags)
    tdx = check_tdx(cpu_flags)

    print_status(sgx)
    print()
    print_status(tdx)

    if args.require == "sgx":
        return 0 if sgx.enabled else 1
    if args.require == "tdx":
        return 0 if tdx.enabled else 1
    if args.require == "both":
        return 0 if sgx.enabled and tdx.enabled else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())