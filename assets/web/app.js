'use strict';

// The same client runs in two transport modes:
//   LAN:    relative REST endpoints + /ws (the original embedded phone server)
//   Online: a single WebSocket to the public relay, selected by /r/<room>/ or
//           ?room=<room>. The tournament code remains a separate ?t= value.
const pageParams = new URLSearchParams(location.search);
const pathRoomMatch = location.pathname.match(/(?:^|\/)r\/([^/]+)(?:\/|$)/);
function safeDecode(value) {
  if (!value) return '';
  try { return decodeURIComponent(value); } catch (_) { return value; }
}
const roomId = (pathRoomMatch ? safeDecode(pathRoomMatch[1]) : (pageParams.get('room') || '')).trim();
const isOnline = roomId.length > 0;
const initialJoinCode = (pageParams.get('t') || '').trim().toUpperCase();
const storagePrefix = isOnline ? `mtg.room.${roomId}.` : 'mtg.';

// ---- session (durable on this device) ----
// Sessions are scoped to one room, because a token only means anything to the
// host that issued it. The nickname and the last list you typed are NOT: they
// are yours, and re-typing 75 cards for every new online event is the single
// worst thing this client asks of a player.
const LAST_NICK_KEY = 'mtg.lastNick';
const LAST_DECK_KEY = 'mtg.lastDeck';

function remember(key, value) {
  try { localStorage.setItem(key, value); } catch (_) { /* private mode / full */ }
}

function lastDeck() {
  try { return JSON.parse(localStorage.getItem(LAST_DECK_KEY) || 'null'); } catch (_) { return null; }
}

let token = localStorage.getItem(storagePrefix + 'token') || null;
let nickname = localStorage.getItem(storagePrefix + 'nick') || localStorage.getItem(LAST_NICK_KEY) || '';
let snap = null;
let ws = null;
let reconnectT = null;
let reconnectAttempt = 0;
let relayReady = false;
let requestSeq = 0;
let lastConnectionNotice = '';
let lastConnectionNoticeAt = 0;
const pendingRequests = new Map();
// UI-only: player tapped "Change my report" to re-enter a score. Reset whenever
// a fresh authoritative snapshot arrives (we never mutate snap from the UI).
let editing = false;
// Optional post-match questionnaire, drafted locally until sent. Kept outside
// `snap` so a fresh snapshot never wipes half-typed answers, and keyed by match
// so it resets when a new round pairs you.
let surveyDraft = null;
const surveySkipped = new Set();

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

function connectionNotice(message) {
  $conn.title = message;
  if (!snap) {
    view(`<div class="card center"><h2>${esc(isOnline ? 'Waiting for the organizer' : 'Connecting')}</h2>
      <p class="muted">${esc(message)}</p></div>`);
  }
  const now = Date.now();
  if (message !== lastConnectionNotice || now - lastConnectionNoticeAt > 10000) {
    toast(message, true);
    lastConnectionNotice = message;
    lastConnectionNoticeAt = now;
  }
}

function parseBody(body) {
  if (body == null || body === '') return {};
  if (typeof body !== 'string') return body;
  try { return JSON.parse(body); } catch (_) { return { error: body }; }
}

function onlinePost(path, body) {
  if (!ws || ws.readyState !== WebSocket.OPEN || !relayReady) {
    return Promise.reject(new Error('The organizer is offline. Reconnecting…'));
  }

  const requestId = (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function'
    ? globalThis.crypto.randomUUID()
    : `${Date.now()}-${++requestSeq}`);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pendingRequests.delete(requestId);
      reject(new Error('The organizer did not respond. Please try again.'));
    }, 15000);
    pendingRequests.set(requestId, { resolve, reject, timer });
    try {
      ws.send(JSON.stringify({ type: 'command', requestId, path, body: { token, ...body } }));
    } catch (error) {
      clearTimeout(timer);
      pendingRequests.delete(requestId);
      reject(error);
    }
  });
}

async function post(path, body) {
  try {
    let status;
    let data;
    if (isOnline) {
      const response = await onlinePost(path, body);
      status = response.status;
      data = parseBody(response.body);
    } else {
      const res = await fetch(path, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ token, ...body }),
      });
      status = res.status;
      data = await res.json().catch(() => ({}));
    }
    if (status < 200 || status >= 300 || data.error) {
      throw new Error(data.error || ('Error ' + status));
    }
    return data;
  } catch (error) {
    toast(error.message || String(error), true);
    throw error;
  }
}

