-- OA 360 · Esquema de base de datos para Supabase
-- Ejecutar una sola vez en Supabase → SQL Editor → New query → Run.

create extension if not exists pgcrypto;

create table if not exists public.docs (
  col text not null,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (col, id)
);
alter table public.docs replica identity full;
alter table public.docs enable row level security;

-- Solo usuarios con sesión (invitados por ti) leen y escriben. Nadie de fuera ve nada.
drop policy if exists "equipo lee" on public.docs;
drop policy if exists "equipo inserta" on public.docs;
drop policy if exists "equipo actualiza" on public.docs;
drop policy if exists "equipo borra" on public.docs;
create policy "equipo lee" on public.docs for select to authenticated using (true);
create policy "equipo inserta" on public.docs for insert to authenticated with check (true);
create policy "equipo actualiza" on public.docs for update to authenticated using (true) with check (true);
create policy "equipo borra" on public.docs for delete to authenticated using (true);

-- Tiempo real (los cambios aparecen al instante en todas las pantallas)
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;

-- Actualización parcial de un documento
create or replace function public.doc_merge(p_col text, p_id text, p_patch jsonb)
returns void language sql security invoker set search_path = public as $$
  insert into public.docs (col, id, data) values (p_col, p_id, p_patch)
  on conflict (col, id) do update set data = public.docs.data || excluded.data, updated_at = now();
$$;
revoke all on function public.doc_merge(text, text, jsonb) from public, anon;
grant execute on function public.doc_merge(text, text, jsonb) to authenticated;

-- Portal del cliente (/reportar.html): solo puede CREAR un ticket o una solicitud de tóner; no lee nada.
create or replace function public.portal_reporte(
  p_tipo text, p_empresa text, p_nombre text, p_contacto text, p_serie text, p_desc text, p_compromiso bigint)
returns text language plpgsql security definer set search_path = public as $$
declare
  pref text; n int; fol text; nid text; eq record; ahora bigint := (extract(epoch from now()) * 1000)::bigint;
  serie_norm text := upper(regexp_replace(coalesce(p_serie, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(coalesce(trim(p_empresa), '')) < 2 or length(coalesce(trim(p_desc), '')) < 3
     or length(coalesce(trim(p_contacto), '')) < 5 then
    raise exception 'Faltan datos';
  end if;
  if (select count(*) from public.docs where col in ('tickets','solicitudes')
        and data->>'canal' = 'Portal' and updated_at > now() - interval '1 hour') > 40 then
    raise exception 'Demasiados reportes; intenta más tarde';
  end if;
  pref := case when p_tipo = 'toner' then 'SAL' else 'OASA' end;
  insert into public.docs (col, id, data) values ('config', 'contadores', jsonb_build_object(pref, 1))
  on conflict (col, id) do update
    set data = public.docs.data || jsonb_build_object(pref, coalesce((public.docs.data->>pref)::int, 0) + 1), updated_at = now()
  returning (data->>pref)::int into n;
  fol := pref || '-' || lpad(n::text, 4, '0');
  nid := 'p' || replace(gen_random_uuid()::text, '-', '');
  select id, data into eq from public.docs where col = 'equipos' and id = serie_norm limit 1;

  if p_tipo = 'toner' then
    insert into public.docs (col, id, data) values ('solicitudes', nid, jsonb_build_object(
      'folio', fol, 'clienteId', coalesce(eq.data->>'clienteId', ''), 'cliente', coalesce(eq.data->>'cliente', left(p_empresa, 120)),
      'solicitante', left(p_nombre, 120), 'contacto', left(p_contacto, 120), 'canal', 'Portal',
      'partidas', jsonb_build_array(jsonb_build_object('toner', left(p_desc, 300), 'impresora', coalesce(eq.data->>'modelo', left(p_serie, 60)), 'cant', 1)),
      'estado', 'pendiente', 'fecha', ahora));
  else
    insert into public.docs (col, id, data) values ('tickets', nid, jsonb_build_object(
      'folio', fol, 'creado', ahora, 'compromiso', p_compromiso,
      'clienteId', coalesce(eq.data->>'clienteId', ''), 'cliente', coalesce(eq.data->>'cliente', left(p_empresa, 120)),
      'equipoId', coalesce(eq.id, ''), 'serie', coalesce(eq.data->>'serie', left(p_serie, 60)), 'modelo', coalesce(eq.data->>'modelo', ''),
      'ubicacion', coalesce(eq.data->>'ubicacion', ''), 'tipo', 'Correctivo', 'prioridad', 'Normal', 'canal', 'Portal',
      'reportadoPor', left(p_nombre, 120), 'telefono', left(p_contacto, 120), 'depto', '', 'desc', left(p_desc, 2000),
      'tecnicoId', '', 'estado', 'abierto', 'checklist', '{}'::jsonb,
      'hist', jsonb_build_array(jsonb_build_object('t', ahora, 'ev', 'Reportado por el cliente desde el portal', 'por', ''))));
  end if;
  return fol;
end $$;
revoke all on function public.portal_reporte(text, text, text, text, text, text, bigint) from public;
grant execute on function public.portal_reporte(text, text, text, text, text, text, bigint) to anon, authenticated;

-- Fotos de los servicios
insert into storage.buckets (id, name, public) values ('fotos', 'fotos', true) on conflict (id) do nothing;
drop policy if exists "equipo sube fotos" on storage.objects;
create policy "equipo sube fotos" on storage.objects for insert to authenticated with check (bucket_id = 'fotos');
