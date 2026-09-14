-- Rollback: 007_segment_reidentification_map.sql
-- Card: SLDP-P3-1
--
-- WARNING, read before running. This drops the re-identification map for every pseudonymised
-- column in every signalloom.observations/v2 segment.
--
-- It is not symmetrical with the forward migration and cannot be. The forward migration is
-- additive, so dropping the table restores the schema exactly — but the v2 segments it explains
-- are signed and immutable, so they do not roll back with it. After this runs, every pseudonym in
-- the columnar store is permanently unresolvable: the data is not destroyed, it becomes anonymous.
--
-- That may be the desired outcome (it is, in effect, a crypto-shred of the whole re-identification
-- surface). It is never a reversible one. If the intent is to undo a deployment rather than to
-- erase, dump the table first.
--
-- Rolling back 007 does NOT roll back the segment schema. A store built from this branch still
-- writes v2 columns; it simply loses the ability to resolve them.

DROP POLICY IF EXISTS segment_reid_tenant_isolation ON segment_reidentification_map;

DROP INDEX IF EXISTS idx_segment_reid_tenant_kind;
DROP INDEX IF EXISTS idx_segment_reid_unique;

DROP TABLE IF EXISTS segment_reidentification_map;
