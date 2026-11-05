-- =====================================================================
--  04_procedures.sql  —  PROCEDURES: as ações que o jogador executa
--  (cada CALL é atômico: qualquer RAISE EXCEPTION desfaz a ação inteira)
-- =====================================================================
SET search_path TO rpg, public;

-- atalhos por nome (CALL não aceita subconsultas como argumento)
CREATE OR REPLACE FUNCTION fn_pid(p_nome text) RETURNS int
LANGUAGE plpgsql STABLE AS $$
DECLARE v int;
BEGIN
    SELECT id INTO v FROM personagem WHERE lower(nome) = lower(btrim(p_nome));
    IF v IS NULL THEN RAISE EXCEPTION 'Personagem "%" não existe.', p_nome; END IF;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION fn_batalha_ativa(p_personagem int) RETURNS int
LANGUAGE sql STABLE AS $$
    SELECT id FROM batalha WHERE personagem_id = p_personagem AND status = 'em_andamento'
$$;

CREATE OR REPLACE FUNCTION fn_valor_venda(p_item int) RETURNS int
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN preco > 0 THEN greatest(1, preco / 2)
                ELSE CASE raridade WHEN 'comum' THEN 3 WHEN 'incomum' THEN 8
                                   WHEN 'raro' THEN 25 WHEN 'epico' THEN 60 END
           END
      FROM item WHERE id = p_item AND tipo <> 'fragmento'
$$;

