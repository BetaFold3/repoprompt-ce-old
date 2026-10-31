// RepoPrompt Remote — plain ES module PWA client (no build toolchain).
//
// Implements the paired-device remote wire protocol v1:
// - pairing bootstrap via the gateway pairing relay (discovery, /api/pair/*, /api/ticket),
// - one-time app-minted ticket + per-frame P256 device signatures (DPoP-lite),
// - direct session subscribe / poll / transcript catch-up / respond / steer / cancel,
// - binding_required surface for the sessions list,
// - Web Push wake registration (push_subscribe) with identifier-only payloads.
//
// Every piece of agent or server text reaches the page through textContent or
// DOM node construction only; this file never parses strings as markup.

const WIRE_VERSION = 1;
const SIGNING_CONTEXT = 'RemoteFrameV1';
const PROOF_CONTEXT = 'RepoPromptRemotePairingDeviceChallengeV1';
const DISCOVERY_PATH = '/.well-known/repoprompt/remote-pairing/v1';
const DISCOVERY_KIND = 'repoprompt_remote_discovery';
const BUILD_CHANNELS = ['release', 'debug'];
const SCOPES = {
  observe: 'sessions:observe',
  operate: 'sessions:operate',
  respond: 'interactions:respond',
};
const DB_NAME = 'repoprompt-remote';
const DB_STORE = 'identity';
const TRANSCRIPT_PAGE = 200;
const COMMAND_TIMEOUT_MS = 120000;
const ACTIVE_STATUSES = ['running', 'waiting_for_input'];
const IDLE_STATUSES = ['completed', 'failed', 'cancelled'];

// ---------------------------------------------------------------------------
// Small utilities

const $ = (id) => document.getElementById(id);
const utf8 = (text) => new TextEncoder().encode(text);

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function bytesToBase64(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function bytesToBase64URL(bytes) {
  return bytesToBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64ToBytes(base64) {
  const normalized = base64.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToHex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256Bytes(bytes) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}

// Canonical JSON matching the gateway's JSONValue.canonicalString():
// object keys sorted, compact separators, JSON string/number primitives.
function canonicalJSON(value) {
  if (value === null || value === undefined) return 'null';
  const kind = typeof value;
  if (kind === 'boolean' || kind === 'number' || kind === 'string') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJSON).join(',')}]`;
  }
  const keys = Object.keys(value).filter((key) => value[key] !== undefined).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`;
}

function logLine(message) {
  const log = $('log');
  const stamp = new Date().toISOString().slice(11, 19);
  log.textContent = `[${stamp}] ${message}\n${log.textContent}`.slice(0, 8000);
}

async function postJSON(path, body) {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.ok === false) {
    const error = new Error(payload.error || payload.message || `HTTP ${response.status}`);
    error.code = payload.code;
    throw error;
  }
  return payload;
}

// The release and Dev gateways can be reached at the same browser origin, but each
// build keeps its own paired-device list and host key. The gateway reports which
// build it is; the identity and pairing discovery both follow that channel.
async function fetchBuildChannel() {
  const unreachable = 'The RepoPrompt gateway did not report its build channel. '
    + 'Check that RepoPrompt is running on your Mac, then try again.';
  let response;
  try {
    response = await fetch('/healthz', { cache: 'no-store' });
  } catch {
    throw new Error(unreachable);
  }
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !BUILD_CHANNELS.includes(payload.channel)) {
    throw new Error(unreachable);
  }
  return payload.channel;
}

// ---------------------------------------------------------------------------
// Device identity (non-extractable P-256 key pair in IndexedDB, one record per channel)

function identityKey(channel) {
  return `identity:${channel}`;
}

function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(DB_STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function dbGet(key) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const request = db.transaction(DB_STORE, 'readonly').objectStore(DB_STORE).get(key);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

// One readwrite transaction per call; resolves only once the transaction commits,
// so a record is either fully stored or absent.
async function dbWrite(apply) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(DB_STORE, 'readwrite');
    apply(tx.objectStore(DB_STORE));
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error('Identity storage was aborted.'));
  });
}

async function signP256(privateKey, bytes) {
  // WebCrypto ECDSA P-256 emits the raw 64-byte r||s form the gateway verifies.
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, bytes);
  return new Uint8Array(signature);
}

// ---------------------------------------------------------------------------
// Client state

const state = {
  channel: null,
  keyPair: null,
  deviceId: null,
  displayName: null,
  scopes: [],
  ws: null,
  connecting: false,
  ticketId: null,
  counter: 0,
  connected: false,
  vapidPublicKey: null,
  sendChain: Promise.resolve(),
  pending: new Map(), // request_id -> {resolve, reject, timer, ws}
  sessions: new Map(), // session_id -> snapshot payload
  currentSessionId: null,
  deepLinkSessionId: null,
  // Bumped whenever the detail view switches session or closes. An async completion
  // writes to the view only if the generation it started under is still current.
  viewGeneration: 0,
  // Bumped on every streamed snapshot, so an older poll reply cannot overwrite it.
  revisionBySession: new Map(),
  // get_log pages are oldest-first turn ranges. The view shows turns from
  // transcriptStart on: older pages the reader loaded, then the newest page, which
  // starts at transcriptLiveStart. Loaded older pages mean history browsing, which
  // pauses background refresh until the Refresh button.
  transcriptToken: 0, // bumped on session switch and manual Refresh; drops in-flight pages
  transcriptLiveRequest: null, // the in-flight newest-page load; at most one at a time
  transcriptLivePending: false, // a newest-page load was asked for while one was in flight
  transcriptOlderRequest: null, // the in-flight "Load more transcript" request
  transcriptStart: null,
  transcriptLiveStart: null,
  transcriptTotal: null, // total_turns from the last newest page
  transcriptOlderText: '',
  transcriptLiveText: '',
  transcriptBrowsing: false,
  lastSeqBySession: new Map(),
  questionInputs: null, // structured question form controls for the shown interaction
};

