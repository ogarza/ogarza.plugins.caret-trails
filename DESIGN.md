# Caret Trails — design notes

All Hyprland APIs referenced here were verified against **Hyprland 0.56.2**
(headers at `/usr/include/hyprland`, sources tagged `v0.56.2`). Quickshell APIs
were verified against **Quickshell 0.3.1** as installed on this machine.

## 1. Architecture

```
Application (zwp_text_input_v3.set_cursor_rectangle)
        |  surface-local cursor rect
        v
Hyprland compositor (CTextInputV3 -> CTextInput -> CInputMethodRelay)
        |  per-frame read + change detection
        v
caret-tracker.so  (native Hyprland plugin - sensor only)
        |  newline-delimited JSON over local AF_UNIX stream socket
        v
Quickshell overlay (CaretTrail.qml - QML properties)
        |  future work
        v
GLSL particle simulation
```

The native plugin contains zero rendering logic. It answers exactly one
question on every compositor tick: *where is the caret rectangle of the focused
text input, in global compositor coordinates?* It emits a message only when the
answer changes.

## 2. Exact source/API path used (verified, Hyprland 0.56.2)

| What | Symbol | Location |
|---|---|---|
| Input manager global | `g_pInputManager` | `src/managers/input/InputManager.hpp:313` |
| Text-input relay (public member) | `CInputMethodRelay m_relay` | `src/managers/input/InputManager.hpp:188` |
| Focused text input | `CTextInput* CInputMethodRelay::getFocusedTextInput()` | declared `InputMethodRelay.hpp:33`, implemented `src/managers/input/InputMethodRelay.cpp:73` |
| Cursor-rect presence | `bool CTextInput::hasCursorRectangle()` | `src/managers/input/TextInput.cpp:299` = `!isV3() \|\| m_v3Input->m_current.box.updated` |
| Cursor rect (surface-local) | `CBox CTextInput::cursorBox()` | `src/managers/input/TextInput.cpp:303` |
| Focused surface | `SP<CWLSurfaceResource> CTextInput::focusedSurface()` | `src/managers/input/TextInput.hpp:36` |
| Surface resource -> desktop view wrapper | `Desktop::View::CWLSurface::fromResource(SP<CWLSurfaceResource>)` | `src/desktop/view/WLSurface.hpp:76` |
| View wrapper -> global box | `std::optional<CBox> getSurfaceBoxGlobal() const` | `src/desktop/view/WLSurface.hpp:48` |

Notes:

- `getFocusedTextInput()` does **not** require an input method to be connected.
  It matches any registered text input whose `focusedSurface()` equals the
  current keyboard-focus surface (preferring enabled ones). This works on a
  plain desktop with no IME running.
- The coordinate computation mirrors what Hyprland's own `CInputPopup`
  (IME popups) does in v0.56.2:
  `parentBox = OWNER->getSurfaceBoxGlobal().value_or(...)`.
  So yes: the current API for the transform is **`getSurfaceBoxGlobal()`**.

```
globalCaret = { surfaceBox.x + cursorBox.x,
                surfaceBox.y + cursorBox.y,
                cursorBox.w, cursorBox.h }
```

## 3. Event mechanism (current)

`registerCallbackDynamic()` / string hooks are **deprecated and a no-op** in
0.56.2 (`PluginAPI.hpp:175`: "doesn't do anything anymore, use Event::bus()").
The current mechanism is the typed event bus in `src/event/EventBus.hpp`,
consumed through hyprutils typed signals:

```cpp
CHyprSignalListener l = Event::bus()->m_events.tick.listen([] { /* ... */ });
```

The returned listener must be kept alive; dropping it unregisters. The plugin
stores it statically and resets it in `pluginExit()`.

Events used:

- `Event::bus()->m_events.tick` (`Event<>`, `EventBus.hpp:72`), emitted once
  per frame from `src/animation/AnimationManager.cpp:358`. The plugin
  recomputes the full caret state each tick and diffs against the last sent
  state, which covers all required cases without extra hooks: caret movement
  within a surface, window moves/scrolls (global coords shift), focus switches,
  enter/leave of text input, surfaces going away.
- The bus also offers `input.keyboard.focus` and `window.active`; they would
  only save at most one frame of latency on focus switches while adding
  coupling. Tick + change detection is sufficient and simpler.

No function hooks are used anywhere. Per-frame polling of ~5 accessor calls is
negligible next to a rendered frame.

## 4. IPC design

**Chosen transport:** an `AF_UNIX` `SOCK_STREAM` socket owned by the plugin:

```
$XDG_RUNTIME_DIR/caret-trails.sock
```

Why this beats the alternatives:

| Option | Verdict |
|---|---|
| Plugin-owned unix socket | local-only, user-owned (`XDG_RUNTIME_DIR` is 0700 tmpfs), microsecond latency, directly consumable via `Quickshell.Io.Socket`, survives shell reloads |
| Hyprland socket2 / plugin custom events | plugin custom events (`HyprlandAPI::addEvent`) feed Hyprland's own Lua/plugin event bus (`hl.on(...)`); they are **not** surfaced through Quickshell's `Hyprland.rawEvent()`. Treated as a separate mechanism - not used. |
| Helper process stdout | fragile lifecycle coupling between processes owned by different supervisors |

Server behavior:

- created in `pluginInit`, stale socket file `unlink()`ed first so a crashed
  previous session cannot block startup; removed again in `pluginExit()`.
- accepts one client at a time; a new connection replaces the old one
  (newest-wins), the old fd is closed under the shared mutex.
- writes happen on the compositor thread during ticks, best-effort with
  `MSG_NOSIGNAL`; send errors drop the client instead of killing anything.
- an accept thread polls the listener fd (200 ms timeout) so shutdown is clean;
  it never touches Hyprland internals.

### Wire format

One JSON object per line (`\n`-terminated):

Handshake, sent immediately after connect:

```json
{"protocol":1,"plugin":"caret-tracker","status":"ready"}
```

State updates, sent only on change:

```json
{"protocol":1,"active":true,"x":734,"y":412,"width":2,"height":20}
{"protocol":1,"active":false}
```

`x/y` are the global top-left of the caret rectangle, `width/height` its size.
For an emitter use bottom-center: `emitterX = x + width/2`,
`emitterY = y + height` (exposed as ready-made properties by `CaretTrail.qml`).

Deliberately omitted in v1 (clean extension points): timestamp (receiver can
stamp arrival time), window class/title (privacy), monitor id.

### State machine seen by Quickshell

| Native plugin state | What Quickshell observes | QML `status` |
|---|---|---|
| absent | connect fails (`ECONNREFUSED`), retried every 2 s | `Unavailable` |
| present but incompatible build | hash gate refuses to load, so identical to absent | `Unavailable` |
| present, different wire protocol | hello line with unknown `protocol` | `Incompatible` |
| working | hello accepted, state lines flow | `Ready` |

## 5. Version compatibility strategy

Three independent gates, cheapest first:

1. **ABI hash gate (automatic).** Plugins embed their compile-time dependency
   hash chain (`__hyprland_api_get_client_hash()`) which the loader compares
   with the running compositor's (`__hyprland_api_get_hash()`). The plugin also
   performs the official explicit comparison in `pluginInit()` and throws, so a
   mismatch is always a clean load failure - never a running, mismatched
   sensor. Failing gracefully rather than crashing is structural here.
2. **Wire protocol gate.** The integer `protocol` field lets QML distinguish
   *absent/unbuildable* from *built but speaking another message format*, so
   the shell can show "update/rebuild caret tracker" instead of pretending.
3. **Repository pinning (`commit_pins`)** maps Hyprland commits/tags to plugin
   commits known to compile against them. Tradeoffs:
   - **Track latest (`main`):** builds against current HEAD; breaks when an
     included internal header changes, until you push a fix.
   - **Pin everything:** deterministic per release, but every Hyprland release
     needs a new pin entry. This is what upstream `hyprland-plugins` does (one
     pin per tag).
   - **Recommended middle ground:** let `main` track current Hyprland and
     append a `["<hyprland-tag-or-hash>", "<release-commit>"]` pair to
     `hyprpm.toml` per known-good release. Users on supported releases get
     deterministic builds; `-git` users get HEAD.

After Hyprland updates (e.g. `omarchy update` bumps the package) the plugin
must be rebuilt: `hyprpm update` (`-f` to force). If no compatible commit
exists yet for a brand-new Hyprland release, `hyprpm update` fails loudly while
the desktop continues fine without the effect - intended graceful degradation.

Build requirements on Arch/Omarchy: `base-devel`, `cmake`, and the `hyprland`
package itself (installs headers + `hyprland.pc` under `/usr/include/hyprland`,
which is what `pkg-config hyprland` exposes and what both `hyprpm` and this
repo build against).

## 6. Race conditions, focus changes, stale state, disconnects, unloading

