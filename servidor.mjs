// Interface gráfica do RPG.
//   node servidor.mjs   ->  abra http://localhost:3000
//
// O servidor NÃO contém regra de jogo: ele só traduz cliques em CALL de procedures
// (executadas com o papel rpg_jogador, sem acesso de escrita às tabelas) e lê views.
// A camada de acesso fica em jogo.mjs, a mesma usada pela demo no navegador.
import { PGlite } from '@electric-sql/pglite';
import { createServer } from 'node:http';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { criarJogo } from './jogo.mjs';

const raiz = dirname(fileURLToPath(import.meta.url));
const PORTA = Number(process.env.PORT) || 3000;
const db = new PGlite(join(raiz, 'dados'));

const scripts = () =>
  readdirSync(join(raiz, 'sql'))
    .filter((f) => f.endsWith('.sql') && !f.includes('demo'))
    .sort()
    .map((f) => readFileSync(join(raiz, 'sql', f), 'utf8'));

const jogo = criarJogo(db, scripts);
await jogo.preparar();

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

const servidor = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(readFileSync(join(raiz, 'public', 'index.html')));
    }
    const corpo = req.method === 'POST' ? await corpoJson(req) : undefined;
    const [status, dados] = await jogo.rota(req.method, req.url, corpo);
    responder(res, status, dados);
  } catch (e) {
    console.error(e);
    responder(res, 500, { erro: e.message });
  }
});

servidor.listen(PORTA, '127.0.0.1', () => {
  console.log(`Ecos de Brumafria rodando em http://localhost:${PORTA}  (Ctrl+C para sair)`);
});
