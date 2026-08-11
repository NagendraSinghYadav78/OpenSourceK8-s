"""
analysis.py

Reproduces all descriptive statistics, inferential tests, and Figure 1
reported in "Empirical Evaluation of Rancher Desktop for Local
Kubernetes-Based Web Application Deployment and Orchestration".

Usage:
    Place this script in the same folder as the four result CSVs from
    each tool's `results/` and `results-minikube/` folders (see README),
    or edit the file paths below, then run:

        pip install pandas numpy scipy matplotlib --break-system-packages
        python analysis.py

Outputs:
    - Prints all descriptive statistics (n, mean, median, SD, 95% CI)
      for both tools across all four metrics (Table 2/3 in the paper).
    - Prints Mann-Whitney U test results with Holm-Bonferroni correction
      and rank-biserial effect sizes (Table 4).
    - Prints the paired Wilcoxon signed-rank test for RQ3
      (scale-out vs. scale-in, within Rancher Desktop).
    - Prints the 95% Clopper-Pearson CI for the deployment success rate.
    - Regenerates Figure 1 (distribution boxplots) as distribution_figure.png.
"""

import numpy as np
import pandas as pd
from scipy import stats

# ---------------------------------------------------------------------------
# Raw trial-level data (reproduced here for standalone use; also available
# as raw CSVs in the project repository: deployment_timing.csv,
# recovery_timing.csv, scaling_timing.csv, success_rate.csv, and their
# results-minikube/ equivalents).
# ---------------------------------------------------------------------------

RANCHER = {
    "deploy_warm": [3.3, 2.67, 2.12, 2.25, 2.28, 4.84, 4.71, 2.12, 2.32, 2.18, 4.93, 4.93, 2.17, 2.25],
    "deploy_cold": [5.27],
    "recovery":    [2.01, 1.88, 1.92, 1.93, 2.13, 1.91, 2.29, 2.18, 1.82, 1.76, 2.27, 1.73, 1.76, 1.81, 2.17],
    "scaleout":    [4.99, 4.78, 7.97, 10.38, 7.46, 7.52, 7.58, 7.75, 7.81, 7.58, 7.57, 7.56, 7.81, 7.56, 7.52],
    "scalein":     [2.11, 2.16, 2.33, 2.19, 2.18, 2.21, 2.42, 2.23, 2.24, 2.21, 2.12, 2.22, 2.27, 2.26, 2.29],
    "success":     [4.89, 2.19, 3.02, 2.37, 4.81, 2.21, 4.91, 2.16, 2.31, 4.95, 2.25, 2.17, 2.21, 5.03, 4.83],  # all 15 succeeded
}

MINIKUBE = {
    "deploy_warm": [4.97, 2.18, 2.19, 2.34, 2.12, 2.13, 2.16, 2.31, 2.23, 7.43, 2.18, 2.3, 2.1, 2.22],
    "deploy_cold": [93.73],
    "recovery":    [2.07, 1.94, 1.94, 1.86, 1.97, 1.85, 1.97, 1.96, 1.86, 1.96, 1.97, 2.17, 1.84, 2.24, 1.82],
    "scaleout":    [4.87, 10.13, 15.81, 10.41, 13.23, 10.23, 12.93, 13.2, 13.2, 13.03, 10.3, 9.8, 9.98, 9.67, 10.18],
    "scalein":     [2.19, 2.13, 2.41, 2.1, 2.02, 2.41, 2.25, 2.46, 2.39, 2.21, 1.99, 2.2, 2.1, 2.48, 2.3],
}


def descriptive_stats(data, label):
    """Print n, mean, median, SD, min, max, 95% CI (Student-t) for a sample."""
    data = np.asarray(data, dtype=float)
    n = len(data)
    mean = np.mean(data)
    median = np.median(data)
    sd = np.std(data, ddof=1) if n > 1 else float("nan")
    if n > 1:
        se = sd / np.sqrt(n)
        ci = stats.t.interval(0.95, n - 1, loc=mean, scale=se)
    else:
        ci = (float("nan"), float("nan"))
    print(f"{label:45s} n={n:2d}  mean={mean:6.2f}  median={median:6.2f}  "
          f"SD={sd:5.2f}  min={data.min():6.2f}  max={data.max():6.2f}  "
          f"95% CI=[{ci[0]:.2f}, {ci[1]:.2f}]")
    return mean, median, sd, ci


