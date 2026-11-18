"""
Gráfico do load test: junta o histórico do Locust (stats_stats_history.csv) com o registro do HPA (hpa.csv)
no mesmo eixo de tempo e salva grafico.png na pasta do resultado.

  python plot.py load/results/<data-hora>     (o load/run.sh já chama, em container)
"""
import csv
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

pasta = Path(sys.argv[1])

# Locust: só a linha "Aggregated" de cada segundo
loc = [r for r in csv.DictReader(open(pasta / "stats_stats_history.csv")) if r["Name"] == "Aggregated"]
t0 = int(loc[0]["Timestamp"])


def num(v):
    try:
        return float(v)
    except ValueError:
        return None


lt = [(int(r["Timestamp"]) - t0) / 60 for r in loc]
usuarios = [int(r["User Count"]) for r in loc]
rps = [float(r["Requests/s"]) for r in loc]
falhas = [float(r["Failures/s"]) for r in loc]
p95 = [num(r["95%"]) for r in loc]

hpa = [r for r in csv.DictReader(open(pasta / "hpa.csv")) if r["atuais"]]
ht = [(int(r["timestamp"]) - t0) / 60 for r in hpa]
atuais = [int(r["atuais"]) for r in hpa]
cpu = [num(r["cpu_percent"]) for r in hpa]

fig, (a1, a2, a3) = plt.subplots(3, 1, figsize=(11, 9), sharex=True)
fig.suptitle("Load test pelo gateway: carga x HPA (kind)")

a1.plot(lt, usuarios, color="tab:blue", label="usuários do Locust")
a1.set_ylabel("usuários")
b1 = a1.twinx()
b1.step(ht, atuais, where="post", color="tab:red", label="pods do gateway")
b1.set_ylabel("pods do gateway")
b1.set_ylim(0, 11)
a1.legend(handles=a1.get_lines() + b1.get_lines(), loc="upper left")

a2.plot(ht, cpu, color="tab:orange", label="CPU média do gateway (% do request)")
a2.axhline(50, color="gray", linestyle="--", label="alvo do HPA (50%)")
a2.set_ylabel("CPU %")
a2.legend(loc="upper left")

a3.plot(lt, rps, color="tab:green", label="requisições/s")
a3.plot(lt, falhas, color="tab:red", label="falhas/s")
a3.set_ylabel("req/s")
b3 = a3.twinx()
b3.plot(lt, p95, color="tab:purple", alpha=0.6, label="latência p95 (ms)")
b3.set_ylabel("p95 (ms)")
a3.legend(handles=a3.get_lines() + b3.get_lines(), loc="upper left")
a3.set_xlabel("minutos desde o início")

for a in (a1, a2, a3):
    a.grid(alpha=0.3)
fig.tight_layout()
fig.savefig(pasta / "grafico.png", dpi=110)
print("grafico.png salvo em", pasta)
