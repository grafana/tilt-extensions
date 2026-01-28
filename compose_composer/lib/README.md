# compose_composer Library Modules

This directory contains the modular components of compose_composer, extracted from the original monolithic Tiltfile to improve maintainability and testability.

## Module Overview

```
lib/
├── utils.tilt              # Pure utility functions (330 lines)
├── profiles.tilt           # Profile activation/filtering (105 lines)
├── dependency_graph.tilt   # Graph traversal (233 lines)
└── wiring.tilt             # Declarative wiring (297 lines)
```

**Dependency Graph:**
```
utils.tilt (no dependencies)
    ↓
profiles.tilt (no dependencies)
    ↓
dependency_graph.tilt (requires: util, profiles)
    ↓
wiring.tilt (requires: util)
```

All modules follow the **struct namespace pattern** for clean imports:
```python
load('./lib/utils.tilt', 'util')
result = util.deep_merge(base, override)
```

## utils.tilt

**Purpose**: Pure utility functions with no external dependencies. Core operations for deep merging, URL parsing, and volume detection.

**Exports** (via `util` struct):

### Data Structure Operations

- `util.deep_merge(base, override)` - Deep merge override into base
  - Dicts merge recursively
  - Lists concatenate (avoiding duplicates)
  - Scalars replace (last wins)
  - Special handling for concatenating environment variables
  - URLs (containing `://`) always replace, never concatenate

- `util.deep_copy(obj)` - Create independent copy using YAML round-trip
  - Returns: Deep copy of obj (dicts, lists, primitives)

### String Operations

- `util.should_concatenate_string(key, base, override)` - Determine if strings should concatenate
  - Returns: True if strings should be comma-concatenated instead of replaced
  - Handles: GF_FEATURE_TOGGLES_ENABLE, WEBHOOK_OPERATORS, etc.
  - Never concatenates URLs (containing `://`)

- `util.CONCAT_ENV_VARS` - List of environment variable names that concatenate:
  - `WEBHOOK_OPERATORS`
  - `API_GROUPS`
  - `GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS`
  - `GF_FEATURE_TOGGLES_ENABLE`

### URL Operations

- `util.is_url(s)` - Check if string is a URL
  - Returns: True if contains `://` or starts with `git@`

- `util.parse_url_with_ref(url_with_ref, default_ref='main')` - Parse composable URL
  - Input: `"https://github.com/org/repo@branch"` or `"https://github.com/org/repo"`
  - Returns: `{'url': '...', 'ref': '...'}`

### Volume Operations

- `util.is_named_volume(source)` - Detect Docker named volumes vs bind mounts
  - Returns: True if source is a named volume (not path, not env var)
  - Detects: Absolute paths (`/`), relative paths (`./`), env vars (`${VAR}`), UNC (`\\`)

- `util.parse_volume_mount(volume_spec)` - Parse Docker volume mount spec
  - Input: `"source:target:mode"` or `"target"`
  - Returns: `{'source': '...', 'target': '...', 'mode': '...'}`

- `util.validate_volume_mounts(volumes, context)` - Validate volume mount specifications
  - Checks for duplicate mount points
  - Validates volume spec format

**Usage Example:**
```python
load('./lib/utils.tilt', 'util')

# Deep merge configurations
config = util.deep_merge(base_config, override_config)

# Parse composable URL
parsed = util.parse_url_with_ref('https://github.com/grafana/composables@v1.2.3')
# Returns: {'url': 'https://github.com/grafana/composables', 'ref': 'v1.2.3'}

# Check if volume is named
if util.is_named_volume('grafana-data'):
    compose_yaml['volumes']['grafana-data'] = None
```

## profiles.tilt

**Purpose**: Profile activation and filtering logic. Determines which dependencies to include based on active profiles (follows Docker Compose profiles model).

**Exports** (via `profiles` struct):

- `profiles.get_active(cfg)` - Get list of active profiles
  - Checks: CLI args (`--profile=dev`), then `CC_PROFILES` environment variable
  - Returns: List of profile names (empty list if none active)
  - Format: `CC_PROFILES="dev,test"` becomes `['dev', 'test']`

- `profiles.is_included(dep_profiles, active_profiles)` - Check if dependency should be included
  - Args:
    - `dep_profiles`: List of profiles declared by dependency (empty = always included)
    - `active_profiles`: List of currently active profiles
  - Returns: True if dependency should be included
  - Logic:
    - No profiles on dependency → always included
    - Has profiles but none active → excluded
    - Any profile matches → included

**Usage Example:**
```python
load('./lib/profiles.tilt', 'profiles')

# Get active profiles from CLI or environment
active = profiles.get_active(config.parse)
# Returns: ['dev', 'monitoring'] if CC_PROFILES="dev,monitoring"

# Check if dependency should be included
if profiles.is_included(['dev', 'test'], active):
    dependencies.append(dev_plugin)
```