// ---- realtime ----
function rejectPendingRequests(message) {
  for (const pending of pendingRequests.values()) {
    clearTimeout(pending.timer);
    pending.reject(new Error(message));
  }
  pendingRequests.clear();
}

function acceptSnapshot(payload) {
  if (typeof payload === 'string') {
    try { payload = JSON.parse(payload); } catch (_) { return false; }
  }
  if (!payload || typeof payload !== 'object' || typeof payload.phase !== 'string') return false;
  const becameReady = isOnline && !relayReady;
  snap = payload;
  editing = false;
  relayReady = isOnline ? true : relayReady;
  $conn.classList.add('online');
  $conn.title = isOnline ? 'Connected to online tournament' : 'Connected to tournament';
  render();
  // A relay may forward the initial anonymous snapshot before its ready frame.
  // Authenticate as soon as either signal proves that the tunnel is usable.
  if (becameReady) reauth();
  return true;
}

function handleOnlineMessage(message) {
  // Some relay versions wrap host output as player.send; current versions
  // unwrap it. Supporting both keeps old tournament links compatible.
  if (message && message.type === 'player.send' && message.payload != null) {
    const nested = typeof message.payload === 'string' ? parseBody(message.payload) : message.payload;
    return handleOnlineMessage(nested);
  }

  if (message && (message.type === 'relay.ready' || message.type === 'ready')) {
    if (message.hostOnline === false) {
      relayReady = false;
      $conn.classList.remove('online');
      connectionNotice('The organizer is offline. Retrying…');
      return;
    }
    relayReady = true;
    reconnectAttempt = 0;
    $conn.classList.add('online');
    $conn.title = 'Connected to online tournament';
    reauth();
    return;
  }

  if (message && message.type === 'response' && message.requestId) {
    const pending = pendingRequests.get(message.requestId);
    if (!pending) return;
    pendingRequests.delete(message.requestId);
    clearTimeout(pending.timer);
    pending.resolve({ status: Number(message.status || 200), body: message.body });
    return;
  }

  if (message && (message.type === 'snapshot' || message.type === 'state')) {
    acceptSnapshot(message.payload ?? message.snapshot ?? message.body);
    return;
  }

  if (acceptSnapshot(message)) return;

  if (message && (message.type === 'relay.error' || message.type === 'error')) {
    const detail = message.message || message.error || 'The online relay reported an error.';
    if (message.requestId && pendingRequests.has(message.requestId)) {
      const pending = pendingRequests.get(message.requestId);
      pendingRequests.delete(message.requestId);
      clearTimeout(pending.timer);
      pending.reject(new Error(detail));
    }
    relayReady = false;
    $conn.classList.remove('online');
    connectionNotice(detail);
    if (/host.*offline|organizer.*offline/i.test(detail) && ws && ws.readyState < WebSocket.CLOSING) {
      ws.close();
    }
  }
}

function connect() {
  clearTimeout(reconnectT);
  relayReady = false;
  const socketPath = isOnline ? `/v1/rooms/${encodeURIComponent(roomId)}/player` : '/ws';
  const url = (location.protocol === 'https:' ? 'wss' : 'ws') + '://' + location.host + socketPath;
  const socket = new WebSocket(url);
  ws = socket;
  $conn.title = isOnline ? 'Connecting to online tournament' : 'Connecting to tournament';
  socket.onopen = () => {
    if (ws !== socket) return;
    if (!isOnline) {
      $conn.classList.add('online');
      socket.send(JSON.stringify({ type: 'auth', token }));
    }
  };
  socket.onmessage = (e) => {
    if (ws !== socket) return;
    try {
      const message = JSON.parse(e.data);
      if (isOnline) handleOnlineMessage(message);
      else acceptSnapshot(message);
    } catch (_) {}
  };
  socket.onclose = () => {
    if (ws !== socket) return;
    $conn.classList.remove('online');
    relayReady = false;
    rejectPendingRequests('Connection lost before the organizer responded.');
    const delay = Math.min(12000, 1200 * Math.pow(1.6, reconnectAttempt++));
    if (isOnline) connectionNotice('Connection lost. Reconnecting…');
    reconnectT = setTimeout(connect, delay);
  };
  socket.onerror = () => {
    if (ws === socket) socket.close();
  };
}

