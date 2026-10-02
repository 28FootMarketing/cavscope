-- Read by SQL as of the functions in 20261002031051. 'app' is added when the workspace reads it.
update cavscope.feature_flags set enforcement = array['sql'], wiring_note = 'Read by cavscope.do_create_client_org together with a per-Partner allowance. Extra-organization billing is not built.' where key = 'client_management_enabled';
