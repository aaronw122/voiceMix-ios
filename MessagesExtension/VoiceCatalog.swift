import SwiftUI

/// Which backend engine (and therefore which endpoint) a voice routes to.
///
/// The backend rejects the wrong pairing with a 422, so this is load-bearing,
/// not cosmetic: `.elevenlabs` voices go to `POST /convert`, `.modal` voices
/// go to `POST /impersonate`.
enum VoiceEngine: String, Equatable {
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

    /// Phase-1 lineup: the three elevenlabs voices that already exist
    /// server-side. Trump/Obama (modal) are intentionally absent until the
    /// backend ships them in phase 2, otherwise their tiles would 404.
    static let all: [VoicePersona] = [
        VoicePersona(id: "old-man",
                     voiceId: "old-man",
                     engine: .elevenlabs,
                     name: "Old Man",
                     tag: "Weathered · warm · unhurried",
                     monogram: "O",
                     color1: Color(hex: 0xF7B733),
                     color2: Color(hex: 0xFC4A1A),
                     uiColor1: UIColor(hex: 0xF7B733),
                     uiColor2: UIColor(hex: 0xFC4A1A)),
        VoicePersona(id: "young-woman",
                     voiceId: "young-woman",
                     engine: .elevenlabs,
                     name: "Young Woman",
                     tag: "Bright · clear · youthful",
                     monogram: "Y",
                     color1: Color(hex: 0xF857A6),
                     color2: Color(hex: 0x9B5CF6),
                     uiColor1: UIColor(hex: 0xF857A6),
                     uiColor2: UIColor(hex: 0x9B5CF6)),
        VoicePersona(id: "femme-fatale",
                     voiceId: "femme-fatale",
                     engine: .elevenlabs,
                     name: "Femme Fatale",
                     tag: "Sultry · smoky · poised",
                     monogram: "F",
                     color1: Color(hex: 0xB24592),
                     color2: Color(hex: 0x4A1942),
                     uiColor1: UIColor(hex: 0xB24592),
                     uiColor2: UIColor(hex: 0x4A1942)),
        VoicePersona(id: "trump",
                     voiceId: "trump",
                     engine: .modal,
                     name: "Trump",
                     tag: "Brash · bold · unmistakable",
                     monogram: "T",
                     color1: Color(hex: 0xE63946),
                     color2: Color(hex: 0xF6A21D),
                     uiColor1: UIColor(hex: 0xE63946),
                     uiColor2: UIColor(hex: 0xF6A21D)),
        VoicePersona(id: "obama",
                     voiceId: "obama",
                     engine: .modal,
                     name: "Obama",
                     tag: "Measured · resonant · calm",
                     monogram: "O",
                     color1: Color(hex: 0x2193B0),
                     color2: Color(hex: 0x6DD5ED),
                     uiColor1: UIColor(hex: 0x2193B0),
                     uiColor2: UIColor(hex: 0x6DD5ED)),
        VoicePersona(id: "queen-elizabeth",
                     voiceId: "queen_elizabeth",
                     engine: .modal,
                     name: "Queen Elizabeth",
                     tag: "Regal · precise · composed",
                     monogram: "Q",
                     color1: Color(hex: 0x8E2DE2),
                     color2: Color(hex: 0x4A00E0),
                     uiColor1: UIColor(hex: 0x8E2DE2),
                     uiColor2: UIColor(hex: 0x4A00E0)),
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
