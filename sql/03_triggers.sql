-- =====================================================================
--  03_triggers.sql  —  TRIGGERS: regras de negócio reativas
-- =====================================================================
SET search_path TO rpg, public;

-- =====================================================================
--  PERSONAGEM
-- =====================================================================

-- [BEFORE INSERT] valida a classe e posiciona o personagem na cidade inicial
CREATE OR REPLACE FUNCTION fn_trg_personagem_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT (SELECT jogavel FROM classe WHERE id = NEW.classe_id) THEN
        RAISE EXCEPTION 'A classe "%" pertence a monstros e não pode ser escolhida.',
            (SELECT nome FROM classe WHERE id = NEW.classe_id);
    END IF;
    NEW.nome  := initcap(btrim(NEW.nome));
    NEW.nivel := 1;
    NEW.xp    := 0;
    IF NEW.regiao_id IS NULL THEN
        SELECT id INTO NEW.regiao_id FROM regiao WHERE segura ORDER BY id LIMIT 1;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_personagem_a_validar BEFORE INSERT ON personagem
    FOR EACH ROW EXECUTE FUNCTION fn_trg_personagem_validar();

-- [AFTER INSERT] gera atributos pela classe, entrega kit inicial e calcula HP/MP
CREATE OR REPLACE FUNCTION fn_trg_personagem_inicializar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE k record;
BEGIN
    PERFORM fn_atualizar_atributos_base(NEW.id);

    FOR k IN SELECT * FROM classe_item_inicial WHERE classe_id = NEW.classe_id LOOP
        INSERT INTO inventario (personagem_id, item_id, quantidade, equipado)
        VALUES (NEW.id, k.item_id, k.quantidade, k.equipar);
    END LOOP;

    PERFORM fn_recalcular_status(NEW.id, true);
    PERFORM fn_cronica(NEW.id, 'origem',
        format('%s, %s, desperta em %s ouvindo um sino que ninguém mais escuta.',
               NEW.nome, (SELECT nome FROM classe WHERE id = NEW.classe_id),
               (SELECT nome FROM regiao WHERE id = NEW.regiao_id)));
    RETURN NULL;
END $$;
CREATE TRIGGER trg_personagem_inicializar AFTER INSERT ON personagem
    FOR EACH ROW EXECUTE FUNCTION fn_trg_personagem_inicializar();

-- [BEFORE UPDATE] mantém HP/MP dentro dos limites
CREATE OR REPLACE FUNCTION fn_trg_personagem_limites() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.hp_atual := least(greatest(NEW.hp_atual, 0), NEW.hp_max);
    NEW.mp_atual := least(greatest(NEW.mp_atual, 0), NEW.mp_max);
    RETURN NEW;
END $$;
CREATE TRIGGER trg_personagem_b_limites BEFORE UPDATE ON personagem
    FOR EACH ROW EXECUTE FUNCTION fn_trg_personagem_limites();

-- [BEFORE UPDATE OF xp] experiência define o nível automaticamente
CREATE OR REPLACE FUNCTION fn_trg_personagem_xp() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.nivel := greatest(OLD.nivel, fn_nivel_por_xp(NEW.xp));
    RETURN NEW;
END $$;
CREATE TRIGGER trg_personagem_c_xp BEFORE UPDATE OF xp ON personagem
    FOR EACH ROW EXECUTE FUNCTION fn_trg_personagem_xp();

-- [BEFORE UPDATE OF regiao_id] valida viagem (nível, região secreta, combate)
CREATE OR REPLACE FUNCTION fn_trg_personagem_viagem() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.regiao_id IS DISTINCT FROM OLD.regiao_id THEN
        IF EXISTS (SELECT 1 FROM batalha WHERE personagem_id = NEW.id AND status = 'em_andamento') THEN
            RAISE EXCEPTION 'Não é possível viajar no meio de uma batalha.';
        END IF;
        IF NOT fn_pode_acessar_regiao(NEW.id, NEW.regiao_id) THEN
            RAISE EXCEPTION 'O caminho para "%" está fechado para %.',
                (SELECT nome FROM regiao WHERE id = NEW.regiao_id), NEW.nome;
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_personagem_d_viagem BEFORE UPDATE OF regiao_id ON personagem
    FOR EACH ROW EXECUTE FUNCTION fn_trg_personagem_viagem();

