# supergateway (stdio -> streamable-HTTP bridge) + the mail-mcp stdio binary.
# Upstream publishes no linux/arm64 artifact, so the binary comes from our
# own GHCR build of the pinned upstream tag (make publish/mail-mcp). Both
# images pinned; bump via the FROM lines only.
FROM ghcr.io/nickawilliams/mail-mcp:v0.4.9 AS mail

FROM supercorp/supergateway:3.4.3
COPY --from=mail /mail-imap-mcp-rs /usr/local/bin/mail-imap-mcp-rs
