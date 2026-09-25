const $ = (id) => document.getElementById(id);

const ui = {
  menu: $("menuButton"), drawer: $("sideDrawer"), backdrop: $("drawerBackdrop"), closeDrawer: $("closeDrawerButton"),
  dot: $("connectionDot"), server: $("serverName"), backend: $("backendName"),
  orb: $("orb"), state: $("recordingState"), timer: $("timer"), bars: [...$("levelBars").children],
  profileSetup: $("profileSetup"), profileName: $("profileName"), machineName: $("machineName"),
  connect: $("connectButton"), disconnect: $("disconnectButton"),
  button: $("recordButton"), buttonLabel: $("recordButtonLabel"),
  message: $("message"), resultsSection: $("resultsSection"), resultsList: $("resultsList"),
  loadMore: $("loadMoreButton")
};

function randomID() {
  if (crypto.randomUUID) return crypto.randomUUID();
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (value) => {
    const random = crypto.getRandomValues(new Uint8Array(1))[0] & 15;
    return (value === "x" ? random : (random & 3) | 8).toString(16);
  });
}

function savedJSON(key) {
  try { return JSON.parse(localStorage.getItem(key) || "null"); }
  catch { return null; }
}

function randomToken(byteCount = 32) {
  return [...crypto.getRandomValues(new Uint8Array(byteCount))]
    .map((value) => value.toString(16).padStart(2, "0")).join("");
}

function withProfileIdentity(profile) {
  if (!profile) return null;
  const identified = {
    ...profile,
    profileID: profile.profileID || randomID(),
    profileToken: profile.profileToken || randomToken()
  };
  localStorage.setItem("remoteScribeProfile", JSON.stringify(identified));
  return identified;
}

const query = new URLSearchParams(location.search);
const enrolledKey = query.get("key");
if (enrolledKey) {
  localStorage.setItem("remoteScribeAccessKey", enrolledKey);
  history.replaceState(null, "", location.pathname);
}

const model = {
  ready: false, connecting: false, recording: false, processing: false, manuallyDisconnected: false,
  sessionID: null, startedAt: 0, timerID: null, sampleFrames: 0, sequence: 0,
  uploadChain: Promise.resolve(), audio: null, wakeLock: null,
  clientID: localStorage.getItem("remoteScribeClientID") || randomID(),
  accessKey: localStorage.getItem("remoteScribeAccessKey") || "",
  profile: withProfileIdentity(savedJSON("remoteScribeProfile")),
  historyProfileID: null, historyOffset: 0, historyTotal: 0, loadingHistory: false
};
localStorage.setItem("remoteScribeClientID", model.clientID);

function authHeaders(extra = {}) {
  return { "X-Remote-Scribe-Key": model.accessKey, "X-Remote-Scribe-Client-ID": model.clientID, ...extra };
}

async function api(path, options = {}) {
  const response = await fetch(path, { cache: "no-store", ...options, headers: authHeaders(options.headers || {}) });
  let payload = null;
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) payload = await response.json();
  if (!response.ok) {
    const error = new Error(payload?.message || `Erreur réseau ${response.status}`);
    error.status = response.status; error.payload = payload; throw error;
  }
  return payload;
}

function setMessage(text, error = false) {
  ui.message.textContent = text; ui.message.classList.toggle("error", error);
}

function defaultMachineName() { return location.hostname.replace(/\.local$/i, "") || ""; }

function openDrawer(populate = true) {
  const wasOpen = ui.drawer.classList.contains("open");
  if (populate && !wasOpen) {
    ui.profileName.value = model.profile?.profileName || "";
    ui.machineName.value = model.profile?.machineName || defaultMachineName();
  }
  ui.disconnect.classList.toggle("hidden", !model.ready);
  ui.drawer.classList.add("open");
  ui.drawer.setAttribute("aria-hidden", "false");
  ui.menu.setAttribute("aria-expanded", "true");
  ui.backdrop.classList.remove("hidden");
  document.body.classList.add("drawer-open");
}

function closeDrawer() {
  ui.drawer.classList.remove("open");
  ui.drawer.setAttribute("aria-hidden", "true");
  ui.menu.setAttribute("aria-expanded", "false");
  ui.backdrop.classList.add("hidden");
  document.body.classList.remove("drawer-open");
}

