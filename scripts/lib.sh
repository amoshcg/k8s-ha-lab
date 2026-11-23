#!/usr/bin/env bash
# shellcheck disable=SC2034 # variáveis usadas pelos scripts que fazem "source" deste arquivo
# Funções e variáveis comuns a todos os scripts do laboratório.
# Compatível com o bash 3.2 do macOS (sem arrays associativos, sem mapfile).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-k8slab}"
NS="${NS:-demo}"
KCTX="kind-${CLUSTER}"
# Imagem dos nós do kind v0.31.0 (Kubernetes v1.35.0). Para outra versão, use
# uma das imagens listadas nas notas de versão do kind, por exemplo:
#   NODE_IMAGE=kindest/node:v1.34.3@sha256:08497ee19eace7b4b5348db5c6a1591d7752b164530a36f855cb0f2bdcbadd48 make cluster
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f}"
KIND_CONFIG="${KIND_CONFIG:-$ROOT/cluster/kind-ha.yaml}"
PROBER_URL="${PROBER_URL:-http://localhost:8090}"
PROBER_CONTAINER="${CLUSTER}-prober"
ENTRY_NODE="${CLUSTER}-control-plane"   # nó com a porta 8080 mapeada; não é derrubado nos experimentos

# Todo kubectl dos scripts aponta explicitamente para o cluster do laboratório,
# mesmo que o seu kubeconfig tenha outros contextos.
kubectl() { command kubectl --context "$KCTX" "$@"; }

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
else
  B='' D='' R='' G='' Y='' C='' N=''
fi

info() { printf '%s==>%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s ✔ %s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[aviso]%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s[erro]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Mostra o comando e o executa (um erro interrompe o script).
run() { printf '%s$ %s%s\n' "$B" "$*" "$N"; "$@"; }
# Como run, mas um erro não interrompe (usado nas demos: às vezes o erro É o resultado).
try() {
  printf '%s$ %s%s\n' "$B" "$*" "$N"
  "$@" || printf '%s(o comando terminou com erro %s)%s\n' "$D" "$?" "$N"
}
# Mostra e executa uma linha de shell com pipe/redirecionamento, sem interromper.
try_sh() {
  printf '%s$ %s%s\n' "$B" "$1" "$N"
  eval "$1" || printf '%s(o comando terminou com erro %s)%s\n' "$D" "$?" "$N"
}

# --- Roteiro da apresentação ---------------------------------------------------
# AUTO=1 dispensa o Enter entre os passos.
step()  { printf '\n%s━━━ %s ━━━%s\n' "$B$C" "$*" "$N"; }
say()   { printf '%s%s%s\n' "$Y" "$*" "$N"; }
pause() {
  if [[ "${AUTO:-0}" == 1 ]]; then sleep "${AUTO_WAIT:-3}"; return; fi
  read -r -p "${D}[Enter para continuar]${N} " _ || true
}
# Espera N segundos mostrando uma contagem regressiva.
countdown() {
  local s=$1 msg=${2:-aguardando}
  if [[ ! -t 1 ]]; then printf '%s (%ss)\n' "$msg" "$s"; sleep "$s"; return; fi
  while ((s > 0)); do printf '\r%s%s: %3ds%s ' "$D" "$msg" "$s" "$N"; sleep 1; s=$((s - 1)); done
  printf '\r%*s\r' $((${#msg} + 12)) ''
}

# Registra uma marca na sonda (se ela estiver rodando). Aparece no painel e no CSV.
mark() {
  curl -fsS -m 1 -G "$PROBER_URL/api/mark" --data-urlencode "label=$*" >/dev/null 2>&1 || true
}

# --- Nós ------------------------------------------------------------------------
all_nodes()    { kind get nodes --name "$CLUSTER" 2>/dev/null | grep -E 'control-plane|worker' | sort; }
cp_nodes()     { all_nodes | grep control-plane || true; }
worker_nodes() { all_nodes | grep worker || true; }
node_ip()      { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
node_paused()  { [[ "$(docker inspect -f '{{.State.Paused}}' "$1" 2>/dev/null)" == "true" ]]; }
is_node()      { all_nodes | grep -qx "$1"; }
require_node() { is_node "$1" || die "nó '$1' não existe. Nós: $(all_nodes | tr '\n' ' ')"; }
require_cluster() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || die "cluster '$CLUSTER' não existe. Rode: make cluster"
}

# Primeiro control plane que não está pausado (para executar comandos dentro dele).
reachable_cp() {
  local n
  for n in $(cp_nodes); do node_paused "$n" || { echo "$n"; return 0; }; done
  return 1
}

# --- Componentes do plano de controle ----------------------------------------------
# Nome do processo (/proc/PID/comm, até 15 caracteres) de cada componente.
comp_comm() {
  case "$1" in
    etcd) echo etcd ;;
    kube-apiserver) echo kube-apiserver ;;
    kube-scheduler) echo kube-scheduler ;;
    kube-controller-manager) echo kube-controller ;;
    *) die "componente desconhecido: $1 (use etcd, kube-apiserver, kube-scheduler ou kube-controller-manager)" ;;
  esac
}

# PIDs de um componente dentro de um nó (vistos a partir do namespace do nó).
comp_pids() {
  local node=$1 comm
  comm=$(comp_comm "$2")
  docker exec "$node" bash -c 'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = "$1" ] && echo "${p#/proc/}"; done; true' _ "$comm"
}

