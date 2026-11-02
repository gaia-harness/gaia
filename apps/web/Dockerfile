# Build from the repo root so the root lockfile and supply-chain settings apply:
#   docker build -f apps/web/Dockerfile .
# BuildKit reads apps/web/Dockerfile.dockerignore beside this file, which keeps
# every .env out of the context.

# The exact pnpm that package.json's packageManager pins, installed with npm at build time, so a
# container start needs no registry. The pin's sha512 is the hash of pnpm's npm tarball, so the
# tarball is checked against it before the install.
FROM node:22.23-alpine AS pnpm-env
WORKDIR /pin
COPY package.json ./
RUN pin="$(node -p "require('./package.json').packageManager")" \
  && case "$pin" in pnpm@*+sha512.*) ;; *) echo "packageManager must read pnpm@<version>+sha512.<hash>, not $pin" >&2; exit 1 ;; esac \
  && version="${pin#pnpm@}" && version="${version%%+*}" \
  && npm pack --silent "pnpm@$version" \
  && echo "${pin##*+sha512.}  pnpm-$version.tgz" | sha512sum -c - \
  && npm install -g "./pnpm-$version.tgz" \
  && rm "pnpm-$version.tgz" \
  && pnpm --version

FROM pnpm-env AS build-env
WORKDIR /repo
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY apps/web/package.json ./apps/web/package.json
# Filtered to the web package: the source repo's lockfile also names the maintainer CLI importer,
# whose manifest this image does not copy, and adopter trees carry no such importer.
RUN pnpm install --frozen-lockfile --filter web
COPY apps/web ./apps/web
RUN pnpm --filter web build
RUN pnpm deploy --filter web --prod /app

FROM pnpm-env
# Container hardening: the server runs as the unprivileged `node` user.
RUN mkdir /app && chown node:node /app
USER node
WORKDIR /app
# Deployed at /app in the build stage so pnpm's recorded install state still matches this path;
# otherwise `pnpm start` sees a stale install and reaches for the registry.
COPY --from=build-env --chown=node:node /app/package.json /app/pnpm-lock.yaml /app/pnpm-workspace.yaml ./
COPY --from=build-env --chown=node:node /app/node_modules ./node_modules
COPY --from=build-env --chown=node:node /repo/apps/web/build ./build
# The install was verified at build time; never reinstall at start.
ENV pnpm_config_verify_deps_before_run=false
CMD ["pnpm", "start"]