function reauth() {
  if (ws && ws.readyState === WebSocket.OPEN && (!isOnline || relayReady)) {
    // `player.open` already gives anonymous Online clients their first
    // snapshot. Wait until a real token exists before spending an auth frame.
    if (isOnline && !token) return;
    ws.send(JSON.stringify({ type: 'auth', token }));
  }
}

// ---- actions ----
async function doJoin(nick, code) {
  if (!nick.trim()) return toast('Enter a nickname', true);
  if (!code.trim()) return toast('Enter the event code', true);
  const r = await post('/api/join', { nickname: nick.trim(), code: code.trim().toUpperCase() });
  token = r.token; nickname = nick.trim();
  remember(storagePrefix + 'token', token);
  remember(storagePrefix + 'nick', nickname);
  remember(LAST_NICK_KEY, nickname);
  reauth();
  toast('Joined ' + (snap?.name || 'the event'));
}

async function doRegisterAndEnter(name, main, side, existingId) {
  let deckId = existingId;
  if (!deckId) {
    if (!name.trim()) return toast('Name your deck', true);
    const r = await post('/api/deck', { name: name.trim(), mainboard: main, sideboard: side });
    deckId = r.deckId;
    // Kept on this device only, so the next event (or the next room) can offer
    // it back rather than making you type it again.
    remember(LAST_DECK_KEY, JSON.stringify({ name: name.trim(), main, side }));
  }
  await post('/api/enter', { deckId });
  toast('You are in! Good luck.');
}

const sendResult = (matchId, mineWon, oppWon, draws) =>
  post('/api/result', { matchId, mineWon, oppWon, draws: draws || 0 }).then(() => toast('Result reported'));
const sendInfraction = (matchId, ok) =>
  post('/api/infraction', { matchId, ok }).then(() => toast(ok ? 'Confirmed — no infractions' : 'Infraction reported'));

// ---- optional questionnaire ----
function ensureSurveyDraft(survey) {
  if (surveyDraft && surveyDraft.matchId === survey.matchId) return surveyDraft;
  surveyDraft = {
    matchId: survey.matchId,
    games: new Array(survey.games).fill('unknown'),
    mulls: new Array(survey.games).fill('unknown'),
    play1: 'unknown',
    sb: 'unknown',
  };
  return surveyDraft;
}

function sendSurvey() {
  if (!surveyDraft) return Promise.resolve();
  const draft = surveyDraft;
  return post('/api/survey', {
    matchId: draft.matchId,
    games: draft.games,
    mulls: draft.mulls,
    play1: draft.play1,
    sb: draft.sb,
  }).then(() => toast('Thanks — saved as your own report'));
}

// ---- round header + optional round clock ----
// The organizer sends an absolute deadline, so this counts down correctly even
// if a push is missed. ponytail: trusts this device's clock to be roughly right
// — it is a wall clock for players and gates nothing.
function roundClock() {
  if (!snap || snap.phase !== 'running' || !snap.roundEndsAt) return '';
  const left = Math.round((new Date(snap.roundEndsAt) - Date.now()) / 1000);
  if (left <= 0) return ' · time';
  return ` · ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
}

function renderRoundLabel() {
  if (!snap) return;
  $round.textContent = (snap.phase === 'running') ? `Round ${snap.round}/${snap.plannedRounds}${roundClock()}`
    : (snap.phase === 'finished' ? 'Finished' : (snap.phase === 'lobby' ? 'Lobby' : ''));
}

setInterval(renderRoundLabel, 1000);

// ---- render ----
function render() {
  if (!snap) return;
  document.getElementById('title').textContent = snap.name || 'MTG Tournament';
  renderRoundLabel();

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

// Dynamic views use delegated listeners so the same client remains compatible
// with the relay's strict Content Security Policy (no inline event handlers).
$app.addEventListener('click', (event) => {
  const target = event.target;
  if (!(target instanceof Element)) return;
  const button = target.closest('[data-action]');
  if (!button || !$app.contains(button)) return;

  const action = button.dataset.action;
  if (action === 'enter-deck') {
    doRegisterAndEnter('', '', '', button.dataset.deckId).catch(() => {});
  } else if (action === 'use-last-deck') {
    const last = lastDeck();
    if (!last) return;
    document.getElementById('d-name').value = last.name || '';
    document.getElementById('d-main').value = last.main || '';
    document.getElementById('d-side').value = last.side || '';
    toast('Filled in — check it, then register');
  } else if (action === 'result') {
    sendResult(
      button.dataset.matchId,
      Number(button.dataset.mine),
      Number(button.dataset.opp),
      Number(button.dataset.draws),
    ).catch(() => {});
  } else if (action === 'infraction') {
    sendInfraction(button.dataset.matchId, button.dataset.ok === 'true').catch(() => {});
  } else if (action === 'change-report') {
    editing = true;
    render();
  } else if (action === 'survey-set') {
    if (!surveyDraft) return;
    const field = button.dataset.field;
    const value = button.dataset.value;
    const game = button.dataset.game;
    if (field === 'game') surveyDraft.games[Number(game)] = value;
    else if (field === 'mull') surveyDraft.mulls[Number(game)] = value;
    else surveyDraft[field] = value;
    render();
  } else if (action === 'survey-send') {
    sendSurvey().catch(() => {});
  } else if (action === 'survey-skip') {
    // Skipping is immediate and local: nothing is sent, nothing is recorded.
    if (surveyDraft) surveySkipped.add(surveyDraft.matchId);
    render();
  }
});

// `error` does not bubble, so capture image failures at the app root.
$app.addEventListener('error', (event) => {
  const image = event.target;
  if (!(image instanceof HTMLImageElement) || !image.classList.contains('card-img')) return;
  image.style.display = 'none';
  const placeholder = image.parentElement?.querySelector('.card-ph');
  if (placeholder instanceof HTMLElement) placeholder.style.display = 'flex';
}, true);

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
    <input id="f-code" maxlength="6" value="${esc(initialJoinCode)}" placeholder="e.g. ${esc(snap.joinCode)}" style="text-transform:uppercase" />
    <div class="spacer"></div>
    <button class="primary" id="b-join">Join</button>
  </div>`);
  document.getElementById('b-join').onclick = () =>
    doJoin(document.getElementById('f-nick').value, document.getElementById('f-code').value);
}

