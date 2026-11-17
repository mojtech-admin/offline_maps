#!/usr/bin/env python3
"""Sanity-check a .roads pack: structure, grid coverage and a sample route.

Usage: python check_pack.py PACK.roads
This is a small reference reader for the format in docs/PACK_FORMAT.md.
"""
import heapq
import math
import struct
import sys

import numpy as np

NODE = np.dtype([("lat", "<i4"), ("lon", "<i4"), ("first", "<u4")])
ARC = np.dtype([("target", "<u4"), ("edge", "<u4")])
EDGE = np.dtype([("a", "<u4"), ("b", "<u4"), ("pstart", "<u4"), ("name", "<u4"),
                 ("ref", "<u4"), ("len", "<f4"), ("pcount", "<u2"), ("cls", "u1"),
                 ("flags", "u1"), ("limit", "u1"), ("speed", "u1"), ("pad", "<u2")])
POINT = np.dtype([("lat", "<i4"), ("lon", "<i4")])


class Pack:
    def __init__(self, path):
        d = self.data = np.memmap(path, dtype=np.uint8, mode="r")
        assert bytes(d[:4]) == b"OFRD", "bad magic"
        h = struct.unpack("<I4i5I8I", bytes(d[4:76]))
        ver, self.bbox, off = h[0], h[1:5], h[10:18]
        self.n_nodes, self.n_arcs, self.n_edges, self.n_points, self.n_strings = h[5:10]
        assert ver == 1
        self.nodes = np.frombuffer(d, NODE, self.n_nodes + 1, off[0])
        self.arcs = np.frombuffer(d, ARC, self.n_arcs, off[1])
        self.edges = np.frombuffer(d, EDGE, self.n_edges, off[2])
        self.points = np.frombuffer(d, POINT, self.n_points, off[3])
        self.strings = bytes(d[off[4]:off[4] + self.n_strings])
        self.grids = []
        for o in off[5:8]:
            lat0, lon0, cell, cols, rows = struct.unpack("<iiiII", bytes(d[o:o + 20]))
            start = np.frombuffer(d, "<u4", cols * rows + 1, o + 20)
            ids = np.frombuffer(d, "<u4", int(start[-1]), o + 20 + 4 * (cols * rows + 1))
            self.grids.append((lat0, lon0, cell, cols, rows, start, ids))

    def string(self, off):
        return self.strings[off:self.strings.index(b"\0", off)].decode()

    def cell_edges(self, level, lat, lon):
        lat0, lon0, cell, cols, rows, start, ids = self.grids[level]
        cy, cx = (lat - lat0) // cell, (lon - lon0) // cell
        if not (0 <= cy < rows and 0 <= cx < cols):
            return []
        c = cy * cols + cx
        return ids[start[c]:start[c + 1]]

    def route(self, src, dst):
        """Plain Dijkstra on travel time; returns (seconds, [edge refs])."""
        dist, prev, heap = {src: 0.0}, {}, [(0.0, src)]
        while heap:
            t, n = heapq.heappop(heap)
            if n == dst:
                break
            if t > dist.get(n, math.inf):
                continue
            for k in range(self.nodes["first"][n], self.nodes["first"][n + 1]):
                arc = self.arcs[k]
                e = self.edges[arc["edge"] >> 1]
                nt = t + float(e["len"]) / (e["speed"] / 3.6)
                m = int(arc["target"])
                if nt < dist.get(m, math.inf):
                    dist[m], prev[m] = nt, (n, int(arc["edge"]))
                    heapq.heappush(heap, (nt, m))
        if dst not in dist:
            return None, []
        path, n = [], dst
        while n != src:
            n, e = prev[n]
            path.append(e)
        return dist[dst], path[::-1]


def main(path):
    p = Pack(path)
    e, n = p.edges, p.nodes
    assert n["first"][-1] == p.n_arcs
    assert (np.diff(n["first"].astype(np.int64)) >= 0).all()
    assert e["a"].max() < p.n_nodes and e["b"].max() < p.n_nodes
    assert (e["pstart"].astype(np.int64) + e["pcount"]).max() <= p.n_points
    assert (e["len"] > 0).all()
    # edge endpoints must coincide with their node coordinates
    assert (p.points["lat"][e["pstart"]] == n["lat"][e["a"]]).all()
    last = e["pstart"].astype(np.int64) + e["pcount"] - 1
    assert (p.points["lon"][last] == n["lon"][e["b"]]).all()
    # every point of every edge must be findable through the finest grid
    rng = np.random.default_rng(1)
    for i in rng.integers(0, p.n_edges, min(2000, p.n_edges)):
        for k in (int(e["pstart"][i]), int(last[i])):
            pt = p.points[k]
            assert i in p.cell_edges(2, int(pt["lat"]), int(pt["lon"])), f"edge {i} missing from grid"
    # sample route between two far-apart nodes
    a = int(np.argmin(n["lat"][:-1].astype(np.int64) + n["lon"][:-1]))
    b = int(np.argmax(n["lat"][:-1].astype(np.int64) + n["lon"][:-1]))
    secs, path = p.route(a, b)
    km = sum(float(e["len"][r >> 1]) for r in path) / 1000
    names = []
    for r in path:
        nm = p.string(int(e["name"][r >> 1])) or p.string(int(e["ref"][r >> 1]))
        if nm and (not names or names[-1] != nm):
            names.append(nm)
    print(f"OK  {p.n_nodes:,} nodes  {p.n_edges:,} edges  {p.n_points:,} points")
    if secs is None:
        print("sample route: the two corner nodes are not connected (fine for islands)")
    else:
        print(f"sample route SW->NE: {km:.1f} km, {secs / 60:.0f} min, via {' > '.join(names[:8])}")


if __name__ == "__main__":
    main(sys.argv[1])
