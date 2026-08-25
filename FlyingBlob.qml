import QtQuick

ShaderEffect {
    id: root

    // Persistent caret chaser: flies toward `goal` every frame, so focus
    // changes simply redirect it mid-flight. Lifecycle: flying → landed
    // (swell + quick dissolve) → dormant until the next goal. Emits `hop`
    // breadcrumbs along its real trajectory so afterimage streaks can trace
    // its actual course.
    anchors.fill: parent

    signal hop(real x1, real y1, real x2, real y2)

    property vector2d center: Qt.vector2d(-100, -100)
    property vector2d radii: Qt.vector2d(9.5, 3.2)
    property real angle: 0
    property real land: 0
    readonly property vector2d resolution: Qt.vector2d(width, height)
    readonly property vector3d tint: Qt.vector3d(0.22, 0.74, 0.97)

    fragmentShader: "shaders/blob.frag.qsb"
    blending: true

    readonly property real hopDist: 10

    property real goalX: -100
    property real goalY: -100
    // current chase position, local to this window
    property real cx: -100
    property real cy: -100
    property bool active: false
    property bool armed: false
    property bool landed: false

    // distance travelled since the last emitted breadcrumb
    property real _acc: 0
    property real _hopX: -100
    property real _hopY: -100

    // vanishes the moment it lands
    opacity: active && !landed ? 1 : 0

    function setGoal(lx, ly, act) {
        if (!armed && act) {
            // very first activation: appear at the caret, don't fly from 0,0
            cx = lx
            cy = ly
            center = Qt.vector2d(cx, cy)
            armed = true
        }

        if ((root.landed || !root.armed) && act) {
            // launching from standstill: breadcrumb anchor starts here
            landed = false
            _acc = 0
            _hopX = cx
            _hopY = cy
        }

        goalX = lx
        goalY = ly
        active = act
    }

    function _lerpAngle(a, b, k) {
        let d = (b - a) % (2 * Math.PI)
        if (d > Math.PI)
            d -= 2 * Math.PI
        if (d < -Math.PI)
            d += 2 * Math.PI
        return a + d * k
    }

    function _emitHop() {
        hop(_hopX, _hopY, cx, cy)
        _hopX = cx
        _hopY = cy
        _acc = 0
    }

    Timer {
        interval: 16
        repeat: true
        running: root.active || root.opacity > 0.01

        onTriggered: {
            const dt = interval / 1000

            if (!root.active)
                return

            const dx = root.goalX - root.cx
            const dy = root.goalY - root.cy
            const dist = Math.sqrt(dx * dx + dy * dy)

            if (dist > 1.2) {
                root.landed = false

                const f = 1 - Math.exp(-dt * 13)
                const nx = root.cx + dx * f
                const ny = root.cy + dy * f
                const md = Math.hypot(nx - root.cx, ny - root.cy)

                if (md > 0.6)
                    root.angle = _lerpAngle(root.angle, Math.atan2(dy, dx), 0.22)

                root.cx = nx
                root.cy = ny
                root._acc += md

                if (root._acc >= root.hopDist)
                    root._emitHop()

                // arrived after a real flight → landing swell
                if (Math.hypot(root.goalX - root.cx, root.goalY - root.cy) < 1.2) {
                    root.land = 1
                    root.landed = true
                    if (root._acc > 4)
                        root._emitHop()
                }
            }

            root.land *= Math.exp(-dt * 7)
            root.center = Qt.vector2d(root.cx, root.cy)
        }
    }
}
