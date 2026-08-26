-- Turn auto recluster on and off
ALTER TABLE t1 SUSPEND RECLUSTER;
ALTER TABLE t1 RESUME RECLUSTER;

-- Add or remove clustering keys to an existing table
ALTER TABLE <tablename> CLUSTER BY (<col1>, <col2>);
ALTER TABLE <tablename> CLUSTER BY (TO_DATE(event_timestamp));
ALTER TABLE <tablename> DROP CLUSTERING KEY;

SELECT SYSTEM$ESTIMATE_AUTOMATIC_CLUSTERING_COSTS(
               'my_database.my_schema.my_large_table',
               '(geo_region, creation_date)'
       );

select 'select system$clustering_information('''
           || table_catalog || '.' ||table_schema|| '.' || table_name
           || ''',''' || clustering_key || '''); --' || auto_clustering_on
from snowflake.account_usage.tables
where deleted is null
  and clustering_key is not null
order by table_catalog, table_schema, table_name;

-- Check overlap depth of each micro-partition. Depth histogram should be short, with bulk of partitions being at the top.
SELECT SYSTEM$CLUSTERING_INFORMATION('table', '(col1, col3)');

-- Sample output of bad micro-partitioning
--+--------------------------------------------------------------------+
--| SYSTEM$CLUSTERING_INFORMATION('TABLE', '(COL1, COL3)')             |
--|--------------------------------------------------------------------|
--| {                                                                  |
--|   "cluster_by_keys" : "LINEAR(COL1, COL3)",                        |
--|   "version" : "CLASSIC",                                           |
--|   "total_partition_count" : 1156,                                  |
--|   "total_constant_partition_count" : 0,                            |
--|   "average_overlaps" : 117.5484,                                   |
--|   "average_depth" : 64.0701,                                       |
--|   "partition_depth_histogram" : {                                  |
--|     "00000" : 0,                                                   |
--|     "00001" : 0,                                                   |
--|     "00002" : 3,                                                   |
--|     "00003" : 3,                                                   |
--|     "00004" : 4,                                                   |
--|     "00005" : 6,                                                   |
--|     "00006" : 3,                                                   |
--|     "00007" : 5,                                                   |
--|     "00008" : 10,                                                  |
--|     "00009" : 5,                                                   |
--|     "00010" : 7,                                                   |
--|     "00011" : 6,                                                   |
--|     "00012" : 8,                                                   |
--|     "00013" : 8,                                                   |
--|     "00014" : 9,                                                   |
--|     "00015" : 8,                                                   |
--|     "00016" : 6,                                                   |
--|     "00032" : 98,                                                  |
--|     "00064" : 269,                                                 |
--|     "00128" : 698                                                  |
--|   },                                                               |
--|   "clustering_errors" : [ {                                        |
--|      "timestamp" : "2023-04-03 17:50:42 +0000",                    |
--|      "error" : "(003325) Clustering service has been disabled.\n"  |
--|      }                                                             |
--|   ]                                                                |
--| }                                                                  |
--+--------------------------------------------------------------------+
-- This example indicates that the test2 table is not well-clustered for the following reasons:

-- Zero (0) constant micro-partitions out of 1156 total micro-partitions.
-- High average of overlapping micro-partitions.
-- High average of overlap depth across micro-partitions.
-- Most of the micro-partitions are grouped at the lower-end of the histogram, with the majority of micro-partitions having an overlap depth between 64 and 128.
