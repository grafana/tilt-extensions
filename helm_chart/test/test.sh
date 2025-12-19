#!/bin/bash
set -e

echo "Testing helm_chart extension..."
cd "$(dirname "$0")"
tilt ci