- **Threading:** the tick callback runs on the compositor thread; only the
  accept thread runs elsewhere. The single piece of shared state is the client
  fd, handed over under a mutex that the sender also holds while writing.
  `MSG_NOSIGNAL` prevents SIGPIPE if the shell died mid-write; any send error
  just drops the client.
- **Focus switches:** between two ticks the caret may be briefly associated
  with the previous surface; worst case is one frame (~16 ms) of latency, which
  the particle animation hides entirely. No stale coordinates are ever emitted
  because every message is computed fresh from current compositor state.
- **No caret / no rectangle:** when there is no focused text input, no cursor
  rectangle, no focused surface, or the surface has no global box (e.g. unmapped
  mid-tick), the plugin emits `{"active":false}` once on transition instead of
  leaving the last position alive forever.
- **Scrolling / window moves:** these change the *global* caret position
  without the app re-committing anything; per-tick recomputation catches them
  automatically - this is exactly why polling beats event-only designs here.
- **Shell reload/restart:** Quickshell reconnects (2 s retry timer); on connect
  it receives the handshake plus an immediate full state snapshot, so it never
  waits for the next movement to learn where the caret is.
- **Plugin unload/disable:** `pluginExit()` resets the tick listener first,
  stops and joins the accept thread, closes all fds under the mutex, then
  unlinks the socket path. The QML side degrades to `Unavailable` and keeps
  rendering nothing.
- **Hyprland restart:** everything dies with the process; `XDG_RUNTIME_DIR` is
  tmpfs so no socket files survive a logout.
- **Multiple clients:** newest connection wins; the previous one is dropped.
  Sufficient for one Omarchy shell.

## 7. Application compatibility

The pipeline works iff the app implements `zwp_text_input_v3` (or v1) on its
*Wayland* connection **and** calls `set_cursor_rectangle()` with real
coordinates after each commit. If it does not, Hyprland has no semantic caret
position anywhere in memory, and no plugin can conjure one - that is the
protocol's documented behavior: "if the client is unaware of the position of
the edited text, it should not issue set_cursor_rectangle".

| Target | Status | Notes |
|---|---|---|
| GTK3/GTK4 apps | expected to work | GTK's Wayland backend implements `zwp_text_input_v3` and sets the cursor rect for text views |
| Qt6 apps | expected to work | QtWayland implements `zwp_text_input_v3` incl. cursor rect |
| Firefox (native Wayland) | expected to work | implements text-input-v3 with cursor rectangles via MOZ_ENABLE_WAYLAND=1 runtime |
| Chromium/Electron (native Wayland, ozone) | mostly works | Chromium implements zwp_text_input_v3 on ozone-wayland; behavior varies by version/embedder flag (`--enable-wayland-ime`) |
| VS Code / Discord | conditional | Electron: same as above; default X11/XWayland mode means **no** tracking |
| XWayland applications | will not work | XWayland has no bridge from X11 IM state to `zwp_text_input_v3` |
| kitty | verify at runtime | supports text-input-v3 for IME, but historically did not send cursor rectangles (IME popups anchor top-left); recent versions improved this |
| foot | likely works | foot implements text-input-v3 thoroughly incl. cursor rectangle reporting |
| Neovim bare (no terminal) | n/a | Neovim is not a Wayland client by itself |
| Neovim inside a terminal | inherits the terminal | tracker follows the terminal's reported caret rect, which terminals update from the grid cursor |

Treat "expected to work" rows as assumptions to validate empirically - the
debug command below lets you watch live messages per application in seconds.

Debugging:

```bash
socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/caret-trails.sock
```

## 8. Repository structure

```
ogarza.plugins.caret-trails/
├── manifest.json            Omarchy shell plugin manifest (kinds: overlay)
├── hyprpm.toml              hyprpm repository manifest at repo ROOT (required)
├── CaretTrail.qml           overlay entry point: unix-socket receiver -> QML props
├── shaders/                 reserved for the future GLSL particle pass
├── hyprland-plugin/
│   ├── CMakeLists.txt       pkg-config "hyprland" based, mirrors upstream plugins
│   └── src/main.cpp         the entire native sensor (~250 lines)
├── scripts/install.sh       convenience wrapper for both install steps
├── README.md                user-facing docs + install
└── DESIGN.md                this document
```

Two manifests, one repo: Omarchy discovers the shell side via `manifest.json`;
`hyprpm add <repo-url>` requires `hyprpm.toml` at the repository root, whose
build commands descend into `hyprland-plugin/`. Both tools can therefore target
the same Git URL.