-- =====================================================================
--  CRIAÇÃO E MOVIMENTAÇÃO
-- =====================================================================
CREATE OR REPLACE PROCEDURE sp_criar_personagem(p_nome text, p_classe text, INOUT p_id int DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE v_classe smallint;
BEGIN
    SELECT id INTO v_classe FROM classe WHERE lower(nome) = lower(btrim(p_classe));
    IF v_classe IS NULL THEN
        RAISE EXCEPTION 'Classe "%" não existe. Opções: %', p_classe,
            (SELECT string_agg(nome, ', ' ORDER BY id) FROM classe WHERE jogavel);
    END IF;
    INSERT INTO personagem (nome, classe_id) VALUES (p_nome, v_classe) RETURNING id INTO p_id;
    RAISE NOTICE 'Personagem % criado (id %).', initcap(p_nome), p_id;
END $$;

CREATE OR REPLACE PROCEDURE sp_viajar(p_personagem int, p_regiao text)
LANGUAGE plpgsql AS $$
DECLARE v_reg regiao;
BEGIN
    SELECT * INTO v_reg FROM regiao WHERE lower(nome) = lower(btrim(p_regiao));
    IF NOT FOUND THEN RAISE EXCEPTION 'Região "%" desconhecida.', p_regiao; END IF;
    UPDATE personagem SET regiao_id = v_reg.id WHERE id = p_personagem;   -- trigger valida
    PERFORM fn_avancar_tempo(2);
    PERFORM fn_cronica(p_personagem, 'viagem', format('Chegou a %s. %s', v_reg.nome, v_reg.descricao));
    RAISE NOTICE 'Chegou a %. Agora é % (%h).', v_reg.nome, fn_periodo_atual(), (SELECT hora FROM mundo);
END $$;

CREATE OR REPLACE PROCEDURE sp_esperar(p_horas int)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_avancar_tempo(p_horas);
    RAISE NOTICE 'O tempo passa... dia %, %h (%).', (SELECT dia FROM mundo), (SELECT hora FROM mundo), fn_periodo_atual();
END $$;

CREATE OR REPLACE PROCEDURE sp_descansar(p_personagem int)
LANGUAGE plpgsql AS $$
DECLARE c_preco CONSTANT int := 10;
BEGIN
    IF NOT (SELECT r.segura FROM personagem p JOIN regiao r ON r.id = p.regiao_id WHERE p.id = p_personagem) THEN
        RAISE EXCEPTION 'Só é possível descansar na estalagem de uma cidade.';
    END IF;
    IF (SELECT ouro FROM personagem WHERE id = p_personagem) < c_preco THEN
        RAISE EXCEPTION 'A estalagem custa % de ouro.', c_preco;
    END IF;
    UPDATE personagem SET ouro = ouro - c_preco WHERE id = p_personagem;
    PERFORM fn_recalcular_status(p_personagem, true);
    PERFORM fn_avancar_tempo(8);
    RAISE NOTICE 'Descansou na estalagem: HP e MP restaurados.';
END $$;

-- =====================================================================
--  MISSÕES
-- =====================================================================
CREATE OR REPLACE PROCEDURE sp_aceitar_quest(p_personagem int, p_quest text)
LANGUAGE plpgsql AS $$
DECLARE v_q quest;
BEGIN
    SELECT * INTO v_q FROM quest WHERE lower(nome) = lower(btrim(p_quest));
    IF NOT FOUND OR v_q.secreta THEN
        RAISE EXCEPTION 'Ninguém ofereceu a missão "%".', p_quest;
    END IF;
    IF EXISTS (SELECT 1 FROM personagem_quest WHERE personagem_id = p_personagem AND quest_id = v_q.id) THEN
        RAISE EXCEPTION 'A missão "%" já foi aceita.', v_q.nome;
    END IF;
    INSERT INTO personagem_quest (personagem_id, quest_id) VALUES (p_personagem, v_q.id);  -- triggers validam
    RAISE NOTICE 'Missão aceita: % — %', v_q.nome, v_q.descricao;
END $$;

-- =====================================================================
--  INVENTÁRIO E LOJA
-- =====================================================================
CREATE OR REPLACE PROCEDURE sp_equipar(p_personagem int, p_item text, p_equipar boolean DEFAULT true)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE inventario i SET equipado = p_equipar
      FROM item it
     WHERE it.id = i.item_id AND i.personagem_id = p_personagem AND lower(it.nome) = lower(btrim(p_item));
    IF NOT FOUND THEN RAISE EXCEPTION 'Você não possui "%".', p_item; END IF;
END $$;

CREATE OR REPLACE PROCEDURE sp_usar_item(p_personagem int, p_item text)
LANGUAGE plpgsql AS $$
DECLARE v_it item;
BEGIN
    IF fn_batalha_ativa(p_personagem) IS NOT NULL THEN
        RAISE EXCEPTION 'Em combate use: CALL sp_turno(batalha, ''item'', ''%'').', p_item;
    END IF;
    SELECT * INTO v_it FROM item WHERE lower(nome) = lower(btrim(p_item)) AND tipo = 'consumivel';
    IF NOT FOUND THEN RAISE EXCEPTION '"%" não é um consumível.', p_item; END IF;
    PERFORM fn_remover_item(p_personagem, v_it.id, 1);
    UPDATE personagem SET hp_atual = hp_atual + v_it.cura_hp, mp_atual = mp_atual + v_it.cura_mp
     WHERE id = p_personagem;
    RAISE NOTICE 'Usou %.', v_it.nome;
END $$;

CREATE OR REPLACE PROCEDURE sp_comprar(p_personagem int, p_item text, p_qtd int DEFAULT 1)
LANGUAGE plpgsql AS $$
DECLARE v_it item; v_total int;
BEGIN
    IF NOT (SELECT r.segura FROM personagem p JOIN regiao r ON r.id = p.regiao_id WHERE p.id = p_personagem) THEN
        RAISE EXCEPTION 'Não há mercador aqui.';
    END IF;
    SELECT * INTO v_it FROM item WHERE lower(nome) = lower(btrim(p_item)) AND preco > 0;
    IF NOT FOUND THEN RAISE EXCEPTION 'O mercador não vende "%".', p_item; END IF;
    v_total := v_it.preco * p_qtd;
    IF (SELECT ouro FROM personagem WHERE id = p_personagem) < v_total THEN
        RAISE EXCEPTION 'Ouro insuficiente: % custa %.', v_it.nome, v_total;
    END IF;
    UPDATE personagem SET ouro = ouro - v_total WHERE id = p_personagem;
    PERFORM fn_dar_item(p_personagem, v_it.id, p_qtd);
    RAISE NOTICE 'Comprou % x% por % de ouro.', v_it.nome, p_qtd, v_total;
END $$;

CREATE OR REPLACE PROCEDURE sp_vender(p_personagem int, p_item text, p_qtd int DEFAULT 1)
LANGUAGE plpgsql AS $$
DECLARE v_inv inventario; v_it item; v_valor int;
BEGIN
    IF NOT (SELECT r.segura FROM personagem p JOIN regiao r ON r.id = p.regiao_id WHERE p.id = p_personagem) THEN
        RAISE EXCEPTION 'Não há mercador aqui.';
    END IF;
    SELECT it.* INTO v_it FROM item it WHERE lower(it.nome) = lower(btrim(p_item));
    SELECT * INTO v_inv FROM inventario WHERE personagem_id = p_personagem AND item_id = v_it.id;
    IF v_inv IS NULL OR v_inv.quantidade < p_qtd THEN RAISE EXCEPTION 'Você não tem % x%.', p_item, p_qtd; END IF;
    IF v_inv.equipado AND v_inv.quantidade = p_qtd THEN RAISE EXCEPTION 'Desequipe "%" antes de vender.', v_it.nome; END IF;
    v_valor := fn_valor_venda(v_it.id);
    IF v_valor IS NULL THEN RAISE EXCEPTION 'O mercador recua: "%" não tem preço.', v_it.nome; END IF;
    PERFORM fn_remover_item(p_personagem, v_it.id, p_qtd);
    UPDATE personagem SET ouro = ouro + v_valor * p_qtd WHERE id = p_personagem;
    RAISE NOTICE 'Vendeu % x% por % de ouro.', v_it.nome, p_qtd, v_valor * p_qtd;
END $$;

-- =====================================================================
--  COMBATE
-- =====================================================================

-- IA do monstro: executa a ação pré-programada conforme seu comportamento
CREATE OR REPLACE FUNCTION fn_turno_monstro(p_batalha int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    b  batalha;  p personagem;  m monstro;  cm classe;  h habilidade;
    r  resultado_ataque;
    v_pct    numeric;
    v_d6     int;
    v_acao   acao_batalha := 'atacar';
    v_mult   numeric := 1;
    v_furia  boolean := false;
    v_elem   elemento;
    v_armad  elemento;
    v_val    int;
    v_msg    text;
BEGIN
    SELECT * INTO b  FROM batalha    WHERE id = p_batalha;
    SELECT * INTO p  FROM personagem WHERE id = b.personagem_id;
    SELECT * INTO m  FROM monstro    WHERE id = b.monstro_id;
    SELECT * INTO cm FROM classe     WHERE id = m.classe_id;

    v_pct := b.hp_monstro::numeric / b.hp_monstro_max;
    v_d6  := fn_rolar(1, 6);

    CASE m.comportamento
        WHEN 'defensivo'  THEN IF v_pct < 0.5 AND v_d6 <= 2 THEN v_acao := 'defender'; END IF;
        WHEN 'covarde'    THEN IF v_pct < 0.3 AND v_d6 <= 3 THEN v_acao := 'fugir';    END IF;
        WHEN 'berserker'  THEN IF v_pct < 0.3 THEN v_mult := v_mult * 1.5; v_furia := true; END IF;
        WHEN 'conjurador' THEN
            IF v_d6 >= 4 THEN
                SELECT * INTO h FROM habilidade
                 WHERE classe_id = m.classe_id AND nivel_minimo <= m.nivel ORDER BY random() LIMIT 1;
                IF FOUND THEN v_acao := 'habilidade'; END IF;
            END IF;
        ELSE NULL;
    END CASE;

    IF b.periodo = 'noite' THEN v_mult := v_mult * cm.bonus_noturno; END IF;

    -- resistência elemental da armadura equipada
    SELECT it.elemento INTO v_armad FROM inventario i JOIN item it ON it.id = i.item_id
     WHERE i.personagem_id = p.id AND i.equipado AND it.tipo = 'armadura';
    v_armad := coalesce(v_armad, 'neutro');

    IF v_acao = 'defender' THEN
        UPDATE batalha SET monstro_defendendo = true WHERE id = b.id;
        PERFORM fn_log(b.id, b.turno, 'monstro', format('%s se encolhe e se protege.', m.nome), 'defender');
        RETURN;

    ELSIF v_acao = 'fugir' THEN
        PERFORM fn_log(b.id, b.turno, 'monstro', format('%s foge para as sombras! Nada foi ganho.', m.nome), 'fugir');
        UPDATE batalha SET status = 'fuga' WHERE id = b.id;
        RETURN;

    ELSIF v_acao = 'habilidade' AND h.cura THEN
        v_val := fn_rolar(h.qtd_dados, h.lados_dado)
               + fn_atributo_monstro(m.id, (SELECT sigla FROM atributo WHERE id = h.atributo_escala));
        UPDATE batalha SET hp_monstro = least(hp_monstro + v_val, hp_monstro_max) WHERE id = b.id;
        PERFORM fn_log(b.id, b.turno, 'monstro', format('%s usa %s e recupera %s HP.', m.nome, h.nome, v_val), 'habilidade');
        RETURN;

    ELSIF v_acao = 'habilidade' THEN
        v_elem := CASE WHEN h.elemento = 'neutro' THEN m.elemento ELSE h.elemento END;
        r := fn_calcular_dano(
                fn_atributo_monstro(m.id, (SELECT sigla FROM atributo WHERE id = h.atributo_escala)),
                fn_atributo_monstro(m.id, 'AGI'), fn_atributo_monstro(m.id, 'SOR'),
                fn_atributo(p.id, 'DEF'), fn_atributo(p.id, 'AGI'),
                h.qtd_dados, h.lados_dado,
                v_mult * fn_multiplicador_elemental(v_elem, v_armad, NULL),
                b.personagem_defendendo);
        v_msg := format('%s conjura %s: d20=%s, %s — %s de dano.', m.nome, h.nome, r.d20, r.texto, r.dano);

    ELSE
        r := fn_calcular_dano(
                fn_atributo_monstro(m.id, (SELECT sigla FROM atributo WHERE id = cm.atributo_principal)),
                fn_atributo_monstro(m.id, 'AGI'), fn_atributo_monstro(m.id, 'SOR'),
                fn_atributo(p.id, 'DEF'), fn_atributo(p.id, 'AGI'),
                1, cm.dado_dano,
                v_mult * fn_multiplicador_elemental(m.elemento, v_armad, NULL),
                b.personagem_defendendo);
        v_msg := format('%s ataca: d20=%s, %s — %s de dano%s.', m.nome, r.d20, r.texto, r.dano,
                        CASE WHEN v_furia AND r.dano > 0 THEN ' (fúria!)'
                             WHEN b.periodo = 'noite' AND cm.bonus_noturno > 1 AND r.dano > 0 THEN ' (fortalecido pela noite)'
                             ELSE '' END);
    END IF;

    PERFORM fn_log(b.id, b.turno, 'monstro', v_msg, v_acao, r);
    UPDATE personagem SET hp_atual = hp_atual - r.dano WHERE id = p.id;

    IF (SELECT hp_atual FROM personagem WHERE id = p.id) <= 0 THEN
        UPDATE batalha SET status = 'derrota' WHERE id = b.id;
    END IF;
END $$;

-- Inicia uma batalha. Sem monstro informado = encontro aleatório ponderado.
CREATE OR REPLACE PROCEDURE sp_iniciar_batalha(p_personagem int, p_monstro text DEFAULT NULL,
                                               INOUT p_batalha int DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    p personagem;
    v_monstro smallint;
    v_periodo periodo := fn_periodo_atual();
    m monstro;
BEGIN
    SELECT * INTO p FROM personagem WHERE id = p_personagem;
    IF fn_batalha_ativa(p.id) IS NOT NULL THEN
        RAISE EXCEPTION '% já está em combate (batalha %).', p.nome, fn_batalha_ativa(p.id);
    END IF;

    IF p_monstro IS NULL THEN
        v_monstro := fn_sortear_monstro(p.regiao_id, v_periodo);
        IF v_monstro IS NULL THEN RAISE EXCEPTION 'Nada se move por aqui.'; END IF;
    ELSE
        SELECT mo.id INTO v_monstro FROM monstro mo JOIN monstro_regiao mr ON mr.monstro_id = mo.id
         WHERE lower(mo.nome) = lower(btrim(p_monstro)) AND mr.regiao_id = p.regiao_id
           AND mr.periodo IN (v_periodo, 'qualquer');
        IF v_monstro IS NULL THEN
            RAISE EXCEPTION '"%" não está à vista em % durante o(a) %.', p_monstro,
                (SELECT nome FROM regiao WHERE id = p.regiao_id), v_periodo;
        END IF;
    END IF;

    INSERT INTO batalha (personagem_id, monstro_id) VALUES (p.id, v_monstro) RETURNING id INTO p_batalha;
    SELECT * INTO m FROM monstro WHERE id = v_monstro;
    PERFORM fn_log(p_batalha, 0, 'sistema',
        format('%s encontra %s (nível %s, %s HP) — %s.', p.nome, m.nome, m.nivel,
               fn_hp_monstro(m.id), coalesce(m.descricao, '')));

    -- EMBOSCADA: disputa de iniciativa d20 + AGI; vencendo por 5+, o monstro age primeiro
    IF fn_rolar(1, 20) + fn_atributo_monstro(m.id, 'AGI') >= fn_rolar(1, 20) + fn_atributo(p.id, 'AGI') + 5 THEN
        PERFORM fn_log(p_batalha, 0, 'sistema', 'Emboscada! O monstro age primeiro.');
        PERFORM fn_turno_monstro(p_batalha);
    END IF;
    RAISE NOTICE 'Batalha % iniciada: % vs %.', p_batalha, p.nome, m.nome;
END $$;

-- Executa UM turno: ação do personagem e, se o monstro sobreviver, a resposta dele.
CREATE OR REPLACE PROCEDURE sp_turno(p_batalha int, p_acao acao_batalha DEFAULT 'atacar', p_ref text DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    b  batalha;  p personagem;  m monstro;  c classe;  h habilidade;  it item;
    r  resultado_ataque;
    v_elem elemento;
    v_mult numeric;
    v_atr  int;
    v_val  int;
    v_msg  text;
BEGIN
    SELECT * INTO b FROM batalha WHERE id = p_batalha FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Batalha % não existe.', p_batalha; END IF;
    IF b.status <> 'em_andamento' THEN
        RAISE EXCEPTION 'A batalha % já terminou (%).', b.id, b.status;
    END IF;
    SELECT * INTO p FROM personagem WHERE id = b.personagem_id;
    SELECT * INTO m FROM monstro    WHERE id = b.monstro_id;
    SELECT * INTO c FROM classe     WHERE id = p.classe_id;

    b.turno := b.turno + 1;
    b.personagem_defendendo := false;

    CASE p_acao
    WHEN 'atacar' THEN
        SELECT it2.elemento INTO v_elem FROM inventario i JOIN item it2 ON it2.id = i.item_id
         WHERE i.personagem_id = p.id AND i.equipado AND it2.tipo = 'arma';
        v_mult := fn_multiplicador_elemental(coalesce(v_elem, 'neutro'), m.elemento, m.fraqueza);
        r := fn_calcular_dano(
                fn_atributo(p.id, (SELECT sigla FROM atributo WHERE id = c.atributo_principal)),
                fn_atributo(p.id, 'AGI'), fn_atributo(p.id, 'SOR'),
                fn_atributo_monstro(m.id, 'DEF'), fn_atributo_monstro(m.id, 'AGI'),
                1, c.dado_dano, v_mult, b.monstro_defendendo);
        b.hp_monstro := b.hp_monstro - r.dano;
        v_msg := format('%s ataca %s: d20=%s, %s — %s de dano%s.', p.nome, m.nome, r.d20, r.texto, r.dano,
                        CASE WHEN r.dano > 0 AND v_mult > 1 THEN ' (fraqueza!)'
                             WHEN r.dano > 0 AND v_mult < 1 THEN ' (resistido)' ELSE '' END);
        PERFORM fn_log(b.id, b.turno, 'personagem', v_msg, p_acao, r);

    WHEN 'habilidade' THEN
        SELECT * INTO h FROM habilidade WHERE lower(nome) = lower(btrim(p_ref)) AND classe_id = p.classe_id;
        IF NOT FOUND THEN RAISE EXCEPTION '% não conhece a habilidade "%".', p.nome, p_ref; END IF;
        IF p.nivel < h.nivel_minimo THEN RAISE EXCEPTION '"%" exige nível %.', h.nome, h.nivel_minimo; END IF;
        IF p.mp_atual < h.custo_mp THEN
            RAISE EXCEPTION 'MP insuficiente para % (% / %).', h.nome, p.mp_atual, h.custo_mp;
        END IF;
        UPDATE personagem SET mp_atual = mp_atual - h.custo_mp WHERE id = p.id;
        v_atr := fn_atributo(p.id, (SELECT sigla FROM atributo WHERE id = h.atributo_escala));

        IF h.cura THEN
            v_val := fn_rolar(h.qtd_dados, h.lados_dado) + v_atr;
            UPDATE personagem SET hp_atual = hp_atual + v_val WHERE id = p.id;
            PERFORM fn_log(b.id, b.turno, 'personagem',
                format('%s usa %s e recupera %s HP.', p.nome, h.nome, v_val), p_acao);
        ELSE
            v_mult := fn_multiplicador_elemental(h.elemento, m.elemento, m.fraqueza);
            r := fn_calcular_dano(v_atr, fn_atributo(p.id, 'AGI'), fn_atributo(p.id, 'SOR'),
                    fn_atributo_monstro(m.id, 'DEF'), fn_atributo_monstro(m.id, 'AGI'),
                    h.qtd_dados, h.lados_dado, v_mult, b.monstro_defendendo);
            b.hp_monstro := b.hp_monstro - r.dano;
            v_msg := format('%s usa %s (%s): d20=%s, %s — %s de dano%s.', p.nome, h.nome, h.elemento,
                            r.d20, r.texto, r.dano,
                            CASE WHEN r.dano > 0 AND v_mult > 1 THEN ' (fraqueza!)'
                                 WHEN r.dano > 0 AND v_mult < 1 THEN ' (resistido)' ELSE '' END);
            PERFORM fn_log(b.id, b.turno, 'personagem', v_msg, p_acao, r);
        END IF;

    WHEN 'item' THEN
        SELECT * INTO it FROM item WHERE lower(nome) = lower(btrim(p_ref)) AND tipo = 'consumivel';
        IF NOT FOUND THEN RAISE EXCEPTION '"%" não é um consumível.', p_ref; END IF;
        PERFORM fn_remover_item(p.id, it.id, 1);
        UPDATE personagem SET hp_atual = hp_atual + it.cura_hp, mp_atual = mp_atual + it.cura_mp
         WHERE id = p.id;
        PERFORM fn_log(b.id, b.turno, 'personagem',
            format('%s usa %s (+%s HP, +%s MP).', p.nome, it.nome, it.cura_hp, it.cura_mp), p_acao);

    WHEN 'defender' THEN
        b.personagem_defendendo := true;
        UPDATE personagem SET mp_atual = mp_atual + 2 WHERE id = p.id;
        PERFORM fn_log(b.id, b.turno, 'personagem',
            format('%s ergue a guarda e recupera o fôlego (+2 MP).', p.nome), p_acao);

    WHEN 'fugir' THEN
        IF m.chefe THEN
            PERFORM fn_log(b.id, b.turno, 'personagem', format('%s tenta fugir, mas %s bloqueia a saída!', p.nome, m.nome), p_acao);
        ELSIF fn_rolar(1, 20) + fn_atributo(p.id, 'AGI') / 3 >= 10 + fn_atributo_monstro(m.id, 'AGI') / 3 THEN
            b.status := 'fuga';
            PERFORM fn_log(b.id, b.turno, 'personagem', format('%s escapa!', p.nome), p_acao);
        ELSE
            PERFORM fn_log(b.id, b.turno, 'personagem', format('%s tenta fugir e tropeça.', p.nome), p_acao);
        END IF;
    END CASE;

    -- a guarda do monstro só vale contra o golpe seguinte
    b.monstro_defendendo := false;
    IF b.hp_monstro <= 0 THEN
        b.hp_monstro := 0;
        b.status := 'vitoria';
    END IF;

    UPDATE batalha
       SET turno = b.turno, hp_monstro = b.hp_monstro, status = b.status,
           personagem_defendendo = b.personagem_defendendo, monstro_defendendo = b.monstro_defendendo
     WHERE id = b.id;

    IF b.status = 'em_andamento' THEN
        PERFORM fn_turno_monstro(b.id);
    END IF;

    SELECT * INTO b FROM batalha WHERE id = p_batalha;
    SELECT * INTO p FROM personagem WHERE id = b.personagem_id;
    RAISE NOTICE 'Turno % | % HP %/% MP %/% | % HP %/% | %', b.turno, p.nome, p.hp_atual, p.hp_max,
        p.mp_atual, p.mp_max, m.nome, b.hp_monstro, b.hp_monstro_max, upper(b.status::text);
END $$;

-- Batalha completa com turnos pré-programados (estratégia automática do personagem)
CREATE OR REPLACE PROCEDURE sp_batalha_automatica(p_personagem int, p_monstro text DEFAULT NULL,
                                                  p_max_turnos int DEFAULT 40,
                                                  INOUT p_resultado status_batalha DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_b    int;
    p      personagem;
    m      monstro;
    v_acao acao_batalha;
    v_ref  text;
BEGIN
    CALL sp_iniciar_batalha(p_personagem, p_monstro, v_b);
    SELECT mo.* INTO m FROM monstro mo JOIN batalha b ON b.monstro_id = mo.id WHERE b.id = v_b;

    LOOP
        SELECT status INTO p_resultado FROM batalha WHERE id = v_b;
        EXIT WHEN p_resultado <> 'em_andamento';
        IF (SELECT turno FROM batalha WHERE id = v_b) >= p_max_turnos THEN
            UPDATE batalha SET status = 'fuga' WHERE id = v_b;
            p_resultado := 'fuga';
            EXIT;
        END IF;

        SELECT * INTO p FROM personagem WHERE id = p_personagem;
        v_acao := NULL; v_ref := NULL;

        -- 1) vida baixa: magia de cura ou poção
        IF p.hp_atual < p.hp_max * 0.4 THEN
            SELECT nome INTO v_ref FROM habilidade
             WHERE classe_id = p.classe_id AND cura AND nivel_minimo <= p.nivel AND custo_mp <= p.mp_atual
             ORDER BY qtd_dados * lados_dado DESC LIMIT 1;
            IF v_ref IS NOT NULL THEN
                v_acao := 'habilidade';
            ELSE
                SELECT it.nome INTO v_ref FROM inventario i JOIN item it ON it.id = i.item_id
                 WHERE i.personagem_id = p.id AND it.cura_hp > 0
                 ORDER BY abs(it.cura_hp - (p.hp_max - p.hp_atual)) LIMIT 1;  -- a que melhor cobre o dano
                IF v_ref IS NOT NULL THEN v_acao := 'item'; END IF;
            END IF;
        END IF;

        -- 2) ofensiva: prefere a habilidade que explora a fraqueza, depois a mais forte
        IF v_acao IS NULL THEN
            SELECT nome INTO v_ref FROM habilidade
             WHERE classe_id = p.classe_id AND NOT cura AND nivel_minimo <= p.nivel AND custo_mp <= p.mp_atual
             ORDER BY (elemento = m.fraqueza) IS TRUE DESC,qtd_dados * lados_dado DESC LIMIT 1;
            v_acao := CASE WHEN v_ref IS NOT NULL THEN 'habilidade' ELSE 'atacar' END::acao_batalha;
        END IF;

        CALL sp_turno(v_b, v_acao, v_ref);
    END LOOP;

    RAISE NOTICE '=== Batalha % terminou: % ===', v_b, upper(p_resultado::text);
END $$;
