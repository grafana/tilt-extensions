# Compose Composer Architecture

This document provides visual representations of the compose_composer architecture, including module dependencies, data flow, and processing pipelines.

## Module Dependency Graph

This diagram shows how the modules depend on each other. Lower-level modules (utils, profiles) have no dependencies, while higher-level modules depend on them through dependency injection.

```mermaid
graph TD
    Tiltfile[Tiltfile<br/>Main orchestration, public API<br/>1,510 lines]

    Utils[lib/utils.tilt<br/>Pure utility functions<br/>330 lines]
    Profiles[lib/profiles.tilt<br/>Profile management<br/>105 lines]
    DepGraph[lib/dependency_graph.tilt<br/>Graph operations<br/>233 lines]
    Wiring[lib/wiring.tilt<br/>Declarative wiring<br/>297 lines]

    Tiltfile -->|imports| Utils
    Tiltfile -->|imports| Profiles
    Tiltfile -->|imports| DepGraph
    Tiltfile -->|imports| Wiring

    DepGraph -->|injected| Utils
    DepGraph -->|injected| Profiles
    Wiring -->|injected| Utils

    style Tiltfile fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style Utils fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    style Profiles fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    style DepGraph fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style Wiring fill:#fff3e0,stroke:#e65100,stroke-width:2px
```

**Legend**:
- **Blue** (Tiltfile): Main orchestration and public API
- **Purple** (Utils, Profiles): Leaf modules with no dependencies
- **Orange** (DepGraph, Wiring): Mid-level modules with injected dependencies

**Key Insight**: Dependencies flow in one direction (bottom-up). No circular dependencies.

## Data Flow Pipeline

This diagram shows how data flows through the system from CLI arguments to running Docker Compose containers.

```mermaid
graph LR
    CLI[CLI Arguments<br/>--arg key=value<br/>--profile=dev]
    Env[Environment<br/>CC_PROFILES]
    Root[Root Plugin<br/>cc_create/cc_import]

    CLI --> ParseCLI[cc_parse_cli_plugins]
    Env --> GetProfiles[profiles.get_active]
    Root --> Flatten
    ParseCLI --> Flatten

    Flatten[dependency_graph.flatten<br/>Tree → Flat List]

    Flatten --> CollectMods[Collect Modifications]
    Flatten --> CollectRules[wiring.collect_rules<br/>Get wire-when rules]

    CollectMods --> ApplyMods[dependency_graph.apply_modifications]
    CollectRules --> ApplyRules[wiring.apply_rules<br/>Modify compose files]

    ApplyMods --> Stage[Stage Compose Files<br/>.cc/ directory]
    ApplyRules --> Stage

    Stage --> Master[Generate Master Compose<br/>include directives]
    Master --> Strip[Strip Internal Keys<br/>_compose_overrides, etc.]
    Strip --> Docker[docker compose up<br/>Start containers]

    GetProfiles --> Flatten

    style CLI fill:#e8f5e9,stroke:#2e7d32
    style Env fill:#e8f5e9,stroke:#2e7d32
    style Root fill:#e8f5e9,stroke:#2e7d32
    style Docker fill:#ffebee,stroke:#c62828
    style Master fill:#fff9c4,stroke:#f57f17
```

**Processing Stages**:
1. **Input** (green): CLI args, environment vars, root plugin
2. **Graph Processing** (center): Flatten, collect rules/mods, apply transformations
3. **Output Generation** (yellow): Generate master compose file
4. **Execution** (red): Start Docker Compose

## Orchestration Workflow

This diagram shows the detailed workflow inside `cc_generate_master_compose()`.

