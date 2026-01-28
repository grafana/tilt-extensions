# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

compose_composer is a Tilt extension (~1900 lines of Starlark) that enables dynamic, runtime assembly of Docker Compose environments from modular, reusable components called "composables." It solves the rigidity of static Docker Compose files by allowing LEGO-block-style composition of dev environments.

## Core Concepts

**Composables**: Tilt extensions that wrap a docker-compose file and optionally expose helper functions. Any composable can import other composables, creating symmetric orchestration.

**Symmetric Orchestration**: Any plugin can be the orchestrator. The result is the same regardless of which plugin initiates composition because wiring is declarative (via `get_wire_when()`) rather than imperative.

**Wire-When Rules**: Declarative rules that define how components wire themselves together when other dependencies are present. Defined via `get_wire_when()` export.

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
- `wiring.collect_rules()` - Collect get_wire_when() exports from all plugins
- `wiring.apply_rules()` - Apply wiring rules when trigger dependencies are present

### Key Functions (Tiltfile)

- `cc_import(name, ...)` - Load a remote composable and return a plugin struct (URL defaults to `COMPOSABLES_URL` env var or `https://github.com/grafana/composables@main`)
- `cc_create(name, compose_path, *deps, ...)` - Declare a local plugin with dependencies
- `cc_parse_cli_plugins(tiltfile_dir)` - Parse CLI args into plugin structs
- `cc_generate_master_compose(root, cli_plugins, ...)` - Assemble dependency tree into master compose
- `cc_docker_compose(master)` - Wrapper that sets COMPOSE_PROFILES and auto-registers services

### Processing Pipeline (in cc_generate_master_compose)

1. Flatten dependency tree with profile filtering
2. Collect plugin-declared modifications from `modifications` parameter
3. Collect wire-when rules via `get_wire_when()` exports
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

### Extension Export Requirements

Every composable must export:
- `cc_export()` - Returns plugin struct from `cc_create()`

Optional exports:
- `get_wire_when()` - Returns conditional wiring rules
- `cc_setup(ctx)` - Host-side setup called by `cc_docker_compose()`
- `process_accumulated_modifications(mods, orchestrator_dir)` - Process markers from other plugins

## Key Files

- `Tiltfile` - Main extension implementation and public API (~1,510 lines)
- `lib/utils.tilt` - Utility functions (deep merge, URL parsing, volume utilities)
- `lib/profiles.tilt` - Profile activation and filtering logic
- `lib/dependency_graph.tilt` - Dependency tree traversal and struct conversion
- `lib/wiring.tilt` - Declarative wiring system (wire-when rules)
- `test/Tiltfile` - Test suite (122 unit tests + 12 integration tests)
- `docs/README.md` - User documentation
- `REFACTORING_SUMMARY.md` - Documentation of modular refactoring (Phases 1-5)
- `future-investigations/` - Design documents for future features

## Environment Variables

- `COMPOSABLES_URL` - Default URL for `cc_import()` when `url` parameter is not provided (default: `https://github.com/grafana/composables@main`)
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
