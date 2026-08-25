import QtQuick

ShaderEffect {
    id: root

    readonly property int margin: 40

    property vector2d p0
    property vector2d p1
    // feeds the `resolution` uniform in trail.frag; pixel size of this quad
    readonly property vector2d resolution: Qt.vector2d(width, height)
    property vector3d tint: Qt.vector3d(0.22, 0.74, 0.97)
    property real progress: 0

    fragmentShader: "shaders/trail.frag.qsb"
    blending: true

    function setup(ax, ay, bx, by) {
        const ox = Math.min(ax, bx) - margin
        const oy = Math.min(ay, by) - margin
        x = ox
        y = oy
        width = Math.abs(bx - ax) + margin * 2
        height = Math.abs(by - ay) + margin * 2
        p0 = Qt.vector2d(ax - ox, ay - oy)
        p1 = Qt.vector2d(bx - ox, by - oy)
    }

    NumberAnimation on progress {
        from: 0
        to: 1
        duration: 1000
        onStopped: root.destroy()
    }
}
