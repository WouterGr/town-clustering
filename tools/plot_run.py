"""Draw a Town Clustering run from the game log.

The mod logs PARAMS, BOUNDS, CENTRE, CLUSTER, SHAPE, TOWN and SPACING lines
prefixed with [town-clustering]. This reads them from stdout.txt (or from a file
holding just those lines) and draws the map: towns coloured by cluster, the map
border, each cluster's shape (or, for logs from before shapes, its expected
radius), and the spacing figures in the title.

Usage:
    python tools/plot_run.py <stdout.txt or log extract> [out.png] [title]

Needs matplotlib (pip install matplotlib). If the log holds more than one run,
the last one is drawn.
"""

import math
import re
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import Circle, Ellipse, Rectangle  # noqa: E402


def parse(path):
    """Return the last run in the log as a dict."""
    run = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "[town-clustering]" not in line:
                continue
            body = line.split("[town-clustering]", 1)[1].strip()
            if body.startswith("PARAMS"):
                run = {"params": body[len("PARAMS"):].strip(), "bounds": None,
                       "centres": {}, "clusters": {}, "shapes": {}, "towns": [], "spacing": [],
                       "lake": None}
                continue
            if run is None:
                continue
            m = re.match(r"BOUNDS x=(-?\d+)\.\.(-?\d+) y=(-?\d+)\.\.(-?\d+)", body)
            if m:
                run["bounds"] = tuple(int(v) for v in m.groups())
                continue
            m = re.match(r"CENTRE (\d+) x=(-?\d+) y=(-?\d+)", body)
            if m:
                run["centres"][int(m[1])] = (int(m[2]), int(m[3]))
                continue
            m = re.match(r"CLUSTER (\d+) spacing=(\d+) radius=(\d+) towns=(\d+)", body)
            if m:
                run["clusters"][int(m[1])] = dict(spacing=int(m[2]), radius=int(m[3]), towns=int(m[4]))
                continue
            m = re.match(r"SHAPE (\d+) kind=(\w+) aspect=([\d.]+) angle=(-?[\d.]+) "
                         r"anchors=(\S+) path=(\S+)", body)
            if m:
                anchors = [tuple(float(v) for v in a.split(":")) for a in m[5].split("|")]
                path = [] if m[6] == "-" else [tuple(float(v) for v in p.split(":")) for p in m[6].split("|")]
                run["shapes"][int(m[1])] = dict(kind=m[2], aspect=float(m[3]), angle=float(m[4]),
                                                anchors=anchors, path=path)
                continue
            m = re.match(r"LAKE x=(-?\d+) y=(-?\d+) r=(\d+)", body)
            if m:
                run["lake"] = tuple(int(v) for v in m.groups())
                continue
            m = re.match(r"TOWN (\w+) c=(\d+) x=(-?\d+) y=(-?\d+)", body)
            if m:
                run["towns"].append((m[1], int(m[2]), int(m[3]), int(m[4])))
                continue
            if body.startswith("SPACING"):
                run["spacing"].append(body[len("SPACING"):].strip())
    if run is None or not run["towns"]:
        sys.exit("No Town Clustering run with TOWN lines found in " + path)
    return run


def draw_shape(ax, sh, colour, km):
    """Outline a cluster's shape: what the placement aimed at, not a boundary."""
    style = dict(fill=False, ls="--", lw=0.8, ec=colour, alpha=0.8)
    anchors = sh["anchors"]
    cx, cy, r = anchors[0][0], anchors[0][1], anchors[0][2]
    if sh["kind"] == "elongated":
        stretch = math.sqrt(sh["aspect"])
        ax.add_patch(Ellipse((cx / km, cy / km), 2 * r * stretch / km, 2 * r / stretch / km,
                             angle=math.degrees(sh["angle"]), **style))
    elif sh["kind"] == "chain" and sh["path"]:
        ax.plot([p[0] / km for p in sh["path"]], [p[1] / km for p in sh["path"]],
                ls="--", lw=1.0, color=colour, alpha=0.8)
    else:
        for i, a in enumerate(anchors):
            if sh["kind"] == "satellite" and i > 0:
                ax.scatter(a[0] / km, a[1] / km, marker="+", s=60, color=colour, zorder=2)
                ax.plot([cx / km, a[0] / km], [cy / km, a[1] / km], ls=":", lw=0.6, color=colour)
            else:
                ax.add_patch(Circle((a[0] / km, a[1] / km), a[2] / km, **style))


