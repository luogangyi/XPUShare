# xpushare Deployment Guide

This guide covers the installation, configuration, and usage of `xpushare` for both local systems and Kubernetes environments.

## Table of Contents
- [Deploy on a Local System](#deploy-on-a-local-system)
  - [Installation (Local)](#installation-local)
  - [Usage (Local)](#usage-local)
  - [Test (Local)](#test-local)
- [Deploy on Kubernetes](#deploy-on-kubernetes)
  - [Installation (Kubernetes)](#installation-kubernetes)
  - [Usage (Kubernetes)](#usage-kubernetes)
  - [Test (Kubernetes)](#test-kubernetes)
  - [Uninstall (Kubernetes)](#uninstall-kubernetes)
- [Build Instructions](#build-instructions)
  - [Build For Local Use](#build-for-local-use)
  - [Build Docker Images](#build-docker-images)
- [Configuration Reference](#configuration-reference)

---

## Deploy on a Local System

### Installation (Local)

#### For compatibility reasons, it is better if you [build `xpushare` from source](#build-for-local-use) for your system before installing.

1. (Optional) Download the latest release tarball from the `Releases` tab or through the command-line:

      ```bash
      wget https://github.com/grgalex/xpushare/releases/download/v0.1.0/xpushare-v0.1.0.tar.gz -O xpushare.tar.gz
      ```

2. Extract the tarball:

      ```bash
      tar -xzvf xpushare.tar.gz
      ```

3. Install `libxpushare.so` and update the dynamic linker's cache:

      ```bash
      sudo mv libxpushare.so /usr/local/lib/libxpushare.so && \
      sudo ldconfig /usr/local/lib
      ```

4. Install `xpushare-scheduler`:

      > `xpushare` uses UNIX sockets for communication and stores them under `/var/run/xpushare`, so it must run as **root**.

      ```bash
      sudo mv xpushare-scheduler /usr/local/sbin/xpushare-scheduler
      ```

5. Install `xpusharectl`:

      ```bash
      sudo mv xpusharectl /usr/local/bin/xpusharectl
      ```

6. Remove the tarball:

      ```bash
      rm xpushare.tar.gz
      ```

### Usage (Local)

1. Start the `xpushare-scheduler`:

      > It must run as `root`, so we must use `sudo`.

      The `xpushare-scheduler` executable will:
      - Create the `/var/run/xpushare` directory
      - Create the `/var/run/xpushare/scheduler.sock` UNIX socket
      - Listen for requests from `xpushare` clients.
      - **Automatically detect all available NVIDIA GPUs** and manage them independently.

      **Option A**: Start `xpushare-scheduler` with **normal logging**:

      ```bash
      sudo bash -c 'xpushare-scheduler'
      ```


      **Option B**: Start `xpushare-scheduler` with **debug logging**:

      ```bash
      sudo bash -c 'XPUSHARE_DEBUG=1 xpushare-scheduler'
      ```

2. Launch your application with `LD_PRELOAD`:

      > We inject our custom `xpushare` logic into CUDA applications using `LD_PRELOAD`. `libxpushare` automatically detects if it's running in a CUDA application and only then communicates with `xpushare-scheduler`.

      **Option A**: Export the `LD_PRELOAD` variable:

      ```bash
      export LD_PRELOAD=libxpushare.so
      ```

      You can then launch your CUDA application as you normally would.

      **Option B**: Set the `LD_PRELOAD` environment variable for a single program:

      Prepend the `LD_PRELOAD` directive and launch your program as you normally would.

      ```bash
      LD_PRELOAD=libxpushare.so <YOUR_PROGRAM> <YOUR_ARGUMENTS>
      ```

      **Option C**: Add an entry for `libxpushare.so` in `/etc/ld.so.preload`:

      > In some cases, for example when using a Jupyter Notebook Server, it may be hard to set environment variables for Notebooks that it spawns after it is stated. You can opt to use the `ld.so.preload` file in those cases.

      ```bash
      sudo bash -c 'echo -ne "\n/usr/local/lib/libxpushare.so" >> /etc/ld.so.preload'
      ```

3. (Optional) Use `xpusharectl` to configure `xpushare-scheduler`:

      By default, `xpushare-scheduler` is on. This means that during TQ seconds, only one process runs computation on the GPU **if thrashing is detected or forced**.

      ```bash
      usage: xpusharectl [options]

      A command line utility to configure the xpushare scheduler.

      -T, --set-tq=n               Set the time quantum of the scheduler to TQ seconds. Only accepts positive integers.
      -S, --anti-thrash=s          Set the desired status of the scheduler. Only accepts values "on" or "off".
      -h, --help                   Shows this help message
      ```

4. You can enable debug logs for any `xpushare`-enabled application by setting the `XPUSHARE_DEBUG=1` environment variable.

### Test (Local)

> If you don't want to use `docker`, you can run the tests manually by cloning the repo, going to the `tests/` directory and running the Python programs by hand, using `LD_PRELOAD=libxpushare.so`.
> The default tests below use about 10 GB GPU memory each. Use these if your GPU has at least 10 GB memory.

1. Install `docker` (https://docs.docker.com/engine/install/)
2. Start the `xpushare-scheduler`, following the instructions in the [`Usage (Local)`](#usage-local) section.
3. In a Terminal window, continuously watch the GPU status:

      ```bash
      watch nvidia-smi
      ```

4. Select your test workload from the available Docker images:

      - Variants that use 10 GB GPU memory:
         - `docker.io/grgalex/xpushare:tf-matmul-v0.1-f654c296`
         - `docker.io/grgalex/xpushare:pytorch-add-v0.1-f654c296`
      - Variants that use 2 GB GPU memory:
         - `docker.io/grgalex/xpushare:tf-matmul-small-v0.1-f654c296`
         - `docker.io/grgalex/xpushare:pytorch-add-small-v0.1-f654c296`

      ```bash
      export WORKLOAD_IMAGE=docker.io/grgalex/xpushare:tf-matmul-v0.1-f654c296
      ```

4. In a new Terminal window, start a container that runs the test workload:

      ```bash
      docker run -it --gpus all \
      --entrypoint=/usr/bin/env \
      -v /usr/local/lib/libxpushare.so:/libxpushare.so \
      -v /var/run/xpushare:/var/run/xpushare \
      ${WORKLOAD_IMAGE?} \
      bash -c "LD_PRELOAD=/libxpushare.so python /tf-matmul.py"
      ```

5. Wait for the first container to start computing on the GPU, and then:

      - Look at the `xpushare-scheduler` logs, watch the magic happen.
      - Look at the `nvidia-smi` output, interpet the memory usage according to https://forums.developer.nvidia.com/t/unified-memory-nvidia-smi-memory-usage-interpretation/177372.

5. In another Terminal window, start another container from the same image you picked in step (4):

      ```bash
      export WORKLOAD_IMAGE=docker.io/grgalex/xpushare:tf-matmul-v0.1-f654c296
      ```

      ```bash
      docker run -it --gpus all \
      --entrypoint=/usr/bin/env \
      -v /usr/local/lib/libxpushare.so:/libxpushare.so \
      -v /var/run/xpushare:/var/run/xpushare \
      ${WORKLOAD_IMAGE?} \
      bash -c "LD_PRELOAD=/libxpushare.so python /tf-matmul.py"
      ```

## Deploy on Kubernetes

### Installation (Kubernetes)

#### Requirements:
- NVIDIA's device plugin (https://github.com/NVIDIA/k8s-device-plugin)
- **For Ascend NPU ONLY:** You must apply the `npu_bypass.ko` kernel patch to disable CANN driver container isolation. Check [design-npu-container-isolation-bypass.md](../design/design-npu-container-isolation-bypass.md) for compiling and loading instructions. Without it, cross-Pod concurrency will fail with `drvRet=87`.

Deploy the `xpushare` Kubernetes components:
1. `xpushare-system` namespace
2. `xpushare-system` ResourceQuotas
3. `xpushare-device-plugin` DaemonSet
4. `xpushare-scheduler` DaemonSet

      ```bash
      kubectl apply -f https://raw.githubusercontent.com/grgalex/xpushare/main/kubernetes/manifests/xpushare-system.yaml && \
      kubectl apply -f https://raw.githubusercontent.com/grgalex/xpushare/main/kubernetes/manifests/xpushare-system-quotas.yaml && \
      kubectl apply -f https://raw.githubusercontent.com/grgalex/xpushare/main/kubernetes/manifests/device-plugin.yaml && \
      kubectl apply -f https://raw.githubusercontent.com/grgalex/xpushare/main/kubernetes/manifests/scheduler.yaml
      ```

The Device Plugin runs on every GPU-enabled node in your Kubernetes cluster (currently it will fail on non-GPU nodes but that is OK) and manages a single GPU on every node. It consumes a single `nvidia.com/gpu` device and advertizes it as multiple (by default 10) `xpushare.com/gpu` devices. This means that up to 10 containers can concurrently run on the same physical GPU.

### Usage (Kubernetes)

#### Use an `xpushare.com/gpu` Device in Your Container

In order to use an `xpushare` virtual GPU, you need to request an 'xpushare.com/gpu' device in the `limits` section of the `resources` of your container.

> Practically, you can replace `nvidia.com/gpu` with `xpushare.com/gpu` in your container specs.

> You can optionally enable debug logs for any `xpushare`-enabled application by setting the `XPUSHARE_DEBUG: "1"` environment variable. You can do this by following the instructions at https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/.

To do this, add the following lines to the container’s spec:

```yaml
resources:
  limits:
    xpushare.com/gpu: 1
```

#### Configure GPU Core/Memory Limits by Annotation

You can set per-Pod GPU limits directly using annotations:

```yaml
metadata:
  annotations:
    xpushare.com/gpu-core-limit: "60"     # 1-100, default 100
    xpushare.com/gpu-memory-limit: "4096" # MB, optional
```

- `xpushare.com/gpu-core-limit` controls compute share in percent.
- `xpushare.com/gpu-memory-limit` controls maximum GPU memory (MB).
- Both can be updated dynamically with `kubectl annotate` for running Pods.

Example:

```bash
kubectl annotate pod <pod-name> -n <namespace> xpushare.com/gpu-core-limit="50" --overwrite
```

#### Enable CANN Memory Oversubscription

For Ascend NPU workloads, `xpushare` supports managed-allocation based oversubscription through ACL hooks.

Recommended Pod environment settings:

```yaml
env:
  - name: XPUSHARE_ENABLE_SINGLE_OVERSUB
    value: "1"
  - name: XPUSHARE_NPU_OVERSUB_ALLOC_MODE
    value: "auto"
  - name: XPUSHARE_NPU_MANAGED_WITHCFG
    value: "0"
  - name: XPUSHARE_NPU_MANAGED_FALLBACK
    value: "1"
```

Optional (for `aclrtMallocWithCfg` managed path / prefetch tuning):

```yaml
env:
  - name: XPUSHARE_NPU_MANAGED_WITHCFG
    value: "1"
  - name: XPUSHARE_NPU_MANAGED_ALIGN32
    value: "1" # experimental: enable managed path for aclrtMallocAlign32
  - name: XPUSHARE_NPU_PREFETCH_ENABLE
    value: "1"
  - name: XPUSHARE_NPU_PREFETCH_MIN_BYTES
    value: "33554432" # 32 MiB
  - name: XPUSHARE_NPU_PREFETCH_MAX_OPS_PER_CYCLE
    value: "4"
```

Notes:
- `XPUSHARE_ENABLE_SINGLE_OVERSUB=1` is required to allow a single process to allocate beyond physical HBM.
- `XPUSHARE_NPU_OVERSUB_ALLOC_MODE=auto` is the default mode.
- NPU quota management path defaults to enabled:
  - `XPUSHARE_NPU_ENABLE_HOOK` defaults to `1`.
  - `XPUSHARE_NPU_ENABLE_CLIENT` defaults to `1`.
  - `XPUSHARE_NPU_NATIVE_QUOTA` defaults to `1`.
  - `XPUSHARE_NPU_STREAM_QUOTA` defaults to `1`.
- Recommended production profile is:
  - `XPUSHARE_NPU_OVERSUB_ALLOC_MODE=auto`
  - `XPUSHARE_NPU_MANAGED_WITHCFG=0`
  - `XPUSHARE_NPU_MANAGED_ALIGN32=0`
- Under this profile:
  - `aclrtMalloc` stays on native ACL path in non-oversub case.
  - When oversub is needed (or native alloc fails near physical boundary), `aclrtMalloc` switches to managed path.
  - `aclrtMallocWithCfg` stays on native ACL path.
  - Mixed workloads (`aclrtMalloc` + `aclrtMallocWithCfg`) are supported; `aclrtMallocWithCfg` should stay within physical HBM unless you explicitly enable withcfg managed mode.
- `XPUSHARE_NPU_MANAGED_WITHCFG=1` only applies when `aclrtMallocWithCfg(..., cfg=NULL)` is used.
- `XPUSHARE_NPU_MANAGED_ALIGN32=0` keeps `aclrtMallocAlign32` on native ACL path to avoid unstable managed oversub behavior in some high-pressure AI-core workloads.
- If `aclrtMallocWithCfg(..., cfg!=NULL)`, xpushare keeps strict behavior and does not force managed mode.
- `XPUSHARE_NPU_MANAGED_FALLBACK=1` keeps fallback to native ACL allocation when managed path/symbol is unavailable.

Quick verification:
1. Run a pod that allocates `> physical HBM` with `XPUSHARE_ENABLE_SINGLE_OVERSUB=1`.
2. Check pod logs for allocation summary (`allocated_bytes > total_mem_bytes`) and `OVERSUB_PASS`.
3. Check metrics for that pod:
   - `xpushare_client_allocated_bytes`
   - `xpushare_client_npu_managed_allocated_bytes`
   - `xpushare_client_npu_native_allocated_bytes`
   - `xpushare_client_npu_alloc_mode{mode="managed|native|mixed|unknown"}`
4. Check fallback/prefetch quality:
   - `xpushare_client_npu_managed_alloc_fallback_total{reason=...}`
   - `xpushare_client_npu_prefetch_total{result="ok|fail"}`

#### (Optional) Configure an `xpushare-scheduler` instance using `xpusharectl`
> As the scheduler is a `DaemonSet`, there is one instance of `xpushare-scheduler` per node.

1. Store the Pod name of the instance you want to change in a variable:
      > You can use `kubectl get pods -n xpushare-system` to find the name.

      ```bash
      XPUSHARE_SCHEDULER_POD_NAME=<pod-name>
      ```

2. Execute into the container and use `xpusharectl` to reconfigure the scheduler:

      ```bash
      kubectl exec -ti ${XPUSHARE_SCHEDULER_POD_NAME?} -n xpushare-system -- xpusharectl ...
      ```

### Test (Kubernetes)

1. Deploy the test workloads:

      > The default tests below use about 10 GB GPU memory each. Use these if your GPU has at least 10 GB memory. Alternatively, you can pick any in the `tests/manifests` directory. The `*-small` variants use less GPU memory. You can either clone the repo or copy the link to the raw file and pass it to `kubectl`.

      ```bash
      kubectl apply -f https://raw.githubusercontent.com/grgalex/xpushare/main/tests/kubernetes/manifests/xpushare-tf-pod-1.yaml && \
      kubectl apply -f https://raw.githubusercontent.com/grgalex/xpushare/main/tests/kubernetes/manifests/xpushare-tf-pod-2.yaml
      ```

2. In a terminal window, watch the logs of the first Pod:

      ```bash
      kubectl logs xpushare-tf-matmul-1 -f
      ```

3. In another window, watch the logs of the second Pod:

      ```bash
      kubectl logs xpushare-tf-matmul-2 -f
      ```

4. (Optional) Find the node that the Pods are running on, watch the `xpushare-scheduler` logs from that node

5. Delete the test workloads:

      ```bash
      kubectl delete -f https://raw.githubusercontent.com/grgalex/xpushare/main/tests/kubernetes/manifests/xpushare-tf-pod-1.yaml && \
      kubectl delete -f https://raw.githubusercontent.com/grgalex/xpushare/main/tests/kubernetes/manifests/xpushare-tf-pod-2.yaml
      ```

### Uninstall (Kubernetes)

Delete all `xpushare` components from your cluster:

```bash
kubectl delete -f https://raw.githubusercontent.com/grgalex/xpushare/main/kubernetes/manifests/scheduler.yaml
kubectl delete -f https://raw.githubusercontent.com/grgalex/xpushare/main/kubernetes/manifests/device-plugin.yaml && \
kubectl delete -f https://raw.githubusercontent.com/grgalex/xpushare/main/kubernetes/manifests/xpushare-system-quotas.yaml && \
kubectl delete -f https://raw.githubusercontent.com/grgalex/xpushare/main/kubernetes/manifests/xpushare-system.yaml && \
```

## Monitoring & Metrics

`xpushare-scheduler` includes a built-in Prometheus exporter that exposes GPU utilization, memory usage, and internal scheduler state.

### Enabling Metrics

Metrics are controlled by the `XPUSHARE_METRICS_ENABLE` environment variable. By default, it is disabled (`0`). Set it to `1` to enable the HTTP server on port `9402`.

In Kubernetes, ensure your `scheduler.yaml` has the environment variable set and the port exposed:

```yaml
env:
  - name: XPUSHARE_METRICS_ENABLE
    value: "1"
ports:
  - containerPort: 9402
    name: metrics
    protocol: TCP
```

### Accessing Metrics

The metrics endpoint is available at `/metrics`.

**Example (Port Forward):**
```bash
kubectl port-forward -n xpushare-system ds/xpushare-scheduler 9402:9402
curl http://localhost:9402/metrics
```

**Key Metrics:**
- `xpushare_gpu_utilization_ratio`: GPU compute utilization (0.0-1.0)
- `xpushare_gpu_memory_used_bytes`: GPU memory usage
- `xpushare_gpu_memory_total_bytes`: total device memory
- `xpushare_client_info`: Registered clients metadata (including Host PID)
- `xpushare_client_allocated_bytes`: total client allocation accounting (managed + native)
- `xpushare_client_managed_allocated_bytes`: managed allocation accounting (legacy/common view)
- `xpushare_client_npu_managed_allocated_bytes`: NPU managed allocation bytes
- `xpushare_client_npu_native_allocated_bytes`: NPU native allocation bytes
- `xpushare_client_npu_alloc_mode{mode=...}`: current NPU allocation mode by client
- `xpushare_client_npu_managed_alloc_fallback_total{reason=...}`: managed-path fallback counters
- `xpushare_client_npu_prefetch_total{result=...}`: managed prefetch success/failure counters
- `xpushare_scheduler_running_clients`: Number of clients currently executing on GPU

**PromQL examples for CANN oversub monitoring:**
```promql
# Per-pod allocation split
sum by (namespace, pod) (xpushare_client_npu_managed_allocated_bytes)
sum by (namespace, pod) (xpushare_client_npu_native_allocated_bytes)

# Total accounted allocation per pod
sum by (namespace, pod) (xpushare_client_allocated_bytes)

# Managed-path fallback and prefetch health
increase(xpushare_client_npu_managed_alloc_fallback_total[5m])
increase(xpushare_client_npu_prefetch_total{result="fail"}[5m])
```

## Build Instructions


### Build For Local Use

> These instructions assume building on a Debian-based system.

> You can use the artifacts on any machine that has `glibc` and supports the ELF binary format.

1. Install requirements:

      ```bash
      sudo apt update && \
      sudo apt install gcc make libc6-dev
      ```

2. Clone this repository:

      ```bash
      git clone https://github.com/grgalex/xpushare.git
      ```

3. Enter the source code directory and build `xpushare`:

      ```bash
      cd xpushare/src/ && make
      ```

4. Use the built `xpushare-XXXX.tar.gz` to [deploy `xpushare` locally](#deploy-on-a-local-system), starting from Step (2), using the new tarball name.

5. Delete the build artifacts:

      ```bash
      make clean
      ```

### Build Docker Images

1. Install `docker` (https://docs.docker.com/engine/install/).  
   For multi-arch builds, ensure `docker buildx` is available:

      ```bash
      docker buildx version
      ```

2. Clone this repository:

      ```bash
      git clone https://github.com/grgalex/xpushare.git
      ```

3. Enter the source code directory:

      ```bash
      cd xpushare/
      ```

4. (Optional) Edit the `Makefile`, change the Image Repository.

5. Build the core Docker images for the current host architecture:

      ```bash
      make build
      ```

6. (Optional) Build with `buildx` and load host-arch images locally (uses buildx flow but keeps local testing workflow):

      ```bash
      make buildx-load
      ```

7. (Optional) Build and push multi-arch images (`linux/amd64,linux/arm64`) for mixed x86/ARM clusters:

      ```bash
      make buildx-push
      ```

8. (Optional) Push the core single-arch Docker images, and update the Kubernetes manifests under `kubernetes/manifests` to use the new images.

      ```bash
      make push
      ```

9. Build the test workload Docker images:

      ```bash
      cd tests/ && make build
      ```

10. (Optional) Push the test workload Docker images, and update the Kubernetes manifests under `tests/kubernetes/manifests` to use the new images.

      ```bash
      make push
      ```

## Configuration Reference

### Environment Variables

| Variable | Component | Description | Default |
|----------|-----------|-------------|---------|
| `XPUSHARE_DEBUG` | `libxpushare`, `scheduler` | Set to `1` to enable debug logging. | `0` |
| `XPUSHARE_ENABLE_SINGLE_OVERSUB` | `libxpushare` | Set to `1` to allow a single process to allocate more than physical device memory (CUDA/CANN oversub path). | `0` |
| `XPUSHARE_NPU_ENABLE_HOOK` | `libxpushare` | Enable NPU ACL hook path (`1` enabled, `0` passthrough). | `1` |
| `XPUSHARE_NPU_ENABLE_CLIENT` | `libxpushare` | Enable scheduler client path for NPU hook mode (`1` enabled, `0` static native quota path). | `1` |
| `XPUSHARE_NPU_NATIVE_QUOTA` | `libxpushare` | Enable native ACL device-level compute quota control. | `1` |
| `XPUSHARE_NPU_STREAM_QUOTA` | `libxpushare` | Enable native ACL stream-level quota reinforcement. | `1` |
| `XPUSHARE_NPU_OVERSUB_ALLOC_MODE` | `libxpushare` | CANN allocation mode for oversub path (`acl`, `managed`, or `auto`). `auto` means native-first and managed-on-demand. | `auto` |
| `XPUSHARE_NPU_MANAGED_WITHCFG` | `libxpushare` | Set to `1` to enable managed path for `aclrtMallocWithCfg(..., cfg=NULL)`; keep `0` as the recommended compatibility default. | `0` |
| `XPUSHARE_NPU_MANAGED_ALIGN32` | `libxpushare` | Set to `1` to allow managed path for `aclrtMallocAlign32`; keep `0` as the default stability profile for AI-core heavy oversub stress. | `0` |
| `XPUSHARE_NPU_MANAGED_FALLBACK` | `libxpushare` | Set to `1` to fallback to native ACL alloc when managed symbol/path is unavailable. | `1` |
| `XPUSHARE_NPU_PREFETCH_ENABLE` | `libxpushare` | Set to `0` to disable managed prefetch; `1` enables prefetch attempts. | `1` |
| `XPUSHARE_NPU_PREFETCH_MIN_BYTES` | `libxpushare` | Minimum allocation size (bytes) eligible for managed prefetch. | `33554432` |
| `XPUSHARE_NPU_PREFETCH_MAX_OPS_PER_CYCLE` | `libxpushare` | Max managed prefetch operations per second cycle. | `4` |
| `XPUSHARE_COMPUTE_WINDOW_MS` | `scheduler` | Compute quota accounting window size (ms). | `2000` |
| `XPUSHARE_QUOTA_SAMPLE_INTERVAL_MS` | `scheduler` | Quota enforcement sampling interval (ms). | `50` |
| `XPUSHARE_QUOTA_CARRYOVER_PERCENT` | `scheduler` | Over-limit carryover ratio across windows. | `25` |
| `XPUSHARE_DROP_TAIL_BILLING_PERCENT` | `scheduler` | Billing ratio for DROP->RELEASE tail section. | `70` |
| `XPUSHARE_MEM_WM_HIGH_PERCENT` | `scheduler` | Memory watermark high threshold (%). When exceeded, scheduler starts memory-pressure preemption. | `95` |
| `XPUSHARE_MEM_WM_LOW_PERCENT` | `scheduler` | Memory watermark low threshold (%). When dropped below, paused tasks can resume. | `90` |
| `XPUSHARE_METRICS_ENABLE` | `scheduler` | Set to `1` to enable Prometheus metrics exporter on port 9402. | `0` |

Notes:
- Current recommended tuning for quota fairness tests:
  - `XPUSHARE_COMPUTE_WINDOW_MS=4000`
  - `XPUSHARE_QUOTA_SAMPLE_INTERVAL_MS=20`
  - `XPUSHARE_QUOTA_CARRYOVER_PERCENT=0`
  - `XPUSHARE_DROP_TAIL_BILLING_PERCENT=70`
- Memory watermark defaults (recommended for production/stability):
  - `XPUSHARE_MEM_WM_HIGH_PERCENT=95`
  - `XPUSHARE_MEM_WM_LOW_PERCENT=90`
  - Keep `HIGH > LOW` with at least a 5-point gap to avoid frequent oscillation.
- `XPUSHARE_DROP_LEAD_MS` was tested and rolled back in this stage due to throughput regression; do not enable it in current recommended deployment.

### `xpusharectl` usage

The `xpusharectl` tool is used to interact with a running scheduler instance.

```bash
# Check current status
xpusharectl

# Set Time Quantum (TQ) in seconds
xpusharectl -T 45

# Enable/Disable Anti-Thrashing Mode
# "on" = scheduler will serialize execution when needed
# "off" = scheduler will allow all processes to submit usage concurrently (may cause thrashing)
xpusharectl -S on
```
