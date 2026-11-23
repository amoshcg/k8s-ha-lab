#!/usr/bin/env bash
# Roteiro enxuto para a demonstração ao vivo do seminário (~8 min).
# Pré-requisitos: make reset-app, make probe (painel aberto), e de preferência
#   scripts/deteccao.sh 20s   (falha de nó detectada em ~20 s em vez de ~50 s)
# Cada passo espera Enter: fale enquanto o terminal aguarda.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

step "1/5 · O cluster"
"$ROOT/scripts/status.sh"
pause

step "2/5 · Rollout v1 → v2 (olhe o painel: azul vira verde, sem vermelho)"
kubectl -n "$NS" annotate deploy/web kubernetes.io/change-cause="v2: nova versão" --overwrite >/dev/null
mark "rollout v1 -> v2"
try kubectl -n "$NS" set image deploy/web app=k8slab/web:v2
try kubectl -n "$NS" rollout status deploy/web --timeout=180s
pause

step "3/5 · Versão com defeito (v3) e rollback"
kubectl -n "$NS" annotate deploy/web kubernetes.io/change-cause="v3: versão com defeito" --overwrite >/dev/null
mark "rollout -> v3 (defeituosa)"
try kubectl -n "$NS" set image deploy/web app=k8slab/web:v3
countdown 15 "a v3 sobe, nunca fica pronta e morre"
try kubectl -n "$NS" get pods -o wide
say "O rollout travou no 1º pod; os 4 pods v2 seguem atendendo."
pause
mark "rollout undo"
try kubectl -n "$NS" rollout undo deploy/web
# O undo não mexe na anotação change-cause: sem isto, a revisão restaurada apareceria como "v3: versão com defeito".
kubectl -n "$NS" annotate deploy/web kubernetes.io/change-cause="rollback: desfaz a v3" --overwrite >/dev/null
try kubectl -n "$NS" rollout history deploy/web
pause

step "4/5 · Um worker cai"
node=$(busiest_worker)
"$ROOT/chaos/no.sh" pause "$node"
t0=$(date +%s)
evicted=""
while :; do
  el=$(($(date +%s) - t0))
  rd=$(kubectl get node "$node" --request-timeout=3s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  ready=$(kubectl -n "$NS" get deploy web --request-timeout=3s -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  on=$(kubectl -n "$NS" get pods -l app=web --request-timeout=3s --no-headers \
    --field-selector "spec.nodeName=$node" 2>/dev/null | awk '{printf "%s ", $3}')
  [[ "$on" == *Terminating* ]] && evicted=1
  printf 'T+%3ds  %s Ready=%-7s  réplicas prontas=%-2s  pods no nó: %s\n' "$el" "$node" "$rd" "${ready:-0}" "${on:-nenhum}"
  [[ -n "$evicted" && "${ready:-0}" == 4 ]] && break
  ((el > 240)) && break
  sleep 3
done
try_sh "kubectl -n $NS get pods -o wide"
pause
"$ROOT/chaos/no.sh" unpause "$node"
info "aguardando $node voltar (Ready=True e pods presos em Terminating removidos)"
t0=$(date +%s)
while :; do
  el=$(($(date +%s) - t0))
  rd=$(kubectl get node "$node" --request-timeout=3s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  on=$(kubectl -n "$NS" get pods -l app=web --request-timeout=3s --no-headers \
    --field-selector "spec.nodeName=$node" 2>/dev/null | awk '{printf "%s ", $3}')
  printf 'T+%3ds  %s Ready=%-7s  pods no nó: %s\n' "$el" "$node" "$rd" "${on:-nenhum}"
  [[ "$rd" == True && "$on" != *Terminating* ]] && break
  ((el > 120)) && { warn "$node ainda não voltou ao normal após 120 s"; break; }
  sleep 3
done
try kubectl get nodes
ok "$node de volta"
pause

step "5/5 · O etcd perde o quórum: a API para, a aplicação não"
victims=$(cp_nodes | grep -v -x "$(etcd_leader_node)" | head -n2)
for v in $victims; do "$ROOT/chaos/componente.sh" freeze etcd "$v"; done
countdown 6 "aguardando"
try kubectl get pods -n "$NS" --request-timeout=4s
try_sh "curl -s -m 2 http://localhost:8080/ ; echo"
etcd_table
pause
for v in $victims; do "$ROOT/chaos/componente.sh" unfreeze etcd "$v"; done
countdown 8 "quórum restaurado"
etcd_table
try kubectl get pods -n "$NS" --request-timeout=5s
ok "fim da apresentação"
