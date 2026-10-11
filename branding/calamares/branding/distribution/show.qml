/* Distribution. installer slideshow — shown while it installs */
import QtQuick 2.15
import calamares.slideshow 1.0

Presentation {
    id: presentation

    function onActivate() { }
    function onLeave() { }

    Timer {
        interval: 6000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Rectangle { anchors.fill: parent; color: "#0E0E10" }
        Image {
            id: logo1
            source: "logo.png"
            width: 160; height: 160
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -40
        }
        Text {
            anchors.top: logo1.bottom; anchors.topMargin: 24
            anchors.horizontalCenter: parent.horizontalCenter
            text: "the period is dropping onto your disk."
            color: "#F4F1EC"; font.pixelSize: 20
        }
    }

    Slide {
        Rectangle { anchors.fill: parent; color: "#0E0E10" }
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            text: "gurt is your package manager.\n\ngurt install anything\ngurt upgrade to update everything"
            color: "#F4F1EC"; font.pixelSize: 20
        }
    }

    Slide {
        Rectangle { anchors.fill: parent; color: "#0E0E10" }
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            text: "typed pacman out of habit?\nit just turns into gurt. you're welcome."
            color: "#F4F1EC"; font.pixelSize: 20
        }
    }
}
