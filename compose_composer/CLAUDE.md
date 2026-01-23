# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

compose_composer is a Tilt extension (~1900 lines of Starlark) that enables dynamic, runtime assembly of Docker Compose environments from modular, reusable components called "composables." It solves the rigidity of static Docker Compose files by allowing LEGO-block-style composition of dev environments.

## Core Concepts

**Composables**: Tilt extensions that wrap a docker-compose file and optionally expose helper functions. Any composable can import other composables, creating symmetric orchestration.

**Symmetric Orchestration**: Any plugin can be the orchestrator. The result is the same regardless of which plugin initiates composition because wiring is declarative (via `get_wire_when()`) rather than imperative.

**Wire-When Rules**: Declarative rules that define how components wire themselves together when other dependencies are present. Defined via `get_wire_when()` export.

## Architecture

### Key Functions (Tiltfile)

- `cc_import(name, url, ...)` - Load a remote composable and return a plugin struct
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

- `Tiltfile` - Main extension implementation
- `test/Tiltfile` - Test suite
- `docs/README.md` - User documentation
- `future-investigations/` - Design documents for future features

## Environment Variables

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
