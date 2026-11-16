#!/usr/bin/env bash
# Demo 4: uma versão com defeito não derruba o serviço, e o rollback é um comando.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

current=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}')
step "1. Publicar a v3 (com defeito)"
say "Versão atual: $current. A v3 não consegue conectar ao 'banco': /readyz responde 503"
say "e o processo morre após 8 s. Como nunca fica pronta, o rollout trava no 1º pod"
say "e os pods antigos continuam atendendo. A sonda deve continuar sem falhas."
try kubectl -n "$NS" annotate deploy/web kubernetes.io/change-cause="v3: versão com defeito" --overwrite
mark "rollout -> v3 (defeituosa)"
try kubectl -n "$NS" set image deploy/web app=k8slab/web:v3
countdown 20 "deixando o defeito aparecer"
try kubectl -n "$NS" get pods -o wide
pause

step "2. O rollout está travado, e o Kubernetes sabe disso"
say "progressDeadlineSeconds=60: sem progresso por 60 s, a condição Progressing vira"
say "False com motivo ProgressDeadlineExceeded. O 'rollout status' abaixo termina com erro."
try kubectl -n "$NS" rollout status deploy/web --timeout=90s
try kubectl -n "$NS" get deploy web \
  -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{"  ("}{.reason}{")\n"}{end}'
say "Atenção: o Kubernetes PARA o rollout, mas não volta sozinho. O rollback automático"
say "fica com ferramentas como Argo Rollouts e Flagger."
pause

step "3. Rollback"
mark "rollout undo"
try kubectl -n "$NS" rollout undo deploy/web
# O undo não mexe na anotação change-cause: sem isto, a revisão restaurada apareceria como "v3: versão com defeito".
kubectl -n "$NS" annotate deploy/web kubernetes.io/change-cause="rollback: desfaz a v3" --overwrite >/dev/null
try kubectl -n "$NS" rollout status deploy/web --timeout=120s
try kubectl -n "$NS" rollout history deploy/web
say "Para voltar a uma revisão específica: kubectl rollout undo deploy/web --to-revision=N"
ok "fim da demo 4"