```mermaid
flowchart TD
    Start([cc_generate_master_compose]) --> Input{Input Type?}

    Input -->|Plugin Struct| ConvertStruct[dependency_graph.struct_to_dict]
    Input -->|Dict| UseDict[Use as-is]

    ConvertStruct --> ParseCLI
    UseDict --> ParseCLI

    ParseCLI[Parse CLI plugins<br/>cc_parse_cli_plugins] --> GetActive[Get active profiles<br/>profiles.get_active]

    GetActive --> Flatten[Flatten tree<br/>dependency_graph.flatten]

    Flatten --> EarlyWire{Early wiring?}

    EarlyWire -->|Yes| CollectEarly[Collect early wire-when rules<br/>wiring.collect_rules<br/>with cc context]
    EarlyWire -->|No| CollectMods

    CollectEarly --> CollectMods[Collect modifications<br/>from all plugins]

    CollectMods --> ApplyMods[Apply modifications<br/>dependency_graph.apply_modifications]

    ApplyMods --> CollectRules[Collect wire-when rules<br/>wiring.collect_rules]

    CollectRules --> ProcessLoop[For each dependency]

    ProcessLoop --> LoadCompose[Load compose file<br/>read_yaml]
    LoadCompose --> CheckProfile{Profile match?}

    CheckProfile -->|Yes| ApplyRules[Apply wire-when rules<br/>wiring.apply_rules]
    CheckProfile -->|No| Skip[Skip dependency]

    ApplyRules --> Stage[Stage modified compose<br/>.cc/dep-name.yaml]

    Stage --> AddInclude[Add to master includes]
    AddInclude --> More{More deps?}

    More -->|Yes| ProcessLoop
    More -->|No| Generate[Generate master compose]

    Skip --> More

    Generate --> StripInternal[Strip internal keys<br/>_compose_overrides, etc.]
    StripInternal --> Write[Write master file]
    Write --> End([Return master_compose])

    style Start fill:#e8f5e9,stroke:#2e7d32,stroke-width:3px
    style End fill:#e8f5e9,stroke:#2e7d32,stroke-width:3px
    style Flatten fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style ApplyRules fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style Generate fill:#fff9c4,stroke:#f57f17,stroke-width:2px
```

## Module Responsibilities

This diagram shows what each module is responsible for.

```mermaid
mindmap
  root((compose_composer))
    Tiltfile
      Public API
        cc_init
        cc_create
        cc_import
        cc_generate_master_compose
        cc_docker_compose
      Plugin Loading
        Resolve specs
        Load extensions
        Symbol binding
      Orchestration
        Master compose generation
        File staging
        Docker execution
    lib/utils.tilt
      Deep Merge
        Dict recursion
        List concatenation
        Env var special cases
      URL Parsing
        Git URL detection
        Reference extraction
      Volume Detection
        Named vs bind mounts
        Path validation
    lib/profiles.tilt
      Profile Activation
        CLI parsing
        Environment vars
      Filtering
        Match checking
        Inclusion logic
    lib/dependency_graph.tilt
      Struct Conversion
        Plugin to dict
        Field extraction
      Tree Flattening
        Depth-first traversal
        Deduplication
        Override merging
      Modifications
        Cross-plugin overrides
        Target resolution
    lib/wiring.tilt
      Rule Collection
        cc_wire_when calls
        Context passing
      Rule Application
        depends_on
        volumes
        environment
        labels
      Symmetric Orchestration
        Declarative wiring
        Trigger detection
```

## Design Patterns

### Struct Namespace Pattern

```mermaid
classDiagram
    class utils_tilt {
        <<struct>>
        +deep_merge(base, override)
        +deep_copy(obj)
        +is_url(s)
        +parse_url_with_ref(url)
        +is_named_volume(source)
    }

    class _private_functions {
        -_deep_merge()
        -_deep_copy()
        -_is_url()
        -_parse_url_with_ref()
        -_is_named_volume()
    }

    class Tiltfile {
        +load('lib/utils.tilt', 'util')
        +util.deep_merge(a, b)
    }

    _private_functions ..|> utils_tilt : exports as struct
    Tiltfile --> utils_tilt : imports

    note for utils_tilt "Single struct export\nenables namespace syntax"
    note for _private_functions "Functions stay private\nwith underscore prefix"
```

### Dependency Injection Pattern

```mermaid
sequenceDiagram
    participant T as Tiltfile
    participant DG as dependency_graph
    participant U as util (injected)
    participant P as profiles (injected)

    T->>T: load('lib/utils.tilt', 'util')
    T->>T: load('lib/profiles.tilt', 'profiles')
    T->>T: load('lib/dependency_graph.tilt', 'dependency_graph')

    Note over T: Now call with injection

    T->>DG: flatten(root, cli, util, profiles, active)

    activate DG
    DG->>U: deep_merge(a, b)
    U-->>DG: merged result

    DG->>P: is_included(dep_profiles, active)
    P-->>DG: true/false

    DG-->>T: flattened dependencies
    deactivate DG

    Note over DG: Module doesn't load()<br/>its dependencies<br/>They're injected
```

## Wire-When System

This diagram shows how the declarative wiring system enables symmetric orchestration.

