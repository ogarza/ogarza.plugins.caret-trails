I want to build an Omarchy plugin that creates a global particle trail following the text caret (insertion cursor) of whichever application currently has keyboard/text focus.

The visual/UI portion will be Quickshell/QML + GLSL. To obtain the caret position globally, I want to provide a small native Hyprland plugin that acts as a caret-position sensor.

The Omarchy plugin will be distributed as source through a Git repository. The native Hyprland component should be distributed as a Hyprland plugin compatible with the CURRENT `hyprpm` plugin manager rather than as a precompiled `.so`.

Please design the Hyprland plugin portion based on Hyprland's CURRENT source/API, not assumptions from older versions.

> **STATUS (2026-08-25): IMPLEMENTED AND VERIFIED.** The pipeline described below now exists in this
> directory (`hyprland-plugin/src/main.cpp`, `CaretTrail.qml`, `hyprpm.toml`, `manifest.json`, `README.md`,
> `DESIGN.md`). It was built against the *installed* Hyprland 0.56.2 headers and Quickshell 0.3.1, compiled
> cleanly, and its plugin symbols were verified. Everything below the original spec (at the bottom of this
> file) is an appendix of verified findings captured during that work — use it instead of re-researching
> if you ever need to rebuild.

# Overall goal

I want this behavior:

- I have multiple windows open simultaneously, e.g. Firefox, Kitty, VS Code, Discord, etc.
- Whichever application currently has the text caret should be tracked.
- When the caret moves normally, a particle trail follows it.
- When the caret jumps a large distance (e.g. clicking elsewhere, jumping lines, switching windows), particles should travel/burst between the old and new caret positions.
- I do NOT want to write a separate plugin for Neovim, Firefox, VS Code, etc.
- I want the solution to be application-independent wherever the application participates in Wayland text-input-v3.
- Quickshell will render the transparent overlay and GLSL particle effect.
- The Hyprland plugin's job is only to obtain the caret position and communicate it to Quickshell.
- The Hyprland plugin should contain no particle simulation or rendering logic.

The architecture should be:

    Application
        ↓
    Wayland text-input-v3
        ↓
    Hyprland
        ↓
    native Hyprland caret-tracker plugin
        ↓
    local IPC / Unix socket
        ↓
    Quickshell
        ↓
    GLSL particle shader

The Hyprland plugin should essentially be a "sensor":

    "The caret is currently at x=734, y=412, w=2, h=20."

Quickshell is responsible for turning that information into animation, velocity, trails, bursts, interpolation, and particles.

# Important finding from investigating current Hyprland source

Hyprland already implements Wayland `zwp_text_input_v3`.

The relevant source architecture appears to be:

    Wayland text-input-v3
            ↓
    CTextInputV3
            ↓
    CTextInput
            ↓
    CInputMethodRelay
            ↓
    getFocusedTextInput()
            ↓
    cursorBox()
            ↓
    focusedSurface()
            ↓
    surface global position
            ↓
    global caret coordinates

Current Hyprland source has `CTextInput` methods along the lines of:

    bool hasCursorRectangle();
    CBox cursorBox();
    SP<CWLSurfaceResource> focusedSurface();

And `CInputMethodRelay` has:

    CTextInput* getFocusedTextInput();

Hyprland's own InputMethodPopup code already uses this machinery to position IME popups. It gets the focused text input, checks `hasCursorRectangle()`, obtains `cursorBox()`, and combines it with the focused surface's global position.

The text-input-v3 implementation stores the rectangle supplied by the application through:

    set_cursor_rectangle(x, y, width, height)

Therefore, I do NOT want to visually detect the caret from the framebuffer and I do NOT want application-specific integrations unless absolutely necessary.

# Critical implementation requirement: use Event Hooks / compositor ticks

Prefer Hyprland EVENT HOOKS / compositor tick callbacks over function hooks.

Hyprland's plugin guidelines explicitly recommend Event Hooks over Function Hooks. Function hooks should only be considered if there is a compelling reason.

I want the plugin to observe changes using stable compositor events/ticks rather than hooking an internal function such as `CTextInput::onCommit()` unless the current Hyprland API provides no suitable event-based alternative.

A likely first implementation is:

1. Register for the current Hyprland compositor tick event.
2. On each tick:
   - obtain `g_pInputManager->m_relay.getFocusedTextInput()`
   - verify the pointer is valid
   - check `hasCursorRectangle()`
   - obtain `cursorBox()`
   - obtain the focused surface
   - obtain the surface's global box/position
   - calculate global caret coordinates
3. Compare the result with the previous coordinates/state.
4. Only send an update when the caret/focus changes.
5. Send the coordinates to Quickshell through a small IPC mechanism, preferably a Unix domain socket or another simple local IPC mechanism.

