-- =====================================================================
--  06_dados.sql  —  conteúdo do mundo de Brumafria
--  Tudo é referenciado por NOME: para expandir o jogo basta inserir linhas.
-- =====================================================================
SET search_path TO rpg, public;

INSERT INTO mundo DEFAULT VALUES;

-- ---------------------------------------------------------------------
--  Atributos
-- ---------------------------------------------------------------------
INSERT INTO atributo (sigla, nome, descricao) VALUES
 ('ATQ', 'Ataque',     'Força física somada ao dano de golpes.'),
 ('DEF', 'Defesa',     'Metade da defesa é subtraída do dano recebido.'),
 ('VIT', 'Vitalidade', 'Cada ponto concede 3 de HP máximo.'),
 ('MAG', 'Magia',      'Potência mágica; cada ponto concede 2 de MP máximo.'),
 ('AGI', 'Agilidade',  'Precisão, esquiva, iniciativa e fuga.'),
 ('SOR', 'Sorte',      'Amplia a margem de crítico e a chance de saque.');

-- ---------------------------------------------------------------------
--  Classes (jogáveis e de monstros)
-- ---------------------------------------------------------------------
INSERT INTO classe (nome, descricao, jogavel, dado_dano, atributo_principal, bonus_noturno)
SELECT v.nome, v.descr, v.jogavel, v.dado, a.id, v.noturno
  FROM (VALUES
   ('Guerreiro',  'Muralha de aço. Muita vida, golpes pesados.',          true,  10, 'ATQ', 1.00),
   ('Mago',       'Frágil, mas explora fraquezas elementais.',            true,   6, 'MAG', 1.00),
   ('Ladino',     'Ataca com agilidade, crítica muito e acha mais saque.', true,   8, 'AGI', 1.00),
   ('Clérigo',    'Cura a si mesmo e pune mortos-vivos com luz sagrada.', true,   6, 'ATQ', 1.00),
   ('Fera',       'Criaturas selvagens.',                                 false,  6, 'ATQ', 1.00),
   ('Morto-vivo', 'Mais fortes sob a lua (+25% de dano à noite).',        false,  8, 'ATQ', 1.25),
   ('Elemental',  'Energia viva; ataca com magia do seu elemento.',       false, 10, 'MAG', 1.00),
   ('Aberração',  'Coisas que não deveriam existir.',                     false, 12, 'ATQ', 1.10)
  ) v(nome, descr, jogavel, dado, sigla, noturno)
  JOIN atributo a ON a.sigla = v.sigla;

INSERT INTO classe_atributo (classe_id, atributo_id, base, ganho_por_nivel)
SELECT c.id, a.id, v.base, v.ganho
  FROM (VALUES
   -- classe        ATQ        DEF        VIT        MAG        AGI        SOR
   ('Guerreiro', 'ATQ',8,2.0), ('Guerreiro','DEF',6,1.5), ('Guerreiro','VIT',8,2.0),
   ('Guerreiro', 'MAG',1,0.2), ('Guerreiro','AGI',4,0.8), ('Guerreiro','SOR',3,0.5),
   ('Mago',      'ATQ',3,0.6), ('Mago',     'DEF',3,0.8), ('Mago',     'VIT',5,1.2),
   ('Mago',      'MAG',10,2.5),('Mago',     'AGI',5,1.0), ('Mago',     'SOR',4,0.6),
   ('Ladino',    'ATQ',4,1.0), ('Ladino',   'DEF',4,1.0), ('Ladino',   'VIT',6,1.4),
   ('Ladino',    'MAG',2,0.4), ('Ladino',   'AGI',9,2.0), ('Ladino',   'SOR',12,2.0),
   ('Clérigo',   'ATQ',5,1.2), ('Clérigo',  'DEF',5,1.3), ('Clérigo',  'VIT',7,1.8),
   ('Clérigo',   'MAG',7,1.8), ('Clérigo',  'AGI',4,0.8), ('Clérigo',  'SOR',5,0.8),
   ('Fera',      'ATQ',4,1.5), ('Fera',     'DEF',2,1.0), ('Fera',     'VIT',3,1.5),
   ('Fera',      'MAG',0,0.0), ('Fera',     'AGI',5,1.0), ('Fera',     'SOR',2,0.3),
   ('Morto-vivo','ATQ',5,1.4), ('Morto-vivo','DEF',4,1.2),('Morto-vivo','VIT',4,1.6),
   ('Morto-vivo','MAG',2,0.8), ('Morto-vivo','AGI',2,0.6),('Morto-vivo','SOR',1,0.2),
   ('Elemental', 'ATQ',2,0.5), ('Elemental','DEF',3,1.0), ('Elemental','VIT',3,1.4),
   ('Elemental', 'MAG',6,1.8), ('Elemental','AGI',4,0.8), ('Elemental','SOR',2,0.3),
   ('Aberração', 'ATQ',6,1.8), ('Aberração','DEF',5,1.5), ('Aberração','VIT',6,2.0),
   ('Aberração', 'MAG',4,1.2), ('Aberração','AGI',3,0.8), ('Aberração','SOR',3,0.5)
  ) v(classe, sigla, base, ganho)
  JOIN classe c ON c.nome = v.classe
  JOIN atributo a ON a.sigla = v.sigla;

