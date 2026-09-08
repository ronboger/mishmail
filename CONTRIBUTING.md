# Contributing to MishMail

Thanks for your interest! MishMail is a native macOS Gmail client built with
SwiftUI, the Gmail REST API, and GRDB/SQLCipher.

## Getting set up

```sh
brew install xcodegen
make hooks     # installs a pre-commit hook that runs the tests
make test      # generate the project + run the unit tests
make ui-test   # launch the fictional inbox and smoke-test the core UI
make build     # build the app
make run       # open the isolated Debug app with fictional demo mail
```

The Xcode project is **generated** from [`project.yml`](project.yml) by
xcodegen — it is git-ignored, so never commit `MishMail.xcodeproj`. Edit
`project.yml` (targets, settings, dependencies) and re-run `xcodegen generate`.

Signing defaults to portable ad-hoc; see
[`Config/Signing.xcconfig`](Config/Signing.xcconfig) to use your own team.

## The test gate

`make test` must pass before every commit (the pre-commit hook enforces this
locally, and CI runs it on every push to `main` and every pull request).
`make ui-test` is a separate CI job for launch, demo navigation, compose, and
Settings — it does not block the unit-test job from reporting. Tests live in
`Tests/MishMailTests` and cover the non-UI core: message/MIME parsing, the
DB schema and migrations, thread derivation, search-query parsing, and
send-scheduling. The test target is **hostless** — it compiles `Gmail/`,
`Store/`, `Auth/`, MCP helpers, and `Support/` by directory (app-only files
are excluded in `project.yml`), so it needs no app host, Keychain, or network.
Do not add individual production files to the test target; put new domain
code in those folders. Longer term this set becomes a Swift package both
targets import. When you touch parser/DB/search/sync-derivation logic, add or
update a test.

## Code layout

```
Sources/MishMail/
  App/        app entry + MailStore (observable UI state) and MailStore+*
              command extensions (sync, mutations, compose, reminders, AI,
              accounts)
  Auth/       OAuth (PKCE, loopback listener)
  Gmail/      GmailClient, SyncEngine, MessageParsing/MIME
  Store/      Database (GRDB models, migrations, SQLCipher)
  Support/    domain helpers and command policy (AccountLifecycle, AITriage,
              LocalReminders, ComposeDrafts, SearchQuery, …)
  UI/         SwiftUI views (ContentView, ThreadList/Detail, Compose, …)
```

`MailStore` is the observable state hub. Put new command/service work in a
`MailStore+…` extension or a Support policy type — do not grow the main
class, and do not add per-view MVVM objects.

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
