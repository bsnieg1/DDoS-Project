#!/usr/bin/env python3
"""
Wykresy z matrycy 3D (typ ruchu x wariant serwera x rozmiar botnetu).

Wejscie:  raw.csv  (long format, 1 wiersz = 1 powtorzenie), kolumny:
          metric_scenario,mode,variant,ver,hard,size,rep,
          cpu_victim_pct,cpu_bots_sum_pct,active_conns,ngx_req_delta,ngx_accept_delta

Wyjscie (w katalogu docelowym):
  summary.csv            agregat (mean/std po rep) per (mode,variant,size) - DANE NUMERYCZNE
  01_cpu_vs_size.png      CPU% ofiary vs rozmiar botnetu, linie=wariant, panele=mode
  02_throughput_vs_size.png   zadania nginx (delta) vs rozmiar botnetu
  03_asymmetry_vs_size.png    wspolczynnik asymetrii kosztu (cpu_victim/cpu_bots) vs rozmiar
  04_variant_fingerprint.png  sredni CPU% per wariant przy najwiekszym rozmiarze (odcisk hardeningu)
  05_reqs_per_conn.png        zadania/polaczenie (sygnatura Rapid Reset: wiele strumieni/1 polaczenie)

Uzycie:
  python make_charts.py <raw.csv> <outdir>
"""
import sys
import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VARIANT_ORDER = ["old_normal", "old_hardened", "new_normal", "new_hardened"]
VARIANT_LABELS = {
    "old_normal": "stary (1.25.1) bez hardeningu",
    "old_hardened": "stary (1.25.1) + hardening",
    "new_normal": "nowy (1.27) bez hardeningu",
    "new_hardened": "nowy (1.27) + hardening",
}
MODE_LABELS = {"attack": "ATAK (Rapid Reset)", "legit": "RUCH LEGALNY (h2load)"}
COLORS = {
    "old_normal": "#d62728",
    "old_hardened": "#ff9896",
    "new_normal": "#1f77b4",
    "new_hardened": "#2ca02c",
}


