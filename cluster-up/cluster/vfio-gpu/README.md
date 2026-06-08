# DRA vfio-gpu for KubeVirt e2e

Provides fake `vfio-pci` devices for KubeVirt DRA e2e tests on the
containerized `k8s-*` providers. The setup uses synthetic PCI devices from the
`fake-iommu` and `fake-pci` kernel modules, but builds and loads those modules
inside the virtualized worker nodes instead of on the host.

> Inspired by the approach explored in
> [kubevirt/kubevirt#16712](https://github.com/kubevirt/kubevirt/pull/16712)
> (synthetic kernel devices for GPU e2e testing without real hardware).

> The host still needs to be able to run kubevirtci `k8s-*` providers with KVM,
> but the fake VFIO kernel modules are loaded in the provider VMs.

## Contents

| File / dir | Purpose |
| ---------- | ------- |
| `fake-iommu/` | Kernel module that exposes fake IOMMU groups |
| `fake-pci/` | Kernel module that publishes synthetic PCI devices on bus `faca` |
| `vfio-node/setup_node_vfio.sh` | Script copied into each worker node to build/load fake modules and bind devices to `vfio-pci` |
| `setup-fake-pci-host.sh` | Shared helper used inside the worker node to load/unload modules and bind devices |
| `config_vfio_cluster.sh` | Post-create cluster setup: fake VFIO modules, node labels, DRA driver install |
| `install_dra_example_driver.sh` | Builds, pushes, and installs the DRA example driver |
| `../k8s-*/config_vfio_cluster.sh` | Provider wrapper gated by `KUBEVIRT_USE_FAKE_VFIO=true` |

## Prerequisites

Host tools: `docker` or `podman`, `kubectl`, `helm`, `git`, `make`, and a
kubevirtci `k8s-*` provider that can run nested virtualization.

Worker node packages: `make`, `gcc`, `elfutils-libelf-devel`, and kernel
headers for the running worker-node kernel. The VFIO setup installs these with
`dnf` or `apt-get` when `FAKE_VFIO_INSTALL_DEPS=true`.

## Cluster setup


```bash
export KUBEVIRT_PROVIDER=k8s-1.36
export KUBEVIRT_USE_FAKE_VFIO=true
export FAKE_PCI_DEVICES=8
export FAKE_IOMMU=true

make cluster-up
```

`make cluster-up` creates the `k8s-*` provider and, when
`KUBEVIRT_USE_FAKE_VFIO=true`, runs the provider's `config_vfio_cluster.sh`
wrapper. That wrapper delegates to this directory and configures each worker
node by:

- copying the fake VFIO sources to `/tmp/fake-vfio`;
- building and loading `fake-iommu.ko` and `fake-pci.ko` inside the worker;
- binding fake PCI devices to `vfio-pci`;
- labeling nodes with `fake-vfio-capable=true`;
- building, pushing, and installing the DRA example driver.

CPU Manager must be enabled for the KubeVirt e2e setup. The `k8s-*` worker
bootstrap configures static CPU Manager policy for supported architectures.

To rerun only the VFIO/DRA setup against an existing cluster:

```bash
bash cluster-up/cluster/k8s-1.36/config_vfio_cluster.sh
```

## KubeVirt sync

```bash
export KUBEVIRT_PROVIDER=k8s-1.36
export FEATURE_GATES=CPUManager,GPUsWithDRA,HostDevicesWithDRA,HostDevices

make cluster-sync
```

If the KubeVirt CR already exists, patch the feature gates:

```bash
kubectl -n kubevirt patch kubevirt kubevirt --type=merge -p '{"spec":{"configuration":{"developerConfiguration":{"featureGates":["GPUsWithDRA","HostDevicesWithDRA","HostDevices"]}}}}'
```

## Run DRA e2e

Once the driver is installed and KubeVirt is synced with DRA feature gates:

```bash
export KUBEVIRT_PROVIDER=k8s-1.36
export FEATURE_GATES=CPUManager,GPUsWithDRA,HostDevicesWithDRA,HostDevices
export KUBEVIRT_E2E_FOCUS='\[sig-compute\]DRA'
make ginkgo
```

## Tear down

```bash
export KUBEVIRT_PROVIDER=k8s-1.36
make cluster-down
```

This deletes the provider VMs. The fake modules are loaded only inside the
worker nodes, so no host module cleanup is required.

## Configuration

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `KUBEVIRT_USE_FAKE_VFIO` | `false` | Enables fake VFIO setup during `make cluster-up` for supported `k8s-*` providers |
| `FAKE_PCI_DEVICES` | `8` | Number of synthetic PCI devices to create inside each worker node |
| `FAKE_IOMMU` | `true` | Load the fake IOMMU companion so fake devices can bind to `vfio-pci` |
| `FAKE_VFIO_INSTALL_DEPS` | `true` | Install worker-node build dependencies before compiling fake modules |
| `DRA_DRIVER_PROFILE` | `vfio-gpu` | DRA example driver profile installed by Helm |
| `DRA_DRIVER_NAME` | `vfio-gpu.example.com` | DRA driver name exposed to KubeVirt |
| `DRA_DRIVER_IMAGE_NAME` | `dra-example-driver` | Image name used for the locally built DRA driver |
| `FEATURE_GATES` | (none) | Set to `CPUManager,GPUsWithDRA,HostDevicesWithDRA,HostDevices` before `cluster-sync` |
