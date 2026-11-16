#!/usr/bin/env bash
# Demo 2: readiness × liveness, e queda abrupta do processo.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

endpoints() {
  try kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"  pronto="}{.conditions.ready}{"\n"}{end}'
}

step "1. Quem está no Service agora"
say "O EndpointSlice lista os pods do Service. Só os com pronto=true recebem tráfego."
endpoints
pause

step "2. Readiness falhando: sai do Service, NÃO reinicia"
pod=$(app_pods | head -n1)
say "Vou fazer $pod responder 503 em /readyz (ex.: perdeu a conexão com uma dependência)."
"$ROOT/chaos/pod.sh" unready "$pod"
countdown 6 "readinessProbe a cada 2 s, 2 falhas seguidas"
endpoints
try_sh "kubectl -n $NS get pod $pod -o wide"
say "READY 0/1 e RESTARTS 0: o pod está vivo, só não recebe tráfego. Nenhuma falha na sonda."
pause
"$ROOT/chaos/pod.sh" fix "$pod"
countdown 4 "voltando"
endpoints
pause

step "3. Liveness falhando: o kubelet reinicia o contêiner"
pod=$(app_pods | sed -n 2p)
say "Agora $pod vai 'travar': /healthz e /readyz passam a falhar e / responde 500."
say "Readiness tira o pod do Service em ~4 s; liveness (3 falhas x 3 s) o reinicia em ~9 s."
say "Na sonda: alguns erros 500 até a readiness agir. O tempo de detecção é o preço."
"$ROOT/chaos/pod.sh" break "$pod"
countdown 15 "aguardando a livenessProbe"
try_sh "kubectl -n $NS get pod $pod -o wide"
try_sh "kubectl -n $NS get events --field-selector involvedObject.name=$pod --sort-by=.lastTimestamp | tail -n 6"
say "RESTARTS 1: um processo novo, saudável. O pod (e o IP) continuam os mesmos."
pause

step "4. Queda abrupta (crash) do processo"
pod=$(app_pods | sed -n 3p)
say "Agora o processo de $pod morre sem aviso (exit 2). O kubelet percebe na hora e"
say "reinicia o contêiner; durante ~3 s de aquecimento o pod fica fora do Service."
"$ROOT/chaos/pod.sh" crash "$pod"
countdown 10 "aguardando"
try_sh "kubectl -n $NS get pod $pod -o wide"
say "Compare na sonda: apagar um pod (demo 1) não gera erro; um crash pode gerar alguns,"
say "das requisições que estavam a caminho daquele pod no instante da queda."
ok "fim da demo 2"