function viewIsCurrent(generation) {
  return state.viewGeneration === generation;
}

function bumpRevision(sessionId) {
  state.revisionBySession.set(sessionId, (state.revisionBySession.get(sessionId) || 0) + 1);
}

function setBadge(text, cls) {
  const badge = $('conn-badge');
  badge.textContent = text;
  badge.className = `badge ${cls || ''}`;
}

function setActionStatus(text, cls) {
  const status = $('action-status');
  status.textContent = text || '';
  status.className = `hint ${cls || ''}`;
}

function isPaired() {
  return Boolean(state.keyPair && state.deviceId);
}

// ---------------------------------------------------------------------------
// Pairing flow

function randomNonce() {
  return bytesToBase64URL(crypto.getRandomValues(new Uint8Array(32)));
}

async function pairDevice() {
  if (!state.channel) throw new Error('The RepoPrompt gateway is not reachable.');
  const channel = state.channel;
  const displayName = ($('device-name').value || '').trim() || 'Remote device';
  const scopes = [SCOPES.observe];
  if ($('scope-operate').checked) scopes.push(SCOPES.operate);
  if ($('scope-respond').checked) scopes.push(SCOPES.respond);
  const sortedScopes = [...scopes].sort();

  const keyPair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const rawPoint = new Uint8Array(await crypto.subtle.exportKey('raw', keyPair.publicKey));
  // The app expects the 64-byte P-256 rawRepresentation (x||y, no 0x04 prefix).
  const raw64 = rawPoint.slice(1);
  const publicKeyBase64 = bytesToBase64(raw64);
  const fingerprintHex = bytesToHex(await sha256Bytes(raw64));
  const deviceId = `remote:${fingerprintHex.slice(0, 8)}`;

  $('pair-status').textContent = 'Contacting your Mac…';
  const nonce = randomNonce();
  const discovery = await postJSON(DISCOVERY_PATH, { v: 1, kind: DISCOVERY_KIND, nonce, channel });
  if (discovery.nonce !== nonce || discovery.channel !== channel || !discovery.approval_context) {
    throw new Error('The gateway returned an unexpected discovery response.');
  }
  $('host-fingerprint').textContent = discovery.host_fingerprint || '–';

  $('pair-status').textContent = 'Requesting pairing challenge…';
  const begin = await postJSON('/api/pair/begin', { approval_context: discovery.approval_context });
  if (begin.host_fingerprint) $('host-fingerprint').textContent = begin.host_fingerprint;

  const proofPayload = [
    PROOF_CONTEXT,
    String(begin.pairing_id).toLowerCase(),
    begin.challenge,
    deviceId,
    displayName,
    publicKeyBase64,
    sortedScopes.join(','),
  ].join('\n') + '\n';
  const proof = bytesToBase64(await signP256(keyPair.privateKey, utf8(proofPayload)));

  $('pair-status').textContent = 'Waiting for approval on your Mac…';
  const complete = await postJSON('/api/pair/complete', {
    pairing_id: begin.pairing_id,
    display_name: displayName,
    public_key: publicKeyBase64,
    proof,
    scopes: sortedScopes,
    device_id: deviceId,
  });

  const device = complete.device || {};
  const record = {
    keyPair,
    device: {
      deviceId: device.id || deviceId,
      displayName: device.display_name || displayName,
      scopes: device.scopes || sortedScopes,
    },
  };
  // Key and device record are written together, so a failure leaves no half identity.
  await dbWrite((store) => store.put(record, identityKey(channel)));
  applyIdentity(record);
  $('pair-status').textContent = '';
  logLine(`Paired as ${state.deviceId} (${channel})`);
  renderIdentity();
  connect();
}

function applyIdentity(record) {
  state.keyPair = record.keyPair;
  state.deviceId = record.device.deviceId;
  state.displayName = record.device.displayName;
  state.scopes = record.device.scopes || [];
}

async function loadIdentity() {
  if (!state.channel) return;
  let record;
  try {
    record = await dbGet(identityKey(state.channel));
  } catch (error) {
    throw new Error(
      `This browser could not read its saved pairing (${error.message || 'storage unavailable'}). `
        + 'Browser storage may be disabled, for example in a private window.',
    );
  }
  if (record && record.keyPair && record.keyPair.privateKey && record.device && record.device.deviceId) {
    applyIdentity(record);
  }
}

// Drops the in-memory identity, connection and every session view, so nothing from
// the previous pairing or build is reopened afterwards.
function resetIdentityState() {
  disconnect();
  state.keyPair = null;
  state.deviceId = null;
  state.displayName = null;
  state.scopes = [];
  state.ticketId = null;
  state.vapidPublicKey = null;
  state.viewGeneration += 1;
  state.currentSessionId = null;
  state.deepLinkSessionId = null;
  resetTranscriptView();
  state.questionInputs = null;
  state.sessions.clear();
  state.revisionBySession.clear();
  state.lastSeqBySession.clear();
  setActionStatus('');
  $('sessions-panel').classList.add('hidden');
  $('detail-panel').classList.add('hidden');
}

