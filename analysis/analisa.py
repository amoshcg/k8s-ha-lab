#!/usr/bin/env python3
"""Analisa um CSV da sonda e gera as métricas para o relatório.

uso:
    python3 analysis/analisa.py results/sonda_20261108-150000.csv [--recovery 2] [--sem-grafico]

Saídas (ao lado do CSV):
    <nome>_analise.md    tabelas em Markdown (cole no relatório)
    <nome>_linha.png     linha do tempo com latência, falhas e marcas (precisa de matplotlib)

Definições (as mesmas da sonda):
    disponibilidade   = respostas ok / requisições
    incidente         = começa na primeira falha; termina quando passam `recovery`
                        segundos seguidos sem falhas (fim = 1ª resposta ok dessa sequência)
    detecção (marca)  = 1ª falha depois da marca − instante da marca
    recuperação       = fim do incidente − instante da marca
Marcas com o mesmo rótulo (nomes de nós e pods normalizados) são agrupadas, o que
permite repetir um experimento N vezes e reportar mediana e extremos.
"""
import argparse
import csv
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def load(path):
    lanes, marks = defaultdict(list), []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            t = int(r["ts_ms"]) / 1000.0
            if r["lane"] == "mark":
                marks.append((t, r["detail"]))
                continue
            lanes[r["lane"]].append({
                "t": t, "ok": r["ok"] == "true", "lat": float(r["latency_ms"] or 0),
                "v": r["version"], "pod": r["pod"], "detail": r["detail"],
            })
    for s in lanes.values():
        s.sort(key=lambda x: x["t"])
    marks.sort()
    return lanes, marks


def incidents(samples, recovery):
    out, cur, ok_since = [], None, None
    for s in samples:
        if not s["ok"]:
            ok_since = None
            if cur is None:
                cur = {"start": s["t"], "end": None, "fails": 0, "total": 0}
                out.append(cur)
            cur["fails"] += 1
            cur["total"] += 1
        elif cur is not None:
            cur["total"] += 1
            if ok_since is None:
                ok_since = s["t"]
            if s["t"] - ok_since >= recovery:
                cur["end"] = ok_since
                cur, ok_since = None, None
    return out


def pct(xs, q):
    if not xs:
        return float("nan")
    s = sorted(xs)
    return s[min(len(s) - 1, int(q * (len(s) - 1) + 0.5))]


def norm_label(label):
    label = re.sub(r"\b[\w-]+-(worker|control-plane)\d*\b", lambda m: f"<{m.group(1)}>", label)
    label = re.sub(r"\bweb-[a-z0-9]+-[a-z0-9]+\b", "<pod>", label)
    return label


