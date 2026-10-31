-- #271: hourly and alternate-day frequencies are capped; unknown text stays uncapped.
begin;
do $do$
begin
  perform tests.ok(pharmacy.prescribed_qty('500 mg', 'Q8H', 5) = 15, 'Q8H x 5 days = 15');
  perform tests.ok(pharmacy.prescribed_qty('500 mg', 'q 6 h', 3) = 12, 'q 6 h x 3 days = 12 (case and spaces)');
  perform tests.ok(pharmacy.prescribed_qty('500 mg', 'Q12H', 7) = 14, 'Q12H x 7 = 14');
  perform tests.ok(pharmacy.prescribed_qty('500 mg', 'Q4H', 2) = 12, 'Q4H x 2 = 12');
  perform tests.ok(pharmacy.prescribed_qty('500 mg', 'Q24H', 10) = 10, 'Q24H x 10 = 10');
  perform tests.ok(pharmacy.prescribed_qty('500 mg', 'every 8 hours', 5) = 15, 'every 8 hours x 5 = 15');
  perform tests.ok(pharmacy.prescribed_qty('500 mg', '8 hourly', 5) = 15, '8 hourly x 5 = 15');
  perform tests.ok(pharmacy.prescribed_qty('500 mg', '6th hourly', 1) = 4, '6th hourly x 1 = 4');
  perform tests.ok(pharmacy.prescribed_qty('2 tabs', 'Q12H', 5) = 20, 'a 2 tab dose Q12H x 5 = 20');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'QOD', 10) = 5, 'QOD x 10 days = 5');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'alternate day', 7) = 4, 'alternate day x 7 = 4 (rounded up)');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'every other day', 4) = 2, 'every other day x 4 = 2');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'three times a day', 5) = 15, 'three times a day x 5 = 15');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'four times daily', 2) = 8, 'four times daily x 2 = 8');
  -- Unchanged behaviour.
  perform tests.ok(pharmacy.prescribed_qty('1 tab', '1-0-1', 5) = 10, '1-0-1 x 5 = 10 (unchanged)');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'BD', 5) = 10, 'BD x 5 = 10 (unchanged)');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'Q5H', 5) is null, 'Q5H does not divide the day: no cap');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'Q0H', 5) is null, 'Q0H is not an interval: no cap');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'Q48H', 5) is null, 'Q48H is out of range: no cap');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'SOS', 5) is null, 'SOS stays uncapped');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'PRN', 5) is null, 'PRN stays uncapped');
  perform tests.ok(pharmacy.prescribed_qty('1 tab', 'Q8H', null) is null, 'no duration: no cap');
end
$do$;
rollback;
