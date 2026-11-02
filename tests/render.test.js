/* Roda o script de dentro do index.html contra um save sintetico e confere que
   render() liga os campos editaveis e que cada um grava onde deve.

   Existe por causa de um bug real: `var t = bytes[o + 8]` dentro de renderStats
   sombreava a funcao t() de traducao, render() estourava na metade, e os
   oninput do dinheiro e da reputacao nunca eram ligados. A tela parecia certa,
   os campos aceitavam digitacao, e nada era gravado. Qualquer excecao no meio
   do render() reproduz essa classe de falha, entao o teste cobre a classe toda,
   nao so aquela linha.

   node tests/render.test.js
   node tests/render.test.js C:\caminho\para\mc4.sav */

var fs = require("fs");
var path = require("path");
var vm = require("vm");
var assert = require("assert");

var ROOT = path.join(__dirname, "..");

var OFF_LABEL = 32, OFF_PLATE = 2186, SLOT_STRIDE = 8176, SLOT0 = 0x24FD;

// ---------- save sintetico ----------
// Mesmo formato do real, pequeno. Nenhum dado do jogo entra no repositorio.

var CAREER = 4000;        // cobre o bloco de progressao: 0x2E9 + 43*65 = 3540
var LOCAL = SLOT0 + SLOT_STRIDE * 2;
var STATS = 1024;

function buildSave() {
  var secs = [
    { name: "Stats", flag: 1, size: STATS },
    { name: "LocalOptions", flag: 9, size: LOCAL },
    { name: "Career", flag: 11, size: CAREER }
  ];

  var total = 8;
  secs.forEach(function (s) { total += 4 + s.name.length + 1 + 4 + s.size; });

  var buf = new ArrayBuffer(total);
  var b = new Uint8Array(buf);
  var dv = new DataView(buf);
  var at = {};

  dv.setUint32(0, 0x0E);
  dv.setUint32(4, secs.length);

  var o = 8;
  secs.forEach(function (s) {
    dv.setUint32(o, s.name.length);
    for (var i = 0; i < s.name.length; i++) b[o + 4 + i] = s.name.charCodeAt(i);
    b[o + 4 + s.name.length] = s.flag;
    dv.setUint32(o + 4 + s.name.length + 1, s.size);
    at[s.name] = o + 4 + s.name.length + 5;
    o = at[s.name] + s.size;
  });
  assert.strictEqual(o, total, "o walk das secoes tem que fechar no fim do arquivo");

  dv.setUint32(at.Career + 0x2D9, 1234);   // dinheiro
  dv.setUint32(at.Career + 0x2E1, 2050);   // reputacao
  dv.setUint32(at.Career + 0x2E5, 43);     // blocos de progressao
  b[at.LocalOptions + 0x53F] = 1;          // contador de carros
  b[at.LocalOptions + 0x543] = 0;

  // slot 0 ocupado, pra ter o que ler na abertura
  var s0 = at.LocalOptions + SLOT0;
  "vp_vw_golf_83".split("").forEach(function (c, i) { b[s0 + i] = c.charCodeAt(0); });
  "83 GOLF/GTI".split("").forEach(function (c, i) { b[s0 + OFF_LABEL + i] = c.charCodeAt(0); });
  "RSTLESS".split("").forEach(function (c, i) { b[s0 + OFF_PLATE + i] = c.charCodeAt(0); });

  // dois registros de stat, no offset absoluto onde offset % 16 == 2
  var st = at.Stats + (((2 - (at.Stats % 16)) % 16) + 16) % 16;
  ["gWIN", "tPUR"].forEach(function (key, n) {
    var r = st + n * 16;
    for (var i = 0; i < 4; i++) b[r + i] = key.charCodeAt(i);
    b[r + 8] = 0x2C;                       // inteiro, nao float
    dv.setUint32(r + 12, 7 + n);
  });

  return { buf: buf, at: at };
}

// ---------- DOM minimo ----------
// addEventListener guarda o listener em _on, pra o teste poder disparar.

function noop() {}

function makeEl(id) {
  var e = {
    id: id, value: "", textContent: "", innerHTML: "", hidden: false,
    className: "", checked: false, dataset: {}, style: {}, files: [], children: [],
    _on: {},
    classList: { add: noop, remove: noop, toggle: noop, contains: function () { return false; } },
    addEventListener: function (type, fn) { e._on[type] = fn; },
    removeEventListener: noop, appendChild: noop, removeChild: noop, remove: noop,
    setAttribute: noop, focus: noop, blur: noop, click: noop, scrollIntoView: noop,
    getAttribute: function () { return null; },
    closest: function () { return e; },
    querySelector: function () { return makeEl("x"); },
    querySelectorAll: function (sel) { return group(sel); }
  };
  return e;
}

/* As linhas da garagem nascem de innerHTML, que este shim nao interpreta, entao
   nos fabricamos as mesmas linhas que a pagina criaria e devolvemos em
   querySelectorAll. Assim os addEventListener reais do index.html caem em
   elementos que o teste consegue acionar depois. */

