import DiskArbitration
import Foundation
@testable import OtosKit
import Testing

/// Plan 0095 D10: `volumeIsRemovable == true` alone accepts mounted disk
/// images too — production evidence held `/Volumes/Raycast` and
/// `/Volumes/BoltAI 2`, both app-installer DMGs, as permanent removable
/// sources. `docs/research/2026-08-19-removable-volume-qualification.md`
/// measured what a real mounted DMG reports via the actual `DiskArbitration`
/// API (not a CLI tool's derived summary, which turned out to disagree —
/// see the research doc's "Correction" section); these fixtures are that
/// recorded data, not a guess.
struct RemovableVolumeMonitorQualificationTests {
    @Test func diskImageIsRejected() {
        #expect(!RemovableVolumeMonitor.isPhysicalRemovableDevice(deviceModel: "Disk Image"))
    }

    @Test func plausibleRealDeviceModelsAreAccepted() {
        // `kDADiskDescriptionDeviceModelKey` is an arbitrary hardware
        // vendor/model string, not a fixed enum — unlike disk images, which
        // measured evidence shows always report exactly `"Disk Image"`, there
        // is no closed set of "real" values to fixture. These are
        // illustrative (the internal SSD on the machine that ran this
        // research measured `"APPLE SSD AP0512R"`); the property under test
        // is simply "anything but the disk-image sentinel is accepted."
        for model in ["APPLE SSD AP0512R", "Kingston DataTraveler", "SD Card Reader", "Generic Flash Disk"] {
            #expect(
                RemovableVolumeMonitor.isPhysicalRemovableDevice(deviceModel: model),
                "\(model) should be accepted"
            )
        }
    }

    @Test func missingOrEmptyModelIsRejected() {
        // Fails closed: no answer is not proof of physical media.
        #expect(!RemovableVolumeMonitor.isPhysicalRemovableDevice(deviceModel: nil))
        #expect(!RemovableVolumeMonitor.isPhysicalRemovableDevice(deviceModel: ""))
    }
}

/// Exercises `deviceModel(forVolumeAt:session:)` against a real mounted disk
/// image rather than a mocked resource-value dictionary — the fact under
/// test is what `DiskArbitration` itself reports, which only a live mount
/// can prove. This is exactly the check that caught the research doc's
/// initial wrong guess (`kDADiskDescriptionDeviceProtocolKey`, which reports
/// the unhelpful `"Virtual Interface"` for a disk image, not `"Disk Image"`).
struct RemovableVolumeMonitorLiveDiskImageTests {
    @Test func mountedDiskImageReportsDiskImageModel() throws {
        let image = try MountedTestDiskImage.attach(named: "OtosQualificationTest")
        defer { image.detach() }

        let session = DASessionCreate(kCFAllocatorDefault)
        let reported = RemovableVolumeMonitor.deviceModel(forVolumeAt: image.mountURL, session: session)
        #expect(reported == "Disk Image")
        #expect(!RemovableVolumeMonitor.isPhysicalRemovableDevice(deviceModel: reported))
    }

    @Test func unmountedPathReportsNoModel() {
        let session = DASessionCreate(kCFAllocatorDefault)
        let neverMounted = URL(fileURLWithPath: "/Volumes/OtosNeverMounted-\(UUID().uuidString)", isDirectory: true)
        #expect(RemovableVolumeMonitor.deviceModel(forVolumeAt: neverMounted, session: session) == nil)
    }
}
