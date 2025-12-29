# Compose Composer

A Tilt extension for dynamically assembling Docker Compose environments from modular, reusable components.

## Overview

Compose Composer enables you to build development environments from composable pieces. Each component (k3s-apiserver, grafana, mysql, your plugins) can define:

- Its own Docker Compose services
- Dependencies on other components
- Wiring rules that activate when other components are present
- A complete dependency tree that travels with the component

**Design Principle**: Any plugin can be the orchestrator. The result is symmetric - whether you run `tilt up` from plugin-A or plugin-B, the final composed environment is consistent because wiring is defined declaratively in each component.

## Quick Start

### Basic Orchestrator

```python
# my-plugin/Tiltfile

# Load compose_composer
v1alpha1.extension_repo(name='tilt-extensions', url='file:///path/to/tilt-extensions')
v1alpha1.extension(name='compose_composer', repo_name='tilt-extensions', repo_path='compose_composer')
load('ext://compose_composer', 'cc_dependency', 'cc_local_compose', 'cc_generate_master_compose', 'cc_parse_cli_plugins')

# Allow any k8s context (we're only using docker-compose)
allow_k8s_contexts(k8s_context())

# Define dependencies using cc_dependency()
DEVENV_URL = 'file:///path/to/devenv-compose'

k3s = cc_dependency(name='k3s-apiserver', url=DEVENV_URL)
mysql = cc_dependency(name='mysql', url=DEVENV_URL)
grafana = cc_dependency(name='grafana', url=DEVENV_URL)

# Define your plugin with its compose file and dependencies
def cc_get_plugin():
    return cc_local_compose(
        'my-plugin',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        k3s, mysql, grafana,  # Dependencies as varargs
    )

# Parse CLI plugins (e.g., 'tilt up -- other-plugin')
cli_plugins = cc_parse_cli_plugins(os.path.dirname(__file__))

# Generate and run
if __file__ == config.main_path:
    master_compose = cc_generate_master_compose(
        cc_get_plugin(),                 # Your plugin with its dependencies
        cli_plugins,                  # Additional plugins from CLI
        staging_dir=os.path.dirname(__file__) + '/.compose-stage',
    )
    docker_compose(encode_yaml(master_compose))
```

### Adding CLI Plugins

```bash
# Run with additional plugins from CLI
tilt up -- plugin-two ../relative/path /absolute/path
```

### Using Profiles

Profiles let you conditionally include dependencies, similar to Docker Compose profiles.

```bash
# Activate profiles via CLI flags
tilt up -- --profile=dev --profile=debug plugin-two

# Or via environment variable
CC_PROFILES=dev,debug tilt up

# Both work together (CLI takes precedence)
CC_PROFILES=dev tilt up -- --profile=staging plugin-two
```

## Core Concepts

### The Unified Dependency Tree

Everything in compose_composer is a **plugin struct**. There are two ways to create one:

1. **Remote dependencies** via `cc_dependency()` - Loads an extension from a repo
2. **Local plugins** via `cc_local_compose()` - Defines a local plugin with its compose file

Both return structs that can be passed to `cc_generate_master_compose()`.

### The `cc_local_compose()` Function

Creates a plugin struct for your local compose file:

```python
def cc_get_plugin():
    return cc_local_compose(
        'my-plugin',                                    # Plugin name
        os.path.dirname(__file__) + '/docker-compose.yaml',  # Compose file path
        k3s, mysql, grafana,                            # Dependencies (varargs)
    )
```

### The `cc_dependency()` Function

Loads a remote extension and returns a plugin struct:

```python
k3s = cc_dependency(
    name='k3s-apiserver',           # Extension name (required)
    url='file:///path/to/repo',     # Extension repo URL (required)
    ref='main',                      # Git ref for https:// URLs (optional)
    repo_path='k3s-apiserver',       # Path within repo (default: name)
    compose_overrides={...},         # Static overrides (optional)
    imports=['register_crds'],       # Helper functions to bind (optional)
)
```