async function forgetIdentity() {
  if (state.channel) {
    try {
      await dbWrite((store) => store.delete(identityKey(state.channel)));
    } catch (error) {
      $('connect-status').textContent = `Could not delete the saved pairing: ${error.message}`;
      return;
    }
  }
  resetIdentityState();
  renderIdentity();
}

// The release and Dev builds can take turns behind the same address. Before each
// connection, re-read the gateway's channel and switch to that build's saved pairing.
async function selectGatewayIdentity() {
  const channel = await fetchBuildChannel();
  if (channel === state.channel) return;
  if (state.channel) {
    // A real build switch: nothing from the other build's pairing carries over.
    logLine(`Gateway is now the ${channel} build.`);
    resetIdentityState();
  }
  state.channel = channel;
  try {
    await loadIdentity();
  } catch (error) {
    // An unreadable record is not an absent pairing: forget the channel so the next
    // connect retries the read instead of offering to pair again.
    state.channel = null;
    throw error;
  } finally {
    renderIdentity();
  }
}

function renderIdentity() {
  const paired = isPaired();
  $('pair-panel').classList.toggle('hidden', paired || !state.channel);
  $('connect-panel').classList.toggle('hidden', !paired);
  $('build-channel').textContent = state.channel || '–';
  if (paired) {
    $('paired-name').textContent = state.displayName || '–';
    $('paired-device-id').textContent = state.deviceId || '–';
  }
}

// ---------------------------------------------------------------------------
// Signed WebSocket frames
//
// Signing and sending run one frame at a time: each frame takes the next counter
// only after the previous frame was sent, so frames reach the gateway in counter
// order even while another request (for example a poll) is still in flight.

async function signedFrame(frame) {
  const unsigned = { ...frame };
  delete unsigned.sig;
  const hashHex = bytesToHex(await sha256Bytes(utf8(canonicalJSON(unsigned))));
  const counter = Math.max(state.counter + 1, Date.now());
  state.counter = counter;
  const signingPayload = [
    SIGNING_CONTEXT,
    state.ticketId,
    state.deviceId,
    String(counter),
    hashHex,
  ].join('\n') + '\n';
  const signature = await signP256(state.keyPair.privateKey, utf8(signingPayload));
  return {
    ...frame,
    sig: {
      ticket_id: state.ticketId,
      device_id: state.deviceId,
      counter,
      algorithm: 'P256-SHA256',
      signature: bytesToBase64(signature),
    },
  };
}

function enqueueSignedSend(ws, frame) {
  const run = state.sendChain.then(async () => {
    if (state.ws !== ws || ws.readyState !== WebSocket.OPEN) throw new Error('Not connected.');
    const signed = await signedFrame(frame);
    if (state.ws !== ws || ws.readyState !== WebSocket.OPEN) throw new Error('Not connected.');
    ws.send(JSON.stringify(signed));
  });
  state.sendChain = run.catch(() => {});
  return run;
}

function settlePending(requestId) {
  const entry = state.pending.get(requestId);
  if (!entry) return null;
  state.pending.delete(requestId);
  clearTimeout(entry.timer);
  return entry;
}

function rejectPendingFor(ws, message) {
  for (const [requestId, entry] of [...state.pending.entries()]) {
    if (entry.ws === ws) {
      settlePending(requestId);
      entry.reject(new Error(message));
    }
  }
}

function sendCommand(frame) {
  return new Promise((resolve, reject) => {
    const ws = state.ws;
    if (!ws || !state.connected || ws.readyState !== WebSocket.OPEN) {
      reject(new Error('Not connected.'));
      return;
    }
    const requestId = frame.request_id || crypto.randomUUID();
    const complete = { v: WIRE_VERSION, request_id: requestId, ...frame };
    const timer = setTimeout(() => {
      if (settlePending(requestId)) reject(new Error(`Timed out waiting for ${frame.type}.`));
    }, COMMAND_TIMEOUT_MS);
    state.pending.set(requestId, { resolve, reject, timer, ws });
    enqueueSignedSend(ws, complete).catch((error) => {
      if (settlePending(requestId)) reject(error);
    });
  });
}

async function connect() {
  if (state.ws || state.connecting) return;
  state.connecting = true;
  try {
    await openConnection();
  } finally {
    state.connecting = false;
  }
}

