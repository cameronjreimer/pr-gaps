"""Cut LAS files into 1 km buckets per campaign, once, for the island-wide run.

    python python/retile.py PR_12March2017_Guayama/PR_12March2017_Guayama_l0s1.las.gz
    python python/retile.py PATH/TO/file.las.gz ...     # several files, one after another
    python python/retile.py --list-tasks                # pending files of the Maria campaigns
    python python/retile.py --check CAMPAIGN ...        # counts per campaign from the done markers
    python python/retile.py --check CAMPAIGN --deep     # ...and every record exactly once

hpc-scaling-plan.md §4.2. Each task streams one LAS file once and writes its points to

    $PR_GAPS_RETILED/<campaign>/<tile>/<file stem>.laz     (default $PR_GAPS_DATA/interim/retiled)

one part per tile the file touches, so tasks for neighbouring strips never write to the
same file. Tiles are the work units' 1 km grid in EPSG:32620, half-open
(tile = floor(x / 1000), floor(y / 1000)), so every point lands in exactly one tile.

Points keep every class and their source point format, scale and offset, so coordinates
are bit-identical to the raw file. Two extra-byte fields say where each came from:
source_file (the file's row in <campaign>/files.csv, the campaign's LAS files from the
inventory in name order) and source_index (its record number in that file).

A file is done when <campaign>/done/<stem>.json exists and matches the source's size and
mtime; it is written last, after the parts are renamed into place, so a killed task
leaves no marker and is redone in full. Exits 1 if any file failed.
"""

import argparse
import copy
import json
import os
import sys
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import (  # noqa: E402  (first: it loads CloudComPy before conflicting libraries)
    CHUNK_SIZE, GLIHT, REPO, RETILED, file_signature, materialized_las, write_json,
)
from plan_units import TILE_M, tile_id  # noqa: E402

INVENTORY = REPO / "derived" / "inventory"
EXTRA_DIMS = (("source_file", np.uint16), ("source_index", np.uint32))


def stem(name):
    for suffix in (".las.gz", ".laz.gz", ".las", ".laz"):
        if name.lower().endswith(suffix):
            return name[: -len(suffix)]
    raise ValueError(f"Not a LAS/LAZ file name: {name}")


def inventory_las():
    files = pd.read_csv(INVENTORY / "pr_files.csv")
    return files[files["subdir"].str.rstrip("/") == "lidar/las"]


def campaign_files(campaign, las=None):
    """The campaign's LAS file names in name order; the row is the file's source_file id."""
    las = inventory_las() if las is None else las
    names = sorted(las.loc[las.campaign == campaign, "name"])
    if not names:
        raise ValueError(f"No LAS files for {campaign} in {INVENTORY / 'pr_files.csv'}")
    return names


def write_files_csv(campaign, names):
    """Identical content from every task, so concurrent writers can't disagree."""
    path = RETILED / campaign / "files.csv"
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(f"files.csv.{os.getpid()}.part")
    pd.DataFrame({"source_file": range(len(names)), "name": names}).to_csv(partial, index=False)
    partial.replace(path)


def resolve(task):
    """A LAS path, or '<campaign>/<file name>' under $PR_GAPS_GLIHT."""
    path = Path(task)
    if not path.is_file():
        campaign, _, name = task.partition("/")
        path = Path(GLIHT) / campaign / "lidar" / "las" / name
    path = path.resolve(strict=True)
    return path.parent.parent.parent.name, path


def marker_path(campaign, name):
    return RETILED / campaign / "done" / f"{stem(name)}.json"


def is_done(campaign, path):
    marker = marker_path(campaign, path.name)
    if not marker.is_file():
        return False
    return json.loads(marker.read_text(encoding="utf-8"))["source"] == file_signature(path)


def bucket_header(source_header):
    import laspy

    header = laspy.LasHeader(version=source_header.version,
                             point_format=source_header.point_format.id)
    header.scales = source_header.scales
    header.offsets = source_header.offsets
    header.add_extra_dims([laspy.ExtraBytesParams(name, dtype) for name, dtype in EXTRA_DIMS])
    return header


