-- ═══════════════════════════════════════════════════════════════════
-- GymLog schema — paste this entire file into Supabase SQL Editor
-- (Dashboard → SQL Editor → New Query → paste → Run)
-- Idempotent: safe to re-run if you tweak and re-apply.
-- ═══════════════════════════════════════════════════════════════════

-- ─── PROFILES ─────────────────────────────────────────────────────
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  weight_unit text default 'kg' check (weight_unit in ('kg','lbs')),
  daily_calorie_goal int default 2200,
  daily_protein_goal int default 160,
  daily_carbs_goal int default 220,
  daily_fat_goal int default 70,
  daily_fiber_goal int default 30,
  created_at timestamptz default now()
);

-- ─── FOOD ─────────────────────────────────────────────────────────
create table if not exists meals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  logged_on date not null,
  section text not null check (section in ('breakfast','lunch','dinner','snack')),
  name text,
  total_calories numeric default 0,
  total_protein_g numeric default 0,
  total_carbs_g numeric default 0,
  total_fat_g numeric default 0,
  total_fiber_g numeric default 0,
  total_weight_g numeric default 0,
  created_at timestamptz default now()
);
create index if not exists meals_user_date_idx on meals(user_id, logged_on);

create table if not exists meal_items (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid not null references meals(id) on delete cascade,
  name text not null,
  grams numeric not null,
  calories numeric default 0,
  protein_g numeric default 0,
  carbs_g numeric default 0,
  fat_g numeric default 0,
  fiber_g numeric default 0,
  sort_order int default 0
);

-- ─── WEIGHT (always kg in DB, converted on display) ───────────────
create table if not exists weight_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  logged_on date not null,
  weight_kg numeric not null,
  created_at timestamptz default now(),
  unique(user_id, logged_on)
);

-- ─── GYM ──────────────────────────────────────────────────────────
create table if not exists muscle_groups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  sort_order int default 0,
  created_at timestamptz default now(),
  unique(user_id, name)
);

create table if not exists exercises (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  muscle_group_id uuid not null references muscle_groups(id) on delete cascade,
  name text not null,
  sort_order int default 0,
  created_at timestamptz default now()
);
create index if not exists exercises_user_group_idx on exercises(user_id, muscle_group_id);

create table if not exists workout_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  exercise_id uuid not null references exercises(id) on delete cascade,
  performed_on date not null,
  notes text,
  is_pr boolean default false,
  max_weight_kg numeric default 0,
  created_at timestamptz default now()
);
create index if not exists sessions_user_exercise_idx on workout_sessions(user_id, exercise_id, performed_on desc);

create table if not exists workout_sets (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references workout_sessions(id) on delete cascade,
  set_number int not null,
  reps int not null,
  weight_kg numeric not null
);

-- ═══════════════════════════════════════════════════════════════════
-- ROW-LEVEL SECURITY — every table filtered by user_id = auth.uid()
-- ═══════════════════════════════════════════════════════════════════

alter table profiles enable row level security;
alter table meals enable row level security;
alter table meal_items enable row level security;
alter table weight_logs enable row level security;
alter table muscle_groups enable row level security;
alter table exercises enable row level security;
alter table workout_sessions enable row level security;
alter table workout_sets enable row level security;

-- profiles
drop policy if exists "profiles_self" on profiles;
create policy "profiles_self" on profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

-- meals
drop policy if exists "meals_owner" on meals;
create policy "meals_owner" on meals
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- meal_items (via meal ownership)
drop policy if exists "meal_items_owner" on meal_items;
create policy "meal_items_owner" on meal_items
  for all using (exists (select 1 from meals m where m.id = meal_items.meal_id and m.user_id = auth.uid()))
  with check (exists (select 1 from meals m where m.id = meal_items.meal_id and m.user_id = auth.uid()));

-- weight_logs
drop policy if exists "weight_owner" on weight_logs;
create policy "weight_owner" on weight_logs
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- muscle_groups
drop policy if exists "groups_owner" on muscle_groups;
create policy "groups_owner" on muscle_groups
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- exercises
drop policy if exists "exercises_owner" on exercises;
create policy "exercises_owner" on exercises
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- workout_sessions
drop policy if exists "sessions_owner" on workout_sessions;
create policy "sessions_owner" on workout_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- workout_sets (via session ownership)
drop policy if exists "sets_owner" on workout_sets;
create policy "sets_owner" on workout_sets
  for all using (exists (select 1 from workout_sessions s where s.id = workout_sets.session_id and s.user_id = auth.uid()))
  with check (exists (select 1 from workout_sessions s where s.id = workout_sets.session_id and s.user_id = auth.uid()));

-- ═══════════════════════════════════════════════════════════════════
-- SIGNUP TRIGGER — seed profile + default muscle groups + exercises
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  chest_id uuid;
  back_id  uuid;
  legs_id  uuid;
begin
  insert into public.profiles(id, display_name)
    values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1)));

  insert into public.muscle_groups(user_id, name, sort_order) values (new.id, 'Chest', 1) returning id into chest_id;
  insert into public.muscle_groups(user_id, name, sort_order) values (new.id, 'Back',  2) returning id into back_id;
  insert into public.muscle_groups(user_id, name, sort_order) values (new.id, 'Legs',  3) returning id into legs_id;

  insert into public.exercises(user_id, muscle_group_id, name, sort_order) values
    (new.id, chest_id, 'Bench Press',           1),
    (new.id, chest_id, 'Incline Dumbbell Press',2),
    (new.id, chest_id, 'Chest Press (Machine)', 3),
    (new.id, chest_id, 'Cable Fly',             4),
    (new.id, chest_id, 'Push-Up',               5),
    (new.id, back_id,  'Lat Pulldown',          1),
    (new.id, back_id,  'Barbell Row',           2),
    (new.id, back_id,  'Seated Cable Row',      3),
    (new.id, back_id,  'Pull-Up',               4),
    (new.id, back_id,  'Deadlift',              5),
    (new.id, legs_id,  'Barbell Squat',         1),
    (new.id, legs_id,  'Leg Press',             2),
    (new.id, legs_id,  'Romanian Deadlift',     3),
    (new.id, legs_id,  'Leg Extension',         4),
    (new.id, legs_id,  'Leg Curl',              5);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