def fmt(x, nd=2):
    return "—" if x is None or x != x else f"{x:.{nd}f}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--recovery", type=float, default=2.0, help="segundos sem falha para encerrar um incidente")
    ap.add_argument("--sem-grafico", action="store_true")
    a = ap.parse_args()

    path = Path(a.csv)
    lanes, marks = load(path)
    if not lanes:
        sys.exit("CSV sem amostras")
    t0 = min(s[0]["t"] for s in lanes.values() if s)
    md = [f"# Análise de `{path.name}`", ""]

    md += ["## Visão geral", "",
           "| pista | requisições | falhas | disponibilidade | p50 (ms) | p95 (ms) | p99 (ms) | incidentes | maior incidente (s) |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    incs = {}
    for name, ss in lanes.items():
        lat = [s["lat"] for s in ss if s["ok"]]
        ok = sum(s["ok"] for s in ss)
        incs[name] = incidents(ss, a.recovery)
        longest = max(((i["end"] or ss[-1]["t"]) - i["start"] for i in incs[name]), default=0)
        md.append(f"| {name} | {len(ss)} | {len(ss) - ok} | {100 * ok / len(ss):.3f}% | {fmt(pct(lat, .5))} | "
                  f"{fmt(pct(lat, .95))} | {fmt(pct(lat, .99))} | {len(incs[name])} | {fmt(longest)} |")

    if marks:
        md += ["", "## Efeito de cada falha injetada", "",
               "| instante (s) | marca | pista | detecção (s) | recuperação (s) | falhas |",
               "|---:|---|---|---:|---:|---:|"]
        groups = defaultdict(lambda: defaultdict(list))
        for k, (mt, label) in enumerate(marks):
            limit = marks[k + 1][0] if k + 1 < len(marks) else float("inf")
            for name in lanes:
                hit = next((i for i in incs[name] if i["start"] < mt and (i["end"] is None or i["end"] > mt)), None) \
                    or next((i for i in incs[name] if mt <= i["start"] < limit), None)
                det = rec = None
                fails = 0
                if hit:
                    det = max(0.0, hit["start"] - mt)
                    rec = (hit["end"] - mt) if hit["end"] else None
                    fails = hit["fails"]
                md.append(f"| {mt - t0:.1f} | {label} | {name} | {fmt(det)} | {fmt(rec)} | {fails} |")
                groups[norm_label(label)][name].append((det, rec, fails))

        repeated = {g: v for g, v in groups.items() if any(len(x) > 1 for x in v.values())}
        if repeated:
            md += ["", "## Experimentos repetidos (mesma marca)", "",
                   "| marca | pista | n | sem falhas | recuperação mediana (s) | mín (s) | máx (s) | falhas (mediana) |",
                   "|---|---|---:|---:|---:|---:|---:|---:|"]
            for g, per in repeated.items():
                for name, runs in per.items():
                    recs = [r for _, r, _ in runs if r is not None]
                    clean = sum(1 for d, _, f in runs if d is None and f == 0)
                    md.append(f"| {g} | {name} | {len(runs)} | {clean} | "
                              f"{fmt(statistics.median(recs) if recs else None)} | {fmt(min(recs) if recs else None)} | "
                              f"{fmt(max(recs) if recs else None)} | {statistics.median([f for *_, f in runs]):.0f} |")

    out_md = path.with_name(path.stem + "_analise.md")
    out_md.write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md))
    print(f"\n→ {out_md}")

    if a.sem_grafico:
        return
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import matplotlib.ticker  # noqa: F401
    except ImportError:
        print("(matplotlib não instalado: pip install matplotlib para gerar o gráfico)")
        return

    colors = {"v1": "#3b6fd9", "v2": "#2e9e62", "v3": "#d9861c"}
    fig, axes = plt.subplots(len(lanes), 1, figsize=(12, 3.2 * len(lanes)), sharex=True, squeeze=False)
    for ax, (name, ss) in zip(axes[:, 0], lanes.items()):
        by_v = defaultdict(lambda: ([], []))
        for s in ss:
            if s["ok"]:
                by_v[s["v"] or name][0].append(s["t"] - t0)
                by_v[s["v"] or name][1].append(max(s["lat"], 0.05))
        for v, (xs, ys) in sorted(by_v.items()):
            ax.scatter(xs, ys, s=4, color=colors.get(v, "#6b7280"), label=f"{v} ok")
        fx = [s["t"] - t0 for s in ss if not s["ok"]]
        if fx:
            ax.scatter(fx, [ax.get_ylim()[1] if ax.has_data() else 1000] * len(fx), marker="|", s=80,
                       color="#d93636", label="falha")
        for i in incs[name]:
            end = (i["end"] or ss[-1]["t"]) - t0
            ax.axvspan(i["start"] - t0, end, color="#d93636", alpha=0.12, lw=0)
        for mt, label in marks:
            ax.axvline(mt - t0, color="#2563eb", ls="--", lw=1)
        ax.set_yscale("log")
        ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:g}"))
        ax.yaxis.set_minor_formatter(matplotlib.ticker.NullFormatter())
        ax.set_ylabel("latência (ms)")
        ax.set_title({"app": "Aplicação (plano de dados)", "api": "API do Kubernetes (plano de controle)"}.get(name, name),
                     loc="left", fontsize=11)
        ax.legend(loc="upper right", fontsize=8, markerscale=2, frameon=False)
        ax.grid(alpha=.25)
    top = axes[0, 0]
    for mt, label in marks:
        top.annotate(label, (mt - t0, 1), xycoords=("data", "axes fraction"), rotation=90, va="top", ha="right",
                     fontsize=7, color="#2563eb")
    axes[-1, 0].set_xlabel("tempo desde o início da medição (s)")
    fig.tight_layout()
    out_png = path.with_name(path.stem + "_linha.png")
    fig.savefig(out_png, dpi=150)
    print(f"→ {out_png}")


if __name__ == "__main__":
    main()
