-- =====================================================================
--  02_funcoes.sql  —  FUNCTIONS: dados, fórmulas, cálculo de dano,
--                     utilitários de inventário, segredos e conquistas
-- =====================================================================
SET search_path TO rpg, public;

-- ---------------------------------------------------------------------
--  DADOS
-- ---------------------------------------------------------------------
-- Rola N dados de L lados (ex.: fn_rolar(2, 6) = 2d6)
CREATE OR REPLACE FUNCTION fn_rolar(p_qtd int, p_lados int)
RETURNS int LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_total int := 0;
BEGIN
    IF p_qtd < 1 OR p_lados < 2 THEN
        RAISE EXCEPTION 'Dado inválido: %d%', p_qtd, p_lados;
    END IF;
    FOR i IN 1..p_qtd LOOP
        v_total := v_total + floor(random() * p_lados)::int + 1;
    END LOOP;
    RETURN v_total;
END $$;

-- Rola a partir de notação de RPG: 'd20', '3d6+2', '1d64-4'
CREATE OR REPLACE FUNCTION fn_rolar_expr(p_expr text)
RETURNS int LANGUAGE plpgsql VOLATILE AS $$
DECLARE m text[];
BEGIN
    m := regexp_match(replace(lower(p_expr), ' ', ''), '^(\d*)d(\d+)([+-]\d+)?$');
    IF m IS NULL THEN
        RAISE EXCEPTION 'Expressão de dado inválida: "%". Use o formato NdL+B (ex.: 2d6+3).', p_expr;
    END IF;
    RETURN fn_rolar(coalesce(nullif(m[1], '')::int, 1), m[2]::int) + coalesce(m[3]::int, 0);
END $$;

-- ---------------------------------------------------------------------
--  PROGRESSÃO
-- ---------------------------------------------------------------------
-- XP total necessário para ALCANÇAR o nível n  (curva 100·(n-1)^1.5)
CREATE OR REPLACE FUNCTION fn_xp_para_nivel(p_nivel int)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT floor(100 * power(greatest(p_nivel - 1, 0), 1.5))::int
$$;

CREATE OR REPLACE FUNCTION fn_nivel_por_xp(p_xp int)
RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
    SELECT max(n)::smallint FROM generate_series(1, 50) n WHERE fn_xp_para_nivel(n) <= p_xp
$$;

CREATE OR REPLACE FUNCTION fn_atributo_id(p_sigla text)
RETURNS smallint LANGUAGE sql STABLE AS $$
    SELECT id FROM atributo WHERE sigla = upper(p_sigla)
$$;

-- valor de um atributo para uma classe em determinado nível
CREATE OR REPLACE FUNCTION fn_atributo_base(p_classe int, p_atributo int, p_nivel int)
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT coalesce(floor(base + ganho_por_nivel * (p_nivel - 1))::int, 0)
      FROM classe_atributo WHERE classe_id = p_classe AND atributo_id = p_atributo
$$;

-- atributo TOTAL do personagem = base + bônus dos itens equipados
CREATE OR REPLACE FUNCTION fn_atributo(p_personagem int, p_sigla text)
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT pa.valor FROM personagem_atributo pa
                      WHERE pa.personagem_id = p_personagem
                        AND pa.atributo_id = fn_atributo_id(p_sigla)), 0)
         + coalesce((SELECT sum(ib.valor) FROM inventario i
                       JOIN item_bonus ib ON ib.item_id = i.item_id
                      WHERE i.personagem_id = p_personagem AND i.equipado
                        AND ib.atributo_id = fn_atributo_id(p_sigla)), 0)::int
$$;

-- atributo do monstro: deriva da sua Classe + nível; chefes recebem +30%
CREATE OR REPLACE FUNCTION fn_atributo_monstro(p_monstro int, p_sigla text)
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT floor(fn_atributo_base(m.classe_id, fn_atributo_id(p_sigla), m.nivel)
                 * CASE WHEN m.chefe THEN 1.3 ELSE 1 END)::int
      FROM monstro m WHERE m.id = p_monstro
$$;

CREATE OR REPLACE FUNCTION fn_hp_max(p_vit int, p_nivel int)
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 10 + p_vit * 3 + p_nivel * 2 $$;

