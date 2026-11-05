-- =====================================================================
--  05_views.sql  —  VIEWS: a "interface" de leitura do jogo
-- =====================================================================
SET search_path TO rpg, public;

-- Ficha completa (atributos totais = base + equipamento)
CREATE OR REPLACE VIEW vw_ficha AS
SELECT p.id, p.nome, coalesce(p.titulo, '—') AS titulo, c.nome AS classe, p.nivel,
       p.xp, fn_xp_para_nivel(p.nivel + 1) AS xp_proximo_nivel,
       p.hp_atual || '/' || p.hp_max AS hp,
       p.mp_atual || '/' || p.mp_max AS mp,
       fn_atributo(p.id, 'ATQ') AS ataque,
       fn_atributo(p.id, 'DEF') AS defesa,
       fn_atributo(p.id, 'VIT') AS vitalidade,
       fn_atributo(p.id, 'MAG') AS magia,
       fn_atributo(p.id, 'AGI') AS agilidade,
       fn_atributo(p.id, 'SOR') AS sorte,
       p.ouro, r.nome AS regiao
  FROM personagem p
  JOIN classe c ON c.id = p.classe_id
  LEFT JOIN regiao r ON r.id = p.regiao_id;

CREATE OR REPLACE VIEW vw_inventario AS
SELECT p.nome AS personagem, it.nome AS item, it.tipo, it.raridade, i.quantidade,
       CASE WHEN i.equipado THEN 'sim' ELSE '' END AS equipado,
       (SELECT string_agg(a.sigla || CASE WHEN ib.valor >= 0 THEN '+' ELSE '' END || ib.valor, ' ' ORDER BY a.id)
          FROM item_bonus ib JOIN atributo a ON a.id = ib.atributo_id WHERE ib.item_id = it.id) AS bonus,
       it.descricao
  FROM inventario i
  JOIN personagem p ON p.id = i.personagem_id
  JOIN item it ON it.id = i.item_id
 ORDER BY p.nome, i.equipado DESC, it.tipo, it.nome;

-- Bestiário: atributos dos monstros são DERIVADOS da classe + nível
CREATE OR REPLACE VIEW vw_bestiario AS
SELECT m.nome, c.nome AS classe, m.nivel, m.comportamento, m.elemento, m.fraqueza,
       CASE WHEN m.chefe THEN 'CHEFE' ELSE '' END AS chefe,
       fn_hp_monstro(m.id) AS hp,
       fn_atributo_monstro(m.id, 'ATQ') AS atq, fn_atributo_monstro(m.id, 'DEF') AS def,
       fn_atributo_monstro(m.id, 'MAG') AS mag, fn_atributo_monstro(m.id, 'AGI') AS agi,
       'd' || c.dado_dano AS dado,
       m.xp_recompensa AS xp,
       (SELECT string_agg(r.nome || CASE WHEN mr.periodo <> 'qualquer' THEN ' (' || mr.periodo || ')' ELSE '' END, ', ')
          FROM monstro_regiao mr JOIN regiao r ON r.id = mr.regiao_id
         WHERE mr.monstro_id = m.id AND NOT r.secreta) AS onde_encontrar,
       (SELECT string_agg(it.nome || ' ' || md.chance || '%', ', ')
          FROM monstro_drop md JOIN item it ON it.id = md.item_id
         WHERE md.monstro_id = m.id AND it.tipo <> 'fragmento') AS saque_conhecido
  FROM monstro m JOIN classe c ON c.id = m.classe_id
 ORDER BY m.nivel, m.nome;

-- Ranking com funções de janela
CREATE OR REPLACE VIEW vw_ranking AS
WITH estat AS (
    SELECT p.id,
           count(b.id) FILTER (WHERE b.status = 'vitoria') AS vitorias,
           count(b.id) FILTER (WHERE b.status = 'derrota') AS derrotas,
           count(b.id) FILTER (WHERE b.status = 'vitoria' AND m.chefe) AS chefes
      FROM personagem p
      LEFT JOIN batalha b ON b.personagem_id = p.id
      LEFT JOIN monstro m ON m.id = b.monstro_id
     GROUP BY p.id
)
SELECT rank() OVER (ORDER BY p.nivel DESC, p.xp DESC) AS posicao,
       p.nome, coalesce(p.titulo, '') AS titulo, c.nome AS classe, p.nivel, p.xp,
       e.vitorias, e.derrotas, e.chefes,
       round(100.0 * e.vitorias / nullif(e.vitorias + e.derrotas, 0), 1) AS taxa_vitoria,
       (SELECT count(*) FROM personagem_conquista pc WHERE pc.personagem_id = p.id) AS conquistas,
       rank() OVER (PARTITION BY p.classe_id ORDER BY p.nivel DESC, p.xp DESC) AS posicao_na_classe
  FROM personagem p JOIN classe c ON c.id = p.classe_id JOIN estat e ON e.id = p.id;

CREATE OR REPLACE VIEW vw_combate AS
SELECT l.batalha_id, l.turno, l.ator, l.mensagem
  FROM batalha_log l ORDER BY l.batalha_id, l.id;

CREATE OR REPLACE VIEW vw_quests AS
SELECT p.nome AS personagem, q.nome AS missao, q.tipo,
       pq.progresso || '/' || q.quantidade AS progresso, pq.status,
       q.recompensa_xp AS xp, q.recompensa_ouro AS ouro,
       CASE WHEN q.secreta THEN 'secreta' ELSE '' END AS observacao
  FROM personagem_quest pq
  JOIN personagem p ON p.id = pq.personagem_id
  JOIN quest q ON q.id = pq.quest_id
 ORDER BY p.nome, pq.status, q.id;

-- Missões que um personagem PODE aceitar agora
CREATE OR REPLACE VIEW vw_quadro_de_missoes AS
SELECT p.nome AS personagem, q.nome AS missao, q.descricao, q.nivel_minimo, q.recompensa_xp, q.recompensa_ouro
  FROM personagem p CROSS JOIN quest q
 WHERE NOT q.secreta
   AND q.nivel_minimo <= p.nivel
   AND NOT EXISTS (SELECT 1 FROM personagem_quest pq WHERE pq.personagem_id = p.id AND pq.quest_id = q.id)
   AND (q.quest_prerequisito IS NULL OR EXISTS (
        SELECT 1 FROM personagem_quest pq WHERE pq.personagem_id = p.id
           AND pq.quest_id = q.quest_prerequisito AND pq.status = 'concluida'));

CREATE OR REPLACE VIEW vw_cronica AS
SELECT p.nome AS personagem, c.tipo, c.mensagem, c.criado_em
  FROM cronica c LEFT JOIN personagem p ON p.id = c.personagem_id
 ORDER BY c.id;

CREATE OR REPLACE VIEW vw_mundo AS
SELECT dia, lpad(hora::text, 2, '0') || 'h' AS hora, fn_periodo_atual() AS periodo FROM mundo;
