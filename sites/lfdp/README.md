# LFDP study area

`canopy.py` expects `lfdp_buf50.gpkg` here: the Luquillo Forest Dynamics Plot boundary
buffered by 50 m, as a polygon layer with a CRS. Copy it from the server copy of the
pipeline (`lfdp/lfdp_buf50.gpkg` beside the original `canopy.py`). It's small and
hand-made rather than derived from raw data, so it's committed here.

Only 2017 points inside the polygon are analysed. 2018 points from the whole tiles stay in
the reference, so edge points are compared with their true nearest neighbours.
