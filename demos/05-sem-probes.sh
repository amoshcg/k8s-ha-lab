#!/usr/bin/env bash
# Demo 5 (contraste): o mesmo Deployment SEM probes.
# Mostra que a alta disponibilidade das demos 3 e 4 vem das probes, não de mágica.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

step "1. Remover as probes"
say "Sem readinessProbe, o pod é considerado pronto assim que o contêiner inicia,"
say "mas a app ainda leva 3 s aquecendo antes de aceitar conexões."
say "Só remover as probes já muda o template e dispara um rollout. Olhe a sonda."
mark "remove probes (rollout sem probes)"
try kubectl -n "$NS" patch deploy/web --type=json -p='[
  {"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"},
  {"op":"remove","path":"/spec/template/spec/containers/0/startupProbe"},
  {"op":"remove","path":"/spec/template/spec/containers/0/livenessProbe"},
  {"op":"replace","path":"/spec/minReadySeconds","value":0}]'
try kubectl -n "$NS" rollout status deploy/web --timeout=120s
say "Erros 'conexão recusada' na sonda: tráfego chegando a pods que ainda não escutam."
pause

step "2. Publicar a v3 defeituosa sem probes"
say "Agora nada impede o rollout: cada pod v3 'fica pronto' na hora, os antigos são"
say "removidos e o serviço inteiro passa a falhar."
mark "rollout -> v3 SEM probes"
try kubectl -n "$NS" set image deploy/web app=k8slab/web:v3
try kubectl -n "$NS" rollout status deploy/web --timeout=120s
countdown 15 "observe o painel"
try kubectl -n "$NS" get pods -o wide
pause

step "3. Restaurar (v1 com probes)"
mark "restaura manifesto com probes"
try kubectl apply -f "$ROOT/k8s/10-web-deployment.yaml"
try kubectl -n "$NS" rollout status deploy/web --timeout=180s
say "Com as probes de volta, o rollout de recuperação é seguro de novo."
ok "fim da demo 5"
