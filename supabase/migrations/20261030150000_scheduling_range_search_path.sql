-- #219: Supabase advisor function_search_path_mutable. The constructors Postgres made for the range type
-- appointment.timerange (and its multirange) had no fixed search_path. Pin it to empty like every other
-- function. Behaviour is unchanged: the constructors only build a range value.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter function appointment.timerange(time, time) set search_path = '';
alter function appointment.timerange(time, time, text) set search_path = '';
alter function appointment.timemultirange() set search_path = '';
alter function appointment.timemultirange(appointment.timerange) set search_path = '';
alter function appointment.timemultirange(appointment.timerange[]) set search_path = '';
