// RepoPrompt Remote — plain ES module PWA client (no build toolchain).
//
// Implements the paired-device remote wire protocol v1:
// - pairing bootstrap via the gateway pairing relay (discovery, /api/pair/*, /api/ticket),
// - one-time app-minted ticket + per-frame P256 device signatures (DPoP-lite),
// - direct session subscribe / poll / transcript catch-up / respond / steer / cancel,
// - a page-local workspace chooser for the sessions list (list_workspaces, ID-only list_sessions),
// - Web Push wake registration (push_subscribe) with identifier-only payloads,
// - optional passkey unlock: lock presentation, native WebAuthn ceremonies started
//   directly from the user's tap, Lock, and foreground activity reports.
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
// Passkey unlock. The app's challenge lives 60 seconds from the begin request; options
// are used only while at least 15 seconds of that remain, so a prompt is not started
// on a challenge about to expire. Ages use the monotonic clock.
const CEREMONY_CHALLENGE_LIFETIME_MS = 60000;
const CEREMONY_OPTIONS_MARGIN_MS = 15000;
// At most one foreground activity report per 30 seconds; never a trailing timer.
const ACTIVITY_THROTTLE_MS = 30000;
const CREDENTIAL_MAX_BYTES = 64 * 1024;
// Gateway reason codes (GatewaySafeControlReason raw values).
const PASSKEY_EXPIRED_REASON = 'passkey_expired';
const LOCK_CODES = ['passkey_locked', PASSKEY_EXPIRED_REASON];
const PASSKEY_FAILURE_CODES = {
  staleCeremony: 'passkey_stale_ceremony',
  unavailable: 'passkey_unavailable',
  authenticationFailure: 'authentication_failed',
};
// Trusted user input that counts as foreground activity. Scrolling alone does not:
// the page scrolls itself while rendering.
const ACTIVITY_EVENTS = ['keydown', 'input', 'change', 'click', 'touchstart', 'wheel'];
const UNCERTAIN_ACTION_TEXT = 'An action sent before access was checked again may have completed. '
  + 'Check the refreshed session before trying it again.';
const monotonicNow = () => performance.now();

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
  transcriptOlderRequest: null, // the in-flight "Load earlier messages" request
  transcriptStart: null,
  transcriptLiveStart: null,
  transcriptTotal: null, // total_turns from the last newest page
  transcriptOlderText: '',
  transcriptLiveText: '',
  transcriptBrowsing: false,
  lastSeqBySession: new Map(),
  questionInputs: null, // structured question form controls for the shown interaction
  // Passkey access. `access` is the latest authoritative metadata from hello_ack or
  // lock_state (null: unknown, so content stays hidden); `accessKey` identifies it
  // without the advisory reason and display deadline, so repeats are ignored.
  access: null,
  accessKey: null,
  // Session content (list, detail, transcript, questions) is shown only while true.
  contentOpen: false,
  // Bumped whenever protected content is cleared; async completions and timers that
  // started under an older value write nothing.
  accessGeneration: 0,
  // Content held closed until the access changes or a fresh hello: after Lock (the
  // lock frame is re-sent on reconnect) or a generic lock error.
  hold: null, // {key, resendLock}
  needsFreshHello: false, // content was hidden for the background; reconnect on return
  ceremony: null, // {kind, phase, ws, accessKey, initiatedAt, maxAge, publicKey, ceremonyId, stale}
  ceremonyNotice: '',
  ceremonyDoneKey: null, // access key when a ceremony completed; buttons wait for new metadata
  activitySentAt: 0,
  // Actions still awaiting their reply, and those whose outcome a lock or hidden page
  // made unknown (dropped again when their success or refusal arrives).
  actionsInFlight: new Set(),
  uncertainActions: new Set(),
  // Status text that only covers the wait for fresh options.
  noticeEndsWhenReady: false,
  // A failure notice kept through the one reconnect that follows a ceremony.
  keepNoticeOnHello: false,
  // Counts trips to the background; a socket remembers the count it was created under.
  hideSeq: 0,
  // Unsent drafts kept in page memory only across a lock: composer text by session,
  // question answers by session and exact interaction id.
  composerDrafts: new Map(),
  questionDrafts: new Map(),
  // The session whose composer and question form are still in the (possibly hidden)
  // detail view, including after Sessions cleared currentSessionId.
  detailSessionId: null,
  // Workspace chooser, page memory only (never stored or put in the URL). The ID is
  // the only selector sent; the name is protected display text cleared on lock.
  selectedWorkspaceId: null,
  selectedWorkspaceName: null,
  workspaceSelectedOnce: false, // a sole workspace is auto-selected only before any choice
  workspaceChoices: [],
  workspaceRetryReason: 'entry', // what the chooser's Retry repeats
  // Bumped by each discovery and choice: an older discovery reply does nothing.
  workspaceGeneration: 0,
  // Bumped by each list request: only the newest list reply is applied.
  listGeneration: 0,
  // The sessions list shows exactly these IDs, from the last accepted list reply.
  listedSessionIds: [],
  listLoaded: false, // true once a list reply for the current choice was accepted
  selectedWorkspaceShared: false, // the chosen name matched another choice when last known
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
  state.access = null;
  state.accessKey = null;
  state.contentOpen = false;
  state.accessGeneration += 1;
  state.hold = null;
  state.needsFreshHello = false;
  state.ceremony = null;
  setCeremonyNotice('');
  state.keepNoticeOnHello = false;
  state.ceremonyDoneKey = null;
  state.uncertainActions.clear();
  clearTimeout(detailRefreshTimer);
  detailRefreshTimer = null;
  clearTimeout(transcriptRefreshTimer);
  transcriptRefreshTimer = null;
  state.composerDrafts.clear();
  state.questionDrafts.clear();
  state.detailSessionId = null;
  clearCopyTimers();
  setActionStatus('');
  // Another build's or a forgotten pairing's workspace is not carried over.
  resetWorkspaceView(true);
  $('sessions-panel').classList.add('hidden');
  $('detail-panel').classList.add('hidden');
  hideDetailChrome();
  renderAccess();
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
  renderAccess();
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

// `expect` names a passkey reply ({type, kind}) the request is settled by instead of
// command_result; command_error settles any request.
function sendCommand(frame, expect) {
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
    state.pending.set(requestId, { resolve, reject, timer, ws, expect: expect || null });
    enqueueSignedSend(ws, complete).catch((error) => {
      if (settlePending(requestId)) reject(error);
    });
  });
}

