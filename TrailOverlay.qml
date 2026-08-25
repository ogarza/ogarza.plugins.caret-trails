import QtQuick
import Quickshell
import Quickshell.Wayland

Item {
    id: root

    required property var trail

    readonly property int cullMargin: 48

    property var windows: []
    property int activeCount: 0
    property int maxActive: 48

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
            onDestroyed: root.activeCount--
        }
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

            Component.onCompleted: root.windows.push(win)
            Component.onDestruction: {
                const i = root.windows.indexOf(win)
                if (i >= 0)
                    root.windows.splice(i, 1)
            }
        }
    }
}
