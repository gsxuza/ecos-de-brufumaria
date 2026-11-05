// Interface gráfica do RPG.
//   node servidor.mjs   ->  abra http://localhost:3000
//
// O servidor NÃO contém regra de jogo: ele só traduz cliques em CALL de procedures
// (executadas com o papel rpg_jogador, sem acesso de escrita às tabelas) e lê views.
import { PGlite } from '@electric-sql/pglite';
import { createServer } from 'node:http';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = dirname(fileURLToPath(import.meta.url));
const PORTA = Number(process.env.PORT) || 3000;
const db = new PGlite(join(raiz, 'dados'));

// ---------------------------------------------------------------- banco
async function instalar() {
  const arquivos = readdirSync(join(raiz, 'sql'))
    .filter((f) => f.endsWith('.sql') && !f.includes('demo')).sort();
  for (const arq of arquivos) {
    await db.exec(readFileSync(join(raiz, 'sql', arq), 'utf8').replace(/^﻿/, ''));
  }
  await db.exec('SET search_path TO rpg, public;');
  console.log('Banco instalado.');
}

const temSchema = await db.query("SELECT to_regnamespace('rpg') IS NOT NULL AS ok");
if (!temSchema.rows[0].ok) await instalar();
await db.exec('SET search_path TO rpg, public;');

// fila: uma operação por vez (as ações trocam de papel com SET ROLE)
let fila = Promise.resolve();
const emFila = (fn) => (fila = fila.then(fn, fn));

const ler = async (sql, params = []) => (await db.query(sql, params)).rows;
const um = async (sql, params = []) => (await ler(sql, params))[0] ?? null;

// ---------------------------------------------------------------- ações (procedures)
const ACOES = {
  criar:      (a) => ['CALL sp_criar_personagem($1, $2, NULL)', [a.nome, a.classe]],
  viajar:     (a) => ['CALL sp_viajar($1, $2)', [a.p, a.regiao]],
  explorar:   (a) => ['CALL sp_iniciar_batalha($1, $2, NULL)', [a.p, a.monstro || null]],
  turno:      (a) => ['CALL sp_turno(fn_batalha_ativa($1), $2::rpg.acao_batalha, $3)', [a.p, a.acao, a.ref || null]],
  automatico: (a) => ['CALL sp_batalha_automatica($1, NULL, 40, NULL)', [a.p]],
  descansar:  (a) => ['CALL sp_descansar($1)', [a.p]],
  esperar:    (a) => ['CALL sp_esperar($1)', [Number(a.horas) || 1]],
  comprar:    (a) => ['CALL sp_comprar($1, $2, $3)', [a.p, a.item, Number(a.qtd) || 1]],
  vender:     (a) => ['CALL sp_vender($1, $2, $3)', [a.p, a.item, Number(a.qtd) || 1]],
  equipar:    (a) => ['CALL sp_equipar($1, $2, $3)', [a.p, a.item, a.equipar !== false]],
  usar:       (a) => ['CALL sp_usar_item($1, $2)', [a.p, a.item]],
  aceitar:    (a) => ['CALL sp_aceitar_quest($1, $2)', [a.p, a.quest]],
};

async function executarAcao(corpo) {
  const montar = ACOES[corpo.acao_jogo];
  if (!montar) throw new Error('Ação desconhecida.');
  const [sql, params] = montar(corpo);
  const mensagens = [];
  await db.exec('SET ROLE rpg_jogador');
  try {
    const r = await db.query(sql, params, {
      onNotice: (n) => { if (n.severity === 'NOTICE' && !n.message.startsWith('#')) mensagens.push(n.message); },
    });
    return { ok: true, mensagens, retorno: r.rows[0] ?? null };
  } catch (e) {
    return { ok: false, mensagens, erro: e.message };
  } finally {
    await db.exec('RESET ROLE');
  }
}

// ---------------------------------------------------------------- leituras (views)
async function lobby() {
  return {
    personagens: await ler('SELECT id, nome, titulo, classe, nivel, regiao FROM vw_ficha ORDER BY nivel DESC, nome'),
    classes: await ler(`
      SELECT c.nome, c.descricao, 'd' || c.dado_dano AS dado,
             (SELECT json_object_agg(a.sigla, ca.base ORDER BY a.id) FROM classe_atributo ca
                JOIN atributo a ON a.id = ca.atributo_id WHERE ca.classe_id = c.id) AS atributos
        FROM classe c WHERE c.jogavel ORDER BY c.id`),
    ranking: await ler('SELECT posicao, nome, titulo, classe, nivel, vitorias, derrotas, chefes FROM vw_ranking ORDER BY posicao LIMIT 10'),
  };
}

