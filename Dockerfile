# syntax=docker/dockerfile:1.7
###############################################################################
#  CodeContainer                                                              #
#  Ubuntu 26.04 LTS "resolute"                                                #
#                                                                             #
#  A kitchen-sink, single-container agent factory:                            #
#    * T3 Code   -> control surface / web + mobile UI          (port 3773)    #
#    * OpenCode  -> the agent, driven by T3 Code               (port 4096)    #
#    * plus basically every language runtime and dev tool a                    #
#      coding agent is likely to reach for.                                   #
#                                                                             #
#  Design rules:                                                              #
#    - one apt layer, aggressively cleaned (image size is a feature)          #
#    - caches that matter live in volumes, not in the image                   #
#    - no docker socket, no DinD: agents run processes against 30000-30099    #
# =============================================================================
# Build stage: the Go LSP / debug tools.
#
# Go itself is deliberately NOT in the final image - agents get it from mise
# per project. But gopls/dlv/goimports are useful everywhere, so compile them
# once here and copy the binaries across. They go to /usr/local/bin, NOT
# /root/go/bin, because /root/go is a bind mount at runtime and would hide them.
# =============================================================================
FROM ubuntu:26.04 AS gotools
ARG GO_VERSION=latest
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in amd64) GARCH=amd64 ;; arm64) GARCH=arm64 ;; *) exit 1 ;; esac; \
    ver="${GO_VERSION}"; \
    if [ "$ver" = "latest" ]; then ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"; fi; \
    curl -fsSLo /tmp/go.tgz "https://go.dev/dl/${ver}.linux-${GARCH}.tar.gz"; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm -f /tmp/go.tgz; \
    mkdir -p /out; \
    GOBIN=/out /usr/local/go/bin/go install golang.org/x/tools/gopls@latest; \
    GOBIN=/out /usr/local/go/bin/go install golang.org/x/tools/cmd/goimports@latest; \
    GOBIN=/out /usr/local/go/bin/go install github.com/go-delve/delve/cmd/dlv@latest; \
    ls -l /out

###############################################################################
FROM ubuntu:26.04

LABEL org.opencontainers.image.title="CodeContainer" \
      org.opencontainers.image.description="Ubuntu 26.04 kitchen-sink dev environment for T3 Code + OpenCode" \
      org.opencontainers.image.source="https://github.com/ShadyHippo/CodeContainer" \
      org.opencontainers.image.licenses="MIT"

# --- pinnable versions (override with --build-arg) ---------------------------
ARG NODE_MAJOR=24
ARG T3_VERSION=latest
ARG PLAYWRIGHT_BROWSERS="chromium firefox"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC \
    T3_VERSION=${T3_VERSION} \
    HOME=/root \
    TERM=xterm-256color \
    EDITOR=nvim \
    VISUAL=nvim \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PIPX_HOME=/root/.local/pipx \
    PIPX_BIN_DIR=/root/.local/bin \
    NODE_PATH=/usr/local/lib/node_modules:/root/.local/lib/node_modules \
    PIP_REQUIRE_VIRTUALENV=1 \
    GIT_CONFIG_GLOBAL=/root/.config/git/config \
    GOPATH=/root/go \
    MISE_DATA_DIR=/mise \
    MISE_SHIMS_DIR=/mise/shims \
    MISE_YES=1 \
    MISE_TRUSTED_CONFIG_PATHS=/root/Projects:/root \
    BUILDAH_ISOLATION=chroot \
    REGISTRY_AUTH_FILE=/root/.config/containers/auth.json \
    PATH=/root/.local/bin:/mise/shims:/root/go/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# =============================================================================
