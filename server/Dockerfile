# syntax=docker/dockerfile:1

########################################################################
# Build stage: build the Jennifer interpreter from the AUR (jennifer-git)
# and fetch the standard module library from the same upstream.
########################################################################
FROM archlinux:base-devel AS builder

# Full upgrade + the tools needed to build an AUR package.
RUN pacman -Syu --noconfirm --needed git sudo

# makepkg refuses to run as root; build as an unprivileged user, with passwordless
# sudo so makepkg can sync its build dependencies.
RUN useradd -m build \
    && echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build
USER build
WORKDIR /home/build

# Build the interpreter package from the AUR. --nocheck skips the upstream Go
# test suite (its check() phase), which is not needed to produce the binary and
# does not build cleanly in a minimal container.
RUN git clone --depth 1 https://aur.archlinux.org/jennifer-git.git
RUN cd jennifer-git && makepkg -s --noconfirm --nocheck
RUN mkdir -p /home/build/out && cp /home/build/jennifer-git/*.pkg.tar.* /home/build/out/

# The Jennifer standard module library (web / flatdb / http / semver / ...),
# from the same upstream repo, so the app's bare imports resolve at runtime.
RUN git clone --depth 1 https://github.com/mplx/jennifer-lang.git /home/build/jennifer-lang

########################################################################
# Runtime stage: a minimal Arch image with the interpreter and the app.
########################################################################
FROM archlinux:base AS runtime

# Install the built interpreter package (pacman -U resolves its runtime deps),
# plus curl for the container healthcheck, then shrink the image.
COPY --from=builder /home/build/out/*.pkg.tar.* /tmp/pkgs/
RUN pacman -Syu --noconfirm --needed curl \
    && pacman -U --noconfirm /tmp/pkgs/*.pkg.tar.* \
    && pacman -Scc --noconfirm \
    && rm -rf /tmp/pkgs /var/cache/pacman/pkg/* /var/lib/pacman/sync/*

# The AUR package ships only the interpreter binary (no .j modules), so populate
# its default system module directory with the standard library the app imports
# (web / flatdb / http / semver / ...). Placing them here means bare imports
# resolve with no -I flag and no JENNIFER_SYSMODDIR override.
COPY --from=builder /home/build/jennifer-lang/modules /usr/share/jennifer/modules

# The deck-repository application: its Jennifer sources and seed database.
WORKDIR /app
COPY *.j /app/

ENV JVC_ADDR=":8080" \
    JVC_DB="/var/lib/jvc/decks.json"

# Seed the registry data; the named volume persists edits made with deckadmin.
RUN mkdir -p /var/lib/jvc
COPY decks.json /var/lib/jvc/decks.json
VOLUME ["/var/lib/jvc"]

# Fail the build early if the interpreter is broken.
RUN jennifer version

EXPOSE 8080

# The website resolves the stdlib modules from $JENNIFER_SYSMODDIR and its own
# modules (./store.j, ./apiview.j, ...) from /app.
CMD ["jennifer", "serve", "serve.j"]