function showProfile(message = "Créez votre profil une seule fois sur cet appareil.") {
  openDrawer(true);
  setMessage(message);
}

function setDisconnected(message, error = false) {
  model.ready = false; ui.button.disabled = true; ui.orb.disabled = true;
  ui.dot.className = `status-dot ${error ? "error" : "searching"}`;
  ui.server.textContent = error ? "Mac indisponible" : "Reconnexion au Mac…";
  ui.backend.textContent = "Le profil sera reconnecté automatiquement"; setMessage(message, error);
}

function setConnected(info) {
  model.ready = true; model.manuallyDisconnected = false;
  ui.dot.className = "status-dot connected";
  ui.server.textContent = info.serverName || info.machineName || "Mac connecté";
  ui.backend.textContent = `${model.profile.profileName} · ${info.selectedBackend || "Remote Scribe"}`;
  closeDrawer();
  ui.button.disabled = false; ui.orb.disabled = false; setMessage("Connexion privée prête.");
  if (model.historyProfileID !== model.profile.profileID) loadHistory(true);
}

async function connectProfile() {
  if (model.connecting || model.ready || model.manuallyDisconnected || model.recording || model.processing) return;
  if (!model.accessKey) {
    showProfile("Scannez une seule fois le QR code stable affiché par le Mac."); ui.connect.disabled = true; return;
  }
  if (!model.profile?.profileName || !model.profile?.machineName) { showProfile(); return; }
  model.connecting = true; ui.connect.disabled = true;
  try {
    const info = await api("/api/connect", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(model.profile)
    });
    setConnected(info);
  } catch (error) {
    model.ready = false; ui.button.disabled = true; ui.orb.disabled = true;
    if (error.status === 423) {
      ui.dot.className = "status-dot error"; ui.server.textContent = "PC déjà utilisé";
      ui.backend.textContent = "Une seule personne peut se connecter à la fois";
      closeDrawer(); setMessage("Nouvel essai automatique dès que le PC se libère.");
    } else if (error.status === 409) {
      showProfile(`Nom incorrect. Ce PC s’appelle « ${error.payload?.machineName || "inconnu"} ».`);
    } else if (error.status === 403 && error.payload?.code === "profile_access_denied") {
      showProfile("Ce profil local n’est pas reconnu. Ne supprimez pas les données Safari si vous voulez conserver son historique.");
    } else if (error.status === 403) {
      model.accessKey = ""; localStorage.removeItem("remoteScribeAccessKey");
      showProfile("Accès non reconnu. Scannez de nouveau le QR code stable du Mac."); ui.connect.disabled = true;
    } else {
      setDisconnected("Le Mac est arrêté. La reconnexion se fera automatiquement.");
    }
  } finally {
    model.connecting = false; if (model.accessKey) ui.connect.disabled = false;
  }
}

async function heartbeat() {
  if (!model.ready || model.recording || model.processing) return;
  try { await api("/api/heartbeat", { method: "POST" }); }
  catch { setDisconnected("Connexion perdue. Reconnexion automatique…"); }
}

async function releaseComputer(manual = true) {
  const payload = JSON.stringify({ clientID: model.clientID, accessKey: model.accessKey });
  try {
    await api("/api/disconnect", { method: "POST", headers: { "Content-Type": "application/json" }, body: payload });
  } catch { /* Le délai d’inactivité libérera aussi le PC. */ }
  model.ready = false; model.manuallyDisconnected = manual; ui.button.disabled = true; ui.orb.disabled = true;
  ui.dot.className = "status-dot searching"; ui.server.textContent = "PC libéré";
  ui.backend.textContent = "Votre profil reste mémorisé";
  if (manual) showProfile("PC libéré. Touchez « Se connecter » pour revenir.");
}

function formatElapsed() {
  const total = Math.floor((Date.now() - model.startedAt) / 1000);
  const hours = String(Math.floor(total / 3600)).padStart(2, "0");
  const minutes = String(Math.floor(total / 60) % 60).padStart(2, "0");
  const seconds = String(total % 60).padStart(2, "0");
  ui.timer.textContent = `${hours}:${minutes}:${seconds}`;
}

