import QtQuick

ShaderEffect {
    id: root

    readonly property int margin: 26

    // lingering afterimage streak: stretches back from `target` toward the
    // point it came from and is fully retracted by end of life
    property vector2d target
    property vector2d tailStart
    readonly property vector2d resolution: Qt.vector2d(width, height)
    readonly property vector3d tint: Qt.vector3d(0.22, 0.74, 0.97)
    property real progress: 0

    fragmentShader: "shaders/streak.frag.qsb"
    blending: true

    function setup(ax, ay, bx, by) {
        // lingering streak covers a randomized quarter-ish of the distance,
        // anchored at the new caret point
        const k = 0.22 + Math.random() * 0.08
        const tx = bx + (ax - bx) * k
        const ty = by + (ay - by) * k

        const m = margin
        const minX = Math.min(ax, bx, tx) - m
        const minY = Math.min(ay, by, ty) - m
        const maxX = Math.max(ax, bx, tx) + m
        const maxY = Math.max(ay, by, ty) + m

        x = minX
        y = minY
        width = maxX - minX
        height = maxY - minY

        // endpoints in the quad's local pixel space
        target = Qt.vector2d(bx - minX, by - minY)
        tailStart = Qt.vector2d(tx - minX, ty - minY)
    }

    NumberAnimation on progress {
        from: 0
        to: 1
        duration: 240
        onStopped: root.destroy()
    }
}
