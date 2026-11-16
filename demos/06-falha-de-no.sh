#!/usr/bin/env bash
# Demo 6: um worker "some" (congelado). Como o cluster detecta e se recupera.
#   demos/06-falha-de-no.sh [nó]      (padrão: o worker com mais pods da aplicação)
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

node=${1:-$(busiest_worker)}
require_node "$node"
[[ "$node" == *worker* ]] || die "use um worker"

step "1. Antes"
try_sh "kubectl -n $NS get pods -o wide"
say "Vou congelar $node. A linha do tempo esperada:"
say "  • kubelet renova a Lease do nó a cada 10 s; congelado, para de renovar"
say "  • após ~50 s sem notícias (node-monitor-grace-period) o node lifecycle controller"
say "    marca o nó como Unknown/NotReady, põe o taint unreachable e marca os pods como"
say "    não prontos => saem do Service. ATÉ AQUI, parte das requisições falha."
say "  • após mais 30 s (tolerationSeconds do manifesto; o padrão é 300 s) os pods são"
say "    despejados e o ReplicaSet controller cria substitutos em outros nós."
pause

step "2. Congelando $node"
"$ROOT/chaos/no.sh" pause "$node"
t0=$(date +%s)
last_ready="" last_taint="" saw_new=""
while :; do
  el=$(($(date +%s) - t0))
  rd=$(kubectl get node "$node" --request-timeout=3s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  tn=$(kubectl get node "$node" --request-timeout=3s -o jsonpath='{.spec.taints[*].key}' 2>/dev/null | tr ' ' ',' || true)
  ready=$(kubectl -n "$NS" get deploy web --request-timeout=3s -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  on=$(kubectl -n "$NS" get pods -l app=web --request-timeout=3s --no-headers \
    --field-selector "spec.nodeName=$node" 2>/dev/null | awk '{printf "%s(%s) ", $1, $3}')
  printf 'T+%3ds  nó Ready=%-7s taints=[%s]  réplicas prontas=%s  pods no nó: %s\n' "$el" "$rd" "${tn:-}" "${ready:-0}" "${on:-nenhum}"
  if [[ "$rd" != "$last_ready" && "$rd" != "True" ]]; then
    say "   ↳ T+${el}s: o controlador percebeu a falha (Ready=$rd)"; mark "nó $node detectado ($rd)"
  fi
  if [[ "$tn" == *unreachable* && "$last_taint" != *unreachable* ]]; then
    say "   ↳ T+${el}s: taint unreachable aplicado"
  fi
  if [[ "$on" == *Terminating* && -z "$saw_new" ]]; then
    say "   ↳ T+${el}s: pods despejados; substitutos sendo criados em outros nós"; mark "pods de $node despejados"; saw_new=1
  fi
  last_ready=$rd last_taint=$tn
  if [[ -n "$saw_new" && "${ready:-0}" -ge 4 ]]; then
    say "   ↳ T+${el}s: 4 réplicas prontas de novo, sem depender de $node"; mark "capacidade restaurada"; break
  fi
  ((el > 240)) && { warn "tempo esgotado"; break; }
  sleep 3
done
pause

step "3. Onde estão os pods agora"
try_sh "kubectl -n $NS get pods -o wide"
say "Os pods de $node aparecem como Terminating: o API server não consegue confirmar"
say "que eles pararam, porque o kubelet de lá não responde. Ficam assim até o nó voltar."
pause

step "4. O nó volta"
"$ROOT/chaos/no.sh" unpause "$node"
say "O kubelet volta, descobre que os pods dele foram apagados e os encerra."
countdown 20 "aguardando"
try kubectl get nodes
try_sh "kubectl -n $NS get pods -o wide"
say "Os pods NÃO voltam sozinhos para $node: o scheduler só decide onde colocar pods novos."
ok "fim da demo 6"
