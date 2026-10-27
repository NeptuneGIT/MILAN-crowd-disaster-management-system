// HISTORICAL: ported from an earlier version (v3) of the crowd simulator, with v3's default
// parameters. ../kumbh-sim.html (the former v4) has different, more pessimistic defaults, so these
// results and the PNGs next to this file do not describe the current simulator. To refresh them,
// copy kumbh-sim.html's defaults into `P` below and re-run.
// Headless port of v3's crowd model, swept over Bluetooth range and crowd density.
//   node sweep.js [--runs 20] [--tmax 240] [--inst 0.01] [--seed 1] [--target 0.99]
// Writes results_p<pct>[_i<installed %>].csv next to this file (no _i suffix = 1% installed).
// Model code is copied from v3 (Hh, gauss, weid, upS, setupWorld, stepRound, buildGrid, eachNear);
// only bands and phones are simulated, since the other dots never affect a result.
// The Bluetooth range is the same at every density, as in v3. Differences from v3, all deliberate:
//   - "band works" = 100%, so "99% of watches" is reachable (v3 default is a 90% ceiling)
//   - seeded PRNG, so runs are repeatable
const fs = require('fs'), path = require('path');
const arg = (n, d) => { const i = process.argv.indexOf('--' + n); return i > 0 ? +process.argv[i + 1] : d };
const RUNS = arg('runs', 20), TMAX = arg('tmax', 240), INST = arg('inst', 0.01), SEED = arg('seed', 1), TARGET = arg('target', .99), CHECK = arg('check', 90); // TARGET: share of watches to locate; CHECK: minute at which "share found" is also recorded
const CHECK_R = Math.round(CHECK * 60 / 10); // in 10 s rounds
const PCT = Math.round(TARGET * 100), OUT = `results_p${PCT}` + (INST === 0.01 ? '' : `_i${+(INST * 100).toFixed(2)}`) + '.csv'; // e.g. results_p99_i2.csv