CREATE OR REPLACE FUNCTION fn_mp_max(p_mag int, p_nivel int)
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT p_mag * 2 + p_nivel $$;

CREATE OR REPLACE FUNCTION fn_hp_monstro(p_monstro int)
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT floor(fn_hp_max(fn_atributo_monstro(m.id, 'VIT'), m.nivel)
                 * CASE WHEN m.chefe THEN 2.0 ELSE 1 END)::int
      FROM monstro m WHERE m.id = p_monstro
$$;

-- grava os atributos-base do personagem conforme classe e nível atuais
CREATE OR REPLACE FUNCTION fn_atualizar_atributos_base(p_personagem int)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO personagem_atributo (personagem_id, atributo_id, valor)
    SELECT p.id, ca.atributo_id, fn_atributo_base(p.classe_id, ca.atributo_id, p.nivel)
      FROM personagem p JOIN classe_atributo ca ON ca.classe_id = p.classe_id
     WHERE p.id = p_personagem
    ON CONFLICT (personagem_id, atributo_id) DO UPDATE SET valor = EXCLUDED.valor;
$$;

-- recalcula HP/MP máximos (VIT/MAG totais); p_curar = restaura tudo
CREATE OR REPLACE FUNCTION fn_recalcular_status(p_personagem int, p_curar boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_hp int; v_mp int; v_nivel int;
BEGIN
    SELECT nivel INTO v_nivel FROM personagem WHERE id = p_personagem;
    v_hp := fn_hp_max(fn_atributo(p_personagem, 'VIT'), v_nivel);
    v_mp := fn_mp_max(fn_atributo(p_personagem, 'MAG'), v_nivel);
    UPDATE personagem
       SET hp_max   = v_hp,
           mp_max   = v_mp,
           hp_atual = CASE WHEN p_curar THEN v_hp ELSE hp_atual END,
           mp_atual = CASE WHEN p_curar THEN v_mp ELSE mp_atual END
     WHERE id = p_personagem;
END $$;

-- ---------------------------------------------------------------------
--  MUNDO (dia / noite)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_periodo_atual()
RETURNS periodo LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN hora BETWEEN 6 AND 17 THEN 'dia' ELSE 'noite' END::periodo FROM mundo
$$;

CREATE OR REPLACE FUNCTION fn_avancar_tempo(p_horas int)
RETURNS void LANGUAGE sql AS $$
    UPDATE mundo SET dia = dia + (hora + p_horas) / 24, hora = (hora + p_horas) % 24;
$$;

-- ---------------------------------------------------------------------
--  COMBATE
-- ---------------------------------------------------------------------
CREATE TYPE resultado_ataque AS (
    acertou       boolean,
    critico       boolean,
    d20           int,
    rolagem_dano  int,
    dano          int,
    multiplicador numeric,
    texto         text
);

-- 1.5x se o elemento do golpe é a fraqueza do alvo; 0.5x se o alvo é do mesmo elemento
CREATE OR REPLACE FUNCTION fn_multiplicador_elemental(p_golpe elemento, p_alvo elemento, p_fraqueza elemento)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN p_golpe = 'neutro'       THEN 1.0
             WHEN p_golpe = p_fraqueza     THEN 1.5
             WHEN p_golpe = p_alvo         THEN 0.5
             ELSE 1.0
           END
$$;

/*  Regra de dano (toda dentro do SGBD):
      1. Rola d20 de acerto. 1 natural = falha crítica.
         Margem de crítico = 20 - SOR/10 (mínimo 17).
      2. Acerta se d20 + AGI_atk/3 >= 8 + AGI_def/3 (ou se for crítico).
      3. Dano = (NdL [+NdL se crítico] + ATQ - DEF/2) * multiplicador;
         alvo defendendo recebe metade. Mínimo 1.                         */
CREATE OR REPLACE FUNCTION fn_calcular_dano(
    p_atq int, p_agi_atacante int, p_sor_atacante int,
    p_def int, p_agi_defensor int,
    p_qtd_dados int, p_lados int,
    p_multiplicador numeric DEFAULT 1,
    p_defendendo boolean DEFAULT false)
RETURNS resultado_ataque LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    r resultado_ataque;
    v_bruto numeric;
BEGIN
    r.d20 := fn_rolar(1, 20);
    r.critico := r.d20 >= greatest(17, 20 - p_sor_atacante / 10);
    r.multiplicador := p_multiplicador;
    r.rolagem_dano := 0;
    r.dano := 0;

    IF r.d20 = 1 THEN
        r.acertou := false; r.critico := false; r.texto := 'falha crítica';
        RETURN r;
    END IF;

    r.acertou := r.critico OR (r.d20 + p_agi_atacante / 3) >= (8 + p_agi_defensor / 3);
    IF NOT r.acertou THEN
        r.texto := 'errou';
        RETURN r;
    END IF;

    r.rolagem_dano := fn_rolar(p_qtd_dados, p_lados);
    IF r.critico THEN
        r.rolagem_dano := r.rolagem_dano + fn_rolar(p_qtd_dados, p_lados);
    END IF;

    v_bruto := (r.rolagem_dano + p_atq - p_def / 2.0) * p_multiplicador;
    IF p_defendendo THEN v_bruto := v_bruto * 0.5; END IF;

    r.dano  := greatest(1, round(v_bruto))::int;
    r.texto := CASE WHEN r.critico THEN 'CRÍTICO' ELSE 'acerto' END;
    RETURN r;
END $$;

-- sorteio ponderado de encontro aleatório na região, respeitando dia/noite
CREATE OR REPLACE FUNCTION fn_sortear_monstro(p_regiao int, p_periodo periodo)
RETURNS smallint LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_total int;
    v_sorteio numeric;
    rec record;
BEGIN
    SELECT sum(peso) INTO v_total FROM monstro_regiao
     WHERE regiao_id = p_regiao AND periodo IN (p_periodo, 'qualquer');
    IF v_total IS NULL THEN RETURN NULL; END IF;

    v_sorteio := random() * v_total;
    FOR rec IN SELECT monstro_id,
                      sum(peso) OVER (ORDER BY monstro_id) AS acumulado
                 FROM monstro_regiao
                WHERE regiao_id = p_regiao AND periodo IN (p_periodo, 'qualquer')
                ORDER BY monstro_id
    LOOP
        IF v_sorteio < rec.acumulado THEN RETURN rec.monstro_id; END IF;
    END LOOP;
    RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
--  REGISTROS NARRATIVOS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cronica(p_personagem int, p_tipo text, p_msg text)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO cronica (personagem_id, tipo, mensagem) VALUES (p_personagem, p_tipo, p_msg);
$$;

CREATE OR REPLACE FUNCTION fn_log(p_batalha int, p_turno int, p_ator text, p_msg text,
                                  p_acao acao_batalha DEFAULT NULL, p_r resultado_ataque DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO batalha_log (batalha_id, turno, ator, acao, rolagem_d20, rolagem_dano, dano, critico, mensagem)
    VALUES (p_batalha, p_turno, p_ator, p_acao, (p_r).d20, (p_r).rolagem_dano, (p_r).dano,
            coalesce((p_r).critico, false), p_msg);
$$;

-- ---------------------------------------------------------------------
--  INVENTÁRIO
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_dar_item(p_personagem int, p_item int, p_qtd int DEFAULT 1)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO inventario (personagem_id, item_id, quantidade)
    VALUES (p_personagem, p_item, p_qtd)
    ON CONFLICT (personagem_id, item_id)
    DO UPDATE SET quantidade = inventario.quantidade + EXCLUDED.quantidade;
$$;

CREATE OR REPLACE FUNCTION fn_remover_item(p_personagem int, p_item int, p_qtd int DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE inventario SET quantidade = quantidade - p_qtd
     WHERE personagem_id = p_personagem AND item_id = p_item AND quantidade >= p_qtd;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Quantidade insuficiente de "%" no inventário.',
            (SELECT nome FROM item WHERE id = p_item);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_pode_acessar_regiao(p_personagem int, p_regiao int)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT p.nivel >= r.nivel_minimo
       AND (NOT r.secreta OR EXISTS (
                SELECT 1 FROM personagem_segredo ps JOIN segredo s ON s.id = ps.segredo_id
                 WHERE ps.personagem_id = p.id AND s.regiao_desbloqueada = r.id))
      FROM personagem p, regiao r
     WHERE p.id = p_personagem AND r.id = p_regiao
$$;

-- ---------------------------------------------------------------------
--  MISTÉRIOS: revela segredos quando o personagem possui TODOS os itens
--  exigidos (divisão relacional com NOT EXISTS duplo)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_verificar_segredos(p_personagem int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE s record;
BEGIN
    FOR s IN
        SELECT sg.* FROM segredo sg
         WHERE EXISTS (SELECT 1 FROM segredo_requisito r WHERE r.segredo_id = sg.id)
           AND NOT EXISTS (SELECT 1 FROM personagem_segredo ps
                            WHERE ps.personagem_id = p_personagem AND ps.segredo_id = sg.id)
           AND NOT EXISTS (SELECT 1 FROM segredo_requisito r
                            WHERE r.segredo_id = sg.id
                              AND NOT EXISTS (SELECT 1 FROM inventario i
                                               WHERE i.personagem_id = p_personagem
                                                 AND i.item_id = r.item_id AND i.quantidade > 0))
    LOOP
        INSERT INTO personagem_segredo (personagem_id, segredo_id) VALUES (p_personagem, s.id);
        PERFORM fn_cronica(p_personagem, 'segredo', s.mensagem);
        IF s.quest_desbloqueada IS NOT NULL THEN
            INSERT INTO personagem_quest (personagem_id, quest_id)
            VALUES (p_personagem, s.quest_desbloqueada) ON CONFLICT DO NOTHING;
        END IF;
        RAISE NOTICE '✦ SEGREDO REVELADO: % ✦', s.nome;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
--  CONQUISTAS (avaliadas por estatísticas agregadas do histórico)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_verificar_conquistas(p_personagem int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    st record;
    c  record;
BEGIN
    SELECT
        (SELECT nivel FROM personagem WHERE id = p_personagem)                          AS nivel,
        count(*) FILTER (WHERE b.status = 'vitoria')                                    AS vitorias,
        count(*) FILTER (WHERE b.status = 'vitoria' AND b.periodo = 'noite')            AS vitorias_noite,
        count(*) FILTER (WHERE b.status = 'derrota')                                    AS derrotas,
        count(*) FILTER (WHERE b.status = 'vitoria' AND m.chefe)                        AS chefes,
        coalesce(max((SELECT count(*) FROM batalha_log l
                       WHERE l.batalha_id = b.id AND l.ator = 'personagem' AND l.critico)), 0) AS max_criticos,
        (SELECT count(*) FROM personagem_segredo WHERE personagem_id = p_personagem)    AS segredos
      INTO st
      FROM batalha b JOIN monstro m ON m.id = b.monstro_id
     WHERE b.personagem_id = p_personagem;

    FOR c IN
        SELECT cq.* FROM conquista cq
         WHERE NOT EXISTS (SELECT 1 FROM personagem_conquista pc
                            WHERE pc.personagem_id = p_personagem AND pc.conquista_id = cq.id)
           AND CASE cq.codigo
                 WHEN 'PRIMEIRO_SANGUE' THEN st.vitorias >= 1
                 WHEN 'CACADOR'         THEN st.vitorias >= 10
                 WHEN 'NOTURNO'         THEN st.vitorias_noite >= 10
                 WHEN 'FAVORECIDO'      THEN st.max_criticos >= 3
                 WHEN 'QUEBRA_COROAS'   THEN st.chefes >= 1
                 WHEN 'VETERANO'        THEN st.nivel >= 5
                 WHEN 'AQUELE_QUE_VOLTOU' THEN st.derrotas >= 1
                 WHEN 'OUVINTE_DO_SINO' THEN st.segredos >= 1
                 ELSE false
               END
    LOOP
        INSERT INTO personagem_conquista (personagem_id, conquista_id) VALUES (p_personagem, c.id);
        IF c.titulo IS NOT NULL THEN
            UPDATE personagem SET titulo = c.titulo WHERE id = p_personagem;
        END IF;
        PERFORM fn_cronica(p_personagem, 'conquista',
                format('Conquista desbloqueada: %s — %s', c.nome, c.descricao));
    END LOOP;
END $$;
