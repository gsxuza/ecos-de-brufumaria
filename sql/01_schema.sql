-- =====================================================================
--  ECOS DE BRUMAFRIA  —  RPG dirigido por SGBD (PostgreSQL 14+)
--  01_schema.sql  —  tipos, tabelas, restrições e índices
-- =====================================================================
DROP SCHEMA IF EXISTS rpg CASCADE;
CREATE SCHEMA rpg;
SET search_path TO rpg, public;

-- ---------------------------------------------------------------------
--  Tipos enumerados (domínio fechado garantido pelo próprio SGBD)
-- ---------------------------------------------------------------------
CREATE TYPE tipo_item      AS ENUM ('arma','armadura','acessorio','consumivel','material','fragmento');
CREATE TYPE raridade       AS ENUM ('comum','incomum','raro','epico','lendario');
CREATE TYPE elemento       AS ENUM ('neutro','fogo','gelo','raio','sagrado','sombra','veneno');
CREATE TYPE status_batalha AS ENUM ('em_andamento','vitoria','derrota','fuga');
CREATE TYPE acao_batalha   AS ENUM ('atacar','habilidade','item','defender','fugir');
CREATE TYPE comportamento  AS ENUM ('agressivo','defensivo','berserker','covarde','conjurador');
CREATE TYPE periodo        AS ENUM ('dia','noite','qualquer');
CREATE TYPE tipo_quest     AS ENUM ('cacar','coletar','explorar');
CREATE TYPE status_quest   AS ENUM ('ativa','concluida');

-- ---------------------------------------------------------------------
--  Mundo (linha única): relógio que define dia/noite
-- ---------------------------------------------------------------------
CREATE TABLE mundo (
    id    boolean  PRIMARY KEY DEFAULT true CHECK (id),     -- garante 1 linha
    dia   integer  NOT NULL DEFAULT 1 CHECK (dia >= 1),
    hora  smallint NOT NULL DEFAULT 8 CHECK (hora BETWEEN 0 AND 23)
);

-- ---------------------------------------------------------------------
--  Atributos e Classes
-- ---------------------------------------------------------------------
CREATE TABLE atributo (
    id        smallserial PRIMARY KEY,
    sigla     char(3)     NOT NULL UNIQUE,
    nome      varchar(30) NOT NULL,
    descricao text
);

CREATE TABLE classe (
    id                 smallserial PRIMARY KEY,
    nome               varchar(40) NOT NULL UNIQUE,
    descricao          text,
    jogavel            boolean  NOT NULL DEFAULT true,   -- false = classe de monstro
    dado_dano          smallint NOT NULL CHECK (dado_dano IN (4,6,8,10,12,20,32,64)),
    atributo_principal smallint NOT NULL REFERENCES atributo(id),
    bonus_noturno      numeric(3,2) NOT NULL DEFAULT 1.00  -- multiplicador de dano à noite
);

-- "Cada Classe tem uma dinâmica de pontuação de Atributos"
CREATE TABLE classe_atributo (
    classe_id       smallint     NOT NULL REFERENCES classe(id) ON DELETE CASCADE,
    atributo_id     smallint     NOT NULL REFERENCES atributo(id),
    base            smallint     NOT NULL CHECK (base >= 0),
    ganho_por_nivel numeric(4,2) NOT NULL CHECK (ganho_por_nivel >= 0),
    PRIMARY KEY (classe_id, atributo_id)
);

CREATE TABLE habilidade (
    id              smallserial PRIMARY KEY,
    nome            varchar(40) NOT NULL UNIQUE,
    classe_id       smallint    NOT NULL REFERENCES classe(id) ON DELETE CASCADE,
    nivel_minimo    smallint    NOT NULL DEFAULT 1,
    custo_mp        smallint    NOT NULL DEFAULT 0 CHECK (custo_mp >= 0),
    qtd_dados       smallint    NOT NULL DEFAULT 1 CHECK (qtd_dados BETWEEN 1 AND 10),
    lados_dado      smallint    NOT NULL CHECK (lados_dado IN (4,6,8,10,12,20,32,64)),
    atributo_escala smallint    NOT NULL REFERENCES atributo(id),
    elemento        elemento    NOT NULL DEFAULT 'neutro',
    cura            boolean     NOT NULL DEFAULT false,
    descricao       text
);

