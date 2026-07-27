FROM mcr.microsoft.com/devcontainers/python:3.11-bookworm

# Copy and set up firewall script
# The file cannot be called init-firewall.sh if you're using claude code feature as it writes over it
COPY firewall-init.sh /usr/local/bin/

# Overwrite vscode sudoers file to restrict what the vscode user can do
USER root
RUN chmod +x /usr/local/bin/firewall-init.sh && \
  echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/firewall-init.sh" > /etc/sudoers.d/vscode && \
  chmod 0440 /etc/sudoers.d/vscode

ARG KUBECTL_VERSION=v1.33.4
RUN arch="$(dpkg --print-architecture)" && \
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
    -o /usr/local/bin/kubectl && \
  chmod 0755 /usr/local/bin/kubectl && \
  kubectl version --client

USER vscode
