\# 1. List all PR campaigns and files --> pr\_files.csv + pr\_campaigns.csv

gl\_step\_inventory                     (02)

&#x20;a. gl\_init\_dirs                      (00 config)

&#x20;  a.1 gl\_paths                       (00 config)

&#x20;    a.1.1 gl\_data\_root               (00 config)

&#x20;      a.1.1.1 gl\_code\_root           (00 config)

&#x20;    a.1.2 gl\_code\_root               (00 config)

&#x20;b. gl\_list\_campaingns                (02)

&#x20;  b.1 gl\_index                       (01)

&#x20;    b.1.1 gl\_paths                   (00 config)

&#x20;    b.1.2 gl\_cache\_key               (01)

&#x20;    b.1.3 gl\_empty\_index             (01)

&#x20;    b.1.4 gl\_fetch\_text              (01)

&#x20;    b.1.5 gl\_empty\_index             (01)

&#x20;    b.1.6 gl\_parse\_index             (01)

&#x20;  b.2 gl\_parse\_campaign\_name         (02)

&#x20;  b.3 gl\_epoch                       (00 config)

&#x20;c. gl\_crawl\_all                      (02)

&#x20;  c.1 gl\_msg                         (00 helpers)

&#x20;  c.2 gl\_crawl\_campaign              (02)

&#x20;    c.2.1 gl\_index                   (01)

&#x20;    c.2.2 gl\_stack                   (00 helpers)

&#x20;  c.3 gl\_stack                       (00 helpers)

&#x20;d. gl\_campaign\_summary               (02)

&#x20;  d.1 gl\_summarise\_one\_campaign      (02)

&#x20;    d.1.1 gl\_las\_scheme              (02)

&#x20;  d.2 gl\_stack                       (00 helpers)

&#x20;e. gl\_write\_csv                      (00 helpers)

&#x20;f. gl\_msg                            (00 helpers)



\# 2. Download, merge, and write all campaign footprints --> pr\_footprints.gpkg + pr\_footprint\_summary.csv + print area summaries

gl\_step\_footprints                    (03)

&#x20;a. gl\_init\_dirs                      (00 config) --- not necessary?

&#x20;b. gl\_try                            (00 helpers)

&#x20;c. gl\_campaign\_tiles                 (03)

&#x20;  c.1 gl\_fetch\_shapefile             (03)

&#x20;    c.1.2 gl\_download                (01)

&#x20;    c.1.3 gl\_extract                 (01)

&#x20;  c.2 gl\_read\_vector                 (03)

&#x20;  c.3 gl\_data\_tile\_ids               (03)

&#x20;  c.4 gl\_las\_scheme                  (02)

&#x20;  c.5 gl\_area\_ha                     (00 helpers)

&#x20;d. gl\_campaign\_trajectory            (03) -- maybe not useful/necessary

&#x20;  d.1 gl\_fetch\_shapefile             (03)

&#x20;  d.2 gl\_read\_vector                 (03)

&#x20;e. gl\_stack                          (00 helpers)

&#x20;f. gl\_attach\_metadata                (00 helpers)

&#x20;g. gl\_dedupe\_trajectories            (03)

&#x20;h. gl\_campaign\_footprints            (03)

&#x20;  h.1 gl\_one\_footprint               (03)

&#x20;  h.2 gl\_stack                       (00 helpers)

&#x20;  h.3 gl\_area\_ha                     (00 helpers)

&#x20;i. gl\_attach\_metadata                (00 helpers)

&#x20;j. gl\_write\_gpkg                     (00 helpers)

&#x20;k. gl\_write\_csv                      (00 helpers)

&#x20;l. gl\_msg                            (00 helpers)



\# 3. Get repeat coverage and write out as a .gpkg

gl\_step\_repeat                        (04)

&#x20;a. gl\_init\_dirs                      (00 config)

&#x20;b. gl\_epoch\_coverage                 (04)

&#x20;  b.1 gl\_analysis\_subset             (00 helpers)

&#x20;  b.2 gl\_stack                       (00 helpers)

&#x20;  b.3 gl\_area\_ha                     (00 helpers)

