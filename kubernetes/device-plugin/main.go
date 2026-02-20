/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.  All rights reserved.
 * Copyright (c) 2023, Georgios Alexopoulos
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package main

import (
	"log"
	"os"
	"strconv"
	"syscall"

	"strings"

	"github.com/fsnotify/fsnotify"
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
)

const (
	LibNvshareHostPath           = "/var/run/nvshare/libnvshare.so"
	LibNvshareContainerPath      = "/usr/lib/libnvshare.so"
	SocketHostPath               = "/var/run/nvshare/scheduler.sock"
	SocketContainerPath          = "/var/run/nvshare/scheduler.sock"
	AscendDriverHostPath         = "/usr/local/Ascend/driver"
	AscendDriverContainerPath    = "/usr/local/Ascend/driver"
	AscendInstallInfoHostPath    = "/etc/ascend_install.info"
	AscendInstallInfoTargetPath  = "/etc/ascend_install.info"
	NvshareVirtualDevicesEnvVar  = "NVSHARE_VIRTUAL_DEVICES"
	NvidiaDevicesEnvVar          = "NVIDIA_VISIBLE_DEVICES"
	NvidiaExposeMountDir         = "/var/run/nvidia-container-devices"
	NvidiaExposeMountHostPath    = "/dev/null"
	AscendVisibleDevicesEnvVar   = "ASCEND_VISIBLE_DEVICES"
	AscendRTVisibleDevicesEnvVar = "ASCEND_RT_VISIBLE_DEVICES"
	NPUVisibleDevicesEnvVar      = "NPU_VISIBLE_DEVICES"
)

var UUIDs []string
var NvshareVirtualDevices int
var nvidiaRuntimeUseMounts bool
var runtimeBackend string

func splitVisibleDevices(value string) []string {
	var out []string
	for _, token := range strings.Split(value, ",") {
		t := strings.TrimSpace(token)
		if t == "" {
			continue
		}
		out = append(out, t)
	}
	return out
}

func detectVisibleDevicesEnv() (string, string, bool) {
	ascendCandidates := []string{
		AscendRTVisibleDevicesEnvVar,
		AscendVisibleDevicesEnvVar,
		NPUVisibleDevicesEnvVar,
	}
	for _, key := range ascendCandidates {
		if value, ok := os.LookupEnv(key); ok && strings.TrimSpace(value) != "" {
			return value, key, true
		}
	}

	value, ok := os.LookupEnv(NvidiaDevicesEnvVar)
	if !ok || strings.TrimSpace(value) == "" {
		return "", "", false
	}
	return value, NvidiaDevicesEnvVar, true
}