-- [AFTER UPDATE] subiu de nível: recalcula atributos, cura e registra
CREATE OR REPLACE FUNCTION fn_trg_personagem_level_up() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_atualizar_atributos_base(NEW.id);
    PERFORM fn_recalcular_status(NEW.id, true);
    PERFORM fn_cronica(NEW.id, 'nivel',
        format('%s alcançou o nível %s!', NEW.nome, NEW.nivel));
    PERFORM fn_verificar_conquistas(NEW.id);
    RAISE NOTICE '▲ % subiu para o nível %!', NEW.nome, NEW.nivel;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_personagem_level_up AFTER UPDATE ON personagem
    FOR EACH ROW WHEN (NEW.nivel > OLD.nivel)
    EXECUTE FUNCTION fn_trg_personagem_level_up();

-- [AFTER UPDATE OF regiao_id] progresso de quests de exploração
CREATE OR REPLACE FUNCTION fn_trg_personagem_explorar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE personagem_quest pq SET progresso = 1
      FROM quest q
     WHERE q.id = pq.quest_id AND pq.personagem_id = NEW.id
       AND pq.status = 'ativa' AND q.tipo = 'explorar' AND q.regiao_alvo = NEW.regiao_id;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_personagem_explorar AFTER UPDATE OF regiao_id ON personagem
    FOR EACH ROW WHEN (NEW.regiao_id IS DISTINCT FROM OLD.regiao_id)
    EXECUTE FUNCTION fn_trg_personagem_explorar();

-- [AFTER UPDATE] auditoria genérica: as colunas auditadas vêm em TG_ARGV
CREATE OR REPLACE FUNCTION fn_trg_auditoria() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_old jsonb := to_jsonb(OLD);
    v_new jsonb := to_jsonb(NEW);
    v_col text;
BEGIN
    FOREACH v_col IN ARRAY TG_ARGV LOOP
        IF v_old -> v_col IS DISTINCT FROM v_new -> v_col THEN
            INSERT INTO auditoria (tabela, registro_id, campo, valor_antigo, valor_novo)
            VALUES (TG_TABLE_NAME, (v_new ->> 'id')::int, v_col, v_old ->> v_col, v_new ->> v_col);
        END IF;
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_personagem_auditoria AFTER UPDATE ON personagem
    FOR EACH ROW EXECUTE FUNCTION fn_trg_auditoria('nivel', 'xp', 'ouro', 'regiao_id', 'titulo');

-- =====================================================================
--  INVENTÁRIO
-- =====================================================================

-- [BEFORE INSERT/UPDATE] capacidade da mochila e regras de equipamento
CREATE OR REPLACE FUNCTION fn_trg_inventario_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_item item;
    v_pers personagem;
    c_capacidade CONSTANT int := 20;
BEGIN
    SELECT * INTO v_item FROM item WHERE id = NEW.item_id;
    SELECT * INTO v_pers FROM personagem WHERE id = NEW.personagem_id;

    IF TG_OP = 'INSERT'
       AND NOT EXISTS (SELECT 1 FROM inventario WHERE personagem_id = NEW.personagem_id AND item_id = NEW.item_id)
       AND (SELECT count(*) FROM inventario WHERE personagem_id = NEW.personagem_id) >= c_capacidade THEN
        RAISE EXCEPTION 'A mochila de % está cheia (% tipos de item).', v_pers.nome, c_capacidade;
    END IF;

    IF NEW.equipado AND (TG_OP = 'INSERT' OR NOT OLD.equipado) THEN
        IF v_item.tipo NOT IN ('arma', 'armadura', 'acessorio') THEN
            RAISE EXCEPTION '"%" não é equipável.', v_item.nome;
        END IF;
        IF v_item.classe_requerida IS NOT NULL AND v_item.classe_requerida <> v_pers.classe_id THEN
            RAISE EXCEPTION '"%" só pode ser usado pela classe %.', v_item.nome,
                (SELECT nome FROM classe WHERE id = v_item.classe_requerida);
        END IF;
        IF v_pers.nivel < v_item.nivel_minimo THEN
            RAISE EXCEPTION '"%" exige nível %.', v_item.nome, v_item.nivel_minimo;
        END IF;
        -- troca automática: desequipa o item do mesmo tipo
        UPDATE inventario i SET equipado = false
          FROM item it
         WHERE it.id = i.item_id AND i.personagem_id = NEW.personagem_id
           AND i.equipado AND it.tipo = v_item.tipo AND i.item_id <> NEW.item_id;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_inventario_validar BEFORE INSERT OR UPDATE ON inventario
    FOR EACH ROW EXECUTE FUNCTION fn_trg_inventario_validar();

