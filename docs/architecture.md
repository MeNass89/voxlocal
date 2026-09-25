# Architecture

```text
[iPhone / iPad]  ios/ (RemoteScribePortable + ios/Core)
  AVAudioEngine -> PCM S16LE 16 kHz -> Remote Scribe v1
  appairage : QR code (nom, code, empreinte) ou saisie manuelle
                                           |
                     TLS 1.3, port 47365, certificat épinglé (SHA-256 du DER)
                                           |
                                           v
                              [Poste hôte : macOS ou Windows]
                              mac/VoxLocal + RemoteScribe/Core (macOS 15+)
                              server/ (Python, Windows/macOS)
                              code d'appairage + verrou 5 échecs / 60 s
                              machine d'état de session
                                           |
                  +------------------------+-------------------------+
                  |                                                  |
          local (Mac)                                      GPU privé (option)
          whisper-cli                                      HTTPS + jeton
          llama-server 127.0.0.1 (clé aléatoire)           /v1/audio/transcriptions
          repli llama-cli                                  /v1/chat/completions
                  |
          texte collé dans l'application active du poste

[Harness d'agent local]
  -> voxlocal-agent-api (127.0.0.1:47366, Bearer, JSON)
  -> voice / clean / llm HTTPS séparés
  -> RunPod privé après validation DPA/ZDR
```

Le contenu clinique ne quitte pas le périmètre contrôlé de l’hôpital, sauf vers
le GPU privé si l’établissement l’active. Les hôtes Python ne persistent rien ;
VoxLocal sur Mac garde un historique local des dictées dans le compte de
l’utilisateur. Les journaux portent des identifiants, des tailles et des états,
jamais le texte ou l’audio. Le détail est dans
[`security-whitepaper.md`](security-whitepaper.md).

Correspondance avec le dépôt : `ios/` contient le client iPhone/iPad et sa copie
durcie du client Core (`ios/Core/Sources`) ; `RemoteScribe/Core/Sources` est le
Core livré, source de vérité du contrat wire ; `mac/VoxLocal/` est l’app macOS
qui embarque ce Core ; `server/` est l’hôte Python de référence ; `agent/` est
l’API loopback ; `harness/` est le harness clinique (profil `dsh`, plugins,
pont portail, feeder) ; `cloud/runpod/` est le runtime GPU privé (déploiement :
[`docs/cloud-deployment.md`](cloud-deployment.md)).

## Harness clinique

Une couche d’agent sur le poste du médecin ([`harness/`](../harness/README.md)).
Elle prend les dictées terminées et prépare les modifications du dossier ; elle
n’écrit dans le portail qu’après un feu vert humain.

```text
[VoxLocal]  dictées nettoyées : API loopback du Mac (47367) ou API agent (47366), Bearer
        |
        | harness/ingest/dictation_feeder.py : une dictée terminée = un message
        | (inject ; un tour est lancé sur pause >= 20 s, commande du médecin ou « fin »)
        v
[dsh, profil « scribe »]  poste du médecin, chat web sur 127.0.0.1 uniquement
  modèle : Qwen3.8-27B via le GPU privé (VOXLOCAL_LLM_URL, jeton VOXLOCAL_LLM_TOKEN)
  plugins : scribe-persona   rôle, boucle, règles, correspondance SOAP
            voxlocal-tools   dictation_list / dictation_get / dictation_retranscribe
            portail-tools    patient_*, record_read_section, record_draft_edit,
                             record_apply, record_restore       (jeton outils)
            scribe-approval  record_apply / record_restore => question au médecin
                             « Allow once » => approve_draft     (jeton approbateur)
        |                                   |
        | PORTAIL_BRIDGE_TOKEN              | PORTAIL_BRIDGE_APPROVER_TOKEN
        v                                   v
[pont portail]  JSON-RPC 127.0.0.1:47368 = frontière de sécurité
  brouillons immuables (drafts.jsonl), citations vérifiées dans la dictée
  approbation à usage unique, 10 min, liée patient / rencontre / section / empreintes
  vérification d'empreinte + écriture + consommation sous un seul verrou
  audit : harness/audit/portal-writes.jsonl
        |
        v
[portail patient]  aujourd'hui : mock enregistré (harness/bridge/portail_mock.py)
                   demain : portail réel derrière la même interface
```

Le flux du feu vert : `record_draft_edit` fait stocker au pont un brouillon
immuable et renvoie un `draft_id`. L’agent appelle ensuite `record_apply`.
`dsh` suspend cet appel et montre au médecin le patient, la rencontre, la
section, le diff exact et les citations. Sur « Allow once », le plugin
`scribe-approval` (jamais le modèle) appelle `approve_draft` avec le jeton
approbateur ; le pont crée l’approbation, puis l’outil écrit avec le jeton
outils. Sans cette approbation, le pont répond 403 ; si la section ou le
brouillon a changé, 409. Le détail est dans
[Agent et portail](security-whitepaper.md#agent-et-portail).
