-- #271: the dispense cap (#187) treated hourly (Q8H, every 8 hours) and alternate-day (QOD) frequencies as
-- unknown, so those prescriptions had no cap. prescribed_qty now understands them; truly unknown text
-- (SOS, PRN, STAT) still returns null (no cap) as before.

create or replace function pharmacy.prescribed_qty(p_dose text, p_frequency text, p_duration integer)
returns bigint
language plpgsql
immutable
set search_path = ''
as $$
declare
  f text := upper(regexp_replace(btrim(coalesce(p_frequency, '')), '\s+', ' ', 'g'));
  per_day numeric;
  per_dose numeric := 1;
  part text;
  hours int;
begin
  if p_duration is null or p_duration < 1 then
    return null;
  end if;
  if f ~ '^[0-9]+(\.[0-9]+)?( ?- ?[0-9]+(\.[0-9]+)?){1,3}$' then
    per_day := 0;
    foreach part in array regexp_split_to_array(f, ' ?- ?') loop
      per_day := per_day + part::numeric;
    end loop;
  else
    per_day := case f
      when 'OD' then 1 when 'QD' then 1 when 'HS' then 1 when 'ONCE DAILY' then 1 when 'ONCE A DAY' then 1
      when 'BD' then 2 when 'BID' then 2 when 'TWICE DAILY' then 2 when 'TWICE A DAY' then 2
      when 'TDS' then 3 when 'TID' then 3 when 'THRICE DAILY' then 3
      when 'QID' then 4 when 'QDS' then 4
      when 'THRICE A DAY' then 3 when 'THREE TIMES A DAY' then 3 when 'THREE TIMES DAILY' then 3
      when 'FOUR TIMES A DAY' then 4 when 'FOUR TIMES DAILY' then 4
      when 'QOD' then 0.5 when 'EOD' then 0.5 when 'ALTERNATE DAY' then 0.5 when 'ALTERNATE DAYS' then 0.5
      when 'EVERY OTHER DAY' then 0.5 when 'ON ALTERNATE DAYS' then 0.5
      else null end;
    -- #271: every N hours (Q8H, Q 8 H, Q8HRS, EVERY 8 HOURS, 8 HOURLY, 8TH HOURLY) = 24 / N doses a day
    -- when N divides the day evenly; any other interval stays uncapped.
    if per_day is null then
      hours := coalesce(
        (regexp_match(f, '^Q ?([0-9]{1,2}) ?(H|HR|HRS|HOURLY)$'))[1],
        (regexp_match(f, '^EVERY ([0-9]{1,2}) ?(H|HR|HRS|HOUR|HOURS)$'))[1],
        (regexp_match(f, '^([0-9]{1,2}) ?(TH|ST|ND|RD)? ?(HOURLY|HRLY)$'))[1])::int;
      if hours between 1 and 24 and 24 % hours = 0 then
        per_day := 24 / hours;
      end if;
    end if;
    -- Word codes count doses; a "2 tabs" dose gives two units each time.
    if per_day is not null and coalesce(p_dose, '') ~* '^\s*[0-9]+(\.[0-9]+)?\s*(tab|tabs|tablet|tablets|cap|caps|capsule|capsules)\M' then
      per_dose := (regexp_match(p_dose, '([0-9]+(?:\.[0-9]+)?)'))[1]::numeric;
    end if;
  end if;
  if per_day is null or per_day <= 0 then
    return null;
  end if;
  return ceil(per_day * per_dose * p_duration)::bigint;
end;
$$;
revoke all on function pharmacy.prescribed_qty(text, text, integer) from public, anon, authenticated;
