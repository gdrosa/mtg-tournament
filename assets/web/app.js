'use strict';

// ---- session (durable on this device) ----
let token = localStorage.getItem('mtg.token') || null;
let nickname = localStorage.getItem('mtg.nick') || '';
let snap = null;
let ws = null;
let reconnectT = null;
// UI-only: player tapped "Change my report" to re-enter a score. Reset whenever
// a fresh authoritative snapshot arrives (we never mutate snap from the UI).
let editing = false;

const $app = document.getElementById('app');
const $round = document.getElementById('round');
const $conn = document.getElementById('conn');
const $toast = document.getElementById('toast');

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function toast(msg, isErr) {
  $toast.textContent = msg;
  $toast.className = 'toast' + (isErr ? ' err' : '');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => ($toast.className = 'toast hidden'), 2200);
}

async function post(path, body) {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token, ...body }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.error) {
    toast(data.error || ('Error ' + res.status), true);
    throw new Error(data.error || res.status);
  }
  return data;
}

// ---- realtime ----
function connect() {
  const url = (location.protocol === 'https:' ? 'wss' : 'ws') + '://' + location.host + '/ws';
  ws = new WebSocket(url);
  ws.onopen = () => {
    $conn.classList.add('online');
    ws.send(JSON.stringify({ type: 'auth', token }));
  };
  ws.onmessage = (e) => {
    try { snap = JSON.parse(e.data); editing = false; render(); } catch (_) {}
  };
  ws.onclose = () => {
    $conn.classList.remove('online');
    clearTimeout(reconnectT);
    reconnectT = setTimeout(connect, 1800);
  };
  ws.onerror = () => ws.close();
}

function reauth() { if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'auth', token })); }

// ---- actions ----
async function doJoin(nick, code) {
  if (!nick.trim()) return toast('Enter a nickname', true);
  if (!code.trim()) return toast('Enter the event code', true);
  const r = await post('/api/join', { nickname: nick.trim(), code: code.trim().toUpperCase() });
  token = r.token; nickname = nick.trim();
  localStorage.setItem('mtg.token', token);
  localStorage.setItem('mtg.nick', nickname);
  reauth();
  toast('Joined ' + (snap?.name || 'the event'));
}

async function doRegisterAndEnter(name, main, side, existingId) {
  let deckId = existingId;
  if (!deckId) {
    if (!name.trim()) return toast('Name your deck', true);
    const r = await post('/api/deck', { name: name.trim(), mainboard: main, sideboard: side });
    deckId = r.deckId;
  }
  await post('/api/enter', { deckId });
  toast('You are in! Good luck.');
}

const sendResult = (matchId, mineWon, oppWon, draws) =>
  post('/api/result', { matchId, mineWon, oppWon, draws: draws || 0 }).then(() => toast('Result reported'));
const sendInfraction = (matchId, ok) =>
  post('/api/infraction', { matchId, ok }).then(() => toast(ok ? 'Confirmed — no infractions' : 'Infraction reported'));

// ---- render ----
function render() {
  if (!snap) return;
  document.getElementById('title').textContent = snap.name || 'MTG Tournament';
  $round.textContent = (snap.phase === 'running') ? `Round ${snap.round}/${snap.plannedRounds}`
    : (snap.phase === 'finished' ? 'Finished' : (snap.phase === 'lobby' ? 'Lobby' : ''));

  if (snap.phase === 'idle' || !snap.joinCode) {
    return view(`<div class="card center"><h2>No active tournament</h2>
      <p class="muted">Ask the organizer to create an event, then enter the code.</p></div>`);
  }
  if (!snap.you) return viewJoin();
  if (!snap.you.seated) {
    if (snap.phase !== 'lobby') {
      return view(`<div class="card center"><h2>Already started</h2>
        <p class="muted">This tournament is underway, so new players can't join.</p></div>`);
    }
    return viewDeck();
  }
  // seated
  if (snap.phase === 'lobby') return viewLobby();
  return viewPlay();
}

function view(html) { $app.innerHTML = html; }

// Double-tap a revealed card to enlarge it full-screen (read the text); tap to
// dismiss. Delegated on $app so it survives every re-render.
$app.addEventListener('dblclick', (e) => {
  const img = e.target.closest('.card-img');
  if (img && img.getAttribute('src')) zoomCard(img.src, img.alt);
});
function zoomCard(src, name) {
  let lb = document.getElementById('lightbox');
  if (!lb) {
    lb = document.createElement('div');
    lb.id = 'lightbox';
    lb.className = 'lightbox hidden';
    lb.onclick = () => lb.classList.add('hidden');
    document.body.appendChild(lb);
  }
  lb.innerHTML = `<img src="${esc(src)}" alt="${esc(name)}">`;
  lb.classList.remove('hidden');
}

