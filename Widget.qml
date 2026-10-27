import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "bpc0sta.gitpulse"
    ipcTarget: "bpc0sta.gitpulse"
    manageIpc: false
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    readonly property string helper: Qt.resolvedUrl("gitpulse.py").toString().replace("file://", "")
    readonly property color foreground: Color.popups.text
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.65)
    readonly property string fontFamily: Style.font.family
    property var repositories: []
    property string failure: ""
    property string message: ""
    property bool actionFailed: false
    property string updated: "Waiting for first scan"
    property string query: ""
    readonly property bool busy: scan.running || action.running
    readonly property var filtered: repositories.filter(r => (r.name + " " + r.path + " " + (r.branch || "")).toLowerCase().includes(query.toLowerCase()))
    readonly property int incoming: repositories.reduce((n, r) => n + (r.behind || 0), 0)
    readonly property int dirty: repositories.filter(r => r.dirty).length
    readonly property bool hasError: failure !== "" || repositories.some(r => r.error || r.fetch_error)

    function refresh(fetch) {
        if (busy) return;
        scan.command = ["python3", helper, "monitor"].concat(fetch ? ["--fetch"] : []);
        scan.running = true;
    }
    function runAction(name, path, extra) {
        if (busy) return;
        message = "";
        actionFailed = false;
        action.command = ["python3", helper, name, path].concat(extra || []);
        action.running = true;
    }
    function moveRepository(path, offset) {
        const index = filtered.findIndex(repo => repo.path === path);
        const neighbor = filtered[index + offset];
        if (index < 0 || !neighbor) return;
        runAction("move", path, [offset < 0 ? "before" : "after", neighbor.path]);
    }
    function pullReason(repo) {
        if (repo.error) return repo.error;
        if (repo.dirty) return "Commit or stash changes before pulling";
        if (repo.detached || !repo.upstream) return "A branch with an upstream is required";
        if (repo.ahead && repo.behind) return "Diverged branches: reconcile in your Git client";
        return "Fetch and fast-forward this repository";
    }
    Component.onCompleted: refresh(false)
    onOpenedChanged: if (opened) refresh(false)
    Timer { interval: 15000; running: true; repeat: true; onTriggered: root.refresh(false) }
    IpcHandler {
        target: root.ipcTarget
        function open(): void { root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.toggle() }
        function refresh(): void { root.refresh(false) }
        function state(): string { return JSON.stringify({repositories: root.repositories, failure: root.failure, busy: root.busy, foreground: String(root.foreground), background: String(Color.popups.background)}); }
    }
    Process {
        id: scan
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    const result = JSON.parse(text);
                    root.repositories = result.repositories;
                    root.failure = result.error || "";
                    root.updated = result.updated ? "Checked " + Qt.formatDateTime(new Date(result.updated), "HH:mm:ss") : "Scan failed";
                } catch (e) { root.failure = "Could not read GitPulse status. Check Python and Git."; }
            }
        }
        onExited: function(code) { if (code !== 0 && !root.failure) root.failure = "GitPulse status helper failed"; }
    }
    Process {
        id: action
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    const result = JSON.parse(text);
                    root.actionFailed = !result.ok;
                    root.message = result.error || result.message || "Done";
                    if (result.ok && result.order) {
                        const order = result.order;
                        const rank = path => order.includes(path) ? order.indexOf(path) : order.length;
                        root.repositories = root.repositories.slice().sort((a, b) => rank(a.path) - rank(b.path));
                    }
                } catch (e) { root.actionFailed = true; root.message = "Git operation failed."; }
            }
        }
        onExited: function(code) {
            if (code !== 0) root.actionFailed = true;
            if (action.command[2] !== "move" || code !== 0)
                Qt.callLater(function() { root.refresh(false); });
        }
    }
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: ""
        active: root.incoming > 0
        tooltipText: "GitPulse · " + root.repositories.length + " repos · " + root.incoming + " incoming · " + root.dirty + " dirty" + (root.hasError ? " · Check errors" : "")
        onPressed: function(code) { if (code === Qt.LeftButton) root.toggle(); }
        Rectangle {
            visible: root.incoming > 0 || root.hasError
            anchors.top: parent.top; anchors.right: parent.right
            width: Math.max(Style.space(13), badge.implicitWidth + Style.space(5))
            height: Style.space(13); radius: height / 2
            color: root.hasError ? Color.urgent : Color.accent
            Text {
                id: badge
                anchors.centerIn: parent
                text: root.hasError ? "!" : root.incoming > 99 ? "99+" : root.incoming
                color: Color.background
                font.family: root.fontFamily; font.pixelSize: Style.space(9); font.bold: true
            }
        }
    }
    KeyboardPanel {
        id: popup
        anchorItem: button; owner: root; bar: root.bar; open: root.opened
        focusTarget: catcher
        contentWidth: fittedContentWidth(Style.space(480))
        contentHeight: fittedContentHeight(Style.space(Math.min(540, 260 + root.filtered.length * 150)), Style.space(650))
        PanelKeyCatcher {
            id: catcher
            anchors.fill: parent
            onCloseRequested: root.close()
            ColumnLayout {
                anchors.fill: parent; spacing: Style.space(12)
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: "GitPulse"; font.bold: true; font.pixelSize: Style.space(20); Layout.fillWidth: true }
                    ActionButton { text: root.busy ? "Working…" : "Fetch now"; enabled: !root.busy; onClicked: root.refresh(true) }
                    ActionButton { text: "×"; onClicked: root.close(); Controls.ToolTip.text: "Close"; Controls.ToolTip.visible: hovered }
                }
                Label { text: root.repositories.length + " repositories · " + root.incoming + " incoming commits"; color: root.muted }
                Controls.TextField {
                    Layout.fillWidth: true
                    placeholderText: "Filter repositories or branches…"
                    color: root.foreground; placeholderTextColor: root.muted
                    font.family: root.fontFamily; font.pixelSize: Style.font.body
                    onTextChanged: root.query = text
                    background: Rectangle { color: "transparent"; radius: Style.space(5); border.color: root.muted }
                    Keys.onEscapePressed: root.close()
                }
                Label { visible: text !== ""; text: root.failure || root.message; color: root.failure || root.actionFailed ? Color.urgent : Color.accent; Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 4; elide: Text.ElideRight; Controls.ToolTip.text: text; Controls.ToolTip.visible: statusHover.hovered; HoverHandler { id: statusHover } }
                ListView {
                    id: list
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true; spacing: Style.space(8)
                    model: root.filtered
                    Controls.ScrollBar.vertical: Controls.ScrollBar {}
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        width: list.width; height: details.implicitHeight + Style.space(20)
                        color: "transparent"; radius: Style.space(6)
                        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
                        ColumnLayout {
                            id: details
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(10) }
                            spacing: Style.space(5)
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: row.modelData.name; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                Label { text: row.modelData.dirty ? "● Dirty · " + row.modelData.changed : "● Clean"; color: row.modelData.dirty ? Color.accent : root.muted; visible: !row.modelData.error }
                                ActionButton {
                                    text: "↑"; enabled: !root.busy && row.index > 0
                                    onClicked: root.moveRepository(row.modelData.path, -1)
                                    Accessible.name: "Move " + row.modelData.name + " up"
                                    Controls.ToolTip.text: "Move up · order is saved"; Controls.ToolTip.visible: hovered
                                }
                                ActionButton {
                                    text: "↓"; enabled: !root.busy && row.index < root.filtered.length - 1
                                    onClicked: root.moveRepository(row.modelData.path, 1)
                                    Accessible.name: "Move " + row.modelData.name + " down"
                                    Controls.ToolTip.text: "Move down · order is saved"; Controls.ToolTip.visible: hovered
                                }
                            }
                            Label { text: row.modelData.error || ("⑂ " + row.modelData.branch + (row.modelData.upstream ? " → " + row.modelData.upstream : " · No upstream")); color: row.modelData.error ? Color.urgent : root.muted; elide: Text.ElideRight; Layout.fillWidth: true }
                            Label { text: row.modelData.path; font.pixelSize: Style.space(10); color: root.muted; elide: Text.ElideMiddle; Layout.fillWidth: true; Controls.ToolTip.text: text; Controls.ToolTip.visible: pathHover.hovered; HoverHandler { id: pathHover } }
                            Label { visible: !!row.modelData.fetch_error; text: "Fetch failed: " + (row.modelData.fetch_error || ""); color: Color.urgent; elide: Text.ElideRight; Layout.fillWidth: true; Controls.ToolTip.text: text; Controls.ToolTip.visible: fetchHover.hovered; HoverHandler { id: fetchHover } }
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: row.modelData.ahead === null ? "Comparison unavailable" : "↑ " + row.modelData.ahead + "  ↓ " + row.modelData.behind; color: row.modelData.behind ? Color.accent : root.muted; Layout.fillWidth: true }
                                ActionButton { text: "Untrack"; enabled: !root.busy; onClicked: root.runAction("remove", row.modelData.path); Controls.ToolTip.text: "Remove from GitPulse; files are kept"; Controls.ToolTip.visible: hovered }
                                ActionButton {
                                    text: "Pull"
                                    enabled: !root.busy && !row.modelData.error && !row.modelData.dirty && !row.modelData.detached && !!row.modelData.upstream && !(row.modelData.ahead && row.modelData.behind)
                                    onClicked: root.runAction("pull", row.modelData.path)
                                    Controls.ToolTip.text: root.pullReason(row.modelData); Controls.ToolTip.visible: hovered
                                }
                            }
                            Label { visible: row.modelData.dirty || !!(row.modelData.ahead && row.modelData.behind); text: root.pullReason(row.modelData); color: root.muted; font.pixelSize: Style.space(10); wrapMode: Text.Wrap; Layout.fillWidth: true }
                        }
                    }
                    Label { anchors.centerIn: parent; width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; visible: root.filtered.length === 0; text: root.repositories.length ? "No matching repositories" : "Track a repository using its folder path below."; color: root.muted }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Controls.TextField {
                        id: addPath
                        Layout.fillWidth: true
                        placeholderText: "~/dev/project"
                        color: root.foreground; placeholderTextColor: root.muted
                        font.family: root.fontFamily; font.pixelSize: Style.font.body
                        background: Rectangle { color: "transparent"; radius: Style.space(5); border.color: root.muted }
                        onAccepted: if (text.trim() && !root.busy) root.runAction("add", text.trim())
                        Keys.onEscapePressed: root.close()
                    }
                    ActionButton { text: "Track"; enabled: !root.busy && addPath.text.trim() !== ""; onClicked: root.runAction("add", addPath.text.trim()) }
                }
                Label { text: root.updated + " · Automatic remote checks"; color: root.muted; font.pixelSize: Style.space(10); Layout.fillWidth: true; elide: Text.ElideRight }
            }
        }
    }
    component Label: Text {
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        textFormat: Text.PlainText
    }
    component ActionButton: Controls.Button {
        id: control
        implicitHeight: Style.space(30)
        implicitWidth: label.implicitWidth + Style.space(18)
        hoverEnabled: true
        contentItem: Label { id: label; text: control.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; opacity: control.enabled ? 1 : 0.4 }
        background: Rectangle { radius: Style.space(5); color: control.hovered && control.enabled ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"; border.color: control.activeFocus ? Color.accent : root.muted; opacity: control.enabled ? 1 : 0.35 }
    }
}
