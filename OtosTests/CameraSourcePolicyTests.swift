@testable import Otos
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
}
