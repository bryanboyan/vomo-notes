import SwiftUI

extension Color {
    static let vomoPurple = Color(red: 0.486, green: 0.227, blue: 0.929)
    static let vomoPurpleLight = Color(red: 0.655, green: 0.545, blue: 0.984)
}

extension ShapeStyle where Self == Color {
    static var vomoPurple: Color { Color.vomoPurple }
    static var vomoPurpleLight: Color { Color.vomoPurpleLight }
}