-- ---------------------------------------------------------------------
--  Regiões
-- ---------------------------------------------------------------------
CREATE TABLE regiao (
    id           smallserial PRIMARY KEY,
    nome         varchar(60) NOT NULL UNIQUE,
    descricao    text,
    nivel_minimo smallint NOT NULL DEFAULT 1,
    segura       boolean  NOT NULL DEFAULT false,   -- cidade: sem combate, com loja
    secreta      boolean  NOT NULL DEFAULT false    -- só acessível após um segredo
);

-- ---------------------------------------------------------------------
--  Itens
-- ---------------------------------------------------------------------
CREATE TABLE item (
    id               smallserial PRIMARY KEY,
    nome             varchar(60) NOT NULL UNIQUE,
    tipo             tipo_item   NOT NULL,
    raridade         raridade    NOT NULL DEFAULT 'comum',
    elemento         elemento    NOT NULL DEFAULT 'neutro',
    classe_requerida smallint    REFERENCES classe(id),
    nivel_minimo     smallint    NOT NULL DEFAULT 1,
    cura_hp          integer     NOT NULL DEFAULT 0 CHECK (cura_hp >= 0),
    cura_mp          integer     NOT NULL DEFAULT 0 CHECK (cura_mp >= 0),
    preco            integer     NOT NULL DEFAULT 0 CHECK (preco >= 0),  -- 0 = não vendido na loja
    descricao        text,
    CHECK (tipo = 'consumivel' OR (cura_hp = 0 AND cura_mp = 0))
);

CREATE TABLE item_bonus (
    item_id     smallint NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    atributo_id smallint NOT NULL REFERENCES atributo(id),
    valor       smallint NOT NULL,
    PRIMARY KEY (item_id, atributo_id)
);

CREATE TABLE classe_item_inicial (
    classe_id  smallint NOT NULL REFERENCES classe(id) ON DELETE CASCADE,
    item_id    smallint NOT NULL REFERENCES item(id),
    quantidade smallint NOT NULL DEFAULT 1,
    equipar    boolean  NOT NULL DEFAULT false,
    PRIMARY KEY (classe_id, item_id)
);

-- ---------------------------------------------------------------------
--  Personagens
-- ---------------------------------------------------------------------
CREATE TABLE personagem (
    id        serial      PRIMARY KEY,
    nome      varchar(40) NOT NULL UNIQUE,
    classe_id smallint    NOT NULL REFERENCES classe(id),
    nivel     smallint    NOT NULL DEFAULT 1 CHECK (nivel BETWEEN 1 AND 50),
    xp        integer     NOT NULL DEFAULT 0 CHECK (xp >= 0),
    hp_atual  integer     NOT NULL DEFAULT 0,
    hp_max    integer     NOT NULL DEFAULT 0,
    mp_atual  integer     NOT NULL DEFAULT 0,
    mp_max    integer     NOT NULL DEFAULT 0,
    ouro      integer     NOT NULL DEFAULT 50 CHECK (ouro >= 0),
    regiao_id smallint    REFERENCES regiao(id),
    titulo    varchar(60),
    criado_em timestamptz NOT NULL DEFAULT now()
);

-- valor BASE do atributo (classe + nível); bônus de equipamento são somados em fn_atributo()
CREATE TABLE personagem_atributo (
    personagem_id integer  NOT NULL REFERENCES personagem(id) ON DELETE CASCADE,
    atributo_id   smallint NOT NULL REFERENCES atributo(id),
    valor         integer  NOT NULL,
    PRIMARY KEY (personagem_id, atributo_id)
);

CREATE TABLE inventario (
    id            serial   PRIMARY KEY,
    personagem_id integer  NOT NULL REFERENCES personagem(id) ON DELETE CASCADE,
    item_id       smallint NOT NULL REFERENCES item(id),
    quantidade    integer  NOT NULL DEFAULT 1 CHECK (quantidade >= 0),
    equipado      boolean  NOT NULL DEFAULT false,
    obtido_em     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (personagem_id, item_id)
);

