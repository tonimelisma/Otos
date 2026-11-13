import Foundation

/// How many photos and videos a count holds, and its words (DES-035): `photos` when every one
/// is a still, `videos` when every one is a video, and `photos and videos` once both are
/// there (owner decision, 2026-11-13, when videos joined People). A count says what it holds,
/// so a person's photos stay `photos` until one of them is a video.
nonisolated struct MediaCount: Hashable, Sendable {
    var photos: Int
    var videos: Int

    init(photos: Int = 0, videos: Int = 0) {
        self.photos = photos
        self.videos = videos
    }

    /// The distinct items among `items`, each with whether it is a video.
    init(items: some Sequence<(MediaAssetID, Bool)>) {
        var isVideo: [MediaAssetID: Bool] = [:]
        for (id, video) in items {
            isVideo[id] = video
        }
        self.init(photos: isVideo.values.count { !$0 }, videos: isVideo.values.count { $0 })
    }

    var total: Int {
        photos + videos
    }

    /// Sentence case: `1 photo`, `3 videos`, `14 photos and videos`.
    var text: String {
        "\(total.formatted()) \(noun(photo: "photo", video: "video", both: "photos and videos"))"
    }

    /// Title case, for menu items and titles (DES-037): `3 Photos`, `14 Photos & Videos`.
    var title: String {
        "\(total.formatted()) \(noun(photo: "Photo", video: "Video", both: "Photos & Videos"))"
    }

    private func noun(photo: String, video: String, both: String) -> String {
        if photos > 0, videos > 0 {
            return both
        }
        let word = videos > 0 ? video : photo
        return total == 1 ? word : word + "s"
    }
}