async function openConnection() {
  try {
    await selectGatewayIdentity();
    $('gateway-status').textContent = '';
    $('gateway-retry').classList.add('hidden');
  } catch (error) {
    $('gateway-status').textContent = error.message;
    $('gateway-retry').classList.remove('hidden');
    return;
  }
  if (!isPaired()) return;
  const deviceId = state.deviceId;
  $('connect-status').textContent = 'Requesting connection ticket…';
  setBadge('connecting…', 'warn');
  let ticket;
  try {
    const minted = await postJSON('/api/ticket', { device_id: deviceId });
    ticket = minted.ticket;
  } catch (error) {
    setBadge('disconnected', 'err');
    const stale = error.code === 'unknown_device' || error.code === 'device_revoked';
    $('connect-status').textContent = stale
      ? `${error.message} Forget pairing here, then pair again on your Mac.`
      : `Ticket request failed: ${error.message}`;
    return;
  }
  if (state.ws || state.deviceId !== deviceId) return;
  state.ticketId = String(ticket.ticket_id).toLowerCase();
  state.counter = Math.max(state.counter, Date.now());

  const wsURL = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;
  const ws = new WebSocket(wsURL);
  state.ws = ws;
  $('connect-status').textContent = 'Connecting…';

  ws.onopen = () => {
    enqueueSignedSend(ws, { v: WIRE_VERSION, type: 'hello', payload: { ticket } })
      .catch((error) => logLine(`hello failed: ${error.message}`));
  };
  ws.onmessage = (event) => handleServerFrame(event.data);
  ws.onclose = () => {
    rejectPendingFor(ws, 'Connection closed.');
    if (state.ws === ws) {
      state.connected = false;
      state.ws = null;
      setBadge('disconnected', 'err');
      $('connect-status').textContent = 'Disconnected.';
      $('push-button').disabled = true;
    }
  };
  ws.onerror = () => logLine('WebSocket error.');
}

function disconnect() {
  const ws = state.ws;
  state.ws = null;
  state.connected = false;
  if (ws) {
    rejectPendingFor(ws, 'Connection closed.');
    ws.close();
  }
  setBadge('disconnected', '');
}

// ---------------------------------------------------------------------------
// Server frame handling

function commandError(payload) {
  const message = (payload && payload.message) || 'Command failed.';
  const error = new Error(message);
  error.code = payload && payload.code;
  return error;
}

function handleServerFrame(raw) {
  let frame;
  try {
    frame = JSON.parse(raw);
  } catch {
    return;
  }
  switch (frame.type) {
    case 'hello_ack': {
      state.connected = true;
      setBadge('connected', 'ok');
      $('connect-status').textContent = '';
      const payload = frame.payload || {};
      if (payload.vapid_public_key) {
        state.vapidPublicKey = payload.vapid_public_key;
        $('push-button').disabled = false;
      }
      logLine(`hello_ack auth=${payload.auth || '?'}`);
      const target = state.currentSessionId || state.deepLinkSessionId;
      if (target) {
        openSession(target);
      } else {
        showSessionsList();
      }
      break;
    }
    case 'command_result':
    case 'command_error': {
      const pending = frame.request_id ? settlePending(frame.request_id) : null;
      const isError = frame.type === 'command_error';
      const code = frame.payload && frame.payload.code;
      if (isError && (code === 'binding_required' || code === 'ambiguous_start_target')) {
        showBindingOverlay(frame.payload.message);
      }
      if (pending) {
        if (isError) {
          pending.reject(commandError(frame.payload));
        } else {
          pending.resolve(frame.payload || {});
        }
      } else if (isError) {
        logLine(`error: ${code || 'unknown'}`);
      }
      break;
    }
    case 'session_update':
    case 'session_terminal': {
      if (frame.session_id) {
        detectSeqGap(frame);
        bumpRevision(frame.session_id);
        state.sessions.set(frame.session_id, frame.payload || {});
        renderSessions();
        if (frame.session_id === state.currentSessionId) {
          renderSessionDetail();
          maybeRefreshTranscript();
        }
        if (frame.type === 'session_terminal') {
          logLine(`session ${shortID(frame.session_id)} finished`);
        }
      }
      break;
    }
    case 'interaction_resolved': {
      if (frame.session_id) {
        // interaction_resolved consumes the same per-session seq stream as
        // updates/terminal frames; track it so the next snapshot does not look
        // like a missed update and trigger a spurious get_log catch-up.
        detectSeqGap(frame);
        if (frame.session_id === state.currentSessionId) scheduleDetailRefresh();
      }
      break;
    }
    case 'session_expired': {
      if (frame.session_id) {
        bumpRevision(frame.session_id);
        state.sessions.delete(frame.session_id);
        renderSessions();
        if (frame.session_id === state.currentSessionId) {
          state.sessions.set(frame.session_id, { status: 'expired' });
          renderSessionDetail();
        }
        logLine(`session ${shortID(frame.session_id)} expired`);
      }
      break;
    }
    case 'channel_closing': {
      const reason = (frame.payload && frame.payload.reason) || 'unknown';
      logLine(`channel closing: ${reason}`);
      setBadge('app link lost', 'warn');
      break;
    }
    case 'pong':
      break;
    default:
      // Additive evolution: ignore unknown server frame types.
      break;
  }
}

function detectSeqGap(frame) {
  if (typeof frame.seq !== 'number' || !frame.session_id) return;
  const last = state.lastSeqBySession.get(frame.session_id) || 0;
  if (last && frame.seq > last + 1 && frame.session_id === state.currentSessionId) {
    // Missed updates: catch up through get_log rather than trusting the stream.
    maybeRefreshTranscript();
  }
  state.lastSeqBySession.set(frame.session_id, frame.seq);
}

// ---------------------------------------------------------------------------
// Sessions list (scoped to the bound window's active workspace)

function shortID(sessionId) {
  return String(sessionId).slice(0, 8);
}

function sessionStatus(payload) {
  return (payload && payload.status) || 'unknown';
}

function sessionName(payload, sessionId) {
  if (!payload) return shortID(sessionId);
  return (payload.session && payload.session.name) || payload.session_name || payload.name || shortID(sessionId);
}

