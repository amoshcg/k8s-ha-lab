#!/usr/bin/env bash
# Panorama do cluster: nós, componentes do plano de controle, quem é líder de
# quê e onde estão os pods da aplicação. Funciona (em parte) mesmo com a API
# fora do ar, porque o etcd é consultado direto nos nós.
source "$(dirname "$0")/lib.sh"
require_cluster
T="--request-timeout=3s"

step "Nós (contêineres Docker)"
for n in $(all_nodes); do
  st=$(docker inspect -f '{{.State.Status}}' "$n")
  node_paused "$n" && st="${R}PAUSADO${N}"
  printf '  %-26s %-15s %s\n' "$n" "$(node_ip "$n")" "$st"
done

step "Nós (visão do Kubernetes)"
kubectl get nodes $T -o wide 2>/dev/null | cut -c1-110 || warn "API indisponível"

step "Plano de controle (static pods em cada control plane)"
kubectl -n kube-system get pods $T -l tier=control-plane \
  -o custom-columns='POD:.metadata.name,PRONTO:.status.containerStatuses[0].ready,REINÍCIOS:.status.containerStatuses[0].restartCount,NÓ:.spec.nodeName' \
  2>/dev/null || warn "API indisponível"

step "Líderes"
if [[ $(cp_nodes | wc -l) -gt 1 ]]; then
  etcd_table || true
else
  say "  (um único control plane: não há eleição)"
fi
echo
for l in kube-scheduler kube-controller-manager; do
  h=$(lease_holder "$l" || true)
  printf '%-32s %s\n' "Lease $l" "${h:-${R}(indisponível)${N}}"
done

step "Aplicação"
kubectl -n "$NS" get deploy web $T -o wide 2>/dev/null || warn "API indisponível"
echo
kubectl -n "$NS" get pods $T -l app=web \
  -o custom-columns='POD:.metadata.name,STATUS:.status.phase,PRONTO:.status.containerStatuses[0].ready,REINÍCIOS:.status.containerStatuses[0].restartCount,IMAGEM:.spec.containers[0].image,NÓ:.spec.nodeName' \
  2>/dev/null || true
