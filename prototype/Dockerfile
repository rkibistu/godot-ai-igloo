# Feasibility prototype image — Godot editor + hi-godot MCP in a GPU-less container.
# See plan_prototype.md. Everything system-level is assembled here; the guinea-pig
# project SOURCE is committed in ./project and COPY'd in. Third-party addons (GUT,
# godot_ai) are fetched + pinned at build time, not committed.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# --- System tooling: virtual display, SOFTWARE rendering, vnc, capture, utils ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc x11-utils \
      libgl1-mesa-dri mesa-utils libglu1-mesa \
      libvulkan1 mesa-vulkan-drivers vulkan-tools \
      ffmpeg imagemagick \
      curl ca-certificates git unzip xz-utils \
      fontconfig libfontconfig1 \
      libxcursor1 libxinerama1 libxrandr2 libxi6 libxkbcommon0 libasound2t64 \
    && rm -rf /var/lib/apt/lists/*

# --- Godot 4.6.3 (standard / GDScript build, not .NET) ---
ARG GODOT_VERSION=4.6.3-stable
RUN curl -fsSL -o /tmp/godot.zip \
      "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" \
    && unzip -q /tmp/godot.zip -d /tmp \
    && mv "/tmp/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm /tmp/godot.zip

# --- Vendored addons, pinned (fetched before project COPY for layer caching) ---
RUN mkdir -p /project/addons
# GUT (Godot Unit Test) 9.3.1 — Phase 5 done-gate
RUN git clone --depth 1 --branch 9.3.1 https://github.com/bitwes/Gut.git /tmp/gut \
    && cp -r /tmp/gut/addons/gut /project/addons/gut \
    && rm -rf /tmp/gut
# hi-godot/godot-ai v2.7.5 — the MCP plugin under test (addon at plugin/addons/godot_ai)
RUN git clone --depth 1 --branch v2.7.5 https://github.com/hi-godot/godot-ai.git /tmp/godotai \
    && cp -r /tmp/godotai/plugin/addons/godot_ai /project/addons/godot_ai \
    && rm -rf /tmp/godotai

# --- uv (the godot_ai Python MCP server is pulled via uvx at runtime, Phase 3) ---
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# --- Guinea-pig project source (committed) merges on top of the vendored addons ---
COPY project/ /project/
# --- In-container helper scripts ---
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh || true

WORKDIR /project
ENV DISPLAY=:99
CMD ["/bin/bash"]