```mermaid
graph TB
    subgraph "Plugin A"
        A_Compose[compose.yaml<br/>service: app]
        A_WireWhen[cc_wire_when<br/>'database': rules]
    end

    subgraph "Plugin B"
        B_Compose[compose.yaml<br/>service: api]
        B_WireWhen[cc_wire_when<br/>'database': rules]
    end

    subgraph "Database Plugin"
        DB_Compose[compose.yaml<br/>service: database]
    end

    subgraph "Orchestrator (any plugin can be orchestrator)"
        Collect[wiring.collect_rules<br/>Collect all wire-when rules]
        Check{Is 'database'<br/>loaded?}
        Apply[wiring.apply_rules<br/>Modify compose files]
    end

    A_WireWhen --> Collect
    B_WireWhen --> Collect
    DB_Compose --> Check

    Collect --> Check
    Check -->|Yes| Apply
    Check -->|No| Skip[Skip wiring]

    Apply --> A_Modified[Modified A compose<br/>app depends_on: database<br/>app environment: DB_HOST]
    Apply --> B_Modified[Modified B compose<br/>api depends_on: database<br/>api environment: DB_HOST]

    style A_WireWhen fill:#e1bee7,stroke:#4a148c
    style B_WireWhen fill:#e1bee7,stroke:#4a148c
    style Collect fill:#fff9c4,stroke:#f57f17
    style Apply fill:#c8e6c9,stroke:#2e7d32
    style A_Modified fill:#c8e6c9,stroke:#2e7d32
    style B_Modified fill:#c8e6c9,stroke:#2e7d32
```

**Key Principle**: Plugins declare "if X is loaded, wire me to X" rather than imperatively importing X. This enables any plugin to be the orchestrator - the result is the same regardless of who starts the composition.

## Profile Filtering Flow

```mermaid
flowchart LR
    Dep[Dependency] --> HasProfiles{Has profiles<br/>declared?}

    HasProfiles -->|No| Include[Include<br/>Always included]
    HasProfiles -->|Yes| CheckActive{Any active<br/>profiles?}

    CheckActive -->|No| Exclude[Exclude<br/>Profiles required<br/>but none active]
    CheckActive -->|Yes| Match{Profile<br/>matches<br/>active?}

    Match -->|Yes| Include
    Match -->|No| Exclude

    style Include fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
    style Exclude fill:#ffcdd2,stroke:#c62828,stroke-width:2px
```

**Examples**:
- `profiles: []` → Always included
- `profiles: ['dev']` + active `['dev']` → Included (match)
- `profiles: ['prod']` + active `['dev']` → Excluded (no match)
- `profiles: ['dev']` + active `[]` → Excluded (profiles required but none active)

## Dependency Graph Flattening

This diagram shows how a dependency tree is flattened into a list with deduplication.

```mermaid
graph TD
    subgraph "Input: Dependency Tree"
        Root[root/app]
        Root --> PluginA[plugin-a]
        Root --> PluginB[plugin-b]
        PluginA --> Common[common-lib]
        PluginB --> Common2[common-lib]
        PluginA --> DB[database]
    end

    subgraph "Depth-First Traversal"
        T1[1. Visit root] --> T2[2. Descend to plugin-a]
        T2 --> T3[3. Descend to common-lib]
        T3 --> T4[4. Add common-lib to result]
        T4 --> T5[5. Back to plugin-a]
        T5 --> T6[6. Descend to database]
        T6 --> T7[7. Add database to result]
        T7 --> T8[8. Back to plugin-a]
        T8 --> T9[9. Add plugin-a to result]
        T9 --> T10[10. Back to root]
        T10 --> T11[11. Descend to plugin-b]
        T11 --> T12[12. Try common-lib]
        T12 --> T13[13. Already seen - merge overrides]
        T13 --> T14[14. Back to plugin-b]
        T14 --> T15[15. Add plugin-b to result]
        T15 --> T16[16. Back to root]
        T16 --> T17[17. Add root to result]
    end

    subgraph "Output: Flat List (Dependency Order)"
        Out1[common-lib]
        Out2[database]
        Out3[plugin-a]
        Out4[plugin-b]
        Out5[root/app]

        Out1 --> Out2 --> Out3 --> Out4 --> Out5
    end

    style Root fill:#e1f5ff,stroke:#01579b,stroke-width:2px
    style Common fill:#ffcdd2,stroke:#c62828,stroke-width:2px
    style Common2 fill:#ffcdd2,stroke:#c62828,stroke-width:2px,stroke-dasharray: 5 5
    style Out1 fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
    style Out5 fill:#e1f5ff,stroke:#01579b,stroke-width:2px
```

**Key Features**:
- Depth-first traversal ensures dependencies appear before dependents
- Deduplication: Each plugin appears only once (first occurrence wins)
- Compose_overrides from duplicate occurrences are merged into first occurrence
- Result list is in dependency order (safe for Docker Compose startup)

