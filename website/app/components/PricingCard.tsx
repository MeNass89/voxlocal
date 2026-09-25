const included = [
  "Installation de VoxLocal sur les postes du service, macOS ou Windows",
  "Appairage des iPhone et iPad des soignants",
  "Choix des modèles Whisper et LLM avec vos équipes",
  "Modes cliniques adaptés à vos comptes rendus",
  "Revue de sécurité avec votre DSI et votre DPO",
  "GPU privé en option, dans la région de votre choix",
];

export function PricingCard() {
  return (
    <article className="pricing-card reveal">
      <div className="pricing-head">
        <h3>Pilote hospitalier</h3>
        <p className="pricing-price">Nous contacter</p>
        <p className="pricing-note">Tarif établi avec vous, selon le nombre de postes et le périmètre du pilote.</p>
      </div>
      <ul>
        {included.map((item) => <li key={item}>{item}</li>)}
      </ul>
      <a
        className="button button-light"
        href="mailto:contact@voxlocal.ai?subject=Pilote%20VoxLocal%20dans%20notre%20%C3%A9tablissement"
      >
        Demander un pilote <span aria-hidden="true">↗</span>
      </a>
    </article>
  );
}
