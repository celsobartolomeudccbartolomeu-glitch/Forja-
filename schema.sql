-- FORJA · Supabase
-- Corre este ficheiro inteiro no SQL Editor do Supabase (uma vez).
-- Regra: visitantes leem tudo; contas criadas publicam; cada um só altera o que é seu.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (char_length(username) between 3 and 24),
  bio text not null default '',
  role text not null default 'user' check (role in ('owner','user')),
  created_at timestamptz not null default now()
);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid references public.profiles(id) on delete cascade,
  author_name text not null default 'FORJA',
  kind text not null check (kind in ('project','code','video')),
  title text not null check (char_length(title) between 3 and 120),
  summary text not null check (char_length(summary) between 10 and 800),
  code text,
  language text,
  repo_url text,
  demo_url text,
  video_url text,
  video_path text,
  tags text[] not null default '{}',
  pinned boolean not null default false,
  sort_order int not null default 0,
  like_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint code_needs_code check (kind <> 'code' or code is not null),
  constraint video_needs_source check (kind <> 'video' or (video_url is not null or video_path is not null))
);

create table if not exists public.likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.tech (
  id uuid primary key default gen_random_uuid(),
  author_id uuid references public.profiles(id) on delete cascade,
  author text not null default 'FORJA',
  title text not null check (char_length(title) between 4 and 120),
  "desc" text not null check (char_length("desc") between 20 and 1200),
  stack text[] not null default '{}',
  cat text not null default 'Ferramentas',
  diff text not null default 'média' check (diff in ('fácil','média','difícil')),
  likes int not null default 0,
  created timestamptz not null default now()
);

create table if not exists public.tech_likes (
  tech_id uuid not null references public.tech(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (tech_id, user_id)
);

create table if not exists public.saved_views (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 40),
  filters jsonb not null default '{}',
  created_at timestamptz not null default now()
);
-- perfil automático no registo; o primeiro utilizador é o dono
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare uname text;
begin
  uname := coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1));
  uname := regexp_replace(lower(uname), '[^a-z0-9_]', '_', 'g');
  if char_length(uname) < 3 then uname := 'dev_' || substr(md5(random()::text),1,6); end if;
  begin
    insert into public.profiles (id, username, role)
    values (new.id, uname, case when not exists (select 1 from public.profiles) then 'owner' else 'user' end);
  exception when unique_violation then
    insert into public.profiles (id, username, role)
    values (new.id, uname || '_' || substr(md5(random()::text),1,4), 'user');
  end;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.set_post_author()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.author_id is not null then
    select username into new.author_name from public.profiles where id = new.author_id;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists posts_author_write on public.posts;
create trigger posts_author_write before insert or update on public.posts
for each row execute function public.set_post_author();

create or replace function public.set_tech_author()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.author_id is not null then
    select username into new.author from public.profiles where id = new.author_id;
  end if;
  return new;
end $$;

drop trigger if exists tech_author_write on public.tech;
create trigger tech_author_write before insert or update on public.tech
for each row execute function public.set_tech_author();

create or replace function public.bump_like_count()
returns trigger language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  pid := coalesce(new.post_id, old.post_id);
  update public.posts set like_count = (select count(*) from public.likes where post_id = pid) where id = pid;
  return coalesce(new, old);
end $$;

drop trigger if exists likes_count_i on public.likes;
create trigger likes_count_i after insert on public.likes
for each row execute function public.bump_like_count();
drop trigger if exists likes_count_d on public.likes;
create trigger likes_count_d after delete on public.likes
for each row execute function public.bump_like_count();

create or replace function public.bump_tech_likes()
returns trigger language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  tid := coalesce(new.tech_id, old.tech_id);
  update public.tech set likes = (select count(*) from public.tech_likes where tech_id = tid) where id = tid;
  return coalesce(new, old);
end $$;

