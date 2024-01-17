# Grafana Tilt Extension

This tilt extension is a wrapper over the grafana helm chart. It's intended
use is for multi-plugin development. When passed a list of paths to `plugin.json` files
it will configure the helm chart with the appropriate provisioning configmap(s).

Default Grafana helm values are in `grafana-values.yaml`.

Usage is:
```
grafana(context, plugin_files, grafana_image='grafana/grafana', grafana_version='latest', namespace='grafana', deps=[], extra_env={}, extra_grafana_ini={}):
    """Deploys one or more plugin(s) in Grafana using the Helm Chart.

    Args:
        context          : The Docker context directory that is the root of the Dockerfile. Typically the 'plugin' directory
        plugin_files     : A path, or list of paths to the 'plugin.json' file for the plugin(s) you are running
        grafana_image    : The grafana image you want to use. Defaults to 'grafana/grafana'
        grafana_version  : The image tag for the version of grafana you want to use. Defaults to 'latest'
        namespace        : The Kubernetes namespace to deploy to. Defaults to 'default'
        deps             : A list of Tilt resources Grafana should wait for
        extra_env        : A dict of env vars to pass to Grafana
        extra_grafana_ini: A dict of key value pairs to configure the grafana.ini file

    Returns:
      Nothing
```