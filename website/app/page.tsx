import type { Metadata } from "next";
import { ImmersiveScene } from "./components/ImmersiveScene";
import { PricingCard } from "./components/PricingCard";
import { ProductShots } from "./components/ProductShots";
import { SecurityGrid } from "./components/SecurityGrid";
import { WaveGlyph } from "./components/WaveGlyph";

function BrandIcon() {
  return (
    <picture>
      <source srcSet="/voxlocal-icon.webp" type="image/webp" />
      <img className="brand-icon" src="/voxlocal-icon.png" alt="" width={28} height={28} />
    </picture>
  );
}

export const metadata: Metadata = {
  title: "VoxLocal — L’IA médicale commence par écouter",
  description:
    "VoxLocal transforme la parole clinique en transcription et en texte structuré par IA, localement sur le poste ou depuis un iPhone avec Remote Scribe.",
};

const journey = [
  {
    number: "01",
    title: "Parler",
    text: "Un clic sur le bouton flottant du Mac, ou « Démarrer la dictée » dans Remote Scribe sur l’iPhone, suffit pour commencer.",
  },
  {
    number: "02",
    title: "Transcrire",
    text: "Whisper transforme l’audio en texte sur le poste. La transcription brute, les segments et le fichier audio restent disponibles.",
  },
  {
    number: "03",
    title: "Structurer",
    text: "Le mode clinique actif guide le modèle de langage local : note médicale, synthèse, email ou format personnalisé.",
  },
  {
    number: "04",
    title: "Utiliser",
    text: "Le texte final est copié ou collé dans l’application de travail, puis conservé avec sa source dans l’historique du poste.",
  },
];

const deployments = [
  {
    title: "Mac",
    status: "Disponible",
    text: "L’app VoxLocal embarque Whisper, le modèle de langage et le serveur Remote Scribe. Un Mac Apple silicon suffit pour un service.",
    detail: "Signature et notarisation Apple avant diffusion large",
  },
  {
    title: "Poste Windows",
    status: "En validation",
    text: "Un hôte Windows reçoit les dictées des iPhone, avec son script d’installation et ses règles de pare-feu.",
    detail: "Validation sur un poste réel de votre parc",
  },
  {
    title: "GPU privé",
    status: "En option",
    text: "Pour les grands modèles, un serveur GPU dédié, joint en HTTPS avec jeton. Le poste reste le point d’entrée.",
    detail: "Région, contrat et rétention validés avec votre DPO",
  },
];

export default function Home() {
  return (
    <main>
      <ImmersiveScene />

      <header className="site-header">
        <a className="brand" href="#top" aria-label="VoxLocal — accueil">
          <BrandIcon />
          <span>VoxLocal</span>
        </a>
        <nav aria-label="Navigation principale">
          <a href="#produit">Produit</a>
          <a href="#securite">Sécurité</a>
          <a href="#deploiement">Déploiement</a>
          <a href="#tarifs">Tarifs</a>
        </nav>
        <a className="header-contact" href="#contact">Nous contacter <span aria-hidden="true">↗</span></a>
      </header>

      <section className="hero" id="top">
        <div className="hero-copy reveal">
          <p className="eyebrow"><span /> Dictée clinique · IA locale · Remote Scribe</p>
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
            <a className="button button-light" href="#produit">Découvrir VoxLocal</a>
            <a className="text-link" href="#fonctionnement">Voir comment ça fonctionne <span aria-hidden="true">↓</span></a>
          </div>
        </div>

        <div className="hero-mark" aria-hidden="true">
          <WaveGlyph />
        </div>

        <div className="hero-foot">
          <span>VoxLocal sur macOS aujourd’hui</span>
          <span className="pulse-dot" />
          <span>Windows demain</span>
        </div>
        <a className="scroll-cue" href="#produit">
          <span className="scroll-line" />
          Faire défiler
        </a>
      </section>

      <section className="product section" id="produit">
        <div className="section-heading reveal">
          <p className="section-index">01 / Produit</p>
          <h2>Le produit aujourd’hui.</h2>
          <p>Captures de l’app macOS et de l’app iPhone, telles qu’elles tournent aujourd’hui.</p>
        </div>
        <ProductShots />
      </section>

      <section className="journey section" id="fonctionnement">
        <div className="section-heading reveal">
          <p className="section-index">02 / Fonctionnement</p>
          <h2>Comment ça marche.</h2>
          <p>De la voix au texte utile, en quatre étapes, sans quitter le poste.</p>
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
        <div className="journey-proof reveal">
          <div className="result-card raw-card">
            <div className="result-topline"><span>Verbatim</span><span>Brut</span></div>
            <p>« Douleur thoracique apparue ce matin, sans irradiation, avec une gêne respiratoire légère… »</p>
          </div>
          <div className="result-card ai-card">
            <div className="result-topline"><span>Note médicale</span><span>Texte final</span></div>
            <p>Douleur thoracique aiguë apparue ce matin, non irradiante, associée à une dyspnée légère.</p>
          </div>
          <p className="journey-proof-note">
            Le texte structuré et la transcription brute sont gardés côte à côte.
            L’audio reste réécoutable : le résultat ne fait jamais disparaître sa source.
          </p>
        </div>
      </section>

      <section className="security section" id="securite">
        <div className="section-heading reveal">
          <p className="section-index">03 / Sécurité</p>
          <h2>Sécurité. <span>La voix reste chez vous.</span></h2>
          <p>Six garanties, chacune détaillée dans le livre blanc sécurité pour votre DSI et votre DPO.</p>
        </div>
        <SecurityGrid />
      </section>

      <section className="deployment section" id="deploiement">
        <div className="section-heading reveal">
          <p className="section-index">04 / Déploiement</p>
          <h2>Déploiement. <span>Du Mac au GPU privé.</span></h2>
          <p>Un poste par service. L’iPhone dicte, le poste transcrit, le GPU privé reste une option.</p>
        </div>
        <div className="deployment-grid">
          {deployments.map((item) => (
            <article className="deployment-card reveal" key={item.title}>
              <p className="deployment-status"><span aria-hidden="true" />{item.status}</p>
              <h3>{item.title}</h3>
              <p>{item.text}</p>
              <small>Reste à faire : {item.detail}</small>
            </article>
          ))}
        </div>
      </section>

      <section className="hospital section" id="tarifs">
        <div className="hospital-orbit" aria-hidden="true"><WaveGlyph /></div>
        <p className="section-index">05 / Tarifs</p>
        <h2 className="reveal">Un pilote dans votre service.<br /><span>Construit avec vos équipes.</span></h2>
        <p className="reveal">
          Pas de grille publique : chaque pilote part de votre parc de postes,
          de vos modes cliniques et de vos règles de sécurité.
        </p>
        <PricingCard />
        <p className="contact-line reveal" id="contact">
          Contact direct : <a href="mailto:contact@voxlocal.ai">contact@voxlocal.ai</a>
        </p>
      </section>

      <footer>
        <a className="brand" href="#top">
          <BrandIcon />
          <span>VoxLocal</span>
        </a>
        <p>L’IA médicale commence par écouter.</p>
        <div><span>Prototype 2026</span><a href="mailto:contact@voxlocal.ai">Contact</a><a href="#top">Retour en haut ↑</a></div>
      </footer>
    </main>
  );
}