function viewJoin() {
  view(`<div class="card">
    <h2>Join the tournament</h2>
    <label>Nickname</label>
    <input id="f-nick" value="${esc(nickname)}" placeholder="e.g. Giuseppe" />
    <label>Event code</label>
    <input id="f-code" maxlength="6" placeholder="e.g. ${esc(snap.joinCode)}" style="text-transform:uppercase" />
    <div class="spacer"></div>
    <button class="primary" id="b-join">Join</button>
  </div>`);
  document.getElementById('b-join').onclick = () =>
    doJoin(document.getElementById('f-nick').value, document.getElementById('f-code').value);
}

function viewDeck() {
  const decks = snap.you.decks || [];
  const existing = decks.map((d) =>
    `<button class="ghost" style="margin-bottom:8px" onclick="window.__enter('${d.id}')">${esc(d.name)}</button>`).join('');
  view(`<div class="card">
    <h2>Register your deck</h2>
    <p class="muted">Welcome, ${esc(snap.you.nickname)}. Enter your list to enter the event.</p>
    ${decks.length ? `<h3>Use a saved deck</h3>${existing}<h3>or create a new one</h3>` : ''}
    <label>Deck name</label>
    <input id="d-name" placeholder="e.g. Domain Zoo" />
    <label>Maindeck (one card per line, e.g. "4 Ragavan")</label>
    <textarea id="d-main" placeholder="60+ cards"></textarea>
    <label>Sideboard</label>
    <textarea id="d-side" placeholder="15 cards"></textarea>
    <div class="spacer"></div>
    <button class="primary" id="b-reg">Register &amp; enter</button>
  </div>`);
  window.__enter = (id) => doRegisterAndEnter('', '', '', id);
  document.getElementById('b-reg').onclick = () => doRegisterAndEnter(
    document.getElementById('d-name').value,
    document.getElementById('d-main').value,
    document.getElementById('d-side').value, null);
}

function viewLobby() {
  view(`<div class="card center">
      <h2>You're in!</h2>
      <p class="muted">Playing <b>${esc(snap.you.deckName)}</b>. Waiting for the organizer to start round 1&hellip;</p>
    </div>
    ${playersCard()}`);
}

function viewPlay() {
  view(matchCard() + standingsCard());
}

function matchCard() {
  const m = snap.yourMatch;
  if (!m) return '';
  if (snap.phase === 'finished')
    return `<div class="card center"><h2>Tournament complete</h2><p class="muted">Final standings below.</p></div>`;
  if (m.bye)
    return `<div class="card center"><h2>Bye</h2><p class="muted">You have a bye this round — it counts as a win.</p></div>`;

  let body = `<h2>vs ${esc(m.opponent)}</h2>`;

  if ((m.needsResult && !m.mySubmission) || (editing && !m.revealed)) {
    body += `<p class="muted">Report your match result (best of 3):</p><div class="grid2">
      ${scoreBtn(m.matchId, 2, 0, 'You win 2–0')}
      ${scoreBtn(m.matchId, 2, 1, 'You win 2–1')}
      ${scoreBtn(m.matchId, 1, 2, 'You lose 1–2')}
      ${scoreBtn(m.matchId, 0, 2, 'You lose 0–2')}</div>
      <div class="spacer"></div>
      <button class="ghost" onclick="window.__res('${m.matchId}',1,1,1)">Draw 1–1</button>`;
  } else if (m.state === 'needsReview' && m.reviewReason === 'resultMismatch') {
    body += `<span class="pill review">Result mismatch</span>
      <p class="muted">Your report didn't match your opponent's. The organizer will resolve it.</p>`;
  } else if (!m.revealed && m.mySubmission) {
    body += `<span class="pill wait">Reported ${esc(m.mySubmission)}</span>
      <p class="muted">Waiting for your opponent to confirm the result.</p>
      <button class="ghost" onclick="window.__change()">Change my report</button>`;
  }

  if (m.revealed) {
    body += `<div class="spacer"></div><span class="pill ok">Result ${esc(m.accepted)}</span>
      <h3>${esc(m.opponent)}'s deck</h3>
      ${deckCardsHtml(m.opponentDeck)}`;
    if (m.needsInfraction) {
      body += `<p class="muted">Any infractions in this match (illegal deck, rules issue)?</p>
        <div class="row">
          <button class="good" onclick="window.__inf('${m.matchId}',true)">&#128077; All good</button>
          <button class="bad" onclick="window.__inf('${m.matchId}',false)">&#128078; Report</button>
        </div>`;
    } else if (m.state === 'needsReview' && m.reviewReason === 'infractionReported') {
      body += `<span class="pill review">Infraction reported</span><p class="muted">The organizer is reviewing.</p>`;
    } else if (m.confirmed) {
      body += `<span class="pill ok">Match confirmed &#10003;</span><p class="muted">Waiting for the round to finish.</p>`;
    } else if (m.yourInfraction != null) {
      body += `<p class="muted">You confirmed. Waiting for your opponent.</p>`;
    }
  }
  return `<div class="card">${body}</div>`;
}

