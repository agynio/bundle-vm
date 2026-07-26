#!/usr/bin/env bash
set -euo pipefail

# Places the bootstrap-token script where the host can invoke it on first boot.
# It is deliberately not run here: at build time there is no per-install token,
# and baking one would put the same credential in every copy of the image.

install -D -m 0755 /tmp/set-bootstrap-token.sh /opt/agyn/set-bootstrap-token.sh
printf '[install-bootstrap-token-hook] installed /opt/agyn/set-bootstrap-token.sh\n'