def retile(campaign, path, file_id, chunk_size=CHUNK_SIZE):
    import laspy

    name, base = path.name, stem(path.name)
    root = RETILED / campaign
    # Parts from an earlier, unfinished or outdated run of this file.
    for old in root.glob(f"E*_N*/{base}.laz*"):
        old.unlink()
    marker_path(campaign, name).unlink(missing_ok=True)

    counts, writers = {}, {}
    offset = 0
    with ExitStack() as stack:
        reader = stack.enter_context(laspy.open(stack.enter_context(materialized_las(path))))
        expected = reader.header.point_count
        header = bucket_header(reader.header)
        for points in reader.chunk_iterator(chunk_size):
            x, y = np.asarray(points.x), np.asarray(points.y)
            if not (np.isfinite(x).all() and np.isfinite(y).all()):
                raise ValueError(f"Nonfinite coordinates in {path} near record {offset}")
            tiles = np.column_stack((np.floor(x / TILE_M), np.floor(y / TILE_M))).astype(np.int64)
            keys, inverse = np.unique(tiles, axis=0, return_inverse=True)
            inverse = inverse.ravel()
            for k, (tx, ty) in enumerate(keys):
                mask = inverse == k
                tile = tile_id(int(tx) * TILE_M, int(ty) * TILE_M)
                if tile not in writers:
                    part = root / tile / f"{base}.laz.part"
                    part.parent.mkdir(parents=True, exist_ok=True)
                    writers[tile] = stack.enter_context(
                        laspy.open(part, mode="w", header=copy.deepcopy(header), do_compress=True))
                    counts[tile] = 0
                selected = points[mask]
                record = laspy.ScaleAwarePointRecord.zeros(len(selected), header=header)
                for dimension in points.point_format.dimension_names:
                    record[dimension] = selected[dimension]
                record["source_file"] = np.full(len(selected), file_id, np.uint16)
                record["source_index"] = (np.flatnonzero(mask) + offset).astype(np.uint32)
                writers[tile].write_points(record)
                counts[tile] += len(selected)
            offset += len(points)
    if offset != expected or sum(counts.values()) != expected:
        raise ValueError(f"{path}: header says {expected:,} points, read {offset:,}, "
                         f"wrote {sum(counts.values()):,}")
    for tile in counts:
        (root / tile / f"{base}.laz.part").replace(root / tile / f"{base}.laz")
    marker_path(campaign, name).parent.mkdir(parents=True, exist_ok=True)
    write_json(marker_path(campaign, name), {
        "source": file_signature(path), "source_file": file_id, "header_count": expected,
        "tiles": dict(sorted(counts.items())),
        "written_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    })
    return expected, counts


def maria_tasks():
    """'<campaign>/<name>' for every LAS file of a campaign in a Maria pair (>= 25 ha)."""
    pairs = pd.read_csv(INVENTORY / "pr_repeat_campaign_pairs.csv")
    maria = pairs[(pairs.epoch_a == "2017_pre") & (pairs.epoch_b == "2018_post")
                  & (pairs.overlap_ha >= 25)]
    las = inventory_las()
    las = las[las.campaign.isin(set(maria.campaign_a) | set(maria.campaign_b))]
    return sorted(f"{row.campaign}/{row.name}" for row in las.itertuples())


def check_campaign(campaign, deep=False):
    """Every inventory file has a marker, parts exist with the marked counts, totals add up."""
    import laspy

    problems, total = [], 0
    names = campaign_files(campaign)
    for file_id, name in enumerate(names):
        marker = marker_path(campaign, name)
        if not marker.is_file():
            problems.append(f"{name}: not retiled")
            continue
        done = json.loads(marker.read_text(encoding="utf-8"))
        if sum(done["tiles"].values()) != done["header_count"]:
            problems.append(f"{name}: parts sum to {sum(done['tiles'].values()):,}, "
                            f"header {done['header_count']:,}")
        seen = np.zeros(done["header_count"], np.uint8) if deep else None
        for tile, count in done["tiles"].items():
            part = RETILED / campaign / tile / f"{stem(name)}.laz"
            if not part.is_file():
                problems.append(f"{name}: missing part {tile}")
                continue
            if deep:
                points = laspy.read(part)
                if not (np.asarray(points.source_file) == file_id).all():
                    problems.append(f"{name}: wrong source_file in {tile}")
                np.add.at(seen, np.asarray(points.source_index), 1)
                if len(points) != count:
                    problems.append(f"{name}: {tile} holds {len(points):,}, marker says {count:,}")
            else:
                with laspy.open(part) as reader:
                    if reader.header.point_count != count:
                        problems.append(f"{name}: {tile} holds {reader.header.point_count:,}, "
                                        f"marker says {count:,}")
        if deep and not (seen == 1).all():
            problems.append(f"{name}: {int((seen == 0).sum()):,} records missing, "
                            f"{int((seen > 1).sum()):,} duplicated")
        total += done["header_count"]
    for problem in problems[:20]:
        print(f"   {problem}")
    print(f"{campaign}: {len(names)} files, {total:,} points; "
          + ("OK" if not problems else f"{len(problems)} problem(s)"))
    return not problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tasks", nargs="*", help="LAS paths or <campaign>/<file name>")
    parser.add_argument("--list-tasks", action="store_true",
                        help="print the Maria LAS files not yet retiled, one per line")
    parser.add_argument("--check", action="store_true", help="check the named campaigns instead")
    parser.add_argument("--deep", action="store_true", help="with --check: read every record")
    args = parser.parse_args()

    if args.list_tasks:
        for task in maria_tasks():
            campaign, path = task.split("/")[0], Path(GLIHT) / task.split("/")[0] / "lidar" / "las" / task.split("/")[1]
            if not (path.is_file() and is_done(campaign, path)):
                print(task)
        return 0
    if args.check:
        return 0 if all([check_campaign(c, args.deep) for c in args.tasks]) else 1

    las, failed = inventory_las(), 0
    for task in args.tasks:
        try:
            campaign, path = resolve(task)
            names = campaign_files(campaign, las)
            if path.name not in names:
                raise ValueError(f"{path.name} is not in the inventory for {campaign}")
            write_files_csv(campaign, names)
            if is_done(campaign, path):
                print(f"{campaign}/{path.name}: already retiled")
                continue
            count, tiles = retile(campaign, path, names.index(path.name))
            print(f"{campaign}/{path.name}: {count:,} points into {len(tiles)} tiles")
        except Exception as error:  # carry on with the other files, then fail
            failed += 1
            print(f"{task}: FAILED: {error}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
