# Revue produit adversariale — 25 septembre 2026

Cette passe cherche les chemins qui pourraient contredire les promesses du
produit (ZDR local, transport contrôlé, harness agent reproductible), plutôt
que d'ajouter une nouvelle suite de tests.

## Corrections livrées

1. **CLI agent : transport explicite.** `agent/voxlocal_agent_api.py` refuse
   maintenant une URL HTTP distante pour `status`, `transcribe`, `clean` et
   `chat`. HTTP reste disponible uniquement pour `localhost`, tandis qu'un
   reverse proxy distant doit être HTTPS. Le bearer token ne peut donc plus
   partir par inadvertance sur le réseau en clair.
2. **Profil mock hermétique.** `serve --mock` échoue si une URL GPU, nettoyage
   ou LLM est présente dans les arguments ou l'environnement. Une variable
   héritée d'une session de production ne peut plus transformer une démo en
   appel distant inattendu.
3. **Contrôle RunPod borné.** `check-services.py` impose un délai de 30 s
   maximum et envoie `Cache-Control: no-store` ainsi que le marqueur ZDR lors
   de la sonde `/v1/models`.
4. **iOS : plaintext limité au test local.** Une connexion découverte par
   Bonjour exige TLS. Le mode TCP sans TLS ne peut être utilisé manuellement
   que vers `localhost`, `127.0.0.0/8` ou `::1`, ce qui correspond au profil
   mock documenté et évite d'envoyer un microphone sur le LAN par simple
   bascule persistée.

## Risques restant volontairement externes

- Le pairing code n'est pas un enrôlement mTLS : il faut certificat géré,
  rotation et révocation avant un pilote clinique.
- Le header ZDR ne prouve pas la politique RunPod : il faut DPA, région,
  rétention, snapshots et journaux vérifiés par l'hôpital.
- Le DMG ad hoc et l'app iOS Personal Team restent des builds d'essai ; la
  signature/notarisation et la validation sur poste Windows réel sont des
  portes de distribution.
- Le trust store iOS valide le certificat système, mais le pinning de clé
  publique reste une décision de provisioning MDM et n'est pas inventé dans
  le prototype.

## Vérification ciblée

- `python3 -m unittest agent.test_agent_api tests.test_runpod_runtime -v` :
  13 tests verts, dont les nouveaux refus HTTP distant, mock hermétique et
  timeout RunPod.
- `swiftc -parse PortableClientModel.swift` (dans `ios/RemoteScribePortable/`) : OK.

Ces contrôles sont intentionnellement limités aux invariants modifiés ; les
suites complètes déjà exécutées restent la référence historique dans
`docs/process-log.md`.
