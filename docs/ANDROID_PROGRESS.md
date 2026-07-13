# Progresso Android

## 2026-07-13 — Correção: recursão RLS em clinic_members (42P17) + paleta escura nativa

### 42P17 — infinite recursion detected in policy for relation "clinic_members"

**Causa raiz confirmada (não presumida):** a policy `"Gestão de membros da clínica"`
(criada em `0001_initial_schema.sql`) usava, na própria cláusula `USING`, um
`EXISTS (SELECT 1 FROM public.clinic_members cm WHERE ...)` — uma subquery contra a MESMA
tabela que a policy protege. Para qualquer role que não seja dona da tabela (ex.:
`authenticated`, usado pelo app real), essa subquery interna também está sujeita a RLS, o
que força reavaliar a mesma policy de novo, indefinidamente. Isso não apareceu nas minhas
validações anteriores porque a conexão do MCP usa a role `postgres` (dona da tabela,
`relforcerowsecurity=false`), que contorna RLS por padrão independente das policies —
confirmado via `pg_class`/`current_setting('is_superuser')` (`is_superuser = off`, mas
`table_owner = postgres = current_user`).

**Prova de causa e efeito (mesma query, antes e depois):**
```sql
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','<uuid_real>','role','authenticated')::text, true);
select * from public.clinic_members;
rollback;
```
- **Antes** da correção: `ERROR: 42P17: infinite recursion detected in policy for relation "clinic_members"`.
- **Depois** da correção: sem erro, `auth.uid()` resolvido corretamente, `count(*) = 0`
  linhas (tabela vazia).

**Correção aplicada** (`supabase/migrations/0002_fix_clinic_members_rls_recursion.sql`,
via `apply_migration`): nova função `public.is_clinic_manager(_user_id uuid, _clinic_id uuid)`
(`SECURITY DEFINER`, `search_path = public`, mesmo padrão de `has_role`/`is_clinic_member`/
`has_clinic_role`) — executa com o privilégio do dono da tabela, então a consulta interna a
`clinic_members` dentro dela não reaciona RLS, quebrando o ciclo. `EXECUTE` restrito a
`authenticated` (revogado de `public`/`anon`). A policy recursiva foi substituída para
chamar essa função em vez do `EXISTS` direto; a policy pública de leitura
(`"Membros de clínica são públicos"`, `is_active = true`) não mudou — nunca foi recursiva.

**Limitação honesta, não contornada:** `clinic_members` está com **0 linhas** no projeto
(nenhum staff/clínica vinculado ainda). Não é possível provar isolamento entre clínicas
(teste positivo "vejo meu vínculo" / negativo "não vejo o de outra clínica") sem dados reais
de mais de um vínculo — e não fabriquei esses dados só para o teste passar. Fica pendente
validar isolamento assim que houver pelo menos 2 `clinic_members` reais (ex.: ao cadastrar a
primeira clínica e vincular staff via `MasterClinicas`/admin).

### Paleta escura persistente (causa diferente da sessão anterior)

A sessão anterior corrigiu `TutIoTheme.kt` (parou de seguir `isSystemInDarkTheme()`) e as
system bars via `WindowCompat` em `MainActivity.kt` — mas isso só cobre o Compose. O tema
NATIVO pré-Compose (`app/src/main/res/values/themes.xml`, `Theme.TutIo` com
`parent="Theme.Material3.DayNight.NoActionBar"`) continuava resolvendo
`app/src/main/res/values-night/themes.xml` + `values-night/colors.xml` quando o sistema
está em modo escuro — isso define a cor de fundo da Window e o status bar ANTES do primeiro
frame do Compose, independentemente do `TutIoTheme` do Compose. `values-night/colors.xml`
tinha `tutio_native_background = #111822` (escuro real), causando a paleta escura
percebida mesmo após a correção anterior.

**Corrigido:** `values-night/colors.xml` e `values-night/themes.xml` agora espelham
`values/` (mesmas cores claras, `windowLightStatusBar=true`), e ambos os `themes.xml`
ganharam `android:forceDarkAllowed="false"` (`tools:targetApi="q"`). Nenhum outro
composable desenha fora do escopo de `TutIoTheme`/`MaterialTheme` — todas as ~50 telas
(incluindo estados de carregamento/erro em `TutStateComposables.kt`) consomem
`TutIoTheme.colors`/`MaterialTheme.colorScheme` via composition local, confirmado por
varredura completa do código-fonte.

### Como foi validado
- `pg_policies`/`pg_class` antes e depois da correção (evidência acima).
- Teste transacional como `authenticated` com UUID real, em uma única chamada
  `execute_sql` (`begin`...`rollback`), antes e depois — erro reproduzido, depois eliminado.
- `gradlew.bat clean assembleDebug` → `BUILD SUCCESSFUL in 5m 42s` (522 tasks).
- **Não testado visualmente no aparelho**: havia 1 dispositivo conectado (`RQCR700H63J`)
  antes do build; desconectou durante os ~6 min de build e não voltou a aparecer em
  `adb devices` depois. Instalação/teste de comportamento visual real ficam pendentes —
  não afirmo que o app "abre com paleta clara no aparelho" porque não observei isso, só que
  o build compila e a causa raiz identificada foi corrigida no código-fonte.

### Pendências reais
1. Reinstalar e abrir o app no aparelho físico quando reconectado, confirmar visualmente
   paleta clara e ausência de 42P17 no fluxo de login real.
2. Validar isolamento entre clínicas em `clinic_members` assim que houver ≥2 vínculos reais.

## 2026-07-13 — Bootstrap do schema Supabase (projeto novo, causa raiz do PGRST205)

### Contexto
Login com Google real no dispositivo físico Samsung SM-A326B falhava com
`PGRST205: Could not find the table 'public.user_roles' in the schema cache`. Causa raiz:
o projeto Supabase (`nbbiwzpktvkacmldwiyk`) era novo, com schema `public` vazio — o código
Kotlin (Domínios 1-10, já implementado) sempre esperou o schema real do backend, que nunca
tinha sido aplicado a este projeto especificamente.

### O que foi implementado
Migration única `supabase/migrations/0001_initial_schema.sql`, aplicada via MCP do Supabase
(`apply_migration`, nome `initial_schema`). Fonte: as 13 migrations reais de
`tutio-web-reference/supabase/migrations/*.sql` (mesmo produto, mesmo backend, conforme
CLAUDE.md) — lidas por completo e consolidadas em uma migration coerente, em vez de
engenharia reversa a partir do uso no Kotlin. 40 tabelas, 8 enums, 14 funções (todas
`security definer` com `search_path` explícito onde aplicável), ~40 triggers, ~150 policies
RLS, 3 buckets de storage (`avatars`, `pets`, `clinics`) com 12 policies em
`storage.objects`.

Divergências deliberadas da fonte (SQL comentado no cabeçalho do arquivo):
1. Não replicado o `INSERT` da clínica fictícia "Praia dos Bichos" (UUID fixo) nem o seed
   de `available_cities` para Caraguatatuba — dados de demonstração presos à marca antiga,
   incompatíveis com "nunca clinic_id/IDs fabricados em produção" do CLAUDE.md. Este projeto
   é produção nova, sem clínicas reais ainda; a primeira clínica real deve ser cadastrada
   pelo master (`MasterClinicas`), não fabricada por mim.
