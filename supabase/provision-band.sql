-- Prints the serial commands that provision each band. Run as postgres in the SQL editor.
-- (Only postgres can read band_keys; no app key or signed-in user can.)
--
-- For each band: open its serial monitor (115200 baud) and paste id_line, then key_line.
-- Re-run this query and paste time_line LAST: it is the band's clock, and the band only needs to be
-- within about 20 minutes of the real time (see eid_window_epochs()).
--
-- The key is the band's secret. Don't paste it in chat, tickets or screenshots, and don't commit the output.
select c.name,
       'ID '   || c.beacon_id                          as id_line,
       'KEY '  || encode(k.key, 'hex')                 as key_line,
       'TIME ' || extract(epoch from now())::bigint    as time_line
from public.children c
join public.band_keys k on k.child_id = c.id
order by c.beacon_id;
