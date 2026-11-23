#!/usr/bin/env bash
# Atualiza a cada segundo: nós, Deployment/ReplicaSets e pods da aplicação.
# (Equivale a "watch kubectl get ...", sem precisar do comando watch.)
source "$(dirname "$0")/lib.sh"
require_cluster
T="--request-timeout=2s"
while true; do
  out=$(
    date '+%H:%M:%S'
    echo
    kubectl get nodes $T 2>&1
    echo
    kubectl -n "$NS" get deploy,rs $T -o wide 2>&1 | cut -c1-150
    echo
    kubectl -n "$NS" get pods $T -o wide 2>&1 | cut -c1-120
  )
  clear
  printf '%s\n' "$out"
  sleep 1
done
