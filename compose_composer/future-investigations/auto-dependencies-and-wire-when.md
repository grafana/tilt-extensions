# Plan: Automatic Database Dependency Injection for mysql.require_database()

## Problem Statement

Currently, when a composable uses `mysql.require_database()` to declare a database requirement, it only handles database creation. The calling service must manually add `depends_on: db` to ensure the database is fully started before the service runs.

**Current behavior:**
```python
# In Tiltfile
mysql.require_database('oncall_gateway_local_dev')

# In docker-compose.yaml - MANUAL dependency
services:
  oncall-gateway:
    depends_on:
      db:
        condition: service_healthy
```

**Desired behavior:**
When calling `mysql.require_database()`, automatically add `depends_on: ['db']` to services that need the database.

## Investigation Summary

### Current Architecture

1. **mysql.require_database()** (`composables/mysql/Tiltfile:61-89`)
   - Returns: `{'_database_requirement': 'db_name', '_target': 'mysql'}`
   - Passed in `modifications` list to `cc_create()`
   - Collected by compose_composer and passed to `process_accumulated_modifications()`

2. **process_accumulated_modifications()** (`composables/mysql/Tiltfile:91-133`)
   - Extracts all `_database_requirement` markers
   - Generates SQL init script
   - Returns modification targeting mysql (volume mount for SQL)
   - **Limitation**: Has NO knowledge of which service requested each database

3. **Modifications** (compose_composer mechanism)
   - Target DEPENDENCIES via `_target` field
   - Cannot modify services in OTHER plugins
   - Deep-merge compose_overrides into target dependency

4. **Wire-When Rules** (alternative mechanism)
   - Defined via `get_wire_when()` export
   - Trigger when specific dependencies are loaded
   - CAN modify services in the SOURCE plugin
   - Already used by grafana to add depends_on

### Architectural Constraint

**Key insight**: Modifications cannot add `depends_on` to services in the calling plugin because:
- Modifications target dependencies (via `_target`)
- They operate on the TARGET dependency's compose file
- They cannot reach back to modify the SOURCE plugin's services

**Wire-when rules solve this** because:
- They are defined BY the source plugin
- They modify services IN the source plugin's compose file
- They trigger WHEN a specific dependency is loaded

## Solution: Use Wire-When Pattern

The compose_composer framework ALREADY supports automatic dependency injection via wire-when rules. Grafana demonstrates this pattern successfully.

### Implementation Approach

**Pattern: Declarative Wire-When (Recommended)**

Use `get_wire_when()` to declare BOTH the database requirement AND the service dependencies in one place:

```python
def get_wire_when():
    return {
        'mysql': {
            # Marker for mysql to process (creates database)
            '_database_requirement': 'oncall_gateway_local_dev',

            # Service-level modifications (adds depends_on)
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

**Benefits:**
- Single source of truth for database requirements
- Automatic `depends_on` injection when mysql is loaded
- Service-level granularity (specify exactly which services need db)
- Symmetric (works regardless of orchestrator)
- No manual compose file edits needed

## Implementation Steps

### Step 1: Update oncall-gateway Tiltfile

**File:** `oncall-gateway/Tiltfile`

**Changes:**
1. Remove `mysql.require_database()` from modifications list in `cc_export()`
2. Add `get_wire_when()` export with database requirement and dependencies
3. Keep the mysql import but remove 'require_database' from imports (optional)

**Before:**
```python
def cc_export():
    return cc_create(
        'oncall-gateway',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        mysql,
        labels=['chatops'],
        modifications=[
            mysql.require_database('oncall_gateway_local_dev'),
        ],
    )
```

**After:**
```python
def cc_export():
    return cc_create(
        'oncall-gateway',
        os.path.dirname(__file__) + '/docker-compose.yaml',
        mysql,
        labels=['chatops'],
    )

