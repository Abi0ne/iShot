# iShot — Clone di **iScreen Shoter**

> Documentazione di progetto: analisi dell'originale + ragionamento + architettura del clone.
> Tutto il progetto vive sotto questa cartella (root del repo).

---

## 1. Obiettivo

Ricostruire, da zero e in **Swift nativo**, l'app macOS **iScreen Shoter** (Mac App Store,
`com.screenshot.iscreenshoter`) come app **menu bar** per screenshot con annotazione, OCR,
registrazione video, scorciatoie globali e impostazioni.

L'originale è **chiusa** (nessuna repo pubblica): il clone è una **reimplementazione** basata
sull'analisi del bundle installato in `/Applications/iScreen Shoter.app`.

---

## 2. Analisi dell'originale (iScreen Shoter)

### 2.1 Identità (dal bundle)
| Campo | Valore |
|---|---|
| Bundle ID | `com.screenshot.iscreenshoter` |
| Versione | `3.0.2` (build `28`) |
| Team ID | `DY69LKWHQV` |
| Principale | `NSApplication` |
| `LSUIElement` | `true` → **app menu bar**, niente icona Dock |
| Binario | Mach-O **universale** (x86_64 + arm64) |
| Min. sistema | macOS 10.15 |
| Build | Xcode 15, macOS SDK 14.0, **Swift** |
| Sandbox | sì (App Store) |

