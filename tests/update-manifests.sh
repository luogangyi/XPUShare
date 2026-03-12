#!/bin/bash

# Define default repositories matching the Makefile.
REGISTRY="${XP_REGISTRY:-registry.cn-hangzhou.aliyuncs.com/xpushare}"
LIB_REPOSITORY="${XP_LIB_REPOSITORY:-$REGISTRY/xpushare-lib}"
SCHEDULER_REPOSITORY="${XP_SCHEDULER_REPOSITORY:-$REGISTRY/xpushare-scheduler}"
DEVICE_PLUGIN_REPOSITORY="${XP_DEVICE_PLUGIN_REPOSITORY:-$REGISTRY/xpushare-device-plugin}"

# Get current git commit hash (short)
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed."
    exit 1
fi

XPUSHARE_COMMIT=$(git rev-parse HEAD)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get git commit hash."
    exit 1
fi
XPUSHARE_TAG="${XPUSHARE_TAG_OVERRIDE:-$(echo "$XPUSHARE_COMMIT" | cut -c 1-8)}"

# Construct image tags (repository already indicates component)
SCHEDULER_TAG="$XPUSHARE_TAG"
DEVICE_PLUGIN_TAG="$XPUSHARE_TAG"
LIBXPUSHARE_TAG="$XPUSHARE_TAG"

# Construct full image URLs
SCHEDULER_IMAGE="$SCHEDULER_REPOSITORY:$SCHEDULER_TAG"
DEVICE_PLUGIN_IMAGE="$DEVICE_PLUGIN_REPOSITORY:$DEVICE_PLUGIN_TAG"
LIBXPUSHARE_IMAGE="$LIB_REPOSITORY:$LIBXPUSHARE_TAG"

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
    # The scheduler yaml has image: docker.io/grgalex/xpushare:xpushare-scheduler-v0.1-8c2f5b90
    # We will look for the line containing "xpushare-scheduler" in the image field.
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|image: .*xpushare-scheduler.*|image: $SCHEDULER_IMAGE|g" "$SCHEDULER_YAML"
    else
        sed -i "s|image: .*xpushare-scheduler.*|image: $SCHEDULER_IMAGE|g" "$SCHEDULER_YAML"
    fi
else
    echo "Warning: $SCHEDULER_YAML not found."
fi

# Update device-plugin.yaml
if [ -f "$DEVICE_PLUGIN_YAML" ]; then
    echo "Updating $DEVICE_PLUGIN_YAML..."
    
    # Update xpushare-lib container image
    echo "  Updating xpushare-lib image to: $LIBXPUSHARE_IMAGE"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|image: .*libxpushare.*|image: $LIBXPUSHARE_IMAGE|g" "$DEVICE_PLUGIN_YAML"
    else
        sed -i "s|image: .*libxpushare.*|image: $LIBXPUSHARE_IMAGE|g" "$DEVICE_PLUGIN_YAML"
    fi
    
    # Update xpushare-device-plugin container image
    echo "  Updating xpushare-device-plugin image to: $DEVICE_PLUGIN_IMAGE"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|image: .*xpushare-device-plugin.*|image: $DEVICE_PLUGIN_IMAGE|g" "$DEVICE_PLUGIN_YAML"
    else
        sed -i "s|image: .*xpushare-device-plugin.*|image: $DEVICE_PLUGIN_IMAGE|g" "$DEVICE_PLUGIN_YAML"
    fi
else
    echo "Warning: $DEVICE_PLUGIN_YAML not found."
fi

echo "Manifests updated successfully."
echo "  Scheduler image: $SCHEDULER_IMAGE"
echo "  Device-plugin image: $DEVICE_PLUGIN_IMAGE"
echo "  Lib image: $LIBXPUSHARE_IMAGE"
