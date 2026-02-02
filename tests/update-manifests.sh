#!/bin/bash

# Define variables matching the Makefile
IMAGE="nvshare"
DOCKERHUB="registry.cn-hangzhou.aliyuncs.com/lgytest1"

# Get current git commit hash (short)
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed."
    exit 1
fi

NVSHARE_COMMIT=$(git rev-parse HEAD)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get git commit hash."
    exit 1
fi
NVSHARE_TAG=$(echo $NVSHARE_COMMIT | cut -c 1-8)

# Construct image tags
SCHEDULER_TAG="nvshare-scheduler-$NVSHARE_TAG"
DEVICE_PLUGIN_TAG="nvshare-device-plugin-$NVSHARE_TAG"
LIBNVSHARE_TAG="libnvshare-$NVSHARE_TAG"

# Construct full image URLs
SCHEDULER_IMAGE="$DOCKERHUB/$IMAGE:$SCHEDULER_TAG"
DEVICE_PLUGIN_IMAGE="$DOCKERHUB/$IMAGE:$DEVICE_PLUGIN_TAG"
LIBNVSHARE_IMAGE="$DOCKERHUB/$IMAGE:$LIBNVSHARE_TAG"

# Paths to manifest files
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
SCHEDULER_YAML="$MANIFESTS_DIR/scheduler.yaml"
DEVICE_PLUGIN_YAML="$MANIFESTS_DIR/device-plugin.yaml"

# Update scheduler.yaml
if [ -f "$SCHEDULER_YAML" ]; then
    echo "Updating $SCHEDULER_YAML with image: $SCHEDULER_IMAGE"
    # Use sed to replace the image line. 
    # Assumes the structure: image: <something>
    # targeting the specific container image if possible, but simple replacement for unique image names works too.
    # The scheduler yaml has image: docker.io/grgalex/nvshare:nvshare-scheduler-v0.1-8c2f5b90
    # We will look for the line containing "nvshare-scheduler" in the image field.
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|image: .*nvshare-scheduler.*|image: $SCHEDULER_IMAGE|g" "$SCHEDULER_YAML"
    else
        sed -i "s|image: .*nvshare-scheduler.*|image: $SCHEDULER_IMAGE|g" "$SCHEDULER_YAML"
    fi
else
    echo "Warning: $SCHEDULER_YAML not found."
fi

# Update device-plugin.yaml
if [ -f "$DEVICE_PLUGIN_YAML" ]; then
    echo "Updating $DEVICE_PLUGIN_YAML..."
    
    # Update nvshare-lib container image
    echo "  Updating nvshare-lib image to: $LIBNVSHARE_IMAGE"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|image: .*libnvshare.*|image: $LIBNVSHARE_IMAGE|g" "$DEVICE_PLUGIN_YAML"
    else
        sed -i "s|image: .*libnvshare.*|image: $LIBNVSHARE_IMAGE|g" "$DEVICE_PLUGIN_YAML"
    fi
    
    # Update nvshare-device-plugin container image
    echo "  Updating nvshare-device-plugin image to: $DEVICE_PLUGIN_IMAGE"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|image: .*nvshare-device-plugin.*|image: $DEVICE_PLUGIN_IMAGE|g" "$DEVICE_PLUGIN_YAML"
    else
        sed -i "s|image: .*nvshare-device-plugin.*|image: $DEVICE_PLUGIN_IMAGE|g" "$DEVICE_PLUGIN_YAML"
    fi
else
    echo "Warning: $DEVICE_PLUGIN_YAML not found."
fi

echo "Manifests updated successfully."