-- ---------------------------------------------------------------------
--  Habilidades (de heróis e de monstros conjuradores)
-- ---------------------------------------------------------------------
INSERT INTO habilidade (nome, classe_id, nivel_minimo, custo_mp, qtd_dados, lados_dado, atributo_escala, elemento, cura, descricao)
SELECT v.nome, c.id, v.nivel, v.custo, v.qtd, v.lados, a.id, v.elem::elemento, v.cura, v.descr
  FROM (VALUES
   ('Golpe Brutal',        'Guerreiro', 1, 3, 2,  8, 'ATQ', 'neutro',  false, 'Um golpe com todo o peso do corpo.'),
   ('Lâmina Flamejante',   'Guerreiro', 4, 5, 2, 10, 'ATQ', 'fogo',    false, 'A espada arde por um instante.'),
   ('Seta de Fogo',        'Mago',      1, 4, 2,  6, 'MAG', 'fogo',    false, NULL),
   ('Lança de Gelo',       'Mago',      1, 4, 2,  6, 'MAG', 'gelo',    false, NULL),
   ('Relâmpago Encadeado', 'Mago',      3, 8, 3,  8, 'MAG', 'raio',    false, NULL),
   ('Punhalada Venenosa',  'Ladino',    1, 3, 2,  6, 'AGI', 'veneno',  false, NULL),
   ('Golpe nas Sombras',   'Ladino',    4, 6, 3,  6, 'AGI', 'sombra',  false, NULL),
   ('Cura',                'Clérigo',   1, 4, 2,  8, 'MAG', 'sagrado', true,  'Restaura a própria vida.'),
   ('Julgamento Sagrado',  'Clérigo',   1, 5, 2,  8, 'MAG', 'sagrado', false, 'Luz que queima os mortos.'),
   ('Explosão Ígnea',      'Elemental', 1, 0, 2,  6, 'MAG', 'neutro',  false, 'Usa o elemento do conjurador.'),
   ('Descarga Estática',   'Elemental', 6, 0, 2, 10, 'MAG', 'raio',    false, NULL),
   ('Toque Gélido',        'Morto-vivo',3, 0, 1, 10, 'MAG', 'gelo',    false, NULL),
   ('Dreno Vital',         'Morto-vivo',5, 0, 2,  6, 'MAG', 'sombra',  true,  NULL),
   ('Olhar do Abismo',     'Aberração', 1, 0, 2, 10, 'MAG', 'sombra',  false, NULL),
   ('Badalada Silenciosa', 'Aberração', 9, 0, 3, 12, 'MAG', 'sombra',  false, 'Um som que se sente nos ossos.')
  ) v(nome, classe, nivel, custo, qtd, lados, sigla, elem, cura, descr)
  JOIN classe c ON c.nome = v.classe
  JOIN atributo a ON a.sigla = v.sigla;

-- ---------------------------------------------------------------------
--  Regiões
-- ---------------------------------------------------------------------
INSERT INTO regiao (nome, descricao, nivel_minimo, segura, secreta) VALUES
 ('Vila de Brumafria',     'Uma vila sob névoa eterna. O sino da torre está mudo há cem anos.', 1, true,  false),
 ('Bosque dos Sussurros',  'Árvores que repetem o que você acabou de pensar.',                  1, false, false),
 ('Minas de Ferrugem',     'Túneis abandonados. Ainda se ouve o martelar das picaretas.',       3, false, false),
 ('Pântano de Vidro',      'A água é tão parada que reflete o céu de outro lugar.',             5, false, false),
 ('Santuário do Sino Partido', 'O lugar onde o som foi enterrado.',                             6, false, true);

