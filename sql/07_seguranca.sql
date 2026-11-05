-- =====================================================================
--  07_seguranca.sql  —  papéis e privilégios
--  O jogador NÃO escreve em tabelas: só chama procedures (SECURITY DEFINER)
--  e lê views. Assim é impossível "trapacear" com UPDATE direto.
-- =====================================================================
SET search_path TO rpg, public;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rpg_jogador') THEN
        CREATE ROLE rpg_jogador NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rpg_mestre') THEN
        CREATE ROLE rpg_mestre NOLOGIN;
    END IF;
END $$;

REVOKE ALL ON SCHEMA rpg FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA rpg FROM PUBLIC;
GRANT USAGE ON SCHEMA rpg TO rpg_jogador, rpg_mestre;

-- Mestre do jogo: controle total
GRANT ALL ON ALL TABLES    IN SCHEMA rpg TO rpg_mestre;
GRANT ALL ON ALL SEQUENCES IN SCHEMA rpg TO rpg_mestre;

-- Jogador: leitura das tabelas "públicas" (necessárias às views e funções de cálculo).
-- segredo*, monstro_drop, regiao, quest, auditoria ficam ocultas: o mistério continua mistério.
GRANT SELECT ON atributo, classe, classe_atributo, habilidade, item, item_bonus,
                personagem, personagem_atributo, inventario, monstro, mundo, batalha
   TO rpg_jogador;

-- Jogador lê todas as views
DO $$
DECLARE v record;
BEGIN
    FOR v IN SELECT viewname FROM pg_views WHERE schemaname = 'rpg' LOOP
        EXECUTE format('GRANT SELECT ON rpg.%I TO rpg_jogador', v.viewname);
    END LOOP;
END $$;

-- Toda procedure roda com os privilégios do dono (SECURITY DEFINER) e search_path fixo
-- (evita sequestro de search_path). Só elas podem alterar o estado do jogo.
DO $$
DECLARE p record;
BEGIN
    FOR p IN SELECT oid::regprocedure AS assinatura
               FROM pg_proc
              WHERE pronamespace = 'rpg'::regnamespace AND prokind = 'p'
    LOOP
        EXECUTE format('ALTER PROCEDURE %s SECURITY DEFINER SET search_path = rpg, public', p.assinatura);
        EXECUTE format('REVOKE ALL ON PROCEDURE %s FROM PUBLIC', p.assinatura);
        EXECUTE format('GRANT EXECUTE ON PROCEDURE %s TO rpg_jogador, rpg_mestre', p.assinatura);
    END LOOP;
END $$;
