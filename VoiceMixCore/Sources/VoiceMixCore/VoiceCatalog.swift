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
                 hex1: UInt32,
                 hex2: UInt32) {
        self.id = id
        self.voiceId = voiceId
        self.engine = engine
        self.name = name
        self.tag = tag
        self.monogram = monogram
        self.color1 = Color(hex: hex1)
        self.color2 = Color(hex: hex2)
        self.uiColor1 = UIColor(hex: hex1)
        self.uiColor2 = UIColor(hex: hex2)
    }

    static let all: [VoicePersona] = [
        VoicePersona(id: "femme-fatale",
                     voiceId: "femme-fatale",
                     engine: .elevenlabs,
                     name: "Femme Fatale",
                     tag: "Sultry · smoky · poised",
                     monogram: "F",
                     hex1: 0xB24592,
                     hex2: 0x4A1942),
        VoicePersona(id: "trump",
                     voiceId: "trump",
                     engine: .modal,
                     name: "Trump",
                     tag: "Brash · bold · unmistakable",
                     monogram: "T",
                     hex1: 0xE63946,
                     hex2: 0xF6A21D),
        VoicePersona(id: "obama",
                     voiceId: "obama",
                     engine: .modal,
                     name: "Obama",
                     tag: "Measured · resonant · calm",
                     monogram: "O",
                     hex1: 0x2193B0,
                     hex2: 0x6DD5ED),
        VoicePersona(id: "queen-elizabeth",
                     voiceId: "queen_elizabeth",
                     engine: .modal,
                     name: "Queen Elizabeth",
                     tag: "Regal · precise · composed",
                     monogram: "Q",
                     hex1: 0x8E2DE2,
                     hex2: 0x4A00E0),
        VoicePersona(id: "young-woman",
                     voiceId: "young-woman",
                     engine: .elevenlabs,
                     name: "Young Woman",
                     tag: "Bright · clear · youthful",
                     monogram: "Y",
                     hex1: 0xF857A6,
                     hex2: 0x9B5CF6),
        VoicePersona(id: "old-man",
                     voiceId: "old-man",
                     engine: .elevenlabs,
                     name: "Old Man",
                     tag: "Weathered · warm · unhurried",
                     monogram: "O",
                     hex1: 0xF7B733,
                     hex2: 0xFC4A1A),
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
