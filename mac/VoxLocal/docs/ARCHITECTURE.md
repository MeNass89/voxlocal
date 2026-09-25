# Architecture native

VoxLocal macOS est une application SwiftUI avec des adaptateurs AppKit pour le floating panel, le focus, les raccourcis et l’auto-collage.

```text
SwiftUI UI
    ↓
AppState + DictationPipeline
    ├── ModeRepository / SettingsRepository / HistoryRepository
    ├── AudioRecorder (AVFoundation + CoreAudio)
    ├── WhisperEngine → whisper-cli embarqué
    ├── LLMEngine → llama-cli embarqué
    └── PlatformServices (AppKit, Accessibility, presse-papier)
```

Les données restent compatibles avec les JSON de la première version grâce aux clés `snake_case`. Les modèles et l’historique vivent hors du bundle dans `~/Library/Application Support/VoxLocal`, donc une mise à jour de l’app ne les efface pas.

La future version Windows utilisera C#/WinUI 3 et conservera les contrats JSON/WAV ainsi que les runtimes whisper.cpp/llama.cpp, sans tenter de partager l’interface Swift.
