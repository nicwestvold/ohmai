# Building from source

Needs Xcode 27 and [mise](https://mise.jdx.dev), which installs the pinned tools (XcodeGen, gh):

```sh
mise install          # once: pinned tools from mise.toml
mise run test         # package tests (fast, no Xcode project needed)
mise run build        # generates ohmai.xcodeproj and builds Debug
```

`mise tasks` lists the rest.

## Signing

To sign with your own Apple team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `OHMAI_TEAM_ID`. The lid helper's caller check is built from that value.

## README images

`mise run readme-shots` regenerates the images in `docs/images/` from a Debug build. It renders the app against a made-up demo world (fake projects, sessions and usage, in a temp folder), so nothing from your own machine ends up in them. Needs `brew install librsvg`.

## Releases

`mise run release` archives, signs with Developer ID, notarizes and staples the app, then builds a signed, notarized and stapled disk image (see `scripts/release.sh` and [updates.md](updates.md)). `mise run publish` attaches it to a GitHub release.

## Docs

- [design.md](design.md): scope, architecture, power policy, lid-closed mode, performance budget
- [agent-integrations.md](agent-integrations.md): how each agent's state and usage are read, with verified findings
- [updates.md](updates.md): why there are no in-app updates, and how updating by hand works
