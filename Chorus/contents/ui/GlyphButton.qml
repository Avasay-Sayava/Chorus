import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3

// Shuffle and repeat button
PC3.ToolButton {
    id: btn

    property string glyph: "shuffle"
    property real size: 24
    property color glyphColor: "white"
    property bool active: false

    hoverEnabled: true
    Layout.preferredWidth: size
    Layout.preferredHeight: size

    background: Rectangle {
        anchors.centerIn: parent
        width: btn.size * 0.88
        height: width
        radius: width / 2
        color: Qt.alpha(Kirigami.Theme.highlightColor,
                        btn.down ? 0.38 : (btn.hovered && btn.enabled ? 0.24 : (btn.active ? 0.14 : 0.0)))
        border.width: ((btn.hovered || btn.down) && btn.enabled) || btn.active ? 1 : 0
        border.color: Qt.alpha(Kirigami.Theme.highlightColor,
                               btn.down ? 0.52 : (btn.hovered ? 0.36 : 0.26))
        Behavior on color { ColorAnimation { duration: 140 } }
    }

    contentItem: Item {
        implicitWidth: btn.size
        implicitHeight: btn.size
        opacity: btn.enabled ? (btn.active ? 1.0 : 0.55) : 0.3
        scale: btn.down ? 0.90 : (btn.hovered && btn.enabled ? 1.05 : 1.0)
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Canvas {
            id: cv
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                var s = Math.min(width, height);
                var lw = Math.max(1.5, s * 0.085);
                ctx.strokeStyle = btn.glyphColor;
                ctx.fillStyle = btn.glyphColor;
                ctx.lineWidth = lw;
                ctx.lineCap = "round";
                ctx.lineJoin = "round";

                function arrowHead(x, y, angle) {
                    var a = s * 0.14;
                    ctx.save();
                    ctx.translate(x, y);
                    ctx.rotate(angle);
                    ctx.beginPath();
                    ctx.moveTo(0, 0);
                    ctx.lineTo(-a * 1.2, -a * 0.85);
                    ctx.lineTo(-a * 1.2, a * 0.85);
                    ctx.closePath();
                    ctx.fill();
                    ctx.restore();
                }

                if (btn.glyph === "shuffle") {
                    var yT = s * 0.32, yB = s * 0.68;
                    var x0 = s * 0.14, x1 = s * 0.34, x2 = s * 0.62, x3 = s * 0.78;
                    // bottom-left -> top-right
                    ctx.beginPath();
                    ctx.moveTo(x0, yB); ctx.lineTo(x1, yB);
                    ctx.lineTo(x2, yT); ctx.lineTo(x3, yT);
                    ctx.stroke();
                    arrowHead(s * 0.90, yT, 0);
                    // top-left -> bottom-right
                    ctx.beginPath();
                    ctx.moveTo(x0, yT); ctx.lineTo(x1, yT);
                    ctx.lineTo(x2, yB); ctx.lineTo(x3, yB);
                    ctx.stroke();
                    arrowHead(s * 0.90, yB, 0);
                } else {
                    // repeat: open circular loop with an arrowhead at the gap
                    var cx = s / 2, cy = s / 2, r = s * 0.30;
                    var start = -Math.PI * 0.38, end = Math.PI * 1.30;
                    ctx.beginPath();
                    ctx.arc(cx, cy, r, start, end, false);
                    ctx.stroke();
                    // arrowhead tangent at the start of the arc gap
                    var ax = cx + r * Math.cos(start);
                    var ay = cy + r * Math.sin(start);
                    arrowHead(ax, ay, start - Math.PI / 2);
                    if (btn.glyph === "repeatOne") {
                        ctx.font = "bold " + Math.round(s * 0.34) + "px sans-serif";
                        ctx.textAlign = "center";
                        ctx.textBaseline = "middle";
                        ctx.fillText("1", cx, cy + s * 0.02);
                    }
                }
            }
            Connections {
                target: btn
                function onGlyphColorChanged() { cv.requestPaint(); }
                function onGlyphChanged() { cv.requestPaint(); }
                function onSizeChanged() { cv.requestPaint(); }
                function onActiveChanged() { cv.requestPaint(); }
            }
        }
    }
}
