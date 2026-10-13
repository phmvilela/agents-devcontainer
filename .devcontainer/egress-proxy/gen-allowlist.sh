#!/bin/sh
#
# gen-allowlist.sh FILE... -- turn allowed_domains files into a Squid
# dstdomain list on stdout; what was left out, and why, goes to stderr.
#
# Syntax of a line, shared with firewall-init.sh:
#   name.example.com     that host, and only that host
#   .example.com         the domain and every host under it (also *.example.com)
#   10.1.2.0/24          an address range: the firewall's business, skipped here
#   direct:db.example    a host reached without the proxy (Postgres, SSH): the
#                        firewall resolves it, skipped here
#   # ...                a comment; blank lines are fine
#
# Squid refuses to start on a list where one entry covers another, so a name
# that a wider entry already covers is dropped.
set -eu

cat "$@" | tr -d '\r' | awk '
{
    sub(/#.*/, ""); gsub(/[ \t]/, "")
    line = tolower($0)
    if (line == "") next
    if (line ~ /^[0-9]+(\.[0-9]+)+(\/[0-9]+)?$/) next
    if (line ~ /^direct:/ || line == "host.docker.internal") next
    sub(/^\*\./, ".", line)
    if (line !~ /^\.?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/) {
        print "egress-proxy: not a hostname, skipped: " $0 > "/dev/stderr"
        next
    }
    if (!(line in seen)) { seen[line] = 1; order[++n] = line }
}
END {
    for (i = 1; i <= n; i++) {
        entry = order[i]; name = entry; sub(/^\./, "", name)
        covered = 0
        for (j = 1; j <= n && !covered; j++) {
            wide = order[j]
            if (wide == entry || substr(wide, 1, 1) != ".") continue
            base = substr(wide, 2)
            tail = "." base
            if (name == base || (length(name) > length(tail) &&
                substr(name, length(name) - length(tail) + 1) == tail)) covered = 1
        }
        if (covered) print "egress-proxy: covered by a wider entry, dropped: " entry > "/dev/stderr"
        else print entry
    }
}'
