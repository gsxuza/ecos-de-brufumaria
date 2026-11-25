// Demo no navegador: o mesmo PostgreSQL (PGlite, compilado para WebAssembly)
// roda dentro da página, com as mesmas procedures e views do servidor.
// Os dados ficam salvos no IndexedDB deste navegador.
import { criarJogo } from './jogo.mjs';

const PGLITE = 'https://cdn.jsdelivr.net/npm/@electric-sql/pglite@__VERSAO_PGLITE__/dist/index.js';
const BANCO = 'idb://ecos-de-brumafria';
const CHAVE_VERSAO = 'ecos-versao-sql';

const texto = async (caminho) => {
  const r = await fetch(caminho);
  if (!r.ok) throw new Error(`não consegui baixar ${caminho} (${r.status})`);
  return r.text();
};

export async function iniciar() {
  const { PGlite } = await import(PGLITE);
  const indice = JSON.parse(await texto('sql/indice.json'));
  const db = new PGlite(BANCO);
  await db.waitReady;

  const jogo = criarJogo(db, () => Promise.all(indice.arquivos.map((f) => texto('sql/' + f))));
  await jogo.preparar();

  // SQL do jogo mudou desde a última visita: recria o mundo.
  let versaoSalva = null;
  try { versaoSalva = localStorage.getItem(CHAVE_VERSAO); } catch {}
  if (versaoSalva !== indice.versao) {
    await jogo.instalar();
    try { localStorage.setItem(CHAVE_VERSAO, indice.versao); localStorage.removeItem('heroi'); } catch {}
  }

  return async (caminho, corpo) => {
    const [, dados] = await jogo.rota(corpo ? 'POST' : 'GET', caminho, corpo);
    return dados;
  };
}