When loaded, it calls `cc_get_plugin()` from the extension to get its compose_path and nested dependencies.

### The `cc_get_plugin()` Export

Every extension should export a `cc_get_plugin()` function:

```python
# grafana/Tiltfile
load('ext://compose_composer', 'cc_local_compose')

def cc_get_plugin():
    return cc_local_compose(
        'grafana',
        os.path.dirname(__file__) + '/grafana.yaml',
    )
```

This replaces the older `get_compose_path()` and `get_dependency_graph()` exports with a single, unified interface.

The `cc_` prefix ensures there are no naming collisions with your own functions.

### Bound Helpers

When you import a helper function, it's bound to the dependency struct:

```python
k3s = cc_dependency(
    name='k3s-apiserver',
    url='...',
    imports=['register_crds'],
)

# Helper is accessed directly on the struct
crd_mod = k3s.register_crds(crd_paths=[
    os.path.dirname(__file__) + '/crds',
    os.path.dirname(__file__) + '/definitions',
])

# Pass modifications to cc_generate_master_compose
master_compose = cc_generate_master_compose(
    cc_get_plugin(),
    cli_plugins,
    modifications=[crd_mod],
)
```

The wrapper automatically adds `_target` metadata so compose_composer knows which dependency to modify.

### Wire When Rules

Extensions can declare conditional wiring that activates when other dependencies are present:

```python
# grafana/Tiltfile
def get_wire_when():
    return {
        'k3s-apiserver': {  # When k3s-apiserver is present...
            'services': {
                'grafana': {  # ...modify the grafana service:
                    'depends_on': ['k3s-apiserver'],
                    'volumes': ['k3s-certs:/etc/kubernetes/pki:ro'],
                    'environment': {
                        'KUBECONFIG': '/etc/grafana/kubeconfig.yaml',
                    },
                },
            },
        },
    }
```

This is symmetric - grafana defines how it wires to k3s-apiserver, not the other way around.

## API Reference

### Functions

#### `cc_local_compose(name, compose_path, *dependencies, profiles=[])`

Creates a local plugin struct.

**Arguments:**
- `name`: Plugin name (required)
- `compose_path`: Absolute path to compose file (required)
- `*dependencies`: Varargs of dependency structs this plugin depends on
- `profiles`: List of profile names this plugin belongs to (optional)

**Returns:** struct with plugin metadata

**Profile Behavior:**
- If `profiles=[]` (empty/default): plugin is always included
- If `profiles=['dev', 'full']`: plugin is only included when one of these profiles is active

#### `cc_dependency(name, url, ref=None, repo_path=None, compose_overrides={}, imports=[], profiles=[])`

Declare a dependency and load its extension.

**Arguments:**
- `name`: Extension name (required)
- `url`: Extension repo URL - `file://` or `https://` (required)
- `ref`: Git ref for https:// URLs (default: 'main')
- `repo_path`: Path within repo (default: name)
- `compose_overrides`: Static overrides dict (optional)
- `imports`: List of symbol names to bind to the struct (optional)
- `profiles`: List of profile names this dependency belongs to (optional)

**Returns:** struct with dependency metadata and bound helpers

**Profile Behavior:**
- If `profiles=[]` (empty/default): dependency is always included
- If `profiles=['dev', 'staging']`: dependency is only included when one of these profiles is active

#### `cc_generate_master_compose(root_plugin, cli_plugins=[], staging_dir=None, modifications=[])`

Assembles a dependency tree into a master compose file.

**Arguments:**
- `root_plugin`: The root plugin struct from `cc_local_compose()` or `cc_get_plugin()`
- `cli_plugins`: List of additional plugin structs from `cc_parse_cli_plugins()`
- `staging_dir`: Directory for modified compose files (default: `.compose-stage/`)
- `modifications`: List of modification dicts returned by helper functions

**Returns:** Dict with `include` key suitable for `docker_compose(encode_yaml(result))`

#### `cc_parse_cli_plugins(tiltfile_dir)`

Parses CLI positional arguments into dependency structs.

