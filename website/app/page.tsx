import type { Metadata } from "next";
import { ImmersiveScene } from "./components/ImmersiveScene";

export const metadata: Metadata = {
  title: "VoxLocal — L’IA médicale commence par écouter",
  description:
    "VoxLocal transforme la parole clinique en transcription et en texte structuré par IA, localement sur le poste ou depuis un iPhone avec RemoteScribe.",
};

const journey = [
  {
    number: "01",
    title: "Parler",
    text: "Un clic sur le microphone flottant du Mac — ou sur START depuis l’iPhone avec RemoteScribe — suffit pour commencer.",
  },
  {
    number: "02",
    title: "Transcrire",
    text: "Whisper transforme l’audio en texte sur le poste. La transcription brute, les segments et le WAV restent disponibles.",
  },
  {
    number: "03",
    title: "Structurer",
    text: "Le mode clinique actif guide le modèle de langage local : note médicale, synthèse, email ou format personnalisé.",
  },
  {
    number: "04",
    title: "Utiliser",
    text: "Le texte final est copié ou collé dans l’application de travail, puis conservé avec sa source dans l’historique privé.",
  },
];

const facts = [
  ["Local", "Whisper et LLM exécutés sur le poste"],
  ["2 entrées", "Microphone du Mac ou iPhone distant"],
  ["3 sources", "Audio, verbatim et texte final réunis"],
  ["0 API", "Aucun cloud requis par VoxLocal"],
];

