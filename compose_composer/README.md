# Compose Composer

A Tilt extension for dynamically assembling Docker Compose environments from modular, reusable components.

## Problem One: Tilt with Kubernetes is Slow and Complex

If you don't have a requirement for running local dev with Kubernetes, using tilt with Kubernetes requires extra components and overhead:

- A Kubernetes server - kind, k3d, etc
- Kubernetes manifests for each of your services - this is extra code to maintain that may not match your production env.
- An image registry - this adds an additional image push/pull step to the process.
- Mounting your local filesystem under the docker container is troublesome - a two step process that needs to be setup when you create the cluster.
- Hot reloading requires that tilt be precisely configured to inject changes into the running container on the cluster.

## Problem Two: Docker Compose is Too Rigid

Docker Compose doesn't support runtime composition. Each docker-compose file has a static list of service to start (profiles not withstanding)

1. **Monolithic stacks**: One huge docker-compose.yaml with everything. Any plugin change requires touching the central file.
2. **Copy-paste**: Duplicate infrastructure across projects. Hard to share reusable components.
3. **Include directives**: Static includes can't adapt to what's actually needed. You get everything or nothing.

What you really want is **LEGO blocks for dev environments** - reusable infrastructure components that you can assemble differently for each project, with the wiring happening automatically based on what's present.

## The Solution: Runtime Assembly of Docker Compose Components using Compose Composer

Compose Composer enables you to build reusable infrastructure components (we call them "composables") that can be assembled dynamically at runtime. Each composable is self-contained and knows how to wire itself to other components when they're present.

A "Composable" is a Tilt extension that wraps a docker-compose file and optionally exposes helper functions to further configure that service.

### Composables:

The [grafana/composables](https://github.com/grafana/composables) repository contains composables used across Grafana development:
- `k3s-apiserver` - A standalone Kubernetes API server with CRD loading and webhook support
- `grafana` - Grafana with MySQL, smart wiring to k3s when present
- `mysql`, `postgres`, `redis` - Databases that auto-configure when other services need them. E.g. `mimir` will auto-provision a datasource into Grafana when it's present.
- many more

As composables are tilt extensions, they can be loaded remotely from github or from the local file system.

Each application configured with Compose Composer is also a composable. `IRM`, `gops-labels`, `grafana-assistant-app`, etc. Any composable can be imported into any other composable. This also means that apps importing other apps is symmetrical:

From `IRM`:

```
    cd irm
    tilt up -- ../grafana-assistant-app
```

From `grafana-assistant-app`:

```
    cd grafana-assistant-app
    tilt up -- ../irm
```


### Orchestrators

An "Orchestrator" in compose composer is a composable where you run `tilt up ...` Any composable can be an orchestrator and `use` other composables as needed, even if those composables are themselves orchestrators.

## The Basic Structure

A Composable needs a few itmes:

1. A Tiltfile that defines its dependencies and the config
2. A docker-compose file that defines the minimal service config for its services

### Dependencies

Use the Compose Composer apis to import your dependencies:

```python
# Export yourself.
def cc_export(cc):
    # These are imported from grafana/composables
    k3s = cc_import(name='k3s-apiserver')
    grafana = cc_import(name='grafana')
    # Create the composable
    return cc_create(
        'my-plugin', 
        './docker-compose.yaml', 
        ...
    )
```

Where `./docker-compose.yaml` is the local app's compose file. 

**The result**: Your plugin gets exactly what it needs, components know how to work together, and you never duplicate infrastructure code.

Compose Composer:
1. **Fetches** the composables from git repos (or local paths)
2. **Resolves** transitive dependencies (grafana needs mysql, mysql is auto-included, duplicate dependencies are removed)
3. **Wires** components together (grafana auto-configures when it sees k3s, mimir auto-provisions datasources into Grafana)
4. **Generates** a master docker-compose.yaml using include directives (see .cc in the orchestrator's directory)
5. **Preserves** relative paths so volume mounts work correctly between composables.

## Getting started

### Writing an Orchestrator

If you need to create a composable that will also run as the entry point into Grafana, the structure looks like this.

Basic imports to include compose-composer as a Tilt extentions:

```python
COMPOSE_COMPOSER_URL = os.getenv('COMPOSE_COMPOSER_URL', 'https://github.com/grafana/tilt-extensions')
COMPOSE_COMPOSER_REF = os.getenv('COMPOSE_COMPOSER_REF', 'compose-composer')

# Set up extension repo
if __file__ == config.main_path:
    if COMPOSE_COMPOSER_REF:
        v1alpha1.extension_repo(name='grafana-tilt-extensions', url=COMPOSE_COMPOSER_URL, ref=COMPOSE_COMPOSER_REF)
    else:
        v1alpha1.extension_repo(name='grafana-tilt-extensions', url=COMPOSE_COMPOSER_URL)
    v1alpha1.extension(name='compose_composer', repo_name='grafana-tilt-extensions', repo_path='compose_composer')

load('ext://compose_composer', 'cc_init')
```

By using environment variables you can override the location or branch for compose-composer.

Next, create a `cc_export()` function that returns the composable. The basic structure looks like:

```python
def cc_export(cc):
    # Define a dependency on Grafana
    grafana = cc.use('grafana')

    # Create the composable
    return cc.create(
        'name-of-your-composable',

        # path to your minimial docker-compose file
        os.path.dirname(__file__) + '/docker-compose.yaml',

        # Tilt labels for the left-hand nav
        labels=['app'],

        # Tell compose-composer what the setup function is for this plugin. (see below)
        symbols={'cc_setup': cc_setup},

        modificiation=[] # overrides or helper methods for your dependencies
    )
```

If you need additional Tilt resources to be run, in addition to whatever is happening in your docker-compose, then put those in `cc_setup()`:

```python
def cc_setup(composable_ctx):
    local_resource('devenv-check', 'make devenv-check', labels=['SLO.Devenv'])

    # Build locally...do other stuff out-of-docker actions
```

Resources defined in `cc_setup` can take/put tilt dependencies on other resources. So you can define the order in which things start.

When you are an orchestrator, i.e. the project where `tilt up` is called, then define the "main" method:

```python
if __file__ == config.main_path:
    # Initialize compose_composer. 'cc' gets passed to other methods later
    # Here 'slo' becomes the docker-compose project name
    cc = cc_init('slo')

    # Parse and load CLI composables e.g. tilt up -- ../other-composable
    cli_plugins = cc.parse_cli_plugins()

    # Get the composable for this plugin
    slo = cc_export(cc) # this is from above
    master = cc.generate_master_compose(slo, cli_plugins)
    # start everything
    cc.docker_compose(master)
```

The modified and generated docker-compose.yaml files are written to the `.cc` directory in the orchestrator's directory.


### Examples of Ported Applications 

#### Grafana Assistant App
For another example, take a look at `compose_composer` as applied to the Grafana Assistant's `docker-compose`. The original [docker-compose.yaml](https://github.com/grafana/grafana-assistant-app/blob/compose-compose/docker-compose.yaml)

After compose-compose, the resulting [Tiltfile](https://github.com/grafana/grafana-assistant-app/blob/compose-compose/Tiltfile) and smaller [docker-compose.yaml](https://github.com/grafana/grafana-assistant-app/blob/compose-compose/assistant-compose.yaml). Notice how the shorted docker-compose file only deals with the application services. Tilt and compose-composer take care of the rest.

#### Service Model - A Simple AppPlatform App

ServiceModel is simple cloud AppPlatform app with a few CRDs and a controller. This [Tiltfile](https://github.com/grafana/service-model/blob/docker-compose/Tiltfile) has been ported to use compose-composer. Note the use of the `register_crds()` helper method. You can run it along side `grafana-assistant-app` like this when you have both checked out (from `grafana-assistant-app`):

```sh
% tilt up  -- --profile=core ../service-model
```

#### IRM

See IRM's [Tiltfile](https://github.com/grafana/irm/blob/compose-composer/Tiltfile)