function showSessionsList() {
  state.viewGeneration += 1;
  state.currentSessionId = null;
  state.deepLinkSessionId = null;
  $('detail-panel').classList.add('hidden');
  $('sessions-panel').classList.remove('hidden');
  refreshSessions();
}

async function refreshSessions() {
  try {
    const result = await sendCommand({ type: 'list_sessions', payload: { limit: 50 } });
    const items = result.sessions || result.items || (Array.isArray(result) ? result : []);
    for (const item of items) {
      const sessionId = item.session_id || item.id;
      if (sessionId) state.sessions.set(sessionId, item);
    }
    renderSessions();
    const ids = [...state.sessions.keys()];
    if (ids.length) {
      await sendCommand({ type: 'subscribe', payload: { session_ids: ids } }).catch(() => {});
    }
  } catch (error) {
    logLine(`list_sessions failed: ${error.message}`);
  }
}

function renderSessions() {
  const list = $('sessions-list');
  list.replaceChildren();
  const entries = [...state.sessions.entries()];
  if (!entries.length) {
    const empty = element('li', 'empty', 'No sessions in the bound workspace.');
    list.appendChild(empty);
    return;
  }
  for (const [sessionId, payload] of entries) {
    const item = element('li');
    const name = element('span', 'name', sessionName(payload, sessionId));
    const status = element('span', 'badge', sessionStatus(payload));
    if (sessionStatus(payload) === 'waiting_for_input') status.classList.add('warn');
    item.append(name, status);
    item.onclick = () => openSession(sessionId);
    list.appendChild(item);
  }
}

// ---------------------------------------------------------------------------
// Session detail: transcript pager + answer / steer / follow up / stop

async function openSession(sessionId) {
  const switching = state.currentSessionId !== sessionId;
  if (switching) state.viewGeneration += 1;
  const generation = state.viewGeneration;
  state.currentSessionId = sessionId;
  $('sessions-panel').classList.add('hidden');
  $('detail-panel').classList.remove('hidden');
  $('detail-session-id').textContent = shortID(sessionId);
  if (switching) {
    resetTranscriptView();
    $('composer-input').value = '';
    setActionStatus('');
  }
  renderSessionDetail();
  try {
    // Subscribe to this session directly; it does not need to be in the bound
    // workspace's sessions list.
    await sendCommand({ type: 'subscribe', session_id: sessionId });
  } catch (error) {
    if (viewIsCurrent(generation)) setActionStatus(error.message, 'err');
    logLine(`subscribe failed: ${error.code || error.message}`);
  }
  if (!viewIsCurrent(generation)) return;
  await pollSession(sessionId);
  if (!viewIsCurrent(generation)) return;
  // Reopening the same session (for example after a reconnect) keeps pages already
  // loaded with "Load more transcript"; Refresh returns to the newest output.
  if (!switching && state.transcriptBrowsing) return;
  await loadTranscript();
}

async function pollSession(sessionId) {
  const target = sessionId || state.currentSessionId;
  if (!target) return null;
  const generation = state.viewGeneration;
  const revision = state.revisionBySession.get(target) || 0;
  try {
    const snapshot = await sendCommand({ type: 'poll', session_id: target });
    if ((state.revisionBySession.get(target) || 0) !== revision) {
      // A streamed update arrived while this poll was in flight; it is newer.
      return state.sessions.get(target) || null;
    }
    if (snapshot && typeof snapshot.status === 'string') {
      state.sessions.set(target, snapshot);
      if (target === state.currentSessionId) renderSessionDetail();
    }
    return snapshot;
  } catch (error) {
    if (target === state.currentSessionId && viewIsCurrent(generation)) setActionStatus(error.message, 'err');
    logLine(`poll failed: ${error.code || error.message}`);
    return null;
  }
}

let detailRefreshTimer = null;
function scheduleDetailRefresh() {
  if (detailRefreshTimer) return;
  detailRefreshTimer = setTimeout(() => {
    detailRefreshTimer = null;
    pollSession();
    maybeRefreshTranscript();
  }, 750);
}

function renderSessionDetail() {
  const sessionId = state.currentSessionId;
  if (!sessionId) return;
  const payload = state.sessions.get(sessionId) || {};
  const status = sessionStatus(payload);
  const badge = $('detail-status');
  badge.textContent = status;
  badge.className = `badge ${status === 'waiting_for_input' ? 'warn' : ''}`;
  $('detail-name').textContent = sessionName(payload, sessionId);
  renderInteraction(status === 'waiting_for_input' ? payload.interaction : null, payload);

  const composer = $('composer');
  const active = ACTIVE_STATUSES.includes(status);
  const idle = IDLE_STATUSES.includes(status);
  composer.classList.toggle('hidden', !(active || idle));
  const verb = active ? 'Steer' : 'Follow up';
  $('composer-label').textContent = verb;
  $('composer-send').textContent = verb;
  $('composer-input').placeholder = active ? 'Steer the running agent…' : 'Send a follow-up message…';
  $('stop-button').classList.toggle('hidden', !active);
}