async function connect() {
  if (state.ws || state.connecting) return;
  state.connecting = true;
  renderAccess();
  try {
    await openConnection();
  } finally {
    state.connecting = false;
    renderAccess();
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
  ws.hideSeq = state.hideSeq;
  ws.createdVisible = document.visibilityState === 'visible';
  state.ws = ws;
  $('connect-status').textContent = 'Connecting…';
  renderAccess();

  ws.onopen = () => {
    enqueueSignedSend(ws, { v: WIRE_VERSION, type: 'hello', payload: { ticket } })
      .catch((error) => logLine(`hello failed: ${error.message}`));
  };
  // Frames from a replaced or closed socket are dropped before any handling.
  ws.onmessage = (event) => {
    if (state.ws === ws) handleServerFrame(event.data);
  };
  ws.onclose = () => {
    rejectPendingFor(ws, 'Connection closed.');
    if (state.ws === ws) {
      state.connected = false;
      state.ws = null;
      setBadge('disconnected', 'err');
      $('connect-status').textContent = 'Disconnected.';
      $('push-button').disabled = true;
      if (protectsContent()) closeProtectedView();
      renderAccess();
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
  if (protectsContent()) closeProtectedView();
  renderAccess();
}

// Closes this socket and connects again for an authoritative hello.
function reconnectNow() {
  disconnect();
  connect();
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
      state.ceremonyDoneKey = null;
      // A failure notice that led to this reconnect stays readable.
      if (!state.keepNoticeOnHello) setCeremonyNotice('');
      state.keepNoticeOnHello = false;
      // A ceremony begun on an earlier connection can never complete on this one.
      if (state.ceremony && state.ceremony.ws !== state.ws) state.ceremony = null;
      // Missing, malformed or inconsistent access metadata keeps content hidden.
      const access = normalizeAccess(payload.access);
      const consistent = access && (typeof payload.locked !== 'boolean' || payload.locked === access.locked);
      applyAccess(consistent ? access : null, true);
      break;
    }
    case 'lock_state':
      // The payload is the access object itself. It may arrive before hello_ack.
      applyAccess(normalizeAccess(frame.payload), false);
      break;
    case 'passkey_challenge':
    case 'passkey_ceremony_complete': {
      // Settles only the begin or complete request it answers, with the expected kind.
      const pending = frame.request_id ? settlePending(frame.request_id) : null;
      if (!pending) break;
      const payload = frame.payload || {};
      const expect = pending.expect;
      if (expect && expect.type === frame.type && payload.kind === expect.kind) {
        pending.resolve(payload);
      } else {
        pending.reject(commandError({ code: 'protocol_error', message: 'Unexpected passkey reply.' }));
      }
      break;
    }
    case 'command_result':
    case 'command_error': {
      const pending = frame.request_id ? settlePending(frame.request_id) : null;
      const isError = frame.type === 'command_error';
      const code = frame.payload && frame.payload.code;
      if (isError && LOCK_CODES.includes(code)) handleLockError();
      // Only the sessions-list flow opens the workspace chooser; an error from any other
      // command never navigates there.
      if (pending) {
        if (isError) {
          pending.reject(commandError(frame.payload));
        } else if (pending.expect) {
          pending.reject(commandError({ code: 'protocol_error', message: 'Unexpected reply.' }));
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
      if (!state.contentOpen) break;
      if (frame.session_id && admitsSessionFrame(frame.session_id)) {
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
      if (!state.contentOpen) break;
      if (frame.session_id && admitsSessionFrame(frame.session_id)) {
        // interaction_resolved consumes the same per-session seq stream as
        // updates/terminal frames; track it so the next snapshot does not look
        // like a missed update and trigger a spurious get_log catch-up.
        detectSeqGap(frame);
        if (frame.session_id === state.currentSessionId) scheduleDetailRefresh();
      }
      break;
    }
    case 'session_expired': {
      if (!state.contentOpen) break;
      if (frame.session_id && admitsSessionFrame(frame.session_id)) {
        bumpRevision(frame.session_id);
        state.sessions.delete(frame.session_id);
        state.listedSessionIds = state.listedSessionIds.filter((id) => id !== frame.session_id);
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

// Watch frames still arrive for sessions observed earlier (another workspace, another
// tab of this device). Only the listed sessions and the open session take them; they
// never add a session to the list.
function admitsSessionFrame(sessionId) {
  return sessionId === state.currentSessionId || state.listedSessionIds.includes(sessionId);
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
// Sessions list (scoped to the workspace chosen on this page)

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

// Back and Stop live in the header and show only with the session detail view.
function hideDetailChrome() {
  $('back-to-sessions').classList.add('hidden');
  $('stop-button').classList.add('hidden');
}

function showSessionsList() {
  // Text typed in the session being left comes back when it is reopened, as across a lock.
  if (state.contentOpen) snapshotDrafts();
  state.viewGeneration += 1;
  state.currentSessionId = null;
  state.deepLinkSessionId = null;
  $('detail-panel').classList.add('hidden');
  hideDetailChrome();
  $('sessions-panel').classList.remove('hidden');
  renderWorkspaceLabel();
  renderSessions();
  // Entry always rereads the open workspaces; a remembered choice still open is kept.
  discoverWorkspaces('entry');
}

// Errors meaning the chosen workspace is no longer open (or no longer routable):
// the choice is cleared and the open workspaces are read again once.
const WORKSPACE_GONE_CODES = ['workspace_not_open', 'workspace_mismatch', 'binding_required'];
const DISCOVERY_ERROR_TEXT = 'Open workspaces are unavailable. Retry.';
const NO_WORKSPACE_TEXT = 'No open workspace is available. Open one on your Mac, then retry.';
// A gateway build without workspace discovery answers with unsupported_frame_type.
const OUTDATED_TEXT = 'This page and the gateway are different versions. Reload this page, or update and restart the gateway.';
const LIST_ERROR_TEXT = 'Sessions are unavailable. Retry.';

function compareText(a, b) {
  if (a < b) return -1;
  return a > b ? 1 : 0;
}

// One choice per workspace ID from a fresh `windows` reply. Rows without an ID are not
// choices. The first name in window order wins; a missing or repeated name gets a
// short ID suffix, while the full ID stays the value.
function normalizeWorkspaceChoices(windows) {
  const order = (row) => (Number.isFinite(row.window_id) ? row.window_id : Number.MAX_SAFE_INTEGER);
  const rows = (Array.isArray(windows) ? windows : [])
    .filter((row) => row && typeof row === 'object')
    .sort((a, b) => order(a) - order(b));
  const byId = new Map();
  for (const row of rows) {
    const id = typeof row.workspace_id === 'string' ? row.workspace_id.trim() : '';
    if (!id) continue;
    const name = typeof row.workspace_name === 'string' ? row.workspace_name.trim() : '';
    const existing = byId.get(id);
    if (!existing) byId.set(id, { id, name });
    else if (!existing.name && name) existing.name = name;
  }
  const choices = [...byId.values()];
  const nameCounts = new Map();
  for (const choice of choices) nameCounts.set(choice.name, (nameCounts.get(choice.name) || 0) + 1);
  for (const choice of choices) {
    choice.label = choice.name && nameCounts.get(choice.name) === 1
      ? choice.name
      : `${choice.name || 'Workspace'} (${shortID(choice.id)})`;
  }
  return choices.sort((a, b) => compareText(a.name, b.name) || compareText(a.id, b.id));
}

// `reason`: 'entry' (sessions list shown), 'switch' (Switch workspace: always show the
// choices) or 'recover' (the chosen workspace closed: show the choices, never auto-pick).
async function discoverWorkspaces(reason) {
  if (!state.contentOpen) return;
  state.workspaceGeneration += 1;
  const generation = state.workspaceGeneration;
  const accessGeneration = state.accessGeneration;
  // Opening a session (or any view change) makes this discovery stale: it must never put
  // the chooser over the session detail.
  const viewGeneration = state.viewGeneration;
  const ws = state.ws;
  const current = () => state.contentOpen && state.ws === ws && viewIsCurrent(viewGeneration)
    && state.workspaceGeneration === generation && state.accessGeneration === accessGeneration;
  if (reason !== 'entry') {
    // Earlier choices may be stale (recover: one just closed); none is offered until
    // the fresh read answers.
    state.workspaceChoices = [];
    showWorkspaceChooser('Looking for open workspaces…', false);
  }
  let result;
  try {
    result = await sendCommand({ type: 'list_workspaces', payload: {} });
  } catch (error) {
    if (!current()) {
      // The socket closed under this still-newest discovery (no lock cleanup, as with
      // protection off): its "Looking…" chooser must not stay up. A newer discovery
      // owns the chooser and is left alone.
      if (state.workspaceGeneration === generation && state.ws !== ws) hideWorkspaceChooser();
      return;
    }
    // A failed Switch keeps the current choice and list; entry stays without a list.
    state.workspaceChoices = [];
    state.workspaceRetryReason = reason === 'switch' ? 'switch' : 'entry';
    const text = error.code === 'unsupported_frame_type' ? OUTDATED_TEXT : DISCOVERY_ERROR_TEXT;
    if (reason !== 'switch') {
      state.listedSessionIds = [];
      state.listLoaded = false;
      state.listGeneration += 1;
      renderSessions();
      setSessionsStatus(text, 'err');
    }
    showWorkspaceChooser(text, true);
    logLine(`list_workspaces failed: ${error.code || 'error'}`);
    return;
  }
  if (!current()) return;
  const choices = normalizeWorkspaceChoices(result && result.windows);
  state.workspaceChoices = choices;
  state.workspaceRetryReason = reason === 'switch' ? 'switch' : 'entry';
  const remembered = choices.find((choice) => choice.id === state.selectedWorkspaceId);
  if (reason === 'entry' && remembered) {
    state.selectedWorkspaceName = remembered.name;
    hideWorkspaceChooser();
    renderWorkspaceLabel();
    refreshSessions();
    return;
  }
  if (reason === 'entry' && state.selectedWorkspaceId && !remembered) {
    // The remembered workspace closed: never silently list a different one.
    clearWorkspaceSelection();
  }
  if (reason === 'entry' && !state.workspaceSelectedOnce && choices.length === 1) {
    chooseWorkspace(choices[0]);
    return;
  }
  showWorkspaceChooser(choices.length ? '' : NO_WORKSPACE_TEXT, !choices.length);
}

function clearWorkspaceSelection() {
  state.selectedWorkspaceId = null;
  state.selectedWorkspaceName = null;
  state.selectedWorkspaceShared = false;
  state.listedSessionIds = [];
  state.listLoaded = false;
  state.listGeneration += 1;
  renderWorkspaceLabel();
  renderSessions();
}

// Choosing only changes what this page lists: nothing is opened, focused or bound on
// the Mac, and no session is unsubscribed.
function chooseWorkspace(choice) {
  if (!state.contentOpen) return;
  state.workspaceGeneration += 1;
  state.selectedWorkspaceId = choice.id;
  state.selectedWorkspaceName = choice.name;
  state.workspaceSelectedOnce = true;
  state.listedSessionIds = [];
  state.listLoaded = false;
  hideWorkspaceChooser();
  renderWorkspaceLabel();
  renderSessions();
  refreshSessions();
}

function showWorkspaceChooser(status, retry) {
  const list = $('workspace-choices');
  list.replaceChildren();
  const generation = state.workspaceGeneration;
  for (const choice of state.workspaceChoices) {
    const item = element('li');
    const row = element('button', 'session-row');
    row.type = 'button';
    row.dataset.workspaceId = choice.id;
    const name = element('span', 'name', choice.label);
    const badge = element('span', 'badge', choice.id === state.selectedWorkspaceId ? 'current' : '');
    const chevron = element('span', 'chevron', '›');
    chevron.setAttribute('aria-hidden', 'true');
    row.append(name, badge, chevron);
    row.onclick = () => {
      if (state.workspaceGeneration === generation) chooseWorkspace(choice);
    };
    item.appendChild(row);
    list.appendChild(item);
  }
  $('workspace-chooser-status').textContent = status || '';
  $('workspace-retry').classList.toggle('hidden', !retry);
  $('binding-overlay').classList.remove('hidden');
}

function hideWorkspaceChooser() {
  $('binding-overlay').classList.add('hidden');
}

// The chosen workspace's name, with a short ID when it is missing or another open
// workspace has the same name, as in the chooser. While a Switch has cleared the
// choices, the answer from the last known choices is kept.
function workspaceDisplayName(id, name) {
  if (state.workspaceChoices.length) {
    state.selectedWorkspaceShared = state.workspaceChoices.some((choice) => choice.id !== id && choice.name === name);
  }
  return name && !state.selectedWorkspaceShared ? name : `${name || 'Workspace'} (${shortID(id)})`;
}

function renderWorkspaceLabel() {
  const id = state.selectedWorkspaceId;
  $('workspace-label').textContent = id && state.contentOpen
    ? `Workspace: ${workspaceDisplayName(id, state.selectedWorkspaceName)}`
    : '';
}

// Clears the chooser and list from the page. Lock keeps the opaque chosen ID for a
// fresh check after unlock; a reset identity (Forget pairing, another build) drops it.
function resetWorkspaceView(forgetChoice) {
  state.workspaceGeneration += 1;
  state.listGeneration += 1;
  state.selectedWorkspaceName = null;
  state.selectedWorkspaceShared = false;
  state.workspaceChoices = [];
  state.listedSessionIds = [];
  state.listLoaded = false;
  if (forgetChoice) {
    state.selectedWorkspaceId = null;
    state.workspaceSelectedOnce = false;
  }
  $('workspace-choices').replaceChildren();
  for (const id of ['workspace-label', 'workspace-chooser-status', 'sessions-status']) $(id).textContent = '';
  hideWorkspaceChooser();
}

function setSessionsStatus(text, kind) {
  const status = $('sessions-status');
  status.textContent = text || '';
  status.classList.toggle('err', kind === 'err');
}

async function refreshSessions() {
  if (!state.contentOpen) return;
  const workspaceId = state.selectedWorkspaceId;
  if (!workspaceId) {
    discoverWorkspaces('entry');
    return;
  }
  state.listGeneration += 1;
  const generation = state.listGeneration;
  const accessGeneration = state.accessGeneration;
  // A list answered after the owner opened a session neither renders nor starts recovery;
  // returning to Sessions lists again.
  const viewGeneration = state.viewGeneration;
  const ws = state.ws;
  // A watch update or expiry during the request is newer than this list's snapshot.
  const revisions = new Map(state.revisionBySession);
  const current = () => state.ws === ws && state.listGeneration === generation && viewIsCurrent(viewGeneration)
    && state.accessGeneration === accessGeneration && state.selectedWorkspaceId === workspaceId;
  setSessionsStatus('');
  let result;
  try {
    result = await sendCommand({ type: 'list_sessions', payload: { workspace_id: workspaceId, limit: 50 } });
  } catch (error) {
    // A list answered after a lock, a newer list or another choice changes nothing.
    if (!current()) return;
    logLine(`list_sessions failed: ${error.code || 'error'}`);
    if (WORKSPACE_GONE_CODES.includes(error.code)) {
      clearWorkspaceSelection();
      discoverWorkspaces('recover');
      return;
    }
    setSessionsStatus(LIST_ERROR_TEXT, 'err');
    return;
  }
  if (!current()) return;
  const items = result.sessions || result.items || (Array.isArray(result) ? result : []);
  const ids = [];
  for (const item of items) {
    const sessionId = item && (item.session_id || item.id);
    if (typeof sessionId !== 'string' || !sessionId || ids.includes(sessionId)) continue;
    if ((state.revisionBySession.get(sessionId) || 0) !== (revisions.get(sessionId) || 0)) {
      // Expired while the list was in flight: not listed again.
      if (!state.sessions.has(sessionId)) continue;
    } else {
      state.sessions.set(sessionId, item);
    }
    ids.push(sessionId);
  }
  // The accepted reply replaces the list; it never adds to an earlier one.
  state.listedSessionIds = ids;
  state.listLoaded = true;
  const workspace = result.workspace;
  if (workspace && workspace.id === workspaceId && typeof workspace.name === 'string' && workspace.name.trim()) {
    state.selectedWorkspaceName = workspace.name.trim();
  }
  renderWorkspaceLabel();
  renderSessions();
  if (ids.length) {
    await sendCommand({ type: 'subscribe', payload: { session_ids: ids } }).catch(() => {});
  }
}

function renderSessions() {
  const list = $('sessions-list');
  list.replaceChildren();
  if (!state.contentOpen) return;
  const ids = state.listedSessionIds;
  if (!ids.length) {
    // Empty only after an accepted reply; before one (loading or failed) nothing is claimed.
    let text = 'Choose a workspace to list its sessions.';
    if (state.selectedWorkspaceId) text = state.listLoaded ? 'No sessions in this workspace.' : 'Sessions not loaded yet.';
    list.appendChild(element('li', 'empty', text));
    return;
  }
  for (const sessionId of ids) {
    const payload = state.sessions.get(sessionId);
    const item = element('li');
    const row = element('button', 'session-row');
    row.type = 'button';
    const name = element('span', 'name', sessionName(payload, sessionId));
    const status = element('span', 'badge', sessionStatus(payload));
    if (sessionStatus(payload) === 'waiting_for_input') status.classList.add('warn');
    const chevron = element('span', 'chevron', '›');
    chevron.setAttribute('aria-hidden', 'true');
    row.append(name, status, chevron);
    row.onclick = () => openSession(sessionId);
    item.appendChild(row);
    list.appendChild(item);
  }
}

// ---------------------------------------------------------------------------
// Session detail: transcript pager + answer / steer / follow up / stop

async function openSession(sessionId) {
  const switching = state.currentSessionId !== sessionId;
  if (switching) state.viewGeneration += 1;
  const generation = state.viewGeneration;
  const accessGeneration = state.accessGeneration;
  state.currentSessionId = sessionId;
  state.detailSessionId = sessionId;
  $('sessions-panel').classList.add('hidden');
  $('detail-panel').classList.remove('hidden');
  $('back-to-sessions').classList.remove('hidden');
  $('detail-session-id').textContent = shortID(sessionId);
  if (switching) {
    resetTranscriptView();
    // An unsent draft kept across a lock comes back exactly as typed; nothing is sent.
    const kept = state.composerDrafts.get(sessionId);
    state.composerDrafts.delete(sessionId);
    $('composer-input').value = kept === undefined ? '' : kept;
    sizeComposer();
    setActionStatus('');
  }
  renderSessionDetail();
  try {
    // Subscribe to this session directly; it does not need to be in the chosen
    // workspace's sessions list.
    await sendCommand({ type: 'subscribe', session_id: sessionId });
  } catch (error) {
    if (viewIsCurrent(generation)) setActionStatus(error.message, 'err');
    if (state.accessGeneration === accessGeneration) logLine(`subscribe failed: ${error.code || error.message}`);
  }
  if (!viewIsCurrent(generation)) return;
  await pollSession(sessionId);
  if (!viewIsCurrent(generation)) return;
  // Reopening the same session (for example after a reconnect) keeps pages already
  // loaded with "Load earlier messages"; Refresh returns to the newest output.
  if (!switching && state.transcriptBrowsing) return;
  await loadTranscript();
}

async function pollSession(sessionId) {
  const target = sessionId || state.currentSessionId;
  if (!target) return null;
  const generation = state.viewGeneration;
  const accessGeneration = state.accessGeneration;
  const revision = state.revisionBySession.get(target) || 0;
  try {
    const snapshot = await sendCommand({ type: 'poll', session_id: target });
    if (state.accessGeneration !== accessGeneration) return null;
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
    if (state.accessGeneration !== accessGeneration) return null;
    if (target === state.currentSessionId && viewIsCurrent(generation)) setActionStatus(error.message, 'err');
    logLine(`poll failed: ${error.code || error.message}`);
    return null;
  }
}

let detailRefreshTimer = null;
function scheduleDetailRefresh() {
  if (detailRefreshTimer) return;
  const accessGeneration = state.accessGeneration;
  const timer = setTimeout(() => {
    if (detailRefreshTimer === timer) detailRefreshTimer = null;
    if (state.accessGeneration !== accessGeneration) return;
    pollSession();
    maybeRefreshTranscript();
  }, 750);
  detailRefreshTimer = timer;
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
  const wasHidden = composer.classList.contains('hidden');
  composer.classList.toggle('hidden', !(active || idle));
  // A kept draft is measured again once the composer is shown.
  if (wasHidden && (active || idle)) sizeComposer();
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
    restoreQuestionDraft(state.currentSessionId, interactionId);
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
  // get_log returns the page as transcript_xml text; see segmentTranscript().
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

// ---------------------------------------------------------------------------
// Transcript presentation
//
// get_log's transcript_xml looks like XML but is not: role bodies and tool arguments
// are written unescaped, so it is never handed to a parser. segmentTranscript() is a
// conservative forward line scan that recognizes only the serializer's own record
// lines and keeps every other line as visible text. Concatenating the segments' raw
// text reproduces the input exactly; the exact text also stays in "Raw transcript".
// Exact protocol-shaped text outside a code fence is ambiguous and can be attributed
// to the wrong record; nothing is decoded or dropped.

const ROW_ATTRIBUTES = '((?: id="[0-9A-Fa-f-]{36}")?(?: ts="\\d+(?:\\.\\d+)?")?)';
const ROLE_OPEN = new RegExp(`^<(user|assistant|system|error|note)${ROW_ATTRIBUTES}>`);
const TOOL_OPEN = new RegExp(`^<tool_call name="([^"]*)"${ROW_ATTRIBUTES}(/?)>`);
const TOOL_RESULT = /^<tool_result name="([^"]*)" status="(success|warning|failed)"\/>$/;
const FENCE_OPEN = /^ {0,3}(`{3,})([^`]*)$/;
const FENCE_CLOSE = /^ {0,3}(`{3,})[ \t]*$/;
const TOOL_CLOSE = '</tool_call>';
const ROLE_LABELS = { user: 'You', assistant: 'Agent', system: 'System', error: 'Error', note: 'Note' };

function isWrapperLine(line) {
  return line === '<transcript>' || line === '</transcript>';
}

// A tool call line the scan recognizes: an opening tag, or a self-closing tag that is
// the whole line.
function toolOpening(line) {
  const match = TOOL_OPEN.exec(line);
  return match && (match[3] !== '/' || line === match[0]) ? match : null;
}

function isRecordBoundary(line) {
  return isWrapperLine(line) || ROLE_OPEN.test(line) || Boolean(toolOpening(line)) || TOOL_RESULT.test(line);
}

function closesFence(text, length) {
  const match = FENCE_CLOSE.exec(text);
  return Boolean(match) && match[1].length >= length;
}

// Backtick fence state after `text`: the open fence's length, or 0 outside a fence.
function nextFence(fence, text) {
  if (fence) return closesFence(text, fence) ? 0 : fence;
  const open = FENCE_OPEN.exec(text);
  return open ? open[1].length : 0;
}

// Serializer attribute escapes, with &amp; last. Bodies are never decoded.
function decodeAttribute(text) {
  return text.replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}

// Finds the line that closes a record opened on line `start` (`first` is the body text
// after the opening tag). A closing line ends with `close` and is followed by another
// record line or the end of input. A candidate inside a fenced code example in the body
// is not structural. Returns {end}, or on failure the first unfenced-rule candidate
// (`naive`, -1 when none) and the line where the scan stopped (`stop`).
// A fenced example and a body cut off inside a fence look the same line by line. The
// serializer cuts only grouped system summaries and tool arguments (`truncated`), so
// there a fence-hidden candidate ends the scan: the record is shown as raw text up to
// that candidate and later records are scanned normally, never swallowed. Other bodies
// are written whole, so a candidate hidden by a fence is body text; the record is still
// uncertain until a later close outside the fence. That scan stops at the end of the
// page, at the next record line after the fence closes, at a later opening line of the
// same record type (which may own any later close: an interrupted body's unclosed fence
// must not swallow later records), or when the shared `budget` for uncertain scans runs
// out; the caller then shows the record up to its first candidate as raw text.
function findRecordClose(lines, start, first, close, budget, truncated) {
  let fence = 0;
  let naive = -1;
  for (let j = start; j < lines.length; j += 1) {
    const text = j === start ? first : lines[j];
    if (j > start && lines[j] === '</transcript>'
      && (j + 1 === lines.length || lines[j + 1] === '<transcript>'
        || (j + 2 === lines.length && lines[j + 1] === ''))) {
      return { end: -1, naive, stop: j };
    }
    if (naive >= 0) {
      budget.left -= 1;
      const open = ROLE_OPEN.exec(lines[j]);
      if (budget.left < 0 || (!fence && isRecordBoundary(lines[j])) || (open && `</${open[1]}>` === close)) {
        return { end: -1, naive, stop: j };
      }
    }
    if (text.endsWith(close)) {
      const next = j + 1;
      const atEnd = next === lines.length || (next === lines.length - 1 && lines[next] === '');
      if (atEnd || isRecordBoundary(lines[next])) {
        if (!fence || closesFence(text.slice(0, text.length - close.length), fence)) return { end: j };
        if (truncated) return { end: -1, naive: j, stop: j + 1 };
        if (naive < 0) naive = j;
      }
    }
    fence = nextFence(fence, text);
  }
  return { end: -1, naive, stop: lines.length };
}

// Pure: raw page text -> [{kind, raw, body?, name?, args?, status?}]. Kinds: wrapper and
// space (not displayed), user, assistant, system, error, note, tool, result (a result
// without its call) and raw (unrecognized or uncertain text, shown verbatim).
function segmentTranscript(raw) {
  if (!raw) return [];
  const lines = raw.split('\n');
  const segments = [];
  const budget = { left: lines.length * 2 + 1024 };
  const sourceOf = (from, to) => lines.slice(from, to).join('\n') + (to < lines.length ? '\n' : '');
  let loose = -1; // first line of pending unrecognized text
  const flushLoose = (to) => {
    if (loose < 0) return;
    const text = sourceOf(loose, to);
    if (text) segments.push({ kind: text.trim() ? 'raw' : 'space', raw: text });
    loose = -1;
  };
  const keepLoose = (from) => {
    if (loose < 0) loose = from;
  };
  // Closes a record or keeps uncertain source visible; returns the next line to scan.
  const closeRecord = (i, openLength, close, build) => {
    const truncated = close === '</system>' || close === TOOL_CLOSE;
    const found = findRecordClose(lines, i, lines[i].slice(openLength), close, budget, truncated);
    if (found.end < 0) {
      keepLoose(i);
      return found.naive >= 0 ? found.naive + 1 : found.stop;
    }
    const text = lines.slice(i, found.end + 1).join('\n');
    flushLoose(i);
    build(text.slice(openLength, text.length - close.length), found.end);
    return found.end + 1;
  };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isWrapperLine(line)) {
      flushLoose(i);
      segments.push({ kind: 'wrapper', raw: sourceOf(i, i + 1) });
      i += 1;
      continue;
    }
    const role = ROLE_OPEN.exec(line);
    if (role) {
      const kind = role[1];
      i = closeRecord(i, role[0].length, `</${kind}>`, (body, end) => {
        segments.push({ kind, raw: sourceOf(i, end + 1), body });
      });
      continue;
    }
    const tool = toolOpening(line);
    if (tool) {
      const start = i;
      const pushTool = (args, end) => {
        let last = end;
        let status = null;
        const result = last + 1 < lines.length ? TOOL_RESULT.exec(lines[last + 1]) : null;
        if (result && result[1] === tool[1]) {
          status = result[2];
          last += 1;
        }
        segments.push({
          kind: 'tool', raw: sourceOf(start, last + 1), name: decodeAttribute(tool[1]), args: args || null, status,
        });
        return last + 1;
      };
      if (tool[3] === '/') {
        flushLoose(i);
        i = pushTool(null, i);
      } else {
        let afterTool = -1;
        const next = closeRecord(i, tool[0].length, TOOL_CLOSE, (args, end) => {
          afterTool = pushTool(args, end);
        });
        i = afterTool >= 0 ? afterTool : next;
      }
      continue;
    }
    const result = TOOL_RESULT.exec(line);
    if (result) {
      flushLoose(i);
      segments.push({ kind: 'result', raw: sourceOf(i, i + 1), name: decodeAttribute(result[1]), status: result[2] });
      i += 1;
      continue;
    }
    keepLoose(i);
    i += 1;
  }
  flushLoose(lines.length);
  return segments;
}

function isDisplayedSegment(segment) {
  return segment.kind !== 'wrapper' && segment.kind !== 'space';
}

function trimBlankEdges(text) {
  return text.replace(/^(?:[ \t]*\n)+/, '').replace(/(?:\n[ \t]*)+$/, '');
}

// Basic Markdown, built with DOM nodes and text only: paragraphs (line breaks kept),
// ATX headings, bullet and numbered lists (nested by indentation), `code` spans,
// **strong** / __strong__ and *em* / _em_ (not inside words). Everything else, such as
// links, images, quotes, tables, rules and HTML, stays literal text.
const MD_HEADING = /^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/;
const MD_ITEM = /^( *)(?:([-*+])|(\d{1,9})[.)])[ \t]+(.*)$/;
const MD_RULE = /^ {0,3}([-*_])[ \t]*(?:\1[ \t]*){2,}$/;
// Emphasis text: complete single-backtick code spans count as whole units and no other
// backtick may appear, so emphasis never opens or closes inside code. `excluded` is the
// emphasis delimiter when it may not appear in its own text.
const MD_SPAN = '`[^`\\n]+`';
const mdEmphasisText = (excluded) => `((?:${MD_SPAN}|[^\`${excluded}\\n])*?(?:${MD_SPAN}|[^\`${excluded}\\s]))`;
const MD_INLINE = new RegExp([
  '(`+)([^`\\n](?:[^\\n]*?[^`\\n])??)\\1(?!`)', // 1 run, 2 code (shortest span first)
  `\\*\\*(?!\\s)${mdEmphasisText('')}\\*\\*`, // 3 strong
  `\\*(?!\\s)${mdEmphasisText('*')}\\*`, // 4 em
  `(^|[^A-Za-z0-9_])(__?)(?!\\s)${mdEmphasisText('_')}\\6(?![A-Za-z0-9_])`, // 5 prefix, 6 delimiter, 7 text
].join('|'), 'g');
// Inline markup never spans lines. A line longer than this stays literal, so a render
// never rescans an unusually long line for closing delimiters.
const MD_INLINE_MAX_LINE = 2000;

function appendInline(parent, text) {
  text.split('\n').forEach((line, index) => {
    if (index) parent.appendChild(document.createTextNode('\n'));
    if (line.length > MD_INLINE_MAX_LINE) {
      parent.appendChild(document.createTextNode(line));
    } else {
      appendInlineLine(parent, line);
    }
  });
}

function appendInlineLine(parent, text) {
  const pattern = new RegExp(MD_INLINE.source, 'g');
  let last = 0;
  let match;
  while ((match = pattern.exec(text))) {
    const start = match.index + (match[5] === undefined ? 0 : match[5].length);
    if (start > last) parent.appendChild(document.createTextNode(text.slice(last, start)));
    if (match[1]) {
      parent.appendChild(element('code', null, match[2]));
    } else {
      const strong = match[3] !== undefined || match[6] === '__';
      const node = element(strong ? 'strong' : 'em');
      appendInlineLine(node, match[3] !== undefined ? match[3] : match[4] !== undefined ? match[4] : match[7]);
      parent.appendChild(node);
    }
    last = match.index + match[0].length;
  }
  if (last < text.length) parent.appendChild(document.createTextNode(text.slice(last)));
}

function appendMarkdown(container, text) {
  let paragraph = [];
  // Open lists, outermost first: {indent, ordered, list, item, lines, contentIndent}.
  // Continuation lines lose indentation only up to their item's text column.
  const levels = [];
  const flushItem = (level) => {
    if (level.lines.length) appendInline(level.item, level.lines.join('\n'));
    level.lines = [];
  };
  const closeLists = () => {
    while (levels.length) flushItem(levels.pop());
  };
  const flushParagraph = () => {
    if (!paragraph.length) return;
    const node = element('p');
    appendInline(node, paragraph.join('\n'));
    container.appendChild(node);
    paragraph = [];
  };
  for (const line of text.split('\n')) {
    const heading = MD_HEADING.exec(line);
    const item = MD_RULE.test(line) ? null : MD_ITEM.exec(line);
    if (!line.trim()) {
      flushParagraph();
      closeLists();
    } else if (heading && heading[2]) {
      flushParagraph();
      closeLists();
      const node = element(`h${Math.min(6, heading[1].length + 2)}`);
      appendInline(node, heading[2]);
      container.appendChild(node);
    } else if (item && (levels.length || item[1].length <= 3)) {
      flushParagraph();
      const indent = item[1].length;
      const ordered = item[3] !== undefined;
      let top = levels[levels.length - 1];
      let parent = container;
      if (top && indent >= top.indent + 2) {
        flushItem(top);
        parent = top.item;
        top = null;
      } else {
        while (levels.length > 1 && indent < top.indent) {
          flushItem(levels.pop());
          top = levels[levels.length - 1];
        }
        if (top && top.ordered !== ordered) {
          flushItem(levels.pop());
          parent = levels.length ? levels[levels.length - 1].item : container;
          top = null;
        }
      }
      if (top) {
        flushItem(top);
      } else {
        const list = element(ordered ? 'ol' : 'ul');
        if (ordered && Number(item[3]) !== 1) list.start = Number(item[3]);
        parent.appendChild(list);
        top = { indent, ordered, list, item: null, lines: [] };
        levels.push(top);
      }
      top.item = element('li');
      top.list.appendChild(top.item);
      top.lines = [item[4]];
      top.contentIndent = line.length - item[4].length;
    } else if (levels.length) {
      const level = levels[levels.length - 1];
      const lead = /^ */.exec(line)[0].length;
      level.lines.push(line.slice(Math.min(lead, level.contentIndent)));
    } else {
      paragraph.push(line);
    }
  }
  flushParagraph();
  closeLists();
}

// A complete fenced block: language label, Copy, and the code scrolling sideways.
// Without clipboard access (a plain-HTTP origin, or a refused write) Copy selects the
// code for the system Copy menu instead and says Selected; when neither works it says
// Not copied. It never reports a copy that did not happen.
function codeBlock(language, text) {
  const block = element('div', 'code-block');
  const head = element('div', 'code-head');
  const copy = element('button', 'link code-copy');
  copy.type = 'button';
  const what = language ? `${language} code` : 'code';
  const show = (label) => {
    copy.textContent = label;
    copy.setAttribute('aria-label', `${label} (${what})`);
  };
  show('Copy');
  head.append(element('span', 'code-lang', language), copy);
  const code = element('code', null, text);
  const pre = element('pre', 'code');
  pre.appendChild(code);
  block.append(head, pre);
  let reset = null;
  copy.onclick = async () => {
    const accessGeneration = state.accessGeneration;
    let label = 'Copied';
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // Cleared by a lock while the clipboard was answering: nothing to select or label.
      if (state.accessGeneration !== accessGeneration) return;
      label = 'Not copied';
      try {
        const selection = window.getSelection();
        selection.selectAllChildren(code);
        if (selection.rangeCount > 0) label = 'Selected';
      } catch {
        // Neither copied nor selected.
      }
    }
    if (state.accessGeneration !== accessGeneration) return;
    show(label);
    clearTimeout(reset);
    copyResetTimers.delete(reset);
    const timer = setTimeout(() => {
      copyResetTimers.delete(timer);
      show('Copy');
    }, 1500);
    reset = timer;
    copyResetTimers.add(timer);
  };
  return block;
}

// Body text as basic Markdown prose plus complete backtick-fenced code blocks. An
// unmatched fence stays literal, together with the rest of the body.
function appendBody(container, text) {
  const lines = text.split('\n');
  let prose = [];
  const flushProse = () => {
    const chunk = trimBlankEdges(prose.join('\n'));
    prose = [];
    if (!chunk.trim()) return;
    const node = element('div', 'prose');
    appendMarkdown(node, chunk);
    container.appendChild(node);
  };
  let i = 0;
  while (i < lines.length) {
    const open = FENCE_OPEN.exec(lines[i]);
    if (open) {
      let end = i + 1;
      while (end < lines.length && !closesFence(lines[end], open[1].length)) end += 1;
      if (end === lines.length) {
        flushProse();
        const rest = trimBlankEdges(lines.slice(i).join('\n'));
        if (rest.trim()) container.appendChild(element('div', 'prose literal', rest));
        return;
      }
      flushProse();
      container.appendChild(codeBlock(open[2].trim(), lines.slice(i + 1, end).join('\n')));
      i = end + 1;
      continue;
    }
    prose.push(lines[i]);
    i += 1;
  }
  flushProse();
}

function appendToolSummary(container, label, segment) {
  container.appendChild(element('span', 'tool-label', label));
  container.appendChild(element('span', 'tool-name', segment.name));
  if (segment.status) container.appendChild(element('span', `tool-status ${segment.status}`, segment.status));
}

function transcriptNode(segment) {
  if (segment.kind === 'raw') return element('pre', 'msg raw', segment.raw.replace(/\n$/, ''));
  if (segment.kind === 'result') {
    const row = element('div', 'msg tool result');
    appendToolSummary(row, 'Result', segment);
    return row;
  }
  if (segment.kind === 'tool') {
    if (!segment.args) {
      const row = element('div', 'msg tool');
      appendToolSummary(row, 'Tool', segment);
      return row;
    }
    const details = element('details', 'msg tool');
    const summary = element('summary');
    appendToolSummary(summary, 'Tool', segment);
    details.append(summary, element('pre', 'tool-args', segment.args));
    return details;
  }
  const node = element('div', `msg ${segment.kind}`);
  node.appendChild(element('div', 'role', ROLE_LABELS[segment.kind]));
  const body = element('div', 'body');
  appendBody(body, segment.body);
  node.appendChild(body);
  return node;
}

// Render-owned state: the last rendered text, the turn it starts at, and its
// [{key, node}] entries in order. A node is kept only where its position establishes
// the same record occurrence, so an opened tool stays open, focus stays put, and the
// reading anchor never moves to an identical copy elsewhere.
const transcriptRender = { text: null, start: null, entries: [] };

function resetTranscriptRender() {
  transcriptRender.text = null;
  transcriptRender.start = null;
  transcriptRender.entries = [];
  $('transcript-view').replaceChildren();
}

// Pairs the previous render's nodes with new entries only where their position shows
// they are the same record occurrences:
// - the view still starts at the same turn (the newest page grew or was re-read in
//   place): entries at the same position from the start;
// - the view starts earlier and its text ends with the previous text (older pages were
//   prepended): entries at the same distance from the end.
// Every other change, in particular a start that moved forward (the newest window
// rolled, or Refresh dropped the older pages), gets fresh, closed nodes, even for
// identical text: get_log carries no row identities, so an evicted record and a new
// identical one cannot be told apart. Matching stops at the first difference.
function matchTranscriptNodes(previous, next, text, start) {
  const old = transcriptRender.text;
  const oldStart = transcriptRender.start;
  if (old === null || !previous.length) return;
  if (start === oldStart) {
    for (let a = 0; a < previous.length && a < next.length; a += 1) {
      if (previous[a].key !== next[a].key) break;
      next[a].node = previous[a].node;
    }
  } else if (start !== null && oldStart !== null && start < oldStart && text.endsWith(old)) {
    for (let a = previous.length - 1, b = next.length - 1; a >= 0 && b >= 0; a -= 1, b -= 1) {
      if (previous[a].key !== next[b].key) break;
      next[b].node = previous[a].node;
    }
  }
}

// A focused element that is hidden (for example the composer of a session view left
// behind) does not count.
function readerIsInteracting() {
  const active = document.activeElement;
  if (!active || active === document.body || !active.getClientRects().length) return false;
  if (['TEXTAREA', 'INPUT', 'SELECT'].includes(active.tagName) || active.isContentEditable) return true;
  return $('transcript-view').contains(active) || $('transcript-raw').contains(active);
}

// Measured before the DOM changes: whether the page is at its bottom, and an anchor
// to hold on screen. A focused, on-screen composer or question field is preferred, so
// the field being typed in stays put while output arrives above it; otherwise the
// first transcript block below the header that survives this render. Without either,
// the document position is kept.
function captureTranscriptScroll(kept) {
  const scroller = document.scrollingElement || document.documentElement;
  const snapshot = {
    scroller,
    scrollTop: scroller.scrollTop,
    nearBottom: scroller.scrollHeight - scroller.scrollTop - window.innerHeight < 48,
    anchor: null,
    anchorTop: 0,
  };
  const headerBottom = $('app-header').getBoundingClientRect().bottom;
  const active = document.activeElement;
  if (active && active !== document.body && readerIsInteracting()
    && ($('composer').contains(active) || $('interaction-box').contains(active))) {
    const rect = active.getBoundingClientRect();
    if (rect.bottom > headerBottom && rect.top < window.innerHeight) {
      snapshot.anchor = active;
      snapshot.anchorTop = rect.top;
      return snapshot;
    }
  }
  for (const entry of transcriptRender.entries) {
    if (!kept.has(entry.node)) continue;
    const rect = entry.node.getBoundingClientRect();
    if (rect.bottom > headerBottom) {
      snapshot.anchor = entry.node;
      snapshot.anchorTop = rect.top;
      break;
    }
  }
  return snapshot;
}

// Follows new output only when the reader was at the bottom and is not typing or
// using a disclosure; otherwise keeps the anchor where it was on screen, or else the
// document position. Unless the reader is typing or using a disclosure, the first
// records of a session view land on the newest output, or on the question when the
// agent is waiting for an answer.
function restoreTranscriptScroll(snapshot, follow, initial) {
  const { scroller } = snapshot;
  if (follow && (snapshot.nearBottom || initial) && !readerIsInteracting()) {
    const question = $('interaction-box');
    if (initial && !question.classList.contains('hidden')) {
      const headerBottom = $('app-header').getBoundingClientRect().bottom;
      scroller.scrollTop += question.getBoundingClientRect().top - headerBottom - 8;
    } else {
      scroller.scrollTop = scroller.scrollHeight;
    }
  } else if (snapshot.anchor && snapshot.anchor.isConnected) {
    const delta = snapshot.anchor.getBoundingClientRect().top - snapshot.anchorTop;
    if (delta) scroller.scrollTop += delta;
  } else {
    scroller.scrollTop = Math.min(snapshot.scrollTop, Math.max(0, scroller.scrollHeight - window.innerHeight));
  }
}

function planTranscriptView(text, start) {
  const previous = transcriptRender.entries;
  const next = [];
  for (const segment of segmentTranscript(text)) {
    if (!isDisplayedSegment(segment)) continue;
    next.push({ key: `${segment.kind}\u0000${segment.raw}`, node: null, segment });
  }
  if (!next.length) next.push({ key: 'empty', node: null, segment: null });
  matchTranscriptNodes(previous, next, text, start);
  return {
    text,
    start,
    previous,
    next,
    initial: !previous.some((entry) => entry.key !== 'empty'),
    kept: new Set(next.map((entry) => entry.node).filter(Boolean)),
  };
}

function applyTranscriptView(plan) {
  const view = $('transcript-view');
  for (const entry of plan.previous) {
    if (!plan.kept.has(entry.node)) entry.node.remove();
  }
  let cursor = view.firstChild;
  for (const entry of plan.next) {
    if (!entry.node) {
      entry.node = entry.segment
        ? transcriptNode(entry.segment)
        : element('p', 'transcript-empty', 'No messages to show yet.');
    }
    if (entry.node === cursor) {
      cursor = cursor.nextSibling;
    } else {
      view.insertBefore(entry.node, cursor);
    }
  }
  transcriptRender.entries = plan.next.map(({ key, node }) => ({ key, node }));
  transcriptRender.text = plan.text;
  transcriptRender.start = plan.start;
}

// Re-rendered when the text or its start turn changes; the start alone decides node
// reuse and whether "Load earlier messages" shows. Scroll is measured once before any
// layout write (paging button, raw text, records) and corrected once after all of them.
function renderTranscript(follow) {
  const text = [state.transcriptOlderText, state.transcriptLiveText].filter(Boolean).join('\n');
  const start = state.transcriptStart;
  const changed = text !== transcriptRender.text || start !== transcriptRender.start;
  const plan = changed ? planTranscriptView(text, start) : null;
  const scroll = plan ? captureTranscriptScroll(plan.kept) : null;
  // Shown only while older turns exist; disabled while one older page is loading.
  const hasOlder = start > 0;
  $('load-older').classList.toggle('hidden', !hasOlder);
  $('load-older').disabled = Boolean(state.transcriptOlderRequest) || !hasOlder;
  if (!plan) return;
  $('transcript').textContent = text;
  applyTranscriptView(plan);
  restoreTranscriptScroll(scroll, follow, plan.initial);
}

// Clears the transcript for a new session view, including its render-owned state.
function resetTranscriptView() {
  resetTranscriptRender();
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
  const accessGeneration = state.accessGeneration;
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
    if (state.accessGeneration === accessGeneration) logLine(`get_log failed: ${error.message}`);
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

// "Load earlier messages": fetches the turns just before the oldest shown turn, so the
// prepended range never overlaps the view. The window moves only after success; a
// failure leaves it in place for a retry.
async function loadOlderTranscript() {
  const sessionId = state.currentSessionId;
  const start = state.transcriptStart;
  if (!sessionId || state.transcriptOlderRequest || !(start > 0)) return;
  const generation = state.viewGeneration;
  const accessGeneration = state.accessGeneration;
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
    if (state.accessGeneration === accessGeneration) logLine(`get_log failed: ${error.message}`);
  } finally {
    if (state.transcriptOlderRequest === request) {
      state.transcriptOlderRequest = null;
      renderTranscript(false);
    }
  }
}

// Background refreshes reload the newest page only while no older pages are loaded;
// after "Load earlier messages", only the Refresh button resets the history.
let transcriptRefreshTimer = null;
function maybeRefreshTranscript() {
  if (transcriptRefreshTimer || state.transcriptBrowsing) return;
  const accessGeneration = state.accessGeneration;
  const timer = setTimeout(() => {
    if (transcriptRefreshTimer === timer) transcriptRefreshTimer = null;
    if (state.accessGeneration !== accessGeneration) return;
    if (state.transcriptBrowsing) return;
    loadTranscript();
  }, 750);
  transcriptRefreshTimer = timer;
}

// Top: the start of the loaded transcript ("Load earlier messages" while older turns
// exist) lands under the header; nothing is fetched. Latest: the end of the page, where
// new output is followed again. While older pages are loaded, Latest first returns to
// the newest page, as Refresh does, since background refresh is paused there.
function jumpToTranscriptTop() {
  const scroller = document.scrollingElement || document.documentElement;
  const loadOlder = $('load-older');
  const target = loadOlder.classList.contains('hidden') ? $('transcript-view').firstElementChild : loadOlder;
  if (!target) return;
  const headerBottom = $('app-header').getBoundingClientRect().bottom;
  scroller.scrollTop += target.getBoundingClientRect().top - headerBottom - 8;
}

function jumpToLatest() {
  const scroller = document.scrollingElement || document.documentElement;
  if (state.transcriptBrowsing) refreshTranscript();
  scroller.scrollTop = scroller.scrollHeight;
}

// Runs one phone action, shows the server's own error text on refusal, and
// refreshes the session afterwards so the view stays current.
// Completion writes go to the view only if it still shows the same session view the
// action started in.
async function runAction(button, pendingText, action) {
  const sessionId = state.currentSessionId;
  if (!sessionId) return;
  const generation = state.viewGeneration;
  const accessGeneration = state.accessGeneration;
  button.disabled = true;
  setActionStatus(pendingText);
  // An action still in flight when the page locks or hides has an unknown outcome until
  // its reply settles it; it is never sent again automatically.
  const token = {};
  state.actionsInFlight.add(token);
  try {
    const doneText = await action(sessionId, generation);
    state.uncertainActions.delete(token);
    if (viewIsCurrent(generation)) setActionStatus(doneText, 'ok');
  } catch (error) {
    // A refusal with its own code settled the action; a lock error or a lost
    // connection leaves it unknown.
    if (error.code && !LOCK_CODES.includes(error.code)) state.uncertainActions.delete(token);
    if (viewIsCurrent(generation)) setActionStatus(error.message, 'err');
    // Not written into a log cleared by a lock; the uncertain-action notice covers it.
    if (state.accessGeneration === accessGeneration) logLine(`${pendingText} failed: ${error.code || error.message}`);
  } finally {
    state.actionsInFlight.delete(token);
    button.disabled = false;
    if (!state.contentOpen) renderAccess();
    if (viewIsCurrent(generation) && state.connected) {
      await pollSession(sessionId);
      maybeRefreshTranscript();
    }
  }
}

// The composer grows with its text up to 40% of the viewport, then scrolls inside.
const COMPOSER_MIN_HEIGHT = 44;
// Measuring sets the height to auto for a moment, which can shorten the page; the
// scroll position is put back afterwards. A hidden composer is not measured.
function sizeComposer() {
  const input = $('composer-input');
  if (input.offsetParent === null) return;
  const scroller = document.scrollingElement || document.documentElement;
  const scrollTop = scroller.scrollTop;
  const border = input.offsetHeight - input.clientHeight;
  const max = Math.max(COMPOSER_MIN_HEIGHT, Math.round(window.innerHeight * 0.4));
  input.style.height = 'auto';
  const wanted = input.scrollHeight + border;
  input.style.height = `${Math.min(max, Math.max(COMPOSER_MIN_HEIGHT, wanted))}px`;
  input.style.overflowY = wanted > max ? 'auto' : 'hidden';
  // Only when measuring moved it: a redundant write can stop momentum scrolling.
  if (scroller.scrollTop !== scrollTop) scroller.scrollTop = scrollTop;
}

function respond() {
  return runAction($('respond-button'), 'Sending answer…', async (sessionId) => {
    const interactionId = $('interaction-box').dataset.interactionId;
    if (!state.questionInputs || !interactionId) throw new Error('Answer this on your Mac.');
    const payload = { interaction_id: interactionId, answers: collectAnswers() };
    await sendCommand({ type: 'respond', session_id: sessionId, payload });
    // Answers known to be sent are never put back from a kept draft.
    state.questionDrafts.delete(questionDraftKey(sessionId, interactionId));
    return 'Answer sent.';
  });
}

function sendComposer() {
  const button = $('composer-send');
  const verb = button.textContent;
  return runAction(button, `${verb}…`, async (sessionId) => {
    const input = $('composer-input');
    const draft = input.value;
    const message = draft.trim();
    if (!message) throw new Error('Type a message first.');
    await sendCommand({ type: 'steer', session_id: sessionId, payload: { message } });
    // Text known to be sent is never put back from a draft kept across a lock.
    if (state.composerDrafts.get(sessionId) === draft) state.composerDrafts.delete(sessionId);
    // Clear only the text that was sent, and only while this session's composer is in
    // the page: shown, kept behind the sessions list, or reopened (with its kept draft
    // restored) before the reply. Newer text stays; after a lock clears content
    // detailSessionId is null and nothing is touched.
    if (state.detailSessionId === sessionId && input.value === draft) {
      input.value = '';
      sizeComposer();
    }
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
// Passkey access
//
// The gateway decides access; this page only follows its latest hello_ack.access or
// lock_state metadata. Content shows only while that metadata allows it. Every way of
// losing access (Lock, lock_state, expiry, a generic lock error, a required-mode
// disconnect, going to the background) runs closeProtectedView(), which keeps unsent
// drafts in memory, clears content from the page and state, and advances the
// generations that every async completion and timer checks before writing.

const copyResetTimers = new Set();

function clearCopyTimers() {
  for (const timer of copyResetTimers) clearTimeout(timer);
  copyResetTimers.clear();
}

// Policy-off browsers keep the ordinary pairing-only behavior. Unknown access counts
// as protected.
function protectsContent() {
  return !(state.access && state.access.policy_state === 'off');
}

function normalizeAccess(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const counter = (value) => typeof value === 'string' && /^\d{1,20}$/.test(value);
  if (!['off', 'required', 'unprotected'].includes(raw.policy_state)) return null;
  if (typeof raw.locked !== 'boolean' || typeof raw.enrolled !== 'boolean') return null;
  if (typeof raw.enrollment_open !== 'boolean') return null;
  if (!counter(raw.epoch) || !counter(raw.lock_generation)) return null;
  if (raw.grant_id !== undefined && (typeof raw.grant_id !== 'string' || !raw.grant_id)) return null;
  return {
    policy_state: raw.policy_state,
    locked: raw.locked,
    enrolled: raw.enrolled,
    enrollment_open: raw.enrollment_open,
    epoch: raw.epoch,
    lock_generation: raw.lock_generation,
    grant_id: raw.grant_id || null,
    reason: typeof raw.reason === 'string' ? raw.reason : null,
  };
}

// The reason and the remaining lifetime are advisory, so they are not part of the key.
function accessKeyOf(access) {
  return [
    access.policy_state, access.locked, access.enrolled, access.enrollment_open,
    access.epoch, access.lock_generation, access.grant_id || '',
  ].join('|');
}

function accessAllowsContent(access) {
  if (!access || access.locked) return false;
  if (access.policy_state === 'required') return Boolean(access.grant_id);
  return access.policy_state === 'off' || access.policy_state === 'unprotected';
}

// Content stays sealed while the page is hidden, and after a return until a hello from
// a connection made in the foreground: metadata alone never shows it again.
function presentationSealed() {
  return document.visibilityState !== 'visible' || state.needsFreshHello;
}

// Applies authoritative metadata. A repeated lock_state with the same key changes
// nothing: no clearing, no new begin, no refetch. hello_ack is always re-evaluated.
function applyAccess(access, fromHello) {
  const key = access ? accessKeyOf(access) : null;
  if (!fromHello && access && key === state.accessKey) return;
  if (fromHello && document.visibilityState === 'visible') state.needsFreshHello = false;
  const changed = key !== state.accessKey;
  state.access = access;
  state.accessKey = key;
  if (state.hold) {
    if (!access || access.locked || key !== state.hold.key) {
      state.hold = null;
    } else if (fromHello) {
      // Still unlocked under the same grant after a reconnect: a Lock the gateway
      // may not have received is sent again; a held lock error is resolved by hello.
      if (state.hold.resendLock) sendLockFrame();
      else state.hold = null;
    }
  }
  if (changed) {
    invalidateCeremony();
    setCeremonyNotice('');
    state.ceremonyDoneKey = null;
  }
  if (!accessAllowsContent(access) || state.hold) {
    closeProtectedView();
  } else if (presentationSealed()) {
    // Access to reopen is confirmed again by a foreground hello; nothing is refetched now.
    if (state.contentOpen && protectsContent()) closeProtectedView();
    if (!state.contentOpen) state.needsFreshHello = true;
  } else if (state.connected) {
    if (!state.contentOpen) openProtectedView();
    else if (fromHello) reopenTarget();
  }
  renderAccess();
  maybePrefetchCeremony();
}

function reopenTarget() {
  const target = state.currentSessionId || state.deepLinkSessionId;
  if (target) {
    openSession(target);
  } else {
    showSessionsList();
  }
}

// Unlock refetches and resubscribes through the ordinary paths.
function openProtectedView() {
  state.contentOpen = true;
  state.needsFreshHello = false;
  setCeremonyNotice('');
  renderAccess();
  reopenTarget();
  if (state.uncertainActions.size > 0) {
    state.uncertainActions.clear();
    setActionStatus(UNCERTAIN_ACTION_TEXT, 'err');
    $('connect-status').textContent = UNCERTAIN_ACTION_TEXT;
  }
}

function questionDraftKey(sessionId, interactionId) {
  return `${sessionId}\u0000${interactionId}`;
}

// Raw values, exactly as left: partial and whitespace-only text, selections, skips.
function snapshotDrafts() {
  const sessionId = state.currentSessionId || state.detailSessionId;
  if (!sessionId) return;
  const draft = $('composer-input').value;
  if (draft) {
    state.composerDrafts.set(sessionId, draft);
  } else {
    state.composerDrafts.delete(sessionId);
  }
  const interactionId = $('interaction-box').dataset.interactionId;
  if (interactionId && state.questionInputs) {
    state.questionDrafts.set(questionDraftKey(sessionId, interactionId), state.questionInputs.map((question) => ({
      id: question.id,
      selected: question.optionInputs.filter((input) => input.checked).map((input) => input.value),
      custom: question.customInput ? question.customInput.value : null,
      skipped: question.skipInput.checked,
    })));
  }
}

// Called once a fresh question form was built: answers kept for this session and
// exact interaction id are put back. Nothing is submitted.
function restoreQuestionDraft(sessionId, interactionId) {
  const key = questionDraftKey(sessionId, interactionId);
  const saved = state.questionDrafts.get(key);
  if (!saved || !interactionId) return;
  state.questionDrafts.delete(key);
  (state.questionInputs || []).forEach((question, index) => {
    const entry = saved[index];
    if (!entry || entry.id !== question.id) return;
    for (const input of question.optionInputs) input.checked = entry.selected.includes(input.value);
    if (question.customInput && typeof entry.custom === 'string') question.customInput.value = entry.custom;
    question.skipInput.checked = entry.skipped;
    question.skipInput.onchange();
  });
}

// Clears every piece of session content from the page and from memory. Drafts are
// kept first, but only while content is shown, so a second transition cannot
// overwrite them with the already-cleared fields.
function closeProtectedView() {
  const wasOpen = state.contentOpen;
  if (wasOpen) {
    snapshotDrafts();
    for (const token of state.actionsInFlight) state.uncertainActions.add(token);
  }
  state.detailSessionId = null;
  state.contentOpen = false;
  state.accessGeneration += 1;
  state.viewGeneration += 1;
  // The target session (deep link or the one being read) is reopened after unlock.
  if (state.currentSessionId) state.deepLinkSessionId = state.currentSessionId;
  state.currentSessionId = null;
  clearTimeout(detailRefreshTimer);
  detailRefreshTimer = null;
  clearTimeout(transcriptRefreshTimer);
  transcriptRefreshTimer = null;
  clearCopyTimers();
  resetTranscriptView();
  state.sessions.clear();
  state.revisionBySession.clear();
  state.lastSeqBySession.clear();
  state.questionInputs = null;
  const box = $('interaction-box');
  box.classList.add('hidden');
  box.dataset.interactionId = '';
  for (const id of ['interaction-title', 'interaction-text', 'interaction-context']) $(id).textContent = '';
  $('question-form').replaceChildren();
  $('sessions-list').replaceChildren();
  // Workspace names and choices are protected; only the opaque chosen ID stays in
  // memory, to be checked against a fresh read after unlock.
  resetWorkspaceView(false);
  for (const id of ['detail-name', 'detail-status', 'detail-session-id']) $(id).textContent = '';
  $('composer-input').value = '';
  $('composer').classList.add('hidden');
  setActionStatus('');
  $('sessions-panel').classList.add('hidden');
  $('detail-panel').classList.add('hidden');
  hideDetailChrome();
  // The activity log names sessions and actions.
  if (wasOpen) $('log').textContent = '';
}

// A generic lock error for any request: content closes at once and stays closed
// until the gateway reports new access or a fresh hello.
function handleLockError() {
  if (!state.contentOpen) return;
  if (accessAllowsContent(state.access)) state.hold = { key: state.accessKey, resendLock: false };
  closeProtectedView();
  renderAccess();
}

// Lock clears this page first, then asks the gateway to lock every tab of this
// browser. The gateway's lock_state is what the page follows afterwards.
function lockNow() {
  const access = state.access;
  if (!state.contentOpen || !access || access.policy_state !== 'required') return;
  state.hold = { key: state.accessKey, resendLock: true };
  closeProtectedView();
  renderAccess();
  sendLockFrame();
}

function sendLockFrame() {
  const ws = state.ws;
  if (!ws || !state.connected || ws.readyState !== WebSocket.OPEN) return;
  enqueueSignedSend(ws, { v: WIRE_VERSION, type: 'lock' })
    .catch((error) => logLine(`lock not sent: ${error.message}`));
}

// Passkeys need the HTTPS page in a secure context with WebAuthn. There is no
// password, weaker user-verification or plain-HTTP fallback.
function passkeySupport() {
  if (location.protocol !== 'https:' || window.isSecureContext !== true) return 'insecure';
  const credentials = navigator.credentials;
  if (!credentials || typeof credentials.get !== 'function' || typeof credentials.create !== 'function'
    || typeof window.PublicKeyCredential === 'undefined') {
    return 'unsupported';
  }
  return 'ok';
}

function ceremonyKindFor(access) {
  if (!access || access.policy_state !== 'required' || !access.locked) return null;
  if (access.enrolled) return 'assertion';
  return access.enrollment_open ? 'registration' : null;
}

function requireText(value) {
  if (typeof value !== 'string' || !value) throw new Error('The passkey request was incomplete.');
  return value;
}

function optionsTimeout(publicKey, options) {
  if (typeof options.timeout === 'number' && options.timeout > 0) publicKey.timeout = options.timeout;
  return publicKey;
}

// The app's begin response (snake_case, base64url binary) to navigator.credentials.create().
function creationOptions(options) {
  const rp = options.rp || {};
  const user = options.user || {};
  const selection = options.authenticator_selection || {};
  const params = Array.isArray(options.pub_key_cred_params) ? options.pub_key_cred_params : [];
  if (selection.user_verification !== 'required' || !params.length) {
    throw new Error('The passkey request was incomplete.');
  }
  const authenticatorSelection = { userVerification: 'required' };
  if (typeof selection.resident_key === 'string') authenticatorSelection.residentKey = selection.resident_key;
  return optionsTimeout({
    challenge: base64ToBytes(requireText(options.challenge)),
    rp: { id: requireText(rp.id), name: requireText(rp.name) },
    user: {
      id: base64ToBytes(requireText(user.id)),
      name: requireText(user.name),
      displayName: requireText(user.display_name),
    },
    pubKeyCredParams: params.map((param) => {
      if (typeof param.alg !== 'number') throw new Error('The passkey request was incomplete.');
      return { type: requireText(param.type), alg: param.alg };
    }),
    authenticatorSelection,
    attestation: typeof options.attestation === 'string' ? options.attestation : 'none',
  }, options);
}

// The app's begin response to navigator.credentials.get().
function requestOptions(options) {
  const allowed = Array.isArray(options.allow_credentials) ? options.allow_credentials : [];
  if (options.user_verification !== 'required' || !allowed.length) {
    throw new Error('The passkey request was incomplete.');
  }
  return optionsTimeout({
    challenge: base64ToBytes(requireText(options.challenge)),
    rpId: requireText(options.rp_id),
    allowCredentials: allowed.map((entry) => ({ type: requireText(entry.type), id: base64ToBytes(requireText(entry.id)) })),
    userVerification: 'required',
  }, options);
}

function binaryToBase64URL(value) {
  if (value === null || value === undefined) return '';
  const bytes = ArrayBuffer.isView(value)
    ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
    : new Uint8Array(value);
  return bytesToBase64URL(bytes);
}

// The completed credential as the JSON string the app verifies, every binary value
// base64url; id and rawId are the same value.
function serializeCredential(kind, credential) {
  const unusable = 'This browser returned a passkey response that cannot be used.';
  if (!credential || credential.type !== 'public-key' || !credential.response) throw new Error(unusable);
  const rawId = binaryToBase64URL(credential.rawId);
  if (!rawId || (typeof credential.id === 'string' && credential.id !== rawId)) throw new Error(unusable);
  const response = credential.response;
  const fields = { clientDataJSON: binaryToBase64URL(response.clientDataJSON) };
  if (kind === 'registration') {
    fields.attestationObject = binaryToBase64URL(response.attestationObject);
  } else {
    fields.authenticatorData = binaryToBase64URL(response.authenticatorData);
    fields.signature = binaryToBase64URL(response.signature);
    const userHandle = binaryToBase64URL(response.userHandle);
    if (userHandle) fields.userHandle = userHandle;
  }
  if (Object.values(fields).some((value) => !value)) throw new Error(unusable);
  const json = JSON.stringify({ id: rawId, rawId, type: 'public-key', response: fields });
  if (utf8(json).length > CREDENTIAL_MAX_BYTES) throw new Error(unusable);
  return json;
}

function ceremonyBindingCurrent(entry) {
  return entry.ws === state.ws && entry.accessKey === state.accessKey && !entry.stale;
}

function ceremonyIsFresh(entry) {
  return monotonicNow() - entry.initiatedAt < entry.maxAge;
}

function setCeremonyNotice(text, endsWhenReady) {
  state.ceremonyNotice = text;
  state.noticeEndsWhenReady = Boolean(endsWhenReady);
}

// A socket created in the foreground since the last trip to the background, whose
// hello has not arrived yet: that hello is the fresh one, so the socket is kept.
function socketAwaitsForegroundHello() {
  const ws = state.ws;
  return Boolean(ws) && !state.connected && ws.createdVisible === true && ws.hideSeq === state.hideSeq;
}

// The app binds a ceremony to the connection that began it, so a native prompt or its
// complete keeps that socket open until it settles.
function ceremonyHoldsSocket() {
  const entry = state.ceremony;
  return Boolean(entry) && Boolean(state.ws) && entry.ws === state.ws
    && (entry.phase === 'native' || entry.phase === 'completing');
}

// After a ceremony settles: when its socket closed meanwhile, or it outlived a trip to the
// background, a fresh connection's hello decides what to show. Nothing is resent on it.
// `keepNotice` keeps a failure notice readable through that reconnect.
function followUpCeremony(keepNotice) {
  if (document.visibilityState === 'visible' && !ceremonyHoldsSocket()
    && (!state.ws || (state.needsFreshHello && !socketAwaitsForegroundHello()))) {
    state.keepNoticeOnHello = Boolean(keepNotice);
    if (state.ws) reconnectNow();
    else connect();
    return;
  }
  maybePrefetchCeremony();
}

// Options fetched under older access are not used. A begin or native prompt in
// progress finishes and is then discarded; a running complete is left to settle.
function invalidateCeremony() {
  const entry = state.ceremony;
  if (!entry) return;
  if (entry.phase === 'ready') {
    state.ceremony = null;
  } else if (entry.phase === 'fetching' || entry.phase === 'native') {
    entry.stale = true;
  }
}

// Fetches options for the shown Unlock or Set up button ahead of the tap. Only one
// ceremony runs at a time: no begin while another begin or a complete is outstanding.
function maybePrefetchCeremony() {
  const entry = state.ceremony;
  if (entry && entry.phase === 'ready' && !(ceremonyBindingCurrent(entry) && ceremonyIsFresh(entry))) {
    state.ceremony = null;
  }
  const kind = ceremonyKindFor(state.access);
  if (!kind || state.ceremony || state.hold || state.contentOpen) return;
  if (!state.ws || !state.connected || document.visibilityState !== 'visible') return;
  if (passkeySupport() !== 'ok' || state.ceremonyDoneKey === state.accessKey) return;
  prefetchCeremony(kind);
}

function prefetchCeremony(kind) {
  const entry = {
    kind,
    phase: 'fetching',
    ws: state.ws,
    accessKey: state.accessKey,
    // Freshness counts from the request, not from the reply.
    initiatedAt: monotonicNow(),
    maxAge: CEREMONY_CHALLENGE_LIFETIME_MS - CEREMONY_OPTIONS_MARGIN_MS,
    publicKey: null,
    ceremonyId: null,
    stale: false,
  };
  state.ceremony = entry;
  renderAccess();
  const type = kind === 'assertion' ? 'passkey_unlock_begin' : 'passkey_register_begin';
  sendCommand({ type }, { type: 'passkey_challenge', kind }).then((payload) => {
    if (state.ceremony !== entry) return;
    if (!ceremonyBindingCurrent(entry)) {
      state.ceremony = null;
      renderAccess();
      maybePrefetchCeremony();
      return;
    }
    try {
      const options = payload.options || {};
      entry.publicKey = kind === 'assertion' ? requestOptions(options) : creationOptions(options);
      entry.ceremonyId = requireText(payload.ceremony_id);
      if (entry.publicKey.timeout) {
        entry.maxAge = Math.max(0, Math.min(CEREMONY_CHALLENGE_LIFETIME_MS, entry.publicKey.timeout)
          - CEREMONY_OPTIONS_MARGIN_MS);
      }
      entry.phase = 'ready';
      if (state.noticeEndsWhenReady) setCeremonyNotice('');
    } catch (error) {
      state.ceremony = null;
      setCeremonyNotice(`${error.message} Tap ${actionLabel(kind)} to try again.`);
    }
    renderAccess();
  }, () => {
    if (state.ceremony !== entry) return;
    state.ceremony = null;
    // Closed by this page's own reconnect: not a failure to report.
    if (entry.ws !== state.ws) {
      renderAccess();
      return;
    }
    // A refused or unanswered begin is not retried automatically.
    setCeremonyNotice('Could not get a passkey request from your Mac. Check that RepoPrompt is running, '
      + `then tap ${actionLabel(kind)} again.`);
    renderAccess();
  });
}

function actionLabel(kind) {
  return kind === 'registration' ? 'Set up passkey' : 'Unlock';
}

// Unlock / Set up tap. With fresh options the native prompt starts right here, before
// anything is awaited, so the tap still counts as the user's gesture. Stale or
// missing options are fetched again and the user taps once more.
function beginNativeCeremony(kind) {
  const entry = state.ceremony;
  const usable = entry && entry.kind === kind && entry.phase === 'ready'
    && ceremonyBindingCurrent(entry) && ceremonyIsFresh(entry);
  if (!usable) {
    // While a request is being prepared or running, the buttons are disabled.
    if (!entry || entry.phase === 'ready') {
      state.ceremony = null;
      state.ceremonyDoneKey = null;
      setCeremonyNotice(`Getting a fresh passkey request. Tap ${actionLabel(kind)} again when it is ready.`, true);
      maybePrefetchCeremony();
    }
    renderAccess();
    return;
  }
  entry.phase = 'native';
  let credential;
  try {
    credential = kind === 'assertion'
      ? navigator.credentials.get({ publicKey: entry.publicKey })
      : navigator.credentials.create({ publicKey: entry.publicKey });
  } catch (error) {
    credential = Promise.reject(error);
  }
  setCeremonyNotice('');
  renderAccess();
  completeNativeCeremony(entry, credential);
}

async function completeNativeCeremony(entry, pendingCredential) {
  const kind = entry.kind;
  let credential;
  try {
    credential = await pendingCredential;
  } catch (error) {
    if (state.ceremony !== entry) return;
    state.ceremony = null;
    setCeremonyNotice(nativeFailureText(kind, error));
    renderAccess();
    // Fresh options for the retry tap; the next begin replaces this ceremony.
    followUpCeremony(true);
    return;
  }
  if (state.ceremony !== entry) return;
  if (!ceremonyBindingCurrent(entry)) {
    state.ceremony = null;
    setCeremonyNotice(`The lock state changed while the passkey prompt was open. Tap ${actionLabel(kind)} again.`);
    renderAccess();
    followUpCeremony(true);
    return;
  }
  let json;
  try {
    json = serializeCredential(kind, credential);
  } catch (error) {
    state.ceremony = null;
    setCeremonyNotice(`${error.message} Tap ${actionLabel(kind)} to try again.`);
    renderAccess();
    followUpCeremony(true);
    return;
  }
  entry.phase = 'completing';
  renderAccess();
  const type = kind === 'assertion' ? 'passkey_unlock_complete' : 'passkey_register_complete';
  let keepNotice = false;
  try {
    await sendCommand(
      { type, payload: { ceremony_id: entry.ceremonyId, credential: json } },
      { type: 'passkey_ceremony_complete', kind },
    );
    if (state.ceremony !== entry) return;
    state.ceremony = null;
    // Completion only ends the ceremony. Access changes come from lock_state alone: the
    // buttons wait while the access is still the one this ceremony started under. When
    // the gateway's new access already arrived (registration's enrollment usually does),
    // there is nothing left to wait for.
    const unchanged = state.accessKey === entry.accessKey;
    if (unchanged) state.ceremonyDoneKey = entry.accessKey;
    if (kind === 'registration') setCeremonyNotice('Passkey saved. Unlock with it next.');
    else if (unchanged) setCeremonyNotice('Passkey verified. Waiting for the gateway to unlock this browser…');
  } catch (error) {
    if (state.ceremony !== entry) return;
    state.ceremony = null;
    // Saved by the app but not yet confirmed to the gateway: no second setup is offered,
    // and Reconnect stays available, until the gateway reports new access. Its notice
    // asks for that reconnect, so it is not kept through one.
    const unavailable = kind === 'registration' && error && error.code === PASSKEY_FAILURE_CODES.unavailable;
    if (unavailable && state.accessKey === entry.accessKey) state.ceremonyDoneKey = entry.accessKey;
    keepNotice = !unavailable;
    setCeremonyNotice(completeFailureText(kind, error));
  }
  renderAccess();
  followUpCeremony(keepNotice);
}

function nativeFailureText(kind, error) {
  const name = error && error.name;
  if (name === 'NotAllowedError' || name === 'AbortError') {
    return `The passkey request was cancelled or not allowed. Tap ${actionLabel(kind)} to try again.`;
  }
  if (name === 'InvalidStateError' && kind === 'registration') {
    return 'Your passkey provider may already have a passkey for this browser. To start over, '
      + 'choose Reset for this browser in Remote Control settings on your Mac.';
  }
  if (name === 'NotSupportedError' || name === 'SecurityError') {
    return 'This browser cannot use a passkey on this page. Open the HTTPS link in Safari, '
      + 'or turn protection off for this browser on your Mac.';
  }
  return `The passkey request did not finish. Tap ${actionLabel(kind)} to try again, or check this `
    + 'browser in Remote Control settings on your Mac.';
}

function completeFailureText(kind, error) {
  const code = error && error.code;
  if (code === PASSKEY_FAILURE_CODES.staleCeremony) {
    return `That passkey request expired or was replaced. Tap ${actionLabel(kind)} to try again.`;
  }
  if (code === PASSKEY_FAILURE_CODES.unavailable && kind === 'registration') {
    return 'Your passkey was saved, but the gateway could not confirm it yet. Tap Reconnect, then Unlock.';
  }
  if (code === PASSKEY_FAILURE_CODES.authenticationFailure) {
    return `The passkey could not be verified. Tap ${actionLabel(kind)} to try again. If it keeps failing, `
      + 'check this browser in Remote Control settings on your Mac.';
  }
  return `No answer from your Mac. Tap ${actionLabel(kind)} to try again, or Reconnect.`;
}

// Shows the lock, setup and recovery presentation in place of session content.
function renderAccess() {
  const paired = isPaired();
  const access = state.access;
  const canLock = paired && state.contentOpen && Boolean(access) && access.policy_state === 'required';
  $('lock-button').classList.toggle('hidden', !canLock);
  $('lock-button').disabled = !canLock;
  const panel = $('lock-panel');
  if (!paired || state.contentOpen) {
    panel.classList.add('hidden');
    return;
  }
  panel.classList.remove('hidden');
  const kind = ceremonyKindFor(access);
  const support = passkeySupport();
  const waiting = state.ceremonyDoneKey !== null && state.ceremonyDoneKey === state.accessKey;
  let message;
  if (!state.ws && !state.connecting) {
    message = 'Not connected. Connect to check whether this browser is unlocked.';
  } else if (!state.connected) {
    message = 'Connecting…';
  } else if (!access) {
    message = 'The gateway did not report whether this browser is unlocked, so sessions stay hidden. '
      + 'Update RepoPrompt on your Mac, then reconnect.';
  } else if (state.hold) {
    message = 'Locked. Waiting for the gateway to confirm…';
  } else if (waiting) {
    message = 'Waiting for your Mac to confirm the passkey…';
  } else if (accessAllowsContent(access)) {
    message = 'Checking access with your Mac…';
  } else if (access.policy_state !== 'required') {
    message = 'Sessions are not available on this connection.';
  } else if (access.enrolled) {
    message = 'Unlock with your passkey to see and control sessions.';
  } else if (access.enrollment_open) {
    message = 'Set up a passkey for this browser. Your Mac has approved setup.';
  } else {
    message = 'Finish passkey setup on your Mac: in Remote Control settings, choose Enroll for this '
      + 'browser, then return here. If setup does not appear shortly, tap Reconnect.';
  }
  if (access && access.reason === PASSKEY_EXPIRED_REASON && access.locked) {
    message = `Locked after 30 minutes without activity. ${message}`;
  }
  if (kind && support === 'insecure') {
    message += ' Passkeys need the HTTPS link. Open the link from Telegram or from Remote Control settings on your Mac.';
  } else if (kind && support === 'unsupported') {
    message += ' This browser does not support passkeys here. Use Safari, or turn protection off for this browser on your Mac.';
  }
  $('lock-message').textContent = message;
  let title = 'Checking access';
  if (!state.ws && !state.connecting) title = 'Not connected';
  else if (!state.connected) title = 'Connecting';
  else if (access && access.policy_state === 'required' && (access.locked || state.hold)) title = 'Locked';
  $('lock-title').textContent = title;
  const entry = state.ceremony;
  // Disabled from the options request until the prompt and its complete have settled.
  const busy = Boolean(entry) && entry.phase !== 'ready';
  const offer = state.connected && support === 'ok' && !state.hold && !waiting;
  $('unlock-button').classList.toggle('hidden', !(offer && kind === 'assertion'));
  $('setup-passkey-button').classList.toggle('hidden', !(offer && kind === 'registration'));
  $('unlock-button').disabled = busy;
  $('setup-passkey-button').disabled = busy;
  // Reconnect is always a working recovery here, except while a prompt or its complete
  // is still running on this connection.
  const recover = Boolean(state.ws) && state.connected && !ceremonyHoldsSocket();
  $('lock-reconnect').classList.toggle('hidden', !recover);
  let status = state.ceremonyNotice;
  if (!status && entry) {
    if (entry.phase === 'fetching') status = 'Preparing the passkey request…';
    else if (entry.phase === 'native') status = 'Waiting for your passkey…';
    else if (entry.phase === 'completing') status = 'Checking with your Mac…';
  }
  $('lock-status').textContent = status || '';
  $('lock-uncertain').textContent = UNCERTAIN_ACTION_TEXT;
  $('lock-uncertain').classList.toggle('hidden', state.uncertainActions.size === 0);
}

// Foreground activity: only trusted user input on a shown, unlocked page, at most once
// per 30 seconds. Never from rendering, scrolling by the page, polling, network,
// reconnects or visibility changes, and never from a timer.
function noteUserActivity(event) {
  if (!event || event.isTrusted !== true) return;
  if (document.visibilityState !== 'visible' || !state.contentOpen) return;
  if (event.target && $('lock-button').contains(event.target)) return;
  const access = state.access;
  if (!access || access.policy_state !== 'required' || access.locked || !access.grant_id) return;
  const now = Date.now();
  if (state.activitySentAt && now - state.activitySentAt < ACTIVITY_THROTTLE_MS) return;
  const ws = state.ws;
  if (!ws || !state.connected || ws.readyState !== WebSocket.OPEN) return;
  state.activitySentAt = now;
  const payload = { grant_id: access.grant_id, epoch: access.epoch, lock_generation: access.lock_generation };
  enqueueSignedSend(ws, { v: WIRE_VERSION, type: 'passkey_activity', payload }).catch(() => {});
}

// Leaving the page hides protected content at once, so it is not shown again before
// the gateway confirms access on return.
function hideForBackground() {
  if (!isPaired()) return;
  state.hideSeq += 1;
  if (state.contentOpen && protectsContent()) closeProtectedView();
  // Options are not kept while away: another tab may replace their ceremony meanwhile.
  if (state.ceremony && state.ceremony.phase === 'ready') state.ceremony = null;
  // Every return is reconciled by a fresh foreground hello, locked or not. A passkey
  // prompt still open on this socket settles there first (followUpCeremony()).
  state.needsFreshHello = true;
  renderAccess();
}

// Returning (visible again, or restored from the back-forward cache): content is
// hidden first under any last-known policy, since the Mac may have turned protection
// on meanwhile; then a fresh connection's hello decides. An unexpired grant reopens
// without a passkey prompt. A locked page keeps its socket and any open ceremony.
function resumeForeground() {
  if (state.contentOpen) closeProtectedView();
  if (isPaired()) state.needsFreshHello = true;
  // A passkey prompt still open on this socket settles first; see followUpCeremony().
  // A socket already made for this return keeps waiting for its hello.
  if (state.needsFreshHello && state.ws && !ceremonyHoldsSocket() && !socketAwaitsForegroundHello()) disconnect();
  if (!state.ws) {
    connect();
    return;
  }
  maybePrefetchCeremony();
  renderAccess();
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
  // The native prompt must start inside these tap handlers; see beginNativeCeremony().
  $('unlock-button').onclick = () => beginNativeCeremony('assertion');
  $('setup-passkey-button').onclick = () => beginNativeCeremony('registration');
  $('lock-button').onclick = () => lockNow();
  $('lock-reconnect').onclick = () => reconnectNow();
  for (const type of ACTIVITY_EVENTS) {
    document.addEventListener(type, noteUserActivity, { capture: true, passive: true });
  }
  $('load-older').onclick = () => loadOlderTranscript();
  $('jump-top').onclick = () => jumpToTranscriptTop();
  $('jump-latest').onclick = () => jumpToLatest();
  $('respond-button').onclick = () => respond();
  $('composer-send').onclick = () => sendComposer();
  $('stop-button').onclick = () => stopSession();
  $('composer-input').addEventListener('input', () => sizeComposer());
  window.addEventListener('resize', () => sizeComposer());
  $('switch-workspace').onclick = () => discoverWorkspaces('switch');
  $('workspace-retry').onclick = () => discoverWorkspaces(state.workspaceRetryReason);
  // Dismiss keeps the current choice and list; a discovery still in flight is dropped.
  $('binding-dismiss').onclick = () => {
    state.workspaceGeneration += 1;
    hideWorkspaceChooser();
  };
  // Returning to the tab reconnects, after re-reading which build the gateway is.
  // Protected content is hidden on leaving and stays hidden until a fresh hello.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      resumeForeground();
    } else {
      hideForBackground();
    }
  });
  window.addEventListener('pagehide', () => hideForBackground());
  window.addEventListener('pageshow', (event) => {
    if (event.persisted) resumeForeground();
  });

  await registerServiceWorker();
  // connect() reads the gateway's build channel, loads that build's saved pairing,
  // and connects when one exists.
  await connect();
  renderIdentity();
}

main();
