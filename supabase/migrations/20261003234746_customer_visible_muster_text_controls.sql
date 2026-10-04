-- The control register is customer-visible. 26 control rows carried "1 MUSTER check map to this
-- reference" in their description, written when the product had its old name and never regenerated.
-- Rewording only; nothing else on a control changes.

update cavscope.controls set description = replace(description, 'MUSTER', 'CavScope') where description like '%MUSTER%';
update cavscope.controls set title = replace(title, 'MUSTER', 'CavScope') where title like '%MUSTER%';
