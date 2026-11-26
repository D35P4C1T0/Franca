// SPDX-License-Identifier: GPL-2.0-or-later

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.franca.app 1.0

Controls.ApplicationWindow {
    id: mainWindow
    visible: true
    width: 1180
    height: 760
    minimumWidth: 740
    minimumHeight: 500
    title: ctrl.window_title

    property bool forceClose: false
    property bool syncGuard: false
    readonly property bool logsTabActive: ctrl.show_logs && mainTabs.currentIndex === 2
    readonly property bool rackVisible: !logsTabActive && (ctrl.split_view || mainTabs.currentIndex === 0)
    readonly property bool patchbayVisible: !logsTabActive && (ctrl.split_view || mainTabs.currentIndex === 1)

    function capturePreparePatchbay() {
        mainTabs.currentIndex = 1;
        ctrl.refresh_patchbay();
        ctrl.arrange_patchbay();
        patchbayView.zoomFit();
    }

    function captureQuit() {
        mainWindow.forceClose = true;
        mainWindow.close();
    }

    Component.onCompleted: {
        if (ctrl.pending_recovery_json && ctrl.pending_recovery_json.length > 0) {
            dialogs.openRecovery(ctrl.pending_recovery_json);
        }
    }

    FrancaController {
        id: ctrl
        onAlert_requested: function(title, message) {
            dialogs.openAlert(title, message);
        }
        onIpc_ui_action: function(action, payload) {
            if (action === "view.tab") {
                if (payload === "rack") mainTabs.currentIndex = 0;
                else if (payload === "patchbay") mainTabs.currentIndex = ctrl.split_view ? 0 : 1;
                else if (payload === "logs" && ctrl.show_logs) mainTabs.currentIndex = 2;
            } else if (action === "canvas.zoom") {
                if (payload === "fit") patchbayView.zoomFit();
                else if (payload === "reset") patchbayView.zoomReset();
                else if (payload === "in") patchbayView.zoomIn();
                else if (payload === "out") patchbayView.zoomOut();
                else {
                    var zv = parseFloat(payload);
                    if (!isNaN(zv) && zv > 0) {
                        patchbayView.zoom = Math.max(0.2, Math.min(3.0, zv));
                        patchbayView.parseScene();
                    }
                }
            } else if (action === "canvas.search") {
                patchbayView.openSearch();
                if (payload && payload.length > 0) {
                    patchbayView.searchQuery = payload;
                    patchbayView.updateSearchResults();
                    if (patchbayView.searchSelectedIdx >= 0) {
                        patchbayView.jumpToSearchMatch(patchbayView.searchSelectedIdx);
                    }
                }
            } else if (action === "canvas.search.close") {
                patchbayView.closeSearch();
            }
        }
        onFocus_patchbay_requested: {
            if (!ctrl.split_view) {
                mainTabs.currentIndex = 1;
            } else if (mainTabs.currentIndex === 2) {
                mainTabs.currentIndex = 0;
            }
        }
        onSplit_viewChanged: {
            if (ctrl.split_view && mainTabs.currentIndex === 1) {
                mainTabs.currentIndex = 0;
            }
        }
        onSelected_patchbay_plugin_idChanged: {
            if (!mainWindow.syncGuard && ctrl.selected_patchbay_plugin_id >= 0) {
                mainWindow.syncGuard = true;
                rackView.focusPlugin(ctrl.selected_patchbay_plugin_id);
                mainWindow.syncGuard = false;
            }
        }
        onQuit_signal_received: {
            mainWindow.forceClose = true;
            mainWindow.close();
        }
    }

    // Periodic engine idle, meter, transport & discovery poll
    Timer {
        id: pollTimer
        interval: Math.max(10, Math.min(100, ctrl.refresh_interval_ms))
        running: !francaUiBusy
        repeat: true
        onTriggered: ctrl.poll_tick()
    }

    onClosing: function(close) {
        if (!forceClose && (ctrl.project_dirty || (ctrl.confirm_exit && ctrl.plugin_count > 0))) {
            close.accepted = false;
            dialogs.openConfirmQuit(ctrl.project_dirty);
            return;
        }
        pollTimer.stop();
        ctrl.shutdown_clean();
    }

    // Keyboard Shortcuts
    Shortcut { sequences: [StandardKey.New]; enabled: ctrl.engine_running; onActivated: ctrl.file_new() }
    Shortcut { sequences: [StandardKey.Open]; enabled: ctrl.engine_running; onActivated: ctrl.file_open() }
    Shortcut { sequences: [StandardKey.Save]; enabled: ctrl.engine_running; onActivated: ctrl.file_save() }
    Shortcut { sequences: [StandardKey.SaveAs]; enabled: ctrl.engine_running; onActivated: ctrl.file_save_as() }
    Shortcut { sequences: [StandardKey.Undo]; enabled: ctrl.can_undo; onActivated: ctrl.undo() }
    Shortcut { sequences: [StandardKey.Redo, "Ctrl+Y"]; enabled: ctrl.can_redo; onActivated: ctrl.redo() }
    Shortcut { sequence: "Ctrl+P"; enabled: ctrl.engine_running; onActivated: addPluginDlg.openForAdd() }
    Shortcut { sequence: "Ctrl+\\"; onActivated: ctrl.set_layout_toggle("split_view", !ctrl.split_view) }
    Shortcut { sequence: "Ctrl+F"; enabled: mainWindow.patchbayVisible; onActivated: patchbayView.openSearch() }
    Shortcut { sequence: "Ctrl+G"; enabled: ctrl.engine_running && mainWindow.patchbayVisible; onActivated: { ctrl.arrange_patchbay(); patchbayView.zoomFit(); } }
    Shortcut { sequences: ["Ctrl+R", "F5"]; enabled: ctrl.engine_running && mainWindow.patchbayVisible; onActivated: ctrl.refresh_patchbay() }
    Shortcut { sequences: ["Ctrl++", "Ctrl+="]; enabled: mainWindow.patchbayVisible; onActivated: patchbayView.zoomIn() }
    Shortcut { sequence: "Ctrl+-"; enabled: mainWindow.patchbayVisible; onActivated: patchbayView.zoomOut() }
    Shortcut { sequence: "Ctrl+1"; enabled: mainWindow.patchbayVisible; onActivated: patchbayView.zoomReset() }
    Shortcut { sequence: "Home"; enabled: mainWindow.patchbayVisible; onActivated: patchbayView.zoomFit() }
    Shortcut { sequence: "Ctrl+A"; enabled: mainWindow.patchbayVisible; onActivated: patchbayView.selectAllBoxes() }
    Shortcut {
        sequences: [StandardKey.Delete]
        enabled: mainWindow.rackVisible && !patchbayView.searchOpen && rackView.selectedPluginId >= 0
        onActivated: ctrl.remove_plugin(rackView.selectedPluginId)
    }
    Shortcut { sequences: [StandardKey.Quit]; onActivated: mainWindow.close() }

    // Native KDE Menu Bar
    menuBar: Controls.MenuBar {
        Controls.Menu {
            title: qsTr("&File")
            Controls.MenuItem { text: qsTr("New"); icon.name: "document-new"; enabled: ctrl.engine_running; onTriggered: ctrl.file_new() }
            Controls.MenuItem { text: qsTr("Open…"); icon.name: "document-open"; enabled: ctrl.engine_running; onTriggered: ctrl.file_open() }
            Controls.MenuItem { text: qsTr("Save"); icon.name: "document-save"; enabled: ctrl.engine_running; onTriggered: ctrl.file_save() }
            Controls.MenuItem { text: qsTr("Save As…"); icon.name: "document-save-as"; enabled: ctrl.engine_running; onTriggered: ctrl.file_save_as() }
            Controls.MenuSeparator {}
            Controls.MenuItem { text: qsTr("Quit"); icon.name: "application-exit"; onTriggered: mainWindow.close() }
        }

        Controls.Menu {
            title: qsTr("&Edit")
            Controls.MenuItem { text: ctrl.undo_label; icon.name: "edit-undo"; enabled: ctrl.can_undo; onTriggered: ctrl.undo() }
            Controls.MenuItem { text: ctrl.redo_label; icon.name: "edit-redo"; enabled: ctrl.can_redo; onTriggered: ctrl.redo() }
        }

        Controls.Menu {
            title: qsTr("E&ngine")
            Controls.MenuItem { text: qsTr("Start"); icon.name: "media-playback-start"; enabled: !ctrl.engine_running; onTriggered: ctrl.start_engine() }
            Controls.MenuItem { text: qsTr("Stop"); icon.name: "media-playback-stop"; enabled: ctrl.engine_running; onTriggered: ctrl.stop_engine() }
            Controls.MenuSeparator {}
            Controls.MenuItem { text: qsTr("Panic (All Notes Off)"); enabled: ctrl.engine_running; onTriggered: ctrl.engine_panic() }
            Controls.MenuItem { text: qsTr("Clear Xruns"); enabled: ctrl.engine_running; onTriggered: ctrl.clear_xruns() }
            Controls.MenuItem { text: qsTr("Driver Settings…"); icon.name: "configure"; enabled: ctrl.engine_running; onTriggered: runtimeDriverDlg.openRuntime() }
        }

        Controls.Menu {
            title: qsTr("&Plugin")
            Controls.MenuItem { text: qsTr("Add Plugin…"); icon.name: "list-add"; enabled: ctrl.engine_running; onTriggered: addPluginDlg.openForAdd() }
            Controls.MenuItem {
                text: qsTr("Add JACK Application…")
                visible: ctrl.jack_apps_enabled
                enabled: ctrl.engine_running
                onTriggered: dialogs.openJackApp()
            }
            Controls.MenuItem { text: qsTr("Remove All…"); icon.name: "edit-delete"; enabled: ctrl.plugin_count > 0; onTriggered: dialogs.openConfirmRemoveAll() }
            Controls.MenuSeparator {}
            Controls.Menu {
                title: qsTr("Macros")
                enabled: ctrl.plugin_count > 0
                Controls.MenuItem { text: qsTr("Enable All"); onTriggered: ctrl.macro_enable_all() }
                Controls.MenuItem { text: qsTr("Disable All"); onTriggered: ctrl.macro_disable_all() }
                Controls.MenuSeparator {}
                Controls.MenuItem { text: qsTr("Volume 100%"); onTriggered: ctrl.macro_volume_100() }
                Controls.MenuItem { text: qsTr("Mute All"); onTriggered: ctrl.macro_mute_all() }
                Controls.MenuSeparator {}
                Controls.MenuItem { text: qsTr("Dry/Wet 100%"); onTriggered: ctrl.macro_wet_100() }
                Controls.MenuItem { text: qsTr("Bypass All (Dry/Wet 0%)"); onTriggered: ctrl.macro_bypass_all() }
                Controls.MenuItem { text: qsTr("Center Balance / Pan"); onTriggered: ctrl.macro_center_balance() }
            }
        }

        Controls.Menu {
            title: qsTr("&Canvas")
            enabled: ctrl.engine_running
            Controls.MenuItem {
                text: qsTr("Plugin Routing (Internal)")
                checkable: true
                checked: !ctrl.external_patchbay
                onTriggered: { patchbayView.needsInitialFit = true; ctrl.switch_external_patchbay(false); }
            }
            Controls.MenuItem {
                text: qsTr("System Routing (External)")
                checkable: true
                checked: ctrl.external_patchbay
                onTriggered: { patchbayView.needsInitialFit = true; ctrl.switch_external_patchbay(true); }
            }
            Controls.MenuSeparator {}
            Controls.MenuItem { text: qsTr("Arrange"); icon.name: "view-sort-ascending"; onTriggered: { ctrl.arrange_patchbay(); patchbayView.zoomFit(); } }
            Controls.MenuItem { text: qsTr("Refresh"); icon.name: "view-refresh"; onTriggered: ctrl.refresh_patchbay() }
            Controls.MenuSeparator {}
            Controls.MenuItem {
                text: qsTr("Side-by-Side Split View")
                icon.name: "view-split-left-right"
                checkable: true
                checked: ctrl.split_view
                onToggled: ctrl.set_layout_toggle("split_view", checked)
            }
            Controls.MenuSeparator {}
            Controls.Menu {
                title: qsTr("Zoom")
                Controls.MenuItem { text: qsTr("Auto-Fit"); icon.name: "zoom-fit-best"; onTriggered: patchbayView.zoomFit() }
                Controls.MenuItem { text: qsTr("Zoom In"); icon.name: "zoom-in"; onTriggered: patchbayView.zoomIn() }
                Controls.MenuItem { text: qsTr("Zoom Out"); icon.name: "zoom-out"; onTriggered: patchbayView.zoomOut() }
                Controls.MenuItem { text: qsTr("Zoom 100%"); icon.name: "zoom-original"; onTriggered: patchbayView.zoomReset() }
            }
            Controls.Menu {
                title: qsTr("Save Image")
                Controls.MenuItem { text: qsTr("Save PNG (1x)…"); onTriggered: ctrl.save_patchbay_image(1.0) }
                Controls.MenuItem { text: qsTr("Save PNG (2x)…"); onTriggered: ctrl.save_patchbay_image(2.0) }
                Controls.MenuItem { text: qsTr("Save PNG (4x)…"); onTriggered: ctrl.save_patchbay_image(4.0) }
                Controls.MenuSeparator {}
                Controls.MenuItem { text: qsTr("Copy to Clipboard"); icon.name: "edit-copy"; onTriggered: ctrl.copy_patchbay_image() }
            }
        }

        Controls.Menu {
            title: qsTr("&Settings")
            Controls.MenuItem {
                text: qsTr("Show Main Toolbar")
                checkable: true
                checked: ctrl.show_toolbar
                onToggled: ctrl.set_layout_toggle("show_toolbar", checked)
            }
            Controls.MenuItem {
                text: qsTr("Show Files, Transport and Minimap")
                checkable: true
                checked: ctrl.show_side_panel
                onToggled: ctrl.set_layout_toggle("show_side_panel", checked)
            }
            Controls.MenuItem {
                text: qsTr("Show Patchbay Peak Meters")
                checkable: true
                checked: ctrl.show_meters
                onToggled: ctrl.set_layout_toggle("show_meters", checked)
            }
            Controls.MenuItem {
                text: qsTr("Show Patchbay Keyboard")
                checkable: true
                checked: ctrl.show_keyboard
                onToggled: ctrl.set_layout_toggle("show_keyboard", checked)
            }
            Controls.MenuItem {
                text: qsTr("Split View (Rack + Patchbay)")
                checkable: true
                checked: ctrl.split_view
                onToggled: ctrl.set_layout_toggle("split_view", checked)
            }
            Controls.MenuSeparator {}
            Controls.MenuItem {
                text: qsTr("Configure Franca…")
                icon.name: "configure"
                onTriggered: settingsDlg.openSettings()
            }
        }

        Controls.Menu {
            title: qsTr("&Help")
            Controls.MenuItem {
                text: qsTr("About Franca")
                icon.name: "help-about"
                onTriggered: dialogs.openAbout()
            }
        }
    }

    // Native KDE Main Toolbar
    header: Controls.ToolBar {
        visible: ctrl.show_toolbar
        RowLayout {
            anchors.fill: parent
            spacing: 2
            Controls.ToolButton { text: qsTr("New"); icon.name: "document-new"; enabled: ctrl.engine_running; onClicked: ctrl.file_new() }
            Controls.ToolButton { text: qsTr("Open"); icon.name: "document-open"; enabled: ctrl.engine_running; onClicked: ctrl.file_open() }
            Controls.ToolButton { text: qsTr("Save"); icon.name: "document-save"; enabled: ctrl.engine_running; onClicked: ctrl.file_save() }
            Controls.ToolSeparator {}
            Controls.ToolButton {
                text: qsTr("Undo")
                icon.name: "edit-undo"
                enabled: ctrl.can_undo
                onClicked: ctrl.undo()
                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: ctrl.undo_label
            }
            Controls.ToolButton {
                text: qsTr("Redo")
                icon.name: "edit-redo"
                enabled: ctrl.can_redo
                onClicked: ctrl.redo()
                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: ctrl.redo_label
            }
            Controls.ToolSeparator {}
            Controls.ToolButton {
                text: qsTr("Add Plugin")
                icon.name: "list-add"
                enabled: ctrl.engine_running
                onClicked: addPluginDlg.openForAdd()
            }
            Controls.ToolSeparator {}
            Controls.ToolButton {
                text: qsTr("Split View")
                icon.name: "view-split-left-right"
                checkable: true
                checked: ctrl.split_view
                onClicked: ctrl.set_layout_toggle("split_view", !ctrl.split_view)
                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Show Rack and Patchbay side-by-side (Ctrl+\\)")
            }
            Item { Layout.fillWidth: true }
            Controls.Label {
                visible: ctrl.autosave_status.length > 0
                text: ctrl.autosave_status
                opacity: 0.65
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.rightMargin: 8
            }
            Controls.Label {
                visible: ctrl.project_name.length > 0 || ctrl.project_dirty
                text: (ctrl.project_name.length > 0 ? ctrl.project_name : qsTr("Untitled"))
                    + (ctrl.project_dirty ? " *" : "")
                opacity: 0.78
                Layout.rightMargin: 8
            }
        }
    }

    // Main Content Area with Drag-and-Drop Support
    Item {
        anchors.fill: parent

        Controls.SplitView {
            anchors.fill: parent
            orientation: Qt.Horizontal

            // Collapsible Left Tools Side Panel
            SidePanel {
                visible: ctrl.show_side_panel
                Controls.SplitView.preferredWidth: 240
                Controls.SplitView.minimumWidth: 190
                Controls.SplitView.maximumWidth: 420
                controller: ctrl
                patchbayView: patchbayView
            }

            // Center Tabs: Rack / Patchbay / Logs
            ColumnLayout {
                Controls.SplitView.fillWidth: true
                spacing: 0

                Controls.TabBar {
                    id: mainTabs
                    Layout.fillWidth: true
                    visible: !ctrl.split_view || ctrl.show_logs
                    Controls.TabButton {
                        text: ctrl.split_view ? qsTr("Patchbay + Rack") : qsTr("Rack")
                    }
                    Controls.TabButton {
                        text: qsTr("Patchbay")
                        visible: !ctrl.split_view
                        width: visible ? implicitWidth : 0
                    }
                    Controls.TabButton {
                        text: qsTr("Logs")
                        visible: ctrl.show_logs
                        width: visible ? implicitWidth : 0
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // Clara-style Dual View: Patchbay on the left (default 65%), Compact Rack on the right (35%)
                    Controls.SplitView {
                        id: dualSplit
                        anchors.fill: parent
                        orientation: Qt.Horizontal
                        visible: !mainWindow.logsTabActive

                        onResizingChanged: {
                            if (!resizing && ctrl.split_view && width > 200 && patchbayView.width > 0) {
                                ctrl.apply_split_view_ratio(patchbayView.width / width);
                            }
                        }

                        handle: Rectangle {
                            implicitWidth: 4
                            implicitHeight: 4
                            color: Controls.SplitHandle.pressed || Controls.SplitHandle.hovered
                                ? Kirigami.Theme.highlightColor
                                : Qt.alpha(Kirigami.Theme.textColor, 0.10)
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }

                        PatchbayView {
                            id: patchbayView
                            visible: mainWindow.patchbayVisible
                            Controls.SplitView.preferredWidth: ctrl.split_view
                                ? Math.round(dualSplit.width * ctrl.split_view_ratio)
                                : dualSplit.width
                            Controls.SplitView.minimumWidth: 320
                            Controls.SplitView.fillWidth: !ctrl.split_view
                            controller: ctrl
                            onOpenAddPluginAt: function(sx, sy) { addPluginDlg.openForAddAt(sx, sy); }
                            onOpenPluginEdit: function(pid) { pluginEditWin.openForPlugin(pid); }
                            onOpenRenamePlugin: function(pid, name) { dialogs.openRename(pid, name); }
                            onOpenReplacePlugin: function(pid) { addPluginDlg.openForReplace(pid); }
                        }

                        RackView {
                            id: rackView
                            visible: mainWindow.rackVisible
                            splitMode: ctrl.split_view
                            patchbayView: patchbayView
                            Controls.SplitView.fillWidth: true
                            Controls.SplitView.minimumWidth: 260
                            controller: ctrl
                            onOpenAddPlugin: addPluginDlg.openForAdd()
                            onOpenPluginEdit: function(pid) { pluginEditWin.openForPlugin(pid); }
                            onOpenRenamePlugin: function(pid, name) { dialogs.openRename(pid, name); }
                            onOpenReplacePlugin: function(pid) { addPluginDlg.openForReplace(pid); }
                            onPluginSelected: function(pid) {
                                if (ctrl.split_view && !mainWindow.syncGuard) {
                                    mainWindow.syncGuard = true;
                                    ctrl.sync_rack_to_patchbay(pid);
                                    patchbayView.focusSelected();
                                    mainWindow.syncGuard = false;
                                }
                            }
                        }
                    }

                    LogsTab {
                        anchors.fill: parent
                        visible: mainWindow.logsTabActive
                        controller: ctrl
                    }
                }
            }
        }

        DropArea {
            id: fileDropArea
            anchors.fill: parent
            z: 100
            onEntered: function(drag) {
                if (drag.hasUrls) {
                    drag.acceptProposedAction();
                } else {
                    drag.accepted = false;
                }
            }
            onDropped: function(drop) {
                if (drop.hasUrls) {
                    drop.acceptProposedAction();
                    for (var i = 0; i < drop.urls.length; i++) {
                        ctrl.load_file_url(drop.urls[i].toString());
                    }
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            z: 101
            visible: fileDropArea.containsDrag
            color: Qt.alpha(Kirigami.Theme.highlightColor, 0.10)
            border.width: 2
            border.color: Kirigami.Theme.highlightColor
        }
    }

    // Native KDE Status Bar
    footer: Controls.ToolBar {
        RowLayout {
            anchors.fill: parent
            spacing: 8

            Rectangle {
                width: 9; height: 9; radius: 4.5
                Layout.leftMargin: 6
                color: ctrl.engine_running ? "#22C55E" : "#9CA3AF"
            }
            Controls.Label {
                text: ctrl.engine_running ? qsTr("%1 running").arg(ctrl.driver_name) : qsTr("Audio stopped")
            }

            Controls.ToolSeparator {}

            Controls.Label {
                text: ctrl.plugin_count === 1 ? qsTr("1 plugin") : qsTr("%1 plugins").arg(ctrl.plugin_count)
            }

            Item { Layout.fillWidth: true }

            // Buffer size
            Controls.Label { text: qsTr("Buffer"); opacity: 0.75 }
            Controls.ComboBox {
                id: bufCombo
                property var sizesList: {
                    try { return JSON.parse(ctrl.buffer_sizes_json); } catch (e) { return []; }
                }
                visible: ctrl.engine_running && ctrl.variable_buffer_size && sizesList.length > 0
                implicitWidth: 82
                model: sizesList
                currentIndex: Math.max(0, sizesList.indexOf(ctrl.buffer_size))
                onActivated: function(i) { ctrl.apply_buffer_size(sizesList[i]); }
            }
            Controls.Label {
                visible: !bufCombo.visible
                text: ctrl.engine_running ? String(ctrl.buffer_size) : "—"
            }

            Controls.ToolSeparator {}

            // Sample rate
            Controls.Label { text: qsTr("Sample rate"); opacity: 0.75 }
            Controls.ComboBox {
                id: srCombo
                property var ratesList: {
                    try { return JSON.parse(ctrl.sample_rates_json); } catch (e) { return []; }
                }
                visible: ctrl.engine_running && ctrl.variable_sample_rate && ratesList.length > 0
                implicitWidth: 100
                model: ratesList.map(function(r) { return r + " Hz"; })
                currentIndex: Math.max(0, ratesList.indexOf(ctrl.sample_rate))
                onActivated: function(i) { ctrl.apply_sample_rate(ratesList[i]); }
            }
            Controls.Label {
                visible: !srCombo.visible
                text: ctrl.engine_running ? (ctrl.sample_rate + " Hz") : "— Hz"
            }

            Controls.ToolSeparator {}

            // Clickable Xruns counter
            Controls.ToolButton {
                enabled: ctrl.engine_running
                text: ctrl.xruns === 1 ? qsTr("1 xrun") : qsTr("%1 xruns").arg(ctrl.xruns)
                onClicked: ctrl.clear_xruns()
                Controls.ToolTip.visible: hovered
                Controls.ToolTip.text: qsTr("Click to clear xruns")
            }

            Controls.ToolSeparator {}

            // DSP % Load Bar
            Controls.Label {
                text: qsTr("DSP")
                opacity: 0.75
            }
            Controls.ProgressBar {
                Layout.preferredWidth: 84
                Layout.alignment: Qt.AlignVCenter
                from: 0; to: 100
                value: ctrl.dsp_load
            }
            Controls.Label {
                Layout.preferredWidth: 34
                Layout.rightMargin: 6
                horizontalAlignment: Text.AlignRight
                text: Math.round(ctrl.dsp_load) + "%"
            }
        }
    }

    // Secondary Windows & Dialogs
    PluginEditWindow { id: pluginEditWin; controller: ctrl }
    AddPluginDialog { id: addPluginDlg; controller: ctrl }
    SettingsDialog { id: settingsDlg; controller: ctrl }
    RuntimeDriverDialog { id: runtimeDriverDlg; controller: ctrl }
    Dialogs {
        id: dialogs
        controller: ctrl
        onQuitConfirmed: {
            mainWindow.forceClose = true;
            mainWindow.close();
        }
    }
}
