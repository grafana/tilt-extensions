#!/usr/bin/env bash
set -Eeou pipefail

echo "Starting post build"

if [ "$#" -ne 2 ]; then
		echo "Usage: post_build.sh <resource> <target_resource>"
		exit 1
fi

RESOURCE=$1
TARGET_RESOURCE=$2

while :
do
    # timeout -1s means a week
    tilt wait --timeout=-1s --for=condition=UpToDate=true uiresource/${RESOURCE}

    echo "Build UpToDate! Running post_build command"

    tilt trigger ${TARGET_RESOURCE} 

    tilt wait --timeout=-1s --for=condition=UpToDate=false uiresource/${RESOURCE}
    echo "Build not UpToDate..."
done
