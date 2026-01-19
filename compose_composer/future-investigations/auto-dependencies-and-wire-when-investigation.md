# Plan: Reverse Wire-When Callback Interface for Compose Composer

## Executive Summary

**Key Finding**: The compose_composer architecture intentionally prevents "reverse callbacks" (dependencies modifying their includers) to preserve **symmetric orchestration**. The current wire-when pattern already provides the necessary mechanism, just inverted: source plugins declare requirements when dependencies are present, rather than dependencies injecting behavior upward.

**Why Current Design is Correct**:
1. **Symmetric**: Any plugin can orchestrate; result is the same
2. **Explicit**: All wiring visible in source plugin's `get_wire_when()`
3. **Declarative**: Rules trigger based on loaded dependencies, not hardcoded parent relationships
4. **Proven**: Grafana + mysql integration works correctly with wire-when

**User Preferences**:
- Maintain symmetric orchestration (no context-dependent behavior)
- Keep explicit declarations (no magic auto-injection)
- Focus on architectural understanding + minimal improvements

**Recommended Outcome**: Document the architectural rationale, optionally add helper functions to reduce wire-when boilerplate while preserving explicitness.

---

## Problem Statement

The user wants to explore a "reverse wire-when" callback interface where dependencies can declare modifications to be applied to **whoever included them**, rather than the current model where:

1. **Modifications** (via `mysql.require_database()`) can only target the dependency itself (mysql)
2. **Wire-when rules** (via `get_wire_when()`) are defined BY the source plugin to modify its own services when a trigger dependency is present

### Current Asymmetry

**Direction 1: Modifications (Caller → Dependency)**
```python
# oncall-gateway/Tiltfile
def cc_export():
    return cc_create(
        'oncall-gateway',
        './docker-compose.yaml',
        mysql,
        modifications=[
            mysql.require_database('oncall_gateway_local_dev'),  # Modifies mysql only
        ]
    )
```
- Target: `_target='mysql'`
- Can only modify mysql's compose overrides
- **Cannot add `depends_on: ['db']` to oncall-gateway services**

**Direction 2: Wire-When (Source Plugin Declares Own Requirements)**
```python
# oncall-gateway/Tiltfile
def get_wire_when():
    return {
        'mysql': {  # When mysql is present
            '_database_requirement': 'oncall_gateway_local_dev',  # Marker for mysql callback
            'services': {
                'oncall-gateway': {  # Modify MY OWN services
                    'depends_on': ['db'],
                }
            }
        }
    }
```
- Defined by oncall-gateway (the INCLUDING plugin)
- Can modify oncall-gateway's own services
- **This is the recommended pattern per the investigation document**

### Proposed Direction 3: Reverse Callback (Dependency → Caller)

User wants to explore:
```python
# mysql/Tiltfile (hypothetical)
def get_inclusion_requirements():
    """When I'm included by anyone, modify THEIR services"""
    return {
        # ??? What goes here? How do I know who included me?
        'service-injection': {
            'depends_on': ['db'],  # Add this to including plugin's services
        }
    }
```

## Architectural Analysis

### Why Modifications Can't Modify "Upward"

**The Flattening Process** (`_flatten_dependency_tree()`, line 1250-1336):

1. Dependencies are flattened depth-first into a flat list
2. The root/orchestrator plugin is added at the end (line 1314-1317)
3. Parent-child relationships are **not preserved** - only a `seen_names` dict tracking which deps exist
4. Result: `[mysql, grafana, k3s, service-model]` (flat, no hierarchy)

**The Modification Application** (`_apply_modifications()`, line 1207-1244):

1. Builds `dep_map = {dep_name: dep}` from flat list
2. For each modification, looks up `_target` in dep_map
3. Deep-merges modification into `dep._compose_overrides_param`

**The Constraint:**
- When mysql is being processed, there's no concept of "who included mysql"
- The root plugin (orchestrator) is in the flat list, but mysql doesn't know about it
- Even if mysql tried `_target='service-model'`, it wouldn't know the orchestrator's name
- **Architectural principle**: Dependencies shouldn't have hardcoded knowledge of callers (breaks symmetric orchestration)

### Why Wire-When Works (and is the Correct Pattern)

**Wire-when rules are applied AFTER flattening** (line 1624):
```python
# Phase 3: Resolve and transform compose files
for dep in loaded_deps:
    content = read_yaml(compose_path)

    # Apply static compose_overrides from modifications
    if overrides:
        content = _deep_merge(content, overrides)

    # Apply wire_when rules
    content = _apply_wire_when_rules(content, dep['name'], wire_when_rules, loaded_dep_names)
```

**Key difference:**
1. Wire-when rules are collected from ALL dependencies (line 1590)
2. For each dependency's compose file, check if any triggers match loaded deps
3. If mysql is loaded AND grafana has rules for mysql, apply those rules to grafana's services
4. **This modifies the SOURCE plugin's compose file**, not the target dependency

