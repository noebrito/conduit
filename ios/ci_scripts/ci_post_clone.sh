#!/bin/sh

# Xcode Cloud ci_post_clone script
#
# Sets CURRENT_PROJECT_VERSION for every target in the pbxproj to Xcode Cloud's
# auto-incrementing build number so each TestFlight upload has a unique,
# increasing CFBundleVersion.
#
# We edit the pbxproj directly (rather than `agvtool new-version -all`) to match
# the approach used by the other iOS projects in this repo, which avoids agvtool
# stalls on projects that mix generated and explicit Info.plist targets.

set -eu

PBXPROJ="$CI_PRIMARY_REPOSITORY_PATH/conduit/ios/Conduit.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
    echo "ci_post_clone: pbxproj not found at $PBXPROJ" >&2
    exit 1
fi

echo "ci_post_clone: setting CURRENT_PROJECT_VERSION to $CI_BUILD_NUMBER in $PBXPROJ"

# Replace every `CURRENT_PROJECT_VERSION = <digits>;` with the CI build number.
# BSD sed on macOS requires an argument to -i; use an empty string for in-place.
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;/g" "$PBXPROJ"

echo "ci_post_clone: updated occurrences:"
grep -c "CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;" "$PBXPROJ" || true