def draw(run, out, title):
    cmap = plt.get_cmap("tab10")
    km = 1000.0

    xs = [t[2] for t in run["towns"]]
    ys = [t[3] for t in run["towns"]]
    if run["bounds"]:
        x0, x1, y0, y1 = run["bounds"]
    else:
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)

    width, height = (x1 - x0) / km, (y1 - y0) / km
    scale = 10.0 / max(width, height)
    fig, ax = plt.subplots(figsize=(max(5.0, width * scale + 1.5), max(5.0, height * scale + 2.0)))

    if run["bounds"]:
        ax.add_patch(Rectangle((x0 / km, y0 / km), width, height, fill=False, lw=1.5, ec="black"))

    if run["lake"]:
        lx, ly, lr = run["lake"]
        ax.add_patch(Circle((lx / km, ly / km), lr / km, color="#bcd7f0", zorder=1))

    if run["shapes"]:
        for i, sh in run["shapes"].items():
            draw_shape(ax, sh, cmap((i - 1) % 10), km)
    else:
        for i, c in run["clusters"].items():
            if i in run["centres"]:
                cx, cy = run["centres"][i]
                ax.add_patch(Circle((cx / km, cy / km), c["radius"] / km, fill=False, ls="--",
                                    lw=0.8, ec=cmap((i - 1) % 10), alpha=0.7))

    style = {
        "stay": dict(marker="o", s=55, edgecolors="black", linewidths=0.6),
        "move": dict(marker="o", s=30, edgecolors="none"),
        "isolated": dict(marker="^", s=55, edgecolors="black", linewidths=0.6),
    }
    for kind in ("move", "stay", "isolated"):
        for k, c, x, y in run["towns"]:
            if k != kind:
                continue
            col = "lightgray" if kind == "isolated" else cmap((c - 1) % 10)
            ax.scatter(x / km, y / km, color=col, zorder=3, **style[kind])

    for i, (x, y) in run["centres"].items():
        ax.scatter(x / km, y / km, marker="x", s=110, color="black", zorder=4)
        label = str(i)
        if i in run["shapes"]:
            label += " " + run["shapes"][i]["kind"]
        ax.annotate(label, (x / km, y / km), xytext=(6, 6), textcoords="offset points",
                    fontsize=8.5, weight="bold")

    pad = 0.5
    ax.set_xlim(min(x0, min(xs)) / km - pad, max(x1, max(xs)) / km + pad)
    ax.set_ylim(min(y0, min(ys)) / km - pad, max(y1, max(ys)) / km + pad)
    ax.set_aspect("equal")
    ax.grid(alpha=0.3)
    ax.set_xlabel("x (km)")
    ax.set_ylabel("y (km)")

    lines = [title or "Town Clustering run", run["params"]] + run["spacing"]
    ax.set_title("\n".join(lines), fontsize=8.5, loc="left")

    ax.legend(handles=[
        Line2D([], [], marker="o", ls="", color="gray", markeredgecolor="black", label="stayed"),
        Line2D([], [], marker="o", ls="", color="gray", label="moved to cluster"),
        Line2D([], [], marker="^", ls="", color="lightgray", markeredgecolor="black", label="isolated"),
        Line2D([], [], marker="x", ls="", color="black", label="cluster centre"),
        Line2D([], [], ls="--", color="gray", label="cluster shape / expected radius"),
    ], loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=8)

    fig.tight_layout()
    fig.savefig(out, dpi=110, bbox_inches="tight")
    print(f"{len(run['towns'])} towns, {len(run['centres'])} clusters -> {out}")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "town_clustering_run.png"
    title = sys.argv[3] if len(sys.argv) > 3 else ""
    draw(parse(src), out, title)


if __name__ == "__main__":
    main()
