# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

compose_composer is a Tilt extension (~1900 lines of Starlark) that enables dynamic, runtime assembly of Docker Compose environments from modular, reusable components called "composables." It solves the rigidity of static Docker Compose files by allowing LEGO-block-style composition of dev environments.

## Core Concepts

**Composables**: Tilt extensions that wrap a docker-compose file and optionally expose helper functions. Any composable can import other composables, creating symmetric orchestration.

**Symmetric Orchestration**: Any plugin can be the orchestrator. The result is the same regardless of which plugin initiates composition because wiring is declarative (via `cc_wire_when()`) rather than imperative.

**Wire-When Rules**: Declarative rules that define how components wire themselves together when other dependencies are present. Defined via `cc_wire_when()` export.

## Architecture

The codebase is organized into a modular structure:

```
compose_composer/
├── Tiltfile                    # Main orchestration (~1,510 lines)
└── lib/
    ├── utils.tilt              # Pure utility functions (330 lines)
    ├── profiles.tilt           # Profile activation/filtering (105 lines)
    ├── dependency_graph.tilt   # Graph traversal (233 lines)
    └── wiring.tilt             # Declarative wiring (297 lines)
```

### Module Design Patterns

**Struct Namespace Pattern**: All modules export a single struct to provide namespace-like access:
```python
load('./lib/utils.tilt', 'util')
result = util.deep_merge(base, override)  # Clean namespace syntax
```

**Dependency Injection**: Modules receive dependencies as parameters rather than loading them directly:
```python
dependency_graph.flatten(root, cli_plugins, util, profiles, active_profiles)
```

This avoids circular dependencies and keeps modules decoupled.

### Library Modules

**lib/utils.tilt** - Pure utility functions with no external dependencies:
- `util.deep_merge()` - Deep merge with list concatenation and special env var handling
- `util.is_url()` - URL detection for git@ and :// patterns
- `util.parse_url_with_ref()` - Parse composable URLs with optional @ref
- `util.is_named_volume()` - Detect Docker named volumes vs bind mounts
- `util.should_concatenate_string()` - Determine if env vars should concatenate

**lib/profiles.tilt** - Profile management:
- `profiles.get_active()` - Get active profiles from CLI args or CC_PROFILES env var
- `profiles.is_included()` - Check if dependency matches active profiles

**lib/dependency_graph.tilt** - Dependency tree operations:
- `dependency_graph.struct_to_dict()` - Convert plugin structs to dicts
- `dependency_graph.flatten()` - Depth-first tree flattening with deduplication
- `dependency_graph.apply_modifications()` - Apply cross-plugin compose_overrides

**lib/wiring.tilt** - Declarative wiring (wire-when) system:
- `wiring.collect_rules()` - Collect cc_wire_when() exports from all plugins
- `wiring.apply_rules()` - Apply wiring rules when trigger dependencies are present

### Public API (Fluent API Pattern)

The **only** public entry point is `cc_init()`. All other functions are accessed through the returned `cc` struct:

```python
# Initialize compose_composer (ONLY public function)
cc = cc_init(
    name='my-project',                           # Docker Compose project name
    composables_url='https://github.com/...',    # Optional: default URL for cc.use()
    staging_dir='./.cc',                          # Optional: where to stage files
)

# All operations through cc struct
mysql = cc.use('mysql')                           # Load remote composable (was cc_import)
plugin = cc.create('my-plugin', './compose.yaml', mysql)  # Create local plugin (was cc_create)
cli_plugins = cc.parse_cli_plugins()              # Parse CLI args (was cc_parse_cli_plugins)
master = cc.generate_master_compose(plugin, cli_plugins)  # Generate master (was cc_generate_master_compose)
cc.docker_compose(master)                         # Start containers (was cc_docker_compose)
profiles = cc.get_active_profiles()               # Get active profiles (was cc_get_active_profiles)
```

**Design Rationale**: The fluent API pattern ensures context (project name, URLs, directories) is captured at initialization and automatically applied to all operations. This prevents errors from forgetting to pass context and provides a cleaner interface.

### Processing Pipeline (in cc.generate_master_compose)

1. Flatten dependency tree with profile filtering
2. Collect plugin-declared modifications from `modifications` parameter
3. Collect wire-when rules via `cc_wire_when()` exports
4. Apply modifications to target dependencies
5. Apply wire-when rules to compose files
6. Stage modified compose files to `.cc/` directory
7. Generate master compose with `include` directives

### Key Data Structures

**Plugin struct** (from cc_create/cc_import):
- `name`, `compose_path`, `dependencies`, `profiles`, `labels`, `modifications`
- `_is_local`, `_from_cli`, `_symbols`, `_compose_overrides_param`
- Bound methods: `compose_overrides()`

**Wire-when rule format**:
```python
{
    'trigger-dep-name': {
        'services': {
            'service-to-modify': {
                'depends_on': ['trigger-dep-name'],
                'volumes': ['vol:/path'],
                'environment': {'KEY': 'value'},
            }
        }
    }
}
```

## Testing

```bash
# Run all tests
make test

# Or directly
cd test && tilt ci
```

Tests are in `test/Tiltfile` using a custom test framework with `assert_equals()`, `assert_true()`, `assert_in()`. Internal functions are exposed via `cc_test_exports()` for unit testing.

## Development Patterns

### Working with Modules

**When adding utilities:**
- Add to `lib/utils.tilt` if it's a pure function with no external dependencies
- Export via the `util` struct: `util = struct(..., new_func = _new_func)`
- Follow the underscore prefix pattern for private functions

**When adding profile logic:**
- Add to `lib/profiles.tilt` if it relates to profile activation or filtering
- Export via the `profiles` struct

