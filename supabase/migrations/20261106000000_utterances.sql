create table public.utterances (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  started_at      timestamptz not null,
  ended_at        timestamptz not null,
  holds           int not null default 1,
  final_text      text,
  outcome         text not null check (outcome in ('heard', 'silence', 'failed')),
  via             text check (via in ('endpoint', 'termination', 'fallback', 'failure')),
  failure         text,
  token           text check (token in ('minted', 'reused')),
  opened_after_ms int,
  final_after_ms  int,
  audio_ms        int,
  partials        jsonb not null default '[]',
  audio_path      text
);

alter table public.utterances enable row level security;

create policy "app inserts utterances" on public.utterances
  for insert to anon with check (true);

insert into storage.buckets (id, name, public) values ('utterances', 'utterances', false);

create policy "app uploads utterance audio" on storage.objects
  for insert to anon with check (bucket_id = 'utterances');
