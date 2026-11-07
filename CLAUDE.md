# slopMTP

- The name is spelled **slopMTP** (lowercase s) in all user-facing text.
- User-facing strings must be localizable: SwiftUI literals localize automatically; anything built in code uses `String(localized:comment:)`, with a comment that gives translators context. MTPKit uses its own catalog through `L(_:comment:)`.
- String Catalogs: `App/slopMTP/Localizable.xcstrings` and `Packages/MTPKit/Sources/MTPKit/Localizable.xcstrings`.
- When translating, follow [TRANSLATION.md](TRANSLATION.md).