drop trigger if exists tech_likes_i on public.tech_likes;
create trigger tech_likes_i after insert on public.tech_likes
for each row execute function public.bump_tech_likes();
drop trigger if exists tech_likes_d on public.tech_likes;
create trigger tech_likes_d after delete on public.tech_likes
for each row execute function public.bump_tech_likes();
alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.likes enable row level security;
alter table public.tech enable row level security;
alter table public.tech_likes enable row level security;
alter table public.saved_views enable row level security;

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select using (true);
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update
using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists posts_read on public.posts;
create policy posts_read on public.posts for select using (true);
drop policy if exists posts_insert_auth on public.posts;
create policy posts_insert_auth on public.posts for insert to authenticated
with check (author_id = auth.uid());
drop policy if exists posts_update_own on public.posts;
create policy posts_update_own on public.posts for update to authenticated
using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists posts_delete_own on public.posts;
create policy posts_delete_own on public.posts for delete to authenticated
using (author_id = auth.uid());

drop policy if exists likes_read on public.likes;
create policy likes_read on public.likes for select using (true);
drop policy if exists likes_insert_own on public.likes;
create policy likes_insert_own on public.likes for insert to authenticated
with check (user_id = auth.uid());
drop policy if exists likes_delete_own on public.likes;
create policy likes_delete_own on public.likes for delete to authenticated
using (user_id = auth.uid());

drop policy if exists tech_read on public.tech;
create policy tech_read on public.tech for select using (true);
drop policy if exists tech_insert_auth on public.tech;
create policy tech_insert_auth on public.tech for insert to authenticated
with check (author_id = auth.uid());
drop policy if exists tech_update_own on public.tech;
create policy tech_update_own on public.tech for update to authenticated
using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists tech_delete_own on public.tech;
create policy tech_delete_own on public.tech for delete to authenticated
using (author_id = auth.uid());

drop policy if exists tech_likes_read on public.tech_likes;
create policy tech_likes_read on public.tech_likes for select using (true);
drop policy if exists tech_likes_insert_own on public.tech_likes;
create policy tech_likes_insert_own on public.tech_likes for insert to authenticated
with check (user_id = auth.uid());
drop policy if exists tech_likes_delete_own on public.tech_likes;
create policy tech_likes_delete_own on public.tech_likes for delete to authenticated
using (user_id = auth.uid());

drop policy if exists views_own on public.saved_views;
create policy views_own on public.saved_views for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.posts, public.likes, public.tech, public.tech_likes, public.saved_views to anon, authenticated;
grant insert, update, delete on public.posts, public.likes, public.tech, public.tech_likes, public.saved_views to authenticated;
grant update (username, bio) on public.profiles to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('forja-videos','forja-videos', true, 52428576, array['video/mp4','video/webm','video/ogg'])
on conflict (id) do update set public = true, file_size_limit = 52428576,
  allowed_mime_types = array['video/mp4','video/webm','video/ogg'];