**Semantic:**
- Source plugin (grafana) says: "When mysql is present, modify MY services like this"
- Not: mysql says "modify whoever includes me"
- This is **declarative** and preserves symmetric orchestration

## Exploration Options

### Option 1: Track "Included By" Metadata During Flattening

**Feasibility**: HIGH

**Changes Required:**
1. Modify `_flatten_dependency_tree()` to track parent relationships:
```python
def _flatten_dependency_tree(root, cli_plugins, seen_names=None, active_profiles=None, parent_chain=None):
    # New parameter: parent_chain (list of ancestor names)

    for dep in root_dict.get('dependencies', []):
        dep_dict = _struct_to_dict(dep)

        # Track who included this dependency
        if '_included_by' not in dep_dict:
            dep_dict['_included_by'] = []
        dep_dict['_included_by'].append(root_dict['name'])

        # Track ancestry chain
        dep_dict['_parent_chain'] = (parent_chain or []) + [root_dict['name']]
```

2. Add new callback interface `get_caller_modifications()`:
```python
# mysql/Tiltfile
def get_caller_modifications(caller_name, caller_compose_path):
    """Return modifications to apply to the caller's services"""
    return {
        'services': {
            # But wait - we don't know the caller's service names!
            # This breaks down unless we scan the caller's compose file
        }
    }
```

**Problems:**
- **Service discovery**: Dependency doesn't know caller's service structure
- **Name collisions**: What if caller has multiple services? Which ones to modify?
- **Symmetric orchestration**: Different orchestrators would see different behavior
- **Complexity**: Needs bidirectional communication during composition

**Assessment**: Technically feasible but **architecturally problematic**.

### Option 2: Convention-Based Service Injection

**Feasibility**: MEDIUM

**Concept**: Dependencies could declare "if a service named X exists in the including plugin, add depends_on"

```python
# mysql/Tiltfile
def get_service_injection_rules():
    """When I'm included, apply these rules to caller's services"""
    return {
        'patterns': [
            {
                'service_regex': '.*',  # All services
                'modifications': {
                    'depends_on': ['db'],
                    'environment': {
                        'DATABASE_HOST': 'db',
                    }
                }
            }
        ]
    }
```

**Implementation:**
1. During compose file assembly (line 1606-1649)
2. Check each dependency for `get_service_injection_rules()`
3. Apply rules to INCLUDING plugin's services based on patterns

**Problems:**
- **Too aggressive**: Blindly adding depends_on to ALL services is wrong (not all services need database)
- **Fragile**: Regex patterns are error-prone
- **Hidden coupling**: Source plugin doesn't declare its requirements, they're inferred
- **Debugging nightmare**: Hard to understand why services have certain dependencies

**Assessment**: Feasible but **too implicit and error-prone**.

### Option 3: Enhanced Wire-When with Automatic Service Discovery

**Feasibility**: HIGH

**Concept**: Keep wire-when as the interface, but make it easier to declare common patterns

```python
# oncall-gateway/Tiltfile
def get_wire_when():
    return {
        'mysql': {
            # Marker for mysql's callback
            '_database_requirement': 'oncall_gateway_local_dev',

            # Use a helper to inject depends_on into all services
            **mysql.auto_inject_depends_on(
                services=['oncall-gateway', 'oncall-gateway-debug']
            )
        }
    }
```

Where `auto_inject_depends_on()` is a helper function exported by mysql:
```python
# mysql/Tiltfile
def auto_inject_depends_on(services):
    """Generate wire-when rules for service dependencies"""
    return {
        'services': {
            service_name: {'depends_on': ['db']}
            for service_name in services
        }
    }
```

**Advantages:**
- Keeps wire-when as the interface (declarative, symmetric)
- Reduces boilerplate for common patterns
- Source plugin still controls which services get modified
- Explicit service list (not pattern-based)

**Assessment**: **Most promising** - enhances existing pattern without breaking architecture.

### Option 4: Two-Phase Callback with Caller Context

**Feasibility**: MEDIUM-HIGH

**Concept**: Add a second callback phase where dependencies can inspect the caller's compose structure

```python
# Compose_composer calls this AFTER reading caller's compose file
def process_caller_requirements(caller_name, caller_services, my_requirements):
    """
    Args:
        caller_name: Name of the including plugin
        caller_services: Dict of service names → service configs from caller's compose file
        my_requirements: Dict of requirements declared by caller (e.g., database names)

    Returns:
        Dict of modifications to apply to caller's services
    """
    modifications = {}

    # Scan caller's services and determine which need database access
    for service_name, service_config in caller_services.items():
        env = service_config.get('environment', {})

        # Heuristic: if service has DATABASE_URL env var, add depends_on
        if any('DATABASE' in key for key in env.keys()):
            modifications[service_name] = {
                'depends_on': ['db'],
            }

    return {'services': modifications}
```