function viewDeck() {
  const decks = snap.you.decks || [];
  const existing = decks.map((d) =>
    `<button class="ghost" style="margin-bottom:8px" data-action="enter-deck" data-deck-id="${esc(d.id)}">${esc(d.name)}</button>`).join('');
  // Only offered when the host has no deck of yours — otherwise the saved
  // decks above already cover it. This is what makes a brand-new online room
  // (a fresh session, so no saved decks) bearable.
  const last = decks.length ? null : lastDeck();
  view(`<div class="card">
    <h2>Register your deck</h2>
    <p class="muted">Welcome, ${esc(snap.you.nickname)}. Enter your list to enter the event.</p>
    ${decks.length ? `<h3>Use a saved deck</h3>${existing}<h3>or create a new one</h3>` : ''}
    ${last ? `<button class="ghost" style="margin-bottom:8px" data-action="use-last-deck">Fill in my last deck: ${esc(last.name)}</button>` : ''}
    <label>Deck name</label>
    <input id="d-name" placeholder="e.g. Domain Zoo" />
    <label>Maindeck (one card per line, e.g. "4 Ragavan")</label>
    <textarea id="d-main" placeholder="60+ cards"></textarea>
    <label>Sideboard</label>
    <textarea id="d-side" placeholder="15 cards"></textarea>
    <div class="spacer"></div>
    <button class="primary" id="b-reg">Register &amp; enter</button>
  </div>`);
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
  if (snap.phase === 'finished')
    return `<div class="card center"><h2>Tournament complete</h2><p class="muted">Final standings below.</p></div>`;
  // No match in a running round means you are not paired — in a knockout that
  // means you are out; in Swiss it means the organizer is still pairing.
  if (!m) {
    if (snap.phase !== 'running') return '';
    return `<div class="card center"><h2>${snap.kind === 'singleElimination' ? 'Knocked out' : 'Not paired this round'}</h2>
      <p class="muted">${snap.kind === 'singleElimination'
        ? 'Thanks for playing — your results are in the standings below.'
        : 'Sit tight; the organizer will pair you.'}</p></div>`;
  }
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
      <button class="ghost" data-action="result" data-match-id="${esc(m.matchId)}"
        data-mine="1" data-opp="1" data-draws="1">Draw 1–1</button>`;
  } else if (m.state === 'needsReview' && m.reviewReason === 'resultMismatch') {
    body += `<span class="pill review">Result mismatch</span>
      <p class="muted">Your report didn't match your opponent's. The organizer will resolve it.</p>`;
  } else if (!m.revealed && m.mySubmission) {
    body += `<span class="pill wait">Reported ${esc(m.mySubmission)}</span>
      <p class="muted">Waiting for your opponent to confirm the result.</p>
      <button class="ghost" data-action="change-report">Change my report</button>`;
  }

  if (m.revealed) {
    body += `<div class="spacer"></div><span class="pill ok">Result ${esc(m.accepted)}</span>
      <h3>${esc(m.opponent)}'s deck</h3>
      ${deckCardsHtml(m.opponentDeck)}`;
    if (m.needsInfraction) {
      body += `<p class="muted">Any infractions in this match (illegal deck, rules issue)?</p>
        <div class="row">
          <button class="good" data-action="infraction" data-match-id="${esc(m.matchId)}"
            data-ok="true">&#128077; All good</button>
          <button class="bad" data-action="infraction" data-match-id="${esc(m.matchId)}"
            data-ok="false">&#128078; Report</button>
        </div>`;
    } else if (m.state === 'needsReview' && m.reviewReason === 'infractionReported') {
      body += `<span class="pill review">Infraction reported</span><p class="muted">The organizer is reviewing.</p>`;
    } else if (m.confirmed) {
      body += `<span class="pill ok">Match confirmed &#10003;</span><p class="muted">Waiting for the round to finish.</p>`;
    } else if (m.yourInfraction != null) {
      body += `<p class="muted">You confirmed. Waiting for your opponent.</p>`;
    }
  }
  return `<div class="card">${body}</div>` + surveyCard(m.survey);
}