If the current Hyprland source provides a more appropriate stable event specifically associated with text-input changes, explain it and use it instead.

Do NOT assume a particular event name from an old version.

# Coordinate calculation

The cursor rectangle from text-input-v3 is surface-local.

The intended calculation is approximately:

    globalCaretX = surfaceGlobalX + cursorBox.x
    globalCaretY = surfaceGlobalY + cursorBox.y

with width/height retained.

For the particle emitter, Quickshell may eventually use the bottom-center of the caret:

    emitterX = globalCaretX + cursorBox.width / 2
    emitterY = globalCaretY + cursorBox.height

But initially the native plugin should report the raw global rectangle:

    x
    y
    width
    height

Also verify whether the current Hyprland source uses `getSurfaceBoxGlobal()` or another current API for this transformation.

# Focus/window changes

The plugin must correctly handle:

- switching between windows
- switching between applications
- entering/leaving text input
- an application losing text focus
- an application not providing a cursor rectangle
- the focused surface changing
- scrolling
- caret movement within the same surface
- the focused text input object changing

If there is no focused text input or no valid cursor rectangle, send an appropriate "no caret" state rather than leaving stale coordinates indefinitely.

For example:

    {
      "active": false
    }

# IPC between Hyprland and Quickshell

The Hyprland plugin should expose a tiny local IPC interface to Quickshell.

A possible message format is:

    {
      "active": true,
      "x": 734,
      "y": 412,
      "width": 2,
      "height": 20
    }

Potentially include:

    timestamp
    surface/window identifier
    focused state

but do not overcomplicate the first implementation.

Recommend the best IPC mechanism for a Hyprland plugin communicating with a Quickshell instance.

I am specifically interested in something that is:

- local-only
- low latency
- simple
- reliable
- easy to implement in C++ on the Hyprland side
- easy to consume from Quickshell/QML

Do not assume that Hyprland plugin custom events automatically become available through Quickshell's `Hyprland.rawEvent()`.

Treat:

    Hyprland plugin event bus

and:

    Hyprland IPC/socket2

as separate mechanisms unless the current source proves otherwise.

A Unix-domain socket owned by the user is a strong candidate.

# Plugin ↔ Quickshell separation

Keep the responsibilities strictly separated.

Hyprland plugin:

    - obtain focused text input
    - obtain cursor rectangle
    - convert to global coordinates
    - detect state/position changes
    - communicate coordinates
    - nothing related to particle rendering

Quickshell:

    - receive caret coordinates
    - maintain previous/current position
    - calculate movement/velocity
    - detect large jumps
    - control animation
    - render transparent overlay
    - provide shader uniforms
    - run GLSL particle simulation

This means the visual effect can evolve independently of the Hyprland plugin.

# Application compatibility

Explain precisely what happens when an application does NOT implement or use `zwp_text_input_v3` / `set_cursor_rectangle()`.

The intended limitation is:

    application reports cursor rectangle
        ↓
    Hyprland knows caret position
        ↓
    plugin can obtain it

versus:

    application does not report caret rectangle
        ↓
    Hyprland does not have semantic caret coordinates
        ↓
    plugin cannot magically obtain them

I understand this means the system won't literally work with every application.

Please identify likely compatibility issues with:

- XWayland applications
- Electron
- GTK
- Qt
- Firefox
- Kitty
- foot
- VS Code
- Neovim
- terminals running Neovim

Do not make unsupported claims; distinguish confirmed support from assumptions.

# Hyprland plugin distribution: hyprpm

This will be distributed as an Omarchy plugin, but the native component should be a normal Hyprland plugin managed by the CURRENT `hyprpm` system.

Do NOT distribute a precompiled Hyprland `.so` as the primary mechanism.

The intended installation flow is:

    Omarchy user
         ↓
    installs/clones the Omarchy plugin
         ↓
    hyprpm adds the Hyprland plugin repository
         ↓
    hyprpm builds the native component against the user's Hyprland
         ↓
    Hyprland loads the caret-tracker plugin
         ↓
    Quickshell communicates with it over local IPC

Please investigate the CURRENT `hyprpm` workflow and use it if it is the recommended/current mechanism.

In particular, verify:

- current `hyprpm` commands
- current `hyprpm.toml` format
- how a plugin repository is declared
- how source commits are pinned
- how Hyprland API/header compatibility is handled
- how plugins are built
- how plugins are enabled/disabled
- how plugins are updated
- how plugins are reloaded after rebuilding
- whether `hyprpm` automatically builds against the installed Hyprland version
- what happens when Hyprland updates
- how to handle incompatible plugin commits/API versions

