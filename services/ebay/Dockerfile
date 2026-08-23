# TEMPORARY: tracking an unreleased fork branch, not a published npm release.
#
# The service normally installs ebay-mcp from npm (see the git history for the
# one-line form, and restore it once the branch lands upstream). It currently
# runs a build of nickawilliams/ebay-mcp@feat/browse-item-search, which adds
# Buy Browse active-listing search — the upstream package is Sell-only, so
# there is no marketplace search without it.
#
# The image is built and pushed off-box by `make publish/ebay-mcp` (the host
# has ~600 MB free and no swap; a tsc pass over that project would OOM it), and
# pinned here by digest. Rebuild + re-pin after every push to the branch —
# unlike an npm version bump, the tag is mutable upstream of this pin.
FROM ghcr.io/nickawilliams/ebay-mcp:1.15.0-browse.3@sha256:56897da88aeccd205d07fe2652b12d9a4f550eb916ad093cf19992100415246e