2. `handle_new_user` cria somente `profiles`, não insere `user_roles` — é o comportamento
   final real do backend web (uma migration posterior sobrescreveu a versão que também
   inseria `user_roles`); sem regressão, pois ausência de linha já significa `AppRole.USER`
   por padrão em `SessionRepository.resolveAppRole`.
3. Bug real corrigido: `redeem_reward` inseria `loyalty_transactions.type = 'debit'`, valor
   que viola o `CHECK` da coluna (só aceita `earn/redeem/expire/adjustment`) — teria
   quebrado em runtime na primeira chamada real. Corrigido para `'redeem'`.
4. Bug real corrigido: `create_order_notification` comparava `orders.status` com
   `'processing'`, valor que não existe no `CHECK` de `orders.status` (branch morto).
   Corrigido para `'preparing'`.
5. Não replicada a policy `"System can insert notifications"` (`USING/WITH CHECK (true)`
   sem restrição de role) — permitiria qualquer cliente autenticado inserir notificação
   para qualquer `user_id`. As triggers reais que geram notificações são `SECURITY DEFINER`
   e não dependem de RLS; nenhuma tela Android usa `notifications` hoje.

### Backfill
1 usuário já existente em `auth.users` (o login Google real que gerou o PGRST205, criado
antes da migration) sem `profiles` correspondente.
Backfill aplicado via `insert ... select ... on conflict do nothing`, usando exatamente a
mesma lógica de `handle_new_user` (nome de `raw_user_meta_data->>'name'`, senão `'Usuário'`).

### Como foi validado (evidência real, não apenas "migration aplicada")
- `list_tables`: 40 tabelas em `public`, todas com `rls_enabled: true`.
- `select * from user_roles limit 1` → vazio, sem erro (PGRST205 resolvido).
- `pg_trigger` + `pg_get_functiondef`: `on_auth_user_created` ativo (`tgenabled='O'`) em
  `auth.users`, apontando para `handle_new_user`, corpo conferido linha a linha.
- `auth.users` vs `profiles`: 1/1 usuário com profile após backfill (0 sem profile).
- `pg_policies`: ~150 policies distribuídas por todas as 40 tabelas.
- `pg_proc`: 14 funções de segurança, todas `prosecdef = true`.
- `storage.buckets`: 3 buckets (`avatars`, `pets`, `clinics`), todos públicos para leitura.
- `pg_policies` (schema `storage`): 12 policies em `storage.objects`.

### Pendências
Nenhuma para o schema em si. Teste funcional do login Google real fica a cargo do
proprietário no dispositivo físico.

## 2026-07-13 — Domínio 10: Área master (último domínio da varredura original)

### O que foi implementado (funcional de ponta a ponta)
Novo módulo `feature:master`, gate real: `pages/master/MasterLayout.tsx` usa
`hasRole("admin")`, que em `AuthContext.tsx` aceita `role === "master"` OU `"admin"` em
`user_roles` — reproduzido com `AppRole.ADMIN.satisfies()` (não `AppRole.MASTER`, que seria
mais restritivo que o web real). Item "Painel master" no menu de perfil, condicional a esse
gate, ao lado de "Área do parceiro" (Domínio 9).
- **Dashboard** (`pages/master/MasterDashboard.tsx`): contagens reais via
  `count(Count.EXACT, head=true)` em `clinics`/`profiles`/`orders`/`appointments`/
  `available_cities`/`pets`, receita do mês somando `orders.total` filtrado por status
  confirmado/entregue/concluído. Grid de 10 cartões, sem gráficos (mesma decisão do
  Domínio 9).
- **Clínicas** (`MasterClinicas.tsx`): listar com filtro (todas/ativas/inativas/destaque),
  criar clínica (`clinics` insert), ativar/desativar (`is_active` update). Sem edição
  completa dos campos existentes — ver B20.
- **Cidades** (`MasterCidades.tsx`): listar, criar (`available_cities` insert),
  ativar/desativar.
- **Usuários** (`MasterUsuarios.tsx`): somente leitura (o próprio web não muta aqui) —
  `profiles` + `user_roles` (join em memória), busca por nome/cidade.
- **Produtos globais** (`MasterProdutos.tsx`): listar (com nome da clínica via embed
  `clinics(name)`), criar, ativar/desativar, excluir contra `products` real — sem edição
  completa nem upload de imagem (Supabase Storage) — ver B20.
- **Configurações** (`MasterConfiguracoes.tsx`): os 5 campos reais de `scheduling_settings`
  (singleton global, sem `clinic_id` — confirmado no web) com upsert.
- **Relatórios** (`MasterRelatorios.tsx`): receita por mês (6 meses, agregada em memória a
  partir de `orders`), top 5 clínicas por receita, contagem de agendamentos por status —
  como listas (sem biblioteca de gráficos, mesma decisão do Domínio 9).

### Tabelas/RPCs usados
`clinics`, `available_cities`, `profiles`, `user_roles`, `products`, `scheduling_settings`,
`orders`, `appointments`, `pets` — todas leitura/gravação direta via Postgrest, sem RPC.

### Como foi validado
`gradlew.bat :app:assembleDebug` (BUILD SUCCESSFUL) e
`gradlew.bat :app:testDebugUnitTest :core:session:testDebugUnitTest
:feature:scheduling:testDebugUnitTest` (BUILD SUCCESSFUL, todos os testes existentes
continuam passando). Não testado em dispositivo físico USB nesta sessão.

### Erros encontrados e corrigidos
- Comentário KDoc com `/*` literal (`Fonte: pages/master/*.tsx`) quebrando o parser Kotlin
  ("Unclosed comment"), cascateando em ~30 falsos "Unresolved reference" no módulo — mesmo
  padrão de bug já visto no Domínio 9 (AdminRepository.kt). Corrigido reescrevendo o texto.
- `isNull("clinic_id")` não existe na API do supabase-kt — corrigido para
  `filter("clinic_id", FilterOperator.IS, "null")`.
- `listClinicsForPicker()`/`getTopClinicsByRevenue()` selecionavam só `id,name` mas
  decodificavam como `ClinicRow` (que exige `slug`/`city`/`state`/`is_active`/`is_featured`
  não-nulos) — teria quebrado em runtime com exceção de deserialização assim que essas
  telas fossem abertas. Corrigido com um `ClinicIdNameRow` dedicado para esses dois casos.
- `Locale("pt", "BR")` (construtor depreciado) trocado por `Locale.Builder()`.

### Divergências registradas
B20 (novo) — MasterProdutos/MasterClinicas/MasterCidades sem formulário de edição completo
nem upload de imagem, só criar/listar/ativar-desativar(+excluir em Produtos); mesmo padrão
de corte já usado em AdminProdutos (Domínio 9).

