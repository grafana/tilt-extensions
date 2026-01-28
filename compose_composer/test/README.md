# Compose Composer Test Suite

## Overview

This directory contains comprehensive tests for the compose_composer extension, including both unit tests and integration tests.

## Running Tests

```bash
# From compose_composer directory
make test

# Or directly
cd test && TILT_PORT=13099 tilt ci
```

**Note:** `TILT_PORT` is set to avoid conflicts with other running Tilt instances.

## Test Structure

### Unit Tests (Tiltfile)
- **~122 unit tests** covering internal functions
- Tests are organized by functional area (deep_merge, wiring, profiles, etc.)
- Heavy focus on edge cases, type safety, and regression prevention
- Uses `cc_test_exports()` to access internal functions

### Integration Tests (integration_test.tilt)
- **12 integration tests** covering end-to-end workflows using the **fluent API** (`cc_init()`)
- Tests demonstrate the recommended client-facing API pattern
- Uses test fixtures in `fixtures/` directory

**All tests use the fluent API pattern:**
```python
cc = cc_init(name='my-project', staging_dir='/tmp/my-staging')
plugin_a = cc.create('plugin-a', 'path/to/compose.yaml', labels=['app'])
plugin_b = cc.create('plugin-b', 'path/to/compose.yaml', plugin_a)
master = cc.generate_master_compose(root_plugin=plugin_b, cli_plugins=[])
```

## Integration Test Coverage

The integration tests provide a safety net for refactoring by validating:

1. **Simple Orchestration** - Basic composition with cc_init() and cc.create()
2. **Dependency Loading** - Loading and flattening dependency trees via fluent API
3. **Composables Registry** - cc.composables() tracking and cc.get_composable()
4. **Wire-When Rules** - Declarative wiring between composables
5. **Dependency Inference** - Auto-inference from cc.composables() when no deps specified
6. **Profile Filtering** - Profile-based inclusion/exclusion with cc.get_active_profiles()
7. **Modifications System** - compose_overrides and deep merge
8. **CLI Plugins** - Command-line plugin parsing and integration
9. **Master Compose File** - File generation using cc.staging_dir and metadata stripping
10. **Resource Dependencies** - Resource dependency propagation
11. **Nested Dependencies** - Transitive dependency resolution
12. **Context Independence** - Multiple cc_init() contexts work independently

## Test Fixtures

Located in `fixtures/` directory:

- **plugin-a** - Simple composable with no dependencies
- **plugin-b** - Composable with wire-when rules (triggers on plugin-a)
- **plugin-c** - Composable with profile requirements (dev, full)
- **orchestrator** - Minimal orchestrator for testing

Each fixture includes:
- `docker-compose.yaml` - Service definitions
- `Tiltfile` - cc_export() function and optional get_wire_when()

## Test Output

Tests produce output to `/tmp/cc-integration-test-*` directories for inspection:
- `master-compose.yaml` - Generated master compose file
- `<plugin-name>.yaml` - Staged/modified compose files

## Adding New Tests

### Unit Tests
Add to `Tiltfile`:
1. Define test function: `def test_new_feature():`
2. Use assert helpers: `assert_equals()`, `assert_true()`, `assert_in()`
3. Add to `run_tests()` function
4. Run tests to verify

### Integration Tests
Add to `integration_test.tilt`:
1. Define test function: `def test_integration_new_workflow():`
2. Create/reuse fixtures as needed
3. Exercise full public API (cc_init, cc_create, cc_generate_master_compose)
4. Validate end-to-end behavior
5. Add to `run_integration_tests()` function

## Coverage Summary

```
Total Tests: ~134 tests
- Unit Tests: ~122 tests (80% internal, 20% public API)
- Integration Tests: 12 tests (100% fluent API + orchestration)

Coverage:
✓ Data transformation & utilities (deep_merge, URL parsing, etc.)
✓ Dependency graph operations (flatten, profile filter)
✓ Wiring system (collect + apply wire-when rules)
✓ Modification system (compose_overrides, deep merge)
✓ Plugin loading & CLI parsing
✓ Fluent API (cc_init, cc.create, cc.generate_master_compose, cc.composables)
✓ Full orchestration pipeline (end-to-end)
✓ Context independence (multiple cc_init instances)
```

## Known Limitations

- **Profile testing** - Profiles are evaluated at load time, so dynamic profile changes cannot be tested in a single test run
- **cc_import real loading** - Integration tests use cc_create for fixtures instead of actual v1alpha1.extension() loading (which would require real git repos)
- **cc_docker_compose execution** - Tests don't actually invoke docker_compose() (would require docker daemon)
