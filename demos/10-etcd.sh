#!/usr/bin/env bash
# Demo 10: o etcd (Raft) — eleição de líder, parada graciosa e perda de quórum.
# Deixe o painel da sonda visível: a pista "api" mede o plano de controle e a
# pista "app" o plano de dados.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster
[[ $(cp_nodes | wc -l) -ge 3 ]] || die "esta demo precisa do cluster com 3 control planes (cluster/kind-ha.yaml)"

# Mostra a tabela até aparecer um líder diferente de $1 (ou até $2 segundos).
wait_new_leader() {
  local old=$1 max=${2:-30} t0 el l
  t0=$(date +%s)
  while :; do
    el=$(($(date +%s) - t0))
    l=$(etcd_leader_node 2>/dev/null || true)
    if [[ -n "$l" && "$l" != "$old" ]]; then
      ok "novo líder do etcd: $l (detectado em ~${el}s pela consulta; a eleição em si leva ~1-2 s)"
      mark "novo líder etcd: $l"; break
    fi
    ((el > max)) && { warn "nenhum novo líder em ${max}s"; break; }
    sleep 1
  done
  etcd_table
}

step "1. O etcd por dentro"
say "Todo o estado do cluster está no etcd. Três membros replicam um log via Raft:"
say "um líder recebe as escritas e só confirma quando a MAIORIA (2 de 3) gravou."
say "TERM = número da eleição (mandato); ÍNDICE = posição no log replicado."
etcd_table
say "Detalhe do kubeadm (topologia 'stacked'): cada kube-apiserver conversa só com o"
say "etcd do PRÓPRIO nó (--etcd-servers=https://127.0.0.1:2379)."
try_sh "docker exec $(cp_nodes | head -n1) grep -- --etcd-servers /etc/kubernetes/manifests/kube-apiserver.yaml"
pause

step "2. Líder trava (SIGSTOP)"
old=$(etcd_leader_node)
say "Congelo o etcd de $old. Os seguidores param de receber heartbeats e, após o"
say "election timeout (~1 s), um deles se candidata, vence com 2 votos e o TERM sobe."
say "Na pista 'api': falhas breves. A fatia que passa pelo apiserver de $old continua"
say "falhando até o HAProxy tirá-lo do balanceamento. Na pista 'app': nada muda."
"$ROOT/chaos/componente.sh" freeze etcd "$old"
wait_new_leader "$old" 30
pause
"$ROOT/chaos/componente.sh" unfreeze etcd "$old"
countdown 5 "o membro antigo volta como seguidor e alcança o log"
etcd_table
pause

step "3. Parada graciosa do líder"
old=$(etcd_leader_node)
say "Agora o líder é encerrado com SIGTERM (tirando o manifesto do static pod). Antes"
say "de sair ele TRANSFERE a liderança para um seguidor: não há espera pelo election"
say "timeout. As falhas que ainda aparecerem na pista 'api' vêm do apiserver de $old,"
say "que perdeu o seu etcd local, até o HAProxy tirá-lo do balanceamento."
"$ROOT/chaos/componente.sh" stop etcd "$old"
wait_new_leader "$old" 40
pause
"$ROOT/chaos/componente.sh" start etcd "$old"
say "O kubelet recria o static pod do etcd (pode levar de 20 a 60 s)."
t0=$(date +%s)
while etcd_table | grep -q "SEM RESPOSTA"; do
  (($(date +%s) - t0 > 120)) && { warn "o etcd de $old ainda não voltou"; break; }
  sleep 2
done
etcd_table
pause

step "4. Perda de quórum (2 de 3 membros travados)"
say "Com só 1 de 3 membros, não há maioria: o etcd recusa leituras e escritas"
say "consistentes. A API do Kubernetes para (escolha por consistência, CP no teorema CAP)."
say "Mas os pods, o kube-proxy e as regras de rede já programadas continuam: a"
say "pista 'app' deve seguir 100% verde. Não deixe assim por mais de ~1 min."
pause
victims=$(cp_nodes | grep -v -x "$(etcd_leader_node)" | head -n2)
for v in $victims; do "$ROOT/chaos/componente.sh" freeze etcd "$v"; done
countdown 8 "aguardando"
try kubectl get pods -n "$NS" --request-timeout=5s
etcd_table
say "kubectl falha; a aplicação continua no ar. Plano de dados independente do plano de controle."
pause
for v in $victims; do "$ROOT/chaos/componente.sh" unfreeze etcd "$v"; done
mark "quórum restaurado"
countdown 10 "quórum restaurado; a API volta"
etcd_table
try kubectl get pods -n "$NS" --request-timeout=5s
say "Controllers e schedulers podem ter reiniciado (perderam a Lease durante a"
say "queda): veja a coluna REINÍCIOS em scripts/status.sh."
ok "fim da demo 10"