### Pendências / próximos passos
Todos os 10 domínios da varredura original (Auth → Master) estão implementados e
compilando. Não há próximo domínio definido pela varredura original — próximos passos
seriam: (1) proprietário preencher `local.properties` com as chaves Supabase reais para
teste em dispositivo físico; (2) B14/B15 (fontes e ícone); (3) formulários de edição
completos onde foram cortados (B19, B20) se o proprietário priorizar fidelidade total;
(4) telas "Secundárias" da lista de prioridades do CLAUDE.md (comunidade, fórum, adoção,
etc., a maioria já mapeada como MOCK/PLACEHOLDER no ROUTE_MATRIX.md e portanto fora do
escopo "real" desta varredura).

## 2026-07-13 — Domínio 9: Área do parceiro via /admin legado

### O que foi implementado (funcional de ponta a ponta)
- **Módulo novo `feature:admin`** (`com.android.library` + Compose). Fonte: pages/admin/*
  (decisão D6/B1: `/admin` legado é a fonte funcional real, `/business` só referência
  visual). Gate por papel: só usuários com papel `staff` ou superior veem a entrada "Área
  do parceiro" no menu de perfil — mesma regra `isStaffOrAdmin` do `AdminLayout.tsx`.
- **`AdminGateViewModel`/`AdminHomeScreen`**: resolve a clínica ativa do parceiro pelo
  primeiro vínculo ativo em `clinic_members` (não confundir com o `ClinicContextState` do
  tutor — são conceitos diferentes) e mostra o hub com as 8 seções.
- **Dashboard**: números reais (pedidos/agendamentos hoje e pendentes, receita do mês,
  clientes/pets/serviços/produtos) via `count(Count.EXACT, head=true)`. Sem os gráficos do
  web (recharts) — não foi adicionada lib de charts nesta fase.
- **Pedidos**/**Agendamentos**: listagem real com filtro de status + transições de status
  reais (mesmas regras `STATUS_ACTIONS` do web) — sem seleção em lote nem calendário.
- **Usuários**: vínculos reais da clínica (`clinic_members` + join `profiles`), trocar
  cargo (staff/admin/owner), ativar/desativar — sem o convite por email (não é real no web,
  não tem mutation correspondente).
- **Serviços**/**Equipe**: CRUD real contra `services`/`staff` — decisão registrada em
  docs/BLOCKERS.md B19, já que o web embrulha telas mock do `/business` para essas duas
  telas específicas (contradiz a premissa geral de D6, só para essas duas).
- **Produtos**: CRUD real contra `products`, com `clinic_id` (igual ao web).
- **Configurações**: edita e salva os campos de texto da clínica (`clinics`) — sem upload
  de logo/capa (Supabase Storage, fora do escopo desta fase).

### Divergência de acesso (não é bloqueio, é adição necessária)
No web, `/admin` só é alcançável digitando a URL diretamente — nenhuma tela do `/app` linka
para lá. Sem URL bar no Android, a "Área do parceiro" foi adicionada ao menu de perfil
(condicional ao papel), senão a funcionalidade ficaria implementada mas inalcançável.

### Tabelas usadas
`clinic_members`, `profiles`, `orders`, `appointments`, `pets`, `services`, `products`,
`staff`, `clinics` (update).

### Como foi validado
`gradlew.bat :app:assembleDebug` → BUILD SUCCESSFUL (precisou corrigir um comentário KDoc
com `/*` literal em "pages/admin/*.tsx" — mesma classe de erro de comentário aninhado já
vista nas Fases 0 e 2). `gradlew.bat :app:testDebugUnitTest :core:session:testDebugUnitTest
:feature:scheduling:testDebugUnitTest` → BUILD SUCCESSFUL. Não testado em dispositivo
físico nesta sessão — a área do parceiro é a que mais precisa de um usuário staff/admin
real vinculado a uma clínica para validar (`clinic_members` com `is_active=true`).

### Próximo passo exato
Domínio 10 (último): Área master — `/master/*` (MasterDashboard, MasterClinicas,
MasterUsuarios, MasterCidades, MasterProdutos, MasterRelatorios, MasterConfiguracoes),
gate por papel `master` (via metadata do JWT, já resolvido em `SessionRepository`).

## 2026-07-13 — Domínio 8: Restante do P2 (Registros, Agenda Inteligente, Álbum, Personalização, Fidelidade)

### O que foi implementado (funcional de ponta a ponta)
- **Módulo novo `feature:tutorextras`** (`com.android.library` + Compose, agrupa as 5 telas
  menores restantes do P2 — todas `REAL` no ROUTE_MATRIX.md — em vez de 5 módulos quase
  idênticos). Depende de `feature:pets` (seletor de pet reutilizado em 3 telas) e
  `feature:profile` (preferências reaproveitam `ProfileRepository`, que ganhou
  `getPreferences`/`updatePreferences`).
- **Registros** (medical_records): lista real com filtro por pet/categoria, formulário de
  criação real (título/data obrigatórios, categoria/profissional/clínica/observações).
- **Agenda Inteligente** (reminders): lista real (próximos/concluídos), criação real,
  marcar concluído/pendente (toggle real).
- **Álbum** (pet_photos): só leitura — o próprio web trava o botão de adicionar foto
  (`disabled`, sem fluxo de upload implementado nem lá), então a versão Android também não
  tem cadastro de foto; fiel ao estado real da referência.
- **Personalização** (profiles.reduce_motion/theme_preference/is_public): formulário real,
  salva de verdade. `theme_preference` ainda não é aplicado ao tema renderizado do app
  nesta fase (TutIoTheme segue o sistema) — só persistido; documentado no código, não é
  bloqueio, é plumbing futuro no MainActivity.
- **Fidelidade** (loyalty_accounts, loyalty_transactions, RPC `redeem_reward`): saldo/nível
  reais, 4 abas (Resgatar/Níveis/Ganhar/Extrato) — níveis e catálogo de recompensas são a
  mesma configuração estática do próprio web (não vêm de tabela, não é dado fabricado:
  é conteúdo de app, igual a `STORE_CATEGORIES`/`SPECIES_OPTIONS` já usados antes), resgate
  chama a RPC real e atualiza saldo/extrato.
- **`AppShell`**: "Fidelidade" e "Ajustes" (menu de perfil) agora abrem as telas reais;
  "Registros"/"Agenda inteligente"/"Álbum" adicionados ao menu (o web só linka essas três a
  partir de atalhos em Perfil.tsx/Pets.tsx, não do menu principal — adição pragmática para
  torná-las alcançáveis); atalhos rápidos do detalhe do pet ("Registros"/"Álbum"/"Agenda
  inteligente") agora abrem as telas reais em vez de "em construção".

### Tabelas/RPCs usados
`medical_records`, `reminders`, `pet_photos`, `profiles` (update), `loyalty_accounts`,
`loyalty_transactions`, RPC `redeem_reward`.

### Como foi validado
`gradlew.bat :app:assembleDebug` → BUILD SUCCESSFUL (após corrigir a assinatura real de
`Postgrest.rpc` — aceita `JsonObject` como parâmetros, não um `@Serializable data class`
genérico direto como as demais chamadas do app; descoberto pelo próprio erro do compilador,
que listou as assinaturas válidas). `gradlew.bat :app:testDebugUnitTest
:core:session:testDebugUnitTest :feature:scheduling:testDebugUnitTest` → BUILD SUCCESSFUL.
Não testado em dispositivo físico nesta sessão.

### Próximo passo exato
Domínio 9: Área do parceiro via `/admin` legado (decisão D6/B1 já registrada — usar o admin
legado real como fonte funcional, não o `/business` mock). Fonte: pages/admin/*.tsx
(AdminDashboard, AdminPedidos, AdminAgendamentos, AdminUsuarios, AdminServicos, AdminStaff,
AdminProdutos, AdminConfiguracoes) — ler cada arquivo antes de portar (B10: AdminServicos/
AdminStaff ainda não tiveram a fonte de dados confirmada na auditoria original).

## 2026-07-13 — Domínio 7: Planos de saúde e carteirinha digital

### O que foi implementado (funcional de ponta a ponta)
- **Módulo novo `feature:healthplans`** (`com.android.library` + Compose, depende de
  `feature:pets` e `feature:profile` para reutilizar `PetRepository`/`ProfileRepository` na
  carteirinha). Fonte: pages/PlanoSaude.tsx, CarteirinhaDigital.tsx + hooks/useHealthPlans.ts.
- **`HealthPlanRepository`**: `health_plans` (ativos), `health_subscriptions` (assinaturas
  ativas do usuário, criação de assinatura com `status="pending"` — igual ao web, sem
  integração de pagamento real, `stripe_subscription_id` existe na tabela mas nunca é usado
  no front; B4 já registrado).
- **`HealthPlansScreen`**: lista de planos reais, assinar (cria `health_subscriptions` real),
  "Plano Ativo" desabilitado quando já ativo.
- **`CarteirinhaScreen`**: nome/cidade real (`profiles`), quantidade de planos ativos real,
  quantidade de pets real (reaproveita `PetRepository`). **Não reproduz** XP/patente/
  "ações no app" do web — são gamificação 100% local (localStorage, sem tabela
  correspondente), diferente do caso já aprovado da home mock (B11): ali o proprietário
  pediu para espelhar; aqui, como card de "identificação oficial do tutor", mostrar
  estatísticas fabricadas pareceria mais enganoso que decorativo — decisão registrada aqui,
  não em BLOCKERS.md por não ser bloqueio real, revisitar se o proprietário preferir
  espelhar também.
- **`AppShell`**: "Plano de saúde" e "Carteirinha digital" adicionados ao menu de perfil
  (o web só linka carteirinha a partir de um card na Perfil.tsx e plano de saúde a partir de
  Servicos.tsx, que é mock e não foi portado — adição pragmática para tornar as telas reais
  alcançáveis).

### Tabelas usadas
`health_plans`, `health_subscriptions`, `profiles`, `pets` (reaproveitado).

### Como foi validado
`gradlew.bat :app:assembleDebug` → BUILD SUCCESSFUL (sem erros na primeira tentativa desta
vez). `gradlew.bat :app:testDebugUnitTest :core:session:testDebugUnitTest
:feature:scheduling:testDebugUnitTest` → BUILD SUCCESSFUL. Não testado em dispositivo
físico nesta sessão.

### Próximo passo exato
Domínio 8 (restante do P2): Registros (medical_records), Personalização/Configurações
(profiles), Fidelidade (loyalty_accounts/transactions + RPC redeem_reward), Agenda
inteligente (reminders), Álbum (pet_photos) — todas REAL segundo ROUTE_MATRIX.md.

## 2026-07-13 — Domínio 6: Loja e pedidos

### O que foi implementado (funcional de ponta a ponta)
- **Módulo novo `feature:store`** (`com.android.library` + Compose). Fonte: pages/Loja.tsx,
  Carrinho.tsx, Checkout.tsx, Pedidos.tsx, PedidoDetalhe.tsx + hooks/useProducts.ts,
  useCart.ts.
- **`StoreRepository`**: `products` (filtrado por `clinic_id` da clínica ativa — mesma
  divergência deliberada de B18 aplicada aqui: o web não filtra por clínica), `cart_items`
  (upsert com `onConflict="user_id,product_id"`, update de quantidade, delete), `orders` +
  `order_items` (criação real, listagem/detalhe com embedding do PostgREST). Sem fallback
  mock (D5): o checkout do web grava em `localStorage` (`orders-storage`) quando o insert
  falha — o Android propaga o erro real e deixa tentar novamente.
- **`LojaScreen`**: grade de produtos, busca, filtro por categoria, adicionar/ajustar
  quantidade no carrinho em tempo real.
- **`CartScreen`**: itens reais, ajustar quantidade, remover, subtotal/frete/total,
  ir para checkout.
- **`CheckoutScreen`**: entrega (receber em casa com endereço / retirar na loja), forma de
  pagamento (só rótulo — sem gateway real, B4 já registrado), resumo, cria o pedido de
  verdade (`orders` + `order_items`) e limpa o carrinho.
- **`OrdersScreen`**/**`OrderDetailScreen`**: pedidos reais do usuário com itens, status,
  entrega, pagamento.