## Test Architecture

```mermaid
graph LR
    subgraph "Unit Tests (122)"
        UT1[utils tests<br/>30+ tests]
        UT2[profiles tests<br/>8 tests]
        UT3[dependency_graph tests<br/>15+ tests]
        UT4[wiring tests<br/>8 tests]
        UT5[other tests<br/>60+ tests]
    end

    subgraph "Integration Tests (12)"
        IT1[Simple orchestration]
        IT2[Dependency loading]
        IT3[Wire-when rules]
        IT4[Profile filtering]
        IT5[Modifications]
        IT6[Fluent API]
        IT7[CLI parsing]
        IT8[Master compose]
        IT9[Resource deps]
        IT10[Nested deps]
        IT11[Multi-plugin]
        IT12[End-to-end]
    end

    subgraph "Test Fixtures"
        F1[plugin-a]
        F2[plugin-b]
        F3[plugin-c]
        F4[orchestrator]
    end

    UT1 --> Modules[lib/*.tilt modules]
    UT2 --> Modules
    UT3 --> Modules
    UT4 --> Modules
    UT5 --> Tiltfile

    IT1 --> F1
    IT2 --> F2
    IT3 --> F3
    IT4 --> F4
    IT5 --> F1
    IT6 --> F2

    Modules --> PublicAPI[Public API Functions]
    Tiltfile --> PublicAPI

    style UT1 fill:#e1bee7,stroke:#4a148c
    style UT2 fill:#e1bee7,stroke:#4a148c
    style UT3 fill:#e1bee7,stroke:#4a148c
    style UT4 fill:#e1bee7,stroke:#4a148c
    style IT1 fill:#c8e6c9,stroke:#2e7d32
    style IT12 fill:#c8e6c9,stroke:#2e7d32
    style PublicAPI fill:#fff9c4,stroke:#f57f17
```

**Test Strategy**:
- **Unit tests** validate individual functions and modules
- **Integration tests** validate end-to-end workflows using fluent API
- **Test fixtures** provide realistic plugin examples
- **Test wrappers** in main Tiltfile maintain backward compatibility

## Refactoring Timeline

```mermaid
timeline
    title Compose Composer Refactoring Journey

    section Phase 1: Safety Net
        Added integration tests : 12 tests
        Created test fixtures : 4 plugins
        Validated coverage : 134 total tests

    section Phase 2: Utils
        Extracted lib/utils.tilt : 330 lines
        Introduced struct pattern : Namespace syntax
        Main file reduction : -340 lines

    section Phase 3: Profiles
        Extracted lib/profiles.tilt : 105 lines
        Profile filtering : CLI + env var
        Main file reduction : -50 lines

    section Phase 4: Graph
        Extracted lib/dependency_graph.tilt : 233 lines
        Dependency injection : Multi-module
        Test wrappers : Backward compat
        Main file reduction : -160 lines

    section Phase 5: Wiring
        Extracted lib/wiring.tilt : 297 lines
        Symmetric orchestration : Declarative rules
        Main file reduction : -210 lines

    section Documentation
        Updated CLAUDE.md : Architecture docs
        Created lib/README.md : Module docs
        Created REFACTORING_SUMMARY.md : Journey docs
        Created ARCHITECTURE.md : Visual diagrams
```

## Success Metrics

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'primaryColor':'#e1f5ff','primaryTextColor':'#000','primaryBorderColor':'#01579b','lineColor':'#01579b','secondaryColor':'#c8e6c9','tertiaryColor':'#fff9c4'}}}%%
pie title Code Distribution After Refactoring
    "Tiltfile (Main)" : 1510
    "lib/utils.tilt" : 330
    "lib/profiles.tilt" : 105
    "lib/dependency_graph.tilt" : 233
    "lib/wiring.tilt" : 297
```

**Achievements**:
- ✅ **33% main file reduction** (2,270 → 1,510 lines)
- ✅ **100% test compatibility** (134/134 passing)
- ✅ **4 focused modules** created
- ✅ **Zero breaking changes** to public API
- ✅ **Clear design patterns** documented

---

**Legend for Diagrams**:
- 🟦 **Blue**: Main orchestration layer (Tiltfile)
- 🟪 **Purple**: Leaf modules (utils, profiles)
- 🟧 **Orange**: Mid-level modules (dependency_graph, wiring)
- 🟩 **Green**: Success/Include paths
- 🟥 **Red**: Failure/Exclude paths
- 🟨 **Yellow**: Generation/Output stages
