#!/usr/bin/env bash
# Validation script: proves that this laptop (tag:client) can reach the
# "web" container (tag:server) over the tailnet, and captures evidence
# for the take-home submission.

# Prerequisites before running:
#   - docker compose up -d   (starts the "web" node)
#   - laptop is tagged tag:client in the Tailscale admin console
#   - policy.hujson has been applied to tailnet's ACLs

set -euo pipefail

OUT_DIR="./validation-output"
mkdir -p "$OUT_DIR"

echo "== tailscale status (from this laptop) =="
tailscale status | tee "$OUT_DIR/tailscale-status.txt"

echo
echo "== resolving web via MagicDNS from this laptop =="
tailscale ip -4 web | tee "$OUT_DIR/web-magicdns-ip.txt"

echo
echo "== curl from this laptop -> web over the tailnet =="
curl -sS -m 5 http://web.tail3815aa.ts.net/ | tee "$OUT_DIR/curl-output.html" \
  || curl -sS -m 5 "http://$(cat "$OUT_DIR/web-magicdns-ip.txt")/" | tee "$OUT_DIR/curl-output.html"

echo
echo "Validation evidence saved to $OUT_DIR/"
