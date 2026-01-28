# Compose Composer Refactoring Plan

## Status: Phase 1 Complete ✓

**Phase 1: Integration Tests (DONE)**
- Added 10 comprehensive integration tests
- Created test fixtures for end-to-end validation
- All tests passing (~132 total: 122 unit + 10 integration)

**Next: Phase 2 - Module Extraction**

## Problem Statement

The compose_composer extension has grown to 2,270 lines in a single Tiltfile, making it difficult to:
- Navigate and understand the codebase
- Maintain and debug issues
- Onboard new contributors
- Test individual components in isolation

## Test Analysis Results

### Current Test Coverage
```
Unit Tests (~122 tests):
├── Data Transformation (41 tests) - deep_merge, URL parsing, volumes
├── Dependency Graph (15 tests) - flatten, profile filtering
├── Wiring & Modifications (19 tests) - wire-when, modifications
├── Plugin Loading & CLI (13 tests) - resolve specs, cc_create, symbols
├── Fluent API (11 tests) - cc_init
└── Misc (23 tests) - Environment vars, safety checks

Integration Tests (10 tests):
├── Simple orchestration
├── Dependency loading
├── Wire-when rules application
├── Profile filtering
├── Modifications system
├── cc_init fluent API
├── CLI plugin parsing
├── Master compose generation
├── Resource dependencies
└── Nested dependencies
```

### Key Findings

1. **Tests reveal clear module boundaries** - Test organization shows natural cohesion
2. **Heavy internal testing** - 80% of tests focus on internals via `cc_test_exports()`
3. **Minimal integration testing** - Only 2 integration tests existed before this phase
4. **Bug-driven growth** - Many tests reference specific bug numbers

## Proposed Module Structure

Based on test analysis and current code organization:

```
compose_composer/
├── lib/
│   ├── utils.tilt                  # ~300 lines
│   │   ├── _deep_merge()
│   │   ├── _deep_copy()
│   │   ├── _should_concatenate_string()
│   │   ├── _is_url()
│   │   ├── _parse_url_with_ref()
│   │   ├── _is_named_volume()
│   │   └── _parse_volume_mount()
│   │
│   ├── profiles.tilt               # ~100 lines
│   │   ├── _get_active_profiles()
│   │   ├── cc_get_active_profiles()
│   │   └── _is_dep_included_by_profile()
│   │
│   ├── dependency_graph.tilt       # ~200 lines
│   │   ├── _struct_to_dict()
│   │   ├── _flatten_dependency_tree()
│   │   └── _get_compose_path_from_dep()
│   │
│   ├── wiring.tilt                 # ~400 lines
│   │   ├── _collect_wire_when_rules()
│   │   ├── _apply_wire_when_rules()
│   │   └── _validate_volume_mounts()
│   │
│   ├── modifications.tilt          # ~200 lines
│   │   ├── _apply_modifications()
│   │   ├── _add_target_wrapper()
│   │   └── _compose_overrides_method()
│   │
│   └── plugin_loading.tilt         # ~600 lines
│       ├── cc_create()
│       ├── cc_import()
│       ├── _cc_import_with_context()
│       ├── _resolve_plugin_spec()
│       ├── cc_parse_cli_plugins()
│       ├── _is_bindable_symbol()
│       └── _run_plugin_setup()
│
├── orchestration.tilt              # ~600 lines
│   ├── cc_generate_master_compose()
│   ├── _stage_compose_file()
│   └── _generate_include_entry()
│
├── api.tilt                        # ~300 lines
│   ├── cc_init()
│   ├── cc_docker_compose()
│   └── cc_test_exports()
│
└── Tiltfile                        # ~100 lines
    └── Public API exports and module loading
```

### Test Structure (Mirrors Code)
```
test/
├── lib/
│   ├── utils_test.tilt
│   ├── profiles_test.tilt
│   ├── dependency_graph_test.tilt
│   ├── wiring_test.tilt
│   ├── modifications_test.tilt
│   └── plugin_loading_test.tilt
├── orchestration_test.tilt
├── api_test.tilt
├── integration_test.tilt           # NEW (10 tests)
├── fixtures/                       # NEW (test composables)
└── Tiltfile                        # Test runner
```

## Refactoring Strategy

### Phase 2: Extract Utility Modules (Bottom-Up)

**Goal:** Extract pure functions with no dependencies

**Modules to extract:**
1. `lib/utils.tilt` (highest test coverage, zero dependencies)
2. `lib/profiles.tilt` (standalone, minimal dependencies)

