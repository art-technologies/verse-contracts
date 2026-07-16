# bookworm variant: the default node:16-slim is Debian buster, which is EOL
# and gone from deb.debian.org (apt-get 404s)
FROM node:16-bookworm-slim

# git: some transitive deps are fetched from git URLs
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# completium-cli 0.4.x (the version this contract was deployed with) relies on
# undeclared transitive deps (glob, bn.js) and loose ranges, so resolve the
# dependency tree as it existed at the time (npm --before) instead of patching.
RUN npm install -g --before=2023-03-01 @completium/completium-cli@0.4.74 \
    && completium-cli init

WORKDIR /contracts

CMD ["bash"]
