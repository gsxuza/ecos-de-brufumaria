-- =====================================================================
--  08_demo.sql  —  roteiro de demonstração (rode no psql ou com rodar.mjs)
--  Cada bloco começa com "-- @"; o runner exibe o resultado de cada um.
-- =====================================================================
SET search_path TO rpg, public;
SELECT setseed(0.42);   -- rolagens reprodutíveis na apresentação

-- @ 1. Os dados: notação de RPG e distribuição de 2d6 (curva em sino)
SELECT fn_rolar_expr('d20') AS d20, fn_rolar_expr('3d6+2') AS "3d6+2",
       fn_rolar_expr('1d32') AS d32, fn_rolar_expr('2d64-10') AS "2d64-10";
SELECT valor AS "2d6", count(*) AS vezes, repeat('█', (count(*) / 60)::int) AS histograma
  FROM (SELECT fn_rolar(2, 6) AS valor FROM generate_series(1, 6000)) t
 GROUP BY valor ORDER BY valor;

-- @ 2. Criação de personagens (trigger gera atributos, HP/MP e kit inicial)
CALL sp_criar_personagem('aria',  'Guerreiro');
CALL sp_criar_personagem('bento', 'Mago');
CALL sp_criar_personagem('cael',  'Ladino');
CALL sp_criar_personagem('dora',  'Clérigo');
SELECT nome, classe, nivel, hp, mp, ataque, defesa, vitalidade, magia, agilidade, sorte, ouro, regiao FROM vw_ficha;

-- @ 3. Regras protegidas pelo banco
DO $$
DECLARE v int;   -- recebe parâmetros INOUT
BEGIN
    BEGIN CALL sp_criar_personagem('Grr', 'Fera', v);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'BLOQUEADO: %', SQLERRM; END;
    BEGIN CALL sp_equipar(fn_pid('Aria'), 'Poção Menor');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'BLOQUEADO: %', SQLERRM; END;
    BEGIN CALL sp_viajar(fn_pid('Aria'), 'Pântano de Vidro');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'BLOQUEADO: %', SQLERRM; END;
    BEGIN CALL sp_viajar(fn_pid('Aria'), 'Santuário do Sino Partido');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'BLOQUEADO: %', SQLERRM; END;
    BEGIN CALL sp_iniciar_batalha(fn_pid('Aria'), NULL, v);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'BLOQUEADO: %', SQLERRM; END;
END $$;

-- @ 4. Loja, missões e viagem
CALL sp_comprar(fn_pid('Aria'), 'Poção Menor', 2);
CALL sp_comprar(fn_pid('Cael'), 'Amuleto do Trevo');
CALL sp_equipar(fn_pid('Cael'), 'Amuleto do Trevo');
CALL sp_aceitar_quest(fn_pid('Aria'), 'Ratos no Celeiro');
SELECT * FROM vw_quadro_de_missoes WHERE personagem = 'Aria';
CALL sp_viajar(fn_pid('Aria'),  'Bosque dos Sussurros');
CALL sp_viajar(fn_pid('Bento'), 'Bosque dos Sussurros');
CALL sp_viajar(fn_pid('Cael'),  'Bosque dos Sussurros');
CALL sp_viajar(fn_pid('Dora'),  'Bosque dos Sussurros');

-- @ 5. Batalha manual, turno a turno
CALL sp_iniciar_batalha(fn_pid('Aria'), 'Rato-de-Musgo');
DO $$
DECLARE b int := fn_batalha_ativa(fn_pid('Aria'));
BEGIN
    CALL sp_turno(b, 'habilidade', 'Golpe Brutal');
    WHILE fn_batalha_ativa(fn_pid('Aria')) IS NOT NULL LOOP
        CALL sp_turno(b, 'atacar');
    END LOOP;
END $$;
SELECT turno, ator, mensagem FROM vw_combate WHERE batalha_id = (SELECT max(id) FROM batalha);

-- @ 6. Turnos pré-programados: 8 batalhas automáticas por herói
DO $$
DECLARE h text; r status_batalha;
BEGIN
    FOREACH h IN ARRAY ARRAY['Aria', 'Bento', 'Cael', 'Dora'] LOOP
        FOR i IN 1..8 LOOP
            IF (SELECT r.segura FROM personagem p JOIN regiao r ON r.id = p.regiao_id WHERE p.id = fn_pid(h)) THEN
                CALL sp_descansar(fn_pid(h));                 -- foi derrotado: volta ao bosque
                CALL sp_viajar(fn_pid(h), 'Bosque dos Sussurros');
            END IF;
            CALL sp_batalha_automatica(fn_pid(h), NULL, 40, r);
        END LOOP;
    END LOOP;
END $$;
SELECT * FROM vw_ranking;
SELECT * FROM vw_quests;