**Process:**
1. Create module file
2. Move functions to module
3. Move corresponding tests
4. Update imports in main Tiltfile
5. Run full test suite
6. Commit if green

**Success criteria:**
- All 132 tests pass
- No behavioral changes
- Import statements work correctly

### Phase 3: Extract Graph & Transformation Modules

**Modules to extract:**
1. `lib/dependency_graph.tilt`
2. `lib/wiring.tilt`
3. `lib/modifications.tilt`

**Dependencies:**
- dependency_graph depends on: utils, profiles
- wiring depends on: utils
- modifications depends on: utils

### Phase 4: Extract Plugin Loading

**Module to extract:**
1. `lib/plugin_loading.tilt`

**Dependencies:**
- Depends on: utils, profiles, modifications, wiring

**Challenges:**
- Most complex module
- Has the most interdependencies
- Consider splitting further if needed

### Phase 5: Extract Orchestration & API

**Modules to extract:**
1. `orchestration.tilt`
2. `api.tilt`

**Dependencies:**
- Both depend on all lib/ modules
- These are the highest-level modules

### Phase 6: Clean Up Main Tiltfile

**Final step:**
- Keep only public API exports
- Clean documentation
- Update CLAUDE.md

## Module Design Principles

### 1. Clear Responsibilities
Each module has a single, well-defined purpose:
- **utils** - Pure transformations, no side effects
- **profiles** - Profile management and filtering
- **dependency_graph** - Tree operations and conversions
- **wiring** - Wire-when rule collection and application
- **modifications** - Modification system and compose overrides
- **plugin_loading** - Loading composables from various sources

### 2. Minimal Dependencies
- Lower-level modules (utils, profiles) have zero dependencies
- Higher-level modules depend only on lower levels
- No circular dependencies

### 3. Test Co-location
- Each module has a corresponding test file
- Tests import only the module they're testing
- Integration tests remain at top level

### 4. Backward Compatibility
- Main Tiltfile exports same public API
- External users see no changes
- Internal refactoring only

## File Extension

Use `.tilt` extension for all Starlark files (not `.star`):
- More explicit about Tilt-specific code
- Follows project convention
- Better IDE support for Tilt-specific features

## Migration Checklist

For each module:
- [ ] Create new module file with docstring
- [ ] Move functions with comments preserved
- [ ] Add load() statements for dependencies
- [ ] Move corresponding tests to new test file
- [ ] Update main Tiltfile imports
- [ ] Run full test suite (make test)
- [ ] Verify integration tests still pass
- [ ] Update cc_test_exports() if needed
- [ ] Commit with descriptive message
- [ ] Update CLAUDE.md with new structure

## Rollback Plan

If refactoring causes issues:
1. Git revert to last working commit
2. Identify specific failing test
3. Fix import or function location issue
4. Rerun tests
5. Continue or rollback further if needed

## Success Metrics

- **All tests pass** - 132 tests (122 unit + 10 integration)
- **No API changes** - External users unaffected
- **Improved navigability** - Find functions faster
- **Easier testing** - Import specific modules for testing
- **Better documentation** - Each module has clear docstring

## Notes

- **TILT_PORT=13099** is used in tests to avoid conflicts
- Integration tests provide safety net for refactoring
- Unit tests may need minor import updates
- Keep `cc_test_exports()` during migration for gradual transition
- Consider removing `cc_test_exports()` after refactoring (rely on integration tests instead)

## Timeline Estimate

- Phase 2 (utils, profiles): 2-4 hours
- Phase 3 (graph, wiring, modifications): 3-5 hours
- Phase 4 (plugin_loading): 2-3 hours
- Phase 5 (orchestration, api): 2-3 hours
- Phase 6 (cleanup): 1-2 hours

**Total: 10-17 hours** (spread over multiple sessions)

## Questions to Resolve

1. Should we remove `cc_test_exports()` after refactoring?
   - Pro: Forces proper module boundaries
   - Con: Useful for testing internals
   - **Recommendation**: Keep for now, consider removing after integration test suite matures

2. Should we split `plugin_loading.tilt` further?
   - It's 600 lines, largest module
   - Could split into: loading, CLI parsing, symbol binding
   - **Recommendation**: Try as single module first, split if needed

3. Should we update CLAUDE.md during or after refactoring?
   - During: Keeps docs in sync
   - After: Less churn if structure changes
   - **Recommendation**: Update at Phase 6 (cleanup)