-- [AFTER INSERT/UPDATE] limpa pilhas vazias, recalcula status, quests de coleta e segredos
CREATE OR REPLACE FUNCTION fn_trg_inventario_pos() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_tipo tipo_item;
BEGIN
    SELECT tipo INTO v_tipo FROM item WHERE id = NEW.item_id;

    IF NEW.quantidade = 0 THEN
        DELETE FROM inventario WHERE id = NEW.id;     -- dispara o trigger de DELETE
        RETURN NULL;
    END IF;

    IF TG_OP = 'INSERT' AND NEW.equipado OR TG_OP = 'UPDATE' AND NEW.equipado <> OLD.equipado THEN
        PERFORM fn_recalcular_status(NEW.personagem_id);
    END IF;

    UPDATE personagem_quest pq SET progresso = NEW.quantidade
      FROM quest q
     WHERE q.id = pq.quest_id AND pq.personagem_id = NEW.personagem_id
       AND pq.status = 'ativa' AND q.tipo = 'coletar' AND q.item_alvo = NEW.item_id;

    IF v_tipo = 'fragmento' THEN
        PERFORM fn_verificar_segredos(NEW.personagem_id);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_inventario_pos AFTER INSERT OR UPDATE ON inventario
    FOR EACH ROW EXECUTE FUNCTION fn_trg_inventario_pos();

CREATE OR REPLACE FUNCTION fn_trg_inventario_removido() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.equipado AND EXISTS (SELECT 1 FROM personagem WHERE id = OLD.personagem_id) THEN
        PERFORM fn_recalcular_status(OLD.personagem_id);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_inventario_removido AFTER DELETE ON inventario
    FOR EACH ROW EXECUTE FUNCTION fn_trg_inventario_removido();

-- =====================================================================
--  BATALHA
-- =====================================================================

-- [BEFORE INSERT] prepara o monstro e valida o local
CREATE OR REPLACE FUNCTION fn_trg_batalha_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_pers personagem;
BEGIN
    SELECT * INTO v_pers FROM personagem WHERE id = NEW.personagem_id;
    IF v_pers.hp_atual <= 0 THEN
        RAISE EXCEPTION '% está sem vida e precisa descansar.', v_pers.nome;
    END IF;
    IF (SELECT segura FROM regiao WHERE id = v_pers.regiao_id) THEN
        RAISE EXCEPTION 'Não há combates em %.', (SELECT nome FROM regiao WHERE id = v_pers.regiao_id);
    END IF;
    NEW.regiao_id      := v_pers.regiao_id;
    NEW.periodo        := fn_periodo_atual();
    NEW.hp_monstro_max := fn_hp_monstro(NEW.monstro_id);
    NEW.hp_monstro     := NEW.hp_monstro_max;
    NEW.status         := 'em_andamento';
    NEW.turno          := 0;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_batalha_preparar BEFORE INSERT ON batalha
    FOR EACH ROW EXECUTE FUNCTION fn_trg_batalha_preparar();

-- [BEFORE UPDATE OF status] carimba o fim da batalha
CREATE OR REPLACE FUNCTION fn_trg_batalha_carimbo() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'em_andamento' THEN
        RAISE EXCEPTION 'A batalha % já foi encerrada.', OLD.id;
    END IF;
    NEW.finalizada_em := clock_timestamp();
    RETURN NEW;