function makeSessionID() { return randomID().toUpperCase(); }

class PCMStreamer {
  constructor(onChunk, onLevel) { this.onChunk = onChunk; this.onLevel = onLevel; this.pending = []; this.pendingLength = 0; }

  async start() {
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 }, video: false
    });
    this.context = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: "interactive" });
    await this.context.resume();
    this.source = this.context.createMediaStreamSource(this.stream);
    this.processor = this.context.createScriptProcessor(4096, 1, 1);
    this.silent = this.context.createGain(); this.silent.gain.value = 0;
    this.processor.onaudioprocess = (event) => this.consume(event.inputBuffer.getChannelData(0));
    this.source.connect(this.processor); this.processor.connect(this.silent); this.silent.connect(this.context.destination);
  }

  consume(samples) {
    let power = 0;
    for (let index = 0; index < samples.length; index++) power += samples[index] * samples[index];
    this.onLevel(Math.min(1, Math.sqrt(power / samples.length) * 5));
    const ratio = this.context.sampleRate / 16000;
    const length = Math.floor(samples.length / ratio);
    const pcm = new Int16Array(length);
    for (let output = 0; output < length; output++) {
      const start = Math.floor(output * ratio);
      const end = Math.max(start + 1, Math.floor((output + 1) * ratio));
      let sum = 0;
      for (let input = start; input < end && input < samples.length; input++) sum += samples[input];
      const value = Math.max(-1, Math.min(1, sum / (end - start)));
      pcm[output] = value < 0 ? value * 0x8000 : value * 0x7fff;
    }
    this.pending.push(new Uint8Array(pcm.buffer)); this.pendingLength += pcm.byteLength;
    if (this.pendingLength >= 32000) this.flush();
  }

  flush() {
    if (!this.pendingLength) return;
    const chunk = new Uint8Array(this.pendingLength); let offset = 0;
    for (const part of this.pending) { chunk.set(part, offset); offset += part.byteLength; }
    this.pending = []; this.pendingLength = 0; this.onChunk(chunk);
  }

  async stop() {
    if (this.processor) { this.processor.disconnect(); this.processor.onaudioprocess = null; }
    if (this.source) this.source.disconnect();
    if (this.silent) this.silent.disconnect();
    this.stream?.getTracks().forEach((track) => track.stop());
    if (this.context) await this.context.close();
    this.flush();
  }
}

function updateLevel(level) {
  ui.bars.forEach((bar, index) => {
    const distance = Math.abs(index - (ui.bars.length - 1) / 2);
    const scaled = Math.max(.08, level * (1 - distance * .09));
    bar.style.height = `${5 + scaled * 23}px`;
  });
}

function enqueueChunk(bytes) {
  const sequence = model.sequence++; model.sampleFrames += bytes.byteLength / 2;
  model.uploadChain = model.uploadChain.then(() => api(`/api/session/${model.sessionID}/chunk?sequence=${sequence}`, {
    method: "POST", headers: { "Content-Type": "application/octet-stream" }, body: bytes
  }));
}

async function startRecording() {
  if (!model.ready || model.recording || model.processing) return;
  model.sessionID = makeSessionID(); model.sequence = 0; model.sampleFrames = 0; model.uploadChain = Promise.resolve();
  setMessage("Demande d’accès au microphone…");
  try {
    await api("/api/session/start", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionID: model.sessionID, language: document.documentElement.lang || "fr" })
    });
    model.audio = new PCMStreamer(enqueueChunk, updateLevel); await model.audio.start();
    if (navigator.wakeLock) model.wakeLock = await navigator.wakeLock.request("screen").catch(() => null);
    model.recording = true; model.startedAt = Date.now(); model.timerID = setInterval(formatElapsed, 250); formatElapsed();
    ui.orb.className = "orb recording"; ui.state.textContent = "Enregistrement…";
    ui.orb.disabled = false; ui.orb.setAttribute("aria-label", "Arrêter l’enregistrement");
    ui.button.classList.add("stop"); ui.buttonLabel.textContent = "STOP";
    setMessage("Parlez normalement. Gardez cette page ouverte.");
  } catch (error) {
    await model.audio?.stop().catch(() => {}); model.audio = null; setMessage(error.message, true);
    if (error.status === 401) setDisconnected("Reconnexion automatique…");
  }
}

