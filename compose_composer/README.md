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
DEVENV_URL = 'file:///path/to/composables'

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
        cc_get_plugin(),                # Your plugin with its dependencies
        cli_plugins,                    # Additional plugins from CLI
        staging_dir=os.path.dirname(__file__) + '/.compose-stage',
    )
    cc_docker_compose(master_compose)   # Auto-registers services with labels
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

#### Unified Profile Model

compose_composer supports a **unified profile model** where profiles control both:
1. **Which dependencies to load** (compose_composer filtering)
2. **Which services to start within those dependencies** (docker-compose profiles)

**Defining profiles on dependencies:**

```python
# Only loaded when 'core' or 'full' profile is active
mysql = cc_dependency(
    name='mysql',
    url=DEVENV_URL,
    profiles=['core', 'full'],
)

# Always loaded (no profile restrictions)
grafana = cc_dependency(name='grafana', url=DEVENV_URL)
```

**Using profiles in compose files:**

```yaml
services:
  db:
    profiles: ['core', 'full']  # Only starts in these profiles
    image: mysql:8
  
  api:
    # No profile = always starts
    image: my-api
```

**Automatic COMPOSE_PROFILES and service registration:**

Use `cc_docker_compose()` instead of `docker_compose()` to automatically:
1. Set COMPOSE_PROFILES environment variable based on active profiles
2. Register all services with `dc_resource()` using their labels

```python
load('ext://compose_composer', 'cc_docker_compose')

if __file__ == config.main_path:
    master = cc_generate_master_compose(cc_get_plugin(), cli_plugins)

    # Pass dict directly (not encoded) for automatic service registration
    cc_docker_compose(master)  # Automatically sets profiles and registers services

    # Legacy pattern (skips auto-registration):
    # cc_docker_compose(encode_yaml(master))
```

**Note:** Pass the dict directly (not encoded) to enable automatic service registration with labels. If you pass an encoded YAML string, profiles will still work but service registration will be skipped.

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

When you import a helper function via `imports=[]`, it's bound to the dependency struct:

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
```

The wrapper automatically adds `_target` metadata so compose_composer knows which dependency to modify.

**Old approach (orchestrator-level):**
```python
# In orchestrator block only - doesn't work for CLI plugins
if __file__ == config.main_path:
    crd_mod = k3s.register_crds(crd_paths=[...])

    master = cc_generate_master_compose(
        cc_get_plugin(),
        cli_plugins,
        modifications=[crd_mod],  # Only applied when this is orchestrator
    )
```

**New approach (plugin-level - RECOMMENDED):**
```python
# In cc_get_plugin() - works as orchestrator OR CLI plugin
def cc_get_plugin():
    return cc_local_compose(
        'my-plugin',
        compose_path,
        k3s, mysql,
        modifications=[
            k3s.register_crds(crd_paths=[...]),  # Applied in ALL modes
        ],
    )
```

See [Plugin-Declared Modifications](#plugin-declared-modifications-recommended) section below for details.

### Plugin-Declared Modifications (Recommended)

**NEW:** Instead of calling helper functions in the orchestrator block, declare modifications directly in `cc_get_plugin()`. This enables **symmetric orchestration** - your plugin works the same whether it's the orchestrator or a CLI plugin.

**Example - Plugin-declared modifications:**

```python
# service-model/Tiltfile

# Load dependencies
k3s = cc_dependency(
    name='k3s-apiserver',
    url=DEVENV_URL,
    imports=['register_crds'],
    labels=['k8s'],
)

mysql = cc_dependency(name='mysql', url=DEVENV_URL, labels=['infra'])
grafana = cc_dependency(name='grafana', url=DEVENV_URL, labels=['app'])

# Declare modifications IN the plugin definition
def cc_get_plugin():
    return cc_local_compose(
        'service-model',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        k3s, mysql, grafana,
        labels=['app'],
        modifications=[
            # Declare requirements here - works in ALL modes!
            k3s.register_crds(crd_paths=[os.path.dirname(__file__) + '/definitions']),
        ],
    )

