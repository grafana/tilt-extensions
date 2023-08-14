# Testing the Grafana Tilt extension

Tilt has no exception handling (try/catch) so we can't setup and, most importantly, tear down things on a failing test.

Therefore, the directory structure for the test will be hard coded, and the Tiltfile for test is located in `parent/Tiltfile`

This is testing two directory structures:

1. A Tiltfile at the root of a plugin tree, for development of that plugin alone
2. A Tiltfile in a "parent" project, that will checkout all the other plugins, the control the Grafana that will load all the plugins
