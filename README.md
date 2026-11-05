# Ecos de Brumafria — RPG dirigido por SGBD

RPG de turnos em que **toda a regra do jogo roda dentro do PostgreSQL**: as rolagens de dados, o cálculo
de dano, a IA dos monstros, a progressão de nível, o saque, as missões, o ciclo dia/noite, os segredos,
as conquistas e a segurança. A aplicação cliente só faz `CALL` em procedures e lê `views`.

> *Brumafria é uma vila sob névoa eterna. O sino da torre está mudo há cem anos. Ele se partiu em três
> pedaços, espalhados entre criaturas do bosque, das minas e do pântano. Quem reunir os três vai ouvir
> o sino tocar e descobrir o que existe sob a torre.*

---

## Como executar

**Opção A: PostgreSQL 14+ (psql)**
```bash
psql -d meu_banco -f sql/01_schema.sql -f sql/02_funcoes.sql -f sql/03_triggers.sql -f sql/04_procedures.sql -f sql/05_views.sql -f sql/06_dados.sql -f sql/07_seguranca.sql
```
```bash
psql -d meu_banco -f sql/08_demo.sql
```

**Opção B: sem instalar PostgreSQL** (Node 18+, usa o [PGlite](https://pglite.dev), que é o PostgreSQL compilado para WebAssembly)
```bash
npm install
```
```bash
node rodar.mjs
```
```bash
node rodar.mjs --console
```
O primeiro comando recria o banco e roda a demonstração. O segundo abre um console SQL para jogar. A saída de uma
execução completa está em `saida_demo.txt`.

### Interface gráfica
```bash
node servidor.mjs
```
Depois, abra **http://localhost:3000** no navegador. Pela página dá para criar heróis, explorar, lutar turno a turno
(com o d20 animado), usar a batalha automática, viajar, comprar e vender, equipar, aceitar missões e ler a crônica.

A interface não contém regra de jogo. O `servidor.mjs` apenas:
- transforma cada clique em um `CALL sp_…`, executado com `SET ROLE rpg_jogador`, ou seja, o papel sem permissão de
  escrita nas tabelas. Isso prova na prática que as procedures `SECURITY DEFINER` são a única porta de entrada;
- lê o estado do jogo pelas views (`vw_ficha`, `vw_quests` etc.);
- mostra como aviso cada `RAISE NOTICE` do banco (level-up, missão concluída, segredo revelado).

A lista **Rastros conhecidos** mostra só os monstros que o herói já enfrentou ou que são alvo de uma missão. Assim,
o mistério do Cervo Pálido continua escondido.

O servidor, o `rodar.mjs` e o console usam o mesmo banco (pasta `dados`), então rode um de cada vez.
Lembre que `node rodar.mjs` recria o banco do zero. O botão **Reiniciar mundo**, no lobby, faz o mesmo sem a demonstração.

### Jogando
```sql
SET search_path TO rpg, public;
CALL sp_criar_personagem('Lia', 'Mago');
CALL sp_comprar(fn_pid('Lia'), 'Poção Menor', 3);
CALL sp_aceitar_quest(fn_pid('Lia'), 'Ratos no Celeiro');
CALL sp_viajar(fn_pid('Lia'), 'Bosque dos Sussurros');
CALL sp_iniciar_batalha(fn_pid('Lia'));                      -- encontro aleatório
CALL sp_turno(fn_batalha_ativa(fn_pid('Lia')), 'habilidade', 'Seta de Fogo');
CALL sp_turno(fn_batalha_ativa(fn_pid('Lia')), 'item', 'Poção Menor');
CALL sp_turno(fn_batalha_ativa(fn_pid('Lia')), 'fugir');
CALL sp_batalha_automatica(fn_pid('Lia'));                   -- batalha inteira no piloto automático
SELECT * FROM vw_ficha;  SELECT * FROM vw_combate;  SELECT * FROM vw_quadro_de_missoes;
```

---

## Arquitetura

| Arquivo | Conteúdo |
|---|---|
| `01_schema.sql` | 9 tipos `ENUM`, 26 tabelas, `CHECK`, FKs, índice único parcial (1 batalha ativa por personagem) |
| `02_funcoes.sql` | Dados (`fn_rolar`, `fn_rolar_expr`), fórmulas de progressão e o **cálculo de dano** (`fn_calcular_dano`) |
| `03_triggers.sql` | 18 triggers: criação, level-up, viagem, inventário, fim de batalha, missões, auditoria, notificação |
| `04_procedures.sql` | As 12 ações do jogador (`sp_*`) e a IA do monstro (`fn_turno_monstro`) |
| `05_views.sql` | Ficha, inventário, bestiário, ranking, combate, missões, crônica |
| `06_dados.sql` | O conteúdo do mundo: 8 classes, 15 habilidades, 5 regiões, 25 itens, 12 monstros, 7 missões, 1 segredo, 8 conquistas |
| `07_seguranca.sql` | Papéis `rpg_jogador` e `rpg_mestre`, procedures `SECURITY DEFINER` |
| `08_demo.sql` | Roteiro de apresentação em 13 etapas |

### Modelo de entidades

```
classe ──< classe_atributo >── atributo          classe ──< habilidade
  │  └──< classe_item_inicial >── item ──< item_bonus >── atributo
  │                                 │
  ├──< personagem ──< inventario >──┘
  │       ├──< personagem_atributo
  │       ├──< personagem_quest >── quest
  │       ├──< personagem_segredo >── segredo ──< segredo_requisito >── item
  │       ├──< personagem_conquista >── conquista
  │       └──< batalha ──< batalha_log
  │              │
  └──< monstro ──┘ ──< monstro_drop >── item       (inventário de saque por tipo de monstro)
         └──< monstro_regiao >── regiao             (peso de encontro + período dia/noite)
```

**Monstros e personagens pertencem a uma Classe.** Os atributos de um monstro não ficam gravados: são
derivados da curva da sua classe (`base + ganho_por_nivel × (nível − 1)`), com +30% para chefes. Para criar
um novo monstro, basta informar a classe e o nível.

---

## Mecânicas

### Atributos
`ATQ` ataque · `DEF` defesa · `VIT` vitalidade (HP = 10 + 3·VIT + 2·nível) · `MAG` magia (MP = 2·MAG + nível) ·
`AGI` agilidade (acerto, esquiva, iniciativa, fuga) · `SOR` sorte (margem de crítico e chance de saque).
O atributo total é a base da classe mais o bônus dos itens equipados (`fn_atributo`).

### Cálculo de dano (`fn_calcular_dano`, dentro do SGBD)
1. Rola um **d20**. Um 1 natural é falha crítica. A margem de crítico é `20 − SOR/10` (mínimo 17).
2. Acerta se `d20 + AGI_atacante/3 ≥ 8 + AGI_defensor/3`.
3. Dano = `(NdL + ATQ − DEF/2) × multiplicador`. No crítico, os dados são rolados duas vezes. Se o alvo
   estiver defendendo, recebe metade. O dano mínimo é 1.
4. Multiplicador elemental: ×1,5 contra a fraqueza do alvo, ×0,5 contra o mesmo elemento. Também entram
   a fúria do berserker (×1,5) e o bônus noturno da classe (mortos-vivos ×1,25).

Cada classe tem seu dado (d4 a d64). As habilidades têm `qtd_dados × lados_dado`. `fn_rolar_expr('3d6+2')`
interpreta a notação de RPG por expressão regular.

### Turnos pré-programados
`sp_turno` executa a ação do personagem (`atacar`, `habilidade`, `item`, `defender`, `fugir`) e, se o
monstro sobreviver, a resposta dele (`fn_turno_monstro`), conforme o comportamento cadastrado:

| Comportamento | IA |
|---|---|
| agressivo | sempre ataca |
| defensivo | abaixo de 50% de HP, às vezes se defende |
| berserker | abaixo de 30% de HP, causa ×1,5 de dano |
| covarde | abaixo de 30% de HP, pode fugir (e o jogador fica sem recompensa) |
| conjurador | em 50% dos turnos usa uma habilidade da sua classe (dano ou cura) |

**Emboscada:** no início da batalha, se o monstro vencer a disputa de iniciativa (d20 + AGI) por 5 ou mais, ele
age primeiro. `sp_batalha_automatica` joga a batalha inteira com uma estratégia: cura quando o HP está baixo,
escolhe a poção que melhor cobre o dano e usa a magia que explora a fraqueza do alvo.

### Cascata de triggers (exemplo real da demo)
`UPDATE batalha SET status='vitoria'` →
**trg_batalha_encerrar** concede XP, ouro e saque →
**trg_personagem_c_xp** recalcula o nível →
**trg_personagem_level_up** atualiza atributos, cura e registra →
**trg_quest_b_progresso** marca a missão de caça como concluída →
**trg_quest_recompensa** concede mais XP (novo level-up) →
**fn_verificar_conquistas** concede o título →
**trg_personagem_auditoria** registra cada alteração →
**trg_cronica_notificar** emite `pg_notify('rpg_eventos', …)`.

### Outras regras garantidas pelo banco
- O personagem não pode escolher uma classe de monstro e só equipa armas, armaduras ou acessórios, respeitando
  classe e nível. Ao equipar, o item anterior do mesmo tipo é trocado automaticamente.
- A mochila tem 20 espaços. Pilhas que chegam a zero são apagadas.
- Para viajar, o personagem precisa do nível mínimo da região, não pode estar em combate, e regiões
  secretas só abrem depois que o segredo for revelado.
- Derrota: o personagem volta à vila com 25% do HP e perde 20% do ouro.
- Missões de coleta acompanham o inventário e consomem os itens ao serem concluídas. Missões de exploração
  são concluídas ao chegar à região. Pré-requisitos e nível são validados.
- Cada batalha avança o relógio do mundo em 1 hora, cada viagem em 2 e cada descanso em 8. Alguns monstros só
  aparecem à noite.

---

## Mistérios do jogo (spoilers)

<details><summary>Abrir</summary>

- O **Sino Partido**: os fragmentos não aparecem no bestiário (`vw_bestiario` esconde os itens do tipo
  `fragmento`), e o papel `rpg_jogador` não pode ler as tabelas `segredo`, `monstro_drop` e `regiao`.
  - *Fragmento do Badalo*: o **Cervo Pálido**, só à noite, com 5% de chance de encontro, e covarde: foge
    quando está ferido. A dica está no Chifre Pálido, que traz gravado "1/3".
  - *Fragmento da Boca*: o chefe **Capataz Sem Rosto**, nas Minas.
  - *Fragmento da Alça*: a chefe **Bruxa do Junco**, no Pântano, só à noite.
- Ao reunir os três, `fn_verificar_segredos` (uma divisão relacional com `NOT EXISTS` duplo) revela o
  **Santuário do Sino Partido** e a missão secreta contra **O Sineiro**, que deixa cair o *Sino Restaurado*.
- Títulos ocultos: *Favorecido pelos Dados* (3 críticos numa mesma batalha), *Caminhante da Noite*,
  *Quebra-Coroas*, *Ouvinte do Sino*.
</details>

---

## Recursos explorados além do básico

| Recurso | Onde |
|---|---|
| Tipos `ENUM` e tipo composto (`resultado_ataque`) como retorno de função | 01, 02 |
| Índice único **parcial** (`WHERE status = 'em_andamento'`) | 01 |
| Triggers `BEFORE`/`AFTER`, `UPDATE OF coluna`, cláusula `WHEN`, ordem alfabética controlada | 03 |
| Trigger **genérico parametrizado** (`TG_ARGV`) com diff em `jsonb` para auditoria | 03 |
| `LISTEN/NOTIFY` (`pg_notify`) para eventos em tempo real | 03 |
| `INSERT … ON CONFLICT DO UPDATE` (upsert do inventário) | 02 |
| Procedures com parâmetro `INOUT`, `CALL` aninhado, atomicidade por exceção | 04 |
| `SELECT … FOR UPDATE` (trava a batalha durante o turno) | 04 |
| Sorteio ponderado com `sum() OVER (ORDER BY …)` | 02 |
| Divisão relacional (`NOT EXISTS` duplo) | 02 |
| Funções de janela `rank() OVER (PARTITION BY …)`, `count(*) FILTER (…)` | 05 |
| Expressão regular (`regexp_match`) para notação de dados | 02 |
| `SECURITY DEFINER` + `SET search_path` (proteção contra sequestro de search_path), `GRANT/REVOKE`, SQL dinâmico com `format('%I')` | 07 |
| `setseed()` para rolagens reprodutíveis na apresentação | 08 |

---

## Como expandir

O conteúdo é orientado a dados: para criar uma nova região, monstro, item, missão ou segredo, basta inserir
linhas, sem alterar código.

```sql
-- nova região, monstro noturno e seu saque
INSERT INTO regiao (nome, descricao, nivel_minimo) VALUES ('Cripta Salgada', 'Ossos e sal.', 8);
INSERT INTO monstro (nome, classe_id, nivel, fraqueza, comportamento, xp_recompensa, ouro_min, ouro_max)
VALUES ('Lich de Sal', (SELECT id FROM classe WHERE nome = 'Morto-vivo'), 9, 'fogo', 'conjurador', 300, 30, 60);
INSERT INTO monstro_regiao VALUES ((SELECT id FROM monstro WHERE nome = 'Lich de Sal'),
                                   (SELECT id FROM regiao  WHERE nome = 'Cripta Salgada'), 10, 'noite');
-- novo segredo: basta listar os itens exigidos
INSERT INTO segredo (nome, mensagem, regiao_desbloqueada) VALUES ('A Coroa de Sal', '...', ...);
INSERT INTO segredo_requisito VALUES (...);
```

Ideias de evolução: novas classes e habilidades com efeitos de status (veneno por turno, atordoamento) numa
tabela `efeito_ativo`; batalhas em grupo (`batalha_participante`); comércio entre jogadores com transações
`SERIALIZABLE`; *Row-Level Security* para que cada jogador só veja os próprios personagens; `pg_cron` para
eventos de mundo agendados (uma lua de sangue toda sexta-feira); e um cliente web que escute `rpg_eventos`.
