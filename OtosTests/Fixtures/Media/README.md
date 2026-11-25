# Media Fixtures

Generated stand-ins with real cameras' metadata, small enough to keep in the repository.
The pixels are a rendered fractal or ffmpeg's `testsrc2` pattern with grain; no photo of
a person or a place is in them. The stills carry the Exif and XMP of a real capture (GPS
and maker notes removed), so date, offset, orientation, exposure and lens behave like a
camera's file.

Files:

- `jpeg-exif-offset-date.jpg`: 6192x4128 JPEG with a Sony a6700's Exif: capture date,
  sub-seconds and a -08:00 offset.
- `ios-heic-offset-date.heic`: 4032x3024 HEIC with an iPhone 12 Pro's Exif, a -07:00
  offset and a 90° rotation (Exif orientation 6 and the HEIF `irot`), written through
  ImageIO.
- `mp4-no-embedded-capture-date.mp4`: 1.5 s, 960x1706, 59.94 fps, 10-bit HLG H.264 MP4
  without an embedded capture date.
- `mov-no-embedded-capture-date.mov`: 1.5 s, 960x1280, 60 fps, HLG H.264 QuickTime movie
  without an embedded capture date.

Privacy rules:

- Never add personal media: this repository is public, and a file once pushed stays in its history.
- Do not add files without clear rights to commit them.
- Do not add fixtures containing sensitive subjects, locations, or private
  metadata.
- Do not log fixture filenames as a pattern for production media logging.
