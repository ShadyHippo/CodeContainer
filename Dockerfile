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
###############################################################################
FROM ubuntu:26.04

LABEL org.opencontainers.image.title="CodeContainer" \
      org.opencontainers.image.description="Ubuntu 26.04 kitchen-sink dev environment for T3 Code + OpenCode" \
      org.opencontainers.image.source="https://github.com/ShadyHippo/CodeContainer" \
      org.opencontainers.image.licenses="MIT"

# --- pinnable versions (override with --build-arg) ---------------------------
ARG NODE_MAJOR=24
ARG GO_VERSION=latest
ARG GO_TOOLCHAIN=1.26.0
ARG DOTNET_CHANNEL=10.0
ARG RUST_TOOLCHAIN=stable
ARG T3_VERSION=nightly
ARG OPENCODE_VERSION=latest
ARG PLAYWRIGHT_BROWSERS="chromium firefox"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC \
    HOME=/root \
    TERM=xterm-256color \
    EDITOR=nvim \
    VISUAL=nvim \
    DOTNET_ROOT=/usr/local/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PIPX_HOME=/root/.local/pipx \
    PIPX_BIN_DIR=/root/.local/bin \
    NODE_PATH=/usr/local/lib/node_modules:/root/.local/lib/node_modules \
    PIP_REQUIRE_VIRTUALENV=1 \
    CARGO_INSTALL_ROOT=/root/.local \
    GIT_CONFIG_GLOBAL=/root/.config/git/config \
    GOPATH=/root/go \
    GOTOOLCHAIN=auto \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    JAVA_HOME=/usr/lib/jvm/java-21 \
    PATH=/root/.local/bin:/root/go/bin:/usr/local/go/bin:/usr/local/dotnet:/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

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
        openjdk-21-jdk maven gradle \
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
    # --- headless browser deps (Playwright) -----------------------------------
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 \
        libpango-1.0-0 libcairo2 libasound2t64 libatspi2.0-0 \
        libx11-xcb1 libxcb-dri3-0 libxtst6 libxss1 libgtk-3-0 \
        fonts-dejavu-core fonts-liberation fonts-noto-color-emoji fonts-noto-cjk; \
    # --- locale ---------------------------------------------------------------
    sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    update-locale LANG=en_US.UTF-8; \
    # --- normalise a few binary names ----------------------------------------
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -sf /usr/bin/batcat /usr/local/bin/bat; \
    ln -sfn "$(readlink -f /usr/lib/jvm/java-21-openjdk-*)" /usr/lib/jvm/java-21; \
    # --- apt non-interactive defaults (agents run apt-get unattended) ---------
    printf 'APT::Get::Assume-Yes "true";\nDpkg::Options { "--force-confdef"; "--force-confold"; };\n' > /etc/apt/apt.conf.d/99-codecontainer; \
    # --- SSH is deliberately unavailable (no client, no server, no inbound) ----
    printf 'Package: openssh-client openssh-server openssh-sftp-server dropbear dropbear-bin\nPin: release *\nPin-Priority: -1\n' > /etc/apt/preferences.d/99-no-ssh; \
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
# 3. Go  (official toolchain tarball)
# =============================================================================
ARG GO_VERSION
ARG GO_TOOLCHAIN
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in amd64) GARCH=amd64 ;; arm64) GARCH=arm64 ;; *) exit 1 ;; esac; \
    ver="${GO_VERSION}"; \
    if [ "$ver" = "latest" ]; then ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"; fi; \
    curl -fsSLo /tmp/go.tgz "https://go.dev/dl/${ver}.linux-${GARCH}.tar.gz"; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm -f /tmp/go.tgz; \
    go version; \
    go env -w GOTOOLCHAIN="${GO_TOOLCHAIN}+auto"; \
    go install golang.org/x/tools/gopls@latest; \
    go install golang.org/x/tools/cmd/goimports@latest; \
    go install github.com/go-delve/delve/cmd/dlv@latest; \
    go clean -modcache -cache

# =============================================================================
# 4. Rust  (rustup, plus clippy/rustfmt/rust-analyzer)
# =============================================================================
ARG RUST_TOOLCHAIN
RUN set -eux; \
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh; \
    sh /tmp/rustup.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_TOOLCHAIN}"; \
    rm -f /tmp/rustup.sh; \
    rustup component add clippy rustfmt rust-src rust-analyzer llvm-tools; \
    rustc --version; cargo --version; \
    rm -rf "${CARGO_HOME}/registry/cache" "${CARGO_HOME}/git"

# =============================================================================
# 5. .NET
# =============================================================================
ARG DOTNET_CHANNEL
RUN set -eux; \
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; \
    bash /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir /usr/local/dotnet; \
    rm -f /tmp/dotnet-install.sh; \
    dotnet --version

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
# 9. OpenCode (the agent)
# =============================================================================
ARG OPENCODE_VERSION
RUN set -eux; \
    npm install -g --no-fund --no-audit "opencode-ai@${OPENCODE_VERSION}"; \
    npm cache clean --force; \
    rm -rf /root/.npm /tmp/*; \
    command -v opencode; \
    opencode --version

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
    mkdir -p /workspace; \
    git --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# Runtime-only: agent-installed npm globals land in the persisted ~/.local
# instead of the container's writable layer (image-owned tools stay in /usr/local).
ENV NPM_CONFIG_PREFIX=/root/.local

WORKDIR /workspace
EXPOSE 3773 4096 30000-30099
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