def rank_biserial_mw(x, y):
    """Rank-biserial correlation effect size for a Mann-Whitney U test.
    r = 1 - 2U/(n1*n2). Positive r indicates x (first sample) has the
    lower/faster values under the convention used in this analysis.
    """
    n1, n2 = len(x), len(y)
    u_stat, _ = stats.mannwhitneyu(x, y, alternative="two-sided")
    return 1 - (2 * u_stat) / (n1 * n2), u_stat


def holm_bonferroni(pvalues, labels, alpha=0.05):
    """Holm-Bonferroni step-down correction. Returns dict of label -> adjusted p."""
    order = np.argsort(pvalues)
    n = len(pvalues)
    adjusted = [None] * n
    running_max = 0.0
    for rank, idx in enumerate(order, start=1):
        candidate = pvalues[idx] * (n - rank + 1)
        running_max = max(running_max, candidate)
        running_max = min(running_max, 1.0)
        adjusted[idx] = running_max
    return dict(zip(labels, adjusted))


def clopper_pearson_ci(successes, trials, alpha=0.05):
    """Exact 95% Clopper-Pearson confidence interval for a binomial proportion."""
    lo = stats.beta.ppf(alpha / 2, successes, trials - successes + 1) if successes > 0 else 0.0
    hi = stats.beta.ppf(1 - alpha / 2, successes + 1, trials - successes) if successes < trials else 1.0
    return lo, hi