# Orchestrator block is clean
if __file__ == config.main_path:
    cli_plugins = cc_parse_cli_plugins(os.path.dirname(__file__))

    master = cc_generate_master_compose(
        cc_get_plugin(),  # Plugin modifications already included
        cli_plugins,
        modifications=[],  # Usually empty - plugins declare their own
    )

    cc_docker_compose(master)
```

**Why this is better:**

1. **Works as orchestrator**: When you run `tilt up` in service-model/, CRDs are loaded
2. **Works as CLI plugin**: When you run `tilt up -- service-model` from another orchestrator, CRDs are still loaded
3. **Single declaration**: Requirements defined once, work everywhere
4. **Self-documenting**: Plugin struct shows all its requirements

**Two-Level Modification System:**

compose_composer collects modifications from two sources:

1. **Plugin-declared** (from `cc_local_compose.modifications`):
   - Collected from root_plugin and all cli_plugins
   - Applied first (define requirements)
   - Enable symmetric orchestration

2. **Orchestrator-provided** (from `cc_generate_master_compose.modifications` parameter):
   - Passed explicitly by orchestrator
   - Applied second (can override)
   - For environment-specific customization only

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

#### `cc_local_compose(name, compose_path, *dependencies, profiles=[], labels=[], modifications=[])`

Creates a local plugin struct.

**Arguments:**
- `name`: Plugin name (required)
- `compose_path`: Absolute path to compose file (required)
- `*dependencies`: Varargs of dependency structs this plugin depends on
- `profiles`: List of profile names this plugin belongs to (optional)
- `labels`: List of Tilt labels for grouping services in the UI (optional, default: `['dependencies']`)
- `modifications`: List of modification dicts from helper function calls (optional, default: `[]`)
  - Declare helper-based modifications here for symmetric orchestration
  - Works as orchestrator OR CLI plugin
  - Applied in ALL modes

**Returns:** struct with plugin metadata

**Profile Behavior:**
- If `profiles=[]` (empty/default): plugin is always included
- If `profiles=['dev', 'full']`: plugin is only included when one of these profiles is active

**Label Behavior:**
- If `labels=[]` (empty/default): services get `['dependencies']` label
- If `labels=['app']`: all services from this plugin get the 'app' label in Tilt UI
- Labels enable Tilt sidebar grouping for better organization

#### `cc_dependency(name, url, ref=None, repo_path=None, compose_overrides={}, imports=[], profiles=[], labels=[])`

Declare a dependency and load its extension.

**Arguments:**
- `name`: Extension name (required)
- `url`: Extension repo URL - `file://` or `https://` (required)
- `ref`: Git ref for https:// URLs (default: 'main')
- `repo_path`: Path within repo (default: name)
- `compose_overrides`: Static overrides dict (optional)
- `imports`: List of symbol names to bind to the struct (optional)
- `profiles`: List of profile names this dependency belongs to (optional)
- `labels`: List of Tilt labels for grouping services in the UI (optional, default: `['dependencies']`)

**Returns:** struct with dependency metadata and bound helpers

**Profile Behavior:**
- If `profiles=[]` (empty/default): dependency is always included
- If `profiles=['dev', 'staging']`: dependency is only included when one of these profiles is active

**Label Behavior:**
- If `labels=[]` (empty/default): services get `['dependencies']` label
- If `labels=['infra']`: all services from this dependency get the 'infra' label in Tilt UI
- Labels enable Tilt sidebar grouping for better organization

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

## Tilt Sidebar Grouping with Labels

Labels organize services in the Tilt UI sidebar into collapsible groups, making it easier to navigate environments with many services.

### Assigning Labels to Dependencies

Labels are assigned when declaring dependencies:

```python
# Infrastructure services
mysql = cc_dependency(name='mysql', url=DEVENV_URL, labels=['infra'])
nats = cc_dependency(name='nats', url=DEVENV_URL, labels=['infra'])

# Observability stack
jaeger = cc_dependency(name='jaeger', url=DEVENV_URL, profiles=['core', 'full'], labels=['observability'])
loki = cc_dependency(name='loki', url=DEVENV_URL, profiles=['core', 'full'], labels=['observability'])

# Application services
grafana = cc_dependency(name='grafana', url=DEVENV_URL, labels=['app'])

# Local plugin services
def cc_get_plugin():
    return cc_local_compose(
        'my-plugin',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        mysql, nats, jaeger, loki, grafana,
        labels=['app'],
    )
```