let sd = SEED >>> 0;
const rnd = () => { sd = (sd + 0x6D2B79F5) | 0; let t = sd; t = Math.imul(t ^ t >>> 15, t | 1); t ^= t + Math.imul(t ^ t >>> 7, t | 61); return ((t ^ t >>> 14) >>> 0) / 4294967296 };
const randn = () => { let u = 0; while (!u) u = rnd(); const v = rnd(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(6.2832 * v) };

const AR = 600 / 960, CAP = 40000, ROUND = 10, NPL = 3, SIG = 6, RC = 6;
// v3 defaults
const P = { w: 80, carry: .5, andr: .94, inst: INST, act: .6, pick: .7, phi: .5, gps: .9, s0: .85, eld: .097, kid: .04 };
P.q = P.carry * P.andr * P.inst * P.act; P.wf = P.eld + P.kid;

const Hh = (a, b, c) => { let x = Math.imul(a, 374761393) ^ Math.imul(b, 668265263) ^ Math.imul(c, 2147483647); x = Math.imul(x ^ (x >>> 15), 2246822519); x = Math.imul(x ^ (x >>> 13), 3266489917); x ^= x >>> 16; return (x >>> 0) / 4294967296 };
const gauss = (a, b, c) => { const u = Math.max(1e-9, Hh(a, b, c)), v = Hh(a, b, c + 7919); return Math.max(-3, Math.min(3, Math.sqrt(-2 * Math.log(u)) * Math.cos(6.2832 * v))) };
const weid = r => { if (r <= .05) return 1.34; const x = 1 / r - 1 / 5.4; return x <= 0 ? .02 : 1.34 * (1 - Math.exp(-1.913 * x)) };
const upS = rho => P.s0 / (1 + (rho / RC) ** 2);
const rangeAt = (rho, rRef) => rRef; // fixed range, any density

// one crowd; returns { tt (minutes to locate TARGET share, Infinity if not reached by TMAX), f30 (share located at the CHECK minute; named f30 for history) }
function run(rho, rRef) {
  let W = P.w, Hm = W * AR, area = W * Hm;
  const need = 40 / Math.max(1e-9, P.q * rho);
  area = Math.max(area, Math.min(need, CAP / rho)); area = Math.min(area, CAP / rho);
  W = Math.sqrt(area / AR); Hm = W * AR;
  const N = Math.max(60, Math.round(rho * W * Hm)), dEff = N / (W * Hm);
  const nB = Math.min(N - 1, Math.max(1, Math.round(N * P.wf))), nP = Math.min(N - nB, Math.round(N * P.q)), M = nB + nP;
  const r = rangeAt(dEff, rRef), Rq = r * Math.pow(10, 3 * SIG / (10 * NPL)), v = weid(dEff), up = upS(dEff);

  const X = new Float32Array(M), Y = new Float32Array(M), TH = new Float32Array(M);
  const cols = Math.ceil(Math.sqrt(N * W / Hm)), rows = Math.ceil(N / cols), cw = W / cols, ch = Hm / rows, order = new Int32Array(cols * rows);
  for (let i = 0; i < order.length; i++) order[i] = i;
  for (let i = order.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); const t = order[i]; order[i] = order[j]; order[j] = t }
  for (let k = 0; k < M; k++) { const c = order[k]; X[k] = ((c % cols) + .15 + .7 * rnd()) * cw; Y[k] = (Math.floor(c / cols) + .15 + .7 * rnd()) * ch; TH[k] = rnd() * 6.2832 }

  const seedZ = (rnd() * 2 ** 30) | 0, nRounds = Math.round(TMAX * 60 / ROUND), located = new Uint8Array(nB);
  const gx = Math.max(1, Math.floor(W / Rq)), gy = Math.max(1, Math.floor(Hm / Rq)), gcw = W / gx, gch = Hm / gy;
  const heads = new Int32Array(gx * gy), nxt = new Int32Array(M);
  let nLoc = 0, f30 = null;
  for (let round = 1; round <= nRounds; round++) {
    for (let i = 0; i < M; i++) {
      TH[i] += randn() * .6; const st = P.phi * v * ROUND * (.5 + rnd());
      X[i] = (X[i] + Math.cos(TH[i]) * st + W) % W; Y[i] = (Y[i] + Math.sin(TH[i]) * st + Hm) % Hm;
    }
    heads.fill(-1); nxt.fill(-1);
    for (let i = nB; i < M; i++) { const c = Math.min(gy - 1, Math.floor(Y[i] / gch)) * gx + Math.min(gx - 1, Math.floor(X[i] / gcw)); nxt[i] = heads[c]; heads[c] = i }
    const bin = Math.floor(round * ROUND / 30);
    for (let a = 0; a < nB; a++) {
      if (located[a]) continue;
      const cx = Math.min(gx - 1, Math.floor(X[a] / gcw)), cy = Math.min(gy - 1, Math.floor(Y[a] / gch));
      const ax = gx >= 3 ? [(cx + gx - 1) % gx, cx, (cx + 1) % gx] : gx === 2 ? [0, 1] : [0], ay = gy >= 3 ? [(cy + gy - 1) % gy, cy, (cy + 1) % gy] : gy === 2 ? [0, 1] : [0];
      let done = false;
      for (const yy of ay) for (const xx of ax) for (let j = heads[yy * gx + xx]; j >= 0 && !done; j = nxt[j]) {
        let dx = X[j] - X[a], dy = Y[j] - Y[a];
        if (dx > W / 2) dx -= W; else if (dx < -W / 2) dx += W; if (dy > Hm / 2) dy -= Hm; else if (dy < -Hm / 2) dy += Hm;
        const d = Math.hypot(dx, dy); if (d > Rq) continue;
        if (d > r * Math.pow(10, SIG * gauss(a, j, seedZ + bin) / (10 * NPL))) continue;
        if (rnd() < P.pick && rnd() < P.gps && rnd() < up) done = true;
      }
      if (done) { located[a] = 1; nLoc++ }
    }
    if (round === CHECK_R) f30 = nLoc / nB;
    if (nLoc / nB >= TARGET) return { tt: round * ROUND / 60, f30: f30 ?? nLoc / nB };
  }
  return { tt: Infinity, f30: f30 ?? nLoc / nB };
}

const RANGES = [.5, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30];
const DENS = [.1, .25, .5, .6, .75, .9, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4, 4.5, 5];
const median = a => { const s = [...a].sort((x, y) => x - y), n = s.length; return n % 2 ? s[(n - 1) / 2] : (isFinite(s[n / 2 - 1]) && isFinite(s[n / 2]) ? (s[n / 2 - 1] + s[n / 2]) / 2 : Infinity) };
const rows = ['range_ref_m,density,range_at_density_m,runs,mean_found_at_check,median_t_target_min,share_reached_target'];
console.error(`runs=${RUNS} target=${PCT}% tmax=${TMAX} installed=${INST} seed=${SEED}`);
for (const rRef of RANGES) {
  for (const rho of DENS) {
    const res = Array.from({ length: RUNS }, () => run(rho, rRef));
    const f30 = res.reduce((s, x) => s + x.f30, 0) / RUNS, t = median(res.map(x => x.tt)), reached = res.filter(x => isFinite(x.tt)).length / RUNS;
    rows.push([rRef, rho, rangeAt(rho, rRef).toFixed(2), RUNS, f30.toFixed(4), isFinite(t) ? t.toFixed(2) : 'inf', reached.toFixed(2)].join(','));
  }
  console.error('range', rRef, 'done');
}
fs.writeFileSync(path.join(__dirname, OUT),rows.join('\n') + '\n');
