#define WLR_USE_UNSTABLE

#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/input/InputMethodRelay.hpp>
#include <hyprland/src/managers/input/TextInput.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

inline HANDLE PHANDLE = nullptr;

static constexpr int    PROTOCOL_VERSION   = 1;
static constexpr const char* PLUGIN_NAME   = "caret-tracker";
static constexpr const char* SOCKET_NAME  = "caret-trails.sock";

static CHyprSignalListener g_tickListener;

static std::atomic<bool>   g_running{false};
static int                 g_listenFd{-1};
static std::thread         g_acceptThread;
static std::mutex          g_clientsMutex;
static std::vector<int>    g_clients;
static std::string         g_socketPath;
static constexpr size_t    MAX_CLIENTS = 8;

struct SLastState {
    bool active = false;
    int  x      = 0;
    int  y      = 0;
    int  w      = 0;
    int  h      = 0;
};

static SLastState g_lastState;

static std::string socketPath() {
    const char* xdg = getenv("XDG_RUNTIME_DIR");
    return (xdg ? std::string(xdg) : std::string("/tmp")) + "/" + SOCKET_NAME;
}

// Clients are non-blocking: a stalled reader gets skipped (EAGAIN) instead of
// ever blocking the compositor's tick thread; a genuinely broken or too-slow
// one (short write / real error) is dropped. Bounded by MAX_CLIENTS.
static void sendLine(const char* data, size_t len) {
    std::lock_guard<std::mutex> lg(g_clientsMutex);
    for (auto it = g_clients.begin(); it != g_clients.end();) {
        const auto n = send(*it, data, len, MSG_NOSIGNAL);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            ++it;
        } else if (n <= 0 || static_cast<size_t>(n) != len) {
            close(*it);
            it = g_clients.erase(it);
        } else {
            ++it;
        }
    }
}

static void pushState(const SLastState& s) {
    char buf[256];
    int  len = 0;
    if (s.active)
        len = snprintf(buf, sizeof(buf), "{\"protocol\":%d,\"active\":true,\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d}\n", PROTOCOL_VERSION, s.x, s.y, s.w, s.h);
    else
        len = snprintf(buf, sizeof(buf), "{\"protocol\":%d,\"active\":false}\n", PROTOCOL_VERSION);
    sendLine(buf, len);
}

static void acceptLoop() {
    while (g_running) {
        pollfd pfd{.fd = g_listenFd, .events = POLLIN, .revents = 0};
        if (poll(&pfd, 1, 200) <= 0)
            continue;

        int cfd = accept4(g_listenFd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (cfd < 0)
            continue;

        bool accepted = false;
        {
            std::lock_guard<std::mutex> lg(g_clientsMutex);
            if (g_clients.size() < MAX_CLIENTS) {
                g_clients.push_back(cfd);
                accepted = true;
            }
        }
        if (!accepted) {
            close(cfd);
            continue;
        }

        char hello[128];
        int  helloLen = snprintf(hello, sizeof(hello), "{\"protocol\":%d,\"plugin\":\"%s\",\"status\":\"ready\"}\n", PROTOCOL_VERSION, PLUGIN_NAME);
        send(cfd, hello, helloLen, MSG_NOSIGNAL);
        pushState(g_lastState);
    }
}

static bool stateChanged(const SLastState& a, const SLastState& b) {
    return a.active != b.active || a.x != b.x || a.y != b.y || a.w != b.w || a.h != b.h;
}

static SLastState computeState() {
    SLastState state;

    const auto ti = g_pInputManager->m_relay.getFocusedTextInput();

    if (!ti)
        return state;

    if (!ti->hasCursorRectangle())
        return state;

    const auto surf = ti->focusedSurface();
    if (!surf)
        return state;

    const auto owner = Desktop::View::CWLSurface::fromResource(surf);
    if (!owner)
        return state;

    const auto surfaceBox = owner->getSurfaceBoxGlobal();
    if (!surfaceBox.has_value())
        return state;

    const CBox cursorLocal = ti->cursorBox();

    state.active = true;
    state.x      = static_cast<int>(surfaceBox->x + cursorLocal.x);
    state.y      = static_cast<int>(surfaceBox->y + cursorLocal.y);
    state.w      = static_cast<int>(cursorLocal.w);
    state.h      = static_cast<int>(cursorLocal.h);

    return state;
}

static void onTick() {
    const auto state = computeState();

    if (stateChanged(state, g_lastState)) {
        g_lastState = state;
        pushState(state);
    }
}

APICALL EXPORT std::string pluginAPIVersion() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO pluginInit(HANDLE handle) {
    PHANDLE = handle;

    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();

    if (HASH != CLIENT_HASH)
        throw std::runtime_error("[caret-tracker] Version mismatch: plugin headers do not match the running Hyprland build");

    g_socketPath = socketPath();
    unlink(g_socketPath.c_str());

    g_listenFd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (g_listenFd < 0) {
        Log::logger->log(Log::ERR, "[caret-tracker] socket() failed: {}", strerror(errno));
        throw std::runtime_error("[caret-tracker] failed to create IPC socket");
    }

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, g_socketPath.c_str(), sizeof(addr.sun_path) - 1);

    if (bind(g_listenFd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0 || listen(g_listenFd, 2) < 0) {
        Log::logger->log(Log::ERR, "[caret-tracker] bind/listen on {} failed: {}", g_socketPath, strerror(errno));
        close(g_listenFd);
        g_listenFd = -1;
        unlink(g_socketPath.c_str());
        throw std::runtime_error("[caret-tracker] failed to bind IPC socket");
    }

    g_running = true;
    g_acceptThread = std::thread(acceptLoop);

    g_tickListener = Event::bus()->m_events.tick.listen([] { onTick(); });

    Log::logger->log(Log::INFO, "[caret-tracker] loaded, sensor socket at {}", g_socketPath);

    return {PLUGIN_NAME, "Global text caret position sensor", "ogarza", "1.0.0"};
}

APICALL EXPORT void pluginExit() {
    g_tickListener.reset();

    g_running = false;

    if (g_listenFd >= 0) {
        shutdown(g_listenFd, SHUT_RDWR);
        close(g_listenFd);
        g_listenFd = -1;
    }

    if (g_acceptThread.joinable())
        g_acceptThread.join();

    {
        std::lock_guard<std::mutex> lg(g_clientsMutex);
        for (const auto fd : g_clients)
            close(fd);
        g_clients.clear();
    }

    if (!g_socketPath.empty())
        unlink(g_socketPath.c_str());

    Log::logger->log(Log::INFO, "[caret-tracker] unloaded");
}