I want the final installation instructions to be suitable for an Omarchy user and as simple as possible.

Ideally the native component should be installable with something conceptually like:

    hyprpm add https://github.com/<user>/<repo>
    hyprpm enable caret-tracker

or whatever the CURRENT correct syntax is.

Do not assume these exact commands; verify them against current Hyprland documentation.

If `hyprpm` requires the plugin repository to have a specific structure or `hyprpm.toml`, implement the plugin accordingly.

# Version compatibility

Because this is a native Hyprland plugin, version compatibility is a major concern.

Design the plugin so that it can detect incompatible Hyprland versions and fail gracefully rather than crashing Hyprland.

Consider providing a small protocol/version handshake to Quickshell, e.g.:

    {
      "protocol": 1,
      "plugin": "caret-tracker",
      "status": "ready"
    }

Quickshell should be able to distinguish:

    native plugin absent
        ↓
    show "caret tracking unavailable"

    native plugin present but incompatible
        ↓
    show "update/rebuild caret tracker"

    native plugin working
        ↓
    enable particle effect

Do not overengineer this in the first implementation, but design the interfaces so this can be added cleanly.

Also explain how Hyprland plugin API changes should be handled in the repository.

If pinning to a specific Hyprland commit/API version is recommended by current `hyprpm` documentation, explain the tradeoff between:

- tracking Hyprland's latest API
- pinning to known-compatible commits
- supporting a range of Hyprland versions

# Quickshell failure behavior

The Quickshell plugin must still load if the native Hyprland component is absent.

If the IPC socket does not exist:

    native caret tracking unavailable

The Quickshell plugin should not crash or break the rest of the Omarchy shell.

The native component is an optional enhancement to the Quickshell plugin.

# Repository structure

Suggest a repository structure appropriate for an Omarchy plugin containing both Quickshell and Hyprland components.

For example:

    caret-trails/
    ├── manifest.json
    ├── qml/
    │   ├── CaretTrail.qml
    │   └── ...
    ├── shaders/
    │   └── particles.frag
    ├── hyprland/
    │   ├── src/
    │   │   └── main.cpp
    │   ├── CMakeLists.txt
    │   └── hyprpm.toml
    ├── README.md
    └── ...

Verify the actual current `hyprpm` repository requirements before finalizing this structure.

# Current authoritative documentation / references

Use these references while designing the implementation. Prefer CURRENT documentation/source over older tutorials.

Hyprland plugin development:

    https://wiki.hypr.land/Plugins/Development/

    https://wiki.hypr.land/Plugins/Development/Getting-Started/

    https://wiki.hypr.land/Plugins/Development/Plugin-Guidelines/

    https://wiki.hypr.land/Plugins/Using-Plugins/

Important:
- Hyprland's current plugin documentation should be treated as authoritative for the plugin API, build system, loading, unloading, and version compatibility.
- The plugin guidelines explicitly recommend Event Hooks over Function Hooks.
- Verify all API names and examples against the CURRENT Hyprland source rather than copying from old plugin tutorials.
- Investigate current `hyprpm` support and use it as the preferred distribution/build/load mechanism if appropriate.
- Investigate `hyprpm.toml`, commit pinning, API/header compatibility, and current plugin repository requirements before writing the build/install instructions.

Wayland text-input-v3:

    https://wayland.app/protocols/text-input-unstable-v3

This protocol documentation is important because it defines:

    zwp_text_input_v3.set_cursor_rectangle(x, y, width, height)

The cursor rectangle is specified in surface-local coordinates.

The protocol also explicitly states that if the client is unaware of the position of the edited text, it should not issue `set_cursor_rectangle()`.

Therefore the plugin must gracefully handle applications for which no cursor rectangle is available.

Quickshell:

    https://quickshell.org/docs/

Use Quickshell documentation to determine the CURRENT recommended way to:

- create the transparent overlay
- receive local IPC
- expose caret coordinates as QML properties
- pass those properties to a shader
- handle the native helper/plugin being unavailable

Do not assume Quickshell has a direct text-input-v3 API.

The expected architecture is that Hyprland obtains the caret rectangle and Quickshell receives the resulting global coordinates over local IPC.

# Important source/API verification

Before writing implementation code, inspect the CURRENT Hyprland source and plugin API.

Specifically verify:

- current location/name of `CTextInput`
- current location/name of `CInputMethodRelay`
- current API for `getFocusedTextInput()`
- current API for `cursorBox()`
- current API for `hasCursorRectangle()`
- current API for obtaining the focused surface
- current API for obtaining a surface's global box
- current plugin event/tick registration mechanism
- current recommended plugin lifecycle/unload behavior
- current plugin build system
- current `hyprpm` manifest format
- current plugin loading/install mechanism
- current plugin ABI/version checks
- current recommended way to pin/track compatible Hyprland commits

