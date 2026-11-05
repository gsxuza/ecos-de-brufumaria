// Executa o projeto sem instalar PostgreSQL, usando PGlite (PostgreSQL real compilado para WebAssembly).
//   npm install
//   node rodar.mjs            -> recria o banco em ./dados e roda a demonstração (08_demo.sql)
//   node rodar.mjs --console  -> abre um console SQL interativo no banco salvo em ./dados
//   node rodar.mjs --sem-demo -> só instala schema + dados
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync, rmSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = dirname(fileURLToPath(import.meta.url));
const pastaSql = join(raiz, 'sql');
const pastaDados = join(raiz, 'dados');
const args = process.argv.slice(2);

const onNotice = (n) => {
  if (['NOTICE', 'WARNING', 'INFO'].includes(n.severity) && !n.message.startsWith('#')) console.log(`  » ${n.message}`);
};

function mostrar(resultados) {
  for (const r of resultados) {
    if (r.fields?.length && r.rows?.length) console.table(r.rows);
  }
}

async function console_() {
  const db = new PGlite(pastaDados);
  await db.exec('SET search_path TO rpg, public;');
  console.log('Console do RPG. Termine comandos com ";"  —  digite \\q para sair.');
  const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: 'rpg> ' });
  let buffer = '';
  rl.prompt();
  for await (const linha of rl) {
    if (linha.trim() === '\\q') break;
    buffer += linha + '\n';
    if (buffer.trim().endsWith(';')) {
      try { mostrar(await db.exec(buffer, { onNotice })); }
      catch (e) { console.log(`  ✖ ${e.message}`); }
      buffer = '';
    }
    rl.setPrompt(buffer ? '...> ' : 'rpg> ');
    rl.prompt();
  }
  rl.close();
  await db.close();
}

async function instalar() {
  rmSync(pastaDados, { recursive: true, force: true });
  const db = new PGlite(pastaDados);
  const arquivos = readdirSync(pastaSql).filter((f) => f.endsWith('.sql')).sort();
  for (const arq of arquivos) {
    if (arq.includes('demo') && args.includes('--sem-demo')) continue;
    console.log(`\n==================== ${arq} ====================`);
    const sql = readFileSync(join(pastaSql, arq), 'utf8').replace(/^﻿/, '');
    if (arq.includes('demo')) {
      // executa bloco a bloco (separados por linhas "-- @") para exibir cada resultado
      for (const [i, bloco] of sql.split(/^-- @/m).entries()) {
        const linhas = bloco.split('\n');
        if (i > 0) console.log(`\n--- ${linhas.shift().trim()} ---`);
        try { mostrar(await db.exec(linhas.join('\n'), { onNotice })); }
        catch (e) { console.log(`  ✖ ERRO: ${e.message}`); }
      }
    } else {
      await db.exec(sql, { onNotice });
      console.log('ok');
    }
  }
  await db.close();
}

if (args.includes('--console')) await console_();
else await instalar();
