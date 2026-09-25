// Each card links to the matching section of the security whitepaper
// (docs/security-whitepaper.md). The anchors below are the contract with that
// document's headings.
const WHITEPAPER = "https://github.com/MeNass89/voxlocal/blob/main/docs/security-whitepaper.md";

const cards = [
  {
    label: "Local",
    title: "Traitement sur le poste",
    text: "Whisper et le modèle de langage tournent sur le poste de l’hôpital. Aucune API cloud n’est nécessaire pour dicter.",
    anchor: "flux-de-données",
  },
  {
    label: "TLS 1.3",
    title: "Chiffré et épinglé",
    text: "L’iPhone parle au poste en TLS 1.3. L’empreinte du certificat est vérifiée à l’appairage, puis épinglée.",
    anchor: "transport",
  },
  {
    label: "0 fichier",
    title: "Aucune persistance serveur",
    text: "L’hôte serveur ne conserve ni l’audio ni le texte. Sur Mac, l’historique reste dans le dossier local de l’utilisateur.",
    anchor: "données-au-repos",
  },
  {
    label: "Keychain",
    title: "Secrets au trousseau",
    text: "Code d’appairage sur iPhone, jeton GPU sur Mac : rangés dans le trousseau du système, jamais dans un fichier de réglages.",
    anchor: "secrets",
  },
  {
    label: "Journaux",
    title: "Aucune donnée patient dans les logs",
    text: "Les journaux notent des événements et des volumes d’octets. Jamais le texte dicté, jamais l’audio.",
    anchor: "journalisation",
  },
  {
    label: "Option",
    title: "GPU privé, si vous le voulez",
    text: "Pour les gros modèles, un GPU dédié en HTTPS avec jeton. Région, contrat et rétention restent à valider avec votre DPO.",
    anchor: "fournisseur-gpu",
  },
];

export function SecurityGrid() {
  return (
    <div className="security-grid">
      {cards.map((card) => (
        <a
          className="security-card reveal"
          key={card.anchor}
          href={`${WHITEPAPER}#${card.anchor}`}
          target="_blank"
          rel="noreferrer"
        >
          <span className="security-label">{card.label}</span>
          <h3>{card.title}</h3>
          <p>{card.text}</p>
          <span className="security-link">Lire la section <span aria-hidden="true">↗</span></span>
        </a>
      ))}
    </div>
  );
}
