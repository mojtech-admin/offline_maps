#!/usr/bin/env python3
"""Build an OffRoute offline map pack from an OpenStreetMap extract.

Usage:  python build_pack.py INPUT.osm.pbf OUTPUT_PREFIX
Writes: OUTPUT_PREFIX.roads          (binary road graph + geometry + spatial grids)
        OUTPUT_PREFIX.search.sqlite  (places, streets, addresses, POIs with FTS5 index)

The .roads layout is documented in docs/PACK_FORMAT.md and mirrored by
App/Core/RoadPack.swift. Keep the two in sync.

Map data (c) OpenStreetMap contributors, ODbL 1.0.
"""
import array
import os
import sqlite3
import struct
import sys

import numpy as np
import osmium

MAGIC = b"OFRD"
VERSION = 1
SCALE = 1e7  # coordinates are stored as int32 degrees * 1e7

# class id, default routing speed (km/h)
CLASSES = {
    "motorway": (0, 105), "trunk": (1, 90), "primary": (2, 70),
    "secondary": (3, 60), "tertiary": (4, 50),
    "unclassified": (5, 40), "residential": (5, 35),
    "living_street": (6, 15), "service": (6, 15),
}
F_ONEWAY, F_LINK, F_ROUNDABOUT, F_TOLL, F_TUNNEL, F_BRIDGE = 1, 2, 4, 8, 16, 32
SKIP_SERVICE = {"parking_aisle", "driveway", "drive-through", "emergency_access"}
NO_ACCESS = {"no", "private", "agricultural", "forestry", "military"}

# (cell size in degrees, highest class id included)
GRIDS = [(0.5, 1), (0.1, 3), (0.02, 6)]

PLACE_RANK = {"city": 0, "town": 1, "village": 2, "suburb": 3, "hamlet": 4,
              "neighbourhood": 5}
POI_KEYS = ("amenity", "tourism", "shop", "leisure")
POI_AMENITY = {"fuel", "charging_station", "restaurant", "fast_food", "cafe",
               "hospital", "pharmacy", "police", "bank", "atm", "parking",
               "school", "university", "library", "post_office", "fire_station",
               "rest_area", "toilets"}


def parse_maxspeed(v):
    """Return the limit in mph (0 = unknown)."""
    if not v:
        return 0
    v = v.strip().lower()
    try:
        if v.endswith("mph"):
            mph = float(v[:-3])
        else:
            mph = float(v) * 0.621371  # bare numbers are km/h
    except ValueError:
        return 0
    return int(min(max(round(mph), 0), 120))


