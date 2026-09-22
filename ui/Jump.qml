import QtQuick
import QtQuick.Controls.Basic

// Date filter, shown with `/`. The day list narrows as you type.
// Enter on one remaining day selects it. A year, month, or longer
// prefix filters the grid. A full month that is not loaded yet is fetched.
Rectangle {
  id: root

  required property var theme
  property var days: []   // [{label, date}], newest first
  property alias input: field
  signal requestClose()
  signal pickDay(string date)
  signal submitDate(string text)

  // Hide days that do not contain what has been typed so far.
  readonly property var shownDays: {
    var src = days || [];
    var q = field.text.trim().toLowerCase();
    if (!q) return src;
    var out = [];
    for (var i = 0; i < src.length; i++)
      if (root.dayMatches(src[i], q)) out.push(src[i]);
    return out;
  }

  function dayMatches(day, q) {
    var date = String(day.date).toLowerCase();
    var label = String(day.label).toLowerCase();
    if (label.indexOf(q) >= 0 || date.indexOf(q) >= 0) return true;
    // "2026-9" and "2026-9-2" should still find zero-padded days.
    var m = q.match(/^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$/);
    if (!m) return false;
    var mo = ("0" + m[2]).slice(-2);
    var padded = m[1] + "-" + mo;
    if (m[3] !== undefined) padded += "-" + ("0" + m[3]).slice(-2);
    return date.indexOf(padded) === 0;
  }

  function commit(text) {
    var shown = shownDays;
    if (shown.length === 1) { pickDay(shown[0].date); return; }
    var q = String(text || "").trim();
    if (/^\d{4}(-\d{0,2}(-\d{0,2})?)?$/.test(q)) submitDate(q);
  }

  color: Qt.rgba(0, 0, 0, 0.6)

  function focusField() { field.forceActiveFocus(); }

  onVisibleChanged: if (visible) {
    field.text = "";
    Qt.callLater(focusField);
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.requestClose()
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.min(420, root.width - 32)
    height: Math.min(520, root.height - 32)
    radius: 12
    color: theme.darkBackground
    border.color: theme.lighterBackground
    border.width: 1
    MouseArea { anchors.fill: parent }

    Column {
      anchors.fill: parent
      anchors.margins: 20
      spacing: 12

      Text {
        id: title
        text: "Filter to a date"
        color: theme.brightForeground
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize + 2
        font.bold: true
      }

      TextField {
        id: field
        width: parent.width
        height: 38
        color: theme.brightForeground
        placeholderText: "Type to filter dates"
        placeholderTextColor: theme.darkForeground
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize + 1
        leftPadding: 12
        rightPadding: 12
        selectByMouse: true
        onTextChanged: scroller.contentY = 0
        onAccepted: root.commit(text)
        Keys.onEscapePressed: event => {
          if (!root.visible) return;
          root.requestClose();
          event.accepted = true;
        }
        background: Rectangle {
          radius: 6
          color: theme.background
          border.width: field.activeFocus ? 2 : 1
          border.color: field.activeFocus ? theme.accent : theme.lighterBackground
        }
      }

      Flickable {
        id: scroller
        width: parent.width
        height: parent.height - title.height - field.height - parent.spacing * 2
        contentHeight: dayCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: dayCol
          width: scroller.width
          spacing: 2
          Text {
            visible: root.shownDays.length === 0
            height: root.shownDays.length === 0 ? implicitHeight : 0
            text: "No matching dates"
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
          }

          Repeater {
            model: root.shownDays
            delegate: Rectangle {
              required property var modelData
              width: dayCol.width
              height: 28
              radius: 6
              color: dayArea.containsMouse ? theme.lighterBackground : "transparent"
              Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label + "   " + modelData.date
                color: theme.foreground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize
              }
              MouseArea {
                id: dayArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.pickDay(modelData.date)
              }
            }
          }
        }
      }
    }
  }
}
