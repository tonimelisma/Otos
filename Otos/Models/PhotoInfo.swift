import CoreGraphics
import Foundation
import MediaMetadata

/// Photo info guide
///
/// What the inspector's Info pane shows for the current target (APP-041, DES-088): a
/// header (the file name and when it was taken) and sections of label and value rows —
/// Camera, Exposure or Video, People, Location, File — in the Edit pane's layout (DES-092).
///
/// Every value is something Otos already holds: the asset row, the metadata record the
/// library reported (ADR 0039), the overlay Otos keeps for the item, and where its original
/// is. Nothing reads the original's bytes for the pane. A fact the catalog does not have
/// reads `Unknown` rather than disappearing (APP-001); with no single item every value reads
/// `—`. Which sections show depends only on the kind, so a row never appears or vanishes
/// between two items of one kind (DES-053).
///
/// The place name is the one value not held: it is looked up from the coordinate when the
/// pane shows a located item (`CatalogWindowViewModel.refreshPhotoInfo`), and reads
/// `Unknown` until it arrives.
nonisolated struct PhotoInfo: Equatable, Sendable {
    static let unknown = "Unknown"
    static let notApplicable = "—"

    nonisolated enum SectionID: String, CaseIterable, Sendable {
        case camera
        case exposure
        case video
        case people
        case location
        case file

        var title: String {
            switch self {
            case .camera: "Camera"
            case .exposure: "Exposure"
            case .video: "Video"
            case .people: "People"
            case .location: "Location"
            case .file: "File"
            }
        }

        var symbol: String {
            switch self {
            case .camera: "camera"
            case .exposure: "camera.aperture"
            case .video: "film"
            case .people: "person.2"
            case .location: "mappin.and.ellipse"
            case .file: "doc"
            }
        }

        /// Each section's rows, in order. Location's leading `Place` row is added by
        /// `PhotoInfo.sections`, because it is the one value looked up after the rest.
        var labels: [String] {
            switch self {
            case .camera: ["Camera", "Lens", "Serial Number"]
            case .exposure: [
                    "Shutter Speed", "Aperture", "ISO", "Focal Length", "Compensation",
                    "Program", "Metering", "Flash", "White Balance",
                ]
            case .video: ["Duration", "Frame Rate", "Codec"]
            case .people: ["People"]
            case .location: ["Coordinates", "Altitude"]
            case .file: [
                    "Kind", "Dimensions", "Size", "Folder", "Original",
                    "Created", "Modified", "Imported", "Companions", "Edits",
                ]
            }
        }
    }

    nonisolated struct Row: Equatable, Sendable, Identifiable {
        let label: String
        let value: String

        var id: String {
            label
        }
    }

    nonisolated struct Section: Equatable, Sendable, Identifiable {
        let id: SectionID
        let rows: [Row]
    }

    /// The asset these facts describe; nil with no single item.
    let id: MediaAssetID?
    /// L1: the file name, `No Selection`, or `3 Items`.
    let title: String
    /// When it was taken, as the clock where it was taken read it, with that clock's offset
    /// from UTC when the file records one.
    let captured: String
    /// The primary location, for the map.
    let coordinate: PlaceCoordinate?
    /// The place name looked up from `coordinate`, once it arrives.
    var placeName: String?
    private let sectionRows: [SectionID: [Row]]
    private let sectionOrder: [SectionID]

    var sections: [Section] {
        sectionOrder.map { section in
            let rows = sectionRows[section] ?? []
            guard section == .location else {
                return Section(id: section, rows: rows)
            }
            let place = id == nil ? Self.notApplicable : placeName ?? Self.unknown
            return Section(id: section, rows: [Row(label: "Place", value: place)] + rows)
        }
    }

    // MARK: - No single item

    /// `No Selection`, or a count of the items selected, every value `—`.
    static func none(itemCount: Int) -> PhotoInfo {
        let order: [SectionID] = [.camera, .exposure, .people, .location, .file]
        var rows: [SectionID: [Row]] = [:]
        for section in order {
            rows[section] = section.labels.map { Row(label: $0, value: notApplicable) }
        }
        return PhotoInfo(
            id: nil,
            title: itemCount > 1 ? "\(itemCount.formatted()) Items" : "No Selection",
            captured: notApplicable,
            coordinate: nil,
            placeName: nil,
            sectionRows: rows,
            sectionOrder: order
        )
    }

    // MARK: - One item

    /// Everything Otos holds for one item: each piece nil when the catalog has none.
    nonisolated struct Source: Sendable {
        var id: MediaAssetID
        var asset: MediaAsset?
        var metadata: AssetMetadata?
        var overlay: PhotoInfoOverlay?
        /// The tile detail's kind, which knows the bytes; else the asset row's.
        var kind: MediaKind?
        /// The upright size the catalog's metadata reports.
        var nativePixelSize: CGSize?
        /// The name the sidebar shows for the item's library.
        var libraryName: String?
        var locality: OriginalLocality?
    }

    /// Everything Otos holds for one item, as the pane shows it.
    static func make(_ source: Source, calendar: Calendar = .current) -> PhotoInfo {
        let id = source.id, asset = source.asset, metadata = source.metadata
        let resolvedKind = source.kind ?? asset?.bestKind
        let order: [SectionID] = resolvedKind == .video
            ? [.camera, .video, .people, .location, .file]
            : [.camera, .exposure, .people, .location, .file]
        let location = metadata?.locations.first
        var rows: [SectionID: [Row]] = [:]
        rows[.camera] = cameraRows(metadata)
        rows[.exposure] = exposureRows(metadata?.exposure?.exposure)
        rows[.video] = videoRows(metadata, asset: asset)
        rows[.people] = [Row(label: "People", value: peopleValue(overlay: source.overlay, asset: asset))]
        rows[.location] = locationRows(location)
        rows[.file] = fileRows(source, kind: resolvedKind, calendar: calendar)
        return PhotoInfo(
            id: id,
            title: asset?.name ?? id.relativePath.fileName,
            captured: capturedValue(asset: asset, metadata: metadata, calendar: calendar),
            coordinate: location.map { PlaceCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
            placeName: nil,
            sectionRows: rows,
            sectionOrder: order
        )
    }

    /// Written as the clock where it was taken read it, whatever zone this Mac is in, with
    /// that clock's offset from UTC when the file records it.
    private static func capturedValue(asset: MediaAsset?, metadata: AssetMetadata?, calendar: Calendar) -> String {
        guard let local = asset?.captureLocalTime else {
            return unknown
        }
        let date = local.formatted(Date.FormatStyle(date: .complete, time: .shortened, calendar: calendar))
        let offset = metadata.flatMap { CaptureTimestamps(records: $0.timestamps).captureWallClock?.time.utcOffsetSeconds }
        guard let offset else {
            return date
        }
        return "\(date) \(utcOffset(offset))"
    }

    static func utcOffset(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        return "UTC\(seconds < 0 ? "−" : "+")\(String(format: "%02d:%02d", minutes / 60, minutes % 60))"
    }

    private static func cameraRows(_ metadata: AssetMetadata?) -> [Row] {
        [
            Row(label: "Camera", value: cameraName(make: metadata?.cameraMake, model: metadata?.cameraModel) ?? unknown),
            Row(label: "Lens", value: metadata?.lensModel ?? unknown),
            Row(label: "Serial Number", value: metadata?.serialNumber ?? unknown),
        ]
    }

    /// The make and model as one name, without repeating a make the model already starts
    /// with ("Canon" + "Canon EOS R5").
    static func cameraName(make: String?, model: String?) -> String? {
        switch (make, model) {
        case let (make?, model?):
            model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        case let (make?, nil):
            make
        case let (nil, model?):
            model
        case (nil, nil):
            nil
        }
    }

    private static func exposureRows(_ exposure: Exposure?) -> [Row] {
        let focal: String = if let millimeters = exposure?.focalLengthMillimeters {
            if let equivalent = exposure?.focalLengthIn35mmFilmMillimeters {
                "\(number(millimeters)) mm (\(equivalent) mm in 35 mm)"
            } else {
                "\(number(millimeters)) mm"
            }
        } else {
            unknown
        }
        return [
            Row(label: "Shutter Speed", value: exposure?.exposureTime.map(shutterSpeed) ?? unknown),
            Row(label: "Aperture", value: exposure?.fNumber.map { "ƒ/\(number($0))" } ?? unknown),
            Row(label: "ISO", value: exposure?.isoSensitivity.map { $0.formatted() } ?? unknown),
            Row(label: "Focal Length", value: focal),
            Row(label: "Compensation", value: exposure?.exposureBiasEV.map(exposureBias) ?? unknown),
            Row(label: "Program", value: exposure?.program.map(programName) ?? unknown),
            Row(label: "Metering", value: exposure?.meteringMode.map(meteringName) ?? unknown),
            Row(label: "Flash", value: exposure?.flash.map(flashDescription) ?? unknown),
            Row(label: "White Balance", value: exposure?.whiteBalance.map { $0 == .auto ? "Auto" : "Manual" } ?? unknown),
        ]
    }

    /// A shutter time as photographers write it: `1/250 s` below a second, `2.5 s` from one.
    static func shutterSpeed(_ time: ExposureTime) -> String {
        let seconds = time.seconds
        if seconds >= 1 {
            return "\(number(seconds)) s"
        }
        if time.numerator == 1 {
            return "1/\(time.denominator) s"
        }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    /// Exposure compensation to a tenth of a stop, signed, `0 EV` when none.
    static func exposureBias(_ ev: Double) -> String {
        let rounded = (ev * 10).rounded() / 10
        guard rounded != 0 else {
            return "0 EV"
        }
        return "\(rounded > 0 ? "+" : "−")\(number(abs(rounded))) EV"
    }

    private static func programName(_ program: ExposureProgram) -> String {
        switch program {
        case .manual: "Manual"
        case .normal: "Program"
        case .aperturePriority: "Aperture Priority"
        case .shutterPriority: "Shutter Priority"
        case .creative: "Creative"
        case .action: "Action"
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        }
    }

    private static func meteringName(_ mode: MeteringMode) -> String {
        switch mode {
        case .average: "Average"
        case .centerWeightedAverage: "Center-Weighted"
        case .spot: "Spot"
        case .multiSpot: "Multi-Spot"
        case .pattern: "Evaluative"
        case .partial: "Partial"
        case .other: "Other"
        }
    }

    static func flashDescription(_ flash: Flash) -> String {
        guard flash.hasFlashFunction else {
            return "No Flash"
        }
        var parts = [flash.fired ? "Fired" : "Did Not Fire"]
        switch flash.mode {
        case .auto: parts.append("Auto")
        case .on: parts.append("On")
        case .off: parts.append("Off")
        case nil: break
        }
        if flash.redEyeReduction {
            parts.append("Red-Eye Reduction")
        }
        return parts.joined(separator: ", ")
    }

    private static func videoRows(_ metadata: AssetMetadata?, asset: MediaAsset?) -> [Row] {
        let duration = metadata?.durationSeconds ?? asset?.durationSeconds
        return [
            Row(label: "Duration", value: duration.map(durationText) ?? unknown),
            Row(label: "Frame Rate", value: metadata?.frameRate.map { "\(number($0, digits: 2)) fps" } ?? unknown),
            Row(label: "Codec", value: metadata?.videoCodec.map(codecName) ?? unknown),
        ]
    }

    static func durationText(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// The library's codec as people name it; a code the library does not know is shown as
    /// its four-character code, and an identifier this build cannot read as stored.
    static func codecName(_ identifier: String) -> String {
        guard let codec = VideoCodec(identifier: identifier) else {
            return identifier
        }
        return switch codec {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes: "ProRes"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .motionJPEG: "Motion JPEG"
        case let .other(fourCC): fourCC
        }
    }

    /// Confirmed names only (DES-111). An item not yet read for faces is `Unknown`; one read
    /// with no one confirmed is `None`.
    private static func peopleValue(overlay: PhotoInfoOverlay?, asset: MediaAsset?) -> String {
        guard let overlay else {
            return unknown
        }
        if !overlay.people.isEmpty {
            return overlay.people.formatted(.list(type: .and))
        }
        return asset?.facesSourceSize == nil ? unknown : "None"
    }

    private static func locationRows(_ location: GeoRecord?) -> [Row] {
        [
            Row(label: "Coordinates", value: location.map(coordinates) ?? unknown),
            Row(label: "Altitude", value: location?.altitudeMeters.map { "\(Int($0.rounded()).formatted()) m" } ?? unknown),
        ]
    }

    static func coordinates(_ location: GeoRecord) -> String {
        func degrees(_ value: Double, positive: String, negative: String) -> String {
            "\(String(format: "%.5f", abs(value)))° \(value < 0 ? negative : positive)"
        }
        let latitude = degrees(location.latitude, positive: "N", negative: "S")
        return "\(latitude), \(degrees(location.longitude, positive: "E", negative: "W"))"
    }

    private static func fileRows(_ source: Source, kind: MediaKind?, calendar: Calendar) -> [Row] {
        let id = source.id, asset = source.asset, overlay = source.overlay
        let fileDate = Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar)
        let folders = id.relativePath.folder.split(separator: "/").map(String.init)
        let folder = ([source.libraryName ?? id.libraryRootPath.displayName] + folders).joined(separator: " ▸ ")
        let companions: String = if let overlay {
            overlay.companionFileNames.isEmpty ? "None" : overlay.companionFileNames.formatted(.list(type: .and))
        } else {
            unknown
        }
        let imported: String = if let overlay {
            overlay.importedAt.map { $0.formatted(fileDate) } ?? "Not Imported by Otos"
        } else {
            unknown
        }
        let edits: String = if let overlay {
            overlay.isEdited ? "Edited" : "None"
        } else {
            unknown
        }
        return [
            Row(label: "Kind", value: kindText(id: id, kind: kind)),
            Row(label: "Dimensions", value: dimensions(source.nativePixelSize)),
            Row(label: "Size", value: asset?.byteSize.map { ImportBarByteFormat.string(bytes: $0) } ?? unknown),
            Row(label: "Folder", value: folder),
            Row(label: "Original", value: source.locality.map(localityText) ?? unknown),
            Row(label: "Created", value: asset?.createdAt?.formatted(fileDate) ?? unknown),
            Row(label: "Modified", value: asset?.contentModifiedAt?.formatted(fileDate) ?? unknown),
            Row(label: "Imported", value: imported),
            Row(label: "Companions", value: companions),
            Row(label: "Edits", value: edits),
        ]
    }

    private static func kindText(id: MediaAssetID, kind: MediaKind?) -> String {
        let label: String? = switch kind {
        case .image: "Image"
        case .raw: "RAW image"
        case .video: "Video"
        case .none: nil
        }
        let format = id.relativePath.fileExtension.uppercased()
        return switch (label, format.isEmpty) {
        case let (label?, false): "\(label) · \(format)"
        case let (label?, true): label
        case (nil, false): format
        case (nil, true): unknown
        }
    }

    /// Pixel size and, from a million pixels, its megapixels.
    private static func dimensions(_ size: CGSize?) -> String {
        guard let size, size.width > 0, size.height > 0 else {
            return unknown
        }
        let width = Int(size.width), height = Int(size.height)
        let megapixels = Double(width * height) / 1_000_000
        let pixels = "\(width) × \(height)"
        return megapixels >= 1 ? "\(pixels) (\(number(megapixels, digits: 1)) MP)" : pixels
    }

    private static func localityText(_ locality: OriginalLocality) -> String {
        switch locality {
        case .local: "On This Mac"
        case .fetchable: "Not Downloaded"
        case .unreachable: "Unavailable"
        }
    }

    /// A decimal with at most `digits` fraction digits and no trailing zeros.
    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... digits)))
    }
}

/// The overlay Otos holds for one asset that the Info pane shows: confirmed people (DES-111),
/// companion files, the import it arrived in, and whether it is edited.
nonisolated struct PhotoInfoOverlay: Equatable, Sendable {
    var people: [String]
    var companionFileNames: [String]
    var importedAt: Date?
    var isEdited: Bool
}
