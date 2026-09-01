# supergateway (stdio -> streamable-HTTP bridge) + the mail-mcp stdio binary.
# Upstream publishes no linux/arm64 artifact, so the binary comes from our
# own GHCR build of the pinned upstream tag (make publish/mail-mcp). Both
# images pinned; bump via the FROM lines only.
FROM ghcr.io/nickawilliams/mail-mcp:v0.4.10@sha256:fc7f0be2c6b2febc1830134f065081cd3ffcd8f74694b8a47145026e522a4456 AS mail

FROM supercorp/supergateway:3.4.3
COPY --from=mail /mail-imap-mcp-rs /usr/local/bin/mail-imap-mcp-rs

# The bridge runs stateless (see compose.yaml), which upstream ships with a
# per-request child-process leak. patch-supergateway.js fixes it at build
# time and fails the build if the upstream anchor moves, so an unpatched
# image cannot ship silently. Remove both lines once fixed upstream.
COPY patch-supergateway.js /tmp/patch-supergateway.js
RUN node /tmp/patch-supergateway.js && rm /tmp/patch-supergateway.js
