"""
Render the headline result as a static chart for the README.

The interactive dashboard lives on Tableau Public, but a README needs a picture
that renders on GitHub without anyone clicking anything — and one that is
regenerated from the same warehouse as everything else, so it can never drift
away from what the pipeline actually produces.

    python -m hrrp.chart
"""

from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from . import db  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / "docs" / "readmission_by_cohort.png"

LABELS = {
    "HF": "Heart failure", "COPD": "COPD", "PNEUMONIA": "Pneumonia",
    "AMI": "Acute MI", "CABG": "CABG", "THA_TKA": "Hip / knee replacement",
    "OTHER": "All other inpatient",
}

INK = "#1b2430"
ABOVE = "#c0392b"     # worse than the national benchmark
BELOW = "#2e7d5b"     # better than the national benchmark
MARK = "#5b6670"


def render(conn, out_path: Path = OUT):
    _, rows = db.query(conn, """
        SELECT hrrp_condition, index_admissions, rate_pct, national_rate_pct
        FROM vw_hrrp_cohort_summary
        ORDER BY rate_pct ASC NULLS FIRST""")

    names = [LABELS.get(r[0], r[0]) for r in rows]
    counts = [r[1] for r in rows]
    rates = [float(r[2] or 0) for r in rows]
    natl = [float(r[3] or 0) for r in rows]
    colors = [ABOVE if a > b else BELOW for a, b in zip(rates, natl)]
    y = range(len(rows))

    fig, ax = plt.subplots(figsize=(9, 4.6), dpi=160)
    ax.barh(list(y), rates, height=0.62, color=colors, zorder=3)

    # National benchmark as a tick per cohort — the comparison that decides
    # whether a cohort is a penalty risk.
    for i, b in enumerate(natl):
        ax.plot([b, b], [i - 0.34, i + 0.34], color=MARK, lw=2.0,
                zorder=4, solid_capstyle="butt")

    for i, r in enumerate(rates):
        ax.text(r + 0.45, i, f"{r:.1f}%", va="center", ha="left",
                fontsize=9.5, color=INK, fontweight="600", zorder=5)

    # Denominators belong in the tick label — as separate text they collide with
    # the category names, and a rate without its n is not reportable anyway.
    ax.set_yticks(list(y), [f"{name}\nn={n:,}" for name, n in zip(names, counts)],
                  fontsize=9.5, color=INK)
    ax.set_xlabel("30-day all-cause readmission rate", fontsize=9.5, color=MARK)
    ax.set_xlim(0, max(rates + natl) * 1.22)
    ax.xaxis.set_major_formatter(lambda v, _: f"{v:.0f}%")
    ax.tick_params(axis="x", labelsize=9, colors=MARK)
    ax.grid(axis="x", color="#dfe3e8", lw=0.8, zorder=0)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color("#dfe3e8")

    ax.set_title("30-day readmission rate by HRRP cohort",
                 fontsize=13, color=INK, fontweight="600", loc="left", pad=26)
    ax.text(0, 1.045,
            "Red = above the CMS national benchmark  ·  green = below  ·  "
            "grey tick = benchmark   |   synthetic data",
            transform=ax.transAxes, fontsize=8.5, color=MARK)

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_path


def main():
    with db.connect() as conn:
        print(f"wrote {render(conn)}")


if __name__ == "__main__":
    main()
