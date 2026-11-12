import GRDB
@testable import OtosKit
import Testing

/// ARC-007: a device identity's text is what the catalog and the import journal persist,
/// so each constructor's text is fixed, and transience is decided by the type alone.
struct DeviceIdentityTests {
    @Test func eachConstructorWritesTheTextTheCatalogPersists() {
        #expect(DeviceIdentity.volume(uuid: "A1").rawValue == "volume:A1")
        #expect(DeviceIdentity.volume(mountPath: "/Volumes/CARD").rawValue == "volume:path:/Volumes/CARD")
        #expect(DeviceIdentity.camera(id: "serial-9").rawValue == "camera:serial-9")
        #expect(DeviceIdentity.camera(name: "EOS R5").rawValue == "camera:transient:EOS R5")
        #expect(DeviceIdentity.volume(uuid: "A1").disambiguated(mountPath: "/Volumes/CARD 1").rawValue
            == "volume:A1#path:/Volumes/CARD 1")
    }

    @Test func onlyMountPathNameAndDisambiguatedIdentitiesAreTransient() {
        #expect(!DeviceIdentity.volume(uuid: "A1").isTransient)
        #expect(!DeviceIdentity.camera(id: "serial-9").isTransient)
        #expect(DeviceIdentity.volume(mountPath: "/Volumes/CARD").isTransient)
        #expect(DeviceIdentity.camera(name: "EOS R5").isTransient)
        #expect(DeviceIdentity.volume(uuid: "A1").disambiguated(mountPath: "/Volumes/CARD 1").isTransient)
    }
}
