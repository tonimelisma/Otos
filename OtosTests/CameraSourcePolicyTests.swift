import AppKit
import Foundation
@testable import OtosKit
import Testing

struct CameraSourcePolicyTests {
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
                identity: .volume(uuid: "duplicate"),
                displayName: "Card A",
                isEjectable: true,
                capabilities: .unknown
            ),
            RemovableVolumeAttachment(
                mountURL: URL(fileURLWithPath: "/Volumes/CardB", isDirectory: true),
                identity: .volume(uuid: "duplicate"),
                displayName: "Card B",
                isEjectable: true,
                capabilities: .unknown
            ),
        ])

        #expect(Set(attachments.map(\.identity)).count == 2)
        #expect(attachments[0].identity == .volume(uuid: "duplicate"))
        #expect(attachments[1].identity == DeviceIdentity(rawValue: "volume:duplicate#path:/Volumes/CardB"))
    }
}
