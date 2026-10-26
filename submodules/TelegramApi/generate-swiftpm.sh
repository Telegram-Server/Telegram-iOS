#!/bin/bash
# Generates the SwiftPM copy of TelegramApi's generated sources from swift_scheme.tl:
# Sources/SwiftPMGenerated, ObjC/SwiftPMGenerated and Tests/SwiftPMGenerated.
#
# Bazel never reads these: it generates its own copy on every build (the TelegramApiGenerated
# genrule in BUILD). SwiftPM consumers do, TelegramCore/Package.swift (which Telegram-Mac builds)
# among them. The copy is gitignored, swift_scheme.tl being the source of truth: run this before a
# SwiftPM build or test, and again after swift_scheme.tl or the generator changes.
set -euo pipefail

package="$(cd "$(dirname "$0")" && pwd)"
generator_package="$package/../../build-system/SwiftTL"

swift build -c release --package-path "$generator_package"
generator="$(swift build -c release --package-path "$generator_package" --show-bin-path)/SwiftTL"

rm -rf "$package/Sources/SwiftPMGenerated" "$package/ObjC/SwiftPMGenerated" "$package/Tests/SwiftPMGenerated"
# telesrv.tl is joined to swift_scheme.tl's function section, as BUILD's TelegramApiScheme genrule does.
scheme="$(mktemp)"
trap 'rm -f "$scheme"' EXIT
{ cat "$package/swift_scheme.tl"; echo; grep -v -e '^//' -e '^---' "$package/telesrv.tl"; } > "$scheme"
# The default --swift-file-count is the one BUILD passes, so both copies split the same way.
"$generator" "$scheme" "$package/Sources/SwiftPMGenerated" \
    --objc-output="$package/ObjC/SwiftPMGenerated" \
    --fixtures-output="$package/Tests/SwiftPMGenerated/SchemaFixtures.swift"
