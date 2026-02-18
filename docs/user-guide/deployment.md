# nvshare Deployment Guide

This guide covers the installation, configuration, and usage of `nvshare` for both local systems and Kubernetes environments.

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

#### For compatibility reasons, it is better if you [build `nvshare` from source](#build-for-local-use) for your system before installing.

1. (Optional) Download the latest release tarball from the `Releases` tab or through the command-line:

      ```bash
      wget https://github.com/grgalex/nvshare/releases/download/v0.1.0/nvshare-v0.1.0.tar.gz -O nvshare.tar.gz
      ```

2. Extract the tarball:

      ```bash
      tar -xzvf nvshare.tar.gz
      ```

3. Install `libnvshare.so` and update the dynamic linker's cache:

      ```bash
      sudo mv libnvshare.so /usr/local/lib/libnvshare.so && \
      sudo ldconfig /usr/local/lib
      ```

4. Install `nvshare-scheduler`:

      > `nvshare` uses UNIX sockets for communication and stores them under `/var/run/nvshare`, so it must run as **root**.

      ```bash
      sudo mv nvshare-scheduler /usr/local/sbin/nvshare-scheduler
      ```

5. Install `nvsharectl`:

      ```bash
      sudo mv nvsharectl /usr/local/bin/nvsharectl
      ```

6. Remove the tarball:

      ```bash
      rm nvshare.tar.gz
      ```

### Usage (Local)

1. Start the `nvshare-scheduler`:

      > It must run as `root`, so we must use `sudo`.

      The `nvshare-scheduler` executable will:
      - Create the `/var/run/nvshare` directory
      - Create the `/var/run/nvshare/scheduler.sock` UNIX socket
      - Listen for requests from `nvshare` clients.
      - **Automatically detect all available NVIDIA GPUs** and manage them independently.

      **Option A**: Start `nvshare-scheduler` with **normal logging**:

      ```bash
      sudo bash -c 'nvshare-scheduler'
      ```


      **Option B**: Start `nvshare-scheduler` with **debug logging**:

      ```bash
      sudo bash -c 'NVSHARE_DEBUG=1 nvshare-scheduler'
      ```

2. Launch your application with `LD_PRELOAD`:

      > We inject our custom `nvshare` logic into CUDA applications using `LD_PRELOAD`. `libnvshare` automatically detects if it's running in a CUDA application and only then communicates with `nvshare-scheduler`.

      **Option A**: Export the `LD_PRELOAD` variable:

      ```bash
      export LD_PRELOAD=libnvshare.so
      ```

      You can then launch your CUDA application as you normally would.

      **Option B**: Set the `LD_PRELOAD` environment variable for a single program:

      Prepend the `LD_PRELOAD` directive and launch your program as you normally would.

      ```bash
      LD_PRELOAD=libnvshare.so <YOUR_PROGRAM> <YOUR_ARGUMENTS>
      ```

      **Option C**: Add an entry for `libnvshare.so` in `/etc/ld.so.preload`:

      > In some cases, for example when using a Jupyter Notebook Server, it may be hard to set environment variables for Notebooks that it spawns after it is stated. You can opt to use the `ld.so.preload` file in those cases.

      ```bash
      sudo bash -c 'echo -ne "\n/usr/local/lib/libnvshare.so" >> /etc/ld.so.preload'
      ```

3. (Optional) Use `nvsharectl` to configure `nvshare-scheduler`:

      By default, `nvshare-scheduler` is on. This means that during TQ seconds, only one process runs computation on the GPU **if thrashing is detected or forced**.

      ```bash
      usage: nvsharectl [options]

      A command line utility to configure the nvshare scheduler.

      -T, --set-tq=n               Set the time quantum of the scheduler to TQ seconds. Only accepts positive integers.
      -S, --anti-thrash=s          Set the desired status of the scheduler. Only accepts values "on" or "off".
      -h, --help                   Shows this help message
      ```

