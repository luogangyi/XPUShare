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

# We keep local image naming by component tag and push to dedicated repositories:
#   - xpushare-lib
#   - xpushare-scheduler
#   - xpushare-device-plugin
IMAGE := xpushare
REGISTRY := registry.cn-hangzhou.aliyuncs.com/xpushare
LIB_REPOSITORY := $(REGISTRY)/xpushare-lib
SCHEDULER_REPOSITORY := $(REGISTRY)/xpushare-scheduler
DEVICE_PLUGIN_REPOSITORY := $(REGISTRY)/xpushare-device-plugin
# Base image is an internal build dependency. By default we keep it in scheduler repo.
BASE_REPOSITORY := $(SCHEDULER_REPOSITORY)
XPUSHARE_COMMIT := $(shell git rev-parse HEAD)
XPUSHARE_TAG := $(shell echo $(XPUSHARE_COMMIT) | cut -c 1-8)
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

LIBXPUSHARE_TAG := $(XPUSHARE_TAG)
SCHEDULER_TAG := $(XPUSHARE_TAG)
DEVICE_PLUGIN_TAG := $(XPUSHARE_TAG)
LOCAL_LIBXPUSHARE_TAG := libxpushare-$(XPUSHARE_TAG)
LOCAL_SCHEDULER_TAG := xpushare-scheduler-$(XPUSHARE_TAG)
LOCAL_DEVICE_PLUGIN_TAG := xpushare-device-plugin-$(XPUSHARE_TAG)
BASE_TAG := baseubuntu
BASE_IMAGE_LOCAL := xpushare:$(BASE_TAG)
BASE_IMAGE_REMOTE := $(BASE_REPOSITORY):$(BASE_TAG)

all: build push

build: build-base build-libxpushare build-scheduler build-device-plugin

# reduce base image build time
build-base:
	docker build -f Dockerfile.baseubuntu -t xpushare:baseubuntu .

build-libxpushare:
	docker build -f Dockerfile.libxpushare -t $(IMAGE):$(LOCAL_LIBXPUSHARE_TAG) .

build-scheduler:
	docker build -f Dockerfile.scheduler -t $(IMAGE):$(LOCAL_SCHEDULER_TAG) .

build-device-plugin:
	docker build -f Dockerfile.device_plugin --build-arg BASE_IMAGE=$(BASE_IMAGE_LOCAL) --build-arg GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE) -t $(IMAGE):$(LOCAL_DEVICE_PLUGIN_TAG) .

# Build multi-arch images and load local platform images into Docker Engine.
buildx-load: buildx-load-base buildx-load-libxpushare buildx-load-scheduler buildx-load-device-plugin

buildx-load-base:
	docker buildx build --platform $(LOCAL_PLATFORM) -f Dockerfile.baseubuntu -t $(BASE_IMAGE_LOCAL) --load .

buildx-load-libxpushare: buildx-load-base
	docker buildx build --platform $(LOCAL_PLATFORM) -f Dockerfile.libxpushare --build-arg BASE_IMAGE=$(BASE_IMAGE_LOCAL) -t $(IMAGE):$(LOCAL_LIBXPUSHARE_TAG) --load .

buildx-load-scheduler: buildx-load-base
	docker buildx build --platform $(LOCAL_PLATFORM) -f Dockerfile.scheduler --build-arg BASE_IMAGE=$(BASE_IMAGE_LOCAL) -t $(IMAGE):$(LOCAL_SCHEDULER_TAG) --load .

buildx-load-device-plugin:
	docker buildx build --platform $(LOCAL_PLATFORM) -f Dockerfile.device_plugin --build-arg BASE_IMAGE=$(BASE_IMAGE_LOCAL) --build-arg GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE) -t $(IMAGE):$(LOCAL_DEVICE_PLUGIN_TAG) --load .

# Build and push multi-arch images to registry.
buildx-push: buildx-push-base buildx-push-libxpushare buildx-push-scheduler buildx-push-device-plugin

buildx-push-base:
	docker buildx build --platform $(PLATFORMS) -f Dockerfile.baseubuntu -t $(BASE_IMAGE_REMOTE) --push .

buildx-push-libxpushare: buildx-push-base
	docker buildx build --platform $(PLATFORMS) -f Dockerfile.libxpushare --build-arg BASE_IMAGE=$(BASE_IMAGE_REMOTE) -t $(LIB_REPOSITORY):$(LIBXPUSHARE_TAG) --push .

buildx-push-scheduler: buildx-push-base
	docker buildx build --platform $(PLATFORMS) -f Dockerfile.scheduler --build-arg BASE_IMAGE=$(BASE_IMAGE_REMOTE) -t $(SCHEDULER_REPOSITORY):$(SCHEDULER_TAG) --push .

buildx-push-device-plugin:
	docker buildx build --platform $(PLATFORMS) -f Dockerfile.device_plugin --build-arg BASE_IMAGE=$(BASE_IMAGE_REMOTE) --build-arg GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE) -t $(DEVICE_PLUGIN_REPOSITORY):$(DEVICE_PLUGIN_TAG) --push .

push: push-libxpushare push-scheduler push-device-plugin

push-libxpushare:
	docker tag "$(IMAGE):$(LOCAL_LIBXPUSHARE_TAG)" "$(LIB_REPOSITORY):$(LIBXPUSHARE_TAG)"
	docker push "$(LIB_REPOSITORY):$(LIBXPUSHARE_TAG)"

push-scheduler:
	docker tag "$(IMAGE):$(LOCAL_SCHEDULER_TAG)" "$(SCHEDULER_REPOSITORY):$(SCHEDULER_TAG)"
	docker push "$(SCHEDULER_REPOSITORY):$(SCHEDULER_TAG)"

push-device-plugin:
	docker tag "$(IMAGE):$(LOCAL_DEVICE_PLUGIN_TAG)" "$(DEVICE_PLUGIN_REPOSITORY):$(DEVICE_PLUGIN_TAG)"
	docker push "$(DEVICE_PLUGIN_REPOSITORY):$(DEVICE_PLUGIN_TAG)"

.PHONY: all
.PHONY: build build-libxpushare build-scheduler build-device-plugin
.PHONY: buildx-load buildx-load-base buildx-load-libxpushare buildx-load-scheduler buildx-load-device-plugin
.PHONY: buildx-push buildx-push-base buildx-push-libxpushare buildx-push-scheduler buildx-push-device-plugin
.PHONY: push push-libxpushare push-scheduler push-device-plugin
