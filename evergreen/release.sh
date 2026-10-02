#!/bin/sh
# Release the version in evergreen/VERSION:
#   build the .kpkg on top of the published KPM repository (gh-pages, so earlier
#   versions stay available), push gh-pages, and tag the source.
#
#   evergreen/release.sh
set -e
cd "$(dirname "$0")/.."
VERSION=$(cat evergreen/VERSION)
TAG="evergreen-v${VERSION}"

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree not clean; commit first." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "${TAG} already exists; bump evergreen/VERSION." >&2
    exit 1
fi

git fetch -q origin gh-pages
rm -rf evergreen/dist
mkdir -p evergreen/dist
git worktree prune
git worktree add -q --detach evergreen/dist/repo origin/gh-pages

python3 evergreen/build.py

(
    cd evergreen/dist/repo
    git add -A
    git commit -q -m "Evergreen ${VERSION}"
    git push -q origin HEAD:gh-pages
)
git worktree remove --force evergreen/dist/repo

git tag -a "${TAG}" -m "Evergreen ${VERSION}"
git push -q origin "${TAG}"
echo "released ${TAG}: https://nolanvo5894.github.io/evergreen/manifest.v2.json"
