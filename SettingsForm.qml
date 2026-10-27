import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons

ColumnLayout {
    id: root
    property var preferences: ({})
    property var applications: ({editor: [], files: [], agent: []})
    property bool perRepository: false
    property bool busy: false
    property string feedback: ""
    property bool feedbackError: false
    property color foreground: Color.popups.text
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.65)
    property bool notificationsEnabled: true
    property bool incomingNotifications: true
    property bool errorNotifications: true
    property bool scheduleEnabled: false
    property bool fetchOnStartup: true
    property bool inheritsInterval: false
    property bool customInterval: false
    property int intervalSeconds: 300
    property var days: [0, 1, 2, 3, 4]
    property real snoozedUntil: 0
    property bool loading: false
    property bool dirty: false
    readonly property bool valid: inheritsInterval || !customInterval || (Number.isInteger(Number(customMinutes.text)) && Number(customMinutes.text) >= 1 && Number(customMinutes.text) <= 1440)
    signal saveRequested(var changes)
    signal testRequested(string kind, string command)
    signal edited()
    spacing: Style.space(12)

    function markDirty() {
        if (loading) return;
        dirty = true;
        edited();
    }
    function choicesFor(kind) {
        return [{name: "System default", command: ""}]
            .concat(applications[kind] || [])
            .concat([{name: "Custom command", command: "__custom__"}]);
    }
    function selectChoice(combo, kind, command) {
        const choices = choicesFor(kind);
        let index = choices.length - 1;
        for (let i = 0; i < choices.length; i++) {
            if (choices[i].command === command) { index = i; break; }
        }
        combo.currentIndex = index;
    }
    function load() {
        loading = true;
        const prefs = preferences || {};
        notificationsEnabled = prefs.notifications !== false;
        const types = prefs.notification_types || {};
        incomingNotifications = types.incoming_commits !== false;
        errorNotifications = types.fetch_errors !== false;
        snoozedUntil = prefs.snoozed_until || 0;
        inheritsInterval = perRepository && !!prefs.inherits_fetch_interval;
        intervalSeconds = prefs.fetch_interval || 300;
        customInterval = ![60, 300, 900].includes(intervalSeconds);
        customMinutes.text = String(Math.round(intervalSeconds / 60));
        fetchOnStartup = prefs.fetch_on_startup !== false;
        const launchers = prefs.launchers || {};
        editorSetting.command = launchers.editor || "";
        filesSetting.command = launchers.files || "";
        agentSetting.command = launchers.agent || "";
        const hours = prefs.work_hours || {};
        scheduleEnabled = !!hours.enabled;
        start.text = hours.start || "09:00";
        end.text = hours.end || "18:00";
        days = hours.weekdays || [0, 1, 2, 3, 4];
        selectChoice(editorSetting.choice, "editor", editorSetting.command);
        selectChoice(filesSetting.choice, "files", filesSetting.command);
        selectChoice(agentSetting.choice, "agent", agentSetting.command);
        dirty = false;
        Qt.callLater(function() { root.loading = false; });
    }
    onPreferencesChanged: Qt.callLater(load)
    onApplicationsChanged: if (!dirty) Qt.callLater(load)
    Component.onCompleted: load()
    function markSaved() { load(); }
    function setInterval(seconds, custom) {
        inheritsInterval = false;
        customInterval = custom;
        if (!custom) intervalSeconds = seconds;
        markDirty();
    }
    function snooze(minutes) {
        snoozedUntil = minutes === -1 ? 253402300799 : minutes === 0 ? 0 : Date.now() / 1000 + minutes * 60;
        markDirty();
    }
    function snoozeUntilTomorrow() {
        const tomorrow = new Date();
        tomorrow.setHours(24, 0, 0, 0);
        snoozedUntil = Math.floor(tomorrow.getTime() / 1000);
        markDirty();
    }
    function save() {
        const changes = {
            notifications: notificationsEnabled,
            notification_types: {incoming_commits: incomingNotifications, fetch_errors: errorNotifications},
            snoozed_until: snoozedUntil,
            fetch_interval: inheritsInterval ? null : customInterval ? Number(customMinutes.text) * 60 : intervalSeconds,
            launchers: {editor: editorSetting.command.trim(), files: filesSetting.command.trim(), agent: agentSetting.command.trim()}
        };
        if (!perRepository) {
            changes.fetch_on_startup = fetchOnStartup;
            changes.work_hours = {enabled: scheduleEnabled, start: start.text.trim(), end: end.text.trim(), weekdays: days};
        }
        saveRequested(changes);
    }

    SectionHeading { text: "NOTIFICATIONS" }
    Label { visible: root.dirty; text: "Unsaved changes"; color: Color.accent; Layout.fillWidth: true }
    SettingSwitch {
        text: root.perRepository ? "Notifications for this repository" : "Desktop notifications"
        checked: root.notificationsEnabled
        enabled: !root.busy
        onToggled: { root.notificationsEnabled = checked; root.markDirty(); }
    }
    Label { text: "Notify me about"; color: root.muted; Layout.fillWidth: true }
    RowLayout {
        Layout.fillWidth: true
        SettingSwitch { text: "Incoming commits"; checked: root.incomingNotifications; enabled: !root.busy; onToggled: { root.incomingNotifications = checked; root.markDirty(); } }
        Item { Layout.fillWidth: true }
        SettingSwitch { text: "Fetch errors"; checked: root.errorNotifications; enabled: !root.busy; onToggled: { root.errorNotifications = checked; root.markDirty(); } }
    }
    RowLayout {
        Layout.fillWidth: true
        Label {
            Layout.fillWidth: true
            text: !root.notificationsEnabled ? "Notifications muted for this scope" : root.snoozedUntil > Date.now() / 1000
                ? (root.snoozedUntil >= 253402300000 ? "Notifications snoozed indefinitely" : "Snoozed until " + Qt.formatDateTime(new Date(root.snoozedUntil * 1000), "ddd HH:mm"))
                : "Notifications are active"
            color: root.muted; elide: Text.ElideRight
        }
        ActionButton { text: "Unsnooze"; enabled: !root.busy && root.snoozedUntil > Date.now() / 1000; onClicked: root.snooze(0) }
    }
    Flow {
        Layout.fillWidth: true
        spacing: Style.space(5)
        ActionButton { text: "1 hour"; enabled: !root.busy; onClicked: root.snooze(60) }
        ActionButton { text: "4 hours"; enabled: !root.busy; onClicked: root.snooze(240) }
        ActionButton { text: "Until tomorrow"; enabled: !root.busy; onClicked: root.snoozeUntilTomorrow() }
        ActionButton { text: "Indefinitely"; enabled: !root.busy; onClicked: root.snooze(-1) }
    }
    ColumnLayout {
        visible: !root.perRepository
        Layout.fillWidth: true
        spacing: Style.space(7)
        Separator {}
        RowLayout {
            Layout.fillWidth: true
            Label { text: "Notification schedule"; font.bold: true; Layout.fillWidth: true }
            Label { text: "Local time"; color: root.muted; font.pixelSize: Style.space(10) }
        }
        SettingSwitch {
            text: "Only notify during selected hours"
            checked: root.scheduleEnabled
            enabled: !root.busy
            onToggled: { root.scheduleEnabled = checked; root.markDirty(); }
        }
        RowLayout {
            Layout.fillWidth: true
            Label { text: "From"; color: root.muted }
            Field { id: start; Layout.fillWidth: true; placeholderText: "09:00"; enabled: root.scheduleEnabled && !root.busy; onTextChanged: root.markDirty() }
            Label { text: "To"; color: root.muted }
            Field { id: end; Layout.fillWidth: true; placeholderText: "18:00"; enabled: root.scheduleEnabled && !root.busy; onTextChanged: root.markDirty() }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(3)
            Repeater {
                model: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                ActionButton {
                    required property string modelData
                    required property int index
                    text: modelData
                    active: root.days.includes(index)
                    enabled: root.scheduleEnabled && !root.busy
                    Layout.fillWidth: true
                    onClicked: { const d = index; root.days = root.days.includes(d) ? root.days.filter(v => v !== d) : root.days.concat([d]); root.markDirty(); }
                }
            }
        }
    }

    Separator { Layout.topMargin: Style.space(4) }
    SectionHeading { text: "REPOSITORY MONITORING" }
    Label { text: "Automatic fetching updates remote-tracking refs. It never pulls or merges into your branch."; color: root.muted; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Style.space(11) }
    Label { text: "Fetch interval"; font.bold: true }
    ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)
        Controls.RadioButton {
            visible: root.perRepository
            text: "Use global interval"
            checked: root.inheritsInterval
            enabled: !root.busy
            palette.highlight: Color.accent
            font.family: Style.font.family
            onClicked: { root.inheritsInterval = true; root.markDirty(); }
        }
        Repeater {
            model: [{label: "Every minute", seconds: 60}, {label: "Every 5 minutes (recommended)", seconds: 300}, {label: "Every 15 minutes", seconds: 900}]
            Controls.RadioButton {
                required property var modelData
                text: modelData.label
                checked: !root.inheritsInterval && !root.customInterval && root.intervalSeconds === modelData.seconds
                enabled: !root.busy
                palette.highlight: Color.accent
                font.family: Style.font.family
                onClicked: root.setInterval(modelData.seconds, false)
            }
        }
        Controls.RadioButton {
            text: "Custom interval"
            checked: !root.inheritsInterval && root.customInterval
            enabled: !root.busy
            palette.highlight: Color.accent
            font.family: Style.font.family
            onClicked: root.setInterval(root.intervalSeconds, true)
        }
        RowLayout {
            visible: root.customInterval && !root.inheritsInterval
            Layout.leftMargin: Style.space(28)
            Field {
                id: customMinutes
                Layout.preferredWidth: Style.space(105)
                placeholderText: "5"
                validator: IntValidator { bottom: 1; top: 1440 }
                onTextChanged: root.markDirty()
            }
            Label { text: "minutes (1 to 1440)"; color: root.muted }
        }
    }
    SettingSwitch {
        visible: !root.perRepository
        text: "Fetch on startup"
        checked: root.fetchOnStartup
        enabled: !root.busy
        onToggled: { root.fetchOnStartup = checked; root.markDirty(); }
    }

    Separator { Layout.topMargin: Style.space(4) }
    SectionHeading { text: "APPLICATIONS" }
    Label { text: root.perRepository ? "Choose commands for this repository. Empty fields inherit global commands." : "Choose an installed application or enter a custom command."; color: root.muted; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Style.space(11) }
    ApplicationField {
        id: editorSetting
        kind: "editor"; title: "Preferred IDE / editor"; choices: root.choicesFor("editor")
    }
    ApplicationField {
        id: filesSetting
        kind: "files"; title: "File manager"; choices: root.choicesFor("files")
    }
    ApplicationField {
        id: agentSetting
        kind: "agent"; title: "Coding agent (opens in a terminal)"; choices: root.choicesFor("agent")
    }
    Label { visible: root.feedback !== ""; text: root.feedback; color: root.feedbackError ? Color.urgent : Color.accent; Layout.fillWidth: true; wrapMode: Text.Wrap }

    component Label: Text {
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        textFormat: Text.PlainText
    }
    component Field: Controls.TextField {
        color: root.foreground
        placeholderTextColor: root.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        selectByMouse: true
        background: Rectangle {
            color: "transparent"
            radius: Style.space(5)
            border.color: parent.activeFocus ? Color.accent : root.muted
        }
    }
    component ActionButton: Controls.Button {
        id: control
        property bool active: false
        implicitHeight: Style.space(30)
        implicitWidth: content.implicitWidth + Style.space(16)
        hoverEnabled: true
        contentItem: Label {
            id: content
            text: control.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: control.active ? Color.accent : root.foreground
            opacity: control.enabled ? 1 : 0.4
        }
        background: Rectangle {
            radius: Style.space(5)
            color: control.hovered && control.enabled ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
            border.color: control.active || control.activeFocus ? Color.accent : root.muted
            opacity: control.enabled ? 1 : 0.35
        }
    }
    component SectionHeading: Label {
        font.bold: true
        font.pixelSize: Style.space(12)
    }
    component Separator: Rectangle {
        Layout.fillWidth: true
        implicitHeight: Style.space(1)
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
    }
    component SettingSwitch: Controls.Switch {
        id: settingSwitch
        contentItem: Label {
            text: settingSwitch.text
            color: root.foreground
            leftPadding: settingSwitch.indicator.width + Style.space(9)
            verticalAlignment: Text.AlignVCenter
            Layout.fillWidth: true
        }
        indicator: Rectangle {
            implicitWidth: Style.space(34)
            implicitHeight: Style.space(20)
            radius: height / 2
            x: settingSwitch.mirrored ? settingSwitch.width - width : 0
            y: settingSwitch.height / 2 - height / 2
            color: settingSwitch.checked ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
            border.color: settingSwitch.checked ? Color.accent : root.muted
            Rectangle {
                width: Style.space(14)
                height: width
                radius: width / 2
                x: settingSwitch.checked ? parent.width - width - Style.space(3) : Style.space(3)
                y: Style.space(3)
                color: settingSwitch.checked ? Color.background : root.foreground
                Behavior on x { NumberAnimation { duration: 100 } }
            }
        }
    }
    component ApplicationField: ColumnLayout {
        id: appField
        property string kind: ""
        property string title: ""
        property var choices: []
        property alias command: commandInput.text
        property alias choice: applicationChoice
        spacing: Style.space(5)
        Label { text: appField.title; font.bold: true }
        Controls.ComboBox {
            id: applicationChoice
            Layout.fillWidth: true
            model: appField.choices
            textRole: "name"
            valueRole: "command"
            enabled: !root.busy
            palette.text: root.foreground
            palette.buttonText: root.foreground
            palette.highlight: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            contentItem: Label { text: applicationChoice.displayText; color: root.foreground; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; leftPadding: Style.space(8) }
            background: Rectangle { color: "transparent"; radius: Style.space(5); border.color: applicationChoice.activeFocus ? Color.accent : root.muted }
            onActivated: {
                if (currentValue !== "__custom__") commandInput.text = currentValue;
                else { commandInput.text = ""; commandInput.forceActiveFocus(); }
                root.markDirty();
            }
        }
        Controls.TextField {
            id: commandInput
            Layout.fillWidth: true
            placeholderText: "Default command or custom command with {path}"
            color: root.foreground
            placeholderTextColor: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            selectByMouse: true
            enabled: !root.busy
            background: Rectangle { color: "transparent"; radius: Style.space(5); border.color: commandInput.activeFocus ? Color.accent : root.muted }
            onTextChanged: {
                if (root.loading) return;
                root.selectChoice(applicationChoice, appField.kind, text);
                root.markDirty();
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Label { text: "Runs in repository folder. Use {path} where needed."; color: root.muted; font.pixelSize: Style.space(10); Layout.fillWidth: true; wrapMode: Text.Wrap }
            ActionButton { text: "Test command"; enabled: !root.busy; onClicked: root.testRequested(appField.kind, commandInput.text.trim()) }
        }
    }
}