-- ---------------------------------------------------------------------
--  Itens
-- ---------------------------------------------------------------------
INSERT INTO item (nome, tipo, raridade, elemento, classe_requerida, nivel_minimo, cura_hp, cura_mp, preco, descricao)
VALUES
 ('Espada Curta',        'arma',      'comum',    'neutro', NULL, 1, 0, 0,  30, 'Simples e honesta.'),
 ('Cajado de Aprendiz',  'arma',      'comum',    'neutro', (SELECT id FROM classe WHERE nome='Mago'),    1, 0, 0, 30, NULL),
 ('Adaga Gasta',         'arma',      'comum',    'neutro', NULL, 1, 0, 0,  25, NULL),
 ('Maça de Peregrino',   'arma',      'comum',    'neutro', (SELECT id FROM classe WHERE nome='Clérigo'), 1, 0, 0, 30, NULL),
 ('Machado de Brasa',    'arma',      'incomum',  'fogo',   NULL, 3, 0, 0, 120, 'Queima feras e afogados.'),
 ('Espada Rúnica',       'arma',      'raro',     'raio',   NULL, 4, 0, 0,   0, 'Runas que zumbem como um sino distante.'),
 ('Cajado de Cristal',   'arma',      'raro',     'gelo',   (SELECT id FROM classe WHERE nome='Mago'),    5, 0, 0, 0, NULL),
 ('Gibão de Couro',      'armadura',  'comum',    'neutro', NULL, 1, 0, 0,  20, NULL),
 ('Manto do Andarilho',  'armadura',  'comum',    'neutro', NULL, 1, 0, 0,  40, NULL),
 ('Cota de Malha',       'armadura',  'incomum',  'neutro', NULL, 3, 0, 0,  90, NULL),
 ('Capa de Junco',       'armadura',  'raro',     'sombra', NULL, 5, 0, 0,   0, 'Reduz à metade o dano sombrio.'),
 ('Amuleto do Trevo',    'acessorio', 'incomum',  'neutro', NULL, 1, 0, 0,  45, NULL),
 ('Sino Restaurado',     'acessorio', 'lendario', 'sagrado',NULL, 1, 0, 0,   0, 'Quando toca, a névoa recua.'),
 ('Poção Menor',         'consumivel','comum',    'neutro', NULL, 1, 25, 0, 10, NULL),
 ('Poção Maior',         'consumivel','incomum',  'neutro', NULL, 1, 60, 0, 30, NULL),
 ('Éter',                'consumivel','comum',    'neutro', NULL, 1, 0, 15, 15, NULL),
 ('Erva Amarga',         'consumivel','comum',    'neutro', NULL, 1, 12, 0,  0, 'Cresce onde os ratos dormem.'),
 ('Couro de Lobo',       'material',  'comum',    'neutro', NULL, 1, 0, 0,   0, NULL),
 ('Brasa Viva',          'material',  'incomum',  'fogo',   NULL, 1, 0, 0,   0, 'Quente mesmo na mão.'),
 ('Chifre Pálido',       'material',  'raro',     'neutro', NULL, 1, 0, 0,   0, 'Há algo gravado nele: "1/3".'),
 ('Minério de Ferro',    'material',  'comum',    'neutro', NULL, 1, 0, 0,   0, NULL),
 ('Vidro Pantanoso',     'material',  'incomum',  'neutro', NULL, 1, 0, 0,   0, NULL),
 ('Fragmento do Badalo', 'fragmento', 'lendario', 'neutro', NULL, 1, 0, 0,   0, 'Um pedaço de bronze. Vibra quando é noite.'),
 ('Fragmento da Boca',   'fragmento', 'lendario', 'neutro', NULL, 1, 0, 0,   0, 'A borda de um sino. Está fria.'),
 ('Fragmento da Alça',   'fragmento', 'lendario', 'neutro', NULL, 1, 0, 0,   0, 'O topo de um sino, envolto em junco.');

