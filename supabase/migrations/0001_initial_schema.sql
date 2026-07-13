-- Tut.Io: schema inicial completo do backend Supabase (projeto novo, schema public vazio).
-- Fonte: tutio-web-reference/supabase/migrations/*.sql (13 migrations reais do mesmo
-- projeto Supabase do web), consolidadas em uma unica migration coerente.
--
-- Divergencias deliberadas da fonte (documentadas com detalhe em
-- tutio-android/docs/ANDROID_PROGRESS.md):
-- 1. Nao replicado: INSERT da clinica "Praia dos Bichos" com UUID fixo e o seed de
--    available_cities para Caraguatatuba (dados fabricados presos a marca antiga, e este
--    projeto e producao nova sem clinicas reais ainda -- CLAUDE.md proibe clinic_id/IDs
--    fabricados em producao e dados falsos silenciosos).
-- 2. handle_new_user cria somente `profiles` (nao insere `user_roles`) -- e o comportamento
--    final real do backend web: a migration 20260104030004 sobrescreveu a versao anterior
--    da funcao (que tambem inseria user_roles) com CREATE OR REPLACE. Sem regressao: ausencia
--    de linha em user_roles ja significa AppRole.USER por padrao em
--    core/session/SessionRepository.kt (resolveAppRole).
-- 3. Bug corrigido: redeem_reward inseria loyalty_transactions.type = 'debit', mas o CHECK
--    da coluna so permite ('earn','redeem','expire','adjustment') -- teria falhado em
--    runtime com violacao de constraint na primeira chamada real. Corrigido para 'redeem'.
-- 4. Bug corrigido: create_order_notification comparava orders.status com 'processing', mas
--    o CHECK de orders.status so permite ('pending','confirmed','preparing','shipped',
--    'delivered','cancelled') -- branch morto. Corrigido para 'preparing'.
-- 5. Nao replicada a policy "System can insert notifications" (USING/WITH CHECK (true) sem
--    restricao de role) -- permitiria qualquer cliente autenticado inserir notificacao para
--    qualquer user_id. As triggers reais (create_appointment_notification/
--    create_order_notification) sao SECURITY DEFINER e ja contornam RLS; a policy nao e
--    necessaria para elas e nenhuma tela Android usa `notifications` hoje.

create extension if not exists pgcrypto;

-- =========================================================================
-- ENUMS
-- =========================================================================
create type public.app_role as enum ('user', 'staff', 'admin');
create type public.location_type as enum ('clinic', 'home', 'both');
create type public.staff_role as enum ('vet', 'groomer', 'driver', 'trainer', 'walker', 'receptionist');
create type public.appointment_status as enum ('pending', 'confirmed', 'in_progress', 'completed', 'cancelled', 'no_show');
create type public.forum_category as enum ('alimentacao','vacinas','comportamento','banho_tosa','adocao','saude','dicas','outros');
create type public.report_target_type as enum ('post','comment','topic','reply','profile');
create type public.report_reason as enum ('spam','conteudo_improprio','assedio','fake','outro');
create type public.report_status as enum ('pending','resolved','dismissed');

-- =========================================================================
-- FUNCAO REUTILIZAVEL DE updated_at
-- =========================================================================
create or replace function public.update_updated_at_column()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =========================================================================
-- IDENTIDADE, PAPEIS, PETS, SEGUIDORES
-- =========================================================================
create table public.profiles (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  name text not null,
  email text,
  phone text,
  city text,
  bio text,
  avatar_url text,
  is_public boolean not null default true,
  reduce_motion boolean not null default false,
  tinder_dog_opt_in boolean not null default false,
  theme_preference text default 'light' check (theme_preference in ('light','dark','system')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_roles (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null default 'user',
  created_at timestamptz not null default now(),
  unique(user_id, role)
);

create table public.pets (
  id uuid not null default gen_random_uuid() primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  species text not null check (species = any (array['cachorro','gato','coelho','passaro','hamster','peixe','reptil','outros'])),
  breed text,
  sex text check (sex is null or sex = any (array['macho','femea'])),
  birth_date date,
  weight decimal(5,2),
  photo_url text,
  energy_level text check (energy_level is null or energy_level = any (array['baixa','media','alta'])),
  sociability text check (sociability is null or sociability = any (array['timido','moderado','sociavel'])),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.follows (
  id uuid not null default gen_random_uuid() primary key,
  follower_id uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(follower_id, following_id),
  check (follower_id != following_id)
);

-- =========================================================================
-- CLINICAS (multiclinica)
-- =========================================================================
create table public.clinics (
  id uuid not null default gen_random_uuid() primary key,
  name text not null,
  slug text not null unique,
  description text,
  logo_url text,
  cover_url text,
  phone text,
  whatsapp text,
  email text,
  website text,
  street text,
  number text,
  complement text,
  neighborhood text,
  city text not null,
  state text not null default 'SP',
  zip_code text,
  latitude numeric,
  longitude numeric,
  working_hours jsonb default '{}',
  is_active boolean not null default true,
  is_featured boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.clinic_members (
  id uuid not null default gen_random_uuid() primary key,
  clinic_id uuid not null references public.clinics(id) on delete cascade,
  user_id uuid not null,
  role text not null default 'staff',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(clinic_id, user_id)
);

create table public.available_cities (
  id uuid not null default gen_random_uuid() primary key,
  city text not null,
  state text not null default 'SP',
  clinics_count integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(city, state)
);

-- =========================================================================
-- SERVICOS, EQUIPE, AGENDA
-- =========================================================================
create table public.services (
  id uuid not null default gen_random_uuid() primary key,
  clinic_id uuid references public.clinics(id) on delete cascade,
  name text not null,
  description text,
  duration_minutes integer not null default 30,
  base_price numeric(10,2),
  location_allowed public.location_type not null default 'both',
  category text,
  icon text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.staff (
  id uuid not null default gen_random_uuid() primary key,
  clinic_id uuid references public.clinics(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  name text not null,
  photo_url text,
  role public.staff_role not null default 'vet',
  bio text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.staff_services (
  id uuid not null default gen_random_uuid() primary key,
  staff_id uuid not null references public.staff(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(staff_id, service_id)
);

create table public.staff_working_hours (
  id uuid not null default gen_random_uuid() primary key,
  staff_id uuid not null references public.staff(id) on delete cascade,
  weekday integer not null check (weekday >= 0 and weekday <= 6),
  start_time time not null,
  end_time time not null,
  slot_interval_minutes integer not null default 30,
  buffer_minutes integer not null default 10,
  location_type public.location_type not null default 'both',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(staff_id, weekday, location_type)
);

create table public.staff_time_off (
  id uuid not null default gen_random_uuid() primary key,
  staff_id uuid not null references public.staff(id) on delete cascade,
  start_datetime timestamptz not null,
  end_datetime timestamptz not null,
  reason text,
  created_at timestamptz not null default now()
);

create table public.clinic_closures (
  id uuid not null default gen_random_uuid() primary key,
  start_datetime timestamptz not null,
  end_datetime timestamptz not null,
  reason text,
  created_at timestamptz not null default now()
);

create table public.scheduling_settings (
  id uuid not null default gen_random_uuid() primary key,
  max_advance_days integer not null default 60,
  min_advance_hours integer not null default 2,
  cancellation_hours integer not null default 4,
  max_home_visits_per_day integer not null default 5,
  home_visit_buffer_minutes integer not null default 30,
  updated_at timestamptz not null default now()
);

create table public.appointments (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  clinic_id uuid references public.clinics(id) on delete cascade,
  service_id uuid references public.services(id),
  staff_id uuid references public.staff(id),
  service_type text not null,
  location_type text not null check (location_type in ('clinic','home')),
  address text,
  street text,
  number text,
  neighborhood text,
  city text,
  zip_code text,
  complement text,
  reference text,
  scheduled_at timestamptz not null,
  scheduled_end timestamptz,
  duration_minutes integer,
  status text not null default 'pending' check (status in ('pending','confirmed','completed','cancelled')),
  price decimal(10,2),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================================================================
-- LOJA, PEDIDOS, CUPONS, PLANOS DE SAUDE
-- =========================================================================
create table public.products (
  id uuid not null default gen_random_uuid() primary key,
  clinic_id uuid references public.clinics(id) on delete cascade,
  name text not null,
  description text,
  brand text,
  price numeric not null,
  original_price numeric,
  image_url text,
  category text not null,
  stock integer not null default 0,
  is_active boolean not null default true,
  rating numeric default 0,
  reviews_count integer default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.coupons (
  id uuid not null default gen_random_uuid() primary key,
  clinic_id uuid references public.clinics(id) on delete cascade,
  code text not null unique,
  description text,
  discount_type text not null check (discount_type in ('percentage','fixed')),
  discount_value numeric not null,
  min_order_value numeric default 0,
  max_uses integer,
  used_count integer not null default 0,
  is_active boolean not null default true,
  starts_at timestamptz not null default now(),
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.orders (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  clinic_id uuid references public.clinics(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','confirmed','preparing','shipped','delivered','cancelled')),
  subtotal numeric not null,
  shipping numeric not null default 0,
  discount numeric not null default 0,
  total numeric not null,
  coupon_id uuid references public.coupons(id),
  delivery_method text not null check (delivery_method in ('delivery','pickup')),
  payment_method text not null check (payment_method in ('credit','debit','pix','boleto')),
  shipping_address jsonb,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid not null default gen_random_uuid() primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  product_name text not null,
  product_price numeric not null,
  quantity integer not null,
  total numeric not null,
  created_at timestamptz not null default now()
);

create table public.cart_items (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  product_id uuid not null references public.products(id) on delete cascade,
  quantity integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, product_id)
);

create table public.health_plans (
  id uuid not null default gen_random_uuid() primary key,
  clinic_id uuid references public.clinics(id) on delete cascade,
  name text not null,
  description text,
  price_monthly numeric not null,
  features jsonb not null default '[]'::jsonb,
  is_popular boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.health_subscriptions (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  plan_id uuid not null references public.health_plans(id),
  pet_id uuid references public.pets(id),
  status text not null default 'active' check (status in ('active','cancelled','expired','pending')),
  started_at timestamptz not null default now(),
  expires_at timestamptz,
  cancelled_at timestamptz,
  stripe_subscription_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================================================================
-- FIDELIDADE
-- =========================================================================
create table public.loyalty_accounts (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null unique,
  points_balance integer not null default 0,
  tier text not null default 'bronze' check (tier in ('bronze','prata','ouro','diamante')),
  total_points_earned integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.loyalty_transactions (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  points integer not null,
  type text not null check (type in ('earn','redeem','expire','adjustment')),
  source text not null,
  reference_id uuid,
  description text,
  created_at timestamptz not null default now()
);

create table public.reward_redemptions (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  reward_name text not null,
  reward_description text,
  points_spent integer not null,
  status text not null default 'active',
  redeemed_at timestamptz not null default now(),
  expires_at timestamptz,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

-- =========================================================================
-- ADOCAO, JOGOS
-- =========================================================================
create table public.adoption_pets (
  id uuid not null default gen_random_uuid() primary key,
  clinic_id uuid references public.clinics(id) on delete cascade,
  name text not null,
  species text not null,
  breed text,
  age_text text,
  sex text check (sex in ('macho','femea')),
  size text check (size in ('pequeno','medio','grande')),
  temperament text,
  description text,
  photo_url text,
  status text not null default 'disponivel' check (status in ('disponivel','reservado','adotado')),
  location text,
  is_vaccinated boolean default false,
  is_neutered boolean default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.adoption_requests (
  id uuid not null default gen_random_uuid() primary key,
  pet_id uuid not null references public.adoption_pets(id) on delete cascade,
  user_id uuid not null,
  name text not null,
  phone text not null,
  city text not null,
  experience text,
  availability text,
  message text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.game_scores (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  game_id text not null,
  score integer not null,
  created_at timestamptz not null default now()
);

-- =========================================================================
-- AGENDA INTELIGENTE, ALBUM, REGISTROS, CUIDADO DIARIO
-- =========================================================================
create table public.reminders (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  pet_id uuid references public.pets(id) on delete cascade,
  type text not null check (type in ('consulta','vacina','medicamento','banho_tosa','vermifugo','outro')),
  title text not null,
  due_at timestamptz not null,
  repeat_rule text check (repeat_rule in ('none','weekly','monthly')),
  notes text,
  is_completed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.pet_photos (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  pet_id uuid not null references public.pets(id) on delete cascade,
  url text not null,
  caption text,
  tags text[],
  taken_at date default current_date,
  created_at timestamptz not null default now()
);

create table public.medical_records (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  pet_id uuid not null references public.pets(id) on delete cascade,
  category text not null check (category in ('vacina','consulta','exame','procedimento','cirurgia')),
  title text not null,
  happened_at date not null,
  professional text,
  clinic text,
  notes text,
  attachment_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.care_logs (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  pet_id uuid not null references public.pets(id) on delete cascade,
  log_date date not null default current_date,
  items_done jsonb not null default '[]'::jsonb,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, pet_id, log_date)
);

-- =========================================================================
-- COMUNIDADE E FORUM (schema real do backend; ainda MOCK no Android/web -- B2)
-- =========================================================================
create table public.community_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null,
  content text not null,
  images text[] default '{}',
  likes_count integer not null default 0,
  comments_count integer not null default 0,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.post_likes (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  user_id uuid not null,
  created_at timestamptz not null default now(),
  unique(post_id, user_id)
);

create table public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  author_id uuid not null,
  content text not null,
  likes_count integer not null default 0,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.comment_likes (
  id uuid primary key default gen_random_uuid(),
  comment_id uuid not null references public.post_comments(id) on delete cascade,
  user_id uuid not null,
  created_at timestamptz not null default now(),
  unique(comment_id, user_id)
);

create table public.forum_topics (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null,
  title text not null,
  content text not null,
  category public.forum_category not null default 'outros',
  images text[] default '{}',
  replies_count integer not null default 0,
  is_hidden boolean not null default false,
  is_solved boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.forum_replies (
  id uuid primary key default gen_random_uuid(),
  topic_id uuid not null references public.forum_topics(id) on delete cascade,
  author_id uuid not null,
  content text not null,
  votes_count integer not null default 0,
  is_best_answer boolean not null default false,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.reply_votes (
  id uuid primary key default gen_random_uuid(),
  reply_id uuid not null references public.forum_replies(id) on delete cascade,
  user_id uuid not null,
  created_at timestamptz not null default now(),
  unique(reply_id, user_id)
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null,
  target_type public.report_target_type not null,
  target_id uuid not null,
  reason public.report_reason not null,
  description text,
  status public.report_status not null default 'pending',
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

-- =========================================================================
-- NOTIFICACOES
-- =========================================================================
create table public.notifications (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null,
  type text not null,
  title text not null,
  message text not null,
  is_read boolean not null default false,
  action_url text,
  metadata jsonb default '{}',
  created_at timestamptz not null default now()
);

-- =========================================================================
-- INDICES
-- =========================================================================
create index idx_clinics_city on public.clinics(city);
create index idx_clinics_state on public.clinics(state);
create index idx_clinics_slug on public.clinics(slug);
create index idx_clinics_active on public.clinics(is_active) where is_active = true;
create index idx_clinic_members_clinic on public.clinic_members(clinic_id);
create index idx_clinic_members_user on public.clinic_members(user_id);
create index idx_services_clinic on public.services(clinic_id);
create index idx_staff_clinic on public.staff(clinic_id);
create index idx_products_clinic on public.products(clinic_id);
create index idx_appointments_clinic on public.appointments(clinic_id);
create index idx_orders_clinic on public.orders(clinic_id);
create index idx_coupons_clinic on public.coupons(clinic_id);
create index idx_adoption_pets_clinic on public.adoption_pets(clinic_id);
create index idx_health_plans_clinic on public.health_plans(clinic_id);
create index idx_staff_working_hours_staff on public.staff_working_hours(staff_id);
create index idx_staff_time_off_staff on public.staff_time_off(staff_id);
create index idx_appointments_staff_date on public.appointments(staff_id, scheduled_at);
create index idx_appointments_user_date on public.appointments(user_id, scheduled_at);
create unique index idx_appointments_no_overlap on public.appointments(staff_id, scheduled_at) where status in ('pending','confirmed','in_progress');
create index idx_loyalty_transactions_user_id on public.loyalty_transactions(user_id);
create index idx_game_scores_game_id_score on public.game_scores(game_id, score desc);
create index idx_notifications_user_unread on public.notifications(user_id, is_read) where is_read = false;
create index idx_notifications_user_created on public.notifications(user_id, created_at desc);

-- =========================================================================
-- FUNCOES DE SEGURANCA (security definer, search_path explicito)
-- =========================================================================
create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_roles
    where user_id = _user_id and role = _role
  )
$$;

create or replace function public.is_clinic_member(_user_id uuid, _clinic_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.clinic_members
    where user_id = _user_id and clinic_id = _clinic_id and is_active = true
  )
$$;

create or replace function public.has_clinic_role(_user_id uuid, _clinic_id uuid, _role text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.clinic_members
    where user_id = _user_id and clinic_id = _clinic_id and role = _role and is_active = true
  )
$$;

-- Cria o profile automaticamente para todo novo usuario (email ou Google). Nunca concede
-- role a partir de metadata do cliente. Ver nota (2) no cabecalho sobre nao inserir user_roles.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (user_id, name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', 'Usuário'),
    new.email
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Contadores de comunidade/forum
create or replace function public.update_post_likes_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    update community_posts set likes_count = likes_count + 1 where id = new.post_id;
  elsif TG_OP = 'DELETE' then
    update community_posts set likes_count = greatest(likes_count - 1, 0) where id = old.post_id;
  end if;
  return null;
end;
$$;
create trigger post_likes_count_trigger after insert or delete on public.post_likes for each row execute function public.update_post_likes_count();

create or replace function public.update_post_comments_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    update community_posts set comments_count = comments_count + 1 where id = new.post_id;
  elsif TG_OP = 'DELETE' then
    update community_posts set comments_count = greatest(comments_count - 1, 0) where id = old.post_id;
  end if;
  return null;
end;
$$;
create trigger post_comments_count_trigger after insert or delete on public.post_comments for each row execute function public.update_post_comments_count();

create or replace function public.update_comment_likes_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    update post_comments set likes_count = likes_count + 1 where id = new.comment_id;
  elsif TG_OP = 'DELETE' then
    update post_comments set likes_count = greatest(likes_count - 1, 0) where id = old.comment_id;
  end if;
  return null;
end;
$$;
create trigger comment_likes_count_trigger after insert or delete on public.comment_likes for each row execute function public.update_comment_likes_count();

create or replace function public.update_topic_replies_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    update forum_topics set replies_count = replies_count + 1 where id = new.topic_id;
  elsif TG_OP = 'DELETE' then
    update forum_topics set replies_count = greatest(replies_count - 1, 0) where id = old.topic_id;
  end if;
  return null;
end;
$$;
create trigger topic_replies_count_trigger after insert or delete on public.forum_replies for each row execute function public.update_topic_replies_count();

create or replace function public.update_reply_votes_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    update forum_replies set votes_count = votes_count + 1 where id = new.reply_id;
  elsif TG_OP = 'DELETE' then
    update forum_replies set votes_count = greatest(votes_count - 1, 0) where id = old.reply_id;
  end if;
  return null;
end;
$$;
create trigger reply_votes_count_trigger after insert or delete on public.reply_votes for each row execute function public.update_reply_votes_count();

-- Contagem de clinicas por cidade (mantem available_cities coerente)
create or replace function public.update_city_clinics_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' or TG_OP = 'UPDATE' then
    insert into public.available_cities (city, state, clinics_count)
    values (new.city, new.state, 1)
    on conflict (city, state)
    do update set clinics_count = (
      select count(*) from public.clinics where city = new.city and state = new.state and is_active = true
    );
  end if;
  if TG_OP = 'DELETE' or TG_OP = 'UPDATE' then
    update public.available_cities
    set clinics_count = (
      select count(*) from public.clinics where city = old.city and state = old.state and is_active = true
    )
    where city = old.city and state = old.state;
  end if;
  return coalesce(new, old);
end;
$$;
create trigger update_city_count_on_clinic_change after insert or update or delete on public.clinics for each row execute function public.update_city_clinics_count();

-- Resgate de recompensas de fidelidade (RPC usada por LoyaltyRepository.redeem no Android).
-- Ver nota (3) no cabecalho: 'debit' corrigido para 'redeem'.
create or replace function public.redeem_reward(
  p_user_id uuid,
  p_reward_name text,
  p_reward_description text,
  p_points_cost integer
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_balance integer;
  v_redemption_id uuid;
begin
  select points_balance into v_current_balance
  from loyalty_accounts
  where user_id = p_user_id
  for update;

  if v_current_balance is null then
    return json_build_object('success', false, 'error', 'Conta de fidelidade não encontrada');
  end if;

  if v_current_balance < p_points_cost then
    return json_build_object('success', false, 'error', 'Saldo insuficiente');
  end if;

  update loyalty_accounts
  set points_balance = points_balance - p_points_cost, updated_at = now()
  where user_id = p_user_id;

  insert into reward_redemptions (user_id, reward_name, reward_description, points_spent, expires_at)
  values (p_user_id, p_reward_name, p_reward_description, p_points_cost, now() + interval '30 days')
  returning id into v_redemption_id;

  insert into loyalty_transactions (user_id, type, source, points, description, reference_id)
  values (p_user_id, 'redeem', 'redemption', -p_points_cost, 'Resgate: ' || p_reward_name, v_redemption_id);

  return json_build_object('success', true, 'redemption_id', v_redemption_id);
end;
$$;

-- Notificacoes automaticas de agendamento/pedido (nota (4) no cabecalho: 'processing'
-- corrigido para 'preparing')
create or replace function public.create_appointment_notification()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    insert into public.notifications (user_id, type, title, message, action_url, metadata)
    values (
      new.user_id, 'appointment', 'Agendamento criado', 'Seu agendamento foi criado com sucesso!',
      '/agendamentos/' || new.id, jsonb_build_object('appointment_id', new.id, 'status', new.status)
    );
  elsif TG_OP = 'UPDATE' and old.status != new.status then
    insert into public.notifications (user_id, type, title, message, action_url, metadata)
    values (
      new.user_id, 'appointment',
      case
        when new.status = 'confirmed' then 'Agendamento confirmado'
        when new.status = 'cancelled' then 'Agendamento cancelado'
        when new.status = 'completed' then 'Atendimento concluído'
        else 'Atualização no agendamento'
      end,
      case
        when new.status = 'confirmed' then 'Seu agendamento foi confirmado!'
        when new.status = 'cancelled' then 'Seu agendamento foi cancelado.'
        when new.status = 'completed' then 'Seu atendimento foi concluído com sucesso!'
        else 'O status do seu agendamento foi atualizado.'
      end,
      '/agendamentos/' || new.id, jsonb_build_object('appointment_id', new.id, 'status', new.status)
    );
  end if;
  return new;
end;
$$;
create trigger notify_appointment_changes after insert or update on public.appointments for each row execute function public.create_appointment_notification();

create or replace function public.create_order_notification()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_OP = 'INSERT' then
    insert into public.notifications (user_id, type, title, message, action_url, metadata)
    values (
      new.user_id, 'order', 'Pedido realizado', 'Seu pedido foi recebido e está sendo processado!',
      '/pedidos/' || new.id, jsonb_build_object('order_id', new.id, 'status', new.status)
    );
  elsif TG_OP = 'UPDATE' and old.status != new.status then
    insert into public.notifications (user_id, type, title, message, action_url, metadata)
    values (
      new.user_id, 'order',
      case
        when new.status = 'preparing' then 'Pedido em processamento'
        when new.status = 'shipped' then 'Pedido enviado'
        when new.status = 'delivered' then 'Pedido entregue'
        when new.status = 'cancelled' then 'Pedido cancelado'
        else 'Atualização no pedido'
      end,
      case
        when new.status = 'preparing' then 'Seu pedido está sendo preparado.'
        when new.status = 'shipped' then 'Seu pedido foi enviado!'
        when new.status = 'delivered' then 'Seu pedido foi entregue com sucesso!'
        when new.status = 'cancelled' then 'Seu pedido foi cancelado.'
        else 'O status do seu pedido foi atualizado.'
      end,
      '/pedidos/' || new.id, jsonb_build_object('order_id', new.id, 'status', new.status)
    );
  end if;
  return new;
end;
$$;
create trigger notify_order_changes after insert or update on public.orders for each row execute function public.create_order_notification();

-- Triggers de updated_at
create trigger update_profiles_updated_at before update on public.profiles for each row execute function public.update_updated_at_column();
create trigger update_pets_updated_at before update on public.pets for each row execute function public.update_updated_at_column();
create trigger update_appointments_updated_at before update on public.appointments for each row execute function public.update_updated_at_column();
create trigger update_clinics_updated_at before update on public.clinics for each row execute function public.update_updated_at_column();
create trigger update_services_updated_at before update on public.services for each row execute function public.update_updated_at_column();
create trigger update_staff_updated_at before update on public.staff for each row execute function public.update_updated_at_column();
create trigger update_scheduling_settings_updated_at before update on public.scheduling_settings for each row execute function public.update_updated_at_column();
create trigger update_products_updated_at before update on public.products for each row execute function public.update_updated_at_column();
create trigger update_orders_updated_at before update on public.orders for each row execute function public.update_updated_at_column();
create trigger update_cart_items_updated_at before update on public.cart_items for each row execute function public.update_updated_at_column();
create trigger update_health_subscriptions_updated_at before update on public.health_subscriptions for each row execute function public.update_updated_at_column();
create trigger update_loyalty_accounts_updated_at before update on public.loyalty_accounts for each row execute function public.update_updated_at_column();
create trigger update_adoption_pets_updated_at before update on public.adoption_pets for each row execute function public.update_updated_at_column();
create trigger update_adoption_requests_updated_at before update on public.adoption_requests for each row execute function public.update_updated_at_column();
create trigger update_reminders_updated_at before update on public.reminders for each row execute function public.update_updated_at_column();
create trigger update_medical_records_updated_at before update on public.medical_records for each row execute function public.update_updated_at_column();
create trigger update_care_logs_updated_at before update on public.care_logs for each row execute function public.update_updated_at_column();
create trigger update_community_posts_updated_at before update on public.community_posts for each row execute function public.update_updated_at_column();
create trigger update_post_comments_updated_at before update on public.post_comments for each row execute function public.update_updated_at_column();
create trigger update_forum_topics_updated_at before update on public.forum_topics for each row execute function public.update_updated_at_column();
create trigger update_forum_replies_updated_at before update on public.forum_replies for each row execute function public.update_updated_at_column();

-- =========================================================================
-- RLS: habilitar em todas as tabelas
-- =========================================================================
alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.pets enable row level security;
alter table public.follows enable row level security;
alter table public.appointments enable row level security;
alter table public.clinics enable row level security;
alter table public.clinic_members enable row level security;
alter table public.available_cities enable row level security;
alter table public.services enable row level security;
alter table public.staff enable row level security;
alter table public.staff_services enable row level security;
alter table public.staff_working_hours enable row level security;
alter table public.staff_time_off enable row level security;
alter table public.clinic_closures enable row level security;
alter table public.scheduling_settings enable row level security;
alter table public.products enable row level security;
alter table public.coupons enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.cart_items enable row level security;
alter table public.health_plans enable row level security;
alter table public.health_subscriptions enable row level security;
alter table public.loyalty_accounts enable row level security;
alter table public.loyalty_transactions enable row level security;
alter table public.reward_redemptions enable row level security;
alter table public.adoption_pets enable row level security;
alter table public.adoption_requests enable row level security;
alter table public.game_scores enable row level security;
alter table public.reminders enable row level security;
alter table public.pet_photos enable row level security;
alter table public.medical_records enable row level security;
alter table public.care_logs enable row level security;
alter table public.community_posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_comments enable row level security;
alter table public.comment_likes enable row level security;
alter table public.forum_topics enable row level security;
alter table public.forum_replies enable row level security;
alter table public.reply_votes enable row level security;
alter table public.reports enable row level security;
alter table public.notifications enable row level security;

-- =========================================================================
-- RLS: policies
-- =========================================================================

-- profiles
create policy "Perfis públicos são visíveis para todos" on public.profiles for select using (is_public = true);
create policy "Usuários podem ver seu próprio perfil" on public.profiles for select using (auth.uid() = user_id);
create policy "Usuários podem atualizar seu próprio perfil" on public.profiles for update using (auth.uid() = user_id);
create policy "Trigger pode criar perfil" on public.profiles for insert with check (auth.uid() = user_id or auth.uid() is null);

-- user_roles (somente leitura pelo cliente; escrita so via trigger SECURITY DEFINER)
create policy "Usuários podem ver seus próprios papéis" on public.user_roles for select using (auth.uid() = user_id);
create policy "Admins podem ver todos os papéis" on public.user_roles for select using (public.has_role(auth.uid(), 'admin'));

-- pets
create policy "Donos podem ver seus próprios pets" on public.pets for select using (auth.uid() = owner_id);
create policy "Pets de perfis públicos são visíveis" on public.pets for select using (
  exists (select 1 from public.profiles where profiles.user_id = pets.owner_id and profiles.is_public = true)
);
create policy "Donos podem criar seus próprios pets" on public.pets for insert with check (auth.uid() = owner_id);
create policy "Donos podem atualizar seus próprios pets" on public.pets for update using (auth.uid() = owner_id);
create policy "Donos podem deletar seus próprios pets" on public.pets for delete using (auth.uid() = owner_id);

-- follows
create policy "Qualquer um pode ver seguidores" on public.follows for select using (true);
create policy "Usuários autenticados podem seguir" on public.follows for insert with check (auth.uid() = follower_id);
create policy "Usuários podem deixar de seguir" on public.follows for delete using (auth.uid() = follower_id);

-- appointments
create policy "Usuários podem ver seus próprios agendamentos" on public.appointments for select using (auth.uid() = user_id);
create policy "Staff pode ver todos agendamentos" on public.appointments for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem criar seus próprios agendamentos" on public.appointments for insert with check (auth.uid() = user_id);
create policy "Usuários podem atualizar seus próprios agendamentos" on public.appointments for update using (auth.uid() = user_id);
create policy "Staff pode atualizar qualquer agendamento" on public.appointments for update using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- clinics
create policy "Clínicas ativas são públicas" on public.clinics for select using (is_active = true);
create policy "Admin pode gerenciar clínicas" on public.clinics for all using (public.has_role(auth.uid(), 'admin'));

-- clinic_members
create policy "Membros de clínica são públicos" on public.clinic_members for select using (is_active = true);
create policy "Gestão de membros da clínica" on public.clinic_members for all using (
  public.has_role(auth.uid(), 'admin') or exists (
    select 1 from public.clinic_members cm
    where cm.clinic_id = clinic_members.clinic_id and cm.user_id = auth.uid() and cm.role in ('owner','admin')
  )
);

-- available_cities
create policy "Cidades são públicas" on public.available_cities for select using (is_active = true and clinics_count > 0);
create policy "Admin pode gerenciar cidades" on public.available_cities for all using (public.has_role(auth.uid(), 'admin'));

-- services
create policy "Serviços ativos são públicos" on public.services for select using (is_active = true);
create policy "Staff pode gerenciar serviços" on public.services for all using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- staff
create policy "Profissionais ativos são públicos" on public.staff for select using (is_active = true);
create policy "Admin pode gerenciar profissionais" on public.staff for all using (public.has_role(auth.uid(), 'admin'));

-- staff_services
create policy "Serviços de profissionais são públicos" on public.staff_services for select using (true);
create policy "Admin pode gerenciar serviços de profissionais" on public.staff_services for all using (public.has_role(auth.uid(), 'admin'));

-- staff_working_hours
create policy "Horários de trabalho são públicos" on public.staff_working_hours for select using (true);
create policy "Admin pode gerenciar horários" on public.staff_working_hours for all using (public.has_role(auth.uid(), 'admin'));

-- staff_time_off
create policy "Folgas são públicas" on public.staff_time_off for select using (true);
create policy "Admin pode gerenciar folgas" on public.staff_time_off for all using (public.has_role(auth.uid(), 'admin'));

-- clinic_closures
create policy "Fechamentos são públicos" on public.clinic_closures for select using (true);
create policy "Admin pode gerenciar fechamentos" on public.clinic_closures for all using (public.has_role(auth.uid(), 'admin'));

-- scheduling_settings
create policy "Configurações são públicas" on public.scheduling_settings for select using (true);
create policy "Admin pode gerenciar configurações" on public.scheduling_settings for all using (public.has_role(auth.uid(), 'admin'));

-- products
create policy "Produtos ativos são públicos" on public.products for select using (is_active = true);
create policy "Staff pode gerenciar produtos" on public.products for all using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- coupons
create policy "Cupons ativos são públicos" on public.coupons for select using (is_active = true and (expires_at is null or expires_at > now()));
create policy "Staff pode gerenciar cupons" on public.coupons for all using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- orders
create policy "Usuários podem ver seus pedidos" on public.orders for select using (auth.uid() = user_id);
create policy "Usuários podem criar pedidos" on public.orders for insert with check (auth.uid() = user_id);
create policy "Staff pode ver todos os pedidos" on public.orders for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Staff pode atualizar pedidos" on public.orders for update using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- order_items
create policy "Usuários podem ver itens de seus pedidos" on public.order_items for select
  using (exists (select 1 from orders where orders.id = order_items.order_id and orders.user_id = auth.uid()));
create policy "Usuários podem criar itens em seus pedidos" on public.order_items for insert
  with check (exists (select 1 from orders where orders.id = order_items.order_id and orders.user_id = auth.uid()));

-- cart_items
create policy "Usuários podem ver seu carrinho" on public.cart_items for select using (auth.uid() = user_id);
create policy "Usuários podem adicionar ao carrinho" on public.cart_items for insert with check (auth.uid() = user_id);
create policy "Usuários podem atualizar seu carrinho" on public.cart_items for update using (auth.uid() = user_id);
create policy "Usuários podem remover do carrinho" on public.cart_items for delete using (auth.uid() = user_id);

-- health_plans
create policy "Planos ativos são públicos" on public.health_plans for select using (is_active = true);
create policy "Staff pode gerenciar planos" on public.health_plans for all using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- health_subscriptions
create policy "Usuários podem ver suas assinaturas" on public.health_subscriptions for select using (auth.uid() = user_id);
create policy "Usuários podem criar assinaturas" on public.health_subscriptions for insert with check (auth.uid() = user_id);
create policy "Usuários podem cancelar assinaturas" on public.health_subscriptions for update using (auth.uid() = user_id);
create policy "Staff pode ver todas as assinaturas" on public.health_subscriptions for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- loyalty_accounts
create policy "Usuários podem ver sua conta de fidelidade" on public.loyalty_accounts for select using (auth.uid() = user_id);
create policy "Staff pode ver todas as contas" on public.loyalty_accounts for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- loyalty_transactions
create policy "Usuários podem ver suas transações" on public.loyalty_transactions for select using (auth.uid() = user_id);
create policy "Staff pode ver todas as transações" on public.loyalty_transactions for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- reward_redemptions (insert somente via RPC redeem_reward, SECURITY DEFINER)
create policy "Usuários podem ver seus resgates" on public.reward_redemptions for select using (auth.uid() = user_id);
create policy "Staff pode ver todos os resgates" on public.reward_redemptions for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- adoption_pets
create policy "Pets para adoção são públicos" on public.adoption_pets for select using (status = 'disponivel');
create policy "Staff pode gerenciar pets de adoção" on public.adoption_pets for all using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- adoption_requests
create policy "Usuários podem ver suas solicitações" on public.adoption_requests for select using (auth.uid() = user_id);
create policy "Usuários podem criar solicitações" on public.adoption_requests for insert with check (auth.uid() = user_id);
create policy "Staff pode gerenciar solicitações" on public.adoption_requests for all using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- game_scores
create policy "Pontuações são públicas" on public.game_scores for select using (true);
create policy "Usuários podem salvar suas pontuações" on public.game_scores for insert with check (auth.uid() = user_id);

-- reminders
create policy "Usuários podem ver seus lembretes" on public.reminders for select using (auth.uid() = user_id);
create policy "Usuários podem criar lembretes" on public.reminders for insert with check (auth.uid() = user_id);
create policy "Usuários podem atualizar seus lembretes" on public.reminders for update using (auth.uid() = user_id);
create policy "Usuários podem deletar seus lembretes" on public.reminders for delete using (auth.uid() = user_id);

-- pet_photos
create policy "Usuários podem ver fotos de seus pets" on public.pet_photos for select using (auth.uid() = user_id);
create policy "Fotos de perfis públicos são visíveis" on public.pet_photos for select using (
  exists (select 1 from profiles where profiles.user_id = pet_photos.user_id and profiles.is_public = true)
);
create policy "Usuários podem adicionar fotos" on public.pet_photos for insert with check (auth.uid() = user_id);
create policy "Usuários podem deletar suas fotos" on public.pet_photos for delete using (auth.uid() = user_id);

-- medical_records
create policy "Usuários podem ver registros de seus pets" on public.medical_records for select using (auth.uid() = user_id);
create policy "Usuários podem criar registros" on public.medical_records for insert with check (auth.uid() = user_id);
create policy "Usuários podem atualizar seus registros" on public.medical_records for update using (auth.uid() = user_id);
create policy "Usuários podem deletar seus registros" on public.medical_records for delete using (auth.uid() = user_id);

-- care_logs
create policy "Usuários podem ver seus logs de cuidado" on public.care_logs for select using (auth.uid() = user_id);
create policy "Usuários podem criar logs" on public.care_logs for insert with check (auth.uid() = user_id);
create policy "Usuários podem atualizar seus logs" on public.care_logs for update using (auth.uid() = user_id);
create policy "Usuários podem deletar seus logs" on public.care_logs for delete using (auth.uid() = user_id);

-- community_posts
create policy "Posts visíveis são públicos" on public.community_posts for select using (is_hidden = false);
create policy "Staff pode ver todos os posts" on public.community_posts for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem criar posts" on public.community_posts for insert with check (auth.uid() = author_id);
create policy "Usuários podem editar seus posts" on public.community_posts for update using (auth.uid() = author_id);
create policy "Staff pode ocultar posts" on public.community_posts for update using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem deletar seus posts" on public.community_posts for delete using (auth.uid() = author_id);

-- post_likes
create policy "Curtidas são públicas" on public.post_likes for select using (true);
create policy "Usuários podem curtir" on public.post_likes for insert with check (auth.uid() = user_id);
create policy "Usuários podem descurtir" on public.post_likes for delete using (auth.uid() = user_id);

-- post_comments
create policy "Comentários visíveis são públicos" on public.post_comments for select using (is_hidden = false);
create policy "Staff pode ver todos os comentários" on public.post_comments for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem comentar" on public.post_comments for insert with check (auth.uid() = author_id);
create policy "Usuários podem editar seus comentários" on public.post_comments for update using (auth.uid() = author_id);
create policy "Staff pode ocultar comentários" on public.post_comments for update using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem deletar seus comentários" on public.post_comments for delete using (auth.uid() = author_id);

-- comment_likes
create policy "Curtidas de comentários são públicas" on public.comment_likes for select using (true);
create policy "Usuários podem curtir comentários" on public.comment_likes for insert with check (auth.uid() = user_id);
create policy "Usuários podem descurtir comentários" on public.comment_likes for delete using (auth.uid() = user_id);

-- forum_topics
create policy "Tópicos visíveis são públicos" on public.forum_topics for select using (is_hidden = false);
create policy "Staff pode ver todos os tópicos" on public.forum_topics for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem criar tópicos" on public.forum_topics for insert with check (auth.uid() = author_id);
create policy "Usuários podem editar seus tópicos" on public.forum_topics for update using (auth.uid() = author_id);
create policy "Staff pode moderar tópicos" on public.forum_topics for update using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem deletar seus tópicos" on public.forum_topics for delete using (auth.uid() = author_id);

-- forum_replies
create policy "Respostas visíveis são públicas" on public.forum_replies for select using (is_hidden = false);
create policy "Staff pode ver todas as respostas" on public.forum_replies for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem responder" on public.forum_replies for insert with check (auth.uid() = author_id);
create policy "Usuários podem editar suas respostas" on public.forum_replies for update using (auth.uid() = author_id);
create policy "Staff pode moderar respostas" on public.forum_replies for update using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem deletar suas respostas" on public.forum_replies for delete using (auth.uid() = author_id);

-- reply_votes
create policy "Votos são públicos" on public.reply_votes for select using (true);
create policy "Usuários podem votar" on public.reply_votes for insert with check (auth.uid() = user_id);
create policy "Usuários podem remover voto" on public.reply_votes for delete using (auth.uid() = user_id);

-- reports
create policy "Usuários podem ver suas denúncias" on public.reports for select using (auth.uid() = reporter_id);
create policy "Staff pode ver todas as denúncias" on public.reports for select using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));
create policy "Usuários podem denunciar" on public.reports for insert with check (auth.uid() = reporter_id);
create policy "Staff pode atualizar denúncias" on public.reports for update using (public.has_role(auth.uid(), 'staff') or public.has_role(auth.uid(), 'admin'));

-- notifications (sem policy de INSERT para o cliente -- ver nota (5) no cabecalho;
-- as triggers que geram notificacoes sao SECURITY DEFINER e nao dependem de RLS)
create policy "Users can view their own notifications" on public.notifications for select using (auth.uid() = user_id);
create policy "Users can update their own notifications" on public.notifications for update using (auth.uid() = user_id);
create policy "Users can delete their own notifications" on public.notifications for delete using (auth.uid() = user_id);

-- =========================================================================
-- STORAGE: buckets e policies
-- =========================================================================
insert into storage.buckets (id, name, public) values
  ('avatars', 'avatars', true),
  ('pets', 'pets', true),
  ('clinics', 'clinics', true)
on conflict (id) do nothing;

create policy "Avatar images are publicly accessible" on storage.objects for select using (bucket_id = 'avatars');
create policy "Users can upload their own avatar" on storage.objects for insert with check (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
create policy "Users can update their own avatar" on storage.objects for update using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
create policy "Users can delete their own avatar" on storage.objects for delete using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "Pet images are publicly accessible" on storage.objects for select using (bucket_id = 'pets');
create policy "Pet owners can upload pet photos" on storage.objects for insert with check (bucket_id = 'pets' and auth.uid()::text = (storage.foldername(name))[1]);
create policy "Pet owners can update pet photos" on storage.objects for update using (bucket_id = 'pets' and auth.uid()::text = (storage.foldername(name))[1]);
create policy "Pet owners can delete pet photos" on storage.objects for delete using (bucket_id = 'pets' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "Clinic images are publicly accessible" on storage.objects for select using (bucket_id = 'clinics');
create policy "Clinic members can upload clinic images" on storage.objects for insert with check (
  bucket_id = 'clinics' and exists (
    select 1 from public.clinic_members
    where clinic_id::text = (storage.foldername(name))[1] and user_id = auth.uid() and is_active = true
  )
);
create policy "Clinic members can update clinic images" on storage.objects for update using (
  bucket_id = 'clinics' and exists (
    select 1 from public.clinic_members
    where clinic_id::text = (storage.foldername(name))[1] and user_id = auth.uid() and is_active = true
  )
);
create policy "Clinic members can delete clinic images" on storage.objects for delete using (
  bucket_id = 'clinics' and exists (
    select 1 from public.clinic_members
    where clinic_id::text = (storage.foldername(name))[1] and user_id = auth.uid() and is_active = true
  )
);

-- =========================================================================
-- DADOS DE BOOTSTRAP (configuracao global, nao dados fabricados de clinica/cidade)
-- =========================================================================
insert into public.scheduling_settings (max_advance_days, min_advance_hours, cancellation_hours)
values (60, 2, 4);