# --- etcd ---------------------------------------------------------------------------
# O etcdctl vem dentro da imagem do etcd; o cluster.sh o copia para os nós
# control-plane, assim conseguimos consultar o etcd mesmo com a API fora do ar.
etcdctl_on() {
  local node=$1 cid; shift
  set -- --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    --dial-timeout=1s --command-timeout=2s "$@"
  if docker exec "$node" test -x /usr/local/bin/etcdctl; then
    docker exec "$node" etcdctl "$@"
  else # alternativa: executar dentro do contêiner do etcd (precisa dele rodando nesse nó)
    cid=$(docker exec "$node" crictl ps --name '^etcd$' -q 2>/dev/null | head -n1)
    [[ -n "$cid" ]] || return 1
    docker exec "$node" crictl exec "$cid" etcdctl "$@"
  fi
}

install_etcdctl() {
  local n
  for n in $(cp_nodes); do
    docker exec "$n" test -x /usr/local/bin/etcdctl && continue
    docker exec "$n" bash -c '
      f=$(find /run/containerd -maxdepth 8 -path "*/rootfs/usr/local/bin/etcdctl" 2>/dev/null | head -n1)
      [ -n "$f" ] && cp "$f" /usr/local/bin/etcdctl' ||
      warn "não encontrei o etcdctl no nó $n (os comandos de etcd não vão funcionar nele)"
  done
}

etcd_endpoints() {
  local n out=""
  for n in $(cp_nodes); do out="${out:+$out,}https://$(node_ip "$n"):2379"; done
  echo "$out"
}

# Tabela "nó  papel  term  índice" a partir de 'etcdctl endpoint status'.
# Membros que não respondem aparecem como SEM RESPOSTA.
etcd_table() {
  local via table n ip line
  via=$(reachable_cp) || { warn "nenhum control plane acessível"; return 1; }
  table=$(etcdctl_on "$via" --endpoints="$(etcd_endpoints)" endpoint status -w table 2>/dev/null || true)
  printf '%-26s %-14s %-6s %s\n' "MEMBRO DO ETCD" "PAPEL" "TERM" "ÍNDICE RAFT"
  for n in $(cp_nodes); do
    ip=$(node_ip "$n")
    line=$(printf '%s\n' "$table" | awk -F'|' -v ip="https://$ip:2379" '
      /ENDPOINT/ { for (i = 1; i <= NF; i++) { h = $i; gsub(/^ +| +$/, "", h)
                     if (h == "ENDPOINT") e = i; if (h == "IS LEADER") l = i
                     if (h == "RAFT TERM") t = i; if (h == "RAFT INDEX") x = i }
                   next }
      e { ep = $e; gsub(/ /, "", ep); if (ep == ip) { ld = $l; tm = $t; ix = $x
            gsub(/ /, "", ld); gsub(/ /, "", tm); gsub(/ /, "", ix); print ld, tm, ix } }')
    if [[ -z "$line" ]]; then
      printf '%-26s %s%-14s%s\n' "$n" "$R" "SEM RESPOSTA" "$N"
    else
      # shellcheck disable=SC2086 # separação em palavras intencional
      set -- $line
      if [[ "$1" == "true" ]]; then
        printf '%-26s %s%-15s%s %-6s %s\n' "$n" "$G$B" "LÍDER" "$N" "$2" "$3"
      else
        printf '%-26s %-14s %-6s %s\n' "$n" "seguidor" "$2" "$3"
      fi
    fi
  done
}

etcd_leader_node() {
  local via table ip n
  via=$(reachable_cp) || return 1
  table=$(etcdctl_on "$via" --endpoints="$(etcd_endpoints)" endpoint status -w table 2>/dev/null || true)
  ip=$(printf '%s\n' "$table" | awk -F'|' '
      /ENDPOINT/ { for (i = 1; i <= NF; i++) { h = $i; gsub(/^ +| +$/, "", h)
                     if (h == "ENDPOINT") e = i; if (h == "IS LEADER") l = i }
                   next }
      e { ld = $l; gsub(/ /, "", ld); if (ld == "true") { ep = $e; gsub(/ /, "", ep); print ep } }' |
    sed -E 's#https://([^:]+):.*#\1#' | head -n1)
  [[ -n "$ip" ]] || return 1
  for n in $(cp_nodes); do [[ "$(node_ip "$n")" == "$ip" ]] && { echo "$n"; return 0; }; done
  return 1
}

# Nó que detém a Lease de liderança (kube-scheduler ou kube-controller-manager).
lease_holder() {
  kubectl -n kube-system get lease "$1" --request-timeout=3s \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null | cut -d_ -f1
}

# --- Aplicação ------------------------------------------------------------------------
# Worker com mais pods da aplicação (o alvo mais "doloroso" para derrubar).
busiest_worker() {
  kubectl -n "$NS" get pods -l app=web -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
    grep worker | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

host_tz() {
  if [[ -n "${TZ:-}" ]]; then echo "$TZ"; return; fi
  local l
  l=$(readlink /etc/localtime 2>/dev/null || true)
  [[ "$l" == *zoneinfo/* ]] && echo "${l##*zoneinfo/}" || echo UTC
}
