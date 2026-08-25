# Changelog

All notable changes to this project are documented here. The format loosely
follows [Keep a Changelog](https://keepachangelog.com/); versions are
`major.minor.patch` starting at `0.1.0`.

## [Unreleased]

### Fixed

- **Overlay never loaded**: `TrailOverlay.qml` used the non-existent
  `Component.onDestroyed` handler, which failed the segment component compile,
  poisoned `TrailOverlay`, and killed the whole `CaretTrail.qml` load. No layer
  surfaces were ever created. Replaced with `Component.onDestruction`.
- **Trails invisible even when loaded**: the trail fragment shader reads a
  `resolution` uniform that `TrailSegment.qml` never provided, so all distance
  math ran against `(0, 0)` and output alpha was ~0 everywhere. The quad's pixel
  size is now fed via `Qt.vector2d(width, height)`.
- **Shader asset unusable on OpenGL**: the committed `trail.frag.qsb` contained
  only SPIR-V; GL backends logged `No GLSL shader code found` and skipped every
  segment. Rebaked with `qsb --qt6` so GLSL ES 100 / 120 / 150 variants ship.
- **Sensor socket was single-client and evicting**: every new connection closed
  the previous one, so running `socat` for debugging kicked the shell overlay
  offline (and the overlay's reconnect then kicked `socat`). The server now
  broadcasts to up to 8 concurrent subscribers and prunes dead peers.
- **Client sockets were blocking**: sends run on the compositor's tick thread,
  so a stalled reader could in principle freeze Hyprland once its socket buffer
  filled. Clients are now non-blocking: stalled readers skip updates, broken or
  too-slow ones are dropped.
- **Reconnect could wedge forever**: if the shell started before the native
  plugin created its socket, the retry timer set an already-`true`
  `Socket.connected` and no new attempt ever fired. The timer now toggles the
  connection state so attempts re-fire every 2 s.

### Changed

- Install flow: `hyprpm.toml` now carries a real commit pin (Hyprland 0.56.2 →
  plugin commit) instead of a placeholder that made `hyprpm add` fail with
  `bad commit pin`; `scripts/install.sh` runs `hyprpm update` before
  `hyprpm add`; README documents the mandatory first-run header bootstrap plus a
  troubleshooting table.

## [0.1.0] - 2026-08-25

- Initial release: caret position sensor plugin (`caret-tracker`) publishing
  focused `text-input-v3` cursor rectangles over a local unix socket, plus the
  Quickshell overlay (`CaretTrail.qml`, `TrailOverlay.qml`, `TrailSegment.qml`)
  drawing a 1-second fading glow line between caret positions.
