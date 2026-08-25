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

## Install (Omarchy)

Requirements: `base-devel`, `cmake`, Hyprland >= 0.56 (headers come with the
package), quickshell.

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

Pipeline stage complete; GLSL particle simulation is next and lives entirely on
the Quickshell side (`shaders/`), consuming the properties above.