4. You can enable debug logs for any `nvshare`-enabled application by setting the `NVSHARE_DEBUG=1` environment variable.

### Test (Local)

> If you don't want to use `docker`, you can run the tests manually by cloning the repo, going to the `tests/` directory and running the Python programs by hand, using `LD_PRELOAD=libnvshare.so`.
> The default tests below use about 10 GB GPU memory each. Use these if your GPU has at least 10 GB memory.

1. Install `docker` (https://docs.docker.com/engine/install/)
2. Start the `nvshare-scheduler`, following the instructions in the [`Usage (Local)`](#usage-local) section.
3. In a Terminal window, continuously watch the GPU status:

      ```bash
      watch nvidia-smi
      ```

4. Select your test workload from the available Docker images:

      - Variants that use 10 GB GPU memory:
         - `docker.io/grgalex/nvshare:tf-matmul-v0.1-f654c296`
         - `docker.io/grgalex/nvshare:pytorch-add-v0.1-f654c296`
      - Variants that use 2 GB GPU memory:
         - `docker.io/grgalex/nvshare:tf-matmul-small-v0.1-f654c296`
         - `docker.io/grgalex/nvshare:pytorch-add-small-v0.1-f654c296`

      ```bash
      export WORKLOAD_IMAGE=docker.io/grgalex/nvshare:tf-matmul-v0.1-f654c296
      ```

4. In a new Terminal window, start a container that runs the test workload:

      ```bash
      docker run -it --gpus all \
      --entrypoint=/usr/bin/env \
      -v /usr/local/lib/libnvshare.so:/libnvshare.so \
      -v /var/run/nvshare:/var/run/nvshare \
      ${WORKLOAD_IMAGE?} \
      bash -c "LD_PRELOAD=/libnvshare.so python /tf-matmul.py"
      ```

5. Wait for the first container to start computing on the GPU, and then:

      - Look at the `nvshare-scheduler` logs, watch the magic happen.
      - Look at the `nvidia-smi` output, interpet the memory usage according to https://forums.developer.nvidia.com/t/unified-memory-nvidia-smi-memory-usage-interpretation/177372.

5. In another Terminal window, start another container from the same image you picked in step (4):

      ```bash
      export WORKLOAD_IMAGE=docker.io/grgalex/nvshare:tf-matmul-v0.1-f654c296
      ```

      ```bash
      docker run -it --gpus all \
      --entrypoint=/usr/bin/env \
      -v /usr/local/lib/libnvshare.so:/libnvshare.so \
      -v /var/run/nvshare:/var/run/nvshare \
      ${WORKLOAD_IMAGE?} \
      bash -c "LD_PRELOAD=/libnvshare.so python /tf-matmul.py"
      ```

## Deploy on Kubernetes

### Installation (Kubernetes)

#### Requirements:
- NVIDIA's device plugin (https://github.com/NVIDIA/k8s-device-plugin)

Deploy the `nvshare` Kubernetes components:
1. `nvshare-system` namespace
2. `nvshare-system` ResourceQuotas
3. `nvshare-device-plugin` DaemonSet
4. `nvshare-scheduler` DaemonSet

      ```bash
      kubectl apply -f https://raw.githubusercontent.com/grgalex/nvshare/main/kubernetes/manifests/nvshare-system.yaml && \
      kubectl apply -f https://raw.githubusercontent.com/grgalex/nvshare/main/kubernetes/manifests/nvshare-system-quotas.yaml && \
      kubectl apply -f https://raw.githubusercontent.com/grgalex/nvshare/main/kubernetes/manifests/device-plugin.yaml && \
      kubectl apply -f https://raw.githubusercontent.com/grgalex/nvshare/main/kubernetes/manifests/scheduler.yaml
      ```

The Device Plugin runs on every GPU-enabled node in your Kubernetes cluster (currently it will fail on non-GPU nodes but that is OK) and manages a single GPU on every node. It consumes a single `nvidia.com/gpu` device and advertizes it as multiple (by default 10) `nvshare.com/gpu` devices. This means that up to 10 containers can concurrently run on the same physical GPU.

### Usage (Kubernetes)

#### Use an `nvshare.com/gpu` Device in Your Container

In order to use an `nvshare` virtual GPU, you need to request an 'nvshare.com/gpu' device in the `limits` section of the `resources` of your container.

> Practically, you can replace `nvidia.com/gpu` with `nvshare.com/gpu` in your container specs.

> You can optionally enable debug logs for any `nvshare`-enabled application by setting the `NVSHARE_DEBUG: "1"` environment variable. You can do this by following the instructions at https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/.

To do this, add the following lines to the container’s spec:

```yaml
resources:
  limits:
    nvshare.com/gpu: 1
```

#### Configure GPU Core/Memory Limits by Annotation

You can set per-Pod GPU limits directly using annotations:

```yaml
metadata:
  annotations:
    nvshare.com/gpu-core-limit: "60"     # 1-100, default 100
    nvshare.com/gpu-memory-limit: "4096" # MB, optional
```

- `nvshare.com/gpu-core-limit` controls compute share in percent.
- `nvshare.com/gpu-memory-limit` controls maximum GPU memory (MB).
- Both can be updated dynamically with `kubectl annotate` for running Pods.

Example:

```bash
kubectl annotate pod <pod-name> -n <namespace> nvshare.com/gpu-core-limit="50" --overwrite
```

#### (Optional) Configure an `nvshare-scheduler` instance using `nvsharectl`
> As the scheduler is a `DaemonSet`, there is one instance of `nvshare-scheduler` per node.

1. Store the Pod name of the instance you want to change in a variable:
      > You can use `kubectl get pods -n nvshare-system` to find the name.

      ```bash
      NVSHARE_SCHEDULER_POD_NAME=<pod-name>
      ```

2. Execute into the container and use `nvsharectl` to reconfigure the scheduler:

      ```bash
      kubectl exec -ti ${NVSHARE_SCHEDULER_POD_NAME?} -n nvshare-system -- nvsharectl ...
      ```

### Test (Kubernetes)

1. Deploy the test workloads:

      > The default tests below use about 10 GB GPU memory each. Use these if your GPU has at least 10 GB memory. Alternatively, you can pick any in the `tests/manifests` directory. The `*-small` variants use less GPU memory. You can either clone the repo or copy the link to the raw file and pass it to `kubectl`.

      ```bash
      kubectl apply -f https://raw.githubusercontent.com/grgalex/nvshare/main/tests/kubernetes/manifests/nvshare-tf-pod-1.yaml && \
      kubectl apply -f https://raw.githubusercontent.com/grgalex/nvshare/main/tests/kubernetes/manifests/nvshare-tf-pod-2.yaml
      ```

2. In a terminal window, watch the logs of the first Pod:

      ```bash
      kubectl logs nvshare-tf-matmul-1 -f
      ```

3. In another window, watch the logs of the second Pod:

      ```bash
      kubectl logs nvshare-tf-matmul-2 -f
      ```

4. (Optional) Find the node that the Pods are running on, watch the `nvshare-scheduler` logs from that node

5. Delete the test workloads:

      ```bash
      kubectl delete -f https://raw.githubusercontent.com/grgalex/nvshare/main/tests/kubernetes/manifests/nvshare-tf-pod-1.yaml && \
      kubectl delete -f https://raw.githubusercontent.com/grgalex/nvshare/main/tests/kubernetes/manifests/nvshare-tf-pod-2.yaml
      ```

### Uninstall (Kubernetes)

Delete all `nvshare` components from your cluster:

```bash
kubectl delete -f https://raw.githubusercontent.com/grgalex/nvshare/main/kubernetes/manifests/scheduler.yaml
kubectl delete -f https://raw.githubusercontent.com/grgalex/nvshare/main/kubernetes/manifests/device-plugin.yaml && \
kubectl delete -f https://raw.githubusercontent.com/grgalex/nvshare/main/kubernetes/manifests/nvshare-system-quotas.yaml && \
kubectl delete -f https://raw.githubusercontent.com/grgalex/nvshare/main/kubernetes/manifests/nvshare-system.yaml && \
```

## Monitoring & Metrics

`nvshare-scheduler` includes a built-in Prometheus exporter that exposes GPU utilization, memory usage, and internal scheduler state.

### Enabling Metrics

Metrics are controlled by the `NVSHARE_METRICS_ENABLE` environment variable. By default, it is disabled (`0`). Set it to `1` to enable the HTTP server on port `9402`.

In Kubernetes, ensure your `scheduler.yaml` has the environment variable set and the port exposed:

```yaml
env:
  - name: NVSHARE_METRICS_ENABLE
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
kubectl port-forward -n nvshare-system ds/nvshare-scheduler 9402:9402
curl http://localhost:9402/metrics
```

**Key Metrics:**
- `nvshare_gpu_utilization_ratio`: GPU compute utilization (0.0-1.0)
- `nvshare_gpu_memory_used_bytes`: GPU memory usage
- `nvshare_client_info`: Registered clients metadata (including Host PID)
- `nvshare_client_managed_allocated_bytes`: Memory allocated by clients via `nvshare`
- `nvshare_scheduler_running_clients`: Number of clients currently executing on GPU

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
      git clone https://github.com/grgalex/nvshare.git
      ```

3. Enter the source code directory and build `nvshare`:

      ```bash
      cd nvshare/src/ && make
      ```

4. Use the built `nvshare-XXXX.tar.gz` to [deploy `nvshare` locally](#deploy-on-a-local-system), starting from Step (2), using the new tarball name.

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
      git clone https://github.com/grgalex/nvshare.git
      ```

3. Enter the source code directory:

      ```bash
      cd nvshare/
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
| `NVSHARE_DEBUG` | `libnvshare`, `scheduler` | Set to `1` to enable debug logging. | `0` |
| `NVSHARE_ENABLE_SINGLE_OVERSUB` | `libnvshare` | Set to `1` to allow a single process to allocate more than physical GPU memory (not recommended). | `0` |
| `NVSHARE_COMPUTE_WINDOW_MS` | `scheduler` | Compute quota accounting window size (ms). | `2000` |
| `NVSHARE_QUOTA_SAMPLE_INTERVAL_MS` | `scheduler` | Quota enforcement sampling interval (ms). | `50` |
| `NVSHARE_QUOTA_CARRYOVER_PERCENT` | `scheduler` | Over-limit carryover ratio across windows. | `25` |
| `NVSHARE_DROP_TAIL_BILLING_PERCENT` | `scheduler` | Billing ratio for DROP->RELEASE tail section. | `70` |
| `NVSHARE_METRICS_ENABLE` | `scheduler` | Set to `1` to enable Prometheus metrics exporter on port 9402. | `0` |

Notes:
- Current recommended tuning for quota fairness tests:
  - `NVSHARE_COMPUTE_WINDOW_MS=4000`
  - `NVSHARE_QUOTA_SAMPLE_INTERVAL_MS=20`
  - `NVSHARE_QUOTA_CARRYOVER_PERCENT=0`
  - `NVSHARE_DROP_TAIL_BILLING_PERCENT=70`
- `NVSHARE_DROP_LEAD_MS` was tested and rolled back in this stage due to throughput regression; do not enable it in current recommended deployment.

### `nvsharectl` usage

The `nvsharectl` tool is used to interact with a running scheduler instance.

```bash
# Check current status
nvsharectl

# Set Time Quantum (TQ) in seconds
nvsharectl -T 45

# Enable/Disable Anti-Thrashing Mode
# "on" = scheduler will serialize execution when needed
# "off" = scheduler will allow all processes to submit usage concurrently (may cause thrashing)
nvsharectl -S on
```
