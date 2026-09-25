// Screenshots are served from `public/screenshots/` under stable names so a
// newer capture can replace a file without touching this component. After
// replacing a PNG, regenerate its WebP sibling (see website/README.md).
type Shot = {
  name: string;
  alt: string;
  width: number;
  height: number;
  title: string;
  caption: string;
  frame: "window" | "phone";
};

const shots: Shot[] = [
  {
    name: "mac-main",
    alt: "Fenêtre principale de VoxLocal sur macOS : historique des dictées, boutons Importer un audio et Dicter depuis ce Mac, mode actif dans la barre latérale.",
    width: 1600,
    height: 1037,
    title: "VoxLocal sur macOS",
    caption: "L’historique des dictées, le mode clinique actif, la dictée au micro du Mac ou l’import d’un fichier audio. Tout passe par le même pipeline local.",
    frame: "window",
  },
  {
    name: "ios-home",
    alt: "Écran d’accueil de Remote Scribe sur iPhone : poste connecté en chiffré, état Prêt et bouton Démarrer la dictée.",
    width: 644,
    height: 1400,
    title: "Remote Scribe sur iPhone",
    caption: "L’iPhone trouve le poste sur le Wi-Fi du service et s’y connecte en chiffré, puis devient son microphone. Le texte revient sur le poste.",
    frame: "phone",
  },
  {
    name: "mac-remote-scribe",
    alt: "Écran iPhone de VoxLocal sur macOS : QR code et code d’appairage, empreinte TLS, appareils connectés et dernières dictées reçues.",
    width: 1600,
    height: 1037,
    title: "Appairer l’iPhone au poste",
    caption: "Un QR code transmet le code d’appairage et l’empreinte TLS du poste. Les dictées reçues de l’iPhone ou de l’iPad s’affichent ici.",
    frame: "window",
  },
];

export function ProductShots() {
  return (
    <div className="shots">
      {shots.map((shot) => (
        <figure className={`shot shot-${shot.frame} reveal`} key={shot.name}>
          <div className="shot-frame">
            <picture>
              <source srcSet={`/screenshots/${shot.name}.webp`} type="image/webp" />
              <img
                src={`/screenshots/${shot.name}.png`}
                alt={shot.alt}
                width={shot.width}
                height={shot.height}
                loading="lazy"
                decoding="async"
              />
            </picture>
          </div>
          <figcaption>
            <strong>{shot.title}</strong>
            <span>{shot.caption}</span>
          </figcaption>
        </figure>
      ))}
    </div>
  );
}