END $$;
CREATE TRIGGER trg_batalha_carimbo BEFORE UPDATE OF status ON batalha
    FOR EACH ROW WHEN (NEW.status <> 'em_andamento')
    EXECUTE FUNCTION fn_trg_batalha_carimbo();

-- [AFTER UPDATE OF status] recompensas, drops, quests, derrota e passagem do tempo
CREATE OR REPLACE FUNCTION fn_trg_batalha_encerrar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_m    monstro;
    v_p    personagem;
    v_xp   int;
    v_ouro int;
    v_sor  int;
    d      record;
    v_qtd  int;
BEGIN
    SELECT * INTO v_m FROM monstro    WHERE id = NEW.monstro_id;
    SELECT * INTO v_p FROM personagem WHERE id = NEW.personagem_id;

    IF NEW.status = 'vitoria' THEN
        -- XP escala com a diferença de nível (mín. 25%, máx. 200%)
        v_xp   := round(v_m.xp_recompensa *
                        least(2.0, greatest(0.25, 1 + (v_m.nivel - v_p.nivel) * 0.15)));
        v_ouro := v_m.ouro_min + floor(random() * (v_m.ouro_max - v_m.ouro_min + 1))::int;
        UPDATE personagem SET xp = xp + v_xp, ouro = ouro + v_ouro WHERE id = v_p.id;
        PERFORM fn_log(NEW.id, NEW.turno, 'sistema',
            format('Vitória! +%s XP, +%s ouro.', v_xp, v_ouro));

        -- drops: SOR do personagem aumenta a chance em SOR/5 pontos percentuais
        v_sor := fn_atributo(v_p.id, 'SOR');
        FOR d IN SELECT md.*, i.nome FROM monstro_drop md JOIN item i ON i.id = md.item_id
                  WHERE md.monstro_id = v_m.id LOOP
            IF random() * 100 < d.chance + v_sor / 5.0 THEN
                v_qtd := d.qtd_min + floor(random() * (d.qtd_max - d.qtd_min + 1))::int;
                PERFORM fn_dar_item(v_p.id, d.item_id, v_qtd);
                PERFORM fn_log(NEW.id, NEW.turno, 'sistema', format('Saque: %s x%s', d.nome, v_qtd));
            END IF;
        END LOOP;

        -- quests de caça
        UPDATE personagem_quest pq SET progresso = progresso + 1
          FROM quest q
         WHERE q.id = pq.quest_id AND pq.personagem_id = v_p.id AND pq.status = 'ativa'
           AND q.tipo = 'cacar' AND q.monstro_alvo = v_m.id;

        IF v_m.chefe THEN
            PERFORM fn_cronica(v_p.id, 'chefe', format('%s derrotou %s.', v_p.nome, v_m.nome));
        END IF;

    ELSIF NEW.status = 'derrota' THEN
        -- desperta na cidade com 25% do HP e perde 20% do ouro
        UPDATE personagem
           SET hp_atual  = greatest(1, hp_max / 4),
               ouro      = ouro - ouro / 5,
               regiao_id = (SELECT id FROM regiao WHERE segura ORDER BY id LIMIT 1)
         WHERE id = v_p.id;
        PERFORM fn_log(NEW.id, NEW.turno, 'sistema',
            format('%s caiu diante de %s e acorda em Brumafria, mais pobre.', v_p.nome, v_m.nome));
        PERFORM fn_cronica(v_p.id, 'derrota', format('Derrotado por %s.', v_m.nome));
    END IF;

    PERFORM fn_avancar_tempo(1);
    PERFORM fn_verificar_conquistas(v_p.id);
    RETURN NULL;
END $$;
CREATE TRIGGER trg_batalha_encerrar AFTER UPDATE OF status ON batalha
    FOR EACH ROW WHEN (OLD.status = 'em_andamento' AND NEW.status <> 'em_andamento')
    EXECUTE FUNCTION fn_trg_batalha_encerrar();

-- =====================================================================
--  QUESTS
-- =====================================================================

