import AppKit
import Foundation
@testable import OtosKit
import Testing

struct CameraSourcePolicyTests {
    @Test func unmountNotificationUsesWorkspaceVolumeURL() {
        let notification = Notification(
            name: NSWorkspace.didUnmountNotification,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(fileURLWithPath: "/Volumes/CARD")]
        )
        #expect(RemovableVolumeMonitor.volumePath(from: notification) == "/Volumes/CARD")
    }

    @Test func rejectsMassStorageAndMountedCameraDevices() {
        #expect(ImageCaptureCameraSourcePolicy.rejectionReason(
            mountPoint: "/Volumes/CARD",
            transportType: nil,
            locationDescription: nil
        ) == .mountedVolume)
        #expect(ImageCaptureCameraSourcePolicy.rejectionReason(
            mountPoint: nil,
            transportType: "USB Mass Storage",
            locationDescription: nil
        ) == .massStorageTransport)
        #expect(ImageCaptureCameraSourcePolicy.rejectionReason(
            mountPoint: nil,
            transportType: "PTP",
            locationDescription: "mass-storage bridge"
        ) == .massStorageLocation)
    }

    @Test func acceptsUnMountedPTPCameraDevices() {
        #expect(ImageCaptureCameraSourcePolicy.rejectionReason(
            mountPoint: nil,
            transportType: "PTP",
            locationDescription: "USB Camera"
        ) == nil)
    }

    @Test func duplicateRemovableVolumeIdentitiesArePathDisambiguated() {
        let attachments = RemovableVolumeMonitor.disambiguatedAttachments([
            RemovableVolumeAttachment(
                mountURL: URL(fileURLWithPath: "/Volumes/CardA", isDirectory: true),
                identity: "volume:duplicate",
                displayName: "Card A",
                isEjectable: true
            ),
            RemovableVolumeAttachment(
                mountURL: URL(fileURLWithPath: "/Volumes/CardB", isDirectory: true),
                identity: "volume:duplicate",
                displayName: "Card B",
                isEjectable: true
            ),
        ])

        #expect(Set(attachments.map(\.identity)).count == 2)
        #expect(attachments[0].identity == "volume:duplicate")
        #expect(attachments[1].identity == "volume:duplicate#path:/Volumes/CardB")
    }
}
