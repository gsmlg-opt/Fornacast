## UI Library

This project uses DuskMoon Web 2. Lock its Hex and npm dependencies to the same published version.

- **`duskmoon_phoenix`** - Phoenix components on Hex and native CSS and JavaScript on npm
- **`@duskmoon-dev/core`** - Core Tailwind CSS plugin and utilities
- **`@duskmoon-dev/el-alert`** - custom element used by `dm_alert`

Use `DuskmoonPhoenix.Component` and project compositions from `fornacast_component` for the web UI. Do NOT use DaisyUI, other CSS component libraries, or `core_components.ex`.
Use `@duskmoon-dev/core/plugin` as the Tailwind CSS plugin.

### Reporting issues or feature requests

Report Phoenix component, Core, and Elements issues in the consolidated repository with the label `internal request`. [DuskMoon Web issues](https://github.com/duskmoon-dev/duskmoon-web/issues)
