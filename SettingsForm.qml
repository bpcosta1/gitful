import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons

ColumnLayout {
    id: root
    property var preferences: ({})
    property bool perRepository: false
    property bool busy: false
    property color foreground: Color.popups.text
    readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.65)
    property bool notificationsEnabled: true
    property bool hoursEnabled: false
    property var days: [0, 1, 2, 3, 4]
    signal saveRequested(var changes)
    spacing: Style.space(10)

    function load() {
        const prefs = preferences || {};
        notificationsEnabled = prefs.notifications !== false;
        interval.text = prefs.inherits_fetch_interval ? "" : String((prefs.fetch_interval || 300) / 60);
        const launchers = prefs.launchers || {};
        editor.text = launchers.editor || "";
        files.text = launchers.files || "";
        agent.text = launchers.agent || "";
        const hours = prefs.work_hours || {};
        hoursEnabled = !!hours.enabled;
        start.text = hours.start || "09:00";
        end.text = hours.end || "18:00";
        days = hours.weekdays || [0, 1, 2, 3, 4];
    }
    onPreferencesChanged: Qt.callLater(load)
    Component.onCompleted: load()
    function save() {
        const value = interval.text.trim();
        const changes = {
            notifications: notificationsEnabled,
            fetch_interval: value === "" && perRepository ? null : Number(value) * 60,
            launchers: {editor: editor.text.trim(), files: files.text.trim(), agent: agent.text.trim()}
        };
        if (!perRepository) changes.work_hours = {enabled: hoursEnabled, start: start.text.trim(), end: end.text.trim(), weekdays: days};
        saveRequested(changes);
    }
    Label { text: "NOTIFICATIONS"; font.bold: true }
    RowLayout {
        Layout.fillWidth: true
        ActionButton {
            text: root.notificationsEnabled ? "Notifications: on" : "Notifications: muted"
            enabled: !root.busy
            onClicked: root.notificationsEnabled = !root.notificationsEnabled
        }
        Item { Layout.fillWidth: true }
        ActionButton { text: "Snooze 1h"; enabled: !root.busy; onClicked: root.saveRequested({snooze_minutes: 60}) }
        ActionButton { text: "Unsnooze"; enabled: !root.busy; onClicked: root.saveRequested({snooze_minutes: 0}) }
    }
    Label {
        visible: (root.preferences.snoozed_until || 0) > Date.now() / 1000
        text: "Snoozed until " + Qt.formatDateTime(new Date((root.preferences.snoozed_until || 0) * 1000), "ddd HH:mm")
        color: root.muted; Layout.fillWidth: true
    }
    Label { text: "Fetch interval (minutes, 1–1440)" }
    Field { id: interval; placeholderText: root.perRepository ? "Use global interval" : "5"; validator: IntValidator { bottom: 1; top: 1440 } }
    Label { visible: root.perRepository; text: "Global mute, snooze, and work hours also apply."; color: root.muted; Layout.fillWidth: true; wrapMode: Text.Wrap }
    ColumnLayout {
        visible: !root.perRepository
        Layout.fillWidth: true; spacing: Style.space(8)
        ActionButton { text: root.hoursEnabled ? "Work hours: enabled" : "Work hours: disabled"; enabled: !root.busy; onClicked: root.hoursEnabled = !root.hoursEnabled }
        RowLayout {
            Layout.fillWidth: true
            Label { text: "From" }
            Field { id: start; placeholderText: "09:00"; enabled: root.hoursEnabled }
            Label { text: "to" }
            Field { id: end; placeholderText: "18:00"; enabled: root.hoursEnabled }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: Style.space(3)
            Repeater {
                model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                ActionButton {
                    required property string modelData
                    required property int index
                    text: modelData
                    active: root.days.includes(index)
                    enabled: root.hoursEnabled && !root.busy
                    onClicked: {
                        const day = index;
                        root.days = root.days.includes(day) ? root.days.filter(value => value !== day) : root.days.concat([day]);
                    }
                }
            }
        }
        Label { text: "Local time. Notifications wait until the next allowed period. Fetching continues."; color: root.muted; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Style.space(11) }
    }
    Label { text: "OPEN REPOSITORY WITH"; font.bold: true; Layout.topMargin: Style.space(8) }
    Label { text: root.perRepository ? "Blank fields inherit global launch commands." : "Blank fields use your system defaults. Use {path} for the repository folder."; color: root.muted; Layout.fillWidth: true; wrapMode: Text.Wrap }
    Label { text: "Preferred IDE / editor" }
    Field { id: editor; placeholderText: "System editor (e.g. code {path})" }
    Label { text: "File manager" }
    Field { id: files; placeholderText: "System file manager (e.g. thunar {path})" }
    Label { text: "Coding agent · opens in a terminal" }
    Field { id: agent; placeholderText: "Omarchy default agent (e.g. claude)" }
    Label { text: "Commands run in the repository directory. Quote arguments containing spaces; shell operators are not expanded."; color: root.muted; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Style.space(11) }
    component Label: Text {
        color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body
        textFormat: Text.PlainText
    }
    component Field: Controls.TextField {
        Layout.fillWidth: true
        color: root.foreground; placeholderTextColor: root.muted
        font.family: Style.font.family; font.pixelSize: Style.font.body
        selectByMouse: true
        background: Rectangle { color: "transparent"; radius: Style.space(5); border.color: parent.activeFocus ? Color.accent : root.muted }
    }
    component ActionButton: Controls.Button {
        id: control
        property bool active: false
        implicitHeight: Style.space(30)
        implicitWidth: content.implicitWidth + Style.space(16)
        hoverEnabled: true
        contentItem: Label { id: content; text: control.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; color: control.active ? Color.accent : root.foreground; opacity: control.enabled ? 1 : 0.4 }
        background: Rectangle { radius: Style.space(5); color: control.hovered && control.enabled ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"; border.color: control.active || control.activeFocus ? Color.accent : root.muted; opacity: control.enabled ? 1 : 0.35 }
    }
}
