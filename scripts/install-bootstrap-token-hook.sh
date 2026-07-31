#!/usr/bin/env bash
set -euo pipefail

# Places the scripts the host invokes against a running VM under /opt/agyn.
#
# None of them can run at build time. Two carry a value the image cannot know:
# the bootstrap token must differ per install (baking one would put the same
# credential in every copy of the image), and the ingress port is whatever the
# user had free. The third upgrades the platform releases long after the image
# was built, to a chart version that did not exist when it was.

for script in set-bootstrap-token.sh set-ingress-port.sh upgrade-platform.sh; do
	install -D -m 0755 "/tmp/${script}" "/opt/agyn/${script}"
	printf '[install-bootstrap-token-hook] installed /opt/agyn/%s\n' "${script}"
done
