# 6. Métricas para o relatório

## 6.1 O que é medido, e como

| Métrica | Definição | Fonte |
|---|---|---|
| **Disponibilidade** | respostas 200 ÷ requisições (pista `app`), em % | sonda |
| **Disponibilidade da API** | escritas aceitas ÷ tentativas (pista `api`) | sonda |
| **Tempo de detecção** | 1ª falha observada − instante da injeção (marca) | `analysis/analisa.py` |
| **Tempo de recuperação** | fim do incidente − instante da injeção. O incidente termina na 1ª resposta ok de uma sequência de 2 s sem falhas | `analysis/analisa.py` |
| **Falhas por incidente** | quantas requisições falharam | sonda / análise |
| **Latência** | p50/p95/p99 das respostas ok, em ms | sonda, k6 |
| **Vazão** | requisições/s sustentadas sob carga | k6 (`scripts/carga.sh`) |
| **Tempo de restauração de capacidade** | injeção → réplicas prontas de volta ao desejado | saída da demo 6 (`T+...s`) / eventos |

Resolução: a pista `app` amostra a cada 100 ms e a `api` a cada 500 ms. Tempos têm
incerteza da ordem de um intervalo. Tudo roda no mesmo relógio (a sua máquina), então não
há erro de sincronização entre a marca e as amostras.

## 6.2 Protocolo

1. Comece de um estado limpo: `make reset-app`.
2. Suba a sonda com um rótulo: `make probe LABEL=e6-falha-no`.
3. Espere ~30 s de linha de base (sem falhas).
4. Execute o experimento N vezes (sem pausas, com restauração entre as rodadas):
   ```bash
   scripts/repetir.sh 5 demos/06-falha-de-no.sh
   scripts/repetir.sh 10 chaos/pod.sh crash
   ```
5. Encerre a sonda com Ctrl+C e analise:
   ```bash
   make analyze                       # CSV mais recente
   python3 analysis/analisa.py results/e6-falha-no_20261110-140000.csv
   ```
   Gera `*_analise.md` (tabelas prontas para colar) e `*_linha.png` (gráfico: latência
   por versão, falhas em vermelho, incidentes sombreados, marcas tracejadas). A seção
   "Experimentos repetidos" agrupa as marcas iguais e dá mediana, mínimo e máximo.

## 6.3 Experimentos sugeridos

| ID | Experimento | Comando | Repetições | Métricas principais |
|---|---|---|---|---|
| E1 | linha de base | `make probe` por 5 min + `scripts/carga.sh` | 1 | disponibilidade, p50/p95/p99, vazão |
| E2 | apagar pod | `scripts/repetir.sh 10 chaos/pod.sh delete` | 10 | falhas (esperado 0) |
| E3 | crash de pod | `scripts/repetir.sh 10 chaos/pod.sh crash` | 10 | falhas, recuperação |
| E4 | pod travado (liveness) | `scripts/repetir.sh 5 chaos/pod.sh break` | 5 | detecção, recuperação |
| E5 | rollout v1→v2 | demo 3 (com e sem `scripts/carga.sh` em paralelo) | 5 | falhas (esperado 0), duração, vazão durante o rollout |
| E6 | versão defeituosa | demo 4 × demo 5 | 3 cada | falhas com probes × sem probes |
| E7 | falha de nó | `scripts/repetir.sh 5 demos/06-falha-de-no.sh` | 5 | detecção, recuperação, restauração de capacidade |
| E8 | drain com PDB | demo 7 | 3 | falhas (esperado 0), duração do drain |
| E9 | líder do etcd travado × parado com SIGTERM | demo 10, passos 2 e 3 | 5 | indisponibilidade da pista `api` |
| E10 | perda de quórum | demo 10, passo 4 | 3 | `api` indisponível, `app` disponível |

### Estudo de parâmetros (dá profundidade ao relatório)

O tempo de reação a uma falha de nó é uma **escolha** entre detectar rápido e evitar
falsos positivos. Meça E7 em combinações diferentes:

```bash
scripts/deteccao.sh 20s          # grace period do node controller (padrão 50s)
scripts/deteccao.sh padrao       # volta ao padrão
# tolerationSeconds (padrão do manifesto 30; padrão do Kubernetes 300):
kubectl -n demo patch deploy web --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/tolerations/0/tolerationSeconds","value":10},
  {"op":"replace","path":"/spec/template/spec/tolerations/1/tolerationSeconds","value":10}]'
```

| grace period | tolerationSeconds | detecção (falhas param) | capacidade restaurada |
|---|---|---|---|
| 50 s (padrão) | 300 s (padrão) | ~50 s | ~5–6 min |
| 50 s | 30 s | ~50 s | ~1,5 min |
| 20 s | 30 s | ~20 s | ~1 min |
| 20 s | 10 s | ~20 s | ~40 s |

(valores esperados; preencha com os medidos)

Discussão para o relatório: com 20 s, uma pausa longa de GC ou um soluço de rede de
poucos segundos já pode tirar um nó saudável de serviço e disparar despejos em massa.
O node controller tem proteções para isso (taxa de despejo limitada e modos para
quando muitos nós caem juntos), justamente porque, num sistema assíncrono, "não
respondeu" não significa "morreu".

## 6.4 Vazão e latência sob carga

```bash
scripts/carga.sh                         # 20 usuários virtuais, 60 s
VUS=50 DURACAO=2m scripts/carga.sh       # mais carga
```

O resumo do k6 traz `http_reqs` (total e por segundo = **vazão**), `http_req_duration`
(avg, med, p90, p95, p99) e `checks` (fração de respostas 200). Rode a carga
**durante** um rollout ou uma falha de nó para medir o impacto na vazão. As marcas de
início e fim da carga aparecem na sonda.

Lembre no relatório: os números absolutos refletem um notebook com 6 "nós" no mesmo
Docker. O que vale comparar são as **relações** (com × sem probes, padrão × ajustado,
falha graciosa × abrupta).

Próximo: [7. Solução de problemas](07-problemas.md)