var SLOTS = 0, CELLS = 0, rows = null, cells = null;

function buildRow(i) {
  var sel = makeEl("sel" + i), lbl = makeEl("lbl" + i), plate = makeEl("plate" + i);
  var row = makeEl("row" + i);
  sel.dataset.slot = String(i);
  lbl.dataset.label = String(i);
  plate.dataset.plate = String(i);
  row.querySelector = function (s) { return s === "select" ? sel : s === "input.plate" ? plate : lbl; };
  sel.closest = lbl.closest = plate.closest = function () { return row; };
  return { row: row, sel: sel, lbl: lbl, plate: plate };
}

function buildCell(i) {
  var c = makeEl("cell" + i);
  c.dataset.prog = String(i);
  c.closest = function () { return c; };
  return c;
}

/* Construido de proposito, nao na primeira chamada: applyLang() roda logo que o
   script carrega e ja chama querySelectorAll, quando ainda nao sabemos quantos
   slots o save tem. */
function buildGroups() {
  rows = []; for (var i = 0; i < SLOTS; i++) rows.push(buildRow(i));
  cells = []; for (var k = 0; k < CELLS; k++) cells.push(buildCell(k));
}

function group(sel) {
  if (!rows) return [];
  if (sel === "select") return rows.map(function (r) { return r.sel; });
  if (sel === "input.lbl") return rows.map(function (r) { return r.lbl; });
  if (sel === "input.plate") return rows.map(function (r) { return r.plate; });
  if (sel === ".cell") return cells;
  return [];
}

function makeDom() {
  var byId = {};
  var doc = {
    getElementById: function (id) {
      if (!byId[id]) byId[id] = makeEl(id);
      return byId[id];
    },
    createElement: function () { return makeEl("created"); },
    querySelectorAll: function (sel) { return group(sel); },
    querySelector: function () { return makeEl("x"); },
    addEventListener: noop,
    documentElement: makeEl("html"),
    body: makeEl("body")
  };
  return { doc: doc, byId: byId };
}

// ---------- montar o contexto ----------

var html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
var script = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"));
assert.ok(script.length > 1000, "nao consegui extrair o script do index.html");

var dom = makeDom();
var ctx = {
  document: dom.doc,
  navigator: { language: "pt-BR" },
  localStorage: { getItem: function () { return null; }, setItem: noop },
  URL: { createObjectURL: function () { return "blob:x"; }, revokeObjectURL: noop },
  Blob: function () {},
  FileReader: function () {},
  setTimeout: noop,
  console: console
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(script, ctx, { filename: "index.html" });

/* Sem argumento roda no save sintetico. Passando um caminho, roda no seu
   mc4.sav de verdade. O arquivo so e lido, nunca gravado. */
var real = process.argv[2];
var save;
if (real) {
  var raw = fs.readFileSync(real);
  save = { buf: raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) };
} else {
  save = buildSave();
}

ctx.bytes = new Uint8Array(save.buf);
ctx.view = new DataView(save.buf);
ctx.secs = ctx.parse(save.buf);
assert.ok(ctx.secs.valid, "o save tem que passar no parse");

var careerAt = ctx.secs.list.filter(function (s) { return s.name === "Career"; })[0].data;
var sizeBefore = ctx.bytes.length;

SLOTS = ctx.slotCount();
CELLS = ctx.progTotal();
assert.ok(SLOTS >= 2, "preciso de pelo menos dois slots pra testar");
assert.ok(CELLS >= 10, "preciso de blocos de progressao pra testar");
buildGroups();

ctx.render();

// ---------- carteira ----------

var rep = dom.byId.rep, money = dom.byId.money;

assert.strictEqual(typeof rep.oninput, "function",
  "render() terminou sem ligar o campo de reputacao: alguma excecao no meio");
assert.strictEqual(typeof money.oninput, "function",
  "render() terminou sem ligar o campo de dinheiro: alguma excecao no meio");

if (!real) {
  assert.strictEqual(Number(rep.value), 2050, "a rep lida do save esta errada");
  assert.strictEqual(Number(money.value), 1234, "o dinheiro lido do save esta errado");
}

rep.value = "4242";
rep.oninput.call(rep);
assert.strictEqual(ctx.view.getUint32(careerAt + 0x2E1), 4242,
  "digitar na reputacao nao gravou nos bytes");

money.value = "999999";
money.oninput.call(money);
assert.strictEqual(ctx.view.getUint32(careerAt + 0x2D9), 999999,
  "digitar no dinheiro nao gravou nos bytes");

// ---------- stats ----------

assert.ok(ctx.STATS.length >= 2, "renderStats nao achou os registros");
assert.notStrictEqual(dom.byId.roRep.textContent, "", "o rodape nao foi preenchido");

// ---------- garagem: trocar o veiculo ----------