- **`AppShell`**: aba "Carrinho" do bottom nav agora é real; atalho "Lojinha" adicionado à
  Home (real, não existia como link direto no bottom nav do web — só na sidebar desktop e
  nos widgets da home mock, ver AppSidebar.tsx/QuickShortcuts.tsx); "Meus pedidos" do menu
  de perfil agora real.

### Escopo deliberadamente reduzido nesta primeira passagem
- **Sem cupom de desconto** (`coupons`, `useCoupons.ts`): adiciona validação por tipo de
  desconto (percentual/fixo), `min_order_value`, incremento de `used_count` com RLS
  incerta (docs/BLOCKERS.md B13 já registrado). Fica para uma iteração futura da loja —
  checkout funciona integralmente sem cupom, só não aplica desconto.
- Dialog de endereço do web (modal) virou formulário inline na mesma tela — mais simples,
  mesmos campos e validação.

### Tabelas usadas
`products`, `cart_items`, `orders`, `order_items`.

### Como foi validado
`gradlew.bat :app:assembleDebug` → BUILD SUCCESSFUL (precisou de import explícito de
`kotlinx.serialization.json.put`, que sem o import resolve para o `put` de `MutableMap`
em vez da extensão de `JsonObjectBuilder` — erro só aparece em uso, não em declaração).
`gradlew.bat :app:testDebugUnitTest :core:session:testDebugUnitTest
:feature:scheduling:testDebugUnitTest` → BUILD SUCCESSFUL. Não testado em dispositivo
físico nesta sessão.

### Próximo passo exato
Domínio 7: Planos de saúde e carteirinha digital — `health_plans`/`health_subscriptions`
(PlanoSaude.tsx, sem cobrança real — stripe_subscription_id existe na tabela mas sem uso
no front) e CarteirinhaDigital.tsx.

## 2026-07-13 — Domínios 4+5: Serviços/agendamento + Agendamentos do usuário

Implementados juntos (mesmo módulo `feature:scheduling`, mesma tabela `appointments`) para
evitar duplicar repositório/modelos entre "criar agendamento" e "listar/cancelar
agendamento".