### Automatic Service Registration

When using `cc_docker_compose()`, services are automatically registered with `dc_resource()` using their plugin's labels:

```python
load('ext://compose_composer', 'cc_docker_compose')

if __file__ == config.main_path:
    master = cc_generate_master_compose(cc_get_plugin(), cli_plugins)

    # Pass dict directly (not encoded) for automatic service registration
    cc_docker_compose(master)  # Auto-registers services with labels
```

This automatically calls `dc_resource(service_name, labels=labels)` for each service.

### Default Label Behavior

- If `labels=[]` (empty/default): services get `['dependencies']` label
- All services from a plugin/dependency inherit that plugin's labels
- Services defined in compose files with `profiles:` are only registered if their profiles are active

### Overriding Labels for Specific Services

Some services may need different labels than their plugin default:

```python
if __file__ == config.main_path:
    master = cc_generate_master_compose(cc_get_plugin(), cli_plugins)
    cc_docker_compose(master)

    # Override labels for profile-specific services
    active_profiles = cc_get_active_profiles()
    if 'core' in active_profiles or 'full' in active_profiles:
        dc_resource('api-admin', labels=['admin'])

    if 'full' in active_profiles:
        dc_resource('advanced-service', labels=['advanced'])
```

### Common Label Grouping Patterns

| Group | Services | Purpose |
|-------|----------|---------|
| `app` | Frontend, API, main application services | Core application |
| `infra` | Database, message broker, cache | Infrastructure dependencies |
| `observability` | Jaeger, Loki, Prometheus, Promtail | Monitoring and logging |
| `admin` | Admin UI, dashboards | Administrative interfaces |
| `sql-test` | Test databases, data generators | SQL testing environment |
| `advanced` | Optional features, proxies | Advanced/optional features |
| `dependencies` | (default) | Unclassified dependencies |

### Profile Interaction

Labels respect docker-compose native profiles. Services with `profiles:` in their compose files are only registered if those profiles are active:

```yaml
# docker-compose.yaml
services:
  api-admin:
    profiles: ['core', 'full']
    image: admin-ui
```

```python
# Tiltfile
# api-admin is only registered when 'core' or 'full' profile is active
```

## Integration with k3s-apiserver

### CRD Loading

k3s-apiserver provides a `register_crds()` helper to mount CRD files:

```python
# Import the helper via cc_dependency()
k3s = cc_dependency(
    name='k3s-apiserver',
    url='file:///path/to/composables',
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

DEVENV_URL = 'file:///shared/composables'

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

    cc_docker_compose(master)  # Auto-registers services with labels
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

## Potential Problems with Tilt
The Tiltfile uses local_resource to run plugin-precache before docker-compose services start, because Tilt doesn't respect docker-compose's `depends_on: service_completed_successfully` conditions.

**Problem:**
This requires specifying the dependency twice:
1. In docker-compose.yaml: `depends_on: plugin-precache: condition: service_completed_successfully`
2. In Tiltfile: local_resource + `resource_deps=['plugin-precache-build']`

This violates DRY principle and creates maintenance burden.

**Attempted Solutions:**

1. **Tilt's wait=True parameter**: Added to `cc_docker_compose()` call, but plugin service still doesn't wait long enough for precache to complete.

2. **Healthcheck approach**: Added healthcheck to plugin-precache service to verify build artifacts exist, changed to `condition: service_healthy`, and made precache stay alive with `tail -f /dev/null`. This still didn't work with Tilt's wait=True.

Both approaches failed to make Tilt properly wait for precache completion. The local_resource workaround remains necessary but requires duplicate dependency specification.

**Desired Solution:**
Find a way to automatically extract and respect docker-compose dependencies without requiring manual Tiltfile configuration. Options:
- Parse docker-compose.yaml to extract `depends_on` relationships
- Create a Tilt extension that wraps docker_compose() and auto-creates local_resources for one-shot services
- Contribute upstream fix to Tilt to respect docker-compose conditions properly

**Workaround Location:**
grafana-assistant-app/Tiltfile lines 230-247

**Related Issues:**
- apiserver-devenv-testing-claude-r74 (original plugin-precache issue)
