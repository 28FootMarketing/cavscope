-- muster_004 wrote this body in lower case; source uses upper case. Behaviour
-- is identical -- this is purely so the whole function layer can be verified
-- with one checksum instead of one-plus-an-exception. A parity check that has
-- to carry a list of known-benign differences stops being a parity check.
CREATE OR REPLACE FUNCTION muster.touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'muster', 'pg_temp'
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $function$
;
