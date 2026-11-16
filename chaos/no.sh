#!/usr/bin/env bash
# Falhas no nível do NÓ.
#
#   chaos/no.sh pause     <nó>   congela o nó inteiro (kubelet, contêineres, tudo): equivale
#                                a uma máquina travada ou que sumiu da rede
#   chaos/no.sh unpause   <nó>   descongela
#   chaos/no.sh partition <nó>   isola o nó na rede (iptables), mas ele continua rodando:
#                                os pods seguem vivos do lado de lá da partição
#   chaos/no.sh heal      <nó>   desfaz a partição
#   chaos/no.sh latency   <nó> <atraso_ms> [variação_ms] [perda_%]   (tc netem na saída do nó)
#   chaos/no.sh clear     <nó>   remove latência/perda
#
# Por que não "docker stop"? Ao reiniciar, o contêiner pode ganhar outro IP e
# um cluster kind com vários nós não se recupera disso. "pause" é reversível.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

action=${1:-}
node=${2:-}
[[ -n "$action" && -n "$node" ]] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
require_node "$node"

guard_entry() {
  if [[ "$node" == "$ENTRY_NODE" && "${FORCE:-0}" != 1 ]]; then
    die "$node é o nó de entrada da sonda (porta 8080). Derrubá-lo mede a queda da entrada, não do cluster. Use FORCE=1 se for isso mesmo."
  fi
}

ipt() { docker exec "$node" iptables "$@"; }
TAG=(-m comment --comment k8slab-particao)

case "$action" in
  pause)
    guard_entry
    mark "docker pause $node"
    run docker pause "$node"
    ok "$node congelado às $(date +%H:%M:%S). Acompanhe: kubectl get nodes -w"
    ;;
  unpause)
    run docker unpause "$node"
    mark "docker unpause $node"
    ;;
  partition)
    guard_entry
    mark "partição: $node isolado"
    # Descarta tudo que entra e sai pela interface do nó na rede do kind.
    for chain in INPUT FORWARD; do ipt -I "$chain" 1 -i eth0 "${TAG[@]}" -j DROP; done
    for chain in OUTPUT FORWARD; do ipt -I "$chain" 1 -o eth0 "${TAG[@]}" -j DROP; done
    ok "$node isolado da rede às $(date +%H:%M:%S)"
    ;;
  heal)
    for chain in INPUT FORWARD; do while ipt -D "$chain" -i eth0 "${TAG[@]}" -j DROP 2>/dev/null; do :; done; done
    for chain in OUTPUT FORWARD; do while ipt -D "$chain" -o eth0 "${TAG[@]}" -j DROP 2>/dev/null; do :; done; done
    mark "partição curada: $node"
    ok "rede de $node restaurada"
    ;;
  latency)
    delay=${3:?informe o atraso em ms}
    jitter=${4:-0}
    loss=${5:-0}
    mark "latência ${delay}ms±${jitter} perda ${loss}% em $node"
    run docker exec "$node" tc qdisc replace dev eth0 root netem delay "${delay}ms" "${jitter}ms" loss "${loss}%"
    ;;
  clear)
    docker exec "$node" tc qdisc del dev eth0 root 2>/dev/null || true
    mark "latência removida: $node"
    ok "rede de $node sem atraso/perda"
    ;;
  *) die "ação desconhecida: $action" ;;
esac
