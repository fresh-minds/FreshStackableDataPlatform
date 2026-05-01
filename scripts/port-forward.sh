#!/usr/bin/env bash
# Start kubectl port-forwards voor service-UI's die NIET via ingress
# gepubliceerd zijn. ingress-nginx services zijn bereikbaar via host:8080/8443.
#
# Achtergrond-processen worden gelogd in /tmp/uwv-pf-*.log; PIDs in
# /tmp/uwv-pf.pids. Stop met:
#   xargs -a /tmp/uwv-pf.pids kill 2>/dev/null
set -euo pipefail

PIDFILE=/tmp/uwv-pf.pids
> "$PIDFILE"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

start() {
  local ns="$1" svc="$2" lp="$3" rp="$4" name="$5"
  if ! kubectl get svc -n "$ns" "$svc" >/dev/null 2>&1; then
    log "Skip $name — service $ns/$svc bestaat (nog) niet"
    return 0
  fi
  log "PF $name → http://127.0.0.1:$lp"
  kubectl port-forward -n "$ns" "svc/$svc" "$lp:$rp" >/tmp/uwv-pf-"$name".log 2>&1 &
  echo $! >> "$PIDFILE"
}

# Naam: ns / svc / local-port / remote-port / label
start uwv-monitoring prometheus-kube-prometheus-prometheus 9090 9090 prometheus
start uwv-platform   minio                                  9000 9000 minio-api

log "Port-forwards gestart. PIDs in $PIDFILE."
log "Stop: xargs -a $PIDFILE kill 2>/dev/null && rm $PIDFILE"