func main() {
	var exists bool
	var NumVirtualDevicesEnv string
	var err error
	var devicePlugin *NvshareDevicePlugin
	var visibleDevicesEnv string

	log.SetOutput(os.Stderr)
	log.Printf("Nvshare Device Plugin starting... (Build: DynamicLimit/v1)")

	/*
	 * Read the underlying GPU UUID from the NVIDIA_VISIBLE_DEVICES environment
	 * variable. Nvshare device plugin's Pod requests 1 `nvidia.com/gpu` in order
	 * to isolate it from the rest of the cluster and manage it, exposing it
	 * as multiple `nvshare.com/gpu` devices.
	 *
	 * Pods (soon to be Nvshare clients) that request an Nvshare GPU device still
	 * need to have access to the real GPU. As such, we must set the same env
	 * variable `NVIDIA_VISIBLE_DEVICES` in the containers of the Pods that
	 * request Nvshare GPUs to the same UUID as NVIDIA's device plugin set it for
	 * us here.
	 */
	/*
	 * The container runtime reads the value of this env variable and exposes
	 * the GPU device into a container.
	 */
	nvidiaRuntimeUseMounts = false
	runtimeBackend = "cuda"
	uuidStr, visibleDevicesEnv, exists := detectVisibleDevicesEnv()
	if exists == false {
		log.Printf("none of %s/%s/%s/%s is set, exiting",
			AscendRTVisibleDevicesEnvVar, AscendVisibleDevicesEnvVar,
			NPUVisibleDevicesEnvVar, NvidiaDevicesEnvVar)
		os.Exit(1)
	}

	/*
	 * Find out how many virtual GPUs we must advertize
	 */
	NumVirtualDevicesEnv, exists = os.LookupEnv(NvshareVirtualDevicesEnvVar)
	if exists == false {
		log.Printf("%s is not set, exiting", NvshareVirtualDevicesEnvVar)
		os.Exit(1)
	}
	NvshareVirtualDevices, err = strconv.Atoi(NumVirtualDevicesEnv)
	if err != nil {
		log.Printf("Failed to parse nvshare devices per GPU")
		log.Fatal(err)
	}
	if NvshareVirtualDevices <= 0 {
		log.Printf("Parsed nvshare virtual devices per GPU is not a positive integer, exiting")
		os.Exit(1)
	}

	/*
	 * Device expose mode is through Volume Mounts, NVIDIA_VISIBLE_DEVICES
	 * has a symbolic value of "/var/run/nvidia-container-devices" and
	 * UUIDs are passed through volume mounts in that directory
	 */
	if visibleDevicesEnv != NvidiaDevicesEnvVar {
		runtimeBackend = "ascend"
		UUIDs = splitVisibleDevices(uuidStr)
		log.Printf("Detected Ascend runtime from %s=%s", visibleDevicesEnv, uuidStr)
	} else {
		if uuidStr == NvidiaExposeMountDir {
			log.Printf("Device Exposure method of NVIDIA device plugin is Volume Mounts, following the same strategy for Nvshare device plugin")
			f, err := os.Open(NvidiaExposeMountDir)
			if err != nil {
				log.Printf("Failed to open %s", NvidiaExposeMountDir)
				log.Fatal(err)
			}
			// Read all filenames in the directory
			nvFiles, err := f.Readdirnames(0)
			if err != nil {
				log.Printf("Error when reading UUIDs from %s directory:%s", NvidiaExposeMountDir, err)
				log.Fatal(err)
			}
			UUIDs = nvFiles
			nvidiaRuntimeUseMounts = true
		} else {
			UUIDs = splitVisibleDevices(uuidStr)
		}
	}

	if len(UUIDs) == 0 {
		log.Printf("No UUIDs found in %s", uuidStr)
		os.Exit(1)
	}

	log.Printf("Runtime backend=%s, Read UUIDs=%v", runtimeBackend, UUIDs)

	log.Println("Starting FS watcher.")
	watcher, err := newFSWatcher(pluginapi.DevicePluginPath)
	if err != nil {
		log.Fatal("Failed to create FS watcher:", err)
	}
	defer watcher.Close()

	log.Println("Starting OS watcher.")
	sigs := newOSWatcher(syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT)

restart:
	/* If we are restarting, stop any running plugin before recreating it */
	devicePlugin.Stop()

	devicePlugin = NewNvshareDevicePlugin()

	pluginStartError := make(chan struct{})

	/*
	 * Start the gRPC server for the device plugin and connect it with
	 * the kubelet.
	 */
	err = devicePlugin.Start()
	if err != nil {
		log.Println("devicePlugin.Start() FAILED. Could not contact Kubelet, retrying. Did you enable the device plugin feature gate?")
		close(pluginStartError)
		goto events
	}

events:
	for {
		select {
		case <-pluginStartError:
			goto restart

		case event := <-watcher.Events:
			if (event.Name == pluginapi.KubeletSocket) && (event.Op&fsnotify.Create == fsnotify.Create) {
				log.Printf("inotify: %s created, restarting", pluginapi.KubeletSocket)
				goto restart
			}

		case err := <-watcher.Errors:
			log.Printf("inotify: %s", err)

		case s := <-sigs:
			switch s {
			case syscall.SIGHUP:
				log.Println("Received SIGHUP, restarting.")
				goto restart
			default:
				log.Printf("Received signal \"%v\", shutting down.", s)
				devicePlugin.Stop()
				break events
			}
		}
	}
	return
}