def main():
    if len(sys.argv) != 3:
        print("Uzycie: python make_charts.py <raw.csv> <outdir>")
        sys.exit(2)
    raw_path, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    df = pd.read_csv(raw_path)
    df["variant"] = pd.Categorical(df["variant"], categories=VARIANT_ORDER, ordered=True)

    # --- Czyszczenie: pod duzym obciazeniem (zwlaszcza tryb "legit" z wieloma
    # tysiacami rownoczesnych polaczen h2load) curl do /status czasem timeoutuje
    # (nginx chwilowo nasycony). Skrypt pomiarowy w takim wypadku domyslnie
    # wstawial 0, co dawalo bezsensowne, mocno ujemne delty zadan. CPU% jest
    # mierzony NIEZALEZNYM kanalem (docker stats), wiec zostaje wiarygodny
    # nawet w tych wierszach - tylko kolumny ze stub_status oznaczamy jako
    # brakujace (NaN), zamiast cicho rysowac fikcyjne liczby.
    bad_status = df["ngx_accept_delta"] <= 0
    n_bad = int(bad_status.sum())
    if n_bad:
        print(f"[!] {n_bad}/{len(df)} wierszy ma nieudany odczyt stub_status (curl timeout pod obciazeniem) "
              f"-> ngx_req_delta/ngx_accept_delta/active_conns/reqs_per_conn oznaczone jako brakujace. "
              f"cpu_victim_pct/cpu_bots_sum_pct (docker stats, niezalezny kanal) pozostaja wazne.")
    for col in ["ngx_req_delta", "ngx_accept_delta", "active_conns"]:
        df[col] = df[col].astype("float64")
        df.loc[bad_status, col] = np.nan

    df["asymmetry"] = df["cpu_victim_pct"] / df["cpu_bots_sum_pct"].replace(0, np.nan)
    df["reqs_per_conn"] = df["ngx_req_delta"] / df["ngx_accept_delta"].replace(0, np.nan)

    agg = (
        df.groupby(["mode", "variant", "size"], observed=True)
        .agg(
            cpu_victim_mean=("cpu_victim_pct", "mean"),
            cpu_victim_std=("cpu_victim_pct", "std"),
            cpu_bots_mean=("cpu_bots_sum_pct", "mean"),
            cpu_bots_std=("cpu_bots_sum_pct", "std"),
            ngx_req_delta_mean=("ngx_req_delta", "mean"),
            ngx_req_delta_std=("ngx_req_delta", "std"),
            asymmetry_mean=("asymmetry", "mean"),
            asymmetry_std=("asymmetry", "std"),
            reqs_per_conn_mean=("reqs_per_conn", "mean"),
            n_reps=("rep", "count"),
        )
        .reset_index()
    )
    summary_path = os.path.join(outdir, "summary.csv")
    agg.to_csv(summary_path, index=False)
    print(f"[*] Zapisano dane numeryczne (agregat) -> {summary_path}")

    modes = [m for m in ["attack", "legit"] if m in agg["mode"].unique()]

    def plot_metric_vs_size(metric_mean, metric_std, title, ylabel, fname, logy=False):
        fig, axes = plt.subplots(1, len(modes), figsize=(6 * len(modes), 5), sharey=True)
        if len(modes) == 1:
            axes = [axes]
        for ax, mode in zip(axes, modes):
            sub = agg[agg["mode"] == mode]
            for variant in VARIANT_ORDER:
                vs = sub[sub["variant"] == variant].sort_values("size")
                if vs.empty:
                    continue
                ax.errorbar(
                    vs["size"], vs[metric_mean], yerr=vs[metric_std].fillna(0),
                    marker="o", label=VARIANT_LABELS[variant], color=COLORS[variant],
                    capsize=3,
                )
            ax.set_title(MODE_LABELS.get(mode, mode))
            ax.set_xlabel("rozmiar botnetu (liczba botow)")
            if logy:
                ax.set_yscale("log")
        axes[0].set_ylabel(ylabel)
        axes[0].legend(fontsize=8, loc="best")
        fig.suptitle(title)
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, fname), dpi=150)
        plt.close(fig)
        print(f"[*] {fname}")

    plot_metric_vs_size(
        "cpu_victim_mean", "cpu_victim_std",
        "CPU% ofiary vs rozmiar botnetu (srednia +/- odch. std. z powtorzen)",
        "CPU ofiary [%]", "01_cpu_vs_size.png",
    )
    plot_metric_vs_size(
        "ngx_req_delta_mean", "ngx_req_delta_std",
        "Zadania nginx (delta w oknie pomiarowym) vs rozmiar botnetu",
        "Zadania nginx / okno", "02_throughput_vs_size.png",
    )
    plot_metric_vs_size(
        "asymmetry_mean", "asymmetry_std",
        "Wspolczynnik asymetrii kosztu: CPU% ofiary / SUMA CPU% floty atakujacej",
        "CPU_victim / CPU_bots (log)", "03_asymmetry_vs_size.png", logy=True,
    )

    # 04: fingerprint hardeningu - CPU przy najwiekszym rozmiarze, bar chart per wariant x mode
    max_size = agg["size"].max()
    fp = agg[agg["size"] == max_size]
    fig, ax = plt.subplots(figsize=(8, 5))
    width = 0.35
    x = range(len(VARIANT_ORDER))
    for i, mode in enumerate(modes):
        vals = [
            fp[(fp["variant"] == v) & (fp["mode"] == mode)]["cpu_victim_mean"].mean()
            for v in VARIANT_ORDER
        ]
        ax.bar([xi + i * width for xi in x], vals, width, label=MODE_LABELS.get(mode, mode))
    ax.set_xticks([xi + width * (len(modes) - 1) / 2 for xi in x])
    ax.set_xticklabels([VARIANT_LABELS[v] for v in VARIANT_ORDER], rotation=20, ha="right", fontsize=8)
    ax.set_ylabel("CPU ofiary [%]")
    ax.set_title(f"Odcisk hardeningu: CPU ofiary przy botnet={max_size}")
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "04_variant_fingerprint.png"), dpi=150)
    plt.close(fig)
    print("[*] 04_variant_fingerprint.png")

    # 05: zadania / polaczenie (sygnatura Rapid Reset) - tylko attack, jesli dostepny
    if "attack" in df["mode"].unique():
        fig, ax = plt.subplots(figsize=(7, 5))
        attack_df = df[df["mode"] == "attack"]
        for variant in VARIANT_ORDER:
            vs = attack_df[attack_df["variant"] == variant]
            vs_agg = vs.groupby("size", observed=True)["reqs_per_conn"].mean().reset_index().sort_values("size")
            if vs_agg.empty:
                continue
            ax.plot(vs_agg["size"], vs_agg["reqs_per_conn"], marker="o", label=VARIANT_LABELS[variant], color=COLORS[variant])
        ax.set_xlabel("rozmiar botnetu (liczba botow)")
        ax.set_ylabel("zadania nginx / nowe polaczenie")
        ax.set_title("Sygnatura Rapid Reset: zadania na polaczenie (tryb attack)")
        ax.legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, "05_reqs_per_conn.png"), dpi=150)
        plt.close(fig)
        print("[*] 05_reqs_per_conn.png")

    print(f"\n[*] Gotowe. Wykresy + summary.csv w: {outdir}")


if __name__ == "__main__":
    main()
