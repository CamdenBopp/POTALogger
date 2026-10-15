# CLAUDE.md

Guidance for Claude Code when working in this repository.

This is the **`master`** branch of POTALogger: the cross-platform (**iOS and macOS**)
build, and the version intended to be **"App Store safe"** should we decide to
publish it. Treat App Store compliance as a hard constraint on this branch.

## SwiftUI style

Follow **Paul Hudson's (Hacking with Swift) SwiftUI best practices**, including his
Pro SwiftUI guidance. In practice:

- Prefer native, idiomatic SwiftUI — `Label`, `LabeledContent`, `Grid`, `.task`,
  `@AppStorage`, etc. — over hand-rolled equivalents.
- Use the standard text styles and respect Dynamic Type; avoid extremes like
  `.caption2` for primary content.
- Keep views small and composable; push logic into computed properties or view
  models rather than fat `body`s.
- Use modern Swift concurrency (`async`/`await`, `.task(id:)`) instead of timers
  or completion handlers where possible.
- Support light/dark appearance, Dynamic Type, and VoiceOver (group related
  elements with proper accessibility labels).

## App Store safety (hard constraint)

This branch must stay shippable to the App Store. When adding or changing code:

- **Public APIs only** — no private/SPI Apple APIs and no swizzling of system internals.
- **Keep the macOS sandbox enabled**; request only entitlements/capabilities that
  are actually used and justifiable.
- **Provide Info.plist privacy usage strings** for anything privacy-sensitive
  (location, notifications, etc.) and request permission at point of use.
- **No remote code execution / downloaded behavior** (App Store Review Guideline 2.5.2).
- **Respect third-party terms and rate limits** (e.g. the pota.app API); prefer
  official/public endpoints over scraping.
- Anything that risks review rejection — aggressive scraping, undocumented
  endpoints, non-sandbox distribution hacks — belongs on the `macos_dmg` branch,
  not here.
- Keep **both iOS and macOS** building and behaving; gate platform-specific code
  with `#if` / availability checks and keep sensible fallbacks.

## Branches

- **`master`** (this branch): cross-platform, App Store–safe — the publishable version.
- **`macos_dmg`**: macOS direct-distribution build (DMG via `create-dmg`); may use
  approaches not permitted in the App Store. Shared UI is kept in sync between the two.