drop policy if exists forja_videos_read on storage.objects;
create policy forja_videos_read on storage.objects for select
using (bucket_id = 'forja-videos');
drop policy if exists forja_videos_insert on storage.objects;
create policy forja_videos_insert on storage.objects for insert to authenticated
with check (bucket_id = 'forja-videos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists forja_videos_update on storage.objects;
create policy forja_videos_update on storage.objects for update to authenticated
using (bucket_id = 'forja-videos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists forja_videos_delete on storage.objects;
create policy forja_videos_delete on storage.objects for delete to authenticated
using (bucket_id = 'forja-videos' and (storage.foldername(name))[1] = auth.uid()::text);

-- conteúdo inicial
do $$
begin
  if not exists (select 1 from public.posts) then
    insert into public.posts (author_name, kind, title, summary, code, language, video_url, tags, pinned, sort_order) values
    ('FORJA','project','Sistema Escolar Web','Matrículas, confirmações e médias sem papel. Schema SQL primeiro, rotas depois — uma escola real a usar vale por mil demos.',null,null,null,array['Escolas','Node','SQL'],true,10),
    ('FORJA','code','Médias da turma','Funções puras para calcular médias por aluno e por turma. Copia, cola na IDE e corre.',
$code$const turma = [
  { nome: "Ana", notas: [14, 16, 12] },
  { nome: "Bruno", notas: [9, 11, 10] },
  { nome: "Carla", notas: [17, 18, 19] }
];
const media = ns => ns.reduce((a, b) => a + b, 0) / ns.length;
console.table(turma.map(a => ({
  aluno: a.nome,
  media: +media(a.notas).toFixed(1),
  situacao: media(a.notas) >= 10 ? "Aprovado" : "Reprovado"
})));$code$,'js',null,array['JavaScript','Escolas'],true,20),
    ('FORJA','video','Leitor de vídeo da comunidade','Demonstração do leitor: contas criadas publicam vídeos por URL ou upload; visitantes apenas assistem. Ficheiro de exemplo, domínio público.',null,null,'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4',array['Demo','Vídeo'],false,30),
    ('FORJA','code','Tabuada em FORJA·lang','O modo demo da IDE usa palavras-chave em português: var, mostra, se, enquanto. Este snippet corre no editor.',
$code$var n = 7
var i = 1
enquanto i <= 10 {
  mostra n + " × " + i + " = " + (n * i)
  i = i + 1
}$code$,'forja',null,array['Linguagem','Demo'],false,40),
    ('FORJA','project','Linguagem + IDE Web','Linguagem própria com IDE web e versão desktop, escrita no telemóvel. O módulo FORJA·lang desta IDE é o primeiro tijolo.',null,null,null,array['Interpretador','JavaScript'],false,50),
    ('FORJA','code','Schema SQLite escolar','Tabelas, chaves estrangeiras e CHECKs antes do código. Uma base bem desenhada evita metade dos bugs.',
$code$CREATE TABLE IF NOT EXISTS notas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  aluno_id INTEGER NOT NULL REFERENCES alunos(id) ON DELETE CASCADE,
  disciplina TEXT NOT NULL,
  trimestre INTEGER NOT NULL CHECK (trimestre BETWEEN 1 AND 3),
  valor REAL NOT NULL CHECK (valor BETWEEN 0 AND 20)
);$code$,'sql',null,array['SQL','Escolas'],false,60);
  end if;

  if not exists (select 1 from public.tech) then
    insert into public.tech (author, title, "desc", stack, cat, diff, likes) values
    ('FORJA','Leitor QR para confirmação de matrícula','Cada matrícula gera um QR; à porta da escola um telemóvel lê e confirma em segundos. Liga direto ao sistema escolar.',array['JavaScript','PWA','SQLite'],'Escolas','média',14),
    ('FORJA','PWA de horários offline','Horário de aulas que abre sem internet, guardado no dispositivo com IndexedDB e atualizado quando há rede.',array['HTML','IndexedDB','Service Worker'],'Escolas','fácil',9),
    ('FORJA','Sincronizador TrebEdit ↔ GitHub','Um script no Termux que faz commit e push automático das pastas de projeto no fim do dia. Backup sem pensar.',array['Node','Git','Termux'],'Ferramentas','média',21),
    ('FORJA','Bot de médias por WhatsApp','O encarregado envia o número do aluno e recebe as médias do trimestre. Ponte entre a base escolar e a app que todos usam.',array['Node','API WhatsApp','SQLite'],'Escolas','difícil',17),
    ('FORJA','Cantina escolar sem filas','Saldo e senhas digitais: o aluno paga por transferência, recebe um código, e a fila anda. Relatório diário automático.',array['Node','SQLite','QR'],'Escolas','média',8),
    ('FORJA','Mini-IDE de linguagem em português','Interpretador com palavras-chave em PT e editor no browser — o primeiro passo para ensinar programação sem a barreira do inglês.',array['JavaScript','Parser'],'Ferramentas','difícil',26);
  end if;
end $$;
