import QtQuick
import Quickshell
import Quickshell.Wayland

Item {
    id: root

    required property var trail

    readonly property int cullMargin: 48

    property var windows: []
    property var blobs: []
    property int activeCount: 0
    property int maxActive: 48

    // Redirect the persistent blob(s) toward a global caret position.
    function redirect(gx, gy, active) {
        for (let i = 0; i < blobs.length; i++) {
            const b = blobs[i]
            const w = windows[i]
            if (!b || !w)
                continue
            b.setGoal(gx - w.screen.x, gy - w.screen.y, active)
        }
    }

    // spawn a lingering afterimage streak between two global points
    function spawn(ax, ay, bx, by) {
        if (activeCount >= maxActive)
            return

        for (let i = 0; i < windows.length; i++) {
            const w = windows[i]
            const lax = ax - w.screen.x
            const lay = ay - w.screen.y
            const lbx = bx - w.screen.x
            const lby = by - w.screen.y

            if (Math.max(lax, lbx) < -cullMargin || Math.min(lax, lbx) > w.width + cullMargin)
                continue
            if (Math.max(lay, lby) < -cullMargin || Math.min(lay, lby) > w.height + cullMargin)
                continue

            const seg = segComponent.createObject(w.contentItem)
            if (seg) {
                activeCount++
                seg.setup(lax, lay, lbx, lby)
            }
        }
    }

    Component {
        id: segComponent

        TrailSegment {
            Component.onDestruction: root.activeCount--
        }
    }

    Component {
        id: blobComponent

        FlyingBlob {}
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win

            required property var modelData

            screen: modelData
            visible: root.trail ? root.trail.healthy : false
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            mask: Region {}
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "ogarza-caret-trails"

            Component.onCompleted: {
                root.windows.push(win)
                const b = blobComponent.createObject(win.contentItem)
                if (b) {
                    // afterimage streaks trace the blob's real trajectory
                    b.hop.connect(function(x1, y1, x2, y2) {
                        root.spawn(x1 + win.screen.x, y1 + win.screen.y,
                                   x2 + win.screen.x, y2 + win.screen.y)
                    })
                    root.blobs.push(b)
                }
            }
            Component.onDestruction: {
                const i = root.windows.indexOf(win)
                if (i >= 0) {
                    root.windows.splice(i, 1)
                    root.blobs.splice(i, 1)
                }
            }
        }
    }
}
