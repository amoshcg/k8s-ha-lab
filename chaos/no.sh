#!/usr/bin/env bash
# Falha no nível do NÓ.
#
#   chaos/no.sh pause   <nó>   congela o nó inteiro (kubelet, contêineres, tudo): equivale
#                              a uma máquina travada ou que sumiu da rede
#   chaos/no.sh unpause <nó>   descongela
#
# Por que não "docker stop"? Ao reiniciar, o contêiner pode ganhar outro IP e
# um cluster kind com vários nós não se recupera disso. "pause" é reversível.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

action=${1:-}
node=${2:-}
[[ -n "$action" && -n "$node" ]] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
require_node "$node"

case "$action" in
  pause)
    if [[ "$node" == "$ENTRY_NODE" && "${FORCE:-0}" != 1 ]]; then
      die "$node é o nó de entrada da sonda (porta 8080). Derrubá-lo mede a queda da entrada, não do cluster. Use FORCE=1 se for isso mesmo."
    fi
    mark "docker pause $node"
    run docker pause "$node"
    ok "$node congelado às $(date +%H:%M:%S). Acompanhe: kubectl get nodes -w"
    ;;
  unpause)
    run docker unpause "$node"
    mark "docker unpause $node"
    ;;
  *) die "ação desconhecida: $action (use pause ou unpause)" ;;
esac
