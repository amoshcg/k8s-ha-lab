#!/usr/bin/env bash
# Demo 8: o kube-scheduler por dentro (filtros, pontuação, Binding).
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster
S="$ROOT/demos/scheduler"

step "1. O que o scheduler faz"
say "Observa pods com spec.nodeName vazio. Para cada um:"
say "  Filtro (Filter): descarta nós inviáveis (recursos, taints, afinidade, portas...)"
say "  Pontuação (Score): ordena os que sobraram (espalhamento, balanceamento, afinidade...)"
say "  Binding: grava o nó escolhido no pod. Daí em diante é com o kubelet daquele nó."
try_sh "kubectl -n $NS get pods -l app=web -o wide"
say "As réplicas estão espalhadas: o plugin PodTopologySpread pontua melhor os nós com menos réplicas."
pause

step "2. Recursos: o scheduler decide por requests, não pelo uso real"
w=$(worker_nodes | head -n1)
try_sh "kubectl describe node $w | sed -n '/Allocatable:/,/System Info:/p' | head -n 8"
try_sh "kubectl describe node $w | sed -n '/Allocated resources:/,/Events:/p'"
pause

step "3. Um pod que não cabe em lugar nenhum"
try kubectl apply -f "$S/pod-grande.yaml"
countdown 4 "aguardando o scheduler"
try kubectl -n "$NS" get pod grande
try_sh "kubectl -n $NS describe pod grande | sed -n '/Events:/,\$p'"
say "Leia a mensagem: cada nó foi eliminado por um filtro (NodeResourcesFit: CPU"
say "insuficiente; TaintToleration: taint de control-plane). O pod fica Pending, e o"
say "scheduler tenta de novo quando algo no cluster muda."
try kubectl -n "$NS" delete pod grande --wait=false
pause

step "4. Afinidade de nó (regra obrigatória)"
alvo=$(worker_nodes | tail -n1)
try kubectl label node "$alvo" disco=ssd --overwrite
try kubectl apply -f "$S/pod-ssd.yaml"
countdown 5 "aguardando"
try kubectl -n "$NS" get pod precisa-ssd -o wide
say "Só $alvo passou no filtro NodeAffinity."
try kubectl -n "$NS" delete pod precisa-ssd --wait=false
try kubectl label node "$alvo" disco-
pause

step "5. Taints: o nó repele pods que não os toleram"
alvo=$(worker_nodes | sed -n 2p)
try kubectl taint node "$alvo" manutencao=sim:NoSchedule --overwrite
mark "taint NoSchedule em $alvo + scale 7"
try kubectl -n "$NS" scale deploy/web --replicas=7
countdown 12 "aguardando"
try_sh "kubectl -n $NS get pods -l app=web -o wide"
say "Nenhuma réplica NOVA foi para $alvo. NoSchedule não remove as que já estavam lá;"
say "NoExecute removeria (é o que o node controller usa quando um nó cai, demo 6)."
try kubectl taint node "$alvo" manutencao-
try kubectl -n "$NS" scale deploy/web --replicas=4
pause

step "6. Escalonar é só preencher spec.nodeName"
say "Um pod criado já com spec.nodeName não passa pelo scheduler: vai direto para o kubelet."
try kubectl apply -f "$S/pod-nodename.yaml"
countdown 5 "aguardando"
try kubectl -n "$NS" get pod sem-scheduler -o wide
try_sh "kubectl -n $NS get events --field-selector involvedObject.name=sem-scheduler -o custom-columns=MOTIVO:.reason,ORIGEM:.source.component"
say "Não há evento 'Scheduled' do default-scheduler."
try kubectl -n "$NS" delete pod sem-scheduler --wait=false
pause

step "7. Sem nenhum scheduler no cluster"
say "Paro o kube-scheduler nos 3 control planes. O cluster continua funcionando,"
say "mas pods novos ficam Pending para sempre: ninguém faz o Binding."
"$ROOT/chaos/componente.sh" stop kube-scheduler todos
countdown 10 "o kubelet encerra os static pods"
try kubectl apply -f "$S/pod-simples.yaml"
countdown 8 "aguardando"
try kubectl -n "$NS" get pod simples -o wide
pause
"$ROOT/chaos/componente.sh" start kube-scheduler todos
say "Os schedulers voltam, um deles conquista a Lease e escalona o que estava pendente."
countdown 25 "aguardando o novo líder"
try kubectl -n "$NS" get pod simples -o wide
try kubectl -n kube-system get lease kube-scheduler -o jsonpath='{.spec.holderIdentity}{"\n"}'
try kubectl -n "$NS" delete pod simples --wait=false
say "Para ver as notas de cada plugin em cada nó: kube-scheduler-simulator (kubernetes-sigs)."
ok "fim da demo 8"