async function stopRecording() {
  if (!model.recording) return;
  model.recording = false; model.processing = true; clearInterval(model.timerID); ui.button.disabled = true; ui.orb.disabled = true;
  ui.orb.className = "orb processing"; ui.state.textContent = "Traitement sur le Mac…";
  ui.button.classList.remove("stop"); ui.buttonLabel.textContent = "START"; setMessage("Envoi des derniers morceaux…");
  try {
    await model.audio.stop(); await model.uploadChain;
    await api(`/api/session/${model.sessionID}/stop`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ framesSent: model.sampleFrames })
    });
    await waitForResult();
  } catch (error) { setMessage(error.message, true); finishProcessing(); }
  finally { model.audio = null; await model.wakeLock?.release().catch(() => {}); model.wakeLock = null; }
}

function formatDuration(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const minutes = Math.floor(total / 60);
  return `${minutes}:${String(total % 60).padStart(2, "0")}`;
}

function renderResult(status, position = "prepend") {
  const cleanText = (value) => typeof value === "string" && value.trim() ? value.trim() : null;
  const finalText = cleanText(status.finalText) || cleanText(status.transcription) || "Le texte traité par IA n’a pas été transmis.";
  const rawText = cleanText(status.rawTranscription);
  const sessionID = status.sessionID || model.sessionID;
  if (sessionID && ui.resultsList.querySelector(`[data-session-id="${sessionID}"]`)) return;
  const item = document.createElement("details");
  item.className = "result-item";
  if (sessionID) item.dataset.sessionId = sessionID;

  const summary = document.createElement("summary");
  const kicker = document.createElement("div");
  kicker.className = "result-kicker";
  const label = document.createElement("span"); label.textContent = "Texte traité par IA";
  const time = document.createElement("span");
  const completedAt = status.completedAt ? new Date(status.completedAt * 1000) : new Date();
  const duration = status.durationSeconds ?? (status.bytesReceived ? status.bytesReceived / 32000 : 0);
  time.textContent = `${completedAt.toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit" })} · ${completedAt.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })} · ${formatDuration(duration)}`;
  kicker.append(label, time);
  const preview = document.createElement("p"); preview.className = "result-preview"; preview.textContent = finalText;
  summary.append(kicker, preview);

  const body = document.createElement("div"); body.className = "result-body";
  const tabs = document.createElement("div"); tabs.className = "result-tabs";
  const finalButton = document.createElement("button"); finalButton.type = "button"; finalButton.className = "result-tab active"; finalButton.textContent = "Texte IA";
  const rawButton = document.createElement("button"); rawButton.type = "button"; rawButton.className = "result-tab"; rawButton.textContent = "Transcription brute";
  const copyButton = document.createElement("button"); copyButton.type = "button"; copyButton.className = "result-copy"; copyButton.textContent = "Copier";
  const content = document.createElement("p"); content.className = "result-content";
  const audioZone = document.createElement("div"); audioZone.className = "result-audio-zone";
  const hasAudio = Boolean(status.hasAudio || status.audioLocation);
  let activeText = finalText;

  const select = (kind) => {
    const showingFinal = kind === "final";
    activeText = showingFinal ? finalText : (rawText || "La transcription brute n’a pas été transmise par le Mac.");
    content.textContent = activeText;
    finalButton.classList.toggle("active", showingFinal);
    rawButton.classList.toggle("active", !showingFinal);
  };
  rawButton.disabled = !rawText;
  finalButton.addEventListener("click", () => select("final"));
  rawButton.addEventListener("click", () => select("raw"));
  copyButton.addEventListener("click", async () => {
    await navigator.clipboard.writeText(activeText).catch(() => {});
    copyButton.textContent = "Copié";
    setTimeout(() => { copyButton.textContent = "Copier"; }, 1200);
  });
  select("final");
  tabs.append(finalButton, rawButton, copyButton);
  if (hasAudio && sessionID) {
    const listenButton = document.createElement("button");
    listenButton.type = "button"; listenButton.className = "result-audio-button"; listenButton.textContent = "▶ Écouter l’audio";
    listenButton.addEventListener("click", async () => {
      const player = document.createElement("audio");
      player.className = "result-audio"; player.controls = true; player.preload = "metadata";
      player.src = `/api/history/${encodeURIComponent(sessionID)}/audio`;
      audioZone.replaceChildren(player);
      await player.play().catch(() => {});
    }, { once: true });
    audioZone.append(listenButton);
  }
  body.append(tabs, audioZone, content); item.append(summary, body);
  if (position === "append") ui.resultsList.append(item); else ui.resultsList.prepend(item);
  ui.resultsSection.classList.remove("hidden");
}

