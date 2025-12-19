# Compose Composer

A Tilt extension for dynamically assembling Docker Compose environments from modular, reusable components.

## Overview

Compose Composer enables you to build development environments from composable pieces. Each component (k3s-apiserver, grafana, mysql, your plugins) can define:

- Its own Docker Compose services
- Dependencies on other components
- Wiring rules that activate when other components are present
- A complete dependency graph that travels with the component

**Design Principle**: Any plugin can be the orchestrator. The result is symmetric - whether you run `tilt up` from plugin-A or plugin-B, the final composed environment is consistent because wiring is defined declaratively in each component.

## Quick Start

### Basic Orchestrator

```python
# my-plugin/Tiltfile

# Load compose_composer
v1alpha1.extension_repo(name='tilt-extensions', url='file:///path/to/tilt-extensions')
v1alpha1.extension(name='compose_composer', repo_name='tilt-extensions', repo_path='compose_composer')
load('ext://compose_composer', 'generate_master_compose', 'parse_cli_plugins')

# Allow any k8s context (we're only using docker-compose)
allow_k8s_contexts(k8s_context())

# Define dependencies
core_dependencies = [
    {'name': 'k3s-apiserver', 'url': 'file:///path/to/devenv-compose'},
    {'name': 'mysql', 'url': 'file:///path/to/devenv-compose'},
    {'name': 'grafana', 'url': 'file:///path/to/devenv-compose'},
]

# Parse CLI plugins (e.g., 'tilt up -- other-plugin')
cli_plugins = parse_cli_plugins(os.path.dirname(__file__))

# Generate and run
master_compose = generate_master_compose(
    core_dependencies + cli_plugins,
    local_compose_paths=[os.path.dirname(__file__) + '/docker-compose.yaml'],
    staging_dir=os.path.dirname(__file__) + '/.compose-stage',
)

docker_compose(encode_yaml(master_compose))
```

### Adding CLI Plugins

```bash
# Run with additional plugins from CLI
tilt up -- plugin-two ../relative/path /absolute/path
```

## Core Concepts

### Orchestrator

The **orchestrator** is the Tiltfile that runs `generate_master_compose()`. It defines:
- Core dependencies that are always included
- Local compose files with its own services
- The staging directory for modified compose files

Any plugin can be an orchestrator. When you run `tilt up` from a directory, that Tiltfile becomes the orchestrator.

### Dependencies

A **dependency** is a reference to another Tilt extension that provides Docker Compose services:

```python
{
    'name': 'k3s-apiserver',           # Extension name (required)
    'url': 'file:///path/to/repo',     # Extension repo URL (required)
    'ref': 'main',                      # Git ref for https:// URLs (optional)
    'repo_path': 'k3s-apiserver',       # Path within repo (default: name)
    'compose_overrides': {...},         # Static overrides (optional)
    'symbols': {...},                   # Pre-loaded symbols (optional)
}
```

### Dependency Graphs

When a CLI plugin exports `get_dependency_graph()`, its dependencies are **merged** with the orchestrator's:

```python
# plugin-two/Tiltfile
def get_dependency_graph():
    return {
        'compose_path': get_compose_path(),
        'dependencies': [
            {'name': 'k3s-apiserver', 'url': '...'},
            {'name': 'my-special-service', 'url': '...'},
        ],
    }
```

When you run `tilt up -- plugin-two`:
1. Orchestrator's dependencies are loaded
2. plugin-two's `get_dependency_graph()` is called
3. Dependencies are merged, deduplicated by name
4. `compose_overrides` are deep-merged for duplicates

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

#### `generate_master_compose(dependencies, local_compose_paths=[], staging_dir=None)`

Assembles dependencies into a master compose file.

**Arguments:**
- `dependencies`: List of dependency dicts
- `local_compose_paths`: Additional local compose files to include
- `staging_dir`: Directory for modified compose files (default: `.compose-stage/`)

**Returns:** Dict with `include` key suitable for `docker_compose(encode_yaml(result))`

#### `parse_cli_plugins(tiltfile_dir)`

Parses CLI positional arguments into dependency dicts.

**Arguments:**
- `tiltfile_dir`: Directory of the calling Tiltfile (typically `os.path.dirname(__file__)`)

**Returns:** List of dependency dicts with `_from_cli: True` marker

### Extension Exports

Extensions should export these functions:

| Function | Required | Description |
|----------|----------|-------------|
| `get_compose_path()` | Yes | Returns absolute path to compose file |
| `get_dependency_graph()` | No | Returns dependencies this extension brings |
| `get_wire_when()` | No | Returns conditional wiring rules |
| `get_provides()` | No | Documents what this extension provides |

