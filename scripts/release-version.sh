#!/usr/bin/env bash
#
# Derive the build's version numbers from a git tag (release automation).
#
# Apple rejects a prerelease suffix in CFBundleShortVersionString — it must be one
# to three dot-separated integers — so a tag like `v1.2.0-rc.1` has to be split:
# the numeric core stamps the bundles, while the full tag names the release and the
# artifact. That split is the whole reason this is a script with tests rather than a
# `${GITHUB_REF#refs/tags/}` expression inlined in the workflow.
#
# Usage:
#   release-version.sh v1.2.0        # KEY=value lines on stdout
#   release-version.sh --self-test   # assert the table below
#
# Output keys (consumed via >> "$GITHUB_OUTPUT"):
#   marketing_version  the numeric core            -> MARKETING_VERSION
#   full_version       the tag without its v       -> release title, artifact name
#   is_prerelease      true|false                  -> gh release --prerelease
#
# A malformed tag is a hard error: emitting nothing would leave MARKETING_VERSION
# empty and silently ship a bundle claiming version "" rather than failing the run.

set -euo pipefail

# Three dot-separated integers, optionally followed by a prerelease suffix of
# dot-separated alphanumerics (`-rc.1`, `-beta.2`). Anchored, so `v1.2.0.4` and
# a bare `1.2.0` are both rejected rather than partially matched.
readonly TAG_PATTERN='^v([0-9]+\.[0-9]+\.[0-9]+)(-([0-9A-Za-z]+(\.[0-9A-Za-z]+)*))?$'

# Prints the three KEY=value lines for $1, or fails with a usable message.
derive_version() {
    local tag="${1-}"

    if [[ -z "$tag" ]]; then
        echo "release-version: no tag given" >&2
        return 1
    fi

    if [[ ! "$tag" =~ $TAG_PATTERN ]]; then
        echo "release-version: '$tag' is not a release tag." >&2
        echo "  Expected vMAJOR.MINOR.PATCH with an optional prerelease suffix," >&2
        echo "  e.g. v1.2.0 or v1.2.0-rc.1." >&2
        return 1
    fi

    local marketing="${BASH_REMATCH[1]}"
    local suffix="${BASH_REMATCH[3]-}"

    echo "marketing_version=$marketing"
    echo "full_version=${tag#v}"
    # A suffix is what distinguishes a release candidate from a release; GitHub's
    # own prerelease flag is set from exactly this.
    if [[ -n "$suffix" ]]; then
        echo "is_prerelease=true"
    else
        echo "is_prerelease=false"
    fi
}

# --- self-test ---------------------------------------------------------------

# Reads one key out of derive_version's output.
value_of() {
    local key="$1" output="$2"
    grep "^${key}=" <<<"$output" | cut -d= -f2-
}

self_test() {
    local failures=0

    # Accepted: tag -> marketing_version|full_version|is_prerelease
    local -a accepted=(
        "v1.2.0|1.2.0|1.2.0|false"
        "v0.0.1|0.0.1|0.0.1|false"
        "v10.20.30|10.20.30|10.20.30|false"
        # The numeric core is what reaches the bundles; the suffix only survives in
        # full_version, because Apple would reject it in CFBundleShortVersionString.
        "v1.2.0-rc.1|1.2.0|1.2.0-rc.1|true"
        "v0.9.0-beta.2|0.9.0|0.9.0-beta.2|true"
        "v1.0.0-alpha|1.0.0|1.0.0-alpha|true"
    )

    local case_ tag want_marketing want_full want_pre output got want key
    for case_ in "${accepted[@]}"; do
        IFS='|' read -r tag want_marketing want_full want_pre <<<"$case_"

        if ! output="$(derive_version "$tag" 2>&1)"; then
            echo "FAIL $tag: rejected, expected acceptance — $output" >&2
            failures=$((failures + 1))
            continue
        fi

        for key in marketing_version full_version is_prerelease; do
            case "$key" in
                marketing_version) want="$want_marketing" ;;
                full_version)      want="$want_full" ;;
                is_prerelease)     want="$want_pre" ;;
            esac
            got="$(value_of "$key" "$output")"
            if [[ "$got" != "$want" ]]; then
                echo "FAIL $tag: $key was '$got', expected '$want'" >&2
                failures=$((failures + 1))
            fi
        done
    done

    # Rejected. Each of these would otherwise stamp a bundle with a wrong or empty
    # version, so the script must exit non-zero rather than emit a partial result.
    local -a rejected=(
        "1.2.0"          # no v prefix — not a release tag by our convention
        "v1.2"           # CFBundleShortVersionString needs three components here
        "v1.2.0.4"       # four components: not semver
        "v1.2.0-"        # empty suffix
        "v1.2.0-rc 1"    # whitespace
        "vX.Y.Z"         # non-numeric
        "release-1.2.0"  # arbitrary tag that happens to contain a version
        ""               # no argument at all
    )

    for tag in "${rejected[@]}"; do
        if output="$(derive_version "$tag" 2>&1)"; then
            echo "FAIL '$tag': accepted, expected rejection — $output" >&2
            failures=$((failures + 1))
        fi
    done

    if (( failures > 0 )); then
        echo "release-version self-test: $failures failure(s)" >&2
        return 1
    fi

    echo "release-version self-test: ${#accepted[@]} accepted + ${#rejected[@]} rejected cases pass"
}

# --- entry point -------------------------------------------------------------

case "${1-}" in
    --self-test) self_test ;;
    *)           derive_version "${1-}" ;;
esac
