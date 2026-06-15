# Apple Documentation Grounding

Use exact Apple documentation, HIG, WWDC, or Swift-DocC sources when a decision
depends on platform semantics, API availability, Swift concurrency behavior,
SwiftUI/AppKit performance, signing, filesystem access, media APIs, or macOS UI
conventions.

## Helper

Fetch a known page through Sosumi:

```sh
script/apple-docs.sh 'https://developer.apple.com/documentation/swiftui/view'
script/apple-docs.sh '/documentation/swiftui/view'
script/apple-docs.sh '/design/human-interface-guidelines/designing-for-macos'
script/apple-docs.sh '/videos/play/wwdc2023/10248'
```

Use `doctor` to verify the helper:

```sh
script/apple-docs.sh doctor
```

## Citation Expectations

- Cite the original Apple URL or Sosumi URL in specs, ADRs, or PR notes when the
  implementation depends on it.
- Prefer direct symbol pages over framework landing pages.
- Mention when behavior is inferred from docs rather than stated directly.
- Do not rely on memory for API behavior that could have changed in the current
  Xcode/macOS beta.

## Accepted Inputs

The helper accepts:

- `https://developer.apple.com/...`
- `https://sosumi.ai/...`
- `/documentation/...`
- `/design/...`
- `/videos/play/...`
- external `https://...` Swift-DocC pages
