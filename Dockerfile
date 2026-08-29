# Build Docker. ONE image, TWO entrypoints: /bin/nethack (the game server,
# which is also where every LLM call is made — the platform injects the
# anthropic_api_key coworld secret into the GAME pod, not the player pod) and
# /bin/nethack-player (the thin nethack seat registrar). The policy set is
# env-switched inside this same image (PLAYER_PROMPT vs PLAYER_SCRIPTED),
# which is what keeps a champion and a scripted filler byte-identical apart
# from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/nethack
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The committed nim.cfg (if any) pins the author's machine paths; rebuild it
# from THIS image's synced package tree.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/nethack-nimcache \
  --out:nethack \
  src/nethack.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/nethack-player-nimcache \
  --out:nethack-player \
  src/nethack_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/nethack
COPY --from=build /workspace/nethack/nethack /bin/nethack
COPY --from=build /workspace/nethack/nethack-player /bin/nethack-player
COPY --from=build /workspace/nethack/*.json ./
COPY --from=build /workspace/nethack/data ./data
COPY --from=build /workspace/nethack/client ./client

CMD ["/bin/nethack"]
