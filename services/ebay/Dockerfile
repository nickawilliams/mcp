# TEMPORARY: tracking an unreleased fork branch, not a published npm release.
#
# The service normally installs ebay-mcp from npm (see the git history for the
# one-line form, and restore it once the branch lands upstream). It currently
# runs a build of nickawilliams/fork-ebay-mcp@feat/browse-item-search, which adds
# Buy Browse active-listing search — the upstream package is Sell-only, so
# there is no marketplace search without it.
#
# The image is built and pushed off-box by `make publish/ebay-mcp` (the host
# has ~600 MB free and no swap; a tsc pass over that project would OOM it), and
# pinned here by digest. Rebuild + re-pin after every push to the branch —
# unlike an npm version bump, the tag is mutable upstream of this pin.
FROM ghcr.io/nickawilliams/ebay-mcp:1.15.0-browse.5@sha256:294999554bae5a1ab51ee1fab2faac74fb6080346d8453bf270399f00f094ec8