async function loadHistory(reset = false) {
  if (!model.ready || model.loadingHistory) return;
  model.loadingHistory = true;
  if (reset) {
    model.historyOffset = 0; model.historyTotal = 0; model.historyProfileID = model.profile.profileID;
    ui.resultsList.replaceChildren(); ui.loadMore.classList.add("hidden");
  }
  try {
    const history = await api(`/api/history?limit=25&offset=${model.historyOffset}`);
    history.items.forEach((item) => renderResult(item, "append"));
    model.historyOffset += history.items.length; model.historyTotal = history.total;
    ui.loadMore.classList.toggle("hidden", model.historyOffset >= model.historyTotal);
    ui.resultsSection.classList.toggle("hidden", model.historyTotal === 0);
  } catch (error) {
    setMessage(`Historique indisponible : ${error.message}`, true);
  } finally {
    model.loadingHistory = false;
  }
}

async function waitForResult() {
  const deadline = Date.now() + 300000;
  while (Date.now() < deadline) {
    const status = await api(`/api/session/${model.sessionID}/status`);
    if (status.state === "completed") {
      status.sessionID = model.sessionID;
      status.durationSeconds = model.sampleFrames / 16000;
      status.hasAudio = Boolean(status.audioLocation);
      renderResult(status);
      model.historyTotal += 1; model.historyOffset += 1;
      setMessage(status.message || "Dictée terminée."); finishProcessing(); return;
    }
    if (status.state === "failed") throw new Error(status.message || "Le traitement a échoué.");
    setMessage(status.message || "Traitement sur le Mac…");
    await new Promise((resolve) => setTimeout(resolve, 900));
  }
  throw new Error("Le Mac n’a pas répondu dans le délai prévu.");
}

function finishProcessing() {
  model.processing = false; model.ready = true; ui.button.disabled = false; ui.orb.disabled = false;
  ui.orb.className = "orb idle"; ui.orb.setAttribute("aria-label", "Démarrer l’enregistrement");
  ui.state.textContent = "Prêt à dicter"; updateLevel(0);
}

const toggleRecording = () => model.recording ? stopRecording() : startRecording();
ui.button.addEventListener("click", toggleRecording);
ui.orb.addEventListener("click", toggleRecording);
ui.connect.addEventListener("click", async () => {
  const profileName = ui.profileName.value.trim(); const machineName = ui.machineName.value.trim();
  if (!profileName || !machineName) { setMessage("Indiquez votre nom et le nom du PC.", true); return; }
  model.profile = withProfileIdentity({
    profileName, machineName,
    profileID: model.profile?.profileID,
    profileToken: model.profile?.profileToken
  });
  model.manuallyDisconnected = false;
  if (model.ready) await releaseComputer(false);
  connectProfile();
});
ui.menu.addEventListener("click", () => openDrawer(true));
ui.closeDrawer.addEventListener("click", closeDrawer);
ui.backdrop.addEventListener("click", closeDrawer);
ui.disconnect.addEventListener("click", () => releaseComputer(true));
ui.loadMore.addEventListener("click", () => loadHistory(false));
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeDrawer();
});

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden" && model.recording) setMessage("Gardez Remote Scribe au premier plan.", true);
  if (document.visibilityState === "visible" && !model.ready) connectProfile();
});
window.addEventListener("pagehide", () => {
  if (!model.accessKey) return;
  const body = new Blob([JSON.stringify({ clientID: model.clientID, accessKey: model.accessKey })], { type: "application/json" });
  navigator.sendBeacon("/api/disconnect", body);
});

setInterval(() => model.ready ? heartbeat() : connectProfile(), 5000);
connectProfile();
