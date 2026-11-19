create table public.exchanges (
  id          uuid primary key,
  created_at  timestamptz not null default now(),
  asked_at    timestamptz not null,
  recalled    int not null,
  question    text not null,
  answer      text not null,
  screens     int not null,
  pointed     jsonb,
  shots       text[] not null default '{}'
);

alter table public.exchanges enable row level security;

create policy "app inserts exchanges" on public.exchanges
  for insert to anon with check (true);

insert into storage.buckets (id, name, public) values ('exchanges', 'exchanges', false);

create policy "app uploads exchange screenshots" on storage.objects
  for insert to anon with check (bucket_id = 'exchanges');
