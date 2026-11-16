#!/usr/bin/env bash
# Cria (up) ou destrói (down) o cluster kind do laboratório.
#   scripts/cluster.sh up      KIND_CONFIG=cluster/kind-lite.yaml scripts/cluster.sh up
#   scripts/cluster.sh down
source "$(dirname "$0")/lib.sh"

check_prereqs() {
  local missing=""
  for c in docker kind kubectl curl; do command -v "$c" >/dev/null || missing="$missing $c"; done
  [[ -z "$missing" ]] || die "faltam programas:$missing (veja docs/01-preparacao.md)"
  docker info >/dev/null 2>&1 || die "o Docker não está rodando (ou seu usuário não tem acesso a ele)"
  info "versões: $(kind version | awk '{print $1, $2}'), kubectl $(command kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}')"

  # Em Linux, clusters com vários nós esgotam facilmente os limites de inotify
  # (sintoma: pods do kube-system em CrashLoop com "too many open files").
  if [[ -r /proc/sys/fs/inotify/max_user_watches ]]; then
    local w i
    w=$(cat /proc/sys/fs/inotify/max_user_watches)
    i=$(cat /proc/sys/fs/inotify/max_user_instances)
    if ((w < 524288 || i < 512)); then
      warn "limites de inotify baixos (watches=$w, instances=$i). Recomendado:"
      warn "  sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512"
    fi
  fi
}

up() {
  check_prereqs
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    ok "cluster '$CLUSTER' já existe"
  else
    info "criando o cluster '$CLUSTER' com $KIND_CONFIG (leva alguns minutos)"
    run kind create cluster --config "$KIND_CONFIG" --image "$NODE_IMAGE" --wait 5m
  fi
  info "copiando o etcdctl para os nós control-plane"
  install_etcdctl
  echo
  run kubectl get nodes -o wide
  echo
  ok "cluster pronto. Próximo passo: make images"
}

down() {
  docker rm -f "$PROBER_CONTAINER" >/dev/null 2>&1 || true
  run kind delete cluster --name "$CLUSTER"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "uso: $0 up|down" >&2; exit 2 ;;
esac
