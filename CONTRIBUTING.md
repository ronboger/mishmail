# Contributing to PerfectMail

Thanks for your interest! PerfectMail is a native macOS Gmail client built with
SwiftUI, the Gmail REST API, and GRDB/SQLCipher.

## Getting set up

```sh
brew install xcodegen
make hooks     # installs a pre-commit hook that runs the tests
make test      # generate the project + run the unit tests
make build     # build the app
```

The Xcode project is **generated** from [`project.yml`](project.yml) by
xcodegen — it is git-ignored, so never commit `PerfectMail.xcodeproj`. Edit
`project.yml` (targets, settings, dependencies) and re-run `xcodegen generate`.

Signing defaults to portable ad-hoc; see
[`Config/Signing.xcconfig`](Config/Signing.xcconfig) to use your own team.

## The test gate

`make test` must pass before every commit (the pre-commit hook enforces this
locally, and CI runs it on every push/PR). Tests live in
`Tests/PerfectMailTests` and cover the non-UI core: message/MIME parsing, the
DB schema and migrations, thread derivation, search-query parsing, and
send-scheduling. The test target is **hostless** — it compiles the relevant
`Sources/` files directly, so it needs no app host, Keychain, or network. When
you touch parser/DB/search/sync-derivation logic, add or update a test.

## Code layout

```
Sources/PerfectMail/
  App/        app entry + MailStore (the observable app state)
  Auth/       OAuth (PKCE, loopback listener)
  Gmail/      GmailClient, SyncEngine, MessageParsing/MIME
  Store/      Database (GRDB models, migrations, SQLCipher)
  Support/    Keychain, Ollama, SearchQuery, SendSchedule, Notifier, styles/colors
  UI/         SwiftUI views (ContentView, ThreadList/Detail, Compose, …)
```

`MailStore` is the hub most features touch; UI is SwiftUI-only with no view
models beyond `MailStore`.

## Conventions

- Swift 5.10, macOS 14 deployment target.
- Prefer parameterized SQL (never string-interpolate user input into queries).
- Anything that renders or executes untrusted mail content must stay sandboxed
  (see the WKWebView setup in `UI/ThreadDetailView.swift` and the [Security
  section of the README](README.md#security)).
- Keep secrets in the Keychain; never log tokens or message bodies.

## Pull requests

- Keep PRs focused; describe the user-facing change.
- Make sure `make test` passes and the app builds.
- For UI changes, a screenshot or short GIF helps a lot.
