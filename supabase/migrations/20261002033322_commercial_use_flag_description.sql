-- Say what the Partner commercial entitlement is, in the flag's own description: the right to charge
-- your own clients for audits you run with CavScope, not a licence to resell or sublicense it.
-- The full terms are the Partner agreement's, not this text's.
update cavscope.feature_flags set description = 'Permits using CavScope as part of paid services delivered to external clients: the right to charge your own clients for audits you run with it. It is not a licence to resell or sublicense CavScope itself, and it is distinct from white-labeling.' where key = 'commercial_use_enabled';
