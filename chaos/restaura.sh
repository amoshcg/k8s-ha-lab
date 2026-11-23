#!/usr/bin/env bash
# Desfaz as falhas injetadas pela apresentação e volta o laboratório a um estado limpo.
#   chaos/restaura.sh          descongela nós e etcd
#   chaos/restaura.sh --app    idem + reaplica k8s/ (aplicação volta para v1 com probes)
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

info "descongelando nós"
for n in $(all_nodes); do node_paused "$n" && run docker unpause "$n"; done

info "descongelando o etcd"
for n in $(cp_nodes); do
  pids=$(comp_pids "$n" etcd | tr '\n' ' ')
  [[ -n "${pids// /}" ]] && docker exec "$n" bash -c "kill -CONT $pids" || true
done

info "aguardando a API responder"
for _ in $(seq 1 60); do kubectl get --raw /readyz --request-timeout=2s >/dev/null 2>&1 && break; sleep 2; done
kubectl get --raw /readyz --request-timeout=2s >/dev/null 2>&1 || die "a API não voltou; veja: scripts/status.sh"

if [[ "${1:-}" == "--app" ]]; then
  "$ROOT/scripts/deploy.sh"
fi
mark "laboratório restaurado"
ok "laboratório restaurado"