INSERT INTO item_bonus (item_id, atributo_id, valor)
SELECT i.id, a.id, v.valor
  FROM (VALUES
   ('Espada Curta','ATQ',3),
   ('Cajado de Aprendiz','MAG',3),
   ('Adaga Gasta','AGI',2), ('Adaga Gasta','ATQ',1),
   ('Maça de Peregrino','ATQ',2), ('Maça de Peregrino','MAG',2),
   ('Machado de Brasa','ATQ',6),
   ('Espada Rúnica','ATQ',7), ('Espada Rúnica','AGI',2),
   ('Cajado de Cristal','MAG',7),
   ('Gibão de Couro','DEF',2),
   ('Manto do Andarilho','DEF',1), ('Manto do Andarilho','MAG',2), ('Manto do Andarilho','AGI',1),
   ('Cota de Malha','DEF',5), ('Cota de Malha','VIT',1), ('Cota de Malha','AGI',-1),
   ('Capa de Junco','DEF',4), ('Capa de Junco','AGI',2),
   ('Amuleto do Trevo','SOR',6),
   ('Sino Restaurado','ATQ',3), ('Sino Restaurado','DEF',3), ('Sino Restaurado','VIT',3),
   ('Sino Restaurado','MAG',3), ('Sino Restaurado','AGI',3), ('Sino Restaurado','SOR',3)
  ) v(item, sigla, valor)
  JOIN item i ON i.nome = v.item
  JOIN atributo a ON a.sigla = v.sigla;

INSERT INTO classe_item_inicial (classe_id, item_id, quantidade, equipar)
SELECT c.id, i.id, v.qtd, v.equipar
  FROM (VALUES
   ('Guerreiro','Espada Curta',1,true), ('Guerreiro','Gibão de Couro',1,true),   ('Guerreiro','Poção Menor',3,false),
   ('Mago','Cajado de Aprendiz',1,true),('Mago','Manto do Andarilho',1,true),    ('Mago','Poção Menor',2,false), ('Mago','Éter',2,false),
   ('Ladino','Adaga Gasta',1,true),     ('Ladino','Gibão de Couro',1,true),      ('Ladino','Poção Menor',3,false),
   ('Clérigo','Maça de Peregrino',1,true),('Clérigo','Gibão de Couro',1,true),   ('Clérigo','Poção Menor',2,false)
  ) v(classe, item, qtd, equipar)
  JOIN classe c ON c.nome = v.classe
  JOIN item i ON i.nome = v.item;

-- ---------------------------------------------------------------------
--  Monstros
-- ---------------------------------------------------------------------
INSERT INTO monstro (nome, classe_id, nivel, elemento, fraqueza, comportamento, chefe, xp_recompensa, ouro_min, ouro_max, descricao)
SELECT v.nome, c.id, v.nivel, v.elem::elemento, v.fraq::elemento, v.comp::comportamento, v.chefe, v.xp, v.omin, v.omax, v.descr
  FROM (VALUES
   ('Rato-de-Musgo',     'Fera',       1, 'neutro', 'fogo',    'agressivo',  false,  25,  1,   5, 'roído e faminto'),
   ('Lobo Cinzento',     'Fera',       2, 'neutro', 'fogo',    'agressivo',  false,  40,  2,   8, 'olhos que brilham na névoa'),
   ('Fogo-Fátuo',        'Elemental',  2, 'fogo',   'gelo',    'conjurador', false,  55,  4,  10, 'uma luz que quer ser seguida'),
   ('Cervo Pálido',      'Fera',       3, 'neutro', 'sombra',  'covarde',    false,  90, 10,  20, 'algo brilha preso aos seus chifres'),
   ('Esqueleto Mineiro', 'Morto-vivo', 3, 'neutro', 'sagrado', 'defensivo',  false,  70,  5,  12, 'ainda segura a picareta'),
   ('Golem de Ferrugem', 'Elemental',  4, 'neutro', 'raio',    'defensivo',  false,  95,  8,  16, 'range a cada passo'),
   ('Capataz Sem Rosto', 'Morto-vivo', 5, 'neutro', 'sagrado', 'berserker',  true,  260, 40,  80, 'carrega um sino quebrado no cinto'),
   ('Sapo Vítreo',       'Fera',       5, 'veneno', 'raio',    'agressivo',  false, 110, 10,  20, 'transparente como um copo'),
   ('Afogado',           'Morto-vivo', 6, 'gelo',   'fogo',    'berserker',  false, 140, 12,  25, 'pinga água que não cai'),
   ('Bruxa do Junco',    'Aberração',  7, 'sombra', 'sagrado', 'conjurador', true,  420, 70, 120, 'canta em uma língua sem vogais'),
   ('Eco do Sino',       'Elemental',  7, 'raio',   'sombra',  'conjurador', false, 180, 15,  30, 'um som que tomou forma'),
   ('O Sineiro',         'Aberração',  8, 'sombra', 'sagrado', 'berserker',  true,  900, 200, 300, 'aquele que calou o sino')
  ) v(nome, classe, nivel, elem, fraq, comp, chefe, xp, omin, omax, descr)
  JOIN classe c ON c.nome = v.classe;