function renderInteraction(interaction, payload) {
  const box = $('interaction-box');
  if (!interaction) {
    box.classList.add('hidden');
    box.dataset.interactionId = '';
    state.questionInputs = null;
    return;
  }
  const interactionId = payload.interaction_id || interaction.id || '';
  box.classList.remove('hidden');
  if (box.dataset.interactionId === interactionId && interactionId) {
    // Keep in-progress selections when the same interaction is re-reported.
    return;
  }
  box.dataset.interactionId = interactionId;
  $('interaction-title').textContent = interaction.title || 'The agent is waiting for input.';
  $('interaction-text').textContent = interaction.prompt || '';
  $('interaction-context').textContent = interaction.context || '';
  // Only ask_user questions (kind "question") can be answered from the phone. Approvals,
  // MCP elicitations, Codex user input and instruction waits stay on the Mac.
  const fields = Array.isArray(interaction.fields) ? interaction.fields : [];
  const answerable = interaction.kind === 'question' && fields.length > 0;
  $('answer-on-mac').classList.toggle('hidden', answerable);
  $('respond-button').classList.toggle('hidden', !answerable);
  if (answerable) {
    renderQuestionForm(fields);
  } else {
    $('question-form').replaceChildren();
    state.questionInputs = null;
  }
}

function renderQuestionForm(fields) {
  const form = $('question-form');
  form.replaceChildren();
  state.questionInputs = fields.map((field, index) => {
    const fieldset = element('fieldset', 'question');
    fieldset.appendChild(element('legend', null, field.header || `Question ${index + 1}`));
    if (field.prompt) fieldset.appendChild(element('p', 'q-prompt', field.prompt));
    if (field.context) fieldset.appendChild(element('p', 'hint', field.context));

    const multiple = field.allows_multiple === true;
    const options = Array.isArray(field.options) ? field.options : [];
    const optionInputs = options.map((option, optionIndex) => {
      const label = element('label', 'check option');
      const input = document.createElement('input');
      input.type = multiple ? 'checkbox' : 'radio';
      input.name = `question-${index}`;
      input.value = String(option.label);
      input.id = `question-${index}-option-${optionIndex}`;
      const text = element('span', 'option-text');
      text.appendChild(element('span', null, option.label));
      if (option.description) text.appendChild(element('span', 'hint option-desc', option.description));
      label.append(input, text);
      fieldset.appendChild(label);
      return input;
    });

    let customInput = null;
    if (field.allows_custom !== false) {
      customInput = document.createElement('input');
      customInput.type = field.is_secret === true ? 'password' : 'text';
      customInput.autocomplete = 'off';
      customInput.placeholder = options.length ? 'Other answer (optional)…' : 'Your answer…';
      fieldset.appendChild(customInput);
      if (!multiple) {
        // Single choice: one option or a custom answer, never both.
        const custom = customInput;
        custom.addEventListener('input', () => {
          if (custom.value.trim()) for (const input of optionInputs) input.checked = false;
        });
        for (const input of optionInputs) {
          input.addEventListener('change', () => {
            if (input.checked) custom.value = '';
          });
        }
      }
    }

    const skipLabel = element('label', 'check skip');
    const skipInput = document.createElement('input');
    skipInput.type = 'checkbox';
    skipLabel.append(skipInput, element('span', null, 'Skip this question'));
    skipInput.onchange = () => {
      for (const input of optionInputs) input.disabled = skipInput.checked;
      if (customInput) customInput.disabled = skipInput.checked;
    };
    fieldset.appendChild(skipLabel);
    form.appendChild(fieldset);
    return { id: field.id, label: field.header || field.prompt || `Question ${index + 1}`, optionInputs, customInput, skipInput };
  });
}

// Builds answers[questionID] = {selected_options, custom_response} or {skipped: true}.
function collectAnswers() {
  const answers = {};
  for (const question of state.questionInputs || []) {
    if (question.skipInput.checked) {
      answers[question.id] = { skipped: true };
      continue;
    }
    const selected = question.optionInputs.filter((input) => input.checked).map((input) => input.value);
    const custom = question.customInput ? question.customInput.value.trim() : '';
    if (!selected.length && !custom) {
      throw new Error(`Answer or skip: ${question.label}`);
    }
    const answer = { selected_options: selected };
    if (custom) answer.custom_response = custom;
    answers[question.id] = answer;
  }
  return answers;
}

function transcriptText(result) {
  if (typeof result === 'string') return result;
  if (!result) return '';
  // get_log returns the page as transcript XML; it is shown as literal text.
  if (typeof result.transcript_xml === 'string') return result.transcript_xml;
  if (result.log && typeof result.log === 'string') return result.log;
  const items = result.entries || result.messages || result.log || result.transcript;
  if (Array.isArray(items)) {
    return items
      .map((entry) => {
        if (typeof entry === 'string') return entry;
        const role = entry.role || entry.kind || entry.type || '';
        const text = entry.text || entry.content || entry.message || JSON.stringify(entry);
        return role ? `[${role}] ${text}` : text;
      })
      .join('\n');
  }
  return JSON.stringify(result, null, 2);
}

function transcriptTotal(result) {
  const total = result && result.total_turns;
  return Number.isInteger(total) && total >= 0 ? total : null;
}

function requestTranscriptPage(sessionId, offset, limit) {
  return sendCommand({ type: 'get_log', session_id: sessionId, payload: { offset, limit } });
}

function renderTranscript(follow) {
  const transcript = $('transcript');
  const nearBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 48;
  transcript.textContent = [state.transcriptOlderText, state.transcriptLiveText].filter(Boolean).join('\n');
  // Follow new output only when the reader was already at the bottom.
  if (follow && nearBottom) transcript.scrollTop = transcript.scrollHeight;
  $('load-older').disabled = Boolean(state.transcriptOlderRequest) || !(state.transcriptStart > 0);
}

