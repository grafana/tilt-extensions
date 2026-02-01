
**TODO** Much of this is LLM generated and needs editing

## Table of Contents

- [The Problem: Docker Compose is Too Rigid](#the-problem-docker-compose-is-too-rigid)
- [The Solution: Runtime Assembly of Composable LEGOs](#the-solution-runtime-assembly-of-composable-legos)
- [Key Innovations](#key-innovation-symmetric-orchestration)
- [Quick Start](#quick-start)
- [Usage Examples](#usage-examples)
- [Core Concepts](#core-concepts)
- [API Reference](#api-reference)
- [Profiles](#profiles)
- [Tilt Sidebar Grouping with Labels](#tilt-sidebar-grouping-with-labels)
- [Integration with k3s-apiserver](#integration-with-k3s-apiserver)
- [Troubleshooting](#troubleshooting)
- [Known Issues with Tilt](#known-issues-with-tilt)

## Quick Start

> **Prerequisites**: This guide assumes you have [Tilt](https://tilt.dev) installed and familiarity with Docker Compose. The examples use the [grafana/composables](https://github.com/grafana/composables) repository.

### Basic Orchestrator

```python
# my-plugin/Tiltfile

# Load compose_composer
v1alpha1.extension_repo(name='grafana-tilt-extensions', url='https://github.com/grafana/tilt-extensions', ref='compose-composer')
v1alpha1.extension(name='compose_composer', repo_name='grafana-tilt-extensions', repo_path='compose_composer')
load('ext://compose_composer', 'cc_composable', 'cc_local_composable', 'cc_generate_master_compose', 'cc_parse_cli_plugins')

# Allow any k8s context (we're only using docker-compose)
allow_k8s_contexts(k8s_context())

# Define dependencies using cc_composable()
# url defaults to 'https://github.com/grafana/composables'
k3s = cc_composable(name='k3s-apiserver')
mysql = cc_composable(name='mysql')
grafana = cc_composable(name='grafana')

# Define your plugin with its compose file and dependencies
def cc_get_plugin():
    return cc_local_composable(
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
        staging_dir=os.path.dirname(__file__) + '/.cc',
    )
    cc_docker_compose(master_compose)   # Auto-registers services with labels
```

### Starting Multiple Plugins from the tilt command line

If the services that you want to run together vary, then you can specify, on the `tilt` command line other composables you want to run. Assuming of course they are build with `compose-composer`. When doing multi-plugin development you may want to:

```bash
# Run with additional plugins from CLI
tilt up -- plugin-two ../relative/path /absolute/path
```

### Using Profiles

Profiles let you conditionally include dependencies, compatible with Docker Compose profiles.

```bash
# Activate profiles via CLI flags and addational composables
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
mysql = cc_composable(
    name='mysql',
    url=DEVENV_URL,
    profiles=['core', 'full'],
)

# Always loaded (no profile restrictions)
grafana = cc_composable(name='grafana')
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

Use `cc_docker_compose()` instead of tilts's `docker_compose()` to automatically:
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

1. **Remote dependencies** via `cc_composable()` - Loads an extension from a repo, either in git or from the local filesystem.
2. **Local plugins** via `cc_local_composable()` - Defines a local plugin with its docker-compose.yaml file

Both return structs that can be passed to `cc_generate_master_compose()`.

### The `cc_local_composable()` Function

Creates a plugin struct for your local compose file:

```python
def cc_get_plugin():
    return cc_local_composable(
        'my-plugin',                                         # Plugin name
        os.path.dirname(__file__) + '/docker-compose.yaml',  # Compose file path
        k3s, mysql, grafana,                                 # Dependencies (varargs)
    )
```

### The `cc_composable()` Function

Loads a remote extension and returns a plugin struct:

```python
k3s = cc_composable(
    name='k3s-apiserver',           # Extension name (required)
    url='https://github.com/grafana/composables',  # Extension repo URL (required)
    ref='main',                      # Git ref for https:// URLs (optional)
    repo_path='k3s-apiserver',       # Path within repo (default: name)
    compose_overrides={...},         # Static overrides (optional)
    imports=['register_crds'],       # Helper functions to bind (optional)
)
```

When loaded, it calls `cc_get_plugin()` from the extension to get its compose_path and nested dependencies.

### The `cc_get_plugin()` Export

Every extension should export a `cc_get_plugin()` function in order to be a composable to someone else:

```python
# grafana/Tiltfile
load('ext://compose_composer', 'cc_local_composable')

def cc_get_plugin():
    return cc_local_composable(
        'grafana',
        os.path.dirname(__file__) + '/grafana.yaml',
    )
```

### Bound Helpers

Composables can export helper functions that provide some syntax sugar for adding to the master docker compose file. Helpers should return slices of a docker compose file to be merged in.

When you import a helper function via `imports=[]`, it's bound to the dependency struct:

```python
k3s = cc_composable(
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

```python
# In cc_get_plugin() - works as orchestrator OR CLI plugin
def cc_get_plugin():
    return cc_local_composable(
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

You may declare modifications to dependent composables directly in `cc_get_plugin()`. This enables **symmetric orchestration** - your plugin works the same whether it's the orchestrator or a CLI plugin.

**Example - Plugin-declared modifications:**

```python
# service-model/Tiltfile

# Load dependencies
k3s = cc_composable(name='k3s-apiserver', imports=['register_crds'],labels=['k8s'])
mysql = cc_composable(name='mysql', labels=['infra'])
grafana = cc_composable(name='grafana', labels=['app'])

# Declare modifications IN the plugin definition
def cc_get_plugin():
    return cc_local_composable(
        'service-model',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        k3s, mysql, grafana,
        labels=['app'],
        modifications=[
            # Declare requirements here
            k3s.register_crds(crd_paths=[os.path.dirname(__file__) + '/definitions']),
        ],
    )
```

If for some reason you need to declare your modifications only when your composable +is* the orchestrator, you can pass in 
modifications to `cc_generate_master_compos`: 

```python
# Orchestrator block is clean
if __file__ == config.main_path:
    cli_plugins = cc_parse_cli_plugins(os.path.dirname(__file__))

    master = cc_generate_master_compose(
        cc_get_plugin(),  # Plugin modifications already included
        cli_plugins,
        modifications=[
            k3s.register_crds(crd_paths=[os.path.dirname(__file__) + '/definitions'])
        ],
    )

    cc_docker_compose(master)
```

**Two-Level Modification System:**

compose_composer collects modifications from two sources:

1. **Plugin-declared** (from `cc_local_composable.modifications`):
   - Collected from root_plugin and all cli_plugins
   - Applied first (define requirements)
   - Enable symmetric orchestration

2. **Orchestrator-provided** (from `cc_generate_master_compose.modifications` parameter):
   - Passed explicitly by orchestrator
   - Applied second (can override)
   - For environment-specific customization only

### Wire When Rules

Composables can declare conditional wiring that activates when other dependencies are present in the docker-compose collective:

```python
# grafana/Tiltfile
def cc_wire_when():
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

This is asymmetric - grafana defines how it wires to k3s-apiserver, not the other way around.

## API Reference

### Functions

#### `cc_local_composable(name, compose_path, *dependencies, profiles=[], labels=[], modifications=[])`

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

#### `cc_composable(name, url, ref=None, repo_path=None, compose_overrides={}, imports=[], profiles=[], labels=[])`

Declare a dependency and load its extension.

**Arguments:**
- `name`: Extension name (required)
- `url`: Extension repo URL - `file://` or `https://` (required)
  - Can embed ref using `@` separator: `https://github.com/user/repo@branch`
  - Supports branches, tags, and commit hashes
- `ref`: Git ref for https:// URLs (default: 'main')
  - Optional if ref is embedded in URL with `@` syntax
  - If both url@ref and ref parameter are provided, ref parameter takes precedence
- `repo_path`: Path within repo (default: name)
- `compose_overrides`: Static overrides dict (optional)
- `imports`: List of symbol names to bind to the struct (optional)
- `profiles`: List of profile names this dependency belongs to (optional)
- `labels`: List of Tilt labels for grouping services in the UI (optional, default: `['dependencies']`)

**Returns:** struct with dependency metadata and bound helpers

**URL with Embedded Ref Examples:**
```python
# Branch
k3s = cc_composable(
    name='k3s-apiserver',
    url='https://github.com/grafana/composables@main',
)

# Tag
mysql = cc_composable(
    name='mysql',
    url='https://github.com/grafana/composables@v1.2.3',
)

# Commit hash
tempo = cc_composable(
    name='tempo',
    url='https://github.com/grafana/composables@abc123def',
)

# Old style (still supported)
redis = cc_composable(
    name='redis',
    url='https://github.com/grafana/composables',
    ref='v2.0.0',
)
```

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
- `root_plugin`: The root plugin struct from `cc_local_composable()` or `cc_get_plugin()`
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
| `cc_wire_when()` | No | Returns conditional wiring rules |

### Compose Overrides

There are three ways to specify compose overrides for dependencies:

#### 1. Parameter-Level Overrides (at Load Time)

Static modifications specified when declaring the dependency:

```python
grafana = cc_composable(
    name='grafana',
    url='...',
    compose_overrides={
        'services': {
            'grafana': {
                'environment': {
                    'MY_CUSTOM_VAR': 'value',
                },
            },
        },
    },
)
```

**Best for:** Simple, static overrides that don't need orchestrator context.

#### 2. compose_overrides() Method (Recommended)

Every composable struct has a bound `compose_overrides()` method that returns a modification dict:

```python
# Compact declaration at top
mysql = cc_composable(name='mysql', url=COMPOSABLES_URL)
grafana = cc_composable(name='grafana', url=COMPOSABLES_URL)

def cc_get_plugin():
    return cc_local_composable(
        'my-app',
        compose_path,
        mysql, grafana,
        modifications=[
            # Group all overrides here
            mysql.compose_overrides({
                'services': {
                    'db': {
                        'environment': {
                            'MYSQL_ROOT_PASSWORD': 'secret',
                        },
                    },
                },
            }),
            grafana.compose_overrides({
                'services': {
                    'grafana': {
                        'volumes': [
                            './config:/etc/grafana',
                        ],
                    },
                },
            }),
        ],
    )
```

**Best for:** Most use cases - cleaner code organization, overrides that need orchestrator context (paths, env vars).

**Benefits:**
- Compact composable declarations
- All overrides grouped in one place
- Clear separation of dependencies vs configuration
- Works as orchestrator OR CLI plugin

#### 3. Custom Helper Functions (via imports)

For reusable, complex configuration logic:

```python
# In mysql/Tiltfile
def configure_database(password, max_connections):
    return {
        'services': {
            'db': {
                'environment': {'MYSQL_ROOT_PASSWORD': password},
                'command': '--max_connections=' + str(max_connections),
            },
        },
    }

# In orchestrator
mysql = cc_composable(name='mysql', url=COMPOSABLES_URL, imports=['configure_database'])

def cc_get_plugin():
    return cc_local_composable(
        'my-app',
        compose_path,
        mysql,
        modifications=[
            mysql.configure_database('secret', 1000),
        ],
    )
```

**Best for:** Complex configuration logic that needs to be reusable across orchestrators.

#### Merging Behavior

When both parameter and method overrides are specified, they deep-merge with the method having higher precedence:

```python
mysql = cc_composable(
    name='mysql',
    url=COMPOSABLES_URL,
    compose_overrides={
        'services': {
            'db': {
                'environment': {
                    'VAR1': 'from_parameter',
                    'COMMON': 'parameter_value',
                },
            },
        },
    },
)

def cc_get_plugin():
    return cc_local_composable(
        'my-app',
        compose_path,
        mysql,
        modifications=[
            mysql.compose_overrides({
                'services': {
                    'db': {
                        'environment': {
                            'VAR2': 'from_method',
                            'COMMON': 'method_wins',  # Overwrites parameter
                        },
                    },
                },
            }),
        ],
    )

# Result: VAR1='from_parameter', VAR2='from_method', COMMON='method_wins'
```

All overrides are deep-merged:
- Dicts are merged recursively
- Lists are concatenated (avoiding duplicates)
- Scalars are replaced (last wins)

## Profiles

Profiles allow you to conditionally include dependencies, similar to Docker Compose profiles.

### Declaring Profiles

Assign profiles to dependencies when declaring them:

```python
# Always included (no profiles)
k3s = cc_composable(name='k3s-apiserver', url=DEVENV_URL)
grafana = cc_composable(name='grafana', url=DEVENV_URL)

# Only included when 'dev' or 'full' profile is active
mysql = cc_composable(name='mysql', url=DEVENV_URL, profiles=['dev', 'full'])

# Only included when 'full' profile is active
redis = cc_composable(name='redis', url=DEVENV_URL, profiles=['full'])

# Local plugin with profiles
def cc_get_plugin():
    return cc_local_composable(
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
mysql = cc_composable(name='mysql', url=DEVENV_URL, labels=['infra'])
nats = cc_composable(name='nats', url=DEVENV_URL, labels=['infra'])

# Observability stack
jaeger = cc_composable(name='jaeger', url=DEVENV_URL, profiles=['core', 'full'], labels=['observability'])
loki = cc_composable(name='loki', url=DEVENV_URL, profiles=['core', 'full'], labels=['observability'])

# Application services
grafana = cc_composable(name='grafana', url=DEVENV_URL, labels=['app'])

# Local plugin services
def cc_get_plugin():
    return cc_local_composable(
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
# Import the helper via cc_composable()
k3s = cc_composable(
    name='k3s-apiserver',
    url='https://github.com/grafana/composables',
    imports=['register_crds'],
)

mysql = cc_composable(name='mysql', url='...')
grafana = cc_composable(name='grafana', url='...')

def cc_get_plugin():
    return cc_local_composable(
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

## Usage Examples

This section demonstrates key capabilities with realistic, copy-pasteable examples.

### Example 1: Transitive Dependencies

**Scenario**: Your plugin needs Grafana, which automatically brings MySQL as a transitive dependency.

```python
# my-dashboard-plugin/Tiltfile

# Load compose_composer
v1alpha1.extension_repo(name='devenv', url='https://github.com/grafana/composables')
v1alpha1.extension(name='compose_composer', repo_name='devenv', repo_path='compose_composer')
load('ext://compose_composer', 'cc_composable', 'cc_local_composable', 'cc_generate_master_compose', 'cc_parse_cli_plugins', 'cc_docker_compose')

allow_k8s_contexts(k8s_context())

# Declare only what you need directly - Grafana brings MySQL automatically
grafana = cc_composable(name='grafana', url='https://github.com/grafana/composables')

def cc_get_plugin():
    return cc_local_composable(
        'dashboard-plugin',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        grafana,  # MySQL is automatically included as transitive dep
        labels=['app'],
    )

if __file__ == config.main_path:
    master = cc_generate_master_compose(cc_get_plugin(), [])
    cc_docker_compose(master)
```

**Output**:
```
Flattening dependency tree:
  Total dependencies: 3
    - mysql (from grafana's dependencies)
    - grafana
    - dashboard-plugin (local)
```

### Example 2: CLI Plugins - Runtime Composition

**Scenario**: Run multiple plugins together without modifying code.

```bash
# Start with just your plugin
tilt up

# Add another plugin from a sibling directory
tilt up -- ../monitoring-plugin

# Add plugins by name (looked up in parent directory)
tilt up -- monitoring-plugin analytics-plugin

# Mix plugins with profiles
tilt up -- --profile=dev monitoring-plugin

# Use fully qualified paths
tilt up -- /absolute/path/to/plugin

# Load from git repositories
tilt up -- https://github.com/myorg/shared-plugin.git
```

Each CLI plugin brings its own dependencies, which are automatically de-duplicated:

```python
# monitoring-plugin also needs grafana
# Result: Only one grafana instance, deps merged
```

### Example 3: Profile-Based Composition

**Scenario**: Different environments need different dependencies.

```python
# analytics-service/Tiltfile

# Core infrastructure (always included)
grafana = cc_composable(name='grafana', url='https://github.com/grafana/composables')

# Development tools (only in dev/full profiles)
jaeger = cc_composable(
    name='jaeger',
    url='https://github.com/grafana/composables',
    profiles=['dev', 'full'],
    labels=['observability'],
)

# SQL test databases (only in sql/full profiles)
clickhouse = cc_composable(
    name='clickhouse',
    url='https://github.com/grafana/composables',
    profiles=['sql', 'full'],
    labels=['sql-test'],
)

postgres = cc_composable(
    name='postgres-test',
    url='https://github.com/grafana/composables',
    profiles=['sql', 'full'],
    labels=['sql-test'],
)

def cc_get_plugin():
    return cc_local_composable(
        'analytics-service',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        grafana, jaeger, clickhouse, postgres,
        labels=['app'],
    )

if __file__ == config.main_path:
    master = cc_generate_master_compose(cc_get_plugin(), cc_parse_cli_plugins(os.path.dirname(__file__)))
    cc_docker_compose(master)
```

**Usage**:
```bash
# Minimal (just grafana)
tilt up

# Development with observability
tilt up -- --profile=dev

# SQL testing
tilt up -- --profile=sql

# Everything
tilt up -- --profile=full
```

### Example 4: Override Resolution with compose_overrides()

**Scenario**: Customize infrastructure components for your plugin's needs.

```python
# service-model/Tiltfile

k3s = cc_composable(
    name='k3s-apiserver',
    url='https://github.com/grafana/composables',
    imports=['register_crds'],
    labels=['k8s'],
)

mysql = cc_composable(
    name='mysql',
    url='https://github.com/grafana/composables',
    labels=['infra'],
)

grafana = cc_composable(
    name='grafana',
    url='https://github.com/grafana/composables',
    labels=['app'],
)

def cc_get_plugin():
    return cc_local_composable(
        'service-model',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        k3s, mysql, grafana,
        labels=['app'],
        modifications=[
            # Register CRDs from your plugin
            k3s.register_crds(crd_paths=[os.path.dirname(__file__) + '/definitions']),

            # Increase MySQL connections for your workload
            mysql.compose_overrides({
                'services': {
                    'db': {
                        'command': '--max_connections=1000',
                        'environment': {
                            'MYSQL_MAX_ALLOWED_PACKET': '256M',
                        },
                    },
                },
            }),

            # Configure Grafana to use k8s aggregated API
            grafana.compose_overrides({
                'services': {
                    'grafana': {
                        'environment': {
                            'GF_GRAFANA_APISERVER_REMOTE_SERVICES_FILE': '/etc/kubernetes/pki/aggregator-config.yaml',
                            'GF_LOG_LEVEL': 'debug',
                        },
                    },
                },
            }),
        ],
    )

if __file__ == config.main_path:
    master = cc_generate_master_compose(cc_get_plugin(), cc_parse_cli_plugins(os.path.dirname(__file__)))
    cc_docker_compose(master)
```

**Key Points**:
- Modifications are declared in `cc_get_plugin()` - works as orchestrator OR CLI plugin
- Multiple modifications to same dependency are merged
- Overrides are type-safe and IDE-friendly

### Example 5: Wire-When Rules for Smart Integration

**Scenario**: Your composable knows how to integrate with other components when they're present.

```python
# In your composable's Tiltfile (e.g., grafana/Tiltfile)

def cc_get_plugin():
    return cc_local_composable(
        'grafana',
        os.path.dirname(__file__) + '/grafana.yaml',
        # ... dependencies ...
    )

def cc_wire_when():
    """
    Define how grafana should wire itself to other components.
    These rules only activate when the trigger component is present.
    """
    return {
        'k3s-apiserver': {
            # When k3s is present, wire grafana to it
            'services': {
                'grafana': {
                    'depends_on': ['k3s-apiserver'],
                    'volumes': [
                        'k3s-certs:/etc/kubernetes/pki:ro',
                        'k3s-output:/etc/grafana:ro',
                    ],
                    'environment': {
                        'KUBECONFIG': '/etc/grafana/kubeconfig.yaml',
                        'GF_GRAFANA_APISERVER_HOST': 'https://k3s-apiserver:6443',
                    },
                },
            },
        },
        'nats': {
            # When nats is present, configure grafana to use it
            'services': {
                'grafana': {
                    'depends_on': ['nats'],
                    'environment': {
                        'GF_NATS_SERVER': 'nats://nats:4222',
                    },
                },
            },
        },
        'jaeger': {
            # When jaeger is present, configure grafana's tracing
            'services': {
                'grafana': {
                    'environment': {
                        'JAEGER_AGENT_HOST': 'jaeger',
                        'JAEGER_AGENT_PORT': '6831',
                    },
                },
            },
        },
    }
```

**Result**: Grafana automatically configures itself based on what else is in the environment. No central coordination needed!

### Example 6: Bound Helper Functions

**Scenario**: Create reusable configuration functions for your composable.

```python
# In k3s-apiserver/Tiltfile

def register_crds(crd_paths):
    """
    Helper function that plugins can call to register CRD directories.
    Returns compose_overrides for mounting CRD paths into crd-loader service.
    """
    if type(crd_paths) != 'list':
        fail("crd_paths must be a list")

    volumes = []
    for path in crd_paths:
        # Generate unique volume mount for each CRD path
        path_hash = str(hash(path))[-6:]
        mount_path = '/crds/crds-' + path_hash
        volumes.append(path + ':' + mount_path + ':ro')

    return {
        'services': {
            'crd-loader': {
                'volumes': volumes,
            },
        },
    }

def cc_get_plugin():
    return cc_local_composable(
        'k3s-apiserver',
        os.path.dirname(__file__) + '/k3s-apiserver.yaml',
    )

# In your plugin's Tiltfile
k3s = cc_composable(
    name='k3s-apiserver',
    url='https://github.com/grafana/composables',
    imports=['register_crds'],  # Bind this helper
)

def cc_get_plugin():
    return cc_local_composable(
        'my-operator',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        k3s,
        modifications=[
            # Call bound helper - it knows its target automatically
            k3s.register_crds(crd_paths=[
                os.path.dirname(__file__) + '/crds',
                os.path.dirname(__file__) + '/definitions',
            ]),
        ],
    )
```

**Benefits**:
- Encapsulates complex logic in the composable
- Type-safe API with autocomplete
- Automatically targets the correct dependency

### Example 7: Plugin-Declared Modifications (Symmetric Orchestration)

**Scenario**: Your plugin should work the same whether it's the orchestrator or a CLI plugin.

```python
# service-model/Tiltfile - Works in BOTH modes

k3s = cc_composable(
    name='k3s-apiserver',
    url='https://github.com/grafana/composables',
    imports=['register_crds'],
)

grafana = cc_composable(
    name='grafana',
    url='https://github.com/grafana/composables',
)

def cc_get_plugin():
    """
    This function is called in ALL modes:
    - When service-model is orchestrator (tilt up in this directory)
    - When service-model is CLI plugin (tilt up -- service-model from elsewhere)

    Modifications declared here work in BOTH cases!
    """
    return cc_local_composable(
        'service-model',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        k3s, grafana,
        labels=['app'],
        modifications=[
            # These modifications travel with the plugin
            k3s.register_crds(crd_paths=[os.path.dirname(__file__) + '/definitions']),

            grafana.compose_overrides({
                'services': {
                    'grafana': {
                        'environment': {
                            'GF_CUSTOM_SETTING': 'value',
                        },
                    },
                },
            }),
        ],
    )

if __file__ == config.main_path:
    # Orchestrator mode - just pass through to compose_composer
    master = cc_generate_master_compose(
        cc_get_plugin(),  # Plugin brings its own modifications
        cc_parse_cli_plugins(os.path.dirname(__file__)),
        modifications=[],  # Usually empty - plugins declare their own
    )
    cc_docker_compose(master)
```

**Test both modes**:
```bash
# Mode 1: service-model as orchestrator
cd service-model
tilt up

# Mode 2: service-model as CLI plugin
cd other-plugin
tilt up -- ../service-model

# In both cases, service-model's CRDs are loaded and Grafana is configured!
```

## Complete Example

### Plugin with Dependencies and CRDs

```python
# my-operator/Tiltfile

# Allow any k8s context
allow_k8s_contexts(k8s_context())

# Load compose_composer
v1alpha1.extension_repo(name='grafana-tilt-extensions', url='https://github.com/grafana/tilt-extensions', ref='compose-composer')
v1alpha1.extension(name='compose_composer', repo_name='grafana-tilt-extensions', repo_path='compose_composer')
load('ext://compose_composer', 'cc_composable', 'cc_local_composable', 'cc_generate_master_compose', 'cc_parse_cli_plugins')

# ============================================================================
# Core Dependencies
# ============================================================================

COMPOSABLES_URL = 'https://github.com/grafana/composables@main'

k3s = cc_composable(
    name='k3s-apiserver',
    url=COMPOSABLES_URL,
    imports=['register_crds'],
)

mysql = cc_composable(name='mysql', url=COMPOSABLES_URL)
grafana = cc_composable(name='grafana', url=COMPOSABLES_URL)

# ============================================================================
# Plugin Definition
# ============================================================================

def cc_get_plugin():
    """Returns this plugin's struct for compose_composer."""
    return cc_local_composable(
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

## Migration Support

compose_composer includes automatic migration detection for repositories transitioning from legacy Tiltfiles (e.g., k8s-based) to compose_composer Tiltfiles.

### The Migration Problem

When migrating a repository to compose_composer, you may have:
- A legacy `Tiltfile` at the repo root (k8s-based or other)
- A new `cc/Tiltfile` for compose_composer

Tilt's extension mechanism expects a `Tiltfile` at `repo_path`, but during migration you need both files to coexist.

### Automatic Detection

compose_composer automatically detects this migration scenario:

1. After downloading/caching the extension repo
2. Checks if `cc/Tiltfile` exists alongside the default `Tiltfile`
3. If both exist, automatically uses `cc/Tiltfile`

```
my-composable/
  Tiltfile           # Legacy (k8s-based)
  cc/
    Tiltfile         # New compose_composer version
    compose.yaml
```

When this structure is detected, you'll see:
```
[compose_composer] Migration detected for 'my-composable': using cc/Tiltfile
```

### Migration Workflow

1. **Create the cc/ directory** in your composable:
   ```bash
   mkdir cc
   ```

2. **Add your compose_composer Tiltfile**:
   ```python
   # cc/Tiltfile
   load('ext://compose_composer', 'cc_init')

   def cc_export(cc):
       return cc.create('my-composable', './compose.yaml')
   ```

3. **Add your compose file**:
   ```yaml
   # cc/compose.yaml
   services:
     my-service:
       image: my-image
   ```

4. **Test the migration** - compose_composer will automatically use `cc/Tiltfile`

5. **Complete the migration** - once all consumers have migrated:
   - Move `cc/Tiltfile` to root `Tiltfile`
   - Move `cc/compose.yaml` to root
   - Remove `cc/` directory

### Cross-Platform Support

Migration detection works on all platforms by using Tilt's extension cache:

| Platform | Cache Location |
|----------|----------------|
| Linux | `~/.local/share/tilt-dev/tilt_modules/` |
| macOS | `~/Library/Application Support/tilt-dev/tilt_modules/` |
| Windows | `%LOCALAPPDATA%/tilt-dev/tilt_modules/` |

The `XDG_DATA_HOME` environment variable can override the cache location on any platform.

### Collection Repositories

For collection repositories (multiple composables in one repo), migration detection checks within each composable's subdirectory:

```
composables/               # Collection repo
  mysql/
    Tiltfile              # Legacy
    cc/
      Tiltfile            # New (auto-detected)
      compose.yaml
  grafana/
    Tiltfile              # Already migrated (no cc/)
```

## Troubleshooting

### "extensions already registered" error

This can happen if an extension is registered twice. The `cc_composable()` function handles this automatically by using unique repo names.

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

## Known Issues with Tilt

### Problem: Tilt Doesn't Respect docker-compose Completion Conditions

Some Tiltfiles use `local_resource` to run one-shot services (like plugin-precache) before docker-compose services start, because Tilt doesn't respect docker-compose's `depends_on: service_completed_successfully` conditions.

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
