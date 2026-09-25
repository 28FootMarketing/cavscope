select vault.create_secret(
  encode(gen_random_bytes(24), 'hex'),
  'muster_beta_export_key',
  'Query-param key protecting the muster-beta-export CSV endpoint (used by Sheets IMPORTDATA)'
) where not exists (select 1 from vault.decrypted_secrets where name = 'muster_beta_export_key');