// Clears the transcript for a new session view.
function resetTranscriptView() {
  state.transcriptToken += 1;
  state.transcriptLiveRequest = null;
  state.transcriptLivePending = false;
  state.transcriptOlderRequest = null;
  state.transcriptStart = null;
  state.transcriptLiveStart = null;
  state.transcriptTotal = null;
  state.transcriptOlderText = '';
  state.transcriptLiveText = '';
  state.transcriptBrowsing = false;
  renderTranscript(false);
}

// Refresh button: drops loaded older pages and in-flight pages, then reloads the newest.
function refreshTranscript() {
  state.transcriptToken += 1;
  state.transcriptLiveRequest = null;
  state.transcriptLivePending = false;
  state.transcriptOlderRequest = null;
  state.transcriptOlderText = '';
  state.transcriptBrowsing = false;
  state.transcriptStart = state.transcriptLiveStart;
  renderTranscript(false);
  return loadTranscript();
}

// Loads the newest page. Pages are oldest-first, so it starts at total_turns minus one
// page. The last known total picks the first offset; when the reply reports another
// length, one more request fetches the actual newest page.
// Loads asked for while one is in flight are coalesced: the in-flight load still
// commits, then one trailing load runs. Refresh and a new session view drop the
// in-flight load instead.
async function loadTranscript() {
  const sessionId = state.currentSessionId;
  if (!sessionId) return;
  if (state.transcriptLiveRequest) {
    state.transcriptLivePending = true;
    return;
  }
  const generation = state.viewGeneration;
  const token = state.transcriptToken;
  const request = {};
  state.transcriptLiveRequest = request;
  state.transcriptLivePending = false;
  // Results for another view, or overtaken by Refresh, are dropped.
  const isCurrent = () => viewIsCurrent(generation) && state.currentSessionId === sessionId
    && state.transcriptToken === token;
  try {
    let offset = Math.max(0, (state.transcriptTotal || 0) - TRANSCRIPT_PAGE);
    let result = await requestTranscriptPage(sessionId, offset, TRANSCRIPT_PAGE);
    let total = transcriptTotal(result);
    // Loaded older pages stay until Refresh.
    if (!isCurrent() || state.transcriptBrowsing) return;
    if (total !== null && offset !== Math.max(0, total - TRANSCRIPT_PAGE)) {
      offset = Math.max(0, total - TRANSCRIPT_PAGE);
      result = await requestTranscriptPage(sessionId, offset, TRANSCRIPT_PAGE);
      total = transcriptTotal(result);
      if (!isCurrent() || state.transcriptBrowsing) return;
    }
    state.transcriptTotal = total;
    state.transcriptLiveStart = offset;
    state.transcriptStart = state.transcriptLiveStart;
    state.transcriptLiveText = transcriptText(result);
    renderTranscript(true);
  } catch (error) {
    logLine(`get_log failed: ${error.message}`);
  } finally {
    // A load dropped by Refresh or a new session view no longer owns this state.
    if (state.transcriptLiveRequest === request) {
      state.transcriptLiveRequest = null;
      const trailing = state.transcriptLivePending && !state.transcriptBrowsing;
      state.transcriptLivePending = false;
      if (trailing) loadTranscript();
    }
  }
}

// "Load more transcript": fetches the turns just before the oldest shown turn, so the
// prepended range never overlaps the view. The window moves only after success; a
// failure leaves it in place for a retry.
async function loadOlderTranscript() {
  const sessionId = state.currentSessionId;
  const start = state.transcriptStart;
  if (!sessionId || state.transcriptOlderRequest || !(start > 0)) return;
  const generation = state.viewGeneration;
  const token = state.transcriptToken;
  const request = {};
  state.transcriptOlderRequest = request;
  $('load-older').disabled = true;
  const offset = Math.max(0, start - TRANSCRIPT_PAGE);
  try {
    const result = await requestTranscriptPage(sessionId, offset, start - offset);
    if (!viewIsCurrent(generation) || state.currentSessionId !== sessionId) return;
    // A newest page that moved the window, or a Refresh, makes this range stale.
    if (state.transcriptToken !== token || state.transcriptStart !== start) return;
    const text = transcriptText(result);
    state.transcriptOlderText = state.transcriptOlderText ? `${text}\n${state.transcriptOlderText}` : text;
    state.transcriptStart = offset;
    state.transcriptBrowsing = true;
  } catch (error) {
    logLine(`get_log failed: ${error.message}`);
  } finally {
    if (state.transcriptOlderRequest === request) {
      state.transcriptOlderRequest = null;
      renderTranscript(false);
    }
  }
}

// Background refreshes reload the newest page only while no older pages are loaded;
// after "Load more transcript", only the Refresh button resets the history.
let transcriptRefreshTimer = null;
function maybeRefreshTranscript() {
  if (transcriptRefreshTimer || state.transcriptBrowsing) return;
  transcriptRefreshTimer = setTimeout(() => {
    transcriptRefreshTimer = null;
    if (state.transcriptBrowsing) return;
    loadTranscript();
  }, 750);
}