-- [BEFORE INSERT] valida pré-requisitos e calcula o progresso inicial
CREATE OR REPLACE FUNCTION fn_trg_quest_aceitar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_q quest; v_p personagem;
BEGIN
    SELECT * INTO v_q FROM quest WHERE id = NEW.quest_id;
    SELECT * INTO v_p FROM personagem WHERE id = NEW.personagem_id;

    IF v_p.nivel < v_q.nivel_minimo THEN
        RAISE EXCEPTION 'A missão "%" exige nível %.', v_q.nome, v_q.nivel_minimo;
    END IF;
    IF v_q.quest_prerequisito IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM personagem_quest WHERE personagem_id = v_p.id
           AND quest_id = v_q.quest_prerequisito AND status = 'concluida') THEN
        RAISE EXCEPTION 'Conclua antes a missão "%".',
            (SELECT nome FROM quest WHERE id = v_q.quest_prerequisito);
    END IF;

    NEW.progresso := CASE v_q.tipo
        WHEN 'coletar'  THEN coalesce((SELECT quantidade FROM inventario
                                       WHERE personagem_id = v_p.id AND item_id = v_q.item_alvo), 0)
        WHEN 'explorar' THEN (v_p.regiao_id = v_q.regiao_alvo)::int
        ELSE 0 END;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_quest_a_aceitar BEFORE INSERT ON personagem_quest
    FOR EACH ROW EXECUTE FUNCTION fn_trg_quest_aceitar();

-- [BEFORE INSERT/UPDATE] marca como concluída ao atingir o objetivo
CREATE OR REPLACE FUNCTION fn_trg_quest_progresso() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'ativa'
       AND NEW.progresso >= (SELECT quantidade FROM quest WHERE id = NEW.quest_id) THEN
        NEW.status := 'concluida';
        NEW.concluida_em := clock_timestamp();
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_quest_b_progresso BEFORE INSERT OR UPDATE ON personagem_quest
    FOR EACH ROW EXECUTE FUNCTION fn_trg_quest_progresso();

-- [AFTER INSERT/UPDATE] entrega recompensas (pode encadear level-up)
CREATE OR REPLACE FUNCTION fn_trg_quest_recompensa() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_q quest;
BEGIN
    IF NEW.status = 'concluida' AND (TG_OP = 'INSERT' OR OLD.status = 'ativa') THEN
        SELECT * INTO v_q FROM quest WHERE id = NEW.quest_id;
        IF v_q.tipo = 'coletar' THEN          -- entrega os itens ao contratante
            PERFORM fn_remover_item(NEW.personagem_id, v_q.item_alvo, v_q.quantidade);
        END IF;
        UPDATE personagem SET xp = xp + v_q.recompensa_xp, ouro = ouro + v_q.recompensa_ouro
         WHERE id = NEW.personagem_id;
        IF v_q.recompensa_item IS NOT NULL THEN
            PERFORM fn_dar_item(NEW.personagem_id, v_q.recompensa_item, 1);
        END IF;
        PERFORM fn_cronica(NEW.personagem_id, 'missao',
            format('Missão concluída: "%s" (+%s XP, +%s ouro%s).', v_q.nome,
                   v_q.recompensa_xp, v_q.recompensa_ouro,
                   coalesce(', ' || (SELECT nome FROM item WHERE id = v_q.recompensa_item), '')));
        RAISE NOTICE '✔ Missão concluída: %', v_q.nome;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_quest_recompensa AFTER INSERT OR UPDATE ON personagem_quest
    FOR EACH ROW EXECUTE FUNCTION fn_trg_quest_recompensa();

-- =====================================================================
--  CRÔNICA → notificação assíncrona (LISTEN rpg_eventos)
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_trg_cronica_notificar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('rpg_eventos', json_build_object(
        'personagem', NEW.personagem_id, 'tipo', NEW.tipo, 'mensagem', NEW.mensagem)::text);
    RETURN NULL;
END $$;
CREATE TRIGGER trg_cronica_notificar AFTER INSERT ON cronica
    FOR EACH ROW EXECUTE FUNCTION fn_trg_cronica_notificar();