&#x20;c. gl\_repeat\_coverage                (04)

&#x20;  c.1 gl\_polygon\_parts               (04)

&#x20;  c.2 gl\_area\_ha                     (00 helpers)

&#x20;d. gl\_repeat\_tiles                   (04)

&#x20;  d.1 gl\_analysis\_subset             (00 helpers)

&#x20;  d.2 gl\_polygon\_parts               (04)

&#x20;  d.3 gl\_area\_ha                     (00 helpers)

&#x20;e. gl\_campaign\_pairs                 (04)

&#x20;  e.1 gl\_analysis\_subset             (00 helpers)

&#x20;  e.2 gl\_pairs\_for\_epochs            (04)

&#x20;    e.2.1 gl\_epoch\_side              (04)

&#x20;    e.2.2 gl\_polygon\_parts           (04)

&#x20;    e.2.3 gl\_area\_ha                 (00 helpers)

&#x20;  e.3 gl\_stack                       (00 helpers)

&#x20;d. gl\_repeat\_summary\_table           (04)

&#x20;f. gl\_write\_gpkg                     (00 helpers)

&#x20;g. gl\_write\_csv                      (00 helpers)

&#x20;h. gl\_msg                            (00 helpers)



\# 4. Report coverage by epoch

gl\_step\_report                        (07)

&#x20;a. gl\_init\_dirs                      (00 config)

&#x20;b. gl\_inventory\_by\_epoch             (07)

&#x20;  b.1 gl\_analysis\_subset             (00 helpers)

&#x20;  b.2 gl\_summarise\_epoch             (07)

&#x20;  b.3 gl\_stack                       (00 helpers)

&#x20;c. gl\_plot\_epoch\_map                 (07)

&#x20;d. gl\_plot\_repeat\_map                (07)

&#x20;

\# 5. Plan and execute full data download

gl\_repeat\_campaigns                   (05)

gl\_plan\_download                      (05)

gl\_run\_download                       (05)

&#x20;a. gl\_plan\_size                      (05)

&#x20;b. gl\_download                       (00 helpers)

&#x20;c. gl\_stack                          (00 helpers)



\# 6. Get exact footprints from the CHM and rerun repeat coverage maps (must opt-in)

gl\_step\_refine\_chm                    (06)

&#x20;a. gl\_init\_dirs                      (00 config)

&#x20;b. gl\_try                            (00 helpers)

&#x20;c. gl\_chm\_footprint                  (06)

&#x20;  c.1 gl\_download                    (00 helpers)

&#x20;  c.2 gl\_extract                     (00 helpers)

&#x20;  c.3 gl\_try                         (00 helpers)

&#x20;  c.4 gl\_raster\_mask\_polygons        (06)

&#x20;  c.5 gl\_stack                       (00 helpers)

&#x20;d. gl\_stack                          (00 helpers)

&#x20;e. gl\_attach\_metadata                (00 helpers)

&#x20;f. gl\_carry\_forward\_refined          (06)

&#x20;  f.1 gl\_rename\_geometry             (00 helpers)

&#x20;g. gl\_epoch\_coverage                 (04)

&#x20;h. gl\_repeat\_coverage                (04)

&#x20;i. gl\_repeat\_summary\_table           (04)

&#x20;j. gl\_write\_gpkg                     (00 helpers)

&#x20;k. gl\_write\_csv                      (00 helpers)



functions to simplify:

* gl\_paths: wrap up with gl\_data\_root and code\_root
* gl\_index: wrap up gl\_empty\_index
* gl\_read\_vector: not necessary??
* gl\_polygon\_parts: could be simplified by checking geometry type in gl\_repeat\_coverage
* have step functions use filepaths instead of variables from ealier steps to make restarting easier
* why run init\_dirs every time?
* update plot\_repeat\_map to map specifically which footprints will work (epoch 1-2 + epoch 1-2-3)
* add PR outline to maps



00 helpers:

