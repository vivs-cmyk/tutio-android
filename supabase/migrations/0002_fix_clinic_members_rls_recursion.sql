-- Corrige 42P17 (infinite recursion detected in policy for relation "clinic_members").
--
-- Causa raiz: a policy "Gestao de membros da clinica" (0001_initial_schema.sql) usa, na
-- sua propria clausula USING, um EXISTS que consulta a MESMA tabela clinic_members:
--
--   exists (select 1 from public.clinic_members cm where cm.clinic_id = clinic_members.clinic_id ...)
--
-- Para qualquer role que nao seja o dono da tabela (ex.: "authenticated", usado pelo app),
-- essa subquery interna tambem esta sujeita a RLS, o que forca reavaliar a mesma policy de
-- novo, indefinidamente -> 42P17. Isso so nao apareceu nas minhas proprias validacoes porque
-- a conexao do MCP usa a role "postgres", dona da tabela (relforcerowsecurity=false), que
-- contorna RLS por padrao independente das policies.
--
-- Correcao: mover a checagem "sou owner/admin desta clinica" para uma funcao SECURITY
-- DEFINER (mesmo padrao ja usado por has_role/is_clinic_member/has_clinic_role). A funcao
-- executa com o privilegio do dono (postgres, dono da tabela), entao a consulta interna a
-- clinic_members dentro dela NAO reaciona RLS -- quebra o ciclo.

create or replace function public.is_clinic_manager(_user_id uuid, _clinic_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.clinic_members cm
    where cm.clinic_id = _clinic_id and cm.user_id = _user_id and cm.role in ('owner','admin') and cm.is_active = true
  )
$$;

revoke all on function public.is_clinic_manager(uuid, uuid) from public;
revoke all on function public.is_clinic_manager(uuid, uuid) from anon;
grant execute on function public.is_clinic_manager(uuid, uuid) to authenticated;

drop policy if exists "Gestão de membros da clínica" on public.clinic_members;

create policy "Gestão de membros da clínica" on public.clinic_members for all
  using (
    public.has_role(auth.uid(), 'admin')
    or public.is_clinic_manager(auth.uid(), clinic_id)
  );

-- Mantida sem alteracao (nao recursiva, ja publica leitura de membros ativos):
-- "Membros de clínica são públicos" on public.clinic_members for select using (is_active = true)