Hyprland plugin APIs change over time.

DO NOT blindly copy code from old Hyprland plugin tutorials.

If an API has changed in the current version, show the current equivalent.

If an internal API is unavoidable, explicitly identify it and explain the compatibility risk.

# Desired output

Please produce:

1. A concise architecture explanation.
2. The exact current Hyprland source/API path used to obtain the caret.
3. The exact current event/tick mechanism you recommend.
4. A minimal current Hyprland plugin implementation that:
   - tracks the focused text input
   - obtains its cursor rectangle
   - converts it to global coordinates
   - detects changes
   - handles focus/no-caret state
   - sends updates over IPC
5. The IPC protocol.
6. A minimal Quickshell-side receiver example showing how the coordinates become QML properties.
7. A current `hyprpm.toml` / plugin repository configuration, if required.
8. The current recommended Hyprland plugin build configuration.
9. Exact current `hyprpm` commands for adding, building, enabling, disabling, updating, and removing the plugin.
10. Instructions for integrating those steps into an Omarchy plugin installation flow.
11. Notes about Hyprland version compatibility and how to handle Hyprland updates.
12. Notes about race conditions, focus changes, stale state, socket disconnects, and plugin unloading.
13. A compatibility discussion for applications that don't expose caret rectangles.
14. A suggested final repository structure for the Omarchy plugin.
15. A concise installation section that I could put directly into the project's README.

Do NOT implement the particle shader yet.

The immediate goal is to make this pipeline reliable:

    Application caret
        ↓
    Wayland text-input-v3
        ↓
    Hyprland
        ↓
    Hyprland native plugin
        ↓
    Unix/local IPC
        ↓
    Quickshell

Once that works, the particle rendering can be developed independently.

Most importantly:

- Use CURRENT Hyprland APIs.
- Prefer EVENT HOOKS / compositor tick callbacks over fragile function hooks.
- Use `hyprpm` as the preferred Hyprland plugin distribution/build/load mechanism if current documentation confirms it.
- Do not distribute a precompiled Hyprland `.so` as the primary mechanism.
- Compile against the user's installed Hyprland.
- Do not require application-specific plugins.
- Keep the native plugin extremely small and focused.
- Keep all visual/animation logic in Quickshell/GLSL.
- Handle missing/incompatible native plugins gracefully.

---

# APPENDIX — VERIFIED FINDINGS & IMPLEMENTATION CONTEXT (2026-08-25)

Everything below was verified against the actual installed software on this
machine, not documentation from memory. If Hyprland moves to a newer major
version, re-check the file:line references.

## A1. Environment snapshot

| Component | Version / path |
|---|---|
| OS | Omarchy (Arch-based), Linux |
| Hyprland | 0.56.2-1, commit `efb50993780079460b0cbed1363e2166a2de1d9f`, tag v0.56.2 |
| Hyprland headers | `/usr/include/hyprland` (installed by the `hyprland` package; no separate dev package needed) |
| pkg-config file | `/usr/share/pkgconfig/hyprland.pc`; Cflags: `-I/usr/include -I/usr/include/hyprland/protocols -I/usr/include/hyprland -I/usr/include/hyprland/src` (pkg-config may dedupe `-I/usr/include`) |
| aquamarine / hyprutils | 0.14.0 / 0.14.1 |
| Quickshell | 0.3.1-1, QML modules at `/usr/lib/qt6/qml/Quickshell/`, type info in `quickshell-core.qmltypes` + `Quickshell/Io/quickshell-io.qmltypes` |
| hyprpm | `/usr/bin/hyprpm` (ships with Hyprland) |
| cmake | NOT installed on this machine at build-test time; compile validation done with g++ directly (see A7) |

Source used for verification: `https://github.com/hyprwm/Hyprland/archive/refs/tags/v0.56.2.tar.gz`
(extracted to `/tmp/opencode/hlsrc` during development).

## A2. Verified Hyprland API (0.56.2) — exact paths

