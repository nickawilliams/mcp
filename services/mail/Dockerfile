# supergateway (stdio -> streamable-HTTP bridge) + the mail-mcp stdio binary.
# Upstream publishes no linux/arm64 artifact, so the binary comes from our
# own GHCR build of the pinned upstream tag (make publish/mail-mcp). Both
# images pinned; bump via the FROM lines only.
FROM ghcr.io/nickawilliams/mail-mcp:v0.4.9@sha256:35867f74795f578023bfcb88b7fdb504366f3f99ec706c18277b286b0fe40061 AS mail

FROM supercorp/supergateway:3.4.3
COPY --from=mail /mail-imap-mcp-rs /usr/local/bin/mail-imap-mcp-rs

# The bridge runs stateless (see compose.yaml), which upstream ships with a
# per-request child-process leak. patch-supergateway.js fixes it at build
# time and fails the build if the upstream anchor moves, so an unpatched
# image cannot ship silently. Remove both lines once fixed upstream.
COPY patch-supergateway.js /tmp/patch-supergateway.js
RUN node /tmp/patch-supergateway.js && rm /tmp/patch-supergateway.js
