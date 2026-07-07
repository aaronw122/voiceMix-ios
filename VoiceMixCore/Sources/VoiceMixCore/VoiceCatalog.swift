import SwiftUI

/// Which backend engine (and therefore which endpoint) a voice routes to.
///
/// The backend rejects the wrong pairing with a 422, so this is load-bearing,
/// not cosmetic: `.elevenlabs` voices go to `POST /convert`, `.modal` voices
/// go to `POST /impersonate`.
public enum VoiceEngine: String, Equatable {
    case elevenlabs
    case modal
}

/// A selectable voice tile.
///
/// `id` is the stable SwiftUI/`Identifiable` identity used for `ForEach`,
/// `Equatable`, and the page-dot selection. `voiceId` is the value that goes
/// on the wire to the backend — keep them separate so UI churn never changes
/// the network contract.
struct VoicePersona: Identifiable, Equatable {
    /// Stable UI identity (SwiftUI `Identifiable`, page-dot selection).
    let id: String
    /// Backend voice id sent in the multipart `voiceId` field.
    let voiceId: String
    /// Endpoint selector — must match the backend's engine for this voice.
    let engine: VoiceEngine
    let name: String
    let tag: String
    let monogram: String
    /// Asset-catalog name for the persona's cartoon art, resolved from the extension
    /// bundle at runtime (same place `sample.mp3` lives). When the named asset is absent,
    /// `PersonaAvatarView` falls back to `placeholderSymbol` — so a slot can ship before
    /// its art does, and real art drops in later with no code change.
    let imageName: String?
    /// SF Symbol shown inside the gradient ring until real cartoon art lands.
    let placeholderSymbol: String
    let color1: Color
    let color2: Color
    let uiColor1: UIColor
    let uiColor2: UIColor

    private init(id: String,
                 voiceId: String,
                 engine: VoiceEngine,
                 name: String,
                 tag: String,
                 monogram: String,
                 imageName: String?,
                 placeholderSymbol: String,
                 hex1: UInt32,
                 hex2: UInt32) {
        self.id = id
        self.voiceId = voiceId
        self.engine = engine
        self.name = name
        self.tag = tag
        self.monogram = monogram
        self.imageName = imageName
        self.placeholderSymbol = placeholderSymbol
        self.color1 = Color(hex: hex1)
        self.color2 = Color(hex: hex2)
        self.uiColor1 = UIColor(hex: hex1)
        self.uiColor2 = UIColor(hex: hex2)
    }

    // `voiceId` + `engine` are the values the backend accepts on the wire — the
    // display `name` is cosmetic and can differ from the voiceId.
    //   Real fine-tuned voices:   trump, dwarkesh, elon           -> .modal
    //   All voiceIds above exist on the server /voices, so the DEBUG preflight passes.
    static let all: [VoicePersona] = [
        VoicePersona(id: "trump",
                     voiceId: "trump",
                     engine: .modal,
                     name: "El Prez",
                     tag: "Brash · bold · unmistakable",
                     monogram: "E",
                     imageName: "persona-trump",
                     placeholderSymbol: "megaphone.fill",
                     hex1: 0xE63946,
                     hex2: 0xF6A21D),
        VoicePersona(id: "dwarkesh",
                     voiceId: "dwarkesh",
                     engine: .modal,
                     name: "Dwarkesh",
                     tag: "Curious · rapid · incisive",
                     monogram: "D",
                     imageName: "persona-dwarkesh",
                     placeholderSymbol: "mic.fill",
                     hex1: 0x2193B0,
                     hex2: 0x6DD5ED),
        VoicePersona(id: "elon",
                     voiceId: "elon",
                     engine: .modal,
                     name: "Tech Magnate",
                     tag: "Dry · halting · visionary",
                     monogram: "T",
                     imageName: "persona-elon",
                     placeholderSymbol: "bolt.fill",
                     hex1: 0x4776E6,
                     hex2: 0x8E54E9),
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}