**Profile Scenarios:**
```python
# Dependency with no profiles - always included
profiles.is_included([], ['dev']) → True
profiles.is_included([], []) → True

# Dependency with profiles, none active - excluded
profiles.is_included(['prod'], []) → False

# Dependency with profiles, match found - included
profiles.is_included(['dev', 'test'], ['dev']) → True

# Dependency with profiles, no match - excluded
profiles.is_included(['prod'], ['dev']) → False
```

## dependency_graph.tilt

**Purpose**: Dependency tree operations including struct conversion, tree flattening, and modification application. Implements depth-first traversal with deduplication.

**Dependencies**: Requires `util` and `profiles` modules via dependency injection.

**Exports** (via `dependency_graph` struct):

- `dependency_graph.struct_to_dict(dep_struct, util)` - Convert plugin struct to dict
  - Extracts: name, compose_path, url, ref, repo_path, dependencies, profiles, labels
  - Handles: Both local and remote plugins
  - Converts: modifications from method or list format
  - Returns: Dict representation suitable for processing

- `dependency_graph.flatten(root, cli_plugins, util, profiles_module, active_profiles, seen_names=None)` - Flatten dependency tree
  - Performs: Depth-first traversal
  - Features:
    - Deduplication (first occurrence wins)
    - Profile filtering
    - Compose_overrides merging for duplicates
  - Returns: List of dependency dicts in dependency-first order
  - Example order: `[db, cache, plugin-a, plugin-b, root]`

- `dependency_graph.apply_modifications(dependencies, modifications, util)` - Apply cross-plugin compose_overrides
  - Deep merges modifications into target dependencies
  - Warns if target not found or _target missing
  - Modifies dependencies list in place

**Usage Example:**
```python
load('./lib/dependency_graph.tilt', 'dependency_graph')
load('./lib/utils.tilt', 'util')
load('./lib/profiles.tilt', 'profiles')

# Flatten dependency tree with profile filtering
dependencies = dependency_graph.flatten(
    root_plugin,
    cli_plugins,
    util,              # Inject util module
    profiles,          # Inject profiles module
    active_profiles    # Current active profiles
)

# Apply cross-plugin modifications
dependency_graph.apply_modifications(dependencies, all_modifications, util)

# Convert struct to dict if needed
if type(plugin) == 'struct':
    plugin_dict = dependency_graph.struct_to_dict(plugin, util)
```

**Dependency Injection Pattern:**
```python
# BAD: Can't load in function (Starlark limitation)
def flatten(...):
    load('./lib/utils.tilt', 'util')  # Error: load not allowed in function

# GOOD: Inject as parameter
def flatten(root, cli_plugins, util, profiles_module, ...):
    result = util.deep_merge(a, b)  # util passed as parameter
```

## wiring.tilt

**Purpose**: Declarative wiring system (wire-when rules) that enables symmetric orchestration. Allows plugins to declare "if dependency X is loaded, wire me to X".

**Dependencies**: Requires `util` module via dependency injection.

**Exports** (via `wiring` struct):

- `wiring.collect_rules(loaded_deps, cc=None)` - Collect wire_when rules from all plugins
  - Calls: `cc_wire_when()` export from each plugin
  - Args:
    - `loaded_deps`: List of loaded dependency dicts with 'symbols' field
    - `cc`: Optional orchestrator context to pass to cc_wire_when(cc)
  - Returns: Dict mapping trigger_dep_name to list of rule sets
  - Format:
    ```python
    {
        'database': [
            {'source_dep': 'plugin-a', 'rules': {...}},
            {'source_dep': 'plugin-b', 'rules': {...}}
        ]
    }
    ```

- `wiring.apply_rules(compose_yaml, dep_name, wire_when_rules, loaded_dep_names, util)` - Apply wiring rules
  - Modifies: compose_yaml dict in place
  - Applies: depends_on, volumes, environment, labels
  - Only applies rules when trigger dependency is present in loaded_dep_names
  - Handles:
    - Volume deduplication by mount point
    - Named volume detection and top-level volume section updates
    - Environment variable concatenation (via util.should_concatenate_string)
    - List-to-dict conversion for environment and labels

**Wire-When Rule Format:**
```python
# In plugin-b/Tiltfile
def cc_wire_when():
    return {
        'database': {  # When 'database' is loaded
            'services': {
                'api': {  # Wire 'api' service in this plugin
                    'depends_on': ['database'],
                    'volumes': ['db-config:/etc/config:ro'],
                    'environment': {
                        'DB_HOST': 'database',
                        'DB_PORT': '5432'
                    },
                    'labels': {
                        'com.example.wired-to': 'database'
                    }
                }
            }
        }
    }
```

