-- The remaining tenant-visible records that carried the old name: the Trial plan's description
-- ("SITREPs with MUSTER attribution"), two risks and one finding that copied the AVAIL-003/004 text
-- before it was corrected, and 18 activity-feed lines ("MUSTER marketing site: posture ...").
--
-- Deliberately left: notification_outbox (every row is already sent, so these are a record of mail that
-- went out), scan_evidence and evidence_embeddings (captured copies of the scanned pages themselves,
-- including the retired marketing site's own "MUSTER by 28 Foot Systems" -- evidence of what a page said),
-- and doc_chunks (internal documents).

update cavscope.plans set description = replace(description, 'MUSTER', 'CavScope') where description like '%MUSTER%';
update cavscope.risks set description = replace(description, 'MUSTER', 'CavScope') where description like '%MUSTER%';
update cavscope.risks set treatment_plan = replace(treatment_plan, 'MUSTER', 'CavScope') where treatment_plan like '%MUSTER%';
update cavscope.findings set detail = replace(detail, 'MUSTER', 'CavScope') where detail like '%MUSTER%';
update cavscope.activity_events set detail = replace(detail, 'MUSTER', 'CavScope') where detail like '%MUSTER%';
