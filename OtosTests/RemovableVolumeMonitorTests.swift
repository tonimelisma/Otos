import DiskArbitration
import Foundation
@testable import OtosKit
import Testing

/// APP-017: `volumeIsRemovable == true` alone accepts mounted disk
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
        let image = try MountedTestDiskImage.attach()
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

/// APP-017: removable reports are applied in the order DiskArbitration made them, and an
/// unmount request quiesces a source that resumes only when the request is refused.
struct RemovableVolumeTrackerTests {
    private static let card = RemovableVolumeAttachment(
        mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
        identity: .volume(uuid: "CARD-UUID"),
        displayName: "CARD",
        isEjectable: true
    )
    private static let cardDisk = RemovableVolumeDisk(volumePath: "/Volumes/CARD", volumeUUID: "CARD-UUID")

    @Test func aMountedCardAttachesOnceAndAnUnmountedOneDetaches() {
        var tracker = RemovableVolumeTracker()
        #expect(tracker.reconcile([Self.card]) == [.attach(Self.card)])
        #expect(tracker.reconcile([Self.card]).isEmpty)
        #expect(tracker.reconcile([]) == [.detach(Self.card.identity, .unmounted)])
    }

    @Test func anUnmountRequestQuiescesAndARefusalResumes() {
        var tracker = RemovableVolumeTracker()
        _ = tracker.reconcile([Self.card])
        let requested = tracker.unmountRequested(Self.cardDisk)
        guard case let .awaitRefusalLimit(identity, request) = requested.last else {
            Issue.record("Expected the refusal limit to start, got \(requested)")
            return
        }
        #expect(requested.first == .quiesce(Self.card.identity))
        #expect(identity == Self.card.identity)
        #expect(tracker.refusalLimitElapsed(identity: identity, request: request) == [.resume(identity)])
        #expect(tracker.refusalLimitElapsed(identity: identity, request: request).isEmpty, "resumes once")
    }

    @Test func anUnmountThatSucceedsDetachesAndNeverResumes() {
        var tracker = RemovableVolumeTracker()
        _ = tracker.reconcile([Self.card])
        guard case let .awaitRefusalLimit(identity, request) = tracker.unmountRequested(Self.cardDisk).last else {
            Issue.record("Expected the refusal limit to start")
            return
        }
        #expect(tracker.reconcile([]) == [.detach(identity, .unmounted)])
        #expect(tracker.refusalLimitElapsed(identity: identity, request: request).isEmpty)
    }

    /// A second request (a retried eject) quiesces again; the first request's limit
    /// elapsing must not resume the source the second one is still unmounting.
    @Test func anOlderRequestsLimitNeverResumesANewerRequest() {
        var tracker = RemovableVolumeTracker()
        _ = tracker.reconcile([Self.card])
        guard case let .awaitRefusalLimit(_, first) = tracker.unmountRequested(Self.cardDisk).last,
              case let .awaitRefusalLimit(identity, second) = tracker.unmountRequested(Self.cardDisk).last
        else {
            Issue.record("Expected two refusal limits")
            return
        }
        #expect(tracker.refusalLimitElapsed(identity: identity, request: first).isEmpty)
        #expect(tracker.refusalLimitElapsed(identity: identity, request: second) == [.resume(identity)])
    }

    @Test func aDisappearedCardDetachesAsDisconnectedMatchedByUUIDOrPath() {
        var tracker = RemovableVolumeTracker()
        _ = tracker.reconcile([Self.card])
        #expect(tracker.disappeared(RemovableVolumeDisk(volumePath: nil, volumeUUID: "CARD-UUID"))
            == [.detach(Self.card.identity, .disconnected)])
        _ = tracker.reconcile([Self.card])
        #expect(tracker.disappeared(RemovableVolumeDisk(volumePath: "/Volumes/CARD", volumeUUID: nil))
            == [.detach(Self.card.identity, .disconnected)])
        #expect(tracker.disappeared(Self.cardDisk).isEmpty, "an unknown disk changes nothing")
    }

    @Test func anUnmountRequestForAnUnknownDiskChangesNothing() {
        var tracker = RemovableVolumeTracker()
        _ = tracker.reconcile([Self.card])
        #expect(tracker.unmountRequested(RemovableVolumeDisk(volumePath: "/Volumes/OTHER", volumeUUID: nil)).isEmpty)
    }
}
