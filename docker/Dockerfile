# Foundation image for the autonomous Godot C# dev agent.
# The slow, confident base: system libs + .NET SDK + Godot mono + uv + Claude + gh.
# Version-sensitive bits (gdUnit4 wiring, the godot_ai MCP plugin, the game project,
# and the pre-built import cache) are baked in a later finalize step, AFTER they are
# validated interactively against a bind-mount (see plan_implementation.md, Phase 1).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# --- System tooling: virtual display, SOFTWARE rendering, capture, utils ---
# (Software GL via Mesa llvmpipe is the proven prototype path; VNC is descoped.)
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11-utils \
      libgl1-mesa-dri mesa-utils libglu1-mesa \
      libvulkan1 mesa-vulkan-drivers vulkan-tools \
      ffmpeg \
      curl ca-certificates gnupg git unzip xz-utils iproute2 \
      fontconfig libfontconfig1 \
      libxcursor1 libxinerama1 libxrandr2 libxi6 libxkbcommon0 libasound2t64 \
    && rm -rf /var/lib/apt/lists/*

# --- .NET SDK 8 (Ubuntu 24.04 ships it via Canonical's feed) ---
RUN apt-get update && apt-get install -y --no-install-recommends dotnet-sdk-8.0 \
    && rm -rf /var/lib/apt/lists/*
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

# --- Godot 4.6.3 .NET (mono) build — extracts to a FOLDER (binary + GodotSharp/) ---
ARG GODOT_VERSION=4.6.3-stable
RUN curl -fsSL -o /tmp/godot.zip \
      "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_mono_linux_x86_64.zip" \
    && unzip -q /tmp/godot.zip -d /opt \
    && mv "/opt/Godot_v${GODOT_VERSION}_mono_linux_x86_64" /opt/godot \
    && ln -s "/opt/godot/Godot_v${GODOT_VERSION}_mono_linux.x86_64" /usr/local/bin/godot \
    && rm /tmp/godot.zip

# --- uv (the godot_ai MCP Python server is fetched via uvx; pre-warm later to kill egress) ---
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# --- yq (mikefarah) — parses the committed .igloo.yml; scripts/lib/config.sh resolves it here ---
ARG YQ_VERSION=v4.44.6
RUN curl -fsSL -o /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    && chmod +x /usr/local/bin/yq

# --- Claude Code CLI (auth injected at runtime via CLAUDE_CODE_OAUTH_TOKEN, never baked) ---
RUN curl -fsSL https://claude.ai/install.sh | bash

# --- gh CLI (GitHub state operations) ---
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /project
ENV DISPLAY=:99
# Prototype gotcha: root + Claude `--dangerously-skip-permissions` requires IS_SANDBOX=1.
# Safe here — the container IS the (ephemeral, --rm) sandbox. Secrets are still injected
# at runtime via `docker run -e`, never baked.
ENV IS_SANDBOX=1
CMD ["/bin/bash"]