### Compose Overrides

Static modifications to a dependency's compose file:

```python
{
    'name': 'grafana',
    'url': '...',
    'compose_overrides': {
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
}
```

Overrides are deep-merged:
- Dicts are merged recursively
- Lists are concatenated (avoiding duplicates)
- Scalars are replaced

## Integration with k3s-apiserver

### CRD Loading

k3s-apiserver provides a `register_crds()` helper to mount CRD files:

```python
# Load k3s-apiserver and get the helper
v1alpha1.extension_repo(name='devenv-compose', url='file:///path/to/devenv-compose')
v1alpha1.extension(name='k3s-apiserver', repo_name='devenv-compose', repo_path='k3s-apiserver')
_k3s_apiserver_symbols = load_dynamic('ext://k3s-apiserver')
register_crds = _k3s_apiserver_symbols['register_crds']

# Use in dependency definition
core_dependencies = [
    {
        'name': 'k3s-apiserver',
        'url': 'file:///path/to/devenv-compose',
        'symbols': _k3s_apiserver_symbols,  # Pass to avoid re-registration
        'compose_overrides': register_crds(
            crd_paths=['./definitions', './crds'],
            caller_dir=os.path.dirname(__file__),
        ),
    },
]
```

When multiple plugins bring CRDs, they are all merged into the single `crd-loader` service.

### Pre-loading Symbols

When you load an extension to use its helpers (like `register_crds`), you must pass the symbols to avoid re-registration errors:

```python
# Load extension and capture symbols
_k3s_symbols = load_dynamic('ext://k3s-apiserver')

# Pass symbols in dependency
{'name': 'k3s-apiserver', 'symbols': _k3s_symbols, ...}
```

## Complete Example

### Plugin with Dependencies and CRDs

```python
# my-operator/Tiltfile

# Allow any k8s context
allow_k8s_contexts(k8s_context())

# Load compose_composer
v1alpha1.extension_repo(name='tilt-ext', url='file:///shared/tilt-extensions')
v1alpha1.extension(name='compose_composer', repo_name='tilt-ext', repo_path='compose_composer')
load('ext://compose_composer', 'generate_master_compose', 'parse_cli_plugins')

# Load k3s-apiserver for register_crds helper
v1alpha1.extension_repo(name='devenv', url='file:///shared/devenv-compose')
v1alpha1.extension(name='k3s-apiserver', repo_name='devenv', repo_path='k3s-apiserver')
_k3s_symbols = load_dynamic('ext://k3s-apiserver')
register_crds = _k3s_symbols['register_crds']

# ============================================================================
# Extension Exports (for when loaded as CLI plugin)
# ============================================================================

def get_compose_path():
    return os.path.dirname(__file__) + '/docker-compose.yaml'

def get_dependency_graph():
    return {
        'compose_path': get_compose_path(),
        'dependencies': _get_core_dependencies(),
    }

# ============================================================================
# Core Dependencies
# ============================================================================

def _get_core_dependencies():
    return [
        {
            'name': 'k3s-apiserver',
            'url': 'file:///shared/devenv-compose',
            'symbols': _k3s_symbols,
            'compose_overrides': register_crds(
                crd_paths=['./crds'],
                caller_dir=os.path.dirname(__file__),
            ),
        },
        {
            'name': 'mysql',
            'url': 'file:///shared/devenv-compose',
        },
        {
            'name': 'grafana',
            'url': 'file:///shared/devenv-compose',
        },
    ]

# ============================================================================
# Orchestrator Mode
# ============================================================================

if __file__ == config.main_path:
    deps = _get_core_dependencies() + parse_cli_plugins(os.path.dirname(__file__))
    
    master = generate_master_compose(
        deps,
        local_compose_paths=[get_compose_path()],
        staging_dir=os.path.dirname(__file__) + '/.compose-stage',
    )
    
    docker_compose(encode_yaml(master))
```

## Troubleshooting

### "extensions already registered" error

This happens when an extension is loaded twice with different repo names.

**Solution**: Pass pre-loaded symbols in the dependency:

```python
_symbols = load_dynamic('ext://k3s-apiserver')
{'name': 'k3s-apiserver', 'symbols': _symbols, ...}
```

### Compose overrides not applying

Check that:
1. The service name in `compose_overrides` matches exactly
2. The override is on the correct dependency

### CRDs not loading

Verify:
1. The path in `register_crds()` is relative to `caller_dir`
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