**Implementation Timeline:**
1. **Phase 1**: Collect modifications (current)
2. **Phase 2**: Read each compose file
3. **NEW Phase 2.5**: For each dependency, call `process_caller_requirements()` with caller context
4. **Phase 3**: Apply all modifications + new caller modifications
5. **Phase 4**: Apply wire-when rules

**Problems:**
- **Heuristics are fragile**: Scanning environment variables is unreliable
- **Ordering complexity**: Nested dependencies would need recursive caller inspection
- **Symmetric orchestration**: Caller behavior depends on dependency callbacks

**Assessment**: Feasible but **adds significant complexity** for marginal benefit.

## Recommended Approach

### Path Forward: Architectural Documentation + Optional Helper Functions

**User Preferences** (from clarification):
- Motivation: Architectural exploration + understanding current design
- Orchestration: Maintain symmetry (no context-dependent behavior)
- Design: Keep explicit declarations (no auto-injection magic)

**Rationale for Recommended Approach:**
1. **Preserve symmetric orchestration**: Source plugin declares its requirements
2. **Maintain explicitness**: No hidden behavior, everything visible in get_wire_when()
3. **Document the "why"**: Current design is intentional and well-reasoned
4. **Optional helpers**: If desired, add helpers that reduce boilerplate without hiding intent
5. **Proven pattern**: Wire-when + modifications already solve the problem correctly

**Implementation Plan:**

#### Step 1: Add Helper Utilities to MySQL

**File**: `composables/mysql/Tiltfile`

```python
def auto_inject_depends_on(services, condition='service_healthy'):
    """
    Generate wire-when rules to add depends_on to specified services.

    Args:
        services: List of service names to inject dependency
        condition: Docker Compose health check condition (default: 'service_healthy')

    Returns:
        Dict with 'services' key for wire-when rules

    Example:
        def get_wire_when():
            return {
                'mysql': {
                    '_database_requirement': 'mydb',
                    **mysql.auto_inject_depends_on(['api', 'worker']),
                }
            }
    """
    result = {'services': {}}

    for service_name in services:
        result['services'][service_name] = {
            'depends_on': {
                'db': {
                    'condition': condition,
                }
            }
        }

    return result
```

#### Step 2: Update Oncall-Gateway to Use Helper

**File**: `oncall-gateway/Tiltfile`

**Before** (current - manual wire-when):
```python
def get_wire_when():
    return {
        'mysql': {
            '_database_requirement': 'oncall_gateway_local_dev',
            'services': {
                'oncall-gateway': {
                    'depends_on': ['db'],
                },
                'oncall-gateway-debug': {
                    'depends_on': ['db'],
                },
            },
        },
    }
```

**After** (with helper):
```python
def get_wire_when():
    return {
        'mysql': {
            '_database_requirement': 'oncall_gateway_local_dev',
            **mysql.auto_inject_depends_on(['oncall-gateway', 'oncall-gateway-debug']),
        },
    }
```

#### Step 3: Update MySQL Documentation

**File**: `composables/mysql/Tiltfile` (docstrings)

Document the recommended pattern:
```python
def require_database(database_name):
    """
    Declare that this composable requires a database to be created.

    RECOMMENDED: Use with auto_inject_depends_on() in wire-when rules.

    Example (RECOMMENDED):
        mysql = cc_import(name='mysql', url=COMPOSABLES_URL,
                          imports=['require_database', 'auto_inject_depends_on'])

        def get_wire_when():
            return {
                'mysql': {
                    '_database_requirement': 'mydb',
                    **mysql.auto_inject_depends_on(['api-service', 'worker']),
                },
            }
    """
```

#### Step 4: Add Tests

**File**: `tilt-extensions/compose_composer/test/`

Test that:
1. Helper generates correct wire-when structure
2. Services get depends_on injected
3. Staged compose files have expected dependencies
4. No modification to services that aren't in the list

### Why This is Better Than Reverse Callbacks

| Aspect | Reverse Callback | Enhanced Wire-When |
|--------|------------------|-------------------|
| **Declarative** | No (dependency controls caller) | Yes (caller declares requirements) |
| **Symmetric** | No (behavior depends on caller) | Yes (works with any orchestrator) |
| **Explicit** | No (hidden in dependency) | Yes (visible in get_wire_when) |
| **Granular** | Hard (all-or-nothing) | Easy (per-service control) |
| **Testable** | Complex (depends on context) | Simple (static rules) |
| **Debuggable** | Hard (implicit behavior) | Easy (trace wire-when rules) |
| **Backward Compatible** | No (new architecture) | Yes (extends existing pattern) |