### O que foi implementado (funcional de ponta a ponta)
- **Módulo novo `feature:scheduling`** (`com.android.library` + Compose, depende de
  `feature:pets` para reutilizar `PetRepository` no seletor de pet). Fonte: Agendar.tsx,
  AgendarNovo.tsx, Agendamentos.tsx, AgendamentoDetalhe.tsx + hooks/useScheduling.ts.
- **`AvailabilityCalculator`**: reimplementação em Kotlin puro (testável, sem Android/rede)
  do algoritmo real de `useDaySlots` — janela de trabalho por profissional/dia da semana/
  local de atendimento, passo de slot, exclusão por folga (`staff_time_off`), fechamento da
  clínica (`clinic_closures`), conflito com agendamento existente e antecedência mínima
  (`scheduling_settings.min_advance_hours`). **Não** reproduz `buildFallbackWorkingHours` do
  web (fabricação de horário quando a clínica não configurou nada) — ver docs/BLOCKERS.md
  B18. 5 testes unitários novos (`AvailabilityCalculatorTest`) cobrindo: sem horário
  configurado, janela simples, conflito remove slot, antecedência mínima remove slot, local
  de atendimento errado não conta.
- **`SchedulingRepository`**: `services` (filtrado por `clinic_id` da clínica ativa —
  divergência deliberada do web, que não filtra por clínica; ver B18), `staff_services` +
  `staff` (profissionais do serviço), `scheduling_settings`, `staff_working_hours`,
  `staff_time_off`, `clinic_closures`, `appointments` (conflitos, criação com
  recheck de conflito antes do insert, listagem com join `pet`/`service`/`staff` via
  embedding do PostgREST, cancelamento via update de status). Sem fallback mock (D5): o
  create de agendamento do web cai para `localStorage` em qualquer erro — o Android propaga
  o erro real.
- **`ServicesScreen`** (Agendar.tsx): lista de serviços da clínica ativa.
- **`AgendarNovoScreen`** (AgendarNovo.tsx): seleção de pet, local (clínica/casa, quando o
  serviço permite ambos), data (lista horizontal dos próximos dias — simplificação
  deliberada do calendário mensal com contagem de vagas do web, mesma regra de
  disponibilidade real por trás), horário (slots reais computados), observações,
  confirmação → cria o agendamento de verdade. Pet vazio → estado honesto pedindo cadastro
  (não deixa travado).
- **`AppointmentsListScreen`** (Agendamentos.tsx): abas Próximos/Concluídos/Cancelados,
  dados reais com join.
- **`AppointmentDetailScreen`** (AgendamentoDetalhe.tsx): detalhe real + cancelamento (só
  quando `status` é pending/confirmed E faltam mais de 4h — mesma regra `canCancel` do web).
  Não portados: "adicionar ao calendário"/"como chegar"/"WhatsApp" (usam endereço/número de
  WhatsApp fixos de clínica única no web — resíduo já registrado em B8; decorativos, fora do
  essencial "ver detalhes + cancelar").
- **`AppShell`**: aba "Agendar" do bottom nav e atalho "Agendamento" do detalhe do pet agora
  abrem o fluxo real (pedem para escolher uma clínica primeiro se `ClinicContextState` ainda
  não tiver uma clínica selecionada); "Meus agendamentos" do menu de perfil também real.

### Tabelas usadas
`services`, `staff_services`, `staff`, `scheduling_settings`, `staff_working_hours`,
`staff_time_off`, `clinic_closures`, `appointments` (select com embedding, insert, update
de status).

### Bloqueio/decisão registrada
docs/BLOCKERS.md B18 — sem fabricação de horário de trabalho quando `staff_working_hours`
está vazio; filtro de `services`/`staff` por `clinic_id` (o web não filtra, gap já
registrado em B7).

### Como foi validado
`gradlew.bat :app:assembleDebug` → BUILD SUCCESSFUL (precisou de `@OptIn(ExperimentalLayoutApi::class)`
para `FlowRow`, que ainda não é 100% estável na versão do Compose BOM usada). `gradlew.bat
:app:testDebugUnitTest :core:session:testDebugUnitTest :feature:scheduling:testDebugUnitTest`
→ BUILD SUCCESSFUL, incluindo os 5 testes novos do `AvailabilityCalculator`. Não testado em
dispositivo físico nesta sessão — o fluxo de agendamento é o mais arriscado para validar
visualmente (cálculo de horários, fuso do dispositivo) e deveria ser o primeiro a testar
quando houver aparelho conectado.

### Próximo passo exato
Domínio 6: Loja e pedidos — categorias/produtos (`/app/loja`), carrinho (`/app/carrinho`,
tabela `cart_items`), checkout sem gateway de pagamento (B4 já registrado — parar no ponto
suportado), pedidos (`/app/pedidos`, tabela `orders`/`order_items`).

## 2026-07-13 — Domínio 3: Pets (listagem, cadastro, edição, detalhe, exclusão)

### O que foi implementado (funcional de ponta a ponta)
- **Módulo novo `feature:pets`** (`com.android.library` + Compose). Fonte: pages/Pets.tsx,
  PetForm.tsx, PetDetalhe.tsx + hooks/usePets.ts.
- **`PetRepository`**: CRUD real na tabela `pets` (RLS dono: `auth.uid() = owner_id`) — sem
  fallback mock em localStorage (D5/B5, diferente do web que cai para `PET_MOCKS`/
  localStorage em qualquer erro). Payloads de insert/update são `@Serializable data class`
  separadas (`PetInsertPayload` com `owner_id`, `PetUpdatePayload` sem) para nunca arriscar
  sobrescrever o dono do pet num update.
- **`PetsListScreen`**: lista real, contagem, cadastrar/editar/excluir (com `AlertDialog` de
  confirmação — mesmo padrão do Dialog do web), estados carregando/vazio/erro obrigatórios.
- **`PetFormScreen`**: cadastro E edição (mesma tela, `existingPetId` nulo ou não —
  espelha PetForm.tsx), validação client-side (nome/espécie obrigatórios), campos espécie/
  sexo como chips selecionáveis, envia `null` explícito para campos opcionais vazios
  (mesma semântica de "substituição completa" do web).
- **`PetDetailScreen`**: campos reais do pet + atalhos para Agendamento/Registros/Álbum/
  Agenda inteligente (todos `ComingSoonScreen` — domínios ainda não implementados; não
  busca medical_records/pet_photos/reminders/appointments ainda, isso é Domínio 8/4/5).
  Editar e excluir reais.
- **`AppShell`**: rota `shell/coming-soon/{label}` genérica (URL-encoded) substituiu ~10
  constantes de rota individuais para itens do menu de perfil ainda não implementados —
  simplificação de arquitetura, mesmo comportamento honesto de antes. "Meus Pets" no menu
  do perfil agora abre a lista real.

### Tabelas usadas
`pets` (select por owner_id/id, insert, update, delete).

### Como foi validado
`gradlew.bat :app:assembleDebug` → BUILD SUCCESSFUL. `gradlew.bat :app:testDebugUnitTest
:core:session:testDebugUnitTest` → BUILD SUCCESSFUL. Não testado em dispositivo físico
nesta sessão — pendente validar visualmente cadastro/edição/exclusão de pet.

