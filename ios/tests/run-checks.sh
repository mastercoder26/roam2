#!/usr/bin/env bash
#
# Runs every standalone Swift check in ios/tests/.
#
# The checks are plain `swiftc`-compiled executables, not an XCTest bundle, so
# they run without Xcode, a simulator, or a scheme. Each one compiles the app's
# pure engine sources together with a single check file and exits non-zero on
# the first failed assertion.
#
# Every check is compiled against the SAME source set. Per-check source lists
# were the previous approach and they rotted: a check would silently stop
# compiling when an engine gained a dependency, and a missing source read as a
# broken test rather than a stale runner.
#
# Usage:
#   ios/tests/run-checks.sh              # run all checks
#   ios/tests/run-checks.sh Theme Drive  # run checks whose name matches a filter

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Xcode command line tools." >&2
    exit 1
fi

# Engine and model sources. These are deliberately free of UIKit, ActivityKit
# and WidgetKit so they compile for the host platform.
#
# DriveActivityAttributes.swift is excluded: it imports ActivityKit/WidgetKit
# and has no logic under test.
sources=()
while IFS= read -r file; do
    sources+=("$file")
done < <(find ios/Roam/Models -name '*.swift' ! -name 'DriveActivityAttributes.swift' | sort)

# Non-Models sources the checks depend on. Anything reachable from a check must
# be listed here rather than in a per-check list.
# Only UIKit-free files from Utilities/ — DesignSystem.swift imports UIKit and
# is not under test here.
sources+=(
    ios/Roam/Utilities/LayoutResponsiveness.swift
    ios/Roam/Features/Profile/DriverProfile.swift
    ios/Roam/Features/Home/RoutePlanningFormModel.swift
    ios/Roam/Services/APIClient.swift
    ios/Roam/Services/ClerkBackendClient.swift
    ios/Roam/Services/AuthSessionStore.swift
    ios/Roam/Services/DriveHistorySyncService.swift
    ios/Roam/Services/SharedRouteImportCoordinator.swift
)

for source in "${sources[@]}"; do
    if [[ ! -f "$source" ]]; then
        echo "Missing source: $source" >&2
        echo "The runner's source list is stale — fix it here, not in the check." >&2
        exit 1
    fi
done

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"

checks=()
while IFS= read -r file; do
    name="$(basename "$file" .swift)"
    if [[ $# -gt 0 ]]; then
        matched=false
        for filter in "$@"; do
            if [[ "$name" == *"$filter"* ]]; then
                matched=true
                break
            fi
        done
        [[ "$matched" == true ]] || continue
    fi
    checks+=("$file")
done < <(find ios/tests -name '*Checks.swift' | sort)

if [[ ${#checks[@]} -eq 0 ]]; then
    echo "No checks matched." >&2
    exit 1
fi

passed=0
failed_names=()

for check in "${checks[@]}"; do
    name="$(basename "$check" .swift)"
    binary="$build_dir/$name"
    compile_log="$build_dir/$name.compile.log"

    if ! swiftc "${sources[@]}" "$check" -o "$binary" >"$compile_log" 2>&1; then
        echo "FAIL (compile) $name"
        grep -E 'error:' "$compile_log" | head -5 | sed 's/^/    /'
        failed_names+=("$name (compile)")
        continue
    fi

    run_log="$build_dir/$name.run.log"
    if "$binary" >"$run_log" 2>&1; then
        echo "pass  $name"
        passed=$((passed + 1))
    else
        echo "FAIL (run)     $name"
        tail -10 "$run_log" | sed 's/^/    /'
        failed_names+=("$name")
    fi
done

echo
echo "$passed of ${#checks[@]} checks passed."

if [[ ${#failed_names[@]} -gt 0 ]]; then
    echo "Failed:"
    for name in "${failed_names[@]}"; do
        echo "  - $name"
    done
    exit 1
fi