**Usage Example:**
```python
load('./lib/wiring.tilt', 'wiring')
load('./lib/utils.tilt', 'util')

# Collect rules from all plugins
wire_when_rules = wiring.collect_rules(loaded_deps, cc=cc)

# Apply rules to each plugin's compose file
for dep in dependencies:
    compose_content = read_yaml(dep['compose_path'])
    compose_content = wiring.apply_rules(
        compose_content,
        dep['name'],
        wire_when_rules,
        loaded_dep_names,
        util  # Inject util for volume and env var handling
    )
    write_yaml('.cc/' + dep['name'] + '.yaml', compose_content)
```

**Supported Modifications:**

- **depends_on** - Service dependencies (list or dict format)
- **volumes** - Volume mounts (auto-detects and declares named volumes)
- **environment** - Environment variables (handles list format, concatenates special vars)
- **labels** - Service labels (handles list format)

**Symmetric Orchestration:**

Wire-when rules enable any plugin to be the orchestrator:

```python
# Plugin A orchestrates: loads B + database
# Plugin B orchestrates: loads A + database
# Plugin C orchestrates: loads A + B + database

# Result is the same in all cases because wiring is declarative
# Plugin B declares: "if database is loaded, wire me to it"
# Not: "imperatively import and configure database"
```

## Design Patterns

### Struct Namespace Pattern

All modules export a single struct to provide namespace-like access:

```python
# In module file (e.g., lib/utils.tilt)
def _private_function(x):
    return x + 1

def _another_function(y):
    return y * 2

# Export single struct - only this is public
util = struct(
    public_name = _private_function,
    another = _another_function,
)
```

```python
# In Tiltfile
load('./lib/utils.tilt', 'util')

result = util.public_name(5)  # Clean namespace syntax
```

**Why this pattern?**
- Starlark cannot export underscore-prefixed names directly
- Provides clear namespace (util.deep_merge vs deep_merge)
- All functions stay private (underscore prefix) except the exported struct

### Dependency Injection Pattern

Modules receive dependencies as parameters rather than loading them directly:

```python
# In lib/dependency_graph.tilt
def _flatten(root, cli_plugins, util, profiles_module, active_profiles, seen_names=None):
    """
    Note: util and profiles_module are injected as parameters
    """
    merged = util.deep_merge(a, b)  # Use injected util
    if profiles_module.is_included(dep_profiles, active_profiles):
        ...
```

```python
# In Tiltfile
load('./lib/dependency_graph.tilt', 'dependency_graph')
load('./lib/utils.tilt', 'util')
load('./lib/profiles.tilt', 'profiles')

# Inject dependencies when calling
result = dependency_graph.flatten(
    root,
    cli_plugins,
    util,              # Inject util module
    profiles,          # Inject profiles module
    active_profiles    # Inject state
)
```

**Why this pattern?**
- Starlark cannot call `load()` inside functions
- Avoids circular dependency issues
- Makes dependencies explicit
- Improves testability

### Test Wrapper Pattern

Main Tiltfile provides wrapper functions that maintain old test signatures:

```python
# In Tiltfile (for test compatibility)
def _flatten_dependency_tree(root, cli_plugins, seen_names=None, active_profiles=None):
    """Wrapper for tests - maintains old signature."""
    if active_profiles == None:
        active_profiles = _active_profiles
    return dependency_graph.flatten(root, cli_plugins, util, profiles, active_profiles, seen_names)
```

**Why this pattern?**
- 122 unit tests use old function signatures
- Avoids modifying all test call sites
- Wrappers inject dependencies automatically
- Tests remain unchanged and passing

## Module Dependencies

The modules have clear dependency relationships:

```
utils.tilt
├─ No dependencies (pure functions)
│
profiles.tilt
├─ No dependencies (self-contained)
│
dependency_graph.tilt
├─ Requires: util (for deep_merge)
├─ Requires: profiles (for is_included)
│
wiring.tilt
├─ Requires: util (for volume/env var handling)
│
Tiltfile
├─ Loads: util, profiles, dependency_graph, wiring
└─ Provides: test wrappers, orchestration logic
```

**Bottom-up extraction order:**
1. utils.tilt (no dependencies)
2. profiles.tilt (no dependencies)
3. dependency_graph.tilt (depends on util, profiles)
4. wiring.tilt (depends on util)

This order ensures dependencies are available when needed.

## Testing

All modules are tested via the main test suite:

```bash
cd test && tilt ci
```

**Test coverage:**
- utils.tilt: 30+ tests for deep_merge, URL parsing, volume detection
- profiles.tilt: 8 tests for activation and filtering
- dependency_graph.tilt: 15+ tests for flattening and modifications
- wiring.tilt: 8 tests for rule collection and application
- Integration tests: 12 end-to-end tests

**Total: 134 tests (122 unit + 12 integration)**

Test wrappers in main Tiltfile maintain backward compatibility with existing test signatures.

## Further Reading

- **REFACTORING_SUMMARY.md** - Detailed documentation of refactoring phases
- **docs/README.md** - User documentation for compose_composer
- **test/Tiltfile** - Test suite with examples of all functions
