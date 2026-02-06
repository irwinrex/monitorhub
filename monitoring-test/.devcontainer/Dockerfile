FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    zsh \
    sudo \
    build-essential \
    ripgrep \
    fd-find \
    fzf \
    xz-utils \
    unzip \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

RUN curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
 && tar -C /opt -xzf nvim-linux-x86_64.tar.gz \
 && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim \
 && rm nvim-linux-x86_64.tar.gz

USER dev
ENV HOME=/home/dev
WORKDIR /workspace

RUN uv python install 3.12 \
 && uv python default 3.12

RUN echo 'export EDITOR=nvim' >> ~/.zshrc \
 && echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