const MULL_LABELS = [['zero', '0'], ['one', '1'], ['two', '2'], ['threePlus', '3+'], ['unknown', '?']];
const GAME_LABELS = [['win', 'Won'], ['loss', 'Lost'], ['draw', 'Draw'], ['unknown', '?']];
const TRI_PLAY = [['yes', 'On the play'], ['no', 'On the draw'], ['unknown', '?']];
const TRI_YESNO = [['yes', 'Yes'], ['no', 'No'], ['unknown', '?']];

function optRow(field, game, options, selected) {
  return `<div class="opts">` + options.map(([value, label]) =>
    `<button class="opt${value === selected ? ' sel' : ''}" data-action="survey-set"
      data-field="${esc(field)}" data-game="${game}" data-value="${esc(value)}">${esc(label)}</button>`
  ).join('') + `</div>`;
}

// Facts only, and only facts the app cannot work out for itself. No questions
// about play quality, matchup feel, or why a match went the way it did.
function surveyCard(survey) {
  if (!survey || !survey.open) return '';
  if (survey.answered) {
    return `<div class="card"><h3 style="margin-top:0">Thanks</h3>
      <p class="muted">Your answers are saved and stay private to you.
      ${survey.opponentAnswered ? 'Your opponent has answered too.' : ''}</p></div>`;
  }
  if (surveySkipped.has(survey.matchId)) return '';

  const draft = ensureSurveyDraft(survey);
  let body = `<h3 style="margin-top:0">Optional &mdash; about 30 seconds</h3>
    <p class="muted">A few facts the app can't work out on its own. Entirely optional,
    private to you, and it never changes the confirmed result.</p>`;
  for (let g = 0; g < survey.games; g++) {
    body += `<label>Game ${g + 1} result</label>${optRow('game', g, GAME_LABELS, draft.games[g])}
      <label>Your mulligans in game ${g + 1}</label>${optRow('mull', g, MULL_LABELS, draft.mulls[g])}`;
  }
  body += `<label>Game 1</label>${optRow('play1', 0, TRI_PLAY, draft.play1)}`;
  if (survey.asksSideboard) {
    body += `<label>Did you change cards between games?</label>${optRow('sb', 0, TRI_YESNO, draft.sb)}`;
  }
  body += `<div class="spacer"></div><div class="row">
      <button class="primary" data-action="survey-send">Send</button>
      <button class="ghost" data-action="survey-skip">Skip</button>
    </div>`;
  return `<div class="card">${body}</div>`;
}

function scoreBtn(matchId, mine, opp, label) {
  return `<button class="score-btn" data-action="result" data-match-id="${esc(matchId)}"
    data-mine="${mine}" data-opp="${opp}" data-draws="0">
    <span class="big">${mine}&ndash;${opp}</span><span class="lbl">${label}</span></button>`;
}

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
        const imageSrc = isOnline && c.remoteImg ? c.remoteImg : c.img;
        html += `<div class="card-cell">
          <img class="card-img" src="${esc(imageSrc)}" alt="${esc(c.name)}" loading="lazy">
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