### 2.2 Entitlements
- `com.apple.security.app-sandbox`
- `com.apple.security.application-groups` → `DY69LKWHQV.AppContext.data`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.network.client`

### 2.3 Framework di terze parti (da `Contents/Frameworks/`)
- **SwiftyJSON** — parsing JSON
- **Alamofire** — rete
- **Firebase** (Core, Crashlytics, Installations) + GoogleDataTransport/GoogleUtilities/FBLPromises/nanopb — analytics & crash
- **SwiftyStoreKit** — in-app purchase (abbonamento)
- **SnapKit** — Auto Layout
- **Lottie** — animazioni (caricamento, emote)
- **HotKey** — scorciatoie da tastiera globali

### 2.4 Helper separato
`Contents/Library/LoginItems/VideoRecrdingHelper.app`
(`com.screenshot.iscreenshoter.shoterHelper`, `LSBackgroundOnly=true`)
→ processo in background dedicato alla **registrazione video** (audio/schermo).

### 2.5 Feature (dal `Localizable.strings` + risorse)
- **Screenshot**: regione (drag), fullscreen, finestra.
- **Annotazione**: penna, rettangolo, ellisse, linea, freccia, testo, **mosaico**, aggiungi immagine, undo.
- **OCR** "Picture to Text": riconoscimento testo (anche "ottimizza per tabelle").
- **Registrazione video** dello schermo.
- **Scorciatoie globali** configurabili (Screenshot Shortcuts, OCR Shortcuts).
- **Salva**: cartella, formato, nome file, Quick Save.
- **Copia** negli appunti, **Pin** sul desktop, **Share** (anche con amici).
- **Impostazioni**: Save Location, Startup (avvio a login), Shortcut, Formato.
- **AI** ("Siders AI"): traduci/spiega/riassumi il testo scansionato (prodotto a pagamento).
- **Store**: abbonamento mensile, Restore Purchase, Support Us.
- **Localizzazione**: en, de, es, fr, ja, ru, zh-Hans.

---

## 3. Ragionamento & decisioni di progetto

### 3.1 Perché SwiftPM + `build-app.sh`
Su questo Mac c'è **solo Command Line Tools** (no Xcode). La convenzione già usata nei tuoi
altri progetti (iRufus, reika-monitor, wolwatcher, NetScout) è:
- package **SwiftPM** in `app/` (target eseguibile),
- script `scripts/build-app.sh` che:
  1. seleziona un **SDK CLT funzionante** (evita i problemi SwiftUI-macro dell'SDK più recente),
  2. `swift build -c release --product iShot`,
  3. **impacchetta** il binario in `build/iShot.app` con `Info.plist` (`LSUIElement=true`),
  4. **firma con il certificato locale "iShot Local Signing"** (ad-hoc solo se manca) e verifica; con `--install` copia in `/Applications`.

→ Seguo esattamente questa convenzione.

### 3.2 Scelte tecniche
| Area | Scelta | Motivo |
|---|---|---|
| UI | **AppKit** (NSWindow/NSView/NSStatusItem) | app menu bar + drawing custom; SwiftUI non serve e complica la build CLT |
| Cattura schermo | **ScreenCaptureKit** (`SCScreenshotManager`) | API attuale; `CGDisplayCreateImage` è deprecata e fa richiedere di nuovo il permesso |
| Selezione regione | **overlay** borderless a schermo intero + drag | standard per screenshot tool |
| OCR | **VisionKit** Live Text (`ImageAnalyzer` + `ImageAnalysisOverlayView`) nell'editor; **Vision** come fallback | testo selezionabile direttamente sull'immagine, offline |
| Scorciatoia globale | **Carbon** `RegisterEventHotKey` | API nativa, nessuna libreria esterna |
| Registrazione video | **ScreenCaptureKit** (macOS 12.3+) | API moderna per capture+audio; fallback: solo se disponibile |
| Persistenza | **UserDefaults** | cartella/formato/nome/shortcut |
| Pin | **NSWindow** borderless floating | overlay trasparente sempre-in-cima |
| Share | **NSSharingServicePicker** | nativo |

### 3.3 Scope
**Incluso (core):** menu bar, cattura regionale + fullscreen, editor annotazione completo
(penna/rettangolo/ellisse/linea/freccia/testo/mosaico/undo/colori), salva/copia/pin, OCR,
scorciatoia globale, impostazioni.

**Incluso se va (nice-to-have):** registrazione video (ScreenCaptureKit), cattura finestra.

**Semplificato/omesso rispetto all'originale:** Firebase, SwiftyStoreKit/IAP, Siders AI,
Lottie, 7 lingue (parto da en + it), helper separato (registro nello stesso processo).

---

## 4. Architettura del clone

### 4.1 Layout cartelle
```
iShot/
├── ARCHITECTURE.md            ← questo file
├── README.md                  ← come buildare/avviare
├── app/
│   ├── Package.swift          ← SwiftPM, target eseguibile "iShot", macOS 14+
│   └── Sources/iShot/
│       ├── main.swift                  # entry point: NSApplication + delegate
│       ├── AppDelegate.swift           # setup status item, menu, shortcut, windows
│       ├── StatusMenu.swift            # menu della barra (Capture/OCR/Record/Settings/Quit)
│       ├── Capture/
│       │   ├── ScreenCapture.swift     # SCScreenshotManager, fullscreen/regione
│       │   └── RegionOverlay.swift     # overlay selezione regione (drag, multi-schermo)
│       ├── Editor/
│       │   ├── Annotation.swift        # modello: tipo, punti, colore, spessore
│       │   ├── Tools.swift             # enum Tool + stato editor
│       │   ├── EditorView.swift        # NSView custom: disegna immagine + annotazioni
│       │   └── EditorWindow.swift      # finestra editor + toolbar + azioni
│       ├── OCR/
│       │   └── OCRService.swift        # Vision VNRecognizeTextRequest
│       ├── Recording/
│       │   └── ScreenRecorder.swift    # ScreenCaptureKit start/stop → file video
│       ├── Shortcut/
│       │   └── GlobalShortcut.swift    # Carbon RegisterEventHotKey
│       ├── Settings/
│       │   ├── SettingsStore.swift     # UserDefaults: cartella, formato, nome, shortcut
│       │   └── SettingsWindow.swift    # finestra impostazioni
│       └── Support/
│           ├── PinWindow.swift         # finestra floating "pin"
│           └── Exporter.swift          # salva file / copia clipboard / share
├── scripts/
│   └── build-app.sh            # build release + bundle .app + firma con certificato locale (+ --install)
└── build/
    └── iShot.app               ← prodotto (generato)
