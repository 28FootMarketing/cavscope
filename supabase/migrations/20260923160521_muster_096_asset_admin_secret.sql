select vault.create_secret(
  encode(gen_random_bytes(24), 'hex'),
  'muster_asset_admin_secret',
  'Shared secret gating the muster-asset-admin Edge Function, used to upload brand assets to Storage'
) where not exists (select 1 from vault.decrypted_secrets where name = 'muster_asset_admin_secret');