// Runs one phone action, shows the server's own error text on refusal, and
// refreshes the session afterwards so the view stays current.
// Completion writes go to the view only if it still shows the same session view the
// action started in.
async function runAction(button, pendingText, action) {
  const sessionId = state.currentSessionId;
  if (!sessionId) return;
  const generation = state.viewGeneration;
  button.disabled = true;
  setActionStatus(pendingText);
  try {
    const doneText = await action(sessionId, generation);
    if (viewIsCurrent(generation)) setActionStatus(doneText, 'ok');
  } catch (error) {
    if (viewIsCurrent(generation)) setActionStatus(error.message, 'err');
    logLine(`${pendingText} failed: ${error.code || error.message}`);
  } finally {
    button.disabled = false;
    if (viewIsCurrent(generation) && state.connected) {
      await pollSession(sessionId);
      maybeRefreshTranscript();
    }
  }
}

function respond() {
  return runAction($('respond-button'), 'Sending answer…', async (sessionId) => {
    const interactionId = $('interaction-box').dataset.interactionId;
    if (!state.questionInputs || !interactionId) throw new Error('Answer this on your Mac.');
    const payload = { interaction_id: interactionId, answers: collectAnswers() };
    await sendCommand({ type: 'respond', session_id: sessionId, payload });
    return 'Answer sent.';
  });
}

function sendComposer() {
  const button = $('composer-send');
  const verb = button.textContent;
  return runAction(button, `${verb}…`, async (sessionId, generation) => {
    const input = $('composer-input');
    const draft = input.value;
    const message = draft.trim();
    if (!message) throw new Error('Type a message first.');
    await sendCommand({ type: 'steer', session_id: sessionId, payload: { message } });
    // Clear only the draft that was sent, and only in the view it was sent from.
    if (viewIsCurrent(generation) && input.value === draft) input.value = '';
    return verb === 'Steer' ? 'Steer sent.' : 'Follow-up sent.';
  });
}

// Stop names the run this page last observed. Without one it polls first and
// refuses rather than cancelling whatever run happens to be current.
function stopSession() {
  return runAction($('stop-button'), 'Stopping…', async (sessionId) => {
    let runId = (state.sessions.get(sessionId) || {}).run_id;
    if (!runId) {
      const snapshot = await pollSession(sessionId);
      runId = snapshot && snapshot.run_id;
    }
    if (!runId) {
      throw new Error('Stop was not sent: the current run could not be identified. Refresh and try again.');
    }
    await sendCommand({ type: 'cancel', session_id: sessionId, payload: { run_id: runId } });
    return 'Stop sent.';
  });
}

// ---------------------------------------------------------------------------
// binding_required surface (sessions list only)

function showBindingOverlay(message) {
  $('binding-message').textContent = message || 'The gateway link is not bound to a RepoPrompt window.';
  $('binding-overlay').classList.remove('hidden');
}

// ---------------------------------------------------------------------------
// Web Push wake registration

async function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return null;
  try {
    return await navigator.serviceWorker.register('./sw.js');
  } catch (error) {
    logLine(`service worker registration failed: ${error.message}`);
    return null;
  }
}

async function enablePush() {
  if (!state.vapidPublicKey) {
    logLine('push unavailable: no VAPID key from gateway');
    return;
  }
  const registration = await navigator.serviceWorker.ready;
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    logLine('push permission denied');
    return;
  }
  const subscription = await registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: base64ToBytes(state.vapidPublicKey),
  });
  try {
    await sendCommand({ type: 'push_subscribe', payload: { subscription: subscription.toJSON() } });
    $('push-button').textContent = 'Push wake enabled';
    $('push-button').disabled = true;
    logLine('push wake enabled');
  } catch (error) {
    logLine(`push_subscribe failed: ${error.code || error.message}`);
  }
}

// ---------------------------------------------------------------------------
// Wire-up

async function main() {
  // Deep link (?session_id=…): kept in memory through first-time pairing and
  // opened as soon as the connection is authenticated.
  state.deepLinkSessionId = new URLSearchParams(location.search).get('session_id');

  $('pair-button').onclick = () => {
    $('pair-button').disabled = true;
    pairDevice()
      .catch((error) => {
        $('pair-status').textContent = `Pairing failed: ${error.message}`;
      })
      .finally(() => {
        $('pair-button').disabled = false;
      });
  };
  $('connect-button').onclick = () => connect();
  $('unpair-button').onclick = () => forgetIdentity();
  $('push-button').onclick = () => enablePush();
  $('refresh-sessions').onclick = () => refreshSessions();
  $('back-to-sessions').onclick = () => showSessionsList();
  $('refresh-detail').onclick = () => {
    pollSession();
    refreshTranscript();
  };
  $('gateway-retry').onclick = () => connect();
  $('load-older').onclick = () => loadOlderTranscript();
  $('respond-button').onclick = () => respond();
  $('composer-send').onclick = () => sendComposer();
  $('stop-button').onclick = () => stopSession();
  $('binding-retry').onclick = () => {
    $('binding-overlay').classList.add('hidden');
    refreshSessions();
  };
  $('binding-dismiss').onclick = () => $('binding-overlay').classList.add('hidden');
  // Returning to the tab reconnects, after re-reading which build the gateway is.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && !state.ws) connect();
  });

  await registerServiceWorker();
  // connect() reads the gateway's build channel, loads that build's saved pairing,
  // and connects when one exists.
  await connect();
  renderIdentity();
}

main();
