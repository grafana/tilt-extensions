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
# Grafana extension tests
cd grafana/test && bash test.sh

# var_subst extension tests
cd var_subst && make test
```

Both extensions use `tilt ci` for running tests in their respective test directories.

## How to Contribute

1. Fork the repository and create your branch from `main`.
2. Make your changes, following the conventions below.
3. Add or update tests for your changes.
4. Ensure tests pass.
5. Open a pull request.

## Extensions

### Grafana Extension

The `grafana` extension is a wrapper over the Grafana Helm chart for multi-plugin development. It supports:

- Single plugin development with Tiltfile at plugin root
- Parent project managing multiple plugins from separate repositories
- Live updates for rapid development via file syncing

### Variable Substitution Extension

The `var_subst` extension provides `${VAR}` and `${VAR:-default}` pattern replacement in templates with environment variable lookup.

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
