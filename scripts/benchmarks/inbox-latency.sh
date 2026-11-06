#!/bin/bash
# Run on an isolated GitHub macOS runner: UI automation needs a desktop.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
    echo "Use the Inbox latency workflow to run this benchmark on a remote desktop." >&2
    exit 1
fi
root=$(git rev-parse --show-toplevel)
revision=$(git rev-parse --verify --end-of-options "$1^{commit}")
name=$2
work="$RUNNER_TEMP/mail-benchmark-$name"
mkdir -p "$work"
git archive "$revision" | tar -x -C "$work"
cp "$root/scripts/benchmarks/InboxLatencyTests.swift" "$work/Tests/MishMailUITests/"
cp "$root/scripts/benchmarks/MailLatencyProbe.swift" "$work/Sources/MishMail/UI/"
cd "$work"
# Extend only the disposable source tree. The shipped app and the recorded
# revisions remain untouched. Keep the original inbox rows above the replicas.
python3 - <<'PY'
from pathlib import Path
source = Path("Sources/MishMail/Support/DemoSeed.swift")
text = source.read_text()
anchor = "                for msg in seedMessages {"
assert text.count(anchor) == 1
text = text.replace(anchor, """                for index in seedMessages.indices where seedMessages[index].id.contains("-x") {
                    seedMessages[index].date = seedMessages[index].date.addingTimeInterval(-60 * 86_400)
                }
                let index = seedMessages.firstIndex { $0.threadId == "\\(account):t2" }!
                let original = seedMessages[index]
                seedMessages[index].bodyText = String(repeating: "Scroll benchmark paragraph. Read the project update.\\n\\n", count: 100)
                for n in 1...39 {
                    var reply = original
                    reply.gmailId += "-reply-\\(n)"
                    reply.id += "-reply-\\(n)"
                    reply.date = original.date.addingTimeInterval(-Double(n) * 3600)
                    reply.messageIdHeader = "<bench-\\(n)@example.org>"
                    reply.bodyText = "Earlier benchmark reply."
                    seedMessages.append(reply)
                }
""" + anchor)
source.write_text(text)
def insert_after(filename, anchor, addition):
    path = Path("Sources/MishMail/UI") / filename
    text = path.read_text()
    assert text.count(anchor) == 1, anchor
    path.write_text(text.replace(anchor, anchor + addition))
insert_after("ThreadListView.swift", ".onAppear { recomputeLayout(scrollProxy: proxy) }",
             '\n            .background { if !grouped.isEmpty { MailLatencyProbe(name: "inbox") } }')
insert_after("ThreadDetailView.swift", "Text(PlainTextLinks.attributed(text))",
             '\n            .background { MailLatencyProbe(name: text.contains("Scroll benchmark paragraph") ? "long" : "short") }')

PY
xcodegen generate
# Debug bundle identity keeps fixtures separate; compile app code with release
# optimization for both revisions. The test runner uses the same settings.
xcodebuild test -project MishMail.xcodeproj -scheme MishMailUITests \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$work/build" \
    -clonedSourcePackagesDirPath "$RUNNER_TEMP/mail-benchmark-packages" \
    -parallel-testing-enabled NO -only-testing:MishMailUITests/InboxLatencyTests \
    SWIFT_OPTIMIZATION_LEVEL=-O CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    > "$RUNNER_TEMP/mail-benchmark-$name.log" 2>&1 || {
        tail -100 "$RUNNER_TEMP/mail-benchmark-$name.log"; exit 1
    }
grep -E '^MAIL_(NATIVE|LATENCY) ' "$RUNNER_TEMP/mail-benchmark-$name.log"