INSERT INTO monstro_regiao (monstro_id, regiao_id, peso, periodo)
SELECT m.id, r.id, v.peso, v.periodo::periodo
  FROM (VALUES
   ('Rato-de-Musgo',     'Bosque dos Sussurros', 40, 'qualquer'),
   ('Lobo Cinzento',     'Bosque dos Sussurros', 30, 'qualquer'),
   ('Fogo-Fátuo',        'Bosque dos Sussurros', 20, 'noite'),
   ('Cervo Pálido',      'Bosque dos Sussurros',  5, 'noite'),
   ('Esqueleto Mineiro', 'Minas de Ferrugem',    40, 'qualquer'),
   ('Golem de Ferrugem', 'Minas de Ferrugem',    30, 'qualquer'),
   ('Capataz Sem Rosto', 'Minas de Ferrugem',     4, 'qualquer'),
   ('Sapo Vítreo',       'Pântano de Vidro',     40, 'qualquer'),
   ('Afogado',           'Pântano de Vidro',     30, 'noite'),
   ('Bruxa do Junco',    'Pântano de Vidro',      4, 'noite'),
   ('Eco do Sino',       'Santuário do Sino Partido', 40, 'qualquer'),
   ('O Sineiro',         'Santuário do Sino Partido', 10, 'qualquer')
  ) v(monstro, regiao, peso, periodo)
  JOIN monstro m ON m.nome = v.monstro
  JOIN regiao r ON r.nome = v.regiao;

-- "inventário" de saque por tipo de monstro
INSERT INTO monstro_drop (monstro_id, item_id, chance, qtd_min, qtd_max)
SELECT m.id, i.id, v.chance, v.qmin, v.qmax
  FROM (VALUES
   ('Rato-de-Musgo',     'Erva Amarga',        40, 1, 2),
   ('Lobo Cinzento',     'Couro de Lobo',      60, 1, 2),
   ('Fogo-Fátuo',        'Brasa Viva',         50, 1, 1),
   ('Fogo-Fátuo',        'Éter',               20, 1, 1),
   ('Cervo Pálido',      'Chifre Pálido',      50, 1, 1),
   ('Cervo Pálido',      'Fragmento do Badalo',35, 1, 1),
   ('Esqueleto Mineiro', 'Minério de Ferro',   50, 1, 2),
   ('Esqueleto Mineiro', 'Poção Menor',        20, 1, 1),
   ('Golem de Ferrugem', 'Minério de Ferro',   80, 1, 3),
   ('Golem de Ferrugem', 'Espada Rúnica',       5, 1, 1),
   ('Capataz Sem Rosto', 'Fragmento da Boca', 100, 1, 1),
   ('Capataz Sem Rosto', 'Poção Maior',        50, 1, 2),
   ('Sapo Vítreo',       'Vidro Pantanoso',    50, 1, 2),
   ('Sapo Vítreo',       'Éter',               15, 1, 1),
   ('Afogado',           'Poção Maior',        20, 1, 1),
   ('Afogado',           'Cajado de Cristal',   5, 1, 1),
   ('Bruxa do Junco',    'Fragmento da Alça', 100, 1, 1),
   ('Bruxa do Junco',    'Capa de Junco',      40, 1, 1),
   ('Eco do Sino',       'Éter',               40, 1, 2),
   ('O Sineiro',         'Sino Restaurado',   100, 1, 1)
  ) v(monstro, item, chance, qmin, qmax)
  JOIN monstro m ON m.nome = v.monstro
  JOIN item i ON i.nome = v.item;

-- ---------------------------------------------------------------------
--  Missões
-- ---------------------------------------------------------------------
INSERT INTO quest (nome, descricao, tipo, nivel_minimo, monstro_alvo, item_alvo, regiao_alvo, quantidade,
                   recompensa_xp, recompensa_ouro, recompensa_item, quest_prerequisito, secreta)
