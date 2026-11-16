#!/usr/bin/env bash
# Aplica os manifestos da pasta k8s/ e espera a aplicação ficar disponível.
# Reaplicar também serve para voltar a aplicação ao estado inicial (v1, com probes).
source "$(dirname "$0")/lib.sh"
require_cluster

run kubectl apply -f "$ROOT/k8s/"
info "aguardando o rollout"
run kubectl -n "$NS" rollout status deploy/web --timeout=180s
echo
run kubectl -n "$NS" get pods -o wide
echo
if curl -fsS -m 2 http://localhost:8080/ >/dev/null 2>&1; then
  ok "aplicação respondendo em http://localhost:8080"
  curl -s -m 2 http://localhost:8080/
else
  warn "http://localhost:8080 ainda não respondeu (tente de novo em alguns segundos)"
fi
echo
ok "Próximo passo (em outro terminal): make probe"
