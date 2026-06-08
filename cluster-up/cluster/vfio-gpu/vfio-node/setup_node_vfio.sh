#!/usr/bin/env bash

set -e
set -o pipefail

: "${FAKE_PCI_DEVICES:=8}"
: "${FAKE_IOMMU:=true}"
: "${FAKE_VFIO_INSTALL_DEPS:=true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    echo "[setup-node-vfio] $*"
}

fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_kernel_package_diagnostics() {
    echo "Kernel package diagnostics:" >&2
    echo "  running kernel: $(uname -r)" >&2
    echo "" >&2

    if command_exists rpm; then
        echo "Installed kernel packages:" >&2
        rpm -qa 'kernel*' | sort >&2 || true
        echo "" >&2
    fi

    if command_exists dnf; then
        echo "Enabled dnf repositories:" >&2
        dnf repolist --enabled >&2 || true
        echo "" >&2

        echo "Available kernel-devel packages:" >&2
        dnf list --showduplicates kernel-devel 2>/dev/null >&2 || true
        echo "" >&2

        echo "Available kernel packages:" >&2
        dnf list --showduplicates kernel kernel-core kernel-modules 2>/dev/null >&2 || true
        echo "" >&2
    fi
}

validate_root() {
    [ "$(id -u)" -eq 0 ] || fatal "This script must be run as root"
}

install_build_deps() {
    if [[ "${FAKE_VFIO_INSTALL_DEPS}" != "true" ]]; then
        return
    fi

    if [[ -d "/lib/modules/$(uname -r)/build" ]] && command_exists make && command_exists gcc; then
        return
    fi

    log "Installing build dependencies for kernel $(uname -r)"
    if command_exists dnf; then
        dnf install -y make gcc elfutils-libelf-devel "kernel-devel-$(uname -r)" || {
            echo "ERROR: failed to install kernel-devel for the running kernel: $(uname -r)" >&2
            print_kernel_package_diagnostics
            echo "The fake VFIO modules must be built against the running VM kernel." >&2
            echo "Install kernel-devel-$(uname -r) in the provider image or enable a repo that provides it." >&2
            exit 1
        }
    elif command_exists apt-get; then
        apt-get update
        apt-get install -y make gcc "linux-headers-$(uname -r)"
    else
        log "No supported package manager found; skipping dependency installation"
    fi
}

validate_build_deps() {
    command_exists make || fatal "make is required to build fake VFIO modules"
    command_exists gcc || fatal "gcc is required to build fake VFIO modules"
    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
        print_kernel_package_diagnostics
        fatal "kernel headers not found at /lib/modules/$(uname -r)/build; install kernel-devel-$(uname -r) inside the VM node"
    fi
}

build_modules() {
    log "Building fake-iommu and fake-pci for kernel $(uname -r)"
    make -C "${SCRIPT_DIR}/fake-iommu" clean
    make -C "${SCRIPT_DIR}/fake-pci" clean
    make -C "${SCRIPT_DIR}/fake-iommu"
    make -C "${SCRIPT_DIR}/fake-pci"
}

configure_vfio_iommu() {
    log "Enabling unsafe interrupts for vfio_iommu_type1"
    modprobe vfio_iommu_type1 allow_unsafe_interrupts=1
    local unsafe_interrupts="/sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts"
    if [[ ! -e "${unsafe_interrupts}" ]]; then
        fatal "vfio_iommu_type1 allow_unsafe_interrupts parameter not found"
    fi

    echo 1 >"${unsafe_interrupts}"
    case "$(cat "${unsafe_interrupts}")" in
    Y|y|1)
        ;;
    *)
        fatal "failed to enable vfio_iommu_type1 allow_unsafe_interrupts"
        ;;
    esac
}

load_modules() {
    log "Loading fake modules and binding fake PCI devices to vfio-pci"
    FAKE_PCI_DEVICES="${FAKE_PCI_DEVICES}" \
        FAKE_PCI_DOMAIN="${FAKE_PCI_DOMAIN:-}" \
        FAKE_PCI_VENDOR_ID="${FAKE_PCI_VENDOR_ID:-}" \
        FAKE_PCI_DEVICE_ID="${FAKE_PCI_DEVICE_ID:-}" \
        FAKE_IOMMU="${FAKE_IOMMU}" \
        bash "${SCRIPT_DIR}/setup-fake-pci-host.sh" cleanup
    FAKE_PCI_DEVICES="${FAKE_PCI_DEVICES}" \
        FAKE_PCI_DOMAIN="${FAKE_PCI_DOMAIN:-}" \
        FAKE_PCI_VENDOR_ID="${FAKE_PCI_VENDOR_ID:-}" \
        FAKE_PCI_DEVICE_ID="${FAKE_PCI_DEVICE_ID:-}" \
        FAKE_IOMMU="${FAKE_IOMMU}" \
        bash "${SCRIPT_DIR}/setup-fake-pci-host.sh" setup
    FAKE_PCI_DEVICES="${FAKE_PCI_DEVICES}" \
        FAKE_PCI_DOMAIN="${FAKE_PCI_DOMAIN:-}" \
        FAKE_PCI_VENDOR_ID="${FAKE_PCI_VENDOR_ID:-}" \
        FAKE_PCI_DEVICE_ID="${FAKE_PCI_DEVICE_ID:-}" \
        FAKE_IOMMU="${FAKE_IOMMU}" \
        bash "${SCRIPT_DIR}/setup-fake-pci-host.sh" bind-vfio
}

chmod_vfio() {
    if [[ -c /dev/vfio/vfio ]]; then
        log "chmod 666 /dev/vfio/vfio"
        chmod 666 /dev/vfio/vfio
    else
        fatal "/dev/vfio/vfio is not present after vfio-pci bind"
    fi
}

discover_devices() {
    log "vfio-pci devices visible on this node:"
    local found=0
    local d bdf v dev grp
    for d in /sys/bus/pci/drivers/vfio-pci/*; do
        [[ -e "$d" ]] || continue
        bdf=$(basename "$d")
        case "$bdf" in
            bind|unbind|new_id|remove_id|module|uevent)
                continue
                ;;
        esac
        v=$(cat "/sys/bus/pci/devices/$bdf/vendor" 2>/dev/null || echo "?")
        dev=$(cat "/sys/bus/pci/devices/$bdf/device" 2>/dev/null || echo "?")
        grp=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null)" 2>/dev/null || true)
        echo "  $bdf vendor=$v device=$dev iommu_group=${grp:-none}"
        found=$((found + 1))
    done
    if [[ $found -eq 0 ]]; then
        fatal "no devices are bound to vfio-pci"
    fi

    log "/dev/vfio entries:"
    ls -1 /dev/vfio/ 2>/dev/null | sed 's/^/  /' || true
}

main() {
    validate_root
    install_build_deps
    validate_build_deps
    build_modules
    load_modules
    chmod_vfio
    configure_vfio_iommu
    discover_devices
}

main "$@"
