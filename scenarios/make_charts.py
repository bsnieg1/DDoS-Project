#!/usr/bin/env python3
"""
Charts from the 3D matrix (traffic type x server variant x botnet size).

Input:  raw.csv  (long format, 1 row = 1 repetition), columns:
        metric_scenario,mode,variant,ver,hard,size,rep,
        cpu_victim_pct,cpu_bots_sum_pct,active_conns,ngx_req_delta,ngx_accept_delta

Output (in target directory):
  summary.csv            aggregate (mean/std over reps) per (mode,variant,size) - NUMERICAL DATA
  01_cpu_vs_size.png      victim CPU% vs botnet size, lines=variant, panels=mode
  02_throughput_vs_size.png   nginx requests (delta) vs botnet size
  03_asymmetry_vs_size.png    cost asymmetry ratio (cpu_victim/cpu_bots) vs size
  04_variant_fingerprint.png  average CPU% per variant at largest size (hardening fingerprint)
  05_reqs_per_conn.png        requests/connection (Rapid Reset signature: many streams/1 connection)

Usage:
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
    "old_normal": "old (1.25.1) no hardening",
    "old_hardened": "old (1.25.1) + hardening",
    "new_normal": "new (1.27) no hardening",
    "new_hardened": "new (1.27) + hardening",
}
MODE_LABELS = {"attack": "ATTACK (Rapid Reset)", "legit": "LEGIT TRAFFIC (h2load)"}
COLORS = {
    "old_normal": "#d62728",
    "old_hardened": "#ff9896",
    "new_normal": "#1f77b4",
    "new_hardened": "#2ca02c",
}


def main():
    if len(sys.argv) != 3:
        print("Usage: python make_charts.py <raw.csv> <outdir>")
        sys.exit(2)
    raw_path, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    df = pd.read_csv(raw_path)
    df["variant"] = pd.Categorical(df["variant"], categories=VARIANT_ORDER, ordered=True)

    # --- Cleanup: under heavy load (especially "legit" mode with many thousands
    # of concurrent h2load connections) curl to /status sometimes times out
    # (nginx temporarily saturated). The measurement script in that case defaulted
    # to 0, which produced nonsensical, strongly negative request deltas. CPU% is
    # measured via an INDEPENDENT channel (docker stats), so it remains reliable
    # even in those rows - we only mark stub_status columns as missing (NaN),
    # instead of silently plotting fictitious numbers.
    bad_status = df["ngx_accept_delta"] <= 0
    n_bad = int(bad_status.sum())
    if n_bad:
        print(f"[!] {n_bad}/{len(df)} rows have failed stub_status reads (curl timeout under load) "
              f"-> ngx_req_delta/ngx_accept_delta/active_conns/reqs_per_conn marked as missing. "
              f"cpu_victim_pct/cpu_bots_sum_pct (docker stats, independent channel) remain valid.")
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
    print(f"[*] Saved numerical data (aggregate) -> {summary_path}")

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
            ax.set_xlabel("botnet size (number of bots)")
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
        "Victim CPU% vs botnet size (mean +/- std. dev. across repetitions)",
        "Victim CPU [%]", "01_cpu_vs_size.png",
    )
    plot_metric_vs_size(
        "ngx_req_delta_mean", "ngx_req_delta_std",
        "Nginx requests (delta in measurement window) vs botnet size",
        "Nginx requests / window", "02_throughput_vs_size.png",
    )
    plot_metric_vs_size(
        "asymmetry_mean", "asymmetry_std",
        "Cost asymmetry ratio: victim CPU% / SUM attacker fleet CPU%",
        "CPU_victim / CPU_bots (log)", "03_asymmetry_vs_size.png", logy=True,
    )

    # 04: hardening fingerprint - CPU at largest size, bar chart per variant x mode
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
    ax.set_ylabel("Victim CPU [%]")
    ax.set_title(f"Hardening fingerprint: victim CPU at botnet={max_size}")
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "04_variant_fingerprint.png"), dpi=150)
    plt.close(fig)
    print("[*] 04_variant_fingerprint.png")

    # 05: requests / connection (Rapid Reset signature) - attack only, if available
    if "attack" in df["mode"].unique():
        fig, ax = plt.subplots(figsize=(7, 5))
        attack_df = df[df["mode"] == "attack"]
        for variant in VARIANT_ORDER:
            vs = attack_df[attack_df["variant"] == variant]
            vs_agg = vs.groupby("size", observed=True)["reqs_per_conn"].mean().reset_index().sort_values("size")
            if vs_agg.empty:
                continue
            ax.plot(vs_agg["size"], vs_agg["reqs_per_conn"], marker="o", label=VARIANT_LABELS[variant], color=COLORS[variant])
        ax.set_xlabel("botnet size (number of bots)")
        ax.set_ylabel("nginx requests / new connection")
        ax.set_title("Rapid Reset signature: requests per connection (attack mode)")
        ax.legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, "05_reqs_per_conn.png"), dpi=150)
        plt.close(fig)
        print("[*] 05_reqs_per_conn.png")

    print(f"\n[*] Done. Charts + summary.csv in: {outdir}")


if __name__ == "__main__":
    main()
