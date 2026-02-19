# Copyright (c) 2023 Georgios Alexopoulos
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# We abuse the image/tag semantics.
# We use a single image name: "nvshare" and incorporate the component name
# into the tag.

# You can change IMAGE to point to your own Repository.
IMAGE := nvshare
DOCKERHUB := registry.cn-hangzhou.aliyuncs.com/lgytest1
NVSHARE_COMMIT := $(shell git rev-parse HEAD)
NVSHARE_TAG := $(shell echo $(NVSHARE_COMMIT) | cut -c 1-8)
PLATFORMS ?= linux/amd64,linux/arm64
GO_BUILDER_IMAGE ?= docker.io/library/golang:1.15.15

UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),x86_64)
LOCAL_ARCH := amd64
else ifeq ($(UNAME_M),aarch64)
LOCAL_ARCH := arm64
else ifeq ($(UNAME_M),arm64)
LOCAL_ARCH := arm64
else
LOCAL_ARCH := amd64
endif
LOCAL_PLATFORM ?= linux/$(LOCAL_ARCH)

LIBNVSHARE_TAG := libnvshare-$(NVSHARE_TAG)
SCHEDULER_TAG := nvshare-scheduler-$(NVSHARE_TAG)
DEVICE_PLUGIN_TAG := nvshare-device-plugin-$(NVSHARE_TAG)
BASE_TAG := baseubuntu
BASE_IMAGE_LOCAL := nvshare:$(BASE_TAG)
BASE_IMAGE_REMOTE := $(DOCKERHUB)/$(IMAGE):$(BASE_TAG)

all: build push

build: build-base build-libnvshare build-scheduler build-device-plugin

# reduce base image build time
build-base:
	docker build -f Dockerfile.baseubuntu -t nvshare:baseubuntu .

build-libnvshare:
	docker build -f Dockerfile.libnvshare -t $(IMAGE):$(LIBNVSHARE_TAG) .

build-scheduler:
	docker build -f Dockerfile.scheduler -t $(IMAGE):$(SCHEDULER_TAG) .

build-device-plugin:
	docker build -f Dockerfile.device_plugin --build-arg BASE_IMAGE=$(BASE_IMAGE_LOCAL) --build-arg GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE) -t $(IMAGE):$(DEVICE_PLUGIN_TAG) .

# Build multi-arch images and load local platform images into Docker Engine.
buildx-load: buildx-load-base buildx-load-libnvshare buildx-load-scheduler buildx-load-device-plugin

buildx-load-base:
	docker buildx build --platform $(LOCAL_PLATFORM) -f Dockerfile.baseubuntu -t $(BASE_IMAGE_LOCAL) --load .

buildx-load-libnvshare: buildx-load-base
	docker buildx build --platform $(LOCAL_PLATFORM) -f Dockerfile.libnvshare --build-arg BASE_IMAGE=$(BASE_IMAGE_LOCAL) -t $(IMAGE):$(LIBNVSHARE_TAG) --load .

buildx-load-scheduler: buildx-load-base
	docker buildx build --platform $(LOCAL_PLATFORM) -f Dockerfile.scheduler --build-arg BASE_IMAGE=$(BASE_IMAGE_LOCAL) -t $(IMAGE):$(SCHEDULER_TAG) --load .

buildx-load-device-plugin:
	docker buildx build --platform $(LOCAL_PLATFORM) -f Dockerfile.device_plugin --build-arg BASE_IMAGE=$(BASE_IMAGE_LOCAL) --build-arg GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE) -t $(IMAGE):$(DEVICE_PLUGIN_TAG) --load .

# Build and push multi-arch images to registry.
buildx-push: buildx-push-base buildx-push-libnvshare buildx-push-scheduler buildx-push-device-plugin

buildx-push-base:
	docker buildx build --platform $(PLATFORMS) -f Dockerfile.baseubuntu -t $(BASE_IMAGE_REMOTE) --push .

buildx-push-libnvshare: buildx-push-base
	docker buildx build --platform $(PLATFORMS) -f Dockerfile.libnvshare --build-arg BASE_IMAGE=$(BASE_IMAGE_REMOTE) -t $(DOCKERHUB)/$(IMAGE):$(LIBNVSHARE_TAG) --push .

buildx-push-scheduler: buildx-push-base
	docker buildx build --platform $(PLATFORMS) -f Dockerfile.scheduler --build-arg BASE_IMAGE=$(BASE_IMAGE_REMOTE) -t $(DOCKERHUB)/$(IMAGE):$(SCHEDULER_TAG) --push .

buildx-push-device-plugin:
	docker buildx build --platform $(PLATFORMS) -f Dockerfile.device_plugin --build-arg BASE_IMAGE=$(BASE_IMAGE_REMOTE) --build-arg GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE) -t $(DOCKERHUB)/$(IMAGE):$(DEVICE_PLUGIN_TAG) --push .

push: push-libnvshare push-scheduler push-device-plugin

push-libnvshare:
	docker tag "$(IMAGE):$(LIBNVSHARE_TAG)" "$(DOCKERHUB)/$(IMAGE):$(LIBNVSHARE_TAG)"
	docker push "$(DOCKERHUB)/$(IMAGE):$(LIBNVSHARE_TAG)"

push-scheduler:
	docker tag "$(IMAGE):$(SCHEDULER_TAG)" "$(DOCKERHUB)/$(IMAGE):$(SCHEDULER_TAG)"
	docker push "$(DOCKERHUB)/$(IMAGE):$(SCHEDULER_TAG)"

push-device-plugin:
	docker tag "$(IMAGE):$(DEVICE_PLUGIN_TAG)" "$(DOCKERHUB)/$(IMAGE):$(DEVICE_PLUGIN_TAG)"
	docker push "$(DOCKERHUB)/$(IMAGE):$(DEVICE_PLUGIN_TAG)"

.PHONY: all
.PHONY: build build-libnvshare build-scheduler build-device-plugin
.PHONY: buildx-load buildx-load-base buildx-load-libnvshare buildx-load-scheduler buildx-load-device-plugin
.PHONY: buildx-push buildx-push-base buildx-push-libnvshare buildx-push-scheduler buildx-push-device-plugin
.PHONY: push push-libnvshare push-scheduler push-device-plugin