### Próximo passo exato
Domínio 4: Serviços e agendamento — services da clínica, staff/disponibilidade,
AgendarNovo.tsx (seleção de pet, serviço, profissional, data/hora, confirmação, criação
real de appointment). É o que preenche a rota "Agendar" do bottom nav e o atalho
"Agendamento" do detalhe do pet.

## 2026-07-13 — Domínio 2: Shell principal, perfil básico, descoberta de clínicas

### O que foi implementado (funcional de ponta a ponta)
- **Descoberta de clínicas** (`feature/discovery`, convertido de stub Kotlin puro para
  `com.android.library` + Compose): `ClinicRepository` consulta `clinics` (ativas) e `staff`
  (ativos, por clínica) reais. `ClinicDiscoveryScreen` (fonte: CityClinicsList.tsx) lista
  clínicas com busca + filtro por estado/cidade — estados/cidades derivados só das clínicas
  realmente cadastradas (sem o mapa decorativo, sem `CLINIC_NETWORK_MOCKS`/
  `BRAZIL_CITY_NODES`, sem métricas fabricadas do web — decisão registrada em
  docs/BLOCKERS.md B17). `ClinicHomeScreen` (fonte: ClinicHome.tsx) mostra clínica real por
  slug + equipe real (tabela `staff`, não o business demo do localStorage); ao abrir, chama
  `sessionRepository.selectClinic(clinicId)` (equivalente a `setClinicContext` do
  AuthContext.tsx). Sem favoritar/avaliações (sem tabela no backend).
- **Perfil básico** (`feature/profile`, módulo NOVO): `ProfileRepository` consulta
  `profiles` por `user_id`. `ProfileScreen` (fonte: Perfil.tsx) mostra avatar/nome/cidade/bio
  reais, menu de atalhos e logout real. Gamificação/XP/patente/carteirinha/carrossel de pets
  do web são mock local — não portados agora (entram nos domínios correspondentes: pets,
  carteirinha, fidelidade).
- **ClinicContextState real**: `SessionRepository.selectClinic`/`clearClinic` atualizam
  `SessionState.Authenticated.clinicContext` em memória (persistência entre reinícios do
  app fica para uma fase futura — não bloqueia o fluxo, é só paridade incremental com o
  `localStorage.selected_clinic_id` do web).
- **Shell principal** (`core/navigation/AppShell.kt`): bottom nav com as mesmas 5 abas do
  web (Início/Agendar/Social/Carrinho/Perfil — fonte BottomNavigation.tsx). "Início" e
  "Perfil" têm telas reais; "Agendar"/"Social"/"Carrinho" e os itens do menu de perfil que
  dependem de domínios futuros (Fórum, Jogos, Adoção, Meus Pets, Fidelidade, Conquistas,
  Meu plano, Meus agendamentos, Meus pedidos, Ajustes) mostram `ComingSoonScreen` — honesto,
  reutilizável, nunca dado fictício. `HomeScreen` é uma versão mínima real do que seria
  Index.tsx (saudação + atalho para Explorar), com a seção de widgets mock do web reproduzida
  de forma clara e MARCADA como "CONTEÚDO DE EXEMPLO" (`HomeMockWidgets.kt`) — decisão
  explícita do proprietário (ver docs/BLOCKERS.md B11, agora resolvido).
- **Design System**: `TutAvatar`/`TutSquareAvatar` (Coil `AsyncImage`, fonte `.avatar-pet`)
  novos em `core/designsystem/components`, reutilizáveis por todas as próximas telas com
  foto (pets, produtos, staff, avatar do usuário).
- `TutIoNavHost` agora entra em `AppShell` (não mais no placeholder `AuthenticatedPlaceholderScreen`,
  removido).

### Tabelas usadas
`clinics` (select, is_active=true), `staff` (select, por clinic_id + is_active=true),
`profiles` (select, por user_id). Nenhuma escrita nova.

### Deliberadamente fora desta fase
- Persistência do `ClinicContextState` entre reinícios do app (DataStore/SharedPreferences)
  — fica em memória por enquanto.
- Ícones no bottom nav e nos campos de formulário (nenhuma lib de ícones adicionada ainda;
  só texto/labels).

### Bloqueio/decisão registrada
docs/BLOCKERS.md B17 — métricas e rede de clínicas fabricadas do web (CityClinicsList.tsx/
ClinicHome.tsx) não reproduzidas; só dados reais de `clinics`/`staff`.

### Como foi validado
`gradlew.bat :app:assembleDebug` → BUILD SUCCESSFUL. `gradlew.bat :app:testDebugUnitTest
:core:session:testDebugUnitTest` → BUILD SUCCESSFUL. Não testado em dispositivo físico
nesta sessão (sem aparelho conectado) — pendente validar visualmente descoberta de
clínicas, seleção de clínica, perfil e navegação por abas.

### Erros e causas raiz corrigidos durante o build
1. Smart cast cross-módulo (`clinic.description`, `member.bio`) — propriedades `String?`
   declaradas em `core/model` (módulo diferente) não podem ser smart-cast diretamente em
   `feature/discovery`; corrigido atribuindo a `val` local antes do `if`.
2. Comentário KDoc com `/app/*` literal abrindo comentário aninhado do Kotlin (mesma classe
   de erro já registrada na Fase 0) — corrigido reescrevendo o texto sem `/*` literal.
3. `Modifier.padding()` sem import (`androidx.compose.foundation.layout.padding`) no
   `AppShell.kt`.

### Próximo passo exato
Domínio 3: Pets — listagem (`/app/pets`), cadastro (`/app/pets/novo`), detalhe
(`/app/pets/:id`) e edição (`/app/pets/:id/editar`), fonte pages/Pets.tsx, PetForm.tsx,
PetDetalhe.tsx, tabela `pets` (+ pet_photos/medical_records/reminders no detalhe conforme
o que já existir). O item "Meus Pets" do menu de perfil e do bottom nav "Agendar" ainda
ficam de fora até seus próprios domínios.

## 2026-07-13 — Domínio 1: Autenticação e sessão real (Supabase)

### O que foi implementado (funcional de ponta a ponta)
- **Cliente Supabase real**: `core/network` convertido de módulo Kotlin puro para
  `com.android.library` (necessário: auth-kt/ktor-client-android são artefatos Android).
  `buildSupabaseClient()` instala Auth (persistência de sessão automática no Android via
  auth-kt) e Postgrest, com `KotlinXSerializer(Json { ignoreUnknownKeys = true })`.
  Dependências: supabase-kt BOM 3.6.0 (`auth-kt`, `postgrest-kt`), `ktor-client-android`
  3.2.4 (versão efetivamente resolvida — a alinhada pelo BOM, mais alta que a inicialmente
  fixada), `kotlinx-serialization-json`, `kotlinx-coroutines-android`. minSdk subiu de 24
  para 26 em todos os módulos Android (exigência documentada do supabase-kt para Android;
  registrado aqui em vez de silenciosamente).
