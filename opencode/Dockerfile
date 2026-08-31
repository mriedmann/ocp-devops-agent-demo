# Portable, ready-to-run opencode environment — bind-mount any directory at
# /workspace (see scripts/run-opencode-container.sh) and it boots straight
# into opencode against it, with no opencode install needed on the host.
#
# opencode's installer always fetches its latest release, so this image
# is only as fresh as the last build — see run-opencode-container.sh's
# --rebuild flag for forcing a refresh.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:${PATH}"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
