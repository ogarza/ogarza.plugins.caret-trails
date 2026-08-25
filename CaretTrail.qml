import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    enum Status {
        Unavailable,
        Ready,
        Incompatible
    }

    property int status: CaretTrail.Status.Unavailable
    property bool connected: false
    property bool caretActive: false
    property int caretX: 0
    property int caretY: 0
    property int caretWidth: 0
    property int caretHeight: 0
    property real lastUpdate: 0

    readonly property bool healthy: status === CaretTrail.Status.Ready && connected
    readonly property real emitterX: caretX + caretWidth / 2
    readonly property real emitterY: caretY + caretHeight

    readonly property string socketPath: `${Quickshell.env("XDG_RUNTIME_DIR")}/caret-trails.sock`
    readonly property int protocolVersionSupported: 1

    // The persistent blob chases the live caret and emits breadcrumbs along
    // its real trajectory; TrailOverlay turns those into afterimage streaks.
    // noteCaretMove is called once per complete socket update — never from
    // individual x/y property change handlers, which would evaluate mid-update.
    function noteCaretMove() {
        if (!healthy || !caretActive) {
            trails.redirect(caretX, caretY, false)
            return
        }

        trails.redirect(emitterX, emitterY, true)
    }

    onHealthyChanged: noteCaretMove()

    TrailOverlay {
        id: trails
        trail: root
    }

    function handleMessage(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            return;
        }

        if (msg.status === "ready") {
            if (msg.plugin !== "caret-tracker" || msg.protocol !== protocolVersionSupported) {
                status = CaretTrail.Status.Incompatible;
                return;
            }
            status = CaretTrail.Status.Ready;
            return;
        }

        if (msg.protocol !== protocolVersionSupported)
            return;

        caretActive = msg.active === true;
        lastUpdate = Date.now();

        if (caretActive) {
            caretX = msg.x;
            caretY = msg.y;
            caretWidth = msg.width;
            caretHeight = msg.height;
        }
        noteCaretMove();
    }

    Timer {
        id: retryTimer
        interval: 2000
        // Toggle so an already-true `connected` still re-fires a connection
        // attempt (e.g. shell started before the native plugin did).
        onTriggered: {
            socket.connected = false
            socket.connected = true
        }
    }

    Socket {
        id: socket

        path: root.socketPath
        connected: true

        parser: SplitParser {
            splitMarker: "\n"
            onRead: line => root.handleMessage(line)
        }

        onConnectionStateChanged: {
            root.connected = connected;
            if (!connected && root.status !== CaretTrail.Status.Incompatible) {
                root.status = CaretTrail.Status.Unavailable;
                retryTimer.restart();
            }
        }

        onError: retryTimer.restart()
    }
}