-- ---------------------------------------------------------------------
--  Monstros  (pertencem a uma Classe; inventário de drop por tipo)
-- ---------------------------------------------------------------------
CREATE TABLE monstro (
    id            smallserial PRIMARY KEY,
    nome          varchar(60) NOT NULL UNIQUE,
    classe_id     smallint    NOT NULL REFERENCES classe(id),
    nivel         smallint    NOT NULL CHECK (nivel BETWEEN 1 AND 60),
    elemento      elemento    NOT NULL DEFAULT 'neutro',
    fraqueza      elemento,
    comportamento comportamento NOT NULL DEFAULT 'agressivo',
    chefe         boolean     NOT NULL DEFAULT false,
    xp_recompensa integer     NOT NULL CHECK (xp_recompensa >= 0),
    ouro_min      integer     NOT NULL DEFAULT 0,
    ouro_max      integer     NOT NULL DEFAULT 0,
    descricao     text,
    CHECK (ouro_max >= ouro_min)
);

CREATE TABLE monstro_regiao (
    monstro_id smallint NOT NULL REFERENCES monstro(id) ON DELETE CASCADE,
    regiao_id  smallint NOT NULL REFERENCES regiao(id) ON DELETE CASCADE,
    peso       smallint NOT NULL DEFAULT 10 CHECK (peso > 0),  -- probabilidade relativa de encontro
    periodo    periodo  NOT NULL DEFAULT 'qualquer',
    PRIMARY KEY (monstro_id, regiao_id)
);

CREATE TABLE monstro_drop (
    monstro_id smallint     NOT NULL REFERENCES monstro(id) ON DELETE CASCADE,
    item_id    smallint     NOT NULL REFERENCES item(id),
    chance     numeric(5,2) NOT NULL CHECK (chance > 0 AND chance <= 100),
    qtd_min    smallint     NOT NULL DEFAULT 1,
    qtd_max    smallint     NOT NULL DEFAULT 1,
    PRIMARY KEY (monstro_id, item_id),
    CHECK (qtd_max >= qtd_min)
);

-- ---------------------------------------------------------------------
--  Batalhas (turnos) e registro de combate
-- ---------------------------------------------------------------------
CREATE TABLE batalha (
    id                   serial  PRIMARY KEY,
    personagem_id        integer NOT NULL REFERENCES personagem(id) ON DELETE CASCADE,
    monstro_id           smallint NOT NULL REFERENCES monstro(id),
    regiao_id            smallint REFERENCES regiao(id),
    periodo              periodo,
    hp_monstro           integer NOT NULL DEFAULT 0,
    hp_monstro_max       integer NOT NULL DEFAULT 0,
    turno                integer NOT NULL DEFAULT 0,
    personagem_defendendo boolean NOT NULL DEFAULT false,
    monstro_defendendo   boolean NOT NULL DEFAULT false,
    status               status_batalha NOT NULL DEFAULT 'em_andamento',
    iniciada_em          timestamptz NOT NULL DEFAULT now(),
    finalizada_em        timestamptz
);
-- um personagem só pode estar em UMA batalha ativa
CREATE UNIQUE INDEX ux_batalha_ativa ON batalha(personagem_id) WHERE status = 'em_andamento';

