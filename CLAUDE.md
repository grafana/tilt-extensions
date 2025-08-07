# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Grafana internal Tilt extensions for development and testing. These extensions are either private to Grafana or in development before being submitted to the upstream tilt-dev/tilt-extensions repository.

## Architecture

The repository contains two main Tilt extensions:

1. **grafana/** - A wrapper over the Grafana Helm chart for multi-plugin development
2. **var_subst/** - A utility for variable substitution in templates

### Grafana Extension

The `grafana` extension is designed for multi-plugin development scenarios:

- **Main function**: `grafana()` in `grafana/Tiltfile:69`
- **Purpose**: Deploys one or more Grafana plugins using the Helm chart
- **Key components**:
  - `load_plugins()` - Loads plugin configurations from plugin.json files
  - `grafana_dockerfile_contents()` - Generates Dockerfile with plugin COPY statements
  - `live_updates()` - Configures live file syncing for development

The extension supports two directory structures:
1. Single plugin development with Tiltfile at plugin root
2. Parent project managing multiple plugins from separate repositories

### Variable Substitution Extension

The `var_subst` extension provides a simple variable substitution function:

- **Main function**: `var_subst()` in `var_subst/Tiltfile:1`
- **Purpose**: Replaces `${VAR}` and `${VAR:-default}` patterns in templates
- **Usage**: Supports environment variable lookup with optional default values

## Common Commands

### Testing

- **Grafana extension**: `cd grafana/test && bash test.sh`
- **var_subst extension**: `cd var_subst && make test`

Both extensions use `tilt ci` for running tests in their respective test directories.

### Development

- Extensions are loaded using Tilt's `load()` function
- The grafana extension expects to be loaded from a Tiltfile in a parent directory
- Plugin configurations are read from `plugin.json` files

## Key Files

- `grafana/Tiltfile` - Main Grafana extension implementation
- `grafana/grafana-values.yaml` - Default Helm chart values
- `var_subst/Tiltfile` - Variable substitution utility
- `grafana/test/parent/Tiltfile` - Test configuration for multi-plugin scenarios
- `var_subst/test/Tiltfile` - Test suite for variable substitution

## Development Notes

- The grafana extension builds custom Docker images with plugins copied into `/var/lib/grafana/plugins/`
- Live updates sync plugin dist directories for rapid development
- The extension automatically configures Grafana provisioning for each plugin
- Tests use `tilt ci` which requires at least one resource to avoid exit code 1