- **SessionRepository** (`core/session`, também convertido para `com.android.library`):
  observa `auth.sessionStatus` e emite `SessionState` real (Initializing/Unauthenticated/
  Authenticated/Expired/Error) — `RefreshFailure` do SDK mapeado para `Expired` (estado
  obrigatório do CLAUDE.md). Em `Authenticated`, consulta `user_roles` e `clinic_members`
  (mesma lógica de `resolveAppRole` do AuthContext.tsx: metadata `role`/`is_master` do JWT
  para master; senão `admin`/`staff` por role ou membership; senão `user`). `clinicContext`
  fica `NoClinicSelected` nesta fase (clinic_members é vínculo de STAFF, não de tutor —
  seleção de clínica pelo tutor é o Domínio 2). `signIn`/`signUp`/`signOut`/
  `sendPasswordResetEmail`/`updatePassword` reais, com `AuthOutcome` tipado e mensagens de
  erro traduzidas (mesmos casos de Login.tsx/Cadastro.tsx). Nenhum fallback mock (D5):
  falha de rede/consulta vira `SessionState.Error` explícito.
- **Telas reais** (`feature/auth`, convertido para `com.android.library` + Compose):
  `LoginScreen`, `CadastroScreen`, `RecuperarSenhaScreen` (fonte: pages/auth/Login.tsx,
  Cadastro.tsx, RecuperarSenha.tsx — só o formulário email/senha real; seletor de modo
  user/business/master e botões de acesso demo deliberadamente fora desta fase, ver
  "Pendências"). ViewModels (`LoginViewModel`/`CadastroViewModel`/`RecuperarSenhaViewModel`)
  com `StateFlow<UiState>`, validação client-side espelhando o web, injeção manual via
  `authViewModelFactory` (sem DI framework).
- **Design System reutilizável** (`core/designsystem/components`, novo pacote):
  `TutButton` (variantes Tropical/Ocean/Accent/Ghost, fonte `.btn-tropical` etc. do
  index.css), `TutTextField` (fonte `.input-tropical`), `TutLoadingState`/`TutErrorState`/
  `TutEmptyState`/`TutOfflineState` (estados de tela obrigatórios do CLAUDE.md,
  reutilizáveis por todas as próximas telas) — nomes conforme docs/COMPONENT_MAPPING.md.
- **Navegação real dirigida por sessão** (`core/navigation/TutIoNavHost`): Splash (mínimo
  700ms) → Login/Cadastro/RecuperarSenha (guest) ou área autenticada, decidido sempre pelo
  `SessionState` observado (nunca por estado local). `AuthenticatedPlaceholderScreen` é uma
  tela HONESTA e temporária (mostra o papel real resolvido pelo backend, logout real) até o
  Domínio 2 substituí-la pela home real do tutor — não inventa dados, não é uma tela do web.
  `FoundationReadyScreen` (scaffold da Fase 0) removida, substituída por este grafo real.
- **TutIoApplication**: dono único do `SessionRepository`/`SupabaseClient` (nunca duplicar).

### Tabelas/RPCs usados
`user_roles` (select), `clinic_members` (select, filtrado por `is_active=true`). Nenhuma
escrita ainda além do que o próprio Supabase Auth faz internamente (auth.users).

### Deliberadamente fora desta fase (não são bloqueios, são sequenciamento)
- Seletor de modo user/business/master no Login e botões "Demo User/Admin/Master"
  (devProfile do web): a lógica de pós-login desses modos depende das áreas /business e
  /master, que ainda não existem (Domínios 9/10). Serão adicionados quando essas áreas
  existirem, para não criar redirecionamento para telas inexistentes.
- CadastroParceiro (mock que não persiste no web — B3): entra no Domínio 9.

### Bloqueio real registrado
docs/BLOCKERS.md B16 — link de recuperação de senha por email não retorna ao app Android
(falta configuração de redirect/App Link no painel do Supabase, fora do alcance deste
ambiente). `updatePassword()` já implementado e pronto para uso autenticado futuro.

### Como foi validado
`gradlew.bat :app:assembleDebug` → BUILD SUCCESSFUL. `gradlew.bat :app:testDebugUnitTest
:core:session:testDebugUnitTest` → BUILD SUCCESSFUL (testes existentes da Fase 0 +
`SessionRepositoryTest` novo, cobrindo `mapAuthError`). Não testado em dispositivo físico
nesta sessão (sem aparelho conectado) — pendente validar visualmente o fluxo de
login/cadastro/recuperação e a persistência de sessão entre reinícios do app.

### Erros e causas raiz corrigidos durante o build (detalhe útil para próximas fases)
1. `implementation(platform(bom))` em core/network não propagava as versões do BOM para
   core/session (erro "Could not find auth-kt:." com versão vazia) — corrigido trocando
   para `api(platform(...))`.
2. `io.github.jan.supabase.postgrest.result.decodeList` não existe como import — `decodeList<T>()`
   é método de instância de `PostgrestResult`, não função top-level. Confirmado inspecionando
   as classes reais do .aar resolvido (não há acesso à documentação oficial 100% confiável
   neste ambiente; a fonte de verdade final foi o bytecode via `javap`).
3. `AppRole` inacessível em core/navigation — core/session expunha `core:model` como
   `implementation` em vez de `api`, quebrando o classpath de quem usa `SessionState.role`.

### Próximo passo exato
Domínio 2: shell principal (`/app`), perfil básico (`/app/perfil`), descoberta de clínicas
(`/app/explorar`, `CityClinicsList.tsx`) e `ClinicContextState` real (seleção/troca de
clínica pelo tutor, substituindo `AuthenticatedPlaceholderScreen`).

## 2026-07-12 — Auditoria completa do web de referência (etapa 0, sem código)

### O que foi analisado
- Estrutura completa de tutio-web-reference (196 arquivos em src; 13 migrations SQL; public/).
- Definição central de rotas (src/App.tsx + src/lib/routes.ts): ~71 rotas com tela + ~40 redirects legados.
- Autenticação/sessão/papéis/clínicas (AuthContext, ClinicContext, ProtectedRoute, RoleGate, ClinicGate, telas de auth).
- Integração Supabase: 30 tabelas, 8 enums, 4 RPCs, 0 views, 3 buckets, RLS das migrations, todas as queries/mutations por arquivo.
- Identidade visual (index.css + tailwind.config.ts): paleta clara/escura, Nunito/Quicksand, raios, sombras, gradientes, animações, classes de componente.
- Marca: ocorrências de Praia dos Bichos (7), PetConnect (19), Tut.Io/tutio (3+).
- Projeto Android existente: template vazio (nenhum arquivo Kotlin, sem Activity/Compose; namespace com.example.tuttio, minSdk 24, compileSdk 36, AGP com libs.versions; docs/ com 3 stubs).

### Documentos produzidos (tutio-android/docs/)
WEB_SOURCE_INVENTORY.md, ROUTE_MATRIX.md, SUPABASE_MAP.md, DATA_ACCESS_MATRIX.md, UI_TOKENS.md, COMPONENT_MAPPING.md, ASSET_INVENTORY.md, BRAND_MAPPING.md, MIGRATION_PLAN.md, BLOCKERS.md (13 itens), DECISIONS.md (7 itens), este arquivo.

