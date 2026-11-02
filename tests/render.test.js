/* Roda o script de dentro do index.html contra um save sintetico e confere que
   render() liga os campos editaveis.

   Existe por causa de um bug real: `var t = bytes[o + 8]` dentro de renderStats
   sombreava a funcao t() de traducao, render() estourava na metade, e os
   oninput do dinheiro e da reputacao nunca eram ligados. A tela parecia certa,
   os campos aceitavam digitacao, e nada era gravado. Qualquer excecao no meio
   do render() reproduz essa classe de falha, entao o teste cobre a classe toda,
   nao so aquela linha.

   node tests/render.test.js */

var fs = require("fs");
var path = require("path");
var vm = require("vm");
var assert = require("assert");

var ROOT = path.join(__dirname, "..");

// ---------- save sintetico ----------
// Mesmo formato do real, pequeno. Nenhum dado do jogo entra no repositorio.

var CAREER = 4000;        // cobre o bloco de progressao: 0x2E9 + 43*65 = 3540
var LOCAL = 0x24FD + 8176 * 2;
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
  b[at.LocalOptions + 0x53F] = 2;          // contador de carros
  b[at.LocalOptions + 0x543] = 1;

  // dois registros de stat, no offset absoluto onde offset % 16 == 2
  var s0 = at.Stats + (((2 - (at.Stats % 16)) % 16) + 16) % 16;
  ["gWIN", "tPUR"].forEach(function (key, n) {
    var r = s0 + n * 16;
    for (var i = 0; i < 4; i++) b[r + i] = key.charCodeAt(i);
    b[r + 8] = 0x2C;                       // inteiro, nao float
    dv.setUint32(r + 12, 7 + n);
  });

  return { buf: buf, at: at };
}

// ---------- DOM minimo ----------

function makeEl(id) {
  return {
    id: id, value: "", textContent: "", innerHTML: "", hidden: false,
    className: "", checked: false, dataset: {}, style: {}, files: [], children: [],
    classList: { add: noop, remove: noop, toggle: noop, contains: function () { return false; } },
    addEventListener: noop, removeEventListener: noop, appendChild: noop,
    removeChild: noop, remove: noop, setAttribute: noop, focus: noop,
    blur: noop, click: noop, scrollIntoView: noop,
    getAttribute: function () { return null; },
    querySelector: function () { return makeEl("x"); },
    querySelectorAll: function () { return []; }
  };
}
function noop() {}

function makeDom() {
  var byId = {};
  var doc = {
    getElementById: function (id) {
      if (!byId[id]) byId[id] = makeEl(id);
      return byId[id];
    },
    createElement: function () { return makeEl("created"); },
    querySelectorAll: function () { return []; },
    querySelector: function () { return makeEl("x"); },
    addEventListener: noop,
    documentElement: makeEl("html"),
    body: makeEl("body")
  };
  return { doc: doc, byId: byId };
}

// ---------- montar o contexto e rodar ----------

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
   mc4.sav de verdade: node tests/render.test.js C:\caminho\mc4.sav
   O arquivo so e lido, nunca gravado. */
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

ctx.render();

// ---------- o que tem que valer depois do render ----------

var rep = dom.byId.rep, money = dom.byId.money;

assert.strictEqual(typeof rep.oninput, "function",
  "render() terminou sem ligar o campo de reputacao: alguma excecao no meio");
assert.strictEqual(typeof money.oninput, "function",
  "render() terminou sem ligar o campo de dinheiro: alguma excecao no meio");

if (!real) {
  assert.strictEqual(Number(rep.value), 2050, "a rep lida do save esta errada");
  assert.strictEqual(Number(money.value), 1234, "o dinheiro lido do save esta errado");
}

assert.ok(ctx.STATS.length >= 2, "renderStats nao achou os registros");
assert.notStrictEqual(dom.byId.roRep.textContent, "", "o rodape nao foi preenchido");

// escrever de verdade, que e o que falhava
rep.value = "4242";
rep.oninput.call(rep);
assert.strictEqual(ctx.view.getUint32(careerAt + 0x2E1), 4242,
  "digitar na reputacao nao gravou nos bytes");

money.value = "999999";
money.oninput.call(money);
assert.strictEqual(ctx.view.getUint32(careerAt + 0x2D9), 999999,
  "digitar no dinheiro nao gravou nos bytes");

// o arquivo tem que continuar valido e do mesmo tamanho
var after = ctx.parse(ctx.bytes.buffer);
assert.ok(after.valid, "o save ficou invalido depois da edicao");
assert.strictEqual(ctx.bytes.length, sizeBefore, "o tamanho do arquivo mudou");

console.log("ok - " + (real ? "save real" : "save sintetico") + ", " +
  ctx.STATS.length + " stats: render liga os campos, a escrita chega nos bytes, o save segue valido");
