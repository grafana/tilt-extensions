# Contributing Guidelines

This document is a guide to help you through the process of contributing to Grafana's internal Tilt extensions.

## Getting Started

This repository contains Grafana internal [Tilt](https://tilt.dev/) extensions for development and testing. Extensions here are either private to Grafana or in development before being submitted to the upstream [tilt-dev/tilt-extensions](https://github.com/tilt-dev/tilt-extensions) repository.

### Prerequisites

- [Tilt](https://docs.tilt.dev/install.html)
- [Docker](https://docs.docker.com/get-docker/) (with Compose)
- Make
- Bash

### Running Tests

```bash
# Compose Composer tests
cd compose_composer && make test

# Grafana extension tests
cd grafana/test && bash test.sh

# var_subst extension tests
cd var_subst && make test
```

All extensions use `tilt ci` for running tests in their respective test directories.

## How to Contribute

1. Fork the repository and create your branch from `main`.
2. Make your changes, following the conventions below.
3. Add or update tests for your changes.
4. Ensure tests pass.
5. Open a pull request.

## Extensions

### Compose Composer

The primary extension in this repository. Compose Composer enables dynamic, runtime assembly of Docker Compose environments from modular, reusable components called "[composables](https://github.com/grafana/composables)." Each composable wraps a docker-compose service and knows how to wire itself to other components when they're present.

Key concepts:

- **Composables** are Tilt extensions that wrap a docker-compose file and expose helper functions via `cc_export()`.
- **Orchestrators** are composables where you run `tilt up`. Any composable can be an orchestrator.
- **Wire-when rules** define declarative wiring — how components configure themselves when other dependencies are present.

The companion [grafana/composables](https://github.com/grafana/composables) repository contains reusable composables (grafana, mysql, redis, k3s-apiserver, etc.) used across Grafana development.

See the [compose_composer README](compose_composer/README.md) for full documentation and examples.

### Other Extensions

- **grafana/** - A wrapper over the Grafana Helm chart for multi-plugin development (single or multi-plugin, with live update support)
- **helm_chart/** - Utilities for working with Helm charts in Tilt
- **merge_dicts/** - Deep dictionary merging utility
- **post_build/** - Post-build step support for Tilt resources
- **var_subst/** - Variable substitution (`${VAR}` and `${VAR:-default}`) in templates

## Code Style

All extension code is **Starlark** (not Python). Key conventions:

- Use `load()` instead of `import`; use `struct()` instead of classes.
- Type checking: `type(x) != 'string'` (not `isinstance`).
- No `try/except` — validate inputs and call `fail()` on errors.
- Extensions are loaded using Tilt's `load()` function.

## Reporting Issues

See our [issue templates](https://github.com/grafana/tilt-extensions/issues/new/choose) or join the [discussions](https://github.com/grafana/tilt-extensions/discussions).

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