### Como foi validado
Leitura direta dos arquivos + varreduras (grep) por supabase/from()/rpc()/insert-update-delete/localStorage/mocks/nomes de marca. Nenhum arquivo do web foi alterado. Nenhum código Android foi escrito.

### Pendências / próximos passos (na época)
1. Decisões do proprietário: D5 (fallback mock silencioso) e D6 (/admin vs /business).
2. Iniciar Fase 0 (fundação Android): identidade io.tutio.app, Kotlin+Compose, supabase-kt, navegação com guards, build em dispositivo físico.
3. Primeira unidade proposta: fundação + tokens do Design System + Splash compilando no aparelho.

## 2026-07-12/13 — Fase 0: Fundação Android

### Decisões aprovadas antes de codificar
D5 (fallback mock silencioso → erro explícito, sem fallback mock fora do modo demo) e D6
(/admin legado é a fonte real do futuro portal do parceiro; /business é só referência
visual) aprovadas pelo proprietário e registradas em docs/DECISIONS.md. docs/BLOCKERS.md
B1/B5/B6 atualizados para "resolvido". Duas novas decisões documentadas nesta fase: D8
(tipografia Nunito/Quicksand ainda placeholder — BLOCKERS B14) e D9 (ícone do app ainda não
gerado a partir do logo oficial — BLOCKERS B15).

### O que foi implementado
- **Identidade**: rootProject "TutIo", namespace/applicationId `io.tutio.app`, app_name
  "Tut.Io" (era `com.example.tuttio`/"Tuttio"). Pacote Kotlin migrado de `com/example` para
  `io/tutio/app` em app/src/{main,test,androidTest}.
- **Kotlin + Compose**: projeto era um template AGP puro sem Kotlin. Kotlin 2.1.0 + Compose
  BOM 2024.12.01 configurados. Descoberto durante o build que AGP 9.2.1 tem suporte nativo a
  Kotlin ("built-in Kotlin") — o plugin separado `org.jetbrains.kotlin.android` não deve ser
  aplicado nos módulos Android (só `kotlin.jvm` nos módulos 100% Kotlin e
  `kotlin.plugin.compose` para o compilador do Compose). Detalhe completo em
  docs/VALIDATION_LOG.md.
- **Estrutura multi-módulo** (Gradle, não só pacotes): `app`, `core:model`, `core:session`,
  `core:network`, `core:database`, `core:designsystem`, `core:navigation`, `feature:splash`,
  `feature:auth`, `feature:discovery` — conforme pedido, com `feature:auth`/`feature:discovery`
  contendo só contratos mínimos (sealed interfaces com TODOs apontando as telas web reais e
  a fase em que entram), sem nenhuma tela.
- **core/model**: `AppRole` (guest < user < staff < admin < master, hierárquico).
- **core/network**: `SupabaseConfig`/`SupabaseConfigResult` (Available/Missing) — só
  validação de presença; nenhuma conexão real ao Supabase nesta fase.
- **core/session**: `SessionState` (ConfigMissing/Initializing/Unauthenticated/
  Authenticated/Expired/Error) e `ClinicContextState` (NoClinicSelected/ClinicSelected) —
  contratos puros, sem storage local como fonte de autorização.
- **core/database**: módulo Android vazio/placeholder (sem Room, sem entidades — nenhuma
  tela usa persistência ainda).
- **core/designsystem**: tokens de cor claro/escuro transcritos 1:1 de docs/UI_TOKENS.md
  (função `hsl()` própria, sem conversão manual para hex), espaçamento, raios/formas,
  sombras coloridas aproximadas (`Modifier.shadow` com ambientColor/spotColor), gradientes
  nomeados com cálculo de ângulo CSS→Offset, tipografia com a escala completa (Quicksand
  display / Nunito corpo) usando `FontFamily.Default` como placeholder documentado (D8),
  `TutIoTheme` compondo tudo sobre Material3 (ColorScheme.copy(), CompositionLocal para os
  tokens extras). Logo oficial (`tutio logo.png`, copiado de tutio-web-reference/public/, sem
  alterar o original) embarcado em drawable-nodpi para a Splash.
- **feature/splash**: `SplashScreen` (fonte: AppLoadingScreen.tsx — cartão do logo,
  APP_NAME/APP_SUBTITLE/"by APP_STUDIO" reais de lib/branding.ts, animação pawPulse; frases
  rotativas e barra de progresso do web NÃO portadas, fora do escopo "mínima" da Fase 0) e
  `FoundationReadyScreen` (tela temporária, não existe no web, só confirma que a fundação
  compila e mostra o SessionState atual).
- **core/navigation**: `TutIoNavHost` com só duas rotas (splash → foundation_ready).
- **app**: `MainActivity` monta `SupabaseConfigResult`/`SessionState` a partir do
  `BuildConfig` (lido de local.properties, nunca hardcoded) e injeta no NavHost dentro de
  `TutIoTheme`. `TutIoApplication` mínima.
- **Configuração segura do Supabase**: `local.properties.example` criado (local.properties
  já estava no .gitignore; Read/Edit dele são bloqueados pelas permissões deste ambiente —
  o proprietário precisa preencher `supabase.url`/`supabase.publishableKey` manualmente).
  `.gitignore` ampliado para `**/build` (múltiplos módulos novos).

### Como foi validado
`gradlew.bat :app:assembleDebug` (APK gerado), `gradlew.bat :app:testDebugUnitTest` (5/5
testes reais passando, cobrindo AppRole, SupabaseConfigResult e SessionState) e
`gradlew.bat build` (todos os módulos, debug+release) — todos com BUILD SUCCESSFUL. Detalhe
completo de cada erro encontrado e corrigido (6 tentativas até o build verde) em
docs/VALIDATION_LOG.md. Não testado em dispositivo físico USB nesta sessão (só build/testes
de host) — pendente para quem tiver o aparelho conectado.

### Erros e causas raiz (resumo — detalhe em VALIDATION_LOG.md)
Conflito de plugin Kotlin com o suporte nativo da AGP 9.2.1; comentários KDoc com `/*`
literal abrindo comentário aninhado do Kotlin; nome de declaração duplicado
(`TutIoShapes`); imports errados (`ContentScale`, `getValue`); `androidx.core:core-ktx`
1.19.0 exigindo compileSdk 37 (rebaixado para 1.13.1); dependência `material` perdida na
reescrita do build.gradle.kts do :app.

### Pendências / próximos passos
1. Proprietário preencher `local.properties` com `supabase.url`/`supabase.publishableKey`
   reais (arquivo protegido por permissão neste ambiente; ver local.properties.example).
2. B14 — decidir fonte real para Nunito/Quicksand (.ttf ou certificados verificados do
   Google Fonts Provider).
3. B15 — aprovar um recorte quadrado do logo para gerar o ícone adaptativo real.
4. Validar em dispositivo físico via USB (não feito nesta sessão).
5. Próxima fase (não iniciada): P1 — auth real (login/cadastro/recuperar senha) e primeira
   tela real de descoberta de clínicas, conforme docs/ROUTE_MATRIX.md.
