# 3. Aplicação e sonda

## 3.1 A aplicação de demonstração

[`app/web/main.go`](../app/web/main.go) é um servidor HTTP de ~200 linhas, sem
dependências. Ela imita os comportamentos de uma aplicação real que importam para o
Kubernetes:

| Endpoint | Para quê | Comportamento |
|---|---|---|
| `GET /` | tráfego normal | JSON com versão, pod, nó e IP |
| `GET /healthz` | **livenessProbe** e **startupProbe** | 200 enquanto o processo está saudável |
| `GET /readyz` | **readinessProbe** | 503 durante o encerramento, ou se marcado como não pronto |
| `/admin/unready` | injeta falha | só `/readyz` passa a falhar |
| `/admin/break` | injeta falha | `/`, `/healthz` e `/readyz` passam a falhar ("travou") |
| `/admin/crash` | injeta falha | o processo morre na hora (exit 2) |
| `/admin/fix` | desfaz `break` e `unready` | |

E o ciclo de vida:

- **Aquecimento:** espera `STARTUP_DELAY` (3 s) antes de abrir a porta, como uma JVM
  carregando o Spring.
- **Encerramento gracioso:** ao receber SIGTERM, passa a responder 503 em `/readyz`,
  **continua atendendo** por `SHUTDOWN_DELAY` (5 s) e só então fecha. Isso cobre a
  janela em que o pod já está sendo removido, mas o kube-proxy dos nós ainda não
  atualizou as regras. Remover endpoints é eventualmente consistente.

Três imagens são geradas do mesmo código:

| Imagem | Diferença |
|---|---|
| `k8slab/web:v1` | versão inicial |
| `k8slab/web:v2` | versão nova, saudável |
| `k8slab/web:v3` | **defeituosa**: "não conecta ao banco", `/readyz` sempre 503, `/` responde 503 e o processo morre após 8 s |

```bash
make images     # docker build (3 versões + sonda) e kind load nos nós
```

Não há registry: `kind load docker-image` copia a imagem para o containerd de cada nó,
e o manifesto usa `imagePullPolicy: IfNotPresent`.

## 3.2 As três probes

Trecho de [`k8s/10-web-deployment.yaml`](../k8s/10-web-deployment.yaml):

```yaml
startupProbe:   { httpGet: { path: /healthz, port: http }, periodSeconds: 1, failureThreshold: 30 }
readinessProbe: { httpGet: { path: /readyz,  port: http }, periodSeconds: 2, failureThreshold: 2, timeoutSeconds: 1 }
livenessProbe:  { httpGet: { path: /healthz, port: http }, periodSeconds: 3, failureThreshold: 3, timeoutSeconds: 1 }
```

| Probe | Pergunta | Se falhar | Tempo até agir (aqui) |
|---|---|---|---|
| startup | "já terminou de iniciar?" | as outras probes nem começam; após 30 falhas, reinicia | até 30 s |
| readiness | "posso receber tráfego agora?" | sai do Service (EndpointSlice), **não reinicia** | ≤ 4 s |
| liveness | "o processo está saudável?" | o kubelet **mata e reinicia** o contêiner | ~9 s |

Quem executa as probes é o **kubelet** do nó, localmente. O resultado vira o status do
pod na API, e o EndpointSlice controller e os kube-proxy reagem a esse status.

Outros campos do Deployment que importam para disponibilidade:

- `replicas: 4` e `topologySpreadConstraints`: réplicas espalhadas entre os 3 workers;
- `strategy.rollingUpdate: maxSurge 1, maxUnavailable 0`: nunca tira um pod antigo
  antes de o novo estar pronto;
- `minReadySeconds: 3`: o pod novo precisa ficar pronto por 3 s seguidos;
- `progressDeadlineSeconds: 60`: rollout sem progresso por 60 s é marcado como falho;
- `tolerations ... tolerationSeconds: 30`: despejo de pods de nó inacessível após 30 s
  (o padrão é 300 s);
- `PodDisruptionBudget minAvailable: 3` ([`k8s/30-web-pdb.yaml`](../k8s/30-web-pdb.yaml)).

## 3.3 Implantar

```bash
make deploy
curl -s http://localhost:8080/ ; echo
```

```json
{"ip":"10.244.3.2","msg":"olá do pod web-6c7b9d8f4-x2k9p","node":"k8slab-worker2","pod":"web-6c7b9d8f4-x2k9p","terminating":false,"uptime_s":41.2,"version":"v1"}
```

Repita o `curl` algumas vezes: o pod que responde muda, porque o Service balanceia a
cada conexão.

## 3.4 A sonda

[`app/prober/main.go`](../app/prober/main.go) roda num contêiner **fora do cluster**,
ligado à rede `kind`, e mede duas pistas:

| Pista | O que faz | Intervalo | O que mede |
|---|---|---|---|
| `app` | `GET http://k8slab-control-plane:30080/` (conexão nova a cada vez) | 100 ms | **plano de dados**: a aplicação está respondendo? |
| `api` | `PATCH` no ConfigMap `demo/api-heartbeat` pelo HAProxy da API | 500 ms | **plano de controle**: a API aceita escritas? (cada escrita exige quórum do etcd) |

Uma requisição é **falha** se não responder 200 em 1 s (`app`) ou 2 s (`api`). Um
**incidente** começa na primeira falha e termina quando passam 2 s seguidos sem falhas.

A pista `api` usa o token de uma ServiceAccount que só pode alterar aquele ConfigMap
([`k8s/40-api-heartbeat.yaml`](../k8s/40-api-heartbeat.yaml)).

```bash
make probe                 # ou: make probe LABEL=falha-de-no
```

- **Terminal:** uma linha por segundo (`app ✔ 10/10 v1:10 4 pods │ api ✔ 2/2`) e avisos
  `▼ FALHAS COMEÇARAM` / `▲ RECUPERADO` com a duração de cada incidente.
- **Painel:** http://localhost:8090, com o estado de cada pista (NO AR / DEGRADADO /
  FORA DO AR), a linha do tempo de 60 s colorida por versão (azul v1, verde v2, laranja
  v3, vermelho falha), quem respondeu nos últimos 5 s e a lista de incidentes.
- **Marcas:** todo script de `chaos/` e `demos/` registra uma marca na sonda no momento
  em que injeta a falha (linha tracejada no painel). Para marcar à mão:
  `curl "localhost:8090/api/mark?label=meu+evento"`.
- **Ctrl+C:** imprime e salva o resumo (`results/<rótulo>_<data>_resumo.txt`), com o
  efeito medido após cada marca. O CSV completo fica em `results/`.

## 3.5 Organização dos terminais

```
┌──────────────────────────────┬──────────────────────────────┐
│ T1: make probe               │ navegador: localhost:8090    │
│ (linhas por segundo)         │ (painel)                     │
├──────────────────────────────┼──────────────────────────────┤
│ T2: make watch               │ T3: ./demos/NN-....sh        │
│ (nós, ReplicaSets, pods)     │ (onde você executa)          │
└──────────────────────────────┴──────────────────────────────┘
```

Próximo: [4. Experimentos de alta disponibilidade](04-alta-disponibilidade.md)