| What | Symbol | Location |
|---|---|---|
| Input manager global | `inline UP<CInputManager> g_pInputManager;` | `src/managers/input/InputManager.hpp:313` |
| Text-input relay, PUBLIC member | `CInputMethodRelay m_relay;` | `src/managers/input/InputManager.hpp:188` |
| Focused text input | `CTextInput* CInputMethodRelay::getFocusedTextInput()` | declared `InputMethodRelay.hpp:33`; impl `src/managers/input/InputMethodRelay.cpp:73` |
| Cursor rect present? | `bool CTextInput::hasCursorRectangle()` | `src/managers/input/TextInput.cpp:299`: `return !isV3() || m_v3Input->m_current.box.updated;` |
| Cursor rect (surface-local) | `CBox CTextInput::cursorBox()` | `src/managers/input/TextInput.cpp:303`: returns v3 `m_current.box.cursorBox` or v1 cursor rectangle |
| Enabled? | `bool CTextInput::isEnabled()` | `src/managers/input/TextInput.cpp:307`: v3 -> `m_current.enabled.value` |
| Focused surface | `SP<CWLSurfaceResource> CTextInput::focusedSurface()` | `src/managers/input/TextInput.hpp:36` |
| Resource -> view wrapper | `static SP<Desktop::View::CWLSurface> Desktop::View::CWLSurface::fromResource(SP<CWLSurfaceResource>)` | `src/desktop/view/WLSurface.hpp:76` |
| View wrapper -> global box | `std::optional<CBox> getSurfaceBoxGlobal() const` | `src/desktop/view/WLSurface.hpp:48` |
| Tick event | `Event<> tick` in `Event::bus()->m_events` | declared `src/event/EventBus.hpp:72`; emitted `src/animation/AnimationManager.cpp:358` (per frame, self-rescheduling) |
| Other bus events of interest | `input.keyboard.focus` (`Event<SP<CWLSurfaceResource>>`), `window.active` (`Event<PHLWINDOW, Desktop::eFocusReason>`), `ready`, `start`, `exit` | same struct |
| Logger | `Log::logger->log(Log::ERR, "fmt {}", args)` | `src/debug/log/Logger.hpp` — NOTE: `src/debug/Log.hpp` no longer exists; logger is `Hyprutils::CLI::CLogger` under `debug/log/` |

Key behavioral facts:

- `getFocusedTextInput()` does NOT require a connected IME. Implementation:
  returns nullptr if no keyboard focus surface; otherwise first text input with
  `focusedSurface() == keyboard-focus surface && isEnabled()`, else any with
  matching surface. Works on a plain desktop without fcitx5/IME.
- Canonical global-coordinate pattern is Hyprland's own `CInputPopup`
  (`src/managers/input/InputMethodPopup.cpp`, v0.56.2):
  `parentBox = OWNER->getSurfaceBoxGlobal().value_or(CBox{...});` then adds
  surface-local offsets. So YES, the current transform API is
  `getSurfaceBoxGlobal()` (returns `std::optional<CBox>`).
- `CBox` members are `x, y, w, h`.
- text-input-v3 state lives in `CTextInputV3::m_pending` / `m_current`
  (`SState`), each containing `box.updated` + `box.cursorBox`
  (`src/protocols/TextInputV3.hpp`); commit copies pending -> current.

## A3. CRITICAL: event hook API changed

