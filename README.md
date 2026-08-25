# ogarza.plugins.caret-trails

A global particle trail that follows the text caret (insertion cursor) of
whichever application currently has text focus. Application-independent:
anything that speaks Wayland `text-input-v3` works — no per-app plugins.

```
App caret -> text-input-v3 -> Hyprland -> caret-tracker.so -> unix socket -> Quickshell -> GLSL particles*
```

`*` particle rendering not implemented yet; this repo currently delivers the
reliable position pipeline end-to-end.

Components:

- `hyprland-plugin/` — tiny native Hyprland plugin ("sensor"). Reads the
  focused `CTextInput`'s cursor rectangle every compositor tick via the current
  typed event bus (`Event::bus()->m_events.tick`), converts it to global
  coordinates (`getSurfaceBoxGlobal()`), and publishes changes as newline-
  delimited JSON on `$XDG_RUNTIME_DIR/caret-trails.sock`. No rendering logic,
  no function hooks.
- `CaretTrail.qml` — Omarchy shell overlay that consumes the socket and exposes
  `status`, `caretActive`, `caretX/Y/Width/Height`, and ready-made emitter
  coordinates (`emitterX`, `emitterY`) as QML properties.
- `TrailOverlay.qml` + `TrailSegment.qml` + `shaders/trail.frag(.qsb)` — the
  visual effect: a glowing line is drawn from the previous caret position to
  the new one whenever the caret moves, then fades out over exactly one second.
  Each screen hosts a transparent, click-through layer-shell overlay
  (`WlrLayer.Overlay`, empty input mask); segments are bounding-box-sized
  `ShaderEffect`s running the GLSL trail shader.

## Install (Omarchy)

### Dependencies

| Package | Why | Preinstalled on Omarchy? |
|---|---|---|
| `hyprland` >= 0.56 | compositor, plugin headers, `pkg-config` file, and `hyprpm` all ship with this package | yes |
| `quickshell` | runs the shell overlay + trail effect | yes |
| `base-devel` | C++ toolchain (`g++`, `make`, etc.) used to build the native plugin | yes |
| `cmake` | configures the plugin build (`hyprpm.toml` build steps use it) | **no — must be installed** |
| `git` | `omarchy plugin add` / `hyprpm add` clone this repo | yes |
| `socat` *(optional)* | watch the live caret stream for debugging | usually present |

Install anything missing with:

```bash
omarchy pkg add cmake
```

(Verified on a stock Omarchy system 2026-08-25: only `cmake` was missing;
everything else above ships with the base install.)

```bash
# 1) Shell side (overlay + receiver)
omarchy plugin add https://github.com/ogarza/ogarza.plugins.caret-trails --enable

# 2) Native sensor (builds against YOUR installed Hyprland)
hyprpm add https://github.com/ogarza/ogarza.plugins.caret-trails
hyprpm enable caret-tracker
```

Or in one step:

```bash
git clone https://github.com/ogarza/ogarza.plugins.caret-trails && ./ogarza.plugins.caret-trails/scripts/install.sh
```

Verify the sensor is publishing:

```bash
socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/caret-trails.sock
# {"protocol":1,"plugin":"caret-tracker","status":"ready"}
# ...then type somewhere: {"protocol":1,"active":true,"x":734,"y":412,"width":2,"height":20}
```

The QML overlay degrades gracefully: with the native plugin absent it stays
loaded but reports `Status.Unavailable`; a wire-protocol mismatch reports
`Status.Incompatible`.

## Updating

| Situation | Action |
|---|---|
| Plugin updated | `omarchy plugin update` + `hyprpm update` |
| Hyprland was updated (`omarchy update`) | `hyprpm update` (add `-f` if needed) rebuilds against new headers |
| New Hyprland release, plugin broken | wait for/pull a fix; `commit_pins` in `hyprpm.toml` keeps known-good pairs |

Useful: `hyprpm list`, `hyprpm reload`, `omarchy restart shell`.

## Removing

```bash
hyprpm disable caret-tracker
hyprpm remove https://github.com/ogarza/ogarza.plugins.caret-trails
omarchy plugin remove ogarza.caret-trails
```

## Compatibility

Tracking works when the focused app reports its cursor rectangle over
`zwp_text_input_v3`: GTK4/GTK3, Qt6, Firefox on native Wayland, Chromium/
Electron with ozone-wayland IME enabled, foot. It cannot work for XWayland
windows (no protocol bridge) or Electron running in default X11 mode, and
terminals vary (see DESIGN.md §7 for details and confidence levels).

## Status

Position pipeline complete, plus a first visual: the 1-second fading trail
line. The full GLSL particle simulation is next and lives entirely on the
Quickshell side (`shaders/`), consuming the properties above.

### Trail tuning

| Knob | Where | Default |
|---|---|---|
| trail color | `TrailSegment.qml` `tint` (vector3d) | sky blue `(0.22, 0.74, 0.97)` |
| lifetime | fade animation `duration` in `TrailSegment.qml` | `1000` ms |
| glow/width/pulse shape | `shaders/trail.frag` | core ~3 px + exponential glow |
| spawn sensitivity | `CaretTrail.qml` `noteCaretMove()` thresholds | 4 px, or 200 ms / 1 px |
| max concurrent trails | `TrailOverlay.qml` `maxActive` | 48 |

Qt 6 `ShaderEffect` cannot take inline GLSL — shaders are authored in
Vulkan-style GLSL (`shaders/trail.frag`) and compiled to `.qsb` with the
`qsb` tool from `qt6-shadertools`. The compiled `.qsb` is committed, so this
package is only needed when editing shaders; after changing the `.frag`,
regenerate it:

```bash
/usr/lib/qt6/bin/qsb shaders/trail.frag -o shaders/trail.frag.qsb
```