def main():
    print("=" * 100)
    print("DESCRIPTIVE STATISTICS (Table 3): Rancher Desktop")
    print("=" * 100)
    descriptive_stats(RANCHER["deploy_warm"], "Apply-to-Pod-Ready latency (warm)")
    descriptive_stats(RANCHER["deploy_cold"], "Apply-to-Pod-Ready latency (cold, n=1)")
    descriptive_stats(RANCHER["recovery"], "Pod-deletion recovery latency")
    descriptive_stats(RANCHER["scaleout"], "Scale-out latency (1->3)")
    descriptive_stats(RANCHER["scalein"], "Scale-in latency (3->1)")

    print("\n" + "=" * 100)
    print("DEPLOYMENT SUCCESS RATE (RQ4, separate dataset)")
    print("=" * 100)
    successes, trials = 15, 15
    lo, hi = clopper_pearson_ci(successes, trials)
    print(f"Success rate: {successes}/{trials} = {successes/trials*100:.1f}%  "
          f"95% Clopper-Pearson CI=[{lo*100:.1f}%, {hi*100:.1f}%]")

    print("\n" + "=" * 100)
    print("RQ3: PAIRED WILCOXON SIGNED-RANK TEST (scale-out vs. scale-in, Rancher Desktop)")
    print("=" * 100)
    w_stat, p_exact = stats.wilcoxon(RANCHER["scaleout"], RANCHER["scalein"], alternative="two-sided")
    diffs = np.array(RANCHER["scaleout"]) - np.array(RANCHER["scalein"])
    n_pos, n_neg = np.sum(diffs > 0), np.sum(diffs < 0)
    r_paired = (n_pos - n_neg) / len(diffs)
    print(f"W = {w_stat}, exact two-sided p = {p_exact:.6f}")
    print(f"Matched-pairs rank-biserial r = {r_paired:.2f} "
          f"(n_pos={n_pos}, n_neg={n_neg}, n_ties={len(diffs)-n_pos-n_neg})")

    print("\n" + "=" * 100)
    print("COMPARATIVE EVALUATION (Table 4): Rancher Desktop vs. Minikube")
    print("Mann-Whitney U tests with Holm-Bonferroni correction across 4 comparisons")
    print("=" * 100)

    comparisons = {
        "Apply-to-Pod-Ready (warm)": (RANCHER["deploy_warm"], MINIKUBE["deploy_warm"]),
        "Pod-deletion recovery":     (RANCHER["recovery"], MINIKUBE["recovery"]),
        "Scale-out":                 (RANCHER["scaleout"], MINIKUBE["scaleout"]),
        "Scale-in":                  (RANCHER["scalein"], MINIKUBE["scalein"]),
    }

    raw_pvalues, u_stats, effect_sizes = {}, {}, {}
    for label, (r_data, m_data) in comparisons.items():
        r_eff, u = rank_biserial_mw(r_data, m_data)
        _, p = stats.mannwhitneyu(r_data, m_data, alternative="two-sided")
        raw_pvalues[label] = p
        u_stats[label] = u
        effect_sizes[label] = r_eff

    adjusted = holm_bonferroni(list(raw_pvalues.values()), list(raw_pvalues.keys()))

    for label, (r_data, m_data) in comparisons.items():
        r_med, r_iqr = np.median(r_data), np.percentile(r_data, 75) - np.percentile(r_data, 25)
        m_med, m_iqr = np.median(m_data), np.percentile(m_data, 75) - np.percentile(m_data, 25)
        print(f"\n{label}:")
        print(f"  Rancher : n={len(r_data)}, median={r_med:.2f} [IQR={r_iqr:.2f}]")
        print(f"  Minikube: n={len(m_data)}, median={m_med:.2f} [IQR={m_iqr:.2f}]")
        print(f"  U={u_stats[label]:.1f}, raw p={raw_pvalues[label]:.6f}, "
              f"Holm-adjusted p={adjusted[label]:.6f}, rank-biserial r={effect_sizes[label]:.2f}")

    print("\n" + "=" * 100)
    print("FIGURE 1: Regenerating distribution boxplots -> distribution_figure.png")
    print("=" * 100)
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        fig, axes = plt.subplots(2, 2, figsize=(9, 7))
        datasets = [
            ("Apply-to-Pod-Ready Latency (warm)", RANCHER["deploy_warm"], MINIKUBE["deploy_warm"], axes[0, 0]),
            ("Pod-deletion Recovery Latency", RANCHER["recovery"], MINIKUBE["recovery"], axes[0, 1]),
            ("Scale-out Latency (1->3)", RANCHER["scaleout"], MINIKUBE["scaleout"], axes[1, 0]),
            ("Scale-in Latency (3->1)", RANCHER["scalein"], MINIKUBE["scalein"], axes[1, 1]),
        ]
        for title, r_data, m_data, ax in datasets:
            bp = ax.boxplot([r_data, m_data], tick_labels=["Rancher\nDesktop", "Minikube"],
                             patch_artist=True, widths=0.5, showmeans=True,
                             meanprops={"marker": "D", "markerfacecolor": "white",
                                        "markeredgecolor": "black", "markersize": 5})
            for patch, color in zip(bp["boxes"], ["#4C72B0", "#DD8452"]):
                patch.set_facecolor(color)
                patch.set_alpha(0.6)
            for i, data in enumerate([r_data, m_data], start=1):
                x = np.random.normal(i, 0.04, size=len(data))
                ax.scatter(x, data, alpha=0.5, s=12, color="black", zorder=3)
            ax.set_title(title, fontsize=10)
            ax.set_ylabel("Seconds", fontsize=9)
            ax.tick_params(labelsize=9)
            ax.grid(axis="y", linestyle="--", alpha=0.4)
        fig.suptitle("Rancher Desktop vs. Minikube: Trial-Level Distributions (n = 14-15 per group)",
                      fontsize=11, y=0.99)
        plt.tight_layout(rect=[0, 0, 1, 0.96])
        plt.savefig("distribution_figure.png", dpi=200, bbox_inches="tight")
        print("Saved distribution_figure.png")
    except ImportError:
        print("matplotlib not installed; skipping figure regeneration. "
              "Run: pip install matplotlib --break-system-packages")


if __name__ == "__main__":
    main()
