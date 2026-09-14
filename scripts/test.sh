#!/bin/zsh
# Runs the unit tests. Command Line Tools ship Swift Testing outside SwiftPM's default search paths.
set -e
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ -d "$FW/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test -Xswiftc -F -Xswiftc $FW -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker $FW -Xlinker -rpath -Xlinker $FW "$@"
fi
exec swift test "$@"