function str(at, n) {
  var s = ""; for (var i = 0; i < n; i++) s += String.fromCharCode(ctx.bytes[at + i]);
  return s;
}

var r1 = rows[1];
assert.strictEqual(typeof r1.sel._on.change, "function", "o select do slot nao foi ligado");

r1.sel.value = "vp_aud_r8_08";
r1.sel._on.change.call(r1.sel);

var slot1 = ctx.slotAt(1);
assert.strictEqual(str(slot1, 12), "vp_aud_r8_08", "o nome do prefab nao foi gravado");
assert.strictEqual(ctx.bytes[slot1 + 12], 0, "faltou o terminador depois do nome");
assert.strictEqual(ctx.bytes[slot1 + 13], 0xCD, "o preenchimento depois do nome nao e 0xCD");
assert.ok(r1.lbl.value.length > 0, "o rotulo automatico nao foi preenchido");

// esvaziar de volta grava "blank", que e o que o jogo poe num slot vazio
r1.sel.value = "";
r1.sel._on.change.call(r1.sel);
assert.strictEqual(str(slot1, 5), "blank", "esvaziar o slot nao gravou blank");

// ---------- garagem: rotulo ----------

assert.strictEqual(typeof r1.lbl._on.input, "function", "o campo de rotulo nao foi ligado");
r1.lbl.value = "MEU R8";
r1.lbl._on.input.call(r1.lbl);
assert.strictEqual(str(slot1 + OFF_LABEL, 6), "MEU R8", "o rotulo nao foi gravado");
assert.strictEqual(ctx.bytes[slot1 + OFF_LABEL + 6], 0, "faltou o terminador depois do rotulo");
assert.strictEqual(ctx.bytes[slot1 + OFF_LABEL + 7], 0xCD, "o preenchimento do rotulo nao e 0xCD");

// ---------- garagem: placa ----------
// A placa ocupa 7 bytes exatos. O byte logo depois e de outra coisa e nao pode
// ser tocado, entao marcamos com uma sentinela e conferimos que sobreviveu.

assert.strictEqual(typeof r1.plate._on.input, "function", "o campo de placa nao foi ligado");
var plateAt = slot1 + OFF_PLATE;
ctx.bytes[plateAt + 7] = 0x5A;

r1.plate.value = "xyz9876";
r1.plate._on.input.call(r1.plate);
assert.strictEqual(r1.plate.value, "XYZ9876", "a placa nao foi passada pra maiuscula");
assert.strictEqual(str(plateAt, 7), "XYZ9876", "a placa nao foi gravada");
assert.strictEqual(ctx.bytes[plateAt + 7], 0x5A, "a placa invadiu o byte seguinte");

// placa incompleta nao pode gravar nada
r1.plate.value = "AB1";
r1.plate._on.input.call(r1.plate);
assert.strictEqual(str(plateAt, 7), "XYZ9876", "placa de menos de 7 caracteres gravou mesmo assim");

// caractere invalido e descartado, nao gravado
r1.plate.value = "ab-12/34";
r1.plate._on.input.call(r1.plate);
assert.strictEqual(r1.plate.value, "AB1234", "os caracteres invalidos nao foram filtrados");
assert.strictEqual(str(plateAt, 7), "XYZ9876", "a placa filtrada ficou curta e gravou assim mesmo");

// ---------- progressao ----------

var prog = dom.byId.prog;
assert.strictEqual(typeof prog.onclick, "function", "a grade de progressao nao foi ligada");

var cell = cells[5], at5 = ctx.progAt(5), was = ctx.bytes[at5];
prog.onclick({ target: cell });
assert.notStrictEqual(ctx.bytes[at5], was, "clicar no bloco de progressao nao mudou o flag");
prog.onclick({ target: cell });
assert.strictEqual(ctx.bytes[at5], was, "clicar de novo nao voltou o flag");

dom.byId.progAll.onclick();
for (var i = 0; i < CELLS; i++) {
  assert.strictEqual(ctx.bytes[ctx.progAt(i)], 1, "marcar tudo deixou o bloco " + i + " de fora");
}
dom.byId.progNone.onclick();
for (var j = 0; j < CELLS; j++) {
  assert.strictEqual(ctx.bytes[ctx.progAt(j)], 0, "limpar tudo deixou o bloco " + j + " marcado");
}

// ---------- o arquivo tem que sobreviver a tudo isso ----------

var after = ctx.parse(ctx.bytes.buffer);
assert.ok(after.valid, "o save ficou invalido depois das edicoes");
assert.strictEqual(ctx.bytes.length, sizeBefore, "o tamanho do arquivo mudou");

console.log("ok - " + (real ? "save real" : "save sintetico") + ": " +
  SLOTS + " slots, " + CELLS + " blocos, " + ctx.STATS.length + " stats. " +
  "Carteira, veiculo, rotulo, placa e progressao gravam; o save segue valido.");
