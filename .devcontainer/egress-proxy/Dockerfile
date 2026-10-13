# The egress proxy that lives next to the dev container: a Squid forward proxy
# that lets HTTPS through by hostname, from the same ~/allowed_domains file the
# firewall reads. See README.md in this directory.
FROM debian:bookworm-slim

# squid-openssl, not squid: reading the hostname out of a TLS handshake
# (ssl_bump peek) needs the build that is linked against OpenSSL.
#   openssl -- the throwaway certificate the peeking port has to be given
#   curl    -- the health check and smoke-test.sh
RUN apt-get update && \
  apt-get install -y --no-install-recommends squid-openssl openssl ca-certificates curl && \
  rm -rf /var/lib/apt/lists/*

COPY baseline_domains /etc/egress-proxy/baseline_domains
COPY gen-allowlist.sh entrypoint.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/gen-allowlist.sh /usr/local/bin/entrypoint.sh

EXPOSE 3128
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 \
  CMD curl -s -o /dev/null --max-time 2 http://127.0.0.1:3128/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
