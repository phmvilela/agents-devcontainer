FROM mcr.microsoft.com/devcontainers/python:3.11-bookworm

# Copy and set up firewall + host-LAN-access (WSL loopback workaround) scripts
# The file cannot be called init-firewall.sh if you're using claude code feature as it writes over it
COPY firewall-init.sh /usr/local/bin/
COPY host-lan-access-init.sh /usr/local/bin/

USER root

# Firewall tooling required by firewall-init.sh. These used to arrive with the
# ghcr.io/anthropics/devcontainer-features/claude-code feature; since Claude
# Code is now installed directly below (to pin its version), they have to be
# installed explicitly or post-start fails with "iptables: command not found".
#   iptables  -- iptables / iptables-save
#   ipset     -- the allowed-domains set
#   dnsutils  -- dig, to resolve /etc/allowed_domains
#   aggregate -- collapses the GitHub meta CIDR list
RUN apt-get update && \
  apt-get install -y --no-install-recommends iptables ipset dnsutils aggregate && \
  rm -rf /var/lib/apt/lists/*

# Overwrite vscode sudoers file to restrict what the vscode user can do
RUN chmod +x /usr/local/bin/firewall-init.sh /usr/local/bin/host-lan-access-init.sh && \
  { \
    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/firewall-init.sh"; \
    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/host-lan-access-init.sh"; \
    echo 'Defaults!/usr/local/bin/host-lan-access-init.sh env_keep += "HOST_LAN_IP"'; \
  } > /etc/sudoers.d/vscode && \
  chmod 0440 /etc/sudoers.d/vscode

ARG KUBECTL_VERSION=v1.33.4
RUN arch="$(dpkg --print-architecture)" && \
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
    -o /usr/local/bin/kubectl && \
  chmod 0755 /usr/local/bin/kubectl && \
  kubectl version --client

# Install Node.js (LTS) and pin Claude Code to a specific version. Done here
# instead of via the claude-code devcontainer feature because that feature
# exposes no `version` option and always installs an unpinned latest, so it
# cannot pin a version. The VS Code extension is still added via
# devcontainer.json customizations.
#
# NODE_MAJOR must stay >= 22: @anthropic-ai/claude-code declares
# "engines": { "node": ">=22.0.0" }, and on Node 20 the install only warns
# (npm EBADENGINE) instead of failing, leaving an unsupported runtime.
ARG NODE_MAJOR=22
ARG CLAUDE_CODE_VERSION=2.1.273
RUN apt-get update && apt-get install -y ca-certificates curl gnupg && \
  install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
  chmod a+r /etc/apt/keyrings/nodesource.gpg && \
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
  apt-get update && apt-get install -y nodejs && \
  rm -rf /var/lib/apt/lists/* && \
  npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && \
  claude --version


USER vscode