- `HyprlandAPI::registerCallbackDynamic()` is **deprecated AND a no-op** in
  0.56.2 (`PluginAPI.hpp:175` comment: "doesn't do anything anymore, use
  Event::bus()"). Old string-hook tutorials are dead code here.
- Current mechanism: typed signals from hyprutils:

  ```cpp
  #include <hyprland/src/event/EventBus.hpp>
  CHyprSignalListener l = Event::bus()->m_events.tick.listen([] { /* ... */ });
  ```

- `CHyprSignalListener` is `Hyprutils::Memory::CSharedPointer<CSignalListener>`
  (`hyprutils/signal/Listener.hpp`). The listener MUST be kept alive (nodiscard);
  dropping/resetting it unregisters. Plugin stores it in a static and calls
  `.reset()` in `pluginExit()`. There is also `listenStatic()` (dies with signal).
- No function hooks used anywhere. Per-tick polling (~5 accessor calls/frame)
  covers caret motion inside a surface, scrolling, window moves, focus changes,
  and enter/leave — dedicated events (`window.active`, `input.keyboard.focus`)
  would save at most one frame of latency and add coupling, so they were not used.

## A4. Plugin skeleton facts (verified against upstream `borders-plus-plus`)

```cpp
#define WLR_USE_UNSTABLE            // first line, matches official plugins

#include <hyprland/src/plugins/PluginAPI.hpp>
// ... other <hyprland/src/...> includes

APICALL EXPORT std::string pluginAPIVersion() { return HYPRLAND_API_VERSION; }   // HYPRLAND_API_VERSION == "0.1"
APICALL EXPORT PLUGIN_DESCRIPTION_INFO pluginInit(HANDLE handle);               // return {name, description, author, version}
APICALL EXPORT void pluginExit();
```

- Official version-guard pattern (in `pluginInit`): compare
  `__hyprland_api_get_hash()` vs `__hyprland_api_get_client_hash()`; throw
  `std::runtime_error` on mismatch -> clean load failure, never a broken sensor.
  The loader itself also checks before calling init.
- Include style is `<hyprland/src/...>` (resolves via `-I/usr/include`).
- Required exported symbols verified after build:
  `pluginAPIVersion`, `pluginInit`, `pluginExit`,
  `__hyprland_api_get_client_hash`.

## A5. hyprpm — verified commands and manifest format

From the installed binary (`hyprpm --help`):

```
add <url> [git rev]           install repo (rev set => commit locks ignored)
remove <url|name|author/name>
enable / disable <name|author/name>
update                        check & update all (add -f to force)
reload                        reload hyprpm state / ensure enabled plugins loaded
list                          list installed plugins
purge-cache                   nuke cache+headers+built plugins
Flags: --no-nix, --notify/-n, --verbose/-v, --force/-f, --no-shallow/-s, --hl-url
```

`hyprpm.toml` lives at the ROOT of the repository passed to `hyprpm add`
(verified against `hyprwm/hyprland-plugins@main`). Format:

```toml
[repository]
name = "..."
authors = ["..."]
commit_pins = [
    ["<hyprland-commit-or-tag-hash>", "<repo-commit-known-to-build>"],   # pairs; one per known-good release
]

[plugin-name]
description = "..."
authors = ["..."]
output = "path/to/plugin-name.so"        # relative to repo root, must match build output
build = [ "cmake -S hyprland-plugin -B hyprland-plugin/build -DCMAKE_BUILD_TYPE=Release",
          "cmake --build hyprland-plugin/build" ]   # run from repo root
# optional per-plugin key seen upstream: since_hyprland = <commit-count>
```

Upstream pins every release tag; e.g. for 0.56.2 the upstream pin is
`["efb50993780079460b0cbed1363e2166a2de1d9f", "7644cecdb947060682891a0db2a0cdc5c0b9e704"]`.
Our repo ships the 0.56.2 pin with a placeholder that must be replaced with our
release commit after tagging. After Hyprland updates: `hyprpm update` (-f if
needed). Incompatible commit => build or hash-gate fails loudly; desktop keeps
running without the effect.

## A6. Quickshell 0.3.1 — verified QML API (from installed qmltypes)

`import Quickshell.Io`:

- `Socket` (client): properties `connected` (writable bool — assign true to
  connect/reconnect), `path`; signals `error(QLocalSocket::LocalSocketError)`,
  `connectionStateChanged`, `pathChanged`. NOTE: there is NO
  `connectionFailed` handler; use `onError:` / `onConnectionStateChanged:`.
  Inherits `DataStream` -> has `parser` property.
- `SplitParser : DataStreamParser`: property `splitMarker`; signal
  `read(string data)` -> use `onRead: line => ...` for line-delimited JSON.
- `SocketServer` also exists (properties `active`, `path`, `handler`) but was
  not needed: ownership decision = **the Hyprland plugin owns/listens on the
  socket; Quickshell is the client**. Rationale: shell reloads reconnect
  trivially; plugin unload just closes the socket; QML degrades gracefully.
- Reconnect pattern used: `Timer { interval: 2000 }` restarted from both error
  and disconnect paths; on connect the server sends handshake + full snapshot,
  so no state is missed while disconnected.
- QML gotcha hit during implementation: an `Item` subclass CANNOT redeclare
  `x/y/width/height` (duplicate property name) -> properties named
  `caretX/caretY/caretWidth/caretHeight`; derived `emitterX/emitterY`
  (bottom-center) exposed ready-made.

## A7. Build configuration (verified working)

Upstream-style Makefile approach also works (`g++ -shared -fPIC -std=c++2b ...
pkg-config --cflags pixman-1 libdrm hyprland pangocairo libinput libudev
wayland-server xkbcommon`), but this repo uses CMake mirroring upstream
`borders-plus-plus/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.27)
project(caret-tracker ...)
set(CMAKE_CXX_STANDARD 23)
add_library(caret-tracker SHARED ${SRC})
find_package(PkgConfig REQUIRED)
pkg_check_modules(deps REQUIRED IMPORTED_TARGET hyprland wayland-server)
find_package(Threads REQUIRED)
target_link_libraries(caret-tracker PRIVATE Threads::Threads PkgConfig::deps)
```

Direct compile-validation command used (cmake absent on machine):

```bash
g++ -std=c++23 -O2 -shared -fPIC \
  $(pkg-config --cflags hyprland wayland-server) \
  hyprland-plugin/src/main.cpp -o /tmp/caret-tracker.so -lpthread
nm -D --defined-only /tmp/caret-tracker.so   # expect pluginAPIVersion/pluginInit/pluginExit
qmllint -I /usr/lib/qt6/qml CaretTrail.qml   # clean pass
```

Build requirements for users: `base-devel`, `cmake`, `hyprland` package.

## A8. IPC protocol as implemented (v1)

Transport: `AF_UNIX SOCK_STREAM`, nonblocking listener + `accept4(..., SOCK_CLOEXEC)`,
path `$XDG_RUNTIME_DIR/caret-trails.sock` (user-owned tmpfs, local-only).

Ownership/threading decisions (all deliberate):

- Server owned by plugin; stale socket file unlinked before bind and on exit;
  crashed-session leftovers cannot block startup.
- One client max, newest-wins; fd handoff + sends guarded by one mutex;
  writes best-effort with `MSG_NOSIGNAL`; send error drops client only.
- Accept thread polls listener fd (200 ms) so shutdown never blocks; thread
  never touches Hyprland internals. All Hyprland access stays on the compositor
  thread via the tick callback.
- `pluginExit()` order: reset tick listener -> stop flag -> shutdown/close listen
  fd -> join accept thread -> close client fd under mutex -> unlink socket path.

Wire format: newline-delimited JSON.

```
handshake (once, right after connect):
{"protocol":1,"plugin":"caret-tracker","status":"ready"}
state (only on change vs last sent):
{"protocol":1,"active":true,"x":734,"y":412,"width":2,"height":20}
{"protocol":1,"active":false}
```

x/y = global top-left of caret rect; w/h retained raw (not clamped).
Emitter = bottom-center (`emitterX = x + w/2`, `emitterY = y + h`).
Deliberately deferred: timestamp (receiver can stamp), window class/title
(privacy), monitor id. Quickshell status mapping: connect-refused =>
`Unavailable`; unknown `protocol` in hello => `Incompatible`; else `Ready`.

## A9. Application compatibility findings (confidence-labeled)

Works iff the app speaks zwp_text_input_v3 (or v1) on its Wayland connection
AND calls `set_cursor_rectangle()` with real coordinates. The protocol
explicitly allows clients to never send it (then Hyprland has NO semantic caret
anywhere in memory — nothing to read).

| Target | Status |
|---|---|
| GTK3/GTK4 | expected to work (assumption: GTK Wayland backend sets cursor rects) |
| Qt6 | expected to work (assumption: QtWayland implements ti-v3 + cursor rect) |
| Firefox native Wayland | expected to work (assumption) |
| Chromium/Electron ozone-wayland | mostly works, varies by version / `--enable-wayland-ime` (assumption) |
| VS Code, Discord | conditional — default X11/XWayland mode means NO tracking |
| XWayland apps | will not work (no bridge to ti-v3) |
| kitty | verify live — supports ti-v3 for IME but historically sent no cursor rect |
| foot | likely works (assumption) |
| Neovim standalone | n/a (not a Wayland client) |
| Neovim in terminal | inherits terminal behavior |

Live verification tool (works because the sensor publishes continuously):

```bash
socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/caret-trails.sock
```

## A10. Omarchy shell integration facts

- Shell plugins live in `~/.config/omarchy/plugins/<id>/`, discovered via
  `manifest.json`. Hot-reload on save; `omarchy-shell shell rescanPlugins`
  forces reload; `omarchy restart shell` restarts everything.
- Manifest schema (verified against installed
  `/usr/share/omarchy/shell/plugins/*/manifest.json`, e.g. osd/reminders):

  ```json
  {
    "schemaVersion": 1,
    "id": "ogarza.caret-trails",
    "name": "...", "version": "...", "author": "...", "description": "...",
    "kinds": ["overlay"],
    "keepLoaded": true,
    "entryPoints": { "overlay": "CaretTrail.qml" }
  }
  ```

  Known kinds seen: `panel`, `overlay`. Entry-point QML root can be a plain
  `Item` exposing properties (that is what OSD does).
- CLI (verified): `omarchy plugin add <git-url> [--enable] [--yes]`, `clone`,
  `enable <id> [placement]`, `disable <id>`, `list [--json]`, `remove <id>`,
  `update [id]`, `validate <folder>`.

## A11. Final repo layout (as implemented)

```
ogarza.plugins.caret-trails/
├── prompt.md                original spec + this appendix
├── manifest.json            Omarchy shell manifest (kinds: overlay)
├── hyprpm.toml              at repo ROOT (required by hyprpm add <url>)
├── CaretTrail.qml           overlay entry: Socket receiver -> QML props
├── shaders/.gitkeep         reserved for GLSL particle pass (NOT implemented yet)
├── hyprland-plugin/
│   ├── CMakeLists.txt
│   └── src/main.cpp         entire native sensor (~220 lines)
├── scripts/install.sh       omarchy plugin add + hyprpm add/enable wrapper
├── README.md                user docs/install
├── DESIGN.md                full design doc (architecture, API refs, races, compat)
└── .gitignore               build/, *.so, *.o
```

Two manifests, one repo: Omarchy reads `manifest.json`, `hyprpm add <same-url>`
reads root `hyprpm.toml` whose build commands descend into `hyprland-plugin/`.

## A12. Rebuild checklist (if starting over)

1. Verify environment: `pacman -Q hyprland quickshell`; headers at
   `/usr/include/hyprland`; `hyprctl version` for exact tag.
2. Pull matching source:
   `curl -sL https://github.com/hyprwm/Hyprland/archive/refs/tags/v<X.Y.Z>.tar.gz`
   and re-check every A2 symbol/file:line (APIs move fast; e.g. Log.hpp moved,
   registerCallbackDynamic died in the 0.56.x series).
3. Native plugin skeleton per A4; event hook per A3; IPC per A8.
4. Build config per A7; validate with the direct g++ line even without cmake.
5. QML receiver per A6 (remember: no `connectionFailed` handler, no x/y/width/
   height shadowing).
6. Manifests per A5/A10; replace the `commit_pins` placeholder with the release
   commit once tagged.
7. End-to-end test: `hyprpm enable` -> `socat - UNIX-CONNECT:...sock` -> type in
   Firefox/GTK/Qt apps -> watch JSON lines flip active/x/y; switch windows and
   confirm an `{"active":false}` transition appears when leaving text fields.

## A13. Trail shader findings (added 2026-08-25, second iteration)

The 1-second fading trail line IS now implemented (v0.2). Facts to remember:

- **Qt 6 ShaderEffect accepts ONLY `.qsb` files** - no inline GLSL strings
  (confirmed in Qt 6.11 docs). Workflow: author Vulkan-style GLSL
  (`shaders/trail.frag`, `#version 440`) -> `/usr/lib/qt6/bin/qsb shaders/trail.frag -o shaders/trail.frag.qsb`
  (qsb comes from `qt6-shadertools` and is NOT on PATH) -> commit BOTH files;
  QML references the `.qsb` with a path relative to its own file.
- Fragment-only effects receive `vec2 qt_TexCoord0` at location 0 from the
  built-in vertex shader (declare input with that exact name).
- Uniform block rules: `layout(std140, binding = 0) uniform buf { mat4 qt_Matrix;
  float qt_Opacity; <customs...> };` - qt_Matrix/qt_Opacity first even when
  unused; custom uniforms after; samplers would use binding >= 1.
- Output must be premultiplied (`fragColor = vec4(col * a, a)`), blending on.
- Property-type mapping must match exactly: vector2d->vec2, real->float,
  vector3d->vec3; `color` maps to PREMULTIPLIED vec4, so use `vector3d` for
  vec3 uniforms.
- Overlay window pattern verified against Omarchy's own shell
  (`/usr/share/omarchy/shell/plugins/background/Background.qml`,
  `Ui/KeyboardPanel.qml`, `Ui/SpeedTestOverlay.qml`):
  `Variants { model: Quickshell.screens; PanelWindow { required property var
  modelData; screen: modelData; anchors all; color: "transparent";
  mask: Region {}; exclusionMode: ExclusionMode.Ignore;
  WlrLayershell.layer: WlrLayer.Overlay } }` with `import Quickshell.Wayland`.
  Empty `Region {}` mask = fully click-through. `QsWindow.contentItem` exists
  for reparenting spawned items; `ShellScreen` has x/y/width/height for
  global->local conversion.
- Trail architecture: `CaretTrail.noteCaretMove()` spawns a segment when the
  emitter point moved >=4px (or >=1px after 200ms); `TrailSegment.setup()`
  positions a bounding-box-sized ShaderEffect around the line (margin 40px);
  one `NumberAnimation` drives `progress` 0->1 over 1000ms then destroys the
  item (= disappears after 1 second); `TrailOverlay.spawn()` duplicates the
  segment into each screen window with global->local conversion + culling so
  multi-monitor crossings render everywhere; `maxActive: 48` caps load.
- Tuning knobs: color `TrailSegment.tint`, lifetime = animation duration,
  glow/width in `shaders/trail.frag`, thresholds in `noteCaretMove()`,
  cap in `TrailOverlay.maxActive`.
- Validation without launching UI: `/usr/lib/qt6/bin/qsb` compiles the GLSL
  (catches syntax/layout errors); `qmllint -I /usr/lib/qt6/qml <files>` catches
  QML/type errors. Visual test happens automatically via omarchy-shell plugin
  hot-reload when files are saved under ~/.config/omarchy/plugins/.
