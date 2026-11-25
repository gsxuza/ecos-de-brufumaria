// Monta a demo estática (GitHub Pages) em _site/: a mesma interface de
// public/index.html, com o banco rodando no navegador (web/motor.mjs + jogo.mjs).
//   node scripts/montar-site.mjs
import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..');
const saida = join(raiz, '_site');
const ler = (...p) => readFileSync(join(raiz, ...p), 'utf8');

rmSync(saida, { recursive: true, force: true });
mkdirSync(join(saida, 'sql'), { recursive: true });

// SQL do jogo (sem a demonstração de terminal) + índice com a versão
const arquivos = readdirSync(join(raiz, 'sql')).filter((f) => f.endsWith('.sql') && !f.includes('demo')).sort();
const hash = createHash('sha256');
for (const f of arquivos) {
  copyFileSync(join(raiz, 'sql', f), join(saida, 'sql', f));
  hash.update(ler('sql', f));
}
const versao = hash.digest('hex').slice(0, 16);
writeFileSync(join(saida, 'sql', 'indice.json'), JSON.stringify({ arquivos, versao }, null, 2));

// Motor: mesma versão do PGlite do package.json
const versaoPglite = JSON.parse(ler('package.json')).dependencies['@electric-sql/pglite'];
if (!/^\d+\.\d+\.\d+$/.test(versaoPglite)) throw new Error(`Fixe a versão exata do PGlite no package.json (está "${versaoPglite}").`);
writeFileSync(join(saida, 'motor.mjs'), ler('web', 'motor.mjs').replace('__VERSAO_PGLITE__', versaoPglite));
copyFileSync(join(raiz, 'jogo.mjs'), join(saida, 'jogo.mjs'));

// Página: injeta o carregador do motor antes do script principal
const carregador = `<div id="motor-aviso" class="motor-aviso" role="status">Preparando o PostgreSQL no seu navegador…</div>
<style>
  .motor-aviso { position: fixed; left: 50%; bottom: 16px; transform: translateX(-50%); z-index: 50;
    max-width: calc(100% - 32px); padding: 8px 14px; text-align: center; font-size: 13px;
    background: var(--painel-2); color: var(--texto-2); border: 1px solid var(--borda); border-radius: var(--raio); }
</style>
<script>
  window.motorPronto = import('./motor.mjs').then((m) => m.iniciar()).then((motor) => {
    const el = document.getElementById('motor-aviso');
    if (el) {
      el.textContent = 'Demo: o PostgreSQL roda no seu navegador (PGlite). Seus heróis ficam salvos aqui.';
      setTimeout(() => el.remove(), 6000);
    }
    return motor;
  }, (e) => {
    const el = document.getElementById('motor-aviso');
    if (el) el.textContent = 'Não foi possível iniciar o banco no navegador: ' + e.message;
    throw e;
  });
</script>
`;
const html = ler('public', 'index.html');
const marca = '\n<script>\n';
if (html.split(marca).length !== 2) throw new Error('Não achei o script principal em public/index.html.');
writeFileSync(join(saida, 'index.html'), html.replace(marca, '\n' + carregador + '<script>\n'));
writeFileSync(join(saida, '.nojekyll'), '');

console.log(`Site montado em _site/ (${arquivos.length} arquivos SQL, versão ${versao}, PGlite ${versaoPglite}).`);