async function estado(p) {
  const ficha = await um(`
    SELECT f.*, pe.hp_atual, pe.hp_max, pe.mp_atual, pe.mp_max, pe.regiao_id, pe.classe_id,
           fn_xp_para_nivel(pe.nivel) AS xp_nivel_atual
      FROM vw_ficha f JOIN personagem pe ON pe.id = f.id WHERE f.id = $1`, [p]);
  if (!ficha) return null;

  const batalhaAtiva = await um(`
    SELECT b.id, b.turno, b.hp_monstro, b.hp_monstro_max, b.status, b.periodo,
           m.nome AS monstro, m.nivel, m.chefe, m.elemento, m.descricao, c.nome AS classe_monstro
      FROM batalha b JOIN monstro m ON m.id = b.monstro_id JOIN classe c ON c.id = m.classe_id
     WHERE b.personagem_id = $1 ORDER BY b.id DESC LIMIT 1`, [p]);

  return {
    ficha,
    mundo: await um('SELECT * FROM vw_mundo'),
    regiao: await um('SELECT nome, descricao, segura FROM regiao WHERE id = $1', [ficha.regiao_id]),
    destinos: await ler(`
      SELECT nome, nivel_minimo, secreta, fn_pode_acessar_regiao($1, id) AS acessivel,
             id = (SELECT regiao_id FROM personagem WHERE id = $1) AS atual
        FROM regiao WHERE NOT secreta OR fn_pode_acessar_regiao($1, id) ORDER BY nivel_minimo, id`, [p]),
    // monstros que o herói já enfrentou nesta região ou que são alvo de missão ativa
    rastros: await ler(`
      SELECT DISTINCT m.nome, m.chefe, mr.periodo,
             mr.periodo IN (fn_periodo_atual(), 'qualquer') AS visivel
        FROM monstro m JOIN monstro_regiao mr ON mr.monstro_id = m.id
       WHERE mr.regiao_id = (SELECT regiao_id FROM personagem WHERE id = $1)
         AND (EXISTS (SELECT 1 FROM batalha b WHERE b.personagem_id = $1 AND b.monstro_id = m.id)
              OR EXISTS (SELECT 1 FROM personagem_quest pq JOIN quest q ON q.id = pq.quest_id
                          WHERE pq.personagem_id = $1 AND pq.status = 'ativa' AND q.monstro_alvo = m.id))
       ORDER BY m.chefe, m.nome`, [p]),
    habilidades: await ler(`
      SELECT h.nome, h.custo_mp, h.qtd_dados || 'd' || h.lados_dado AS dado, h.elemento, h.cura,
             h.nivel_minimo, h.nivel_minimo <= pe.nivel AS liberada, h.descricao
        FROM habilidade h JOIN personagem pe ON pe.classe_id = h.classe_id
       WHERE pe.id = $1 ORDER BY h.nivel_minimo, h.custo_mp`, [p]),
    inventario: await ler(`
      SELECT it.nome, it.tipo, it.raridade, i.quantidade, i.equipado, it.cura_hp, it.cura_mp, it.descricao,
             fn_valor_venda(it.id) AS valor_venda, v.bonus
        FROM inventario i JOIN item it ON it.id = i.item_id
        JOIN vw_inventario v ON v.personagem = $2 AND v.item = it.nome
       WHERE i.personagem_id = $1
       ORDER BY i.equipado DESC, it.tipo, it.nome`, [p, ficha.nome]),
    loja: ficha.regiao && (await um('SELECT segura FROM regiao WHERE id = $1', [ficha.regiao_id])).segura
      ? await ler(`
          SELECT it.nome, it.tipo, it.raridade, it.preco, it.nivel_minimo, it.descricao, it.cura_hp, it.cura_mp,
                 (SELECT string_agg(a.sigla || CASE WHEN ib.valor >= 0 THEN '+' ELSE '' END || ib.valor, ' ' ORDER BY a.id)
                    FROM item_bonus ib JOIN atributo a ON a.id = ib.atributo_id WHERE ib.item_id = it.id) AS bonus,
                 (SELECT nome FROM classe WHERE id = it.classe_requerida) AS classe
            FROM item it WHERE it.preco > 0 ORDER BY it.tipo, it.preco`)
      : [],
    missoes: await ler('SELECT * FROM vw_quests WHERE personagem = $1', [ficha.nome]),
    quadro: await ler('SELECT missao, descricao, nivel_minimo, recompensa_xp, recompensa_ouro FROM vw_quadro_de_missoes WHERE personagem = $1', [ficha.nome]),
    conquistas: await ler(`
      SELECT c.nome, c.descricao, pc.obtida_em FROM personagem_conquista pc
        JOIN conquista c ON c.id = pc.conquista_id WHERE pc.personagem_id = $1 ORDER BY pc.obtida_em`, [p]),
    cronica: await ler('SELECT tipo, mensagem FROM cronica WHERE personagem_id = $1 ORDER BY id DESC LIMIT 25', [p]),
    batalha: batalhaAtiva,
    log: batalhaAtiva
      ? await ler('SELECT turno, ator, mensagem, rolagem_d20, critico FROM batalha_log WHERE batalha_id = $1 ORDER BY id', [batalhaAtiva.id])
      : [],
  };
}

// ---------------------------------------------------------------- http
function responder(res, status, dados) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(dados));
}

async function corpoJson(req) {
  let txt = '';
  for await (const parte of req) txt += parte;
  return txt ? JSON.parse(txt) : {};
}

const servidor = createServer((req, res) => emFila(async () => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(readFileSync(join(raiz, 'public', 'index.html')));
    }
    if (req.method === 'GET' && url.pathname === '/api/lobby') return responder(res, 200, await lobby());
    if (req.method === 'GET' && url.pathname === '/api/estado') {
      const e = await estado(Number(url.searchParams.get('p')));
      return e ? responder(res, 200, e) : responder(res, 404, { erro: 'Personagem não encontrado.' });
    }
    if (req.method === 'POST' && url.pathname === '/api/acao') {
      return responder(res, 200, await executarAcao(await corpoJson(req)));
    }
    if (req.method === 'POST' && url.pathname === '/api/reiniciar') {
      await instalar();
      return responder(res, 200, { ok: true });
    }
    responder(res, 404, { erro: 'Não encontrado.' });
  } catch (e) {
    console.error(e);
    responder(res, 500, { erro: e.message });
  }
}));

servidor.listen(PORTA, '127.0.0.1', () => {
  console.log(`Ecos de Brumafria rodando em http://localhost:${PORTA}  (Ctrl+C para sair)`);
});