VALUES
 ('Ratos no Celeiro', 'O moleiro pede que você elimine 3 ratos-de-musgo no bosque.', 'cacar', 1,
   (SELECT id FROM monstro WHERE nome='Rato-de-Musgo'), NULL, NULL, 3, 60, 20, (SELECT id FROM item WHERE nome='Poção Menor'), NULL, false),
 ('Peles para o Inverno', 'A curtidora precisa de 3 couros de lobo.', 'coletar', 1,
   NULL, (SELECT id FROM item WHERE nome='Couro de Lobo'), NULL, 3, 100, 40, (SELECT id FROM item WHERE nome='Manto do Andarilho'), 1, false),
 ('Luzes no Bosque', 'Crianças somem seguindo luzes à noite. Apague 2 fogos-fátuos.', 'cacar', 2,
   (SELECT id FROM monstro WHERE nome='Fogo-Fátuo'), NULL, NULL, 2, 120, 30, NULL, NULL, false),
 ('O Que Dorme nas Minas', 'Desça às Minas de Ferrugem e veja o que restou.', 'explorar', 3,
   NULL, NULL, (SELECT id FROM regiao WHERE nome='Minas de Ferrugem'), 1, 80, 0, NULL, NULL, false),
 ('O Capataz', 'Os mineiros falam de um capataz que ainda cobra o turno. Encerre o expediente dele.', 'cacar', 3,
   (SELECT id FROM monstro WHERE nome='Capataz Sem Rosto'), NULL, NULL, 1, 300, 100, (SELECT id FROM item WHERE nome='Cota de Malha'), 4, false),
 ('Vidro e Junco', 'Algo canta no Pântano de Vidro quando a lua está alta.', 'cacar', 5,
   (SELECT id FROM monstro WHERE nome='Bruxa do Junco'), NULL, NULL, 1, 450, 150, NULL, NULL, false),
 ('O Sino que Não Toca', 'Os três fragmentos se unem. Há um caminho sob a torre da vila. Silencie quem silenciou o sino.', 'cacar', 1,
   (SELECT id FROM monstro WHERE nome='O Sineiro'), NULL, NULL, 1, 1200, 500, NULL, NULL, true);

-- ---------------------------------------------------------------------
--  Mistério principal
-- ---------------------------------------------------------------------
INSERT INTO segredo (nome, mensagem, regiao_desbloqueada, quest_desbloqueada) VALUES
 ('O Sino Partido',
  'Os três fragmentos se encaixam nas suas mãos e, por um instante, o sino da vila TOCA. A névoa se abre e revela uma escada sob a torre: o Santuário do Sino Partido.',
  (SELECT id FROM regiao WHERE nome = 'Santuário do Sino Partido'),
  (SELECT id FROM quest  WHERE nome = 'O Sino que Não Toca'));

INSERT INTO segredo_requisito (segredo_id, item_id)
SELECT s.id, i.id FROM segredo s, item i
 WHERE s.nome = 'O Sino Partido'
   AND i.nome IN ('Fragmento do Badalo', 'Fragmento da Boca', 'Fragmento da Alça');

-- ---------------------------------------------------------------------
--  Conquistas
-- ---------------------------------------------------------------------
INSERT INTO conquista (codigo, nome, descricao, titulo) VALUES
 ('PRIMEIRO_SANGUE',   'Primeiro Sangue',     'Vença sua primeira batalha.',               NULL),
 ('CACADOR',           'Caçador',             'Vença 10 batalhas.',                        'o Caçador'),
 ('NOTURNO',           'Caminhante da Noite', 'Vença 10 batalhas à noite.',                 'Caminhante da Noite'),
 ('FAVORECIDO',        'Favorecido pelos Dados', 'Acerte 3 críticos na mesma batalha.',    'Favorecido pelos Dados'),
 ('QUEBRA_COROAS',     'Quebra-Coroas',       'Derrote um chefe.',                         'Quebra-Coroas'),
 ('VETERANO',          'Veterano',            'Alcance o nível 5.',                        NULL),
 ('AQUELE_QUE_VOLTOU', 'Aquele que Voltou',   'Seja derrotado e volte a lutar.',           NULL),
 ('OUVINTE_DO_SINO',   'Ouvinte do Sino',     'Revele o segredo do sino.',                 'Ouvinte do Sino');

