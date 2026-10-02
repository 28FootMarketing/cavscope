-- Read by SQL (cavscope_pdf_export_allowed) and by the cavscope-sitrep-pdf edge function.
update cavscope.feature_flags set enforcement = array['sql','edge'], wiring_note = 'Read by public.cavscope_pdf_export_allowed and the cavscope-sitrep-pdf function. The kill switch stays on until an owner turns it off.' where key = 'pdf_export';