export default function Home() {
  return (
    <main>
      <ImmersiveScene />

      <header className="site-header">
        <a className="brand" href="#top" aria-label="VoxLocal — accueil">
          <span className="brand-eight" aria-hidden="true">8</span>
          <span>VoxLocal</span>
        </a>
        <nav aria-label="Navigation principale">
          <a href="#experience">Produit</a>
          <a href="#architecture">Technologie</a>
          <a href="#hospital">Hôpitaux</a>
        </nav>
        <a className="header-contact" href="#hospital">Nous contacter <span>↗</span></a>
      </header>

      <section className="hero" id="top">
        <div className="hero-copy reveal">
          <p className="eyebrow"><span /> Dictée clinique · IA locale · RemoteScribe</p>
          <h1>
            La médecine parle.
            <span>VoxLocal transforme.</span>
          </h1>
          <p className="hero-description">
            Une plateforme de transcription vocale assistée par IA, pensée pour
            la pratique clinique : depuis le microphone du Mac ou de l’iPhone
            jusqu’au texte structuré, sans dépendre d’une API cloud.
          </p>
          <div className="hero-actions">
            <a className="button button-light" href="#experience">Découvrir VoxLocal</a>
            <a className="text-link" href="#architecture">Voir comment ça fonctionne <span>↓</span></a>
          </div>
        </div>

        <div className="hero-mark" aria-hidden="true">
          <span>8</span>
          <small>Prototype mark / 01</small>
        </div>

        <div className="hero-foot">
          <span>VoxLocal sur macOS aujourd’hui</span>
          <span className="pulse-dot" />
          <span>Windows demain</span>
        </div>
        <a className="scroll-cue" href="#manifesto">
          <span className="scroll-line" />
          Faire défiler
        </a>
      </section>

      <section className="manifesto section" id="manifesto">
        <p className="section-index">01 / L’intention</p>
        <h2 className="display-copy reveal">
          Moins de saisie.
          <span>Plus de présence clinique.</span>
        </h2>
        <p className="manifesto-note reveal">
          Le soignant parle naturellement. VoxLocal transcrit, structure et
          remet le texte dans le flux de travail — sans transformer la rencontre
          médicale en séance de saisie.
        </p>
      </section>

      <section className="journey section" id="experience">
        <div className="section-heading reveal">
          <p className="section-index">02 / Un seul geste</p>
          <h2>De la voix au texte utile.</h2>
          <p>Quatre étapes. Une expérience continue.</p>
        </div>
        <div className="journey-grid">
          {journey.map((item) => (
            <article className="journey-card reveal" key={item.number}>
              <span className="card-number">{item.number}</span>
              <div className="card-orbit" aria-hidden="true"><i /></div>
              <h3>{item.title}</h3>
              <p>{item.text}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="results section">
        <div className="results-stage reveal">
          <div className="results-glow" aria-hidden="true" />
          <div className="result-card raw-card">
            <div className="result-topline"><span>Verbatim</span><span>Brut · 12:42</span></div>
            <p>« Douleur thoracique apparue ce matin, sans irradiation, avec une gêne respiratoire légère… »</p>
            <div className="wave" aria-hidden="true">▂▅▃▇▄▆▂▃▆▅▂▇▃▅▂▆▃▇▅▂</div>
          </div>
          <div className="result-card ai-card">
            <div className="result-topline"><span>Synthèse clinique</span><span>IA · prête</span></div>
            <h3>Motif et histoire</h3>
            <p>Douleur thoracique aiguë apparue ce matin, non irradiante, associée à une dyspnée légère.</p>
            <div className="result-tags"><span>Texte structuré</span><span>Copiable</span><span>Historisé</span></div>
          </div>
        </div>
        <div className="results-copy reveal">
          <p className="section-index">03 / Deux niveaux de vérité</p>
          <h2>Le texte utile.<br /><span>Sans perdre la source.</span></h2>
          <p>
            VoxLocal conserve séparément le texte traité par l’IA et la
            transcription brute. L’audio original reste réécoutable : le
            résultat ne fait jamais disparaître sa source.
          </p>
        </div>
      </section>

      <section className="architecture section" id="architecture">
        <div className="section-heading reveal">
          <p className="section-index">04 / Une plateforme, deux usages</p>
          <h2>L’IA reste près du soin.</h2>
          <p>Au bureau avec VoxLocal. En mobilité avec RemoteScribe.</p>
        </div>
        <div className="architecture-visual reveal" aria-label="Schéma de fonctionnement de la plateforme VoxLocal">
          <div className="node phone-node"><span>01</span><strong>Mac<br />iPhone</strong><small>Bouton flottant ou RemoteScribe</small></div>
          <div className="connection"><i /><em>Audio clinique</em></div>
          <div className="node host-node"><span>02</span><strong>VoxLocal</strong><small>Modes, pipeline et historique</small></div>
          <div className="connection"><i /><em>Traitement privé</em></div>
          <div className="node engine-node"><span>03</span><strong>Whisper<br />+ LLM</strong><small>Moteurs locaux embarqués</small></div>
        </div>
        <div className="fact-grid">
          {facts.map(([value, label]) => (
            <div className="fact reveal" key={value}>
              <strong>{value}</strong>
              <span>{label}</span>
            </div>
          ))}
        </div>
        <p className="security-note reveal">
          VoxLocal fonctionne déjà hors ligne sur macOS. RemoteScribe ajoute la
          capture mobile sur un réseau local de confiance. Le bridge
          Superwhisper reste disponible comme intégration de transition ; la
          version Windows native est prévue après validation du produit macOS.
        </p>
      </section>

      <section className="hospital section" id="hospital">
        <div className="hospital-orbit" aria-hidden="true"><span>8</span></div>
        <p className="section-index">05 / Déploiement institutionnel</p>
        <h2 className="reveal">Une expérience pensée pour le terrain.<br /><span>Une architecture à adapter à votre hôpital.</span></h2>
        <p className="reveal">
          Parc de postes, modèles locaux, profils soignants, modes cliniques,
          politique de conservation, sécurité réseau et déploiement Windows :
          construisons le cadre qui correspond à votre établissement.
        </p>
        <a className="button button-light reveal" href="mailto:contact@voxlocal.ai?subject=Plan%20Business%20VoxLocal%20pour%20notre%20h%C3%B4pital">
          Contactez-nous pour le plan Business de votre hôpital
          <span>↗</span>
        </a>
        <small>Premier échange · étude de l’infrastructure · plan de déploiement</small>
      </section>

      <footer>
        <a className="brand" href="#top"><span className="brand-eight">8</span><span>VoxLocal</span></a>
        <p>L’IA médicale commence par écouter.</p>
        <div><span>Prototype 2026</span><a href="mailto:contact@voxlocal.ai">Contact</a><a href="#top">Retour en haut ↑</a></div>
      </footer>
    </main>
  );
}