def get_wire_when():
    """
    Declarative wiring rules for oncall-gateway.

    When mysql is loaded, this plugin will:
    - Declare database requirement (creates oncall_gateway_local_dev database)
    - Automatically add depends_on to services that need the database
    """
    return {
        'mysql': {
            # Database requirement marker (processed by mysql)
            '_database_requirement': 'oncall_gateway_local_dev',

            # Service dependencies (processed by compose_composer)
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

### Step 2: Update docker-compose.yaml (Optional)

**File:** `oncall-gateway/docker-compose.yaml`

**Rationale:** Since wire-when will automatically add `depends_on: ['db']`, we can remove it from the compose file. However, keeping it is also fine - compose_composer will merge/deduplicate.

**Option A: Remove manual depends_on** (cleaner, demonstrates automatic injection)
```yaml
services:
  oncall-gateway:
    build: ...
    ports: ...
    environment: ...
    # depends_on removed - now automatic via wire-when

  oncall-gateway-debug:
    build: ...
    # depends_on removed - now automatic via wire-when
```

**Option B: Keep manual depends_on** (safer, provides fallback if wire-when doesn't trigger)
```yaml
services:
  oncall-gateway:
    depends_on:
      db:
        condition: service_healthy  # Keep existing
```

**Recommendation:** Start with Option B to be safe, verify wire-when works, then consider Option A.

### Step 3: Update mysql Documentation

**File:** `composables/mysql/Tiltfile` (docstrings)

Update `require_database()` docstring to recommend wire-when pattern:

```python
def require_database(database_name):
    """
    Declare that this composable requires a database to be created.

    RECOMMENDED: Use this via wire-when rules for automatic dependency injection.

    Example (RECOMMENDED - Automatic depends_on):
        def get_wire_when():
            return {
                'mysql': {
                    '_database_requirement': 'oncall_local_dev',
                    'services': {
                        'oncall-gateway': {
                            'depends_on': ['db'],
                        },
                    },
                },
            }

    Example (LEGACY - Manual depends_on in compose file):
        # In cc_export():
        return cc_create(
            'oncall-backend',
            ...,
            mysql,
            modifications=[
                mysql.require_database('oncall_local_dev'),
            ],
        )
        # Must manually add depends_on: ['db'] to docker-compose.yaml
    """
```

## Critical Files

1. **oncall-gateway/Tiltfile** - Add get_wire_when() export
2. **oncall-gateway/docker-compose.yaml** - Optionally remove manual depends_on
3. **composables/mysql/Tiltfile** - Update documentation
4. **composables/grafana/Tiltfile** - Reference implementation (already using pattern)

## Testing & Verification

### Test Plan

1. **Verify wire-when triggers:**
   ```bash
   cd oncall-gateway
   tilt up
   ```
   - Check Tilt logs for: `[wire_when] grafana wired grafana for mysql`
   - Should see similar message for oncall-gateway

2. **Verify database creation:**
   ```bash
   # Check that database was created
   docker exec -it oncall-gateway-db-1 mysql -uuser -ppass -e "SHOW DATABASES"
   ```
   - Should see `oncall_gateway_local_dev` database

3. **Verify service dependency:**
   ```bash
   # Check that service depends on db
   docker inspect oncall-gateway-oncall-gateway-1 --format '{{json .HostConfig.DependsOn}}'
   ```
   - Should include `db` in the list

4. **Verify startup order:**
   ```bash
   docker compose logs oncall-gateway
   ```
   - Should see database migrations run successfully
   - No connection errors before db is ready

5. **Test compose file generation:**
   ```bash
   # Check staged compose file
   cat .cc/oncall-gateway.yaml
   ```
   - Verify `depends_on: ['db']` was added to oncall-gateway service

### Expected Output

**Tilt Logs:**
```
Collecting wiring rules:
  mysql triggers: grafana, oncall-gateway

Assembling compose files:
  oncall-gateway: /path/to/docker-compose.yaml
    [wire_when] oncall-gateway wired oncall-gateway for mysql
    [wire_when] oncall-gateway wired oncall-gateway-debug for mysql
    -> Modified, staged to: /path/.cc/oncall-gateway.yaml
```

**Staged Compose (.cc/oncall-gateway.yaml):**
```yaml
services:
  oncall-gateway:
    depends_on:
      - db  # <- Automatically added by wire-when
  oncall-gateway-debug:
    depends_on:
      - db  # <- Automatically added by wire-when
```

## Alternative Approaches Considered

### Option 1: Enhance require_database() API
```python
mysql.require_database('db_name', services=['oncall-gateway'])
```
**Rejected:** Modifications cannot target services in other plugins.

### Option 2: Return multiple modifications from callback
Have `process_accumulated_modifications()` return list of modifications.
**Rejected:** Still cannot target services in other plugins.

### Option 3: Automatic injection for all services
Automatically add depends_on to ALL services in plugins with database requirements.
**Rejected:** Too aggressive (not all services need database, e.g., lgtm service).

### Option 4: Extend compose_composer to track modification sources
Track which plugin created each modification, add depends_on automatically.
**Rejected:** Still cannot determine WHICH services need the database.

## Conclusion

The wire-when pattern is the correct architectural solution because:
1. It provides service-level granularity
2. It keeps concerns together (database requirement + dependencies)
3. It's already implemented and working (grafana proves it)
4. It's symmetric (works regardless of orchestrator)
5. It follows compose_composer's declarative design philosophy

The "automatic" behavior the user wants IS available - it just requires using the `get_wire_when()` pattern instead of the `modifications` parameter.
