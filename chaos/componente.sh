#!/usr/bin/env bash
# Congela um componente do plano de controle, sem derrubar o nó inteiro.
#
#   chaos/componente.sh freeze   <componente> <nó>   SIGSTOP: o processo trava (não responde,
#                                                    não renova liderança)
#   chaos/componente.sh unfreeze <componente> <nó>   SIGCONT
#
# Componentes: etcd, kube-apiserver, kube-scheduler, kube-controller-manager
# Obs.: os static pods têm livenessProbe; um processo congelado por mais de
# ~1-2 min acaba sendo morto e recriado pelo kubelet.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

action=${1:-}
comp=${2:-}
node=${3:-}
[[ -n "$action" && -n "$comp" && -n "$node" ]] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
comp_comm "$comp" >/dev/null
require_node "$node"

signal_comp() { # sinal
  local pids
  pids=$(comp_pids "$node" "$comp" | tr '\n' ' ')
  [[ -n "${pids// /}" ]] || { warn "$comp não está rodando em $node"; return 0; }
  docker exec "$node" bash -c "kill -$1 $pids"
}

case "$action" in
  freeze)
    mark "freeze $comp em $node"
    signal_comp STOP
    ok "$comp em $node congelado às $(date +%H:%M:%S)"
    ;;
  unfreeze)
    signal_comp CONT
    mark "unfreeze $comp ($node)"
    ok "$comp descongelado ($node)"
    ;;
  *) die "ação desconhecida: $action (use freeze ou unfreeze)" ;;
esac