function scoreBtn(matchId, mine, opp, label) {
  return `<button class="score-btn" onclick="window.__res('${matchId}',${mine},${opp},0)">
    <span class="big">${mine}&ndash;${opp}</span><span class="lbl">${label}</span></button>`;
}
window.__res = (id, a, b, d) => sendResult(id, a, b, d);
window.__inf = (id, ok) => sendInfraction(id, ok);
// Re-enter a score before the opponent confirms — UI-only; the authoritative
// submission stays until the server broadcasts a new snapshot.
window.__change = () => { editing = true; render(); };

function deckText(d) {
  if (!d) return '';
  let t = (d.mainboard || '').trim();
  if ((d.sideboard || '').trim()) t += '\n\nSideboard:\n' + d.sideboard.trim();
  return t || '(no list provided)';
}

const CAT_ORDER = ['creature', 'planeswalker', 'instant', 'sorcery', 'artifact', 'enchantment', 'land', 'other'];
const CAT_LABEL = {
  creature: 'Creatures', planeswalker: 'Planeswalkers', instant: 'Instants', sorcery: 'Sorceries',
  artifact: 'Artifacts', enchantment: 'Enchantments', land: 'Lands', other: 'Other',
};

// Card-format opponent deck (images served from the host cache over the LAN).
// Falls back to the plain-text list if the deck hasn't been resolved to cards.
function deckCardsHtml(d) {
  if (!d) return '';
  const cards = d.cards;
  if (!cards || !cards.length) return `<div class="decklist">${esc(deckText(d))}</div>`;
  const sum = (arr) => arr.reduce((s, c) => s + c.qty, 0);
  let html = '';
  for (const board of ['main', 'side']) {
    const inBoard = cards.filter((c) => c.board === board);
    if (!inBoard.length) continue;
    html += `<h4 class="board-h">${board === 'main' ? 'Maindeck' : 'Sideboard'}
      <span class="muted">${sum(inBoard)}</span></h4>`;
    for (const cat of CAT_ORDER) {
      const inCat = inBoard.filter((c) => c.category === cat);
      if (!inCat.length) continue;
      html += `<div class="cat-h">${CAT_LABEL[cat]} (${sum(inCat)})</div><div class="card-grid">`;
      for (const c of inCat) {
        html += `<div class="card-cell">
          <img class="card-img" src="${esc(c.img)}" alt="${esc(c.name)}" loading="lazy"
            onerror="this.style.display='none';this.parentElement.querySelector('.card-ph').style.display='flex'">
          <div class="card-ph" style="display:none">${esc(c.name)}</div>
          <span class="qty">&times;${c.qty}</span>
        </div>`;
      }
      html += `</div>`;
    }
  }
  return html;
}

function standingsCard() {
  const s = snap.standings || [];
  if (!s.length) return '';
  const rows = s.map((r) => `<div class="list-row">
      <div class="rank">${r.rank}</div>
      <div class="grow"><div>${esc(r.nickname)}</div><div class="sub">${esc(r.deckName)} &middot; ${esc(r.record)}</div></div>
      <div class="mono"><b>${r.matchPoints}</b> pts<div class="sub">OMW ${r.omw}%</div></div>
    </div>`).join('');
  return `<div class="card"><h3 style="margin-top:0">Standings</h3>${rows}</div>`;
}

function playersCard() {
  const p = snap.players || [];
  const rows = p.map((x) => `<div class="list-row">
      <div class="grow"><div>${esc(x.nickname)}</div><div class="sub">${esc(x.deckName)}</div></div>
      ${x.dropped ? '<span class="pill review">dropped</span>' : ''}
    </div>`).join('');
  return `<div class="card"><h3 style="margin-top:0">Players (${p.length})</h3>${rows}</div>`;
}

connect();
