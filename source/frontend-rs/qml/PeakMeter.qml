// SPDX-License-Identifier: GPL-2.0-or-later

import QtQuick
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Item {
    id: root
    property int channels: 2
    property real levelL: 0.0
    property real levelR: 0.0
    property bool clipL: false
    property bool clipR: false
    property bool vertical: false
    property color baseColor: "#4ADE80"
    property color hotColor: "#FACC15"
    property color clipColor: "#DC2626"
    property color clipCapColor: "#EF4444"
    property string tooltipText: ""

    readonly property int chCount: Math.max(0, Math.min(2, root.channels))
    readonly property real innerW: Math.max(1, width - 2)
    readonly property real innerH: Math.max(1, height - 2)
    readonly property real hGap: chCount > 1 ? 1 : 0
    readonly property real vGap: chCount > 1 ? 2 : 0
    readonly property real chH: chCount > 0 ? (innerH - hGap * (chCount - 1)) / chCount : 0
    readonly property real chW: chCount > 0 ? (innerW - vGap * (chCount - 1)) / chCount : 0

    readonly property real normL: Math.max(0, Math.min(1, levelL))
    readonly property real normR: Math.max(0, Math.min(1, levelR))
    readonly property real barSpanL: clipL
        ? Math.max(vertical ? 4 : 3, (vertical ? innerH : innerW) * Math.max(normL, 0.95))
        : (normL > 0.001 ? (vertical ? innerH : innerW) * Math.sqrt(normL) : 0)
    readonly property real barSpanR: clipR
        ? Math.max(vertical ? 4 : 3, (vertical ? innerH : innerW) * Math.max(normR, 0.95))
        : (normR > 0.001 ? (vertical ? innerH : innerW) * Math.sqrt(normR) : 0)

    Controls.ToolTip.visible: hoverArea.containsMouse && tooltipText.length > 0
    Controls.ToolTip.text: tooltipText

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    // Native GPU-batched meter well & bars (avoids software Canvas rasterization)
    Rectangle {
        anchors.fill: parent
        clip: true
        color: Qt.darker(Kirigami.Theme.backgroundColor, 1.35)
        border.width: 1
        border.color: Qt.alpha(Kirigami.Theme.textColor, 0.2)

        // Channel 0 (Left / Mono)
        Rectangle {
            visible: root.chCount >= 1 && root.barSpanL > 0
            x: 1
            y: root.vertical ? (1 + root.innerH - root.barSpanL) : 1
            width: root.vertical ? root.chW : root.barSpanL
            height: root.vertical ? root.barSpanL : root.chH
            color: root.clipL
                ? root.clipColor
                : (root.normL >= 0.85 ? root.hotColor : root.baseColor)
        }
        Rectangle {
            visible: root.chCount >= 1 && root.clipL
            x: root.vertical ? 1 : (1 + root.innerW - Math.min(3, root.innerW))
            y: 1
            width: root.vertical ? root.chW : Math.min(3, root.innerW)
            height: root.vertical ? Math.min(3, root.innerH) : root.chH
            color: root.clipCapColor
        }

        // Channel 1 (Right)
        Rectangle {
            visible: root.chCount >= 2 && root.barSpanR > 0
            x: root.vertical ? (1 + root.chW + root.vGap) : 1
            y: root.vertical ? (1 + root.innerH - root.barSpanR) : (1 + root.chH + root.hGap)
            width: root.vertical ? root.chW : root.barSpanR
            height: root.vertical ? root.barSpanR : root.chH
            color: root.clipR
                ? root.clipColor
                : (root.normR >= 0.85 ? root.hotColor : root.baseColor)
        }
        Rectangle {
            visible: root.chCount >= 2 && root.clipR
            x: root.vertical ? (1 + root.chW + root.vGap) : (1 + root.innerW - Math.min(3, root.innerW))
            y: root.vertical ? 1 : (1 + root.chH + root.hGap)
            width: root.vertical ? root.chW : Math.min(3, root.innerW)
            height: root.vertical ? Math.min(3, root.innerH) : root.chH
            color: root.clipCapColor
        }
    }
}
