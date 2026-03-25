# tilt-extensions

Grafana Internal Tilt extensions

> **Note:** This project is under active development. APIs and extension interfaces may change.

This repo is for Grafana private Tilt extensions or extensions that are in development before being submitted to the upstream [tilt-dev/tilt-extensions: Extensions for Tilt](https://github.com/tilt-dev/tilt-extensions)

## Extensions

### Compose Composer

The flagship extension. Compose Composer enables dynamic, runtime assembly of Docker Compose environments from modular, reusable components called "[composables](https://github.com/grafana/composables)." Instead of maintaining monolithic docker-compose files, you build LEGO-block-style dev environments that wire themselves together automatically.

See the [compose_composer README](compose_composer/README.md) for full documentation and the [grafana/composables](https://github.com/grafana/composables) repository for reusable composable components.

### Other Extensions

- **grafana/** - A wrapper over the Grafana Helm chart for multi-plugin development
- **helm_chart/** - Utilities for working with Helm charts in Tilt
- **merge_dicts/** - Deep dictionary merging utility
- **post_build/** - Post-build step support for Tilt resources
- **var_subst/** - Variable substitution (`${VAR}` and `${VAR:-default}`) in templates

## Contributing

See our [contributing guide](CONTRIBUTING.md).

## License

[Apache License 2.0](LICENSE)
