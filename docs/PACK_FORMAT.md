# `.roads` pack format (version 1)

Little-endian. Coordinates are `int32` degrees × 1e7. Written by `tools/build_pack.py`, read by
`App/Core/RoadPack.swift` and `tools/check_pack.py`.

## Header (128 bytes)

| Offset | Type | Field |
| --- | --- | --- |
| 0 | char[4] | `OFRD` |
| 4 | u32 | version = 1 |
| 8 | i32 × 4 | min lat, min lon, max lat, max lon |
| 24 | u32 | node count N |
| 28 | u32 | arc count |
| 32 | u32 | edge count |
| 36 | u32 | point count |
| 40 | u32 | string pool bytes |
| 44 | u32 × 8 | file offsets: nodes, arcs, edges, points, strings, grid 0, grid 1, grid 2 |

## Sections

- **Nodes** (N + 1 records, 12 bytes): `i32 lat, i32 lon, u32 firstArc`. Arcs leaving node *n* are
  `firstArc[n] ..< firstArc[n+1]`.
- **Arcs** (8 bytes): `u32 targetNode, u32 edgeRef` where `edgeRef = edge << 1 | reversed`.
- **Edges** (32 bytes), one per stretch of road between two junctions:
  `u32 a, u32 b, u32 pointStart, u32 nameOffset, u32 refOffset, f32 lengthMetres,
  u16 pointCount, u8 class, u8 flags, u8 limitMph, u8 routingSpeedKph, u16 pad`.
  Class: 0 motorway, 1 trunk, 2 primary, 3 secondary, 4 tertiary, 5 residential, 6 service.
  Flags: 1 one-way (a→b), 2 ramp/link, 4 roundabout, 8 toll, 16 tunnel, 32 bridge.
- **Points** (8 bytes): `i32 lat, i32 lon`. An edge's geometry is `pointCount` points from
  `pointStart`, running a→b, end points included.
- **Strings**: NUL-terminated UTF-8; offset 0 is the empty string.
- **Grids** (three): `i32 lat0, i32 lon0, i32 cellSize, u32 cols, u32 rows`, then
  `u32 cellStart[cols*rows + 1]`, then `u32 edgeIds[]`. Grid 0: 0.5° cells, classes 0–1.
  Grid 1: 0.1° cells, classes 0–3. Grid 2: 0.02° cells, all classes.

## `.search.sqlite`

Table `place(id, kind, name, detail, lat, lon, rank)` with kinds `city`, `street`, `address`,
`poi`, and an FTS5 index `place_fts(name, detail)`.
