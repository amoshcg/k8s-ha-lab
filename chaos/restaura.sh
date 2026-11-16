#!/usr/bin/env bash
# Desfaz TODAS as falhas injetadas e volta o laboratório a um estado limpo.
#   chaos/restaura.sh          infraestrutura (nós, rede, componentes, taints)
#   chaos/restaura.sh --app    idem + reaplica k8s/ (aplicação volta para v1 com probes)
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

info "descongelando nós"
for n in $(all_nodes); do node_paused "$n" && run docker unpause "$n"; done

info "removendo partições e latências"
for n in $(all_nodes); do
  PROBER_URL=http://127.0.0.1:9 "$ROOT/chaos/no.sh" heal "$n" >/dev/null 2>&1 || true   # sem marcas na sonda
  docker exec "$n" tc qdisc del dev eth0 root 2>/dev/null || true
done

info "restaurando componentes do plano de controle"
for c in etcd kube-apiserver kube-scheduler kube-controller-manager; do
  for n in $(cp_nodes); do
    pids=$(comp_pids "$n" "$c" | tr '\n' ' ')
    [[ -n "${pids// /}" ]] && docker exec "$n" bash -c "kill -CONT $pids" || true
    if docker exec "$n" test -f "/etc/kubernetes/$c.yaml.parado"; then
      run docker exec "$n" mv "/etc/kubernetes/$c.yaml.parado" "/etc/kubernetes/manifests/$c.yaml"
    fi
  done
done

info "aguardando a API responder"
for _ in $(seq 1 60); do kubectl get --raw /readyz --request-timeout=2s >/dev/null 2>&1 && break; sleep 2; done
kubectl get --raw /readyz --request-timeout=2s >/dev/null 2>&1 || die "a API não voltou; veja: scripts/status.sh"

info "removendo cordons, taints e rótulos das demos"
for n in $(worker_nodes); do
  kubectl uncordon "$n" >/dev/null
  kubectl taint node "$n" manutencao- >/dev/null 2>&1 || true
  kubectl label node "$n" disco- >/dev/null 2>&1 || true
done
kubectl -n "$NS" delete pod -l demo=scheduler --ignore-not-found --wait=false >/dev/null

if [[ "${1:-}" == "--app" ]]; then
  "$ROOT/scripts/deploy.sh"
fi
mark "laboratório restaurado"
ok "laboratório restaurado"