-- @ 7. Dia e noite: o Cervo Pálido só aparece à noite
UPDATE mundo SET hora = 12;      -- mestre ajusta o relógio para meio-dia
SELECT * FROM vw_mundo;
DO $$
DECLARE r status_batalha;
BEGIN
    IF (SELECT regiao FROM vw_ficha WHERE nome = 'Cael') <> 'Bosque dos Sussurros' THEN
        CALL sp_viajar(fn_pid('Cael'), 'Bosque dos Sussurros');
    END IF;
    BEGIN CALL sp_batalha_automatica(fn_pid('Cael'), 'Cervo Pálido', 40, r);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'BLOQUEADO: %', SQLERRM; END;

    WHILE fn_periodo_atual() = 'dia' LOOP CALL sp_esperar(1); END LOOP;

    CALL sp_batalha_automatica(fn_pid('Cael'), 'Cervo Pálido', 40, r);   -- agora ele aparece
END $$;
SELECT turno, ator, mensagem FROM vw_combate WHERE batalha_id = (SELECT max(id) FROM batalha);
SELECT nome, nivel, comportamento, fraqueza, hp, onde_encontrar, saque_conhecido FROM vw_bestiario;

-- @ 8. Modo mestre: experiência concedida dispara level-up em cascata (trigger)
UPDATE personagem SET xp = fn_xp_para_nivel(8) WHERE nome = 'Dora';
SELECT nome, nivel, hp, mp, ataque, defesa, magia, titulo FROM vw_ficha WHERE nome = 'Dora';

-- @ 9. O MISTÉRIO: reunir os três fragmentos revela o Santuário
SELECT fn_dar_item(fn_pid('Dora'), (SELECT id FROM item WHERE nome = 'Fragmento do Badalo'));
SELECT fn_dar_item(fn_pid('Dora'), (SELECT id FROM item WHERE nome = 'Fragmento da Boca'));
SELECT * FROM vw_quests WHERE personagem = 'Dora';
SELECT fn_dar_item(fn_pid('Dora'), (SELECT id FROM item WHERE nome = 'Fragmento da Alça'));
SELECT * FROM vw_quests WHERE personagem = 'Dora';

-- @ 10. Chefe final: O Sineiro (fraco contra sagrado — especialidade do Clérigo)
SELECT fn_dar_item(fn_pid('Dora'), (SELECT id FROM item WHERE nome = 'Poção Maior'), 4);
UPDATE personagem SET ouro = ouro + 150 WHERE nome = 'Dora';   -- recompensa do mestre
CALL sp_viajar(fn_pid('Dora'), 'Vila de Brumafria');
CALL sp_comprar(fn_pid('Dora'), 'Cota de Malha');
CALL sp_equipar(fn_pid('Dora'), 'Cota de Malha');
-- até 3 tentativas: a derrota devolve Dora à vila (trigger), ela descansa e volta
DO $$
DECLARE r status_batalha; tentativa int := 0;
BEGIN
    LOOP
        tentativa := tentativa + 1;
        RAISE NOTICE '--- Tentativa % ---', tentativa;
        CALL sp_descansar(fn_pid('Dora'));
        CALL sp_viajar(fn_pid('Dora'), 'Santuário do Sino Partido');
        CALL sp_batalha_automatica(fn_pid('Dora'), 'O Sineiro', 40, r);
        EXIT WHEN r = 'vitoria' OR tentativa = 3;
    END LOOP;
END $$;
SELECT turno, ator, mensagem FROM vw_combate WHERE batalha_id = (SELECT max(id) FROM batalha);
SELECT * FROM vw_quests WHERE personagem = 'Dora';
SELECT item, tipo, raridade, equipado, bonus FROM vw_inventario WHERE personagem = 'Dora';

-- @ 11. Crônica, conquistas e títulos
SELECT personagem, tipo, mensagem FROM vw_cronica WHERE personagem = 'Dora';
SELECT p.nome, c.nome AS conquista, coalesce(p.titulo, '') AS titulo_atual
  FROM personagem_conquista pc JOIN personagem p ON p.id = pc.personagem_id JOIN conquista c ON c.id = pc.conquista_id
 ORDER BY p.nome, pc.obtida_em;
SELECT * FROM vw_ranking;

-- @ 12. Auditoria automática (trigger parametrizado)
SELECT campo, count(*) AS alteracoes FROM auditoria GROUP BY campo ORDER BY campo;
SELECT registro_id AS personagem, campo, valor_antigo, valor_novo FROM auditoria
 WHERE campo IN ('nivel', 'titulo') ORDER BY id;

-- @ 13. Segurança: o jogador só age por procedures
SET ROLE rpg_jogador;
DO $$ BEGIN
    BEGIN UPDATE rpg.personagem SET ouro = 999999 WHERE nome = 'Cael';
    EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO (trapaça): %', SQLERRM; END;
    BEGIN PERFORM * FROM rpg.segredo;
    EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'BLOQUEADO (spoiler): %', SQLERRM; END;
END $$;
CALL rpg.sp_viajar(rpg.fn_pid('Cael'), 'Vila de Brumafria');   -- permitido via procedure
RESET ROLE;
SELECT nome, ouro, regiao FROM vw_ficha WHERE nome = 'Cael';

