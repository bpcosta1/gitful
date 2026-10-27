import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import qs.Ui as Ui

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
    property var applications: ({editor: [], files: [], agent: []})
    property string failure: ""
    property string message: ""
    property bool actionFailed: false
    property bool refreshing: false
    property string updated: "Waiting for first scan"
    property string query: ""
    property bool trackingOpen: false
    property string openMenuPath: ""
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
    readonly property color cleanColor: "#69c891"

    function statusText(repo) {
        if (repo.error || repo.fetch_error) return "Error";
        if (repo.conflicts) return "Conflicts";
        if (repo.operation) return repo.operation + " in progress";
        return repo.dirty ? "Modified" : "Clean";
    }
    function statusColor(repo) {
        if (repo.error || repo.fetch_error || repo.conflicts || repo.operation) return Color.urgent;
        return repo.dirty ? Color.accent : cleanColor;
    }

    function refresh(fetch, startup) {
        if (busy) return;
        refreshing = true;
        scan.command = ["python3", helper, "monitor"].concat(fetch ? ["--fetch"] : []).concat(startup ? ["--startup"] : []);
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
        openMenuPath = "";
        settingsPath = repo ? repo.path : "";
        settingsTitle = repo ? repo.name + " settings" : "Gitful settings";
        editingPreferences = repo ? (repo.settings || {}) : preferences;
        settingsOpen = true;
        trackingOpen = false;
        message = "";
        if (!appScan.running) {
            appScan.command = ["python3", helper, "applications"];
            appScan.running = true;
        }
        Qt.callLater(function() { settingsForm.load(); });
    }
    function showRepositorySettings(repo) {
        openMenuPath = "";
        showSettings(repo);
        open();
        Qt.callLater(function() {
            root.settingsOpen = true;
            root.open();
        });
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
    Component.onCompleted: refresh(false, true)
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
                    root.applications = result.applications || root.applications;
                    root.failure = result.error || "";
                    root.updated = result.updated ? "Checked " + Qt.formatDateTime(new Date(result.updated), "HH:mm:ss") : "Scan failed";
                } catch (e) { root.failure = "Could not read Gitful status. Check Python and Git."; }
            }
        }
        onExited: function(code) {
            root.refreshing = false;
            if (code !== 0 && !root.failure) root.failure = "Gitful status helper failed";
        }
    }
    Process {
        id: appScan
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { root.applications = JSON.parse(text).applications || root.applications; }
                catch (e) { root.message = "Could not detect installed applications."; root.actionFailed = true; }
            }
        }
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
                    if (result.ok && action.command[2] === "settings") {
                        root.editingPreferences = result.preferences;
                        Qt.callLater(function() { settingsForm.markSaved(); });
                    }
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
        contentHeight: fittedContentHeight(Style.space(root.settingsOpen ? 620 : Math.max(500, Math.min(620, 150 + (root.trackingOpen ? 50 : 0) + root.filtered.length * 117))), Style.space(690))
        FocusScope {
            id: catcher
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.openMenuPath !== "" ? root.openMenuPath = "" : root.settingsOpen ? root.settingsOpen = false : root.trackingOpen ? root.trackingOpen = false : root.close()
            Keys.onPressed: function(event) {
                if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_K) {
                    searchField.forceActiveFocus();
                    searchField.selectAll();
                    event.accepted = true;
                }
            }
            ColumnLayout {
                id: popupColumn
                anchors.fill: parent; spacing: Style.space(9)
                Item {
                    Layout.fillWidth: true
                    implicitHeight: Math.max(headerLabels.implicitHeight, headerActions.implicitHeight)
                    ColumnLayout {
                        id: headerLabels
                        anchors.left: parent.left
                        anchors.right: headerActions.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0
                        Label { text: root.settingsOpen ? root.settingsTitle : "Gitful"; font.bold: true; font.pixelSize: Style.space(20); elide: Text.ElideRight }
                    }
                    RowLayout {
                        id: headerActions
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)
                        ActionButton { visible: root.settingsOpen; text: "Cancel"; onClicked: root.settingsOpen = false }
                        ActionButton { visible: root.settingsOpen; text: "Save"; enabled: !root.busy && settingsForm.dirty && settingsForm.valid; selected: settingsForm.dirty; onClicked: settingsForm.save() }
                        ActionButton { visible: !root.settingsOpen; text: "Track repository"; iconText: "󰐕"; selected: root.trackingOpen; onClicked: { root.trackingOpen = !root.trackingOpen; if (root.trackingOpen) addPath.forceActiveFocus(); } }
                        ActionButton { visible: !root.settingsOpen; iconText: "󰒓"; tooltipText: "Settings"; Accessible.name: "Settings"; onClicked: root.showSettings(null) }
                    }
                }
                Rectangle {
                    visible: !root.settingsOpen
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(5)
                    implicitHeight: Style.space(36)
                    radius: Style.space(6)
                    color: searchField.activeFocus ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05) : "transparent"
                    border.color: searchField.activeFocus ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(9); anchors.rightMargin: Style.space(8)
                        spacing: Style.space(7)
                        Label { text: "󰍉"; color: root.muted; font.pixelSize: Style.space(14) }
                        Controls.TextField {
                            id: searchField
                            Layout.fillWidth: true
                            placeholderText: "Search repositories or branches…"
                            color: root.foreground; placeholderTextColor: root.muted
                            font.family: root.fontFamily; font.pixelSize: Style.font.body
                            selectByMouse: true
                            onTextChanged: root.query = text
                            background: Item {}
                            Keys.onEscapePressed: { clear(); root.catcher.forceActiveFocus(); }
                        }
                        Label { text: "Ctrl K"; color: root.muted; font.pixelSize: Style.space(9) }
                    }
                }
                Label { visible: !root.settingsOpen && text !== ""; text: root.failure || root.message; color: root.failure || root.actionFailed ? Color.urgent : Color.accent; Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                ListView {
                    id: list
                    visible: !root.settingsOpen
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true; spacing: Style.space(6)
                    model: root.filtered
                    Controls.ScrollBar.vertical: Controls.ScrollBar {}
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        width: list.width; height: details.implicitHeight + Style.space(16)
                        color: rowHover.hovered ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.018)
                        radius: Style.space(6)
                        border.color: rowHover.hovered ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                        Behavior on color { ColorAnimation { duration: 100 } }
                        HoverHandler { id: rowHover }
                        ColumnLayout {
                            id: details
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(8) }
                            spacing: Style.space(4)
                            RowLayout {
                                Layout.fillWidth: true; spacing: Style.space(5)
                                Label { text: row.modelData.name; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                Label { text: "●"; color: root.statusColor(row.modelData); font.pixelSize: Style.space(11) }
                                Label { text: root.statusText(row.modelData); color: root.statusColor(row.modelData); font.pixelSize: Style.space(10) }
                                ActionButton {
                                    id: contextButton
                                    iconText: "󰇘"; tooltipText: "Repository options"; Accessible.name: "Options for " + row.modelData.name
                                    enabled: !root.busy; bordered: false
                                    onClicked: root.openMenuPath = root.openMenuPath === row.modelData.path ? "" : row.modelData.path
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: Style.space(6)
                                Label {
                                    text: row.modelData.error || ("⑂ " + row.modelData.branch + (row.modelData.upstream ? " → " + row.modelData.upstream : " · No upstream"))
                                    color: row.modelData.error ? Color.urgent : root.muted; elide: Text.ElideRight; Layout.fillWidth: true
                                    Controls.ToolTip.text: text; Controls.ToolTip.visible: branchHover.hovered
                                    HoverHandler { id: branchHover }
                                }
                                Label {
                                    text: row.modelData.path; color: root.muted; font.pixelSize: Style.space(9)
                                    elide: Text.ElideLeft; horizontalAlignment: Text.AlignRight; Layout.maximumWidth: Style.space(180)
                                    Controls.ToolTip.text: text; Controls.ToolTip.visible: pathHover.hovered
                                    HoverHandler { id: pathHover }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: Style.space(8)
                                Label { text: "↑ " + (row.modelData.ahead === null ? "–" : row.modelData.ahead); color: row.modelData.ahead ? Color.accent : root.muted }
                                Label { text: "↓ " + (row.modelData.behind === null ? "–" : row.modelData.behind); color: row.modelData.behind ? Color.accent : root.muted }
                                Label { visible: !!row.modelData.stashes; text: "󰆓 " + row.modelData.stashes; color: root.muted; Controls.ToolTip.text: row.modelData.stashes + " stashes"; Controls.ToolTip.visible: stashHover.hovered; HoverHandler { id: stashHover } }
                                Label { visible: !!row.modelData.staged; text: "+" + row.modelData.staged + " staged"; color: root.muted }
                                Label { visible: !!row.modelData.unstaged; text: "~" + row.modelData.unstaged + " unstaged"; color: Color.accent }
                                Label { visible: !!row.modelData.untracked; text: "?" + row.modelData.untracked + " untracked"; color: root.muted }
                                Label { visible: !!row.modelData.conflicts; text: "!" + row.modelData.conflicts + " conflicts"; color: Color.urgent }
                                Item { Layout.fillWidth: true }
                            }
                            Label {
                                visible: !!row.modelData.fetch_error
                                text: "Fetch failed: " + (row.modelData.fetch_error || "")
                                color: Color.urgent; elide: Text.ElideRight; Layout.fillWidth: true; font.pixelSize: Style.space(9)
                                Controls.ToolTip.text: text; Controls.ToolTip.visible: fetchHover.hovered
                                HoverHandler { id: fetchHover }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: Style.space(3)
                                ActionButton { text: "IDE"; iconText: "󰆍"; bordered: false; enabled: !root.busy && !row.modelData.error; onClicked: root.launch(row.modelData, "editor"); tooltipText: "Open preferred editor" }
                                ActionButton { text: "Files"; iconText: "󰉋"; bordered: false; enabled: !root.busy && !row.modelData.error; onClicked: root.launch(row.modelData, "files"); tooltipText: "Open file manager" }
                                ActionButton { text: "Terminal"; iconText: ""; bordered: false; enabled: !root.busy && !row.modelData.error; onClicked: root.launch(row.modelData, "terminal"); tooltipText: "Open terminal in repository" }
                                ActionButton { text: "Agent"; iconText: "󰚩"; bordered: false; enabled: !root.busy && !row.modelData.error; onClicked: root.launch(row.modelData, "agent"); tooltipText: "Start coding agent" }
                                Item { Layout.fillWidth: true }
                                ActionButton {
                                    text: "Pull"; iconText: "󰁅"; selected: !!row.modelData.behind
                                    enabled: !root.busy && !row.modelData.error && !row.modelData.dirty && !row.modelData.operation && !row.modelData.detached && !!row.modelData.upstream && !(row.modelData.ahead && row.modelData.behind)
                                    onClicked: root.runAction("pull", row.modelData.path)
                                    tooltipText: root.pullReason(row.modelData)
                                }
                            }
                        }
                        Rectangle {
                            id: repositoryMenu
                            visible: root.openMenuPath === row.modelData.path
                            z: 10
                            width: Style.space(194)
                            height: menuItems.implicitHeight + Style.space(12)
                            x: row.width - width - Style.space(8)
                            y: Style.space(6)
                            radius: Style.space(6)
                            color: Color.popups.background
                            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.24)

                            ColumnLayout {
                                id: menuItems
                                anchors.fill: parent
                                anchors.margins: Style.space(6)
                                spacing: Style.space(2)
                                ActionButton {
                                    Layout.fillWidth: true
                                    text: "Repository settings"
                                    onClicked: root.showRepositorySettings(row.modelData)
                                }
                                ActionButton {
                                    Layout.fillWidth: true
                                    text: "Move up"
                                    enabled: root.repositories.findIndex(repo => repo.path === row.modelData.path) > 0
                                    onClicked: { root.openMenuPath = ""; root.moveRepository(row.modelData.path, -1); }
                                }
                                ActionButton {
                                    Layout.fillWidth: true
                                    text: "Move down"
                                    enabled: root.repositories.findIndex(repo => repo.path === row.modelData.path) < root.repositories.length - 1
                                    onClicked: { root.openMenuPath = ""; root.moveRepository(row.modelData.path, 1); }
                                }
                                ActionButton {
                                    Layout.fillWidth: true
                                    text: "Untrack repository"
                                    onClicked: { root.openMenuPath = ""; root.runAction("remove", row.modelData.path); }
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
                        }
                        SettingsForm {
                            id: settingsForm
                            Layout.fillWidth: true
                            preferences: root.editingPreferences
                            perRepository: root.settingsPath !== ""
                            applications: root.applications
                            busy: root.busy
                            feedback: root.message
                            feedbackError: root.actionFailed
                            onEdited: root.message = ""
                            onSaveRequested: function(changes) { root.saveSettings(changes); }
                            onTestRequested: function(kind, command) {
                                const extra = [command];
                                if (root.settingsPath) extra.push("--repo", root.settingsPath);
                                root.runAction("test-launch", kind, extra);
                            }
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
                    ActionButton { text: "Add"; enabled: !root.busy && addPath.text.trim() !== ""; onClicked: root.runAction("add", addPath.text.trim()) }
                    ActionButton { text: "Cancel"; onClicked: root.trackingOpen = false }
                }
                RowLayout {
                    visible: !root.settingsOpen
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(8)
                    spacing: Style.space(5)
                    Label { text: "●"; color: root.hasError ? Color.urgent : root.incoming ? Color.accent : root.cleanColor; font.pixelSize: Style.space(10) }
                    Label {
                        text: (root.refreshing ? "Checking repositories" : root.hasError ? "Fetch needs attention" : root.incoming ? root.incoming + " incoming commits" : "Up to date")
                            + " · Last fetch " + (root.lastFetch ? Qt.formatDateTime(new Date(root.lastFetch * 1000), "HH:mm") : "-")
                            + " · Checks every " + Math.round((root.preferences.fetch_interval || 300) / 60) + "m"
                        color: root.hasError ? Color.urgent : root.muted; font.pixelSize: Style.space(9); Layout.fillWidth: true; elide: Text.ElideRight
                    }
                    ActionButton { text: "Fetch now"; iconText: "󰑐"; iconSpinning: root.refreshing; enabled: !root.busy; onClicked: root.refresh(true); tooltipText: "Fetch all repositories now" }
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
    component ActionButton: Ui.Button {
        implicitHeight: Style.space(32)
        bordered: true
        focusable: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        iconSize: Style.font.icon
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(5)
    }
}