```

### 4.2 Moduli e responsabilità
- **main / AppDelegate**: avvia `NSApplication` (`.accessory`), crea `NSStatusItem`,
  registra la scorciatoia globale, gestisce i comandi del menu.
- **StatusMenu**: voce "Cattura regione" (default), "Cattura schermo intero",
  "Registra schermo", "OCR ultimo screenshot", "Impostazioni…", "Info", "Esci".
- **ScreenCapture**: ritorna `NSImage`/`CGImage` di uno schermo o di un rettangolo globale.
- **RegionOverlay**: finestra borderless su tutto lo schermo (o tutti gli schermi),
  sfondo semi-trasparente, drag per il rettangolo; al `mouseUp` ritorna il rettangolo
  (coordinate globali) e si chiude.
- **Annotation**: struct `{ id, tool, points: [CGPoint], color, lineWidth, text? }`.
  Array ordinata = ordine di disegno. Undo = rimuovi l'ultimo.
- **Tools**: `enum { select, pen, rect, ellipse, line, arrow, text, mosaic }` + colore/spessore correnti.
- **EditorView**: `draw(_:)` → disegna l'immagine di base, poi ogni annotazione
  (shape, freccia con punta, penna come path, testo, mosaico come blur/pixelation della zona).
  Gestisce mouse per creare/muovere annotazioni a seconda del tool attivo.
- **EditorWindow**: mostra `EditorView` + toolbar (tool, colori, spessore, undo, cancella)
  + barra azioni (Salva, Copia, Pin, OCR, Condividi, Esc).
- **OCRService**: `func recognize(from image: NSImage) -> String` via Vision.
- **ScreenRecorder**: `start()/stop()` con ScreenCaptureKit → salva `.mov` nella cartella.
- **GlobalShortcut**: registra una combo (es. `⌥⇧A`) che lancia la cattura regionale;
  la combo è configurabile in Impostazioni.
- **SettingsStore**: `saveDir`, `format` (png/jpg), `fileNamePrefix`, `hotkey`, `launchAtLogin`.
- **Exporter**: salva in `saveDir` con nome `prefix_YYYYMMDD_HHMMSS.<ext>`,
  copia negli appunti, apre `NSSharingServicePicker`.
- **PinWindow**: finestra floating con l'immagine finale, sempre in cima, chiudibile.

### 4.3 Flussi principali
```
[Menu / Hotkey] → RegionOverlay (drag) → ScreenCapture(regione)
   → EditorWindow(EditorView + annotazioni)
        → Salva | Copia | Pin | OCR | Share

[Menu] → OCR ultimo screenshot → editor in modalità testo (Live Text)

[Menu] → ScreenRecorder.start() → … → stop() → file .mov in saveDir
```

### 4.4 Modello dati
```swift
enum Tool { case select, pen, rect, ellipse, line, arrow, text, mosaic }

struct Annotation: Identifiable {
    let id: UUID
    var tool: Tool
    var points: [CGPoint]      // pen: polyline; rect/line/arrow: 2 punti; text: 1
    var color: NSColor
    var lineWidth: CGFloat
    var text: String?          // solo per .text
}

