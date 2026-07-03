# Ubuntu-based image with Claude Code and the GitHub CLI pre-installed.
#
# Build:  docker build -t claude-code .
# Run:    docker run -it --rm -v "$PWD":/workspace claude-code
#
# On first run, authenticate the tools inside the container:
#   claude          # sign in to Claude Code
#   gh auth login   # sign in to the GitHub CLI
#
# Tip: mount a volume for ~/.claude and ~/.config/gh to persist credentials
# across container rebuilds, e.g.
#   docker run -it --rm \
#     -v "$PWD":/workspace \
#     -v claude-config:/root/.claude \
#     -v gh-config:/root/.config/gh \
#     claude-code

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=22

# Install base tooling, Node.js, and the GitHub CLI.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally via npm.
RUN npm install -g @anthropic-ai/claude-code

# Runs as root.
WORKDIR /workspace

CMD ["bash", "-lc", "claude --version && gh --version && exec bash"]
