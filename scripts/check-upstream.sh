#!/usr/bin/env bash
# Compare every version the Dockerfile pins with the latest upstream release.
#
# The base image is `FROM httpd:${HTTPD_VERSION}-${DEBIAN_RELEASE}`, a tag
# built from ARGs, which Dependabot cannot resolve or move. This script reads
# both ARGs and checks them against upstream:
#
#   HTTPD_VERSION   the newest 2.4.x tag of the official `httpd` image on
#                   Docker Hub, and the newest release httpd.apache.org announces
#   DEBIAN_RELEASE  the Debian release the official image's `latest` is built on
#
# It exits 1 listing every pin that is behind. Nothing else in the image is
# pinned: curl and acl are Debian's current packages.
#
# Usage: scripts/check-upstream.sh [path/to/Dockerfile]
# Needs bash, curl and jq.

set -euo pipefail

DOCKERFILE="${1:-Dockerfile}"
behind=()
failed=()

arg() {
    local value
    value="$(sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -n1)"
    [ -n "$value" ] || { echo "ARG $1 not found in $DOCKERFILE" >&2; exit 2; }
    printf '%s' "$value"
}

fetch() { curl -fsSL --retry 3 --max-time 60 "$@"; }

hub_digest() {
    fetch "https://hub.docker.com/v2/namespaces/library/repositories/httpd/tags/$1" | jq -r '.digest // empty'
}

# compare NAME PINNED LATEST: record NAME as behind when LATEST sorts after PINNED.
compare() {
    local name="$1" pinned="$2" latest="$3"
    if [ -z "$latest" ]; then
        failed+=("$name: could not read the latest upstream version")
    elif [ "$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -n1)" != "$pinned" ]; then
        behind+=("$name: pinned $pinned, latest $latest")
    fi
    printf '%-34s pinned %-10s latest %s\n' "$name" "$pinned" "${latest:-?}"
}

httpd_pinned="$(arg HTTPD_VERSION)"
debian="$(arg DEBIAN_RELEASE)"

# The official image's version tags, newest first by version.
hub_latest="$(fetch 'https://hub.docker.com/v2/namespaces/library/repositories/httpd/tags?page_size=100&ordering=last_updated&name=2.4.' \
    | jq -r '.results[].name' | grep -E '^2\.4\.[0-9]+$' | sort -V | tail -n1 || true)"
compare "httpd (Docker Hub library/httpd)" "$httpd_pinned" "$hub_latest"

# The release the Apache HTTP Server project itself announces. It can be ahead
# of Docker Hub for a few days; that is still worth knowing about.
site_latest="$(fetch https://httpd.apache.org/ \
    | grep -oE 'Apache httpd 2\.4\.[0-9]+ Released' | grep -oE '2\.4\.[0-9]+' | sort -V | tail -n1 || true)"
compare "httpd (httpd.apache.org)" "$httpd_pinned" "$site_latest"

# The Debian release: `httpd:latest` and `httpd:<release>` are the same image
# while the pinned release is the one upstream builds on.
latest_digest="$(hub_digest latest || true)"
release_digest="$(hub_digest "$debian" || true)"
printf '%-34s pinned %-10s %s\n' "Debian release" "$debian" \
    "$([ -n "$latest_digest" ] && [ "$latest_digest" = "$release_digest" ] && echo "httpd:latest is httpd:${debian}" || echo "httpd:latest differs")"
if [ -z "$latest_digest" ] || [ -z "$release_digest" ]; then
    failed+=("Debian release: could not read httpd:latest and httpd:${debian} from Docker Hub")
elif [ "$latest_digest" != "$release_digest" ]; then
    behind+=("Debian release: httpd:latest is no longer httpd:${debian}")
fi

# The base image this Dockerfile names must exist.
if [ -z "$(hub_digest "${httpd_pinned}-${debian}" || true)" ]; then
    failed+=("the base image httpd:${httpd_pinned}-${debian} was not found on Docker Hub")
fi

echo
if [ "${#failed[@]}" -gt 0 ]; then
    echo "Could not check:"
    printf '  %s\n' "${failed[@]}"
fi
if [ "${#behind[@]}" -gt 0 ]; then
    echo "Behind upstream:"
    printf '  %s\n' "${behind[@]}"
fi
if [ "${#failed[@]}" -gt 0 ] || [ "${#behind[@]}" -gt 0 ]; then
    exit 1
fi
echo "Every pin is at the latest upstream release."