## User Requirements (Clarified)

**Preferences:**
- **Motivation**: Mixed - architectural understanding + exploring possibilities
- **Orchestration**: Maintain symmetry - no context-dependent behavior
- **Design**: Explicit declarations - no magic auto-injection
- **Scope**: Open to minimal improvements that preserve architecture

**This Rules Out:**
- ❌ Option 2: Convention-based injection (too implicit)
- ❌ Option 4: Two-phase callbacks with caller context (breaks symmetry)
- ❌ Aggressive auto-injection patterns

**Viable Approaches:**
- ✅ Option 3: Helper functions (reduces boilerplate, stays explicit)
- ✅ Architectural documentation (understanding current design)
- ✅ Minimal core changes only if they enhance without breaking principles

## Key Architectural Insights

### Why Modifications Can't Flow Upward

**The Constraint**: When `_apply_modifications()` runs (line 1207), it operates on a flat dependency list with no parent-child hierarchy. The root/orchestrator is in the list but mysql doesn't know it's the "parent". Even if we tracked parent relationships, hardcoding parent names breaks symmetric orchestration.

**Example**:
```
mysql doesn't know: "I was included by service-model"
mysql can't say: "add depends_on to service-model's services"
service-model might not even exist (mysql could be standalone)
```

### Why Wire-When is the Correct Pattern

**Wire-when inverts the relationship**:
- Not: mysql says "modify whoever includes me"
- Instead: source says "when mysql is present, modify MY services"

**This preserves symmetry** because:
- Source plugin controls its own configuration
- Same wiring applies regardless of orchestrator
- No hardcoded knowledge of parent plugins

### The Two-Direction Model

| Direction | Mechanism | Purpose | Example |
|-----------|-----------|---------|---------|
| **Caller → Dependency** | Modifications | Configure the dependency | `mysql.require_database('mydb')` creates database |
| **Source ← Trigger** | Wire-when | Integrate when trigger present | `get_wire_when()` adds `depends_on` to MY services |

Both are needed and complement each other.

## Critical Files

| File | Purpose | Changes Needed |
|------|---------|----------------|
| `tilt-extensions/compose_composer/Tiltfile` | Core framework | Documentation only (no code changes needed) |
| `composables/mysql/Tiltfile` | MySQL extension | Optional: Add helper functions |
| `oncall-gateway/Tiltfile` | Example consumer | Optional: Use helpers if added |
| `tilt-extensions/compose_composer/future-investigations/` | Investigation docs | Update with findings |

## Verification Plan

### Test Scenario 1: Helper Function Pattern
```bash
cd oncall-gateway
tilt ci  # Should generate correct wire-when rules without docker-compose

# Expected output:
# - Wire-when rules show mysql trigger
# - Staged compose has depends_on for oncall-gateway services
# - Master compose includes all expected files
```

### Test Scenario 2: Multiple Orchestrators (Symmetric Test)
```bash
cd service-model
tilt ci -- ../oncall-gateway  # oncall-gateway as CLI plugin

# Expected:
# - Same dependencies added regardless of orchestrator
# - service-model doesn't break oncall-gateway's mysql integration
```

### Test Scenario 3: No False Positives
```bash
cd tilt-dc-testing/plugin-three
tilt ci -- ../plugin-with-mysql-but-no-services  # Hypothetical

# Expected:
# - wire-when rules don't inject depends_on into non-existent services
# - No errors, just skipped injections
```

## Next Steps

Based on user preferences, recommended path forward:

### Phase 1: Document Current Architecture (Primary Goal)
Create comprehensive documentation explaining:
1. Why modifications flow dependency-direction only
2. How wire-when provides the "reverse" mechanism
3. Why this design preserves symmetric orchestration
4. When to use modifications vs. wire-when vs. helpers

**Deliverable**: Architecture document (can be part of CLAUDE.md or separate doc)

### Phase 2: Optional Helper Functions (Secondary Goal)
If boilerplate reduction is desired:
1. Add `mysql.auto_inject_depends_on()` helper
2. Update examples to show helper usage
3. Document pattern in mysql/Tiltfile

**Deliverable**: Helper functions + updated examples

### Phase 3: Enhance Investigation Document (Tertiary Goal)
Update `auto-dependencies-and-wire-when.md`:
1. Add section explaining why "reverse callbacks" break symmetry
2. Document the architectural constraints
3. Add comparison table: modifications vs. wire-when vs. proposed alternatives

**Deliverable**: Enhanced investigation document

## Implementation Estimate

- **Phase 1** (Documentation): 1-2 hours
- **Phase 2** (Helper functions): 1-2 hours (if desired)
- **Phase 3** (Investigation update): 30-60 minutes

**Total**: 2.5-5 hours depending on scope