class Collector(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.refs = array.array("q")
        self.lat = array.array("i")
        self.lon = array.array("i")
        self.way_start = array.array("I")
        self.way_cls = array.array("B")
        self.way_flags = array.array("B")
        self.way_limit = array.array("B")
        self.way_speed = array.array("B")
        self.way_name = array.array("I")
        self.way_ref = array.array("I")
        self.strings = bytearray(b"\0")
        self.string_off = {"": 0}
        self.places = []   # (kind, name, detail, lat, lon, rank)

    def intern(self, s):
        off = self.string_off.get(s)
        if off is None:
            off = len(self.strings)
            self.strings += s.encode("utf-8") + b"\0"
            self.string_off[s] = off
        return off

    # ---- search rows -------------------------------------------------
    def search_row(self, tags, lat, lon):
        name = tags.get("name")
        place = tags.get("place")
        if place in PLACE_RANK and name:
            self.places.append(("city", name, place, lat, lon, PLACE_RANK[place]))
            return
        hn, street = tags.get("addr:housenumber"), tags.get("addr:street")
        if hn and street:
            city = tags.get("addr:city", "")
            self.places.append(("address", f"{hn} {street}", city, lat, lon, 8))
        if name:
            for k in POI_KEYS:
                v = tags.get(k)
                if v and (k != "amenity" or v in POI_AMENITY):
                    self.places.append(("poi", name, v.replace("_", " "), lat, lon, 7))
                    break

    def node(self, n):
        if len(n.tags) and n.location.valid():
            self.search_row(n.tags, n.location.lat, n.location.lon)

    # ---- roads -------------------------------------------------------
    def way(self, w):
        tags = w.tags
        hw = tags.get("highway")
        if hw is None:
            # buildings / areas that carry an address or a POI name
            if len(w.nodes) and ("addr:housenumber" in tags or "name" in tags):
                loc = w.nodes[0].location
                if loc.valid():
                    self.search_row(tags, loc.lat, loc.lon)
            return
        link = hw.endswith("_link")
        base = hw[:-5] if link else hw
        if base not in CLASSES or len(w.nodes) < 2:
            return
        if tags.get("access") in NO_ACCESS or tags.get("motor_vehicle") in NO_ACCESS \
                or tags.get("motorcar") in NO_ACCESS or tags.get("area") == "yes":
            return
        if base == "service" and tags.get("service") in SKIP_SERVICE:
            return
        cls, speed = CLASSES[base]
        flags = 0
        oneway = tags.get("oneway", "")
        roundabout = tags.get("junction") in ("roundabout", "circular")
        reverse = oneway in ("-1", "reverse")
        if oneway in ("yes", "true", "1") or reverse or roundabout or \
                (base == "motorway" and oneway != "no"):
            flags |= F_ONEWAY
        if link:
            flags |= F_LINK
            speed = min(speed, 50)
        if roundabout:
            flags |= F_ROUNDABOUT
            speed = min(speed, 30)
        if tags.get("toll") == "yes":
            flags |= F_TOLL
        if tags.get("tunnel") in ("yes", "building_passage"):
            flags |= F_TUNNEL
        if tags.get("bridge") == "yes":
            flags |= F_BRIDGE
        limit = parse_maxspeed(tags.get("maxspeed"))
        if limit:
            speed = max(5, min(130, int(limit * 1.609 * 0.95)))
        if not all(nd.location.valid() for nd in w.nodes):
            return
        pts = [(nd.ref, nd.location.y, nd.location.x) for nd in w.nodes]
        if reverse:
            pts.reverse()
        self.way_start.append(len(self.refs))
        for ref, y, x in pts:
            self.refs.append(ref)
            self.lat.append(y)
            self.lon.append(x)
        self.way_cls.append(cls)
        self.way_flags.append(flags)
        self.way_limit.append(limit)
        self.way_speed.append(speed)
        self.way_name.append(self.intern(tags.get("name", "")))
        self.way_ref.append(self.intern(tags.get("ref", "").replace(";", " / ")))


def haversine(lat1, lon1, lat2, lon2):
    r = 6371008.8
    p1, p2 = np.radians(lat1), np.radians(lat2)
    a = np.sin((p2 - p1) / 2) ** 2 + \
        np.cos(p1) * np.cos(p2) * np.sin(np.radians(lon2 - lon1) / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


def expand_ranges(start, count):
    """Indices start[i]..start[i]+count[i]-1 for all i, plus the owner i of each."""
    total = int(count.sum())
    owner = np.repeat(np.arange(len(start), dtype=np.int64), count)
    first = np.repeat(np.cumsum(count) - count, count)
    idx = np.arange(total, dtype=np.int64) - first + np.repeat(start.astype(np.int64), count)
    return idx, owner


def build_grid(cell_deg, max_cls, bbox, lat, lon, e_pstart, e_pcount, e_cls):
    cell = int(round(cell_deg * SCALE))
    lat0, lon0 = bbox[0], bbox[1]
    cols = (bbox[3] - lon0) // cell + 1
    rows = (bbox[2] - lat0) // cell + 1
    sel_all = np.nonzero(e_cls <= max_cls)[0]
    parts = []
    for c0 in range(0, len(sel_all), 200_000):  # chunked to bound memory
        sel = sel_all[c0:c0 + 200_000]
        # one entry per segment, subdivided so no grid cell is skipped
        idx, owner = expand_ranges(e_pstart[sel], e_pcount[sel] - 1)
        la1, lo1 = lat[idx].astype(np.int64), lon[idx].astype(np.int64)
        la2, lo2 = lat[idx + 1].astype(np.int64), lon[idx + 1].astype(np.int64)
        steps = np.maximum(np.abs(la2 - la1), np.abs(lo2 - lo1)) // (cell // 2) + 1
        sidx, sown = expand_ranges(np.zeros(len(idx), dtype=np.int64), steps + 1)
        t = sidx / np.repeat(steps, steps + 1)
        sla = la1[sown] + (la2 - la1)[sown] * t
        slo = lo1[sown] + (lo2 - lo1)[sown] * t
        cy = ((sla - lat0) // cell).astype(np.int64)
        cx = ((slo - lon0) // cell).astype(np.int64)
        edge = sel[owner[sown]].astype(np.int64)
        parts.append(np.unique(((cy * cols + cx) << 32) | edge))
    keys = np.unique(np.concatenate(parts)) if parts else np.zeros(0, dtype=np.int64)
    cells = keys >> 32
    edges = (keys & 0xFFFFFFFF).astype("<u4")
    counts = np.bincount(cells, minlength=rows * cols)
    start = np.zeros(rows * cols + 1, dtype="<u4")
    np.cumsum(counts, out=start[1:])
    header = struct.pack("<iiiII", lat0, lon0, cell, cols, rows)
    return header + start.tobytes() + edges.tobytes()


def build(src, prefix):
    col = Collector()
    col.apply_file(src, locations=True)
    nways = len(col.way_start)
    if nways == 0:
        sys.exit("no drivable roads found in " + src)
    refs = np.frombuffer(col.refs, dtype=np.int64)
    lat = np.frombuffer(col.lat, dtype=np.int32)
    lon = np.frombuffer(col.lon, dtype=np.int32)
    npts = len(refs)
    wstart = np.frombuffer(col.way_start, dtype=np.uint32).astype(np.int64)
    wend = np.append(wstart[1:], npts)  # exclusive
    way_of = np.repeat(np.arange(nways), wend - wstart)

    # graph nodes = way endpoints + every OSM node used more than once
    uniq, first, inverse, counts = np.unique(
        refs, return_index=True, return_inverse=True, return_counts=True)
    is_node = counts[inverse] > 1
    is_node[wstart] = True
    is_node[wend - 1] = True
    u_is_node = np.zeros(len(uniq), dtype=bool)
    u_is_node[inverse[is_node]] = True
    u_node_id = np.cumsum(u_is_node) - 1
    node_count = int(u_is_node.sum())
    node_first = first[u_is_node]
    node_lat, node_lon = lat[node_first], lon[node_first]

    # edges = runs between consecutive graph nodes of the same way
    pos = np.nonzero(is_node)[0]
    same = way_of[pos[:-1]] == way_of[pos[1:]]
    p0, p1 = pos[:-1][same], pos[1:][same]
    seg = haversine(lat[:-1] / SCALE, lon[:-1] / SCALE, lat[1:] / SCALE, lon[1:] / SCALE)
    cum = np.concatenate(([0.0], np.cumsum(seg)))
    raw_len = cum[p1] - cum[p0]
    # OSM sometimes repeats a node inside a way: that gives a zero-length loop, which is dropped.
    keep = ~((inverse[p0] == inverse[p1]) & (raw_len < 0.05))
    p0, p1, raw_len = p0[keep], p1[keep], raw_len[keep]
    e_way = way_of[p0]
    e_a = u_node_id[inverse[p0]].astype("<u4")
    e_b = u_node_id[inverse[p1]].astype("<u4")
    e_pstart = p0.astype("<u4")
    e_pcount = (p1 - p0 + 1)
    assert e_pcount.max() < 65536
    # two different nodes mapped at the same spot still join roads; give the link a token length
    e_len = np.maximum(raw_len, 0.1).astype("<f4")
    e_cls = np.frombuffer(col.way_cls, dtype=np.uint8)[e_way]
    e_flags = np.frombuffer(col.way_flags, dtype=np.uint8)[e_way]
    edge_count = len(e_a)

    edges = np.zeros(edge_count, dtype=np.dtype([
        ("a", "<u4"), ("b", "<u4"), ("pstart", "<u4"), ("name", "<u4"),
        ("ref", "<u4"), ("len", "<f4"), ("pcount", "<u2"), ("cls", "u1"),
        ("flags", "u1"), ("limit", "u1"), ("speed", "u1"), ("pad", "<u2")]))
    assert edges.dtype.itemsize == 32
    edges["a"], edges["b"], edges["pstart"] = e_a, e_b, e_pstart
    edges["name"] = np.frombuffer(col.way_name, dtype=np.uint32)[e_way]
    edges["ref"] = np.frombuffer(col.way_ref, dtype=np.uint32)[e_way]
    edges["len"], edges["pcount"] = e_len, e_pcount
    edges["cls"], edges["flags"] = e_cls, e_flags
    edges["limit"] = np.frombuffer(col.way_limit, dtype=np.uint8)[e_way]
    edges["speed"] = np.frombuffer(col.way_speed, dtype=np.uint8)[e_way]

    # directed arcs in CSR form
    eid = np.arange(edge_count, dtype=np.int64)
    two_way = (e_flags & F_ONEWAY) == 0
    src_n = np.concatenate((e_a, e_b[two_way])).astype(np.int64)
    dst_n = np.concatenate((e_b, e_a[two_way]))
    eref = np.concatenate((eid << 1, (eid[two_way] << 1) | 1))
    order = np.argsort(src_n, kind="stable")
    arcs = np.zeros(len(order), dtype=np.dtype([("target", "<u4"), ("edge", "<u4")]))
    arcs["target"], arcs["edge"] = dst_n[order], eref[order]
    first_arc = np.zeros(node_count + 1, dtype=np.int64)
    np.cumsum(np.bincount(src_n, minlength=node_count), out=first_arc[1:])
    nodes = np.zeros(node_count + 1, dtype=np.dtype(
        [("lat", "<i4"), ("lon", "<i4"), ("first", "<u4")]))
    nodes["lat"][:-1], nodes["lon"][:-1] = node_lat, node_lon
    nodes["first"] = first_arc

    points = np.zeros(npts, dtype=np.dtype([("lat", "<i4"), ("lon", "<i4")]))
    points["lat"], points["lon"] = lat, lon
    bbox = (int(lat.min()), int(lon.min()), int(lat.max()), int(lon.max()))
    strings = bytes(col.strings)
    strings += b"\0" * (-len(strings) % 4)
    grids = [build_grid(c, m, bbox, lat, lon, e_pstart.astype(np.int64),
                        e_pcount.astype(np.int64), e_cls) for c, m in GRIDS]

    sections = [nodes.tobytes(), arcs.tobytes(), edges.tobytes(),
                points.tobytes(), strings] + grids
    offsets, off = [], 128
    for s in sections:
        offsets.append(off)
        off += len(s)
    if off >= 2 ** 32:
        sys.exit("pack exceeds 4 GB")
    header = MAGIC + struct.pack("<I4i5I8I", VERSION, *bbox, node_count, len(arcs),
                                 edge_count, npts, len(strings), *offsets)
    header += b"\0" * (128 - len(header))
    with open(prefix + ".roads", "wb") as f:
        f.write(header)
        for s in sections:
            f.write(s)

    build_search(col, prefix, edges, lat, lon)
    print(f"{prefix}: {node_count:,} nodes, {edge_count:,} edges, {npts:,} points, "
          f"{os.path.getsize(prefix + '.roads') / 1e6:.1f} MB roads, "
          f"{os.path.getsize(prefix + '.search.sqlite') / 1e6:.1f} MB search")


def build_search(col, prefix, edges, lat, lon):
    rows = list(col.places)
    cities = [(r[3], r[4], r[1]) for r in rows if r[0] == "city" and r[5] <= 2]

    # one row per street name per ~5 km cell, located at an edge midpoint
    named = np.nonzero(edges["name"] != 0)[0]
    mid = edges["pstart"][named].astype(np.int64) + edges["pcount"][named] // 2
    mlat, mlon = lat[mid] / SCALE, lon[mid] / SCALE
    key = (edges["name"][named].astype(np.int64) << 32) | \
          ((np.floor(mlat / 0.05).astype(np.int64) & 0xFFFF) << 16) | \
          (np.floor(mlon / 0.05).astype(np.int64) & 0xFFFF)
    _, keep = np.unique(key, return_index=True)
    strings = bytes(col.strings)
    for i in keep:
        off = int(edges["name"][named[i]])
        name = strings[off:strings.index(b"\0", off)].decode("utf-8")
        rows.append(("street", name, "", float(mlat[i]), float(mlon[i]), 6))

    # fill the "detail" column with the nearest town where it is empty
    if cities:
        from scipy.spatial import cKDTree
        cl = np.array([(c[0], c[1] * np.cos(np.radians(c[0]))) for c in cities])
        tree = cKDTree(cl)
        need = [i for i, r in enumerate(rows) if r[0] in ("street", "address") and not r[2]]
        if need:
            q = np.array([(rows[i][3], rows[i][4] * np.cos(np.radians(rows[i][3])))
                          for i in need])
            _, nearest = tree.query(q)
            for i, j in zip(need, nearest):
                r = rows[i]
                rows[i] = (r[0], r[1], cities[j][2], r[3], r[4], r[5])

    path = prefix + ".search.sqlite"
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript("""
        PRAGMA journal_mode=OFF; PRAGMA page_size=4096;
        CREATE TABLE place(id INTEGER PRIMARY KEY, kind TEXT, name TEXT, detail TEXT,
                           lat REAL, lon REAL, rank INTEGER);
        CREATE VIRTUAL TABLE place_fts USING fts5(name, detail, content='place',
            content_rowid='id', tokenize='unicode61 remove_diacritics 2', prefix='2 3');
    """)
    db.executemany("INSERT INTO place(kind,name,detail,lat,lon,rank) VALUES(?,?,?,?,?,?)", rows)
    db.execute("INSERT INTO place_fts(rowid,name,detail) SELECT id,name,detail FROM place")
    db.execute("CREATE INDEX place_city ON place(rank, lat, lon) WHERE kind='city'")
    db.commit()
    db.execute("VACUUM")
    db.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build(sys.argv[1], sys.argv[2])
