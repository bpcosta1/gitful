import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "bpc0sta.gitful"
    ipcTarget: "bpc0sta.gitful"
    manageIpc: false
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    readonly property string helper: Qt.resolvedUrl("gitful.py").toString().replace("file://", "")
    readonly property color foreground: Color.popups.text
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.65)
    readonly property string fontFamily: Style.font.family
    property var repositories: []
    property string failure: ""
    property string message: ""
    property bool actionFailed: false
    property string updated: "Waiting for first scan"
    property string query: ""
    property bool trackingOpen: false
    readonly property var selectedRepo: repositories.find(r => r.path === settingsPath) || null
    readonly property int selectedIndex: repositories.findIndex(r => r.path === settingsPath)
    property var preferences: ({})
    property bool settingsOpen: false
    property string settingsPath: ""
    property string settingsTitle: ""
    property var editingPreferences: ({})
    readonly property bool busy: scan.running || action.running
    readonly property var filtered: repositories.filter(r =>
        (r.name + " " + r.path + " " + (r.branch || "")).toLowerCase().includes(query.toLowerCase()))
    readonly property real lastFetch: repositories.reduce((latest, repo) => Math.max(latest, repo.fetched || 0), 0)
    readonly property int incoming: repositories.reduce((n, r) => n + (r.behind || 0), 0)
    readonly property int dirty: repositories.filter(r => r.dirty).length
    readonly property bool hasError: failure !== "" || repositories.some(r => r.error || r.fetch_error)
    readonly property int conflicts: repositories.reduce((n, r) => n + (r.conflicts || 0), 0)

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
        const index = repositories.findIndex(repo => repo.path === path);
        const neighbor = repositories[index + offset];
        if (index < 0 || !neighbor) return;
        runAction("move", path, [offset < 0 ? "before" : "after", neighbor.path]);
    }
    function showSettings(repo) {
        settingsPath = repo ? repo.path : "";
        settingsTitle = repo ? repo.name + " settings" : "Gitful settings";
        editingPreferences = repo ? (repo.settings || {}) : preferences;
        settingsOpen = true;
        trackingOpen = false;
        message = "";
    }
    function saveSettings(changes) {
        const extra = [JSON.stringify(changes)].concat(settingsPath ? ["--repo", settingsPath] : []);
        runAction("settings", "--set", extra);
    }
    function launch(repo, kind) { runAction("launch", repo.path, [kind]); }
    function changeSummary(repo) {
        const parts = [];
        if (repo.staged) parts.push(repo.staged + " staged");
        if (repo.unstaged) parts.push(repo.unstaged + " unstaged");
        if (repo.untracked) parts.push(repo.untracked + " untracked");
        if (repo.stashes) parts.push(repo.stashes + " stashes");
        if (repo.conflicts) parts.push(repo.conflicts + " conflicts");
        return parts.join(" · ") || "Working tree clean";
    }
    function fetchSummary(repo) {
        if (!repo.upstream) return "No upstream to fetch";
        if (!repo.fetched) return "No successful fetch yet · local refs may be stale";
        const age = Math.max(0, Math.floor((Date.now() / 1000 - repo.fetched) / 60));
        const elapsed = age < 1 ? "just now" : age < 60 ? age + "m ago" : Math.floor(age / 60) + "h ago";
        return "Fetched " + elapsed + (repo.stale ? " · stale refs" : "");
    }
    function pullReason(repo) {
        if (repo.error) return repo.error;
        if (repo.conflicts) return "Resolve conflicts before pulling";
        if (repo.operation) return "Finish the " + repo.operation.toLowerCase() + " before pulling";
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
        function settings(): void { root.showSettings(null); root.open(); }
        function state(): string { return JSON.stringify({repositories: root.repositories, preferences: root.preferences, settingsOpen: root.settingsOpen, failure: root.failure, busy: root.busy, foreground: String(root.foreground), background: String(Color.popups.background)}); }
    }
    Process {
        id: scan
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    const result = JSON.parse(text);
                    root.repositories = result.repositories;
                    root.preferences = result.preferences || {};
                    root.failure = result.error || "";
                    root.updated = result.updated ? "Checked " + Qt.formatDateTime(new Date(result.updated), "HH:mm:ss") : "Scan failed";
                } catch (e) { root.failure = "Could not read Gitful status. Check Python and Git."; }
            }
        }
        onExited: function(code) { if (code !== 0 && !root.failure) root.failure = "Gitful status helper failed"; }
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
                    if (result.ok && action.command[2] === "settings") root.editingPreferences = result.preferences;
                    if (result.ok && action.command[2] === "launch") root.close();
                    if (result.ok && action.command[2] === "add") { root.trackingOpen = false; addPath.text = ""; }
                    if (result.ok && action.command[2] === "remove") root.settingsOpen = false;
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
            if (!["move", "launch"].includes(action.command[2]) || code !== 0)
                Qt.callLater(function() { root.refresh(false); });
        }
    }
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: ""
        active: root.incoming > 0 || root.conflicts > 0
        tooltipText: "Gitful · " + root.repositories.length + " repos · " + root.incoming + " incoming · " + root.dirty + " dirty · " + root.conflicts + " conflicts" + (root.hasError ? " · Check errors" : "")
        onPressed: function(code) { if (code === Qt.LeftButton) root.toggle(); }
        Rectangle {
            visible: root.incoming > 0 || root.hasError || root.conflicts > 0
            anchors.top: parent.top; anchors.right: parent.right
            width: Math.max(Style.space(13), badge.implicitWidth + Style.space(5))
            height: Style.space(13); radius: height / 2
            color: root.hasError || root.conflicts > 0 ? Color.urgent : Color.accent
            Text {
                id: badge
                anchors.centerIn: parent
                text: root.hasError || root.conflicts > 0 ? "!" : root.incoming > 99 ? "99+" : root.incoming
                color: Color.background
                font.family: root.fontFamily; font.pixelSize: Style.space(9); font.bold: true
            }
        }
    }
    KeyboardPanel {
        id: popup
        anchorItem: button; owner: root; bar: root.bar; open: root.opened
        focusTarget: catcher
        contentWidth: fittedContentWidth(Style.space(520))
        contentHeight: fittedContentHeight(Style.space(root.settingsOpen ? 620 : Math.min(620, 190 + (root.trackingOpen ? 50 : 0) + root.filtered.length * 175)), Style.space(690))
        FocusScope {
            id: catcher
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.settingsOpen ? root.settingsOpen = false : root.trackingOpen ? root.trackingOpen = false : root.close()
            ColumnLayout {
                anchors.fill: parent; spacing: Style.space(12)
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: root.settingsOpen ? root.settingsTitle : "Gitful"; font.bold: true; font.pixelSize: Style.space(20); Layout.fillWidth: true; elide: Text.ElideRight }
                    ActionButton { visible: root.settingsOpen; text: "Back"; onClicked: root.settingsOpen = false }
                    ActionButton { visible: root.settingsOpen; text: "Save"; enabled: !root.busy; onClicked: settingsForm.save() }
                    ActionButton { visible: !root.settingsOpen; text: "+ Track repository"; onClicked: { root.trackingOpen = !root.trackingOpen; if (root.trackingOpen) addPath.forceActiveFocus(); } }
                    ActionButton { visible: !root.settingsOpen; text: "⚙"; Accessible.name: "Settings"; Controls.ToolTip.text: "Settings"; Controls.ToolTip.visible: hovered; onClicked: root.showSettings(null) }
                }
                Label {
                    visible: !root.settingsOpen
                    text: root.repositories.length + " repositories · " + root.incoming + " incoming commits"
                    color: root.muted; Layout.fillWidth: true; elide: Text.ElideRight
                }
                Controls.TextField {
                    visible: !root.settingsOpen
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
                    visible: !root.settingsOpen
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
                            spacing: Style.space(8)
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: row.modelData.name; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                Label { text: row.modelData.conflicts ? "● Conflicts" : row.modelData.dirty ? "● Modified" : "● Clean"; color: row.modelData.conflicts ? Color.urgent : row.modelData.dirty ? Color.accent : root.muted; visible: !row.modelData.error }
                                ActionButton { text: "Options"; enabled: !root.busy; onClicked: root.showSettings(row.modelData) }
                            }
                            Label { text: row.modelData.error || ("⑂ " + row.modelData.branch + (row.modelData.upstream ? " → " + row.modelData.upstream : " · No upstream")); color: row.modelData.error ? Color.urgent : root.muted; elide: Text.ElideRight; Layout.fillWidth: true }
                            Label { text: row.modelData.path; font.pixelSize: Style.space(10); color: root.muted; elide: Text.ElideMiddle; Layout.fillWidth: true; Controls.ToolTip.text: text; Controls.ToolTip.visible: pathHover.hovered; HoverHandler { id: pathHover } }
                            Label { visible: !row.modelData.error && !!(row.modelData.dirty || row.modelData.stashes); text: root.changeSummary(row.modelData); color: row.modelData.conflicts ? Color.urgent : root.muted; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Label { visible: !!row.modelData.operation; text: (row.modelData.operation || "") + " in progress"; color: Color.urgent; Layout.fillWidth: true }
                            Label { visible: !!row.modelData.fetch_error; text: "Fetch failed: " + (row.modelData.fetch_error || ""); color: Color.urgent; elide: Text.ElideRight; Layout.fillWidth: true; Controls.ToolTip.text: text; Controls.ToolTip.visible: fetchHover.hovered; HoverHandler { id: fetchHover } }
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: row.modelData.ahead === null ? "Comparison unavailable" : row.modelData.ahead + " unpushed · " + row.modelData.behind + " incoming"; color: row.modelData.behind || row.modelData.ahead ? Color.accent : root.muted; Layout.fillWidth: true; elide: Text.ElideRight }
                            }

                            RowLayout {
                                Layout.fillWidth: true; spacing: Style.space(5)
                                ActionButton { text: "IDE"; enabled: !root.busy && !row.modelData.error; onClicked: root.launch(row.modelData, "editor"); Controls.ToolTip.text: "Open preferred editor in this repository"; Controls.ToolTip.visible: hovered }
                                ActionButton { text: "Files"; enabled: !root.busy && !row.modelData.error; onClicked: root.launch(row.modelData, "files") }
                                ActionButton { text: "Agent"; enabled: !root.busy && !row.modelData.error; onClicked: root.launch(row.modelData, "agent"); Controls.ToolTip.text: "Start your configured coding agent in this repository"; Controls.ToolTip.visible: hovered }
                                Item { Layout.fillWidth: true }
                                ActionButton {
                                    text: "Pull"
                                    enabled: !root.busy && !row.modelData.error && !row.modelData.dirty && !row.modelData.operation && !row.modelData.detached && !!row.modelData.upstream && !(row.modelData.ahead && row.modelData.behind)
                                    onClicked: root.runAction("pull", row.modelData.path)
                                    Controls.ToolTip.text: root.pullReason(row.modelData); Controls.ToolTip.visible: hovered
                                }
                            }
                        }
                    }
                    Label { anchors.centerIn: parent; width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; visible: root.filtered.length === 0; text: root.repositories.length ? "No matching repositories" : "Add your first repository with + Track repository."; color: root.muted }
                }
                Controls.ScrollView {
                    id: settingsScroll
                    visible: root.settingsOpen
                    Layout.fillWidth: true; Layout.fillHeight: true
                    contentWidth: availableWidth
                    ColumnLayout {
                        width: settingsScroll.availableWidth
                        spacing: Style.space(16)
                        ColumnLayout {
                            visible: root.settingsPath !== ""
                            Layout.fillWidth: true
                            Label { text: root.settingsPath; color: root.muted; Layout.fillWidth: true; wrapMode: Text.WrapAnywhere }
                            Label { text: root.selectedRepo ? root.fetchSummary(root.selectedRepo) + " · Notifications: " + (root.selectedRepo.notification_status || "On") : ""; color: root.muted; Layout.fillWidth: true; wrapMode: Text.Wrap }
                            RowLayout {
                                Layout.fillWidth: true
                                ActionButton { text: "Move up"; enabled: !root.busy && root.selectedIndex > 0; onClicked: root.moveRepository(root.settingsPath, -1) }
                                ActionButton { text: "Move down"; enabled: !root.busy && root.selectedIndex >= 0 && root.selectedIndex < root.repositories.length - 1; onClicked: root.moveRepository(root.settingsPath, 1) }
                                Item { Layout.fillWidth: true }
                                ActionButton { text: "Untrack"; enabled: !root.busy; onClicked: root.runAction("remove", root.settingsPath); Controls.ToolTip.text: "Remove from Gitful; files are kept"; Controls.ToolTip.visible: hovered }
                            }
                        }
                        SettingsForm {
                            id: settingsForm
                            Layout.fillWidth: true
                            preferences: root.editingPreferences
                            perRepository: root.settingsPath !== ""
                            busy: root.busy
                            onSaveRequested: function(changes) { root.saveSettings(changes); }
                        }
                    }
                }
                RowLayout {
                    visible: !root.settingsOpen && root.trackingOpen
                    Layout.fillWidth: true
                    Controls.TextField {
                        id: addPath
                        Layout.fillWidth: true
                        placeholderText: "~/dev/project"
                        color: root.foreground; placeholderTextColor: root.muted
                        font.family: root.fontFamily; font.pixelSize: Style.font.body
                        background: Rectangle { color: "transparent"; radius: Style.space(5); border.color: root.muted }
                        onAccepted: if (text.trim() && !root.busy) root.runAction("add", text.trim())
                        Keys.onEscapePressed: root.trackingOpen = false
                    }
                    ActionButton { text: "Track"; enabled: !root.busy && addPath.text.trim() !== ""; onClicked: root.runAction("add", addPath.text.trim()) }
                    ActionButton { text: "Cancel"; onClicked: root.trackingOpen = false }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: (root.busy ? "Working…" : root.lastFetch ? "Last fetch " + Qt.formatDateTime(new Date(root.lastFetch * 1000), "HH:mm") : "No fetch yet") + " · Remote checks every " + Math.round((root.preferences.fetch_interval || 300) / 60) + "m by default"; color: root.muted; font.pixelSize: Style.space(10); Layout.fillWidth: true; elide: Text.ElideRight }
                    ActionButton { text: "↻"; Accessible.name: "Fetch all repositories"; enabled: !root.busy; onClicked: root.refresh(true); Controls.ToolTip.text: "Fetch all repositories"; Controls.ToolTip.visible: hovered }
                }
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
        contentItem: Label { id: label; text: control.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; color: control.checked ? Color.accent : root.foreground; opacity: control.enabled ? 1 : 0.4 }
        background: Rectangle { radius: Style.space(5); color: control.hovered && control.enabled ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"; border.color: control.checked || control.activeFocus ? Color.accent : root.muted; opacity: control.enabled ? 1 : 0.35 }
    }
}