**When modifying dependency graph:**
- Edit `lib/dependency_graph.tilt` for tree traversal or struct conversion logic
- Remember to use dependency injection for util and profiles modules

**When modifying wiring:**
- Edit `lib/wiring.tilt` for wire-when rule collection or application
- Uses dependency injection for util module

**Test compatibility:**
- Test wrapper functions in main Tiltfile maintain old signatures for backward compatibility
- Don't modify test wrapper functions unless test signatures need to change

### Adding New Features

1. Implement in main `Tiltfile`
2. Export internal functions via `cc_test_exports()` if needed for testing
3. Add tests to `test/Tiltfile`
4. Update documentation in `docs/README.md`

### Common Modification Patterns

**Deep merge semantics**:
- Dicts merge recursively
- Lists concatenate (avoiding duplicates)
- Certain env vars (WEBHOOK_OPERATORS, GF_FEATURE_TOGGLES_ENABLE) concatenate by comma
- URLs (containing `://`) always replace, never concatenate
- Scalars replace (last wins)

**Environment variable concatenation** (in `_CONCAT_ENV_VARS`):
- `WEBHOOK_OPERATORS`
- `API_GROUPS`
- `GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS`
- `GF_FEATURE_TOGGLES_ENABLE`

### Extension Export Requirements (Plugin Callbacks)

These are **callbacks** implemented by plugins, not part of the public API:

**Required:**
- `cc_export(cc=None)` - Returns plugin struct. When `cc` is provided (orchestrator context), use `cc.create()` and `cc.use()` to build dependencies. Otherwise, manually construct the struct.

**Optional:**
- `cc_wire_when(cc=None)` - Returns conditional wiring rules for declarative dependency wiring
- `cc_setup(plugin_ctx)` - Host-side setup called by `cc.generate_master_compose()` before processing
- `process_accumulated_modifications(mods, orchestrator_dir)` - Process markers from other plugins

**Example plugin with cc context:**
```python
def cc_export(cc):
    """Export plugin using fluent API when orchestrator provides cc context."""
    mysql = cc.use('mysql')
    redis = cc.use('redis')
    return cc.create('my-plugin', './compose.yaml', mysql, redis)
```

## Key Files

- `Tiltfile` - Main extension implementation and public API (~1,600 lines)
- `lib/utils.tilt` - Utility functions (deep merge, URL parsing, volume utilities)
- `lib/profiles.tilt` - Profile activation and filtering logic
- `lib/dependency_graph.tilt` - Dependency tree traversal and struct conversion
- `lib/wiring.tilt` - Declarative wiring system (wire-when rules)
- `test/Tiltfile` - Test suite (131 unit tests + 12 integration tests)
- `test_migration/` - Migration detection test harness and fake repos
- `docs/README.md` - User documentation
- `REFACTORING_SUMMARY.md` - Documentation of modular refactoring (Phases 1-5)
- `future-investigations/` - Design documents for future features

## Migration Detection

compose_composer supports automatic detection of migration scenarios where both a legacy `Tiltfile` and a new `cc/Tiltfile` exist in a composable repository.

### Internal Functions

These functions are in main `Tiltfile` and exported via `cc_test_exports()`:

- `_get_tilt_data_dir()` - Cross-platform detection of Tilt's extension cache directory
  - Linux: `~/.local/share/tilt-dev/tilt_modules/`
  - macOS: `~/Library/Application Support/tilt-dev/tilt_modules/`
  - Windows: `%LOCALAPPDATA%/tilt-dev/tilt_modules/`
  - Override: `$XDG_DATA_HOME/tilt-dev/tilt_modules/`

- `_get_tilt_module_cache_path(url)` - Construct cache path for extension URL
  - For `file://` URLs: returns the local path directly
  - For remote URLs: returns `{tilt_data_dir}/{url_without_scheme}`

- `_detect_tiltfile_path(cache_path, default_repo_path)` - Check if `cc/Tiltfile` exists
  - If `cc/Tiltfile` exists, returns `'cc'` or `'{default_repo_path}/cc'`
  - Otherwise returns `default_repo_path`

### Integration Point

Migration detection is integrated into `_cc_import_with_context()`:
1. After `extension_repo()` downloads/caches the repo
2. Construct cache path with `_get_tilt_module_cache_path(url)`
3. Detect actual path with `_detect_tiltfile_path(cache_path, repo_path)`
4. Pass detected path to `extension()`

### Test Files

- `test_migration/Tiltfile` - Test harness with multiple test modes
- `test_migration/fake_migrating_repo/Tiltfile` - Legacy file (fails if loaded)
- `test_migration/fake_migrating_repo/cc/Tiltfile` - New CC version (succeeds)

## Environment Variables

- `COMPOSABLES_URL` - Default URL for `cc.use()` when `url` parameter is not provided (default: `https://github.com/grafana/composables@main`)
- `CC_PROFILES` - Comma-separated list of profiles to activate
- `CC_SKIP_SETUP` - Skip calling `cc_setup()` for all plugins
- `CC_DRY_RUN` - Generate files but skip starting containers

## Starlark Considerations

This is Starlark code, not Python. Key differences:
- No `import` statements, use `load()`
- No classes, use `struct()`
- Type checking: `type(x) == 'dict'` not `isinstance()`
- No `try/except`, use validation with `fail()`
- `hasattr()` for struct field checking
- YAML round-trip for deep copy: `decode_yaml(encode_yaml(obj))`
- **Cannot export underscore-prefixed names**: Use struct pattern to export private functions
- **Cannot load() in functions**: Use dependency injection to pass modules as parameters
- **Module pattern**: Export single struct with all public functions for namespace syntax
