# 7. Roteiro da demonstração ao vivo (5 a 10 minutos)

## Na véspera

- [ ] Rodar o roteiro completo uma vez, do zero (`make down && make up`), cronometrando.
- [ ] **Gravar a tela** desse ensaio (OBS, ou `asciinema rec` para o terminal). É o plano B.
- [ ] Guardar um CSV e o gráfico de cada experimento (`make analyze`) para mostrar se a
      demo falhar.

## 30 minutos antes

```bash
make status                       # tudo pronto? 3 líderes visíveis?
make reset-app                    # aplicação na v1, sem falhas pendentes
scripts/deteccao.sh 20s           # falha de nó detectada em ~20 s (explique que o padrão é 50 s)
make probe LABEL=apresentacao     # terminal 1
```

- Navegador em http://localhost:8090 (painel), com zoom de 125–150%.
- Terminal com fonte grande (≥ 18 pt), fundo escuro, janela dividida: painel à
  esquerda, terminal à direita.
- Notificações do sistema desligadas; notebook na tomada; Wi-Fi não é necessário.

## O roteiro (`./demos/00-apresentacao.sh`)

| Tempo | Passo | Fale sobre | O público vê |
|---|---|---|---|
| 0:00 | 1 · panorama (`status`) | nós são contêineres; 3 etcd em Raft (líder, term); Leases do scheduler e controller-manager | tabela de líderes |
| 1:00 | 2 · rollout v1→v2 | estado desejado; maxSurge/maxUnavailable; readiness como portão | painel azul → verde, **zero vermelho** |
| 2:30 | 3 · v3 defeituosa + undo | a readinessProbe contém o defeito; progressDeadline; o K8s não reverte sozinho | 1 pod em CrashLoop, painel verde; `rollout undo` |
| 4:30 | 4 · worker cai | heartbeat por Lease, timeout, taint, despejo; detector de falhas não distingue morto de lento | contagem `T+...`; falhas parciais e depois recuperação |
| 6:30 | 5 · etcd sem quórum | maioria; CP no CAP; plano de dados × plano de controle | `kubectl` falha, `curl` funciona; pista `api` vermelha e `app` verde |
| 8:00 | encerramento | Ctrl+C na sonda: o resumo com disponibilidade e incidentes | números finais |

Se o tempo apertar, pule o passo 3 (mostre o gráfico do ensaio no lugar).

## Frases que ajudam

- "Ninguém mandou o Kubernetes criar este pod. Ele **percebeu** que faltava um."
- "A aplicação só recebe tráfego quando **ela mesma** diz que está pronta."
- "Durante esses segundos o cluster não sabe se o nó morreu ou se só está lento. Isso
  não é um defeito do Kubernetes: é um resultado clássico de sistemas assíncronos."
- "Sem quórum, o etcd prefere ficar indisponível a arriscar dois históricos diferentes.
  E a aplicação nem percebe."

## Depois da apresentação

```bash
scripts/deteccao.sh padrao
make reset-app
```