struct Settings {
    var saveDir: String        // default ~/Pictures/Schermate
    var format: String         // "png" | "jpg"
    var fileNamePrefix: String // default "iShot"
    var hotkey: String         // es. "⌥⇧A"
    var launchAtLogin: Bool
}
```

---

## 5. Build & run

### 5.1 `scripts/build-app.sh` (in sintesi)
1. **SDK CLT**: se `xcode-select` non punta a Xcode, sceglie l'SDK più recente
   funzionante (come iRufus) ed esporta `SDKROOT`.
2. `swift build --package-path app -c release --product iShot`
3. `BIN=$(swift build --show-bin-path)/iShot`
4. Crea `build/iShot.app/Contents/{MacOS,Resources}`, copia il binario.
5. Scrive `Contents/Info.plist` con:
   - `CFBundleIdentifier = com.local.ishot`
   - `CFBundleExecutable = iShot`
   - `LSUIElement = true` (menu bar)
   - `NSPrincipalClass = NSApplication`
   - `LSMinimumSystemVersion = 14.0`
   - `NSHighResolutionCapable = true`
   - `NSCameraUsageDescription`/screen recording note (permessi)
6. `codesign --force --sign "iShot Local Signing" build/iShot.app` + `codesign --verify` (identità stabile: il permesso Screen Recording sopravvive ai rebuild).

### 5.2 Avvio
```
cd iShot
scripts/build-app.sh
open build/iShot.app
```
→ appare l'icona nella **barra di stato**. Al primo uso macOS chiede il permesso
**Registrazione schermo** (necessario per catturare/registrare).

---

## 6. Piano di implementazione (step)
1. Scaffold: `Package.swift`, `main.swift`, `AppDelegate`, `StatusMenu` → app menu bar che parte.
2. `ScreenCapture` + `RegionOverlay` → cattura regionale funzionante.
3. `Annotation`/`Tools`/`EditorView`/`EditorWindow` → editor con tool base (penna, rett, linea, freccia, testo) + undo.
4. `Exporter` → salva + copia + pin.
5. `OCRService` → OCR.
6. `GlobalShortcut` + `SettingsStore`/`SettingsWindow` → hotkey + impostazioni.
7. `ScreenRecorder` (ScreenCaptureKit) → registrazione video.
8. `build-app.sh` + `Info.plist` + firma → `.app` finale; test end-to-end.

---

## 7. Limiti / follow-up
- **Registrazione video**: ScreenCaptureKit richiede macOS 12.3+ e permesso; se dà problemi
  in build CLT, la isoliamo e la rendiamo opzionale.
- **Cattura finestra**: richiede enumerazione finestre (accessibility) → follow-up.
- **Multi-schermo**: l'overlay parte da tutto lo schermo; gestione multi-monitor da rifinire.
- **Localizzazione**: parto da en/it; le altre 5 lingue sono follow-up.
- **IAP/AI/Firebase**: fuori scope del clone (funzionalità di business dell'originale).

---

## 8. Stato
- [x] Analisi dell'originale
- [x] Decisioni di progetto
- [x] Architettura definita (questo file)
- [x] Implementazione (step 1–8)
- [x] Build `.app` + test

**v0.1.0** — tutti gli step del piano completati:
- 16 file Swift (~2550 righe), tutti i moduli del §4.2 implementati.
- Build release + bundle + firma con certificato locale via `scripts/build-app.sh`; icona `AppIcon.icns` generata.
- Smoke test: l'app parte e resta in esecuzione come menu bar app.
- Versione: `CFBundleShortVersionString = 0.1.1`, `CFBundleVersion` = numero commit git.

**v0.1.1**
- Firma con certificato locale stabile (`scripts/create-signing-cert.sh`): il permesso Screen Recording
  sopravvive ai rebuild; `build-app.sh --install` installa in `/Applications`.
- Cattura via ScreenCaptureKit (`SCScreenshotManager`) al posto di `CGDisplayCreateImage`.
- OCR come Live Text direttamente nell'editor (VisionKit): testo selezionabile e copiabile sull'immagine.

**v0.1.2**
- Aggiornamento automatico all'apertura (`Support/Updater.swift`): legge l'ultima GitHub Release,
  chiede conferma, scarica `iShot.zip`, verifica che l'app nuova soddisfi il designated requirement
  di quella in esecuzione (stesso certificato), sostituisce il bundle e riavvia.
  Menu "Check for Updates…", opzione nelle impostazioni, "Skip This Version".
- `scripts/release.sh`: build firmata + zip + tag + push + `gh release create`.
- Condivisione su WhatsApp: WhatsApp per Mac non ha una Share extension, quindi `ShareExtras`
  (in `Support/Exporter.swift`) aggiunge una voce "WhatsApp" al picker che apre l'immagine in
  WhatsApp e la copia negli appunti.
