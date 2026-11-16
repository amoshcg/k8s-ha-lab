#!/usr/bin/env bash
# Falhas em UM componente do plano de controle, sem derrubar o nó inteiro.
#
#   chaos/componente.sh freeze   <componente> <alvo>   SIGSTOP: o processo trava (não responde,
#                                                      não renova liderança); simula travamento
#   chaos/componente.sh unfreeze <componente> <alvo>   SIGCONT
#   chaos/componente.sh kill     <componente> <alvo>   SIGKILL: queda abrupta; o kubelet recria o
#                                                      contêiner do static pod em seguida
#   chaos/componente.sh stop     <componente> <alvo>   parada graciosa: tira o manifesto de
#                                                      /etc/kubernetes/manifests e o kubelet
#                                                      encerra o static pod com SIGTERM
#   chaos/componente.sh start    <componente> <alvo>   devolve o manifesto
#
# Componentes: etcd, kube-apiserver, kube-scheduler, kube-controller-manager
# Alvo: nome de um nó control-plane, "lider" (o líder atual: Raft no etcd, Lease
# no scheduler/controller-manager) ou "todos" (os três control planes).
# Obs.: os static pods têm livenessProbe; um processo congelado por mais de
# ~1-2 min acaba sendo morto e recriado pelo kubelet.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

action=${1:-}
comp=${2:-}
target=${3:-}
[[ -n "$action" && -n "$comp" && -n "$target" ]] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
comp_comm "$comp" >/dev/null

nodes_for() {
  if [[ "$target" == "todos" ]]; then cp_nodes; else resolve_node "$comp" "$target"; fi
}

signal_comp() { # sinal nó
  local pids
  pids=$(comp_pids "$2" "$comp" | tr '\n' ' ')
  [[ -n "${pids// /}" ]] || { warn "$comp não está rodando em $2"; return 0; }
  docker exec "$2" bash -c "kill -$1 $pids"
}

nodes=$(nodes_for)
where=$(echo "$nodes" | tr "\n" " ")

case "$action" in
  freeze | kill)
    sig=STOP; [[ "$action" == kill ]] && sig=KILL
    mark "$action $comp em $where"
    for node in $nodes; do signal_comp "$sig" "$node"; done
    ok "$comp em $where recebeu SIG$sig às $(date +%H:%M:%S)"
    ;;
  unfreeze)
    for node in $nodes; do signal_comp CONT "$node"; done
    mark "unfreeze $comp ($where)"
    ok "$comp descongelado ($where)"
    ;;
  stop)
    mark "stop $comp em $where"
    for node in $nodes; do
      run docker exec "$node" mv "/etc/kubernetes/manifests/$comp.yaml" "/etc/kubernetes/$comp.yaml.parado"
    done
    ok "manifesto removido; o kubelet de $where vai encerrar o static pod $comp"
    ;;
  start)
    for node in $nodes; do
      if docker exec "$node" test -f "/etc/kubernetes/$comp.yaml.parado"; then
        run docker exec "$node" mv "/etc/kubernetes/$comp.yaml.parado" "/etc/kubernetes/manifests/$comp.yaml"
      fi
    done
    mark "start $comp ($target)"
    ok "manifestos de $comp devolvidos ($target)"
    ;;
  *) die "ação desconhecida: $action" ;;
esac