* gl\_analysis\_subset: get rows that belong in a coverage overlay
* gl\_area\_ha: return area of each polygon in ha
* gl\_attach\_metadata: attach campaign date, epoch, and site to table with campaign column
* gl\_download: download one file
* gl\_extract: unpack .zip or .tar.gz files
* gl\_msg: print message to console
* gl\_rename\_geometry: rename geometry column to avoid errors with rbind
* gl\_stack: combine a list of tables into one, skipping empty entries
* gl\_try: run an expression and return NULL if it fails
* gl\_write\_csv: write table to output dir
* gl\_write\_gpkg: write map layers to one .gpkg



00 config:

* gl\_code\_root: get code path for setup
* gl\_data\_root: get data path for setup
* gl\_epoch: return which epoch a directory corresponds to
* gl\_init\_dirs: create dirs for storing data/outputs
* gl\_paths: write paths relative to set working directory



01 http:

* gl\_cache\_key: turns url into safe file name
* gl\_empty\_index: output empty directory listing
* gl\_fetch\_text: fetch a url and return its text
* gl\_index: create dir for json cache files
* gl\_parse\_index: read one directory page into a table of name / is\_dir / size / date



02 crawl:

* gl\_crawl\_all: list all of the files for all campaigns in one dataframe
* gl\_crawl\_campaign: list every file for one campaign
* gl\_las\_scheme: return las file scheme (one file per flight or per map tile)
* gl\_list\_campaigns: list every campaign directory, dated and labelled by epoch
* gl\_parse\_campaign\_name: pull the date and site out of a campaign directory name (handles inconsistent naming)
* **gl\_step\_footprints**: download, process, merge, and save all campaign footprint to .gpkg
* **gl\_step\_inventory**: crawl through download page and list all campaigns and files
* gl\_summarise\_one\_campaign: return one row describing campaign files



03 footprints:

* gl\_campaign\_footprints: get one footprint for each campaign
* gl\_campaign\_tiles: get tile polygons for a single campaign, flagged with whether LAS was delivered
* gl\_campaign\_trajectory: get flight path for a single campaign
* gl\_data\_tile\_ids: check which tiles have data
* gl\_dedupe\_trajectories: collapse the duplicated day tracks down to one feature per flight day
* gl\_fetch\_shapefile: download a campaign's tile/trajectory file and return local path (published as .zip, .tar.gz, or .shp)
* gl\_one\_footprint: dissolve a campaign's polygons into one footprint
* gl\_read\_vector: read shapefile and cleanup



04 repeat:

* gl\_campaign\_pairs: get which flights overlap with which, across epochs
* gl\_epoch\_coverage: merge all of an epoch's campaign footprints into one polygon
* gl\_epoch\_sides: update column names for one epoch's footprints
* gl\_pairs\_for epochs: get overlapping flight pairs between two epochs
* gl\_polygon\_parts: keep only the two-dimensional parts of an overlay result
* gl\_repeat\_coverage: cut epoch polygons against each other
* gl\_repeat\_summary\_table: total overlay's many small pieces into one row per epoch combination
* gl\_repeat\_tiles: for every data-bearing tile, get the fraction of it covered by each epoch.
* **gl\_step\_repeat**: get repeat coverage by epoch and write out .gpkg



05 download:

* gl\_plan\_download: work out which files a request comes to, and where each would be saved.
* gl\_plan\_size: get size in GB of download plan
* gl\_repeat\_campaigns: return which flights have repeat coverage for specified epochs
* **gl\_run\_download**: run download plan (defaults to a dry run which prints the size)



06 refine:

* gl\_carry\_forward\_refined: add previously refined campaigns back in, so results accumulate across runs
* gl\_chm\_footprint: get exact area covered for one campaign
* gl\_raster\_mask\_polygons: trace outline of pixels with data in one raster



07 report:

* gl\_inventory\_by\_epoch: summarise flights and campaigns by each epoch
* gl\_plot\_epoch\_map: map footprints for each epoch
* gl\_plot\_repeat\_map: map which footprints have coverage in more than 1 epoch
* **gl\_step\_report**: map footprints and generate tables of which tiles/footprints are covered in multiple epochs
* gl\_summarise\_epoch: get one row summarizing a single epoch

