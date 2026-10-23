-- À exécuter dans Supabase > SQL Editor (après warhammer_supabase_setup.sql)
-- Verrouillage des dates :
--   * une date verrouillée refuse toute création de table (web comme bot) ;
--   * seul le bot Discord (clé service_role) peut verrouiller / déverrouiller.

alter table public.warhammer_dates
  add column if not exists locked boolean not null default false,
  add column if not exists lock_comment text,
  add column if not exists locked_at timestamptz,
  add column if not exists locked_by text;

-- 1) Bloque l'ajout d'une table (ou son déplacement) vers une date verrouillée
create or replace function public.warhammer_block_locked_date()
returns trigger
language plpgsql
as $$
declare
  d record;
begin
  if tg_op = 'UPDATE' and new.date_id = old.date_id then
    return new; -- modification d'une table existante : autorisée
  end if;

  select locked, lock_comment, label into d
  from public.warhammer_dates
  where id = new.date_id;

  if d.locked then
    raise exception 'DATE_VERROUILLEE: La date % est verrouillée. %',
      d.label, coalesce('Motif : ' || nullif(d.lock_comment, ''), '')
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists warhammer_tables_block_locked on public.warhammer_tables;
create trigger warhammer_tables_block_locked
  before insert or update of date_id on public.warhammer_tables
  for each row execute function public.warhammer_block_locked_date();

-- 2) Interdit de toucher au verrouillage depuis la page web (clé publique / anon)
create or replace function public.warhammer_protect_lock_columns()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), '') = 'service_role' or current_user in ('postgres', 'service_role') then
    return new; -- le bot (service_role) ou l'éditeur SQL peuvent tout faire
  end if;

  if tg_op = 'INSERT' then
    new.locked := false;
    new.lock_comment := null;
    new.locked_at := null;
    new.locked_by := null;
  elsif new.locked is distinct from old.locked
     or new.lock_comment is distinct from old.lock_comment
     or new.locked_at is distinct from old.locked_at
     or new.locked_by is distinct from old.locked_by then
    raise exception 'Le verrouillage d''une date se fait uniquement via le bot Discord.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists warhammer_dates_protect_lock on public.warhammer_dates;
create trigger warhammer_dates_protect_lock
  before insert or update on public.warhammer_dates
  for each row execute function public.warhammer_protect_lock_columns();