# 1. System packages  (ONE layer - cleaned in place)
# =============================================================================
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    # --- core + build ---------------------------------------------------------
        ca-certificates curl wget gnupg gpg apt-transport-https \
        locales tzdata tini file less rsync unzip zip xz-utils bzip2 zstd p7zip-full \
        build-essential gcc g++ make cmake ninja-build meson pkg-config \
        autoconf automake libtool m4 gettext \
        clang lld lldb llvm libc++-dev libc++abi-dev \
        gdb valgrind strace ltrace patchelf \
        protobuf-compiler shellcheck shfmt \
    # --- shared libs / headers ------------------------------------------------
        libssl-dev libffi-dev zlib1g-dev libbz2-dev libreadline-dev \
        libsqlite3-dev libncurses-dev liblzma-dev uuid-dev libicu-dev \
    # --- vcs + cli ------------------------------------------------------------
        git git-lfs git-delta gh direnv just \
        jq yq ripgrep fd-find fzf bat tree htop btop ncdu fdupes qrencode \
        tmux screen vim neovim nano zsh starship \
        httpie netcat-openbsd socat dnsutils iputils-ping net-tools \
        iproute2 lsof procps psmisc pv \
    # --- language runtimes (apt-provided) -------------------------------------
        python3 python3-pip python3-venv python3-dev pipx \
        ruby-full \
        php-cli php-mbstring php-xml php-curl php-zip composer \
        lua5.4 luarocks perl \
        erlang elixir \
    # --- databases (agents spin these up as processes, no sidecars) -----------
        postgresql postgresql-client mariadb-server mariadb-client \
        redis-server redis-tools sqlite3 \
    # --- media + docs ---------------------------------------------------------
        imagemagick ffmpeg graphviz pandoc qpdf poppler-utils ghostscript \
        texlive-latex-base texlive-latex-recommended texlive-fonts-recommended \
    # --- GPU video: hardware transcode. /dev/dri is passed in at runtime. ------
        vainfo libva-drm2 intel-media-va-driver-non-free i965-va-driver \
        mesa-libgallium mediainfo mkvtoolnix \
    # --- daemonless image building. No docker socket, ever. Requires the
    #     container to run with security_opt: seccomp=unconfined. -------------
    #     netavark/aardvark-dns are Recommends we would otherwise skip, and
    #     buildah needs them to set up the build container's network.
        buildah netavark aardvark-dns \
    # --- headless browser deps (Playwright) -----------------------------------
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 \
        libpango-1.0-0 libcairo2 libasound2t64 libatspi2.0-0 \
        libx11-xcb1 libxcb-dri3-0 libxtst6 libxss1 libgtk-3-0 \
        fonts-dejavu-core fonts-liberation fonts-noto-color-emoji fonts-noto-cjk \
    # --- inbound SSH, for VS Code Remote-SSH and T3's SSH environments --------
    #     Key-only and opt-in; the entrypoint starts sshd only when a public key
    #     is supplied. Brings openssh-client along as a dependency. Outbound SSH
    #     is still blocked at the host firewall - this is not a way out.
        openssh-server; \
    # --- locale ---------------------------------------------------------------
    sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    update-locale LANG=en_US.UTF-8; \
    # --- normalise a few binary names ----------------------------------------
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -sf /usr/bin/batcat /usr/local/bin/bat; \
    # --- apt non-interactive defaults (agents run apt-get unattended) ---------
    printf 'APT::Get::Assume-Yes "true";\nDpkg::Options { "--force-confdef"; "--force-confold"; };\n' > /etc/apt/apt.conf.d/99-codecontainer; \
    # --- dropbear stays unavailable; openssh is allowed (installed above) ------
    printf 'Package: dropbear dropbear-bin\nPin: release *\nPin-Priority: -1\n' > /etc/apt/preferences.d/99-no-ssh; \
    # --- cleanup ---------------------------------------------------------------
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/apt/*

# =============================================================================
# 2. Node.js + global JS tooling / LSPs
# =============================================================================
ARG NODE_MAJOR
ARG T3_VERSION
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
      amd64) NARCH=x64 ;; \
      arm64) NARCH=arm64 ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    DIST="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"; \
    FILE="$(curl -fsSL "$DIST/" | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+-linux-${NARCH}\.tar\.xz" | head -n1)"; \
    curl -fsSLo /tmp/node.tar.xz "$DIST/$FILE"; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
        --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md; \
    rm -f /tmp/node.tar.xz; \
    node --version; npm --version; \
    npm install -g --no-fund --no-audit \
        "t3@${T3_VERSION}" \
        pnpm@latest yarn@latest \
        typescript@latest tsx@latest \
        eslint@latest prettier@latest \
        typescript-language-server@latest \
        pyright@latest \
        bash-language-server@latest \
        yaml-language-server@latest \
        vscode-langservers-extracted@latest \
        dockerfile-language-server-nodejs@latest \
        @tailwindcss/language-server@latest \
        playwright@latest; \
    npm cache clean --force; \
    rm -rf /root/.npm /tmp/*

# =============================================================================
# 3. Go LSP / debug tools  (compiled in the gotools stage above)
#    Go itself comes from mise, per project.
# =============================================================================
COPY --from=gotools /out/gopls /out/goimports /out/dlv /usr/local/bin/

# =============================================================================
# 4. Rust -> mise. Only rust-analyzer is kept here, so Rust LSP support does not
#    depend on a project having a mise config.
# =============================================================================
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
      amd64) RA=x86_64-unknown-linux-gnu ;; \
      arm64) RA=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/ra.gz \
      "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-${RA}.gz"; \
    gunzip -c /tmp/ra.gz > /usr/local/bin/rust-analyzer; \
    chmod 0755 /usr/local/bin/rust-analyzer; \
    rm -f /tmp/ra.gz; \
    rust-analyzer --version

# =============================================================================
# 5. mise  (owns rust / go / dotnet per project; MISE_DATA_DIR is a bind mount)
# =============================================================================
RUN set -eux; \
    curl -fsSL https://mise.run | sh; \
    install -m 0755 "${HOME}/.local/bin/mise" /usr/local/bin/mise; \
    rm -rf "${HOME}/.local/bin/mise" "${HOME}/.local/share/mise" "${HOME}/.config/mise"; \
    mise --version

# System-wide defaults: what `mise install` populates on first boot. The data dir
# is a bind mount, so this is a TEMPLATE, not the installed toolchain.
COPY config/storage.conf /etc/containers/storage.conf
COPY config/mise.toml /etc/mise/config.toml

# =============================================================================
# 6. Python extras (uv) + Bun + Deno
# =============================================================================
RUN set -eux; \
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh; \
    uv --version; \
    rm -rf /root/.cache/uv

RUN set -eux; \
    export BUN_INSTALL=/usr/local; \
    curl -fsSL https://bun.sh/install | bash; \
    bun --version; \
    rm -rf /root/.bun/install/cache

RUN set -eux; \
    export DENO_INSTALL=/usr/local; \
    curl -fsSL https://deno.land/install.sh | sh -s -- -y; \
    deno --version

# =============================================================================
# 7. Playwright browsers (chromium + firefox) into the image
# =============================================================================
ARG PLAYWRIGHT_BROWSERS
RUN set -eux; \
    mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}"; \
    playwright install ${PLAYWRIGHT_BROWSERS}; \
    chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}"; \
    rm -rf /tmp/*

# =============================================================================
# 8. Typst (prebuilt, for markdown -> pdf without a 4GB TeX install)
# =============================================================================
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
      amd64) TARCH=x86_64-unknown-linux-musl ;; \
      arm64) TARCH=aarch64-unknown-linux-musl ;; \
      *) exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/typst.tar.xz \
        "https://github.com/typst/typst/releases/latest/download/typst-${TARCH}.tar.xz"; \
    tar -xJf /tmp/typst.tar.xz -C /tmp; \
    install -m 0755 /tmp/typst-${TARCH}/typst /usr/local/bin/typst; \
    rm -rf /tmp/typst*; \
    typst --version

# =============================================================================
# 9. OpenCode is deliberately NOT installed here.
#
# T3 Code drives provider CLIs and can only one-click update installs it
# recognises. A mise-managed copy looks "manual" to it - it reports the update
# but cannot perform it - so OpenCode is installed the way T3 expects a provider
# CLI to be: npm-global into ~/.local (a bind mount, and first on PATH above).
#
# The entrypoint fills that install on first boot; after that "Update now" in
# Settings > Providers is the update path, and it survives rebuilds.
#
# Channel is OPENCODE_CHANNEL (default: latest).
# =============================================================================

# =============================================================================
# 10. Shell / git defaults + helper scripts
# =============================================================================
COPY config/gitconfig /etc/gitconfig
COPY config/bashrc /etc/bash.bashrc.d-codecontainer
COPY config/zshrc /etc/zsh/zshrc.d-codecontainer
COPY config/AGENTS.md /etc/codecontainer/AGENTS.md
COPY bin/preview /usr/local/bin/preview
COPY bin/agent-notes /usr/local/bin/agent-notes
COPY bin/freeport /usr/local/bin/freeport
COPY bin/pair /usr/local/bin/pair

RUN set -eux; \
    chmod 0755 /usr/local/bin/preview /usr/local/bin/agent-notes /usr/local/bin/freeport /usr/local/bin/pair; \
    printf '\n[ -f /etc/bash.bashrc.d-codecontainer ] && . /etc/bash.bashrc.d-codecontainer\n' >> /etc/bash.bashrc; \
    printf '\n[ -f /etc/zsh/zshrc.d-codecontainer ] && . /etc/zsh/zshrc.d-codecontainer\n' >> /etc/zsh/zshrc; \
    mkdir -p /root/Projects; \
    git --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# =============================================================================
# 11. Language servers, in their own layers
#
# Deliberately LAST: adding one of these does not invalidate the big apt layer
# or anything after it, so a rebuild only fetches these few MB.
# =============================================================================

# clangd is the one LSP the VS Code extension does not bundle - it looks for the
# binary on PATH. Matches the clang 21 already installed above.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends clangd; \
    clangd --version; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/apt/*

# Lua has no apt package. Official release tarball; the archive has no
# top-level directory, so it unpacks straight into /opt.
ARG LUA_LS_VERSION=3.19.2
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
      amd64) LLS=x64 ;; \
      arm64) LLS=arm64 ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/lua-language-server; \
    curl -fsSL "https://github.com/LuaLS/lua-language-server/releases/download/${LUA_LS_VERSION}/lua-language-server-${LUA_LS_VERSION}-linux-${LLS}.tar.gz" \
      | tar -xz -C /opt/lua-language-server; \
    ln -sf /opt/lua-language-server/bin/lua-language-server /usr/local/bin/lua-language-server; \
    lua-language-server --version

# Runtime-only: agent-installed npm globals land in the persisted ~/.local
# instead of the container's writable layer (image-owned tools stay in /usr/local).
ENV NPM_CONFIG_PREFIX=/root/.local

WORKDIR /root/Projects
# Docker 29 rejects port ranges in the image's ExposedPorts (EXPOSE), even
# though docker run / compose still support publishing them. The preview range
# is published by compose.yaml, so only the fixed service ports belong here.
EXPOSE 3773 4096
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