**Arguments:**
- `tiltfile_dir`: Directory of the calling Tiltfile (typically `os.path.dirname(__file__)`)

**Returns:** List of dependency structs

#### `cc_get_active_profiles()`

Returns the list of currently active profiles.

**Returns:** List of profile name strings

**Example:**
```python
profiles = cc_get_active_profiles()
print("Active profiles:", profiles)
```

**Profile Sources (in priority order):**
1. CLI `--profile=X` flags (can be repeated)
2. `CC_PROFILES` environment variable (comma-separated)

### Extension Exports

Extensions should export these functions:

| Function | Required | Description |
|----------|----------|-------------|
| `cc_get_plugin()` | Yes | Returns plugin struct (name, compose_path, dependencies) |
| `get_wire_when()` | No | Returns conditional wiring rules |
| `get_provides()` | No | Documents what this extension provides |
| `get_compose_path()` | Legacy | Returns path to compose file (for backward compat) |

### Compose Overrides

Static modifications to a dependency's compose file:

```python
grafana = cc_dependency(
    name='grafana',
    url='...',
    compose_overrides={
        'services': {
            'grafana': {
                'environment': {
                    'MY_CUSTOM_VAR': 'value',
                },
                'labels': {
                    'managed-by': 'my-orchestrator',
                },
            },
        },
    },
)
```

Overrides are deep-merged:
- Dicts are merged recursively
- Lists are concatenated (avoiding duplicates)
- Scalars are replaced

## Profiles

Profiles allow you to conditionally include dependencies, similar to Docker Compose profiles.

### Declaring Profiles

Assign profiles to dependencies when declaring them:

```python
# Always included (no profiles)
k3s = cc_dependency(name='k3s-apiserver', url=DEVENV_URL)
grafana = cc_dependency(name='grafana', url=DEVENV_URL)

# Only included when 'dev' or 'full' profile is active
mysql = cc_dependency(name='mysql', url=DEVENV_URL, profiles=['dev', 'full'])

# Only included when 'full' profile is active
redis = cc_dependency(name='redis', url=DEVENV_URL, profiles=['full'])

# Local plugin with profiles
def cc_get_plugin():
    return cc_local_compose(
        'debug-tools',
        os.path.dirname(__file__) + '/debug.yaml',
        profiles=['dev', 'debug'],
    )
```

### Activating Profiles

Profiles can be activated via:

1. **CLI flags** (can be repeated):
   ```bash
   tilt up -- --profile=dev
   tilt up -- --profile=dev --profile=debug
   ```

2. **Environment variable** (comma-separated):
   ```bash
   CC_PROFILES=dev,debug tilt up
   ```

3. **Both** (CLI takes precedence):
   ```bash
   CC_PROFILES=staging tilt up -- --profile=dev
   # Results in: ['dev'] (CLI wins)
   ```

### Profile Behavior

| Dependency profiles | Active profiles | Included? |
|---------------------|-----------------|-----------|
| `[]` (none)         | any             | Yes (always) |
| `['dev']`           | `[]` (none)     | No |
| `['dev']`           | `['dev']`       | Yes |
| `['dev', 'full']`   | `['dev']`       | Yes (one match) |
| `['dev']`           | `['staging']`   | No |

### Profiles with CLI Plugins

Profiles and CLI plugins work together:

```bash
# With profiles and plugins
tilt up -- --profile=dev plugin-two ../other-plugin

# Environment + CLI plugins
CC_PROFILES=dev tilt up -- plugin-two
```

### Checking Active Profiles

Use `cc_get_active_profiles()` to see which profiles are active:

```python
from compose_composer import cc_get_active_profiles

profiles = cc_get_active_profiles()
if 'debug' in profiles:
    print("Debug mode enabled")
```

## Integration with k3s-apiserver

### CRD Loading

k3s-apiserver provides a `register_crds()` helper to mount CRD files:

```python
# Import the helper via cc_dependency()
k3s = cc_dependency(
    name='k3s-apiserver',
    url='file:///path/to/devenv-compose',
    imports=['register_crds'],
)

mysql = cc_dependency(name='mysql', url='...')
grafana = cc_dependency(name='grafana', url='...')

def cc_get_plugin():
    return cc_local_compose(
        'my-operator',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        k3s, mysql, grafana,
    )

if __file__ == config.main_path:
    cli_plugins = cc_parse_cli_plugins(os.path.dirname(__file__))
    
    # Call helper with absolute paths
    crd_mod = k3s.register_crds(crd_paths=[
        os.path.dirname(__file__) + '/definitions',
        os.path.dirname(__file__) + '/crds',
    ])
    
    master_compose = cc_generate_master_compose(
        cc_get_plugin(),
        cli_plugins,
        modifications=[crd_mod],
    )
    
    docker_compose(encode_yaml(master_compose))
```

When multiple plugins bring CRDs, they are all merged into the single `crd-loader` service.

## Complete Example

### Plugin with Dependencies and CRDs

```python
# my-operator/Tiltfile

# Allow any k8s context
allow_k8s_contexts(k8s_context())

# Load compose_composer
v1alpha1.extension_repo(name='tilt-ext', url='file:///shared/tilt-extensions')
v1alpha1.extension(name='compose_composer', repo_name='tilt-ext', repo_path='compose_composer')
load('ext://compose_composer', 'cc_dependency', 'cc_local_compose', 'cc_generate_master_compose', 'cc_parse_cli_plugins')

# ============================================================================
# Core Dependencies
# ============================================================================

DEVENV_URL = 'file:///shared/devenv-compose'

k3s = cc_dependency(
    name='k3s-apiserver',
    url=DEVENV_URL,
    imports=['register_crds'],
)

mysql = cc_dependency(name='mysql', url=DEVENV_URL)
grafana = cc_dependency(name='grafana', url=DEVENV_URL)

# ============================================================================
# Plugin Definition
# ============================================================================

def cc_get_plugin():
    """Returns this plugin's struct for compose_composer."""
    return cc_local_compose(
        'my-operator',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        k3s, mysql, grafana,
    )

# ============================================================================
# Orchestrator Mode
# ============================================================================

if __file__ == config.main_path:
    cli_plugins = cc_parse_cli_plugins(os.path.dirname(__file__))
    
    # Register CRDs (use absolute paths)
    crd_mod = k3s.register_crds(crd_paths=[os.path.dirname(__file__) + '/crds'])
    
    master = cc_generate_master_compose(
        cc_get_plugin(),
        cli_plugins,
        staging_dir=os.path.dirname(__file__) + '/.compose-stage',
        modifications=[crd_mod],
    )
    
    docker_compose(encode_yaml(master))
```

## Troubleshooting

### "extensions already registered" error

This can happen if an extension is registered twice. The `cc_dependency()` function handles this automatically by using unique repo names.

### Compose overrides not applying

Check that:
1. The service name in `compose_overrides` matches exactly
2. The override is on the correct dependency

### Modifications not applying

Ensure:
1. The helper function is called (e.g., `crd_mod = k3s.register_crds(...)`)
2. The result is passed to `modifications=[crd_mod]`
3. Check the output for "Applied modification to: ..."

### CRDs not loading

Verify:
1. The path in `register_crds()` is absolute
2. The staged compose file has the volume mount (check `.compose-stage/`)
3. Files are `.json`, `.yaml`, or `.yml`

### Wire rules not triggering

Wire rules only apply when the trigger dependency is loaded:

```python
# This only applies if 'k3s-apiserver' is in the dependency list
'k3s-apiserver': { ... }
```

## File Structure

```
.compose-stage/           # Staged (modified) compose files
  k3s-apiserver.yaml      # Modified version with overrides applied
  grafana.yaml            # Modified with wire_when rules applied
docker-compose.yaml       # Your local services
Tiltfile                  # Orchestrator
```

## Running Tests

```bash
cd tilt-extensions/compose_composer
make test
```
