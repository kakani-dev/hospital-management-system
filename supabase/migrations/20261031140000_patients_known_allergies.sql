-- #275 (patient safety): record known allergies on the patient so the pharmacist sees them at dispense.
-- Null = not recorded (the UI shows a "not recorded" warning); "No known allergies" is typed explicitly.
-- The API caps input at 500 characters; the table allows more so merged charts can keep both lists.
set local lock_timeout = '5s';
set local statement_timeout = '120s';

alter table patient.patients add column if not exists known_allergies text;
alter table patient.patients add constraint patients_known_allergies_len
  check (known_allergies is null or char_length(known_allergies) between 1 and 2000);

-- Same column grants as the other writable patient columns.
grant select (known_allergies), insert (known_allergies), update (known_allergies)
  on patient.patients to hms_svc_patients, authenticated;

-- Merging a duplicate chart must never drop an allergy: the duplicate's list is appended to the
-- survivor's (skipped when the survivor already has the same text).
create or replace function patient.carry_allergies_on_merge()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_dup text := nullif(btrim(new.known_allergies), '');
begin
  if v_dup is null then
    return new;
  end if;
  update patient.patients s
     set known_allergies = case
           when nullif(btrim(s.known_allergies), '') is null then v_dup
           when position(lower(v_dup) in lower(s.known_allergies)) > 0 then s.known_allergies
           else left(s.known_allergies || '; ' || v_dup, 2000) end
   where s.id = new.merged_into_patient_id and s.tenant_id = new.tenant_id;
  return new;
end;
$$;
revoke execute on function patient.carry_allergies_on_merge() from public, anon, authenticated;

drop trigger if exists patients_carry_allergies_on_merge on patient.patients;
create trigger patients_carry_allergies_on_merge
  after update of merged_into_patient_id on patient.patients
  for each row
  when (old.merged_into_patient_id is null and new.merged_into_patient_id is not null)
  execute function patient.carry_allergies_on_merge();