CREATE TABLE batalha_log (
    id             bigserial PRIMARY KEY,
    batalha_id     integer  NOT NULL REFERENCES batalha(id) ON DELETE CASCADE,
    turno          integer  NOT NULL,
    ator           varchar(10) NOT NULL CHECK (ator IN ('personagem','monstro','sistema')),
    acao           acao_batalha,
    rolagem_d20    smallint,
    rolagem_dano   smallint,
    dano           integer,
    critico        boolean NOT NULL DEFAULT false,
    mensagem       text    NOT NULL,
    criado_em      timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_batalha_log_batalha ON batalha_log(batalha_id, id);

-- ---------------------------------------------------------------------
--  Quests
-- ---------------------------------------------------------------------
CREATE TABLE quest (
    id                 smallserial PRIMARY KEY,
    nome               varchar(80) NOT NULL UNIQUE,
    descricao          text,
    tipo               tipo_quest  NOT NULL,
    nivel_minimo       smallint    NOT NULL DEFAULT 1,
    monstro_alvo       smallint    REFERENCES monstro(id),
    item_alvo          smallint    REFERENCES item(id),
    regiao_alvo        smallint    REFERENCES regiao(id),
    quantidade         integer     NOT NULL DEFAULT 1 CHECK (quantidade > 0),
    recompensa_xp      integer     NOT NULL DEFAULT 0,
    recompensa_ouro    integer     NOT NULL DEFAULT 0,
    recompensa_item    smallint    REFERENCES item(id),
    quest_prerequisito smallint    REFERENCES quest(id),
    secreta            boolean     NOT NULL DEFAULT false,
    CHECK (   (tipo = 'cacar'    AND monstro_alvo IS NOT NULL)
           OR (tipo = 'coletar'  AND item_alvo    IS NOT NULL)
           OR (tipo = 'explorar' AND regiao_alvo  IS NOT NULL))
);

CREATE TABLE personagem_quest (
    personagem_id integer  NOT NULL REFERENCES personagem(id) ON DELETE CASCADE,
    quest_id      smallint NOT NULL REFERENCES quest(id),
    progresso     integer  NOT NULL DEFAULT 0,
    status        status_quest NOT NULL DEFAULT 'ativa',
    aceita_em     timestamptz  NOT NULL DEFAULT now(),
    concluida_em  timestamptz,
    PRIMARY KEY (personagem_id, quest_id)
);

-- ---------------------------------------------------------------------
--  Mistérios: segredos revelados ao reunir itens
-- ---------------------------------------------------------------------
CREATE TABLE segredo (
    id                  smallserial PRIMARY KEY,
    nome                varchar(80) NOT NULL UNIQUE,
    mensagem            text        NOT NULL,    -- texto narrativo exibido ao revelar
    regiao_desbloqueada smallint    REFERENCES regiao(id),
    quest_desbloqueada  smallint    REFERENCES quest(id)
);

CREATE TABLE segredo_requisito (
    segredo_id smallint NOT NULL REFERENCES segredo(id) ON DELETE CASCADE,
    item_id    smallint NOT NULL REFERENCES item(id),
    PRIMARY KEY (segredo_id, item_id)
);

CREATE TABLE personagem_segredo (
    personagem_id integer  NOT NULL REFERENCES personagem(id) ON DELETE CASCADE,
    segredo_id    smallint NOT NULL REFERENCES segredo(id),
    revelado_em   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (personagem_id, segredo_id)
);

-- ---------------------------------------------------------------------
--  Conquistas, crônica e auditoria
-- ---------------------------------------------------------------------
CREATE TABLE conquista (
    id        smallserial PRIMARY KEY,
    codigo    varchar(30) NOT NULL UNIQUE,
    nome      varchar(60) NOT NULL,
    descricao text,
    titulo    varchar(60)            -- título concedido ao personagem
);

CREATE TABLE personagem_conquista (
    personagem_id integer  NOT NULL REFERENCES personagem(id) ON DELETE CASCADE,
    conquista_id  smallint NOT NULL REFERENCES conquista(id),
    obtida_em     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (personagem_id, conquista_id)
);

-- diário de eventos narrativos do personagem
CREATE TABLE cronica (
    id            bigserial PRIMARY KEY,
    personagem_id integer REFERENCES personagem(id) ON DELETE CASCADE,
    tipo          varchar(20) NOT NULL,
    mensagem      text        NOT NULL,
    criado_em     timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_cronica_personagem ON cronica(personagem_id, id);

-- trilha de auditoria genérica (preenchida por trigger parametrizado)
CREATE TABLE auditoria (
    id           bigserial PRIMARY KEY,
    tabela       text NOT NULL,
    registro_id  integer,
    campo        text NOT NULL,
    valor_antigo text,
    valor_novo   text,
    usuario      text NOT NULL DEFAULT session_user,
    alterado_em  timestamptz NOT NULL DEFAULT clock_timestamp()
);
