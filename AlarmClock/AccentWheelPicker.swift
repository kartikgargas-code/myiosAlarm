import SwiftUI


struct AccentWheelPicker: View {
    let values: [Int]
    let display: (Int) -> String
    @Binding var selection: Int
    var accent: Color = .accentColor
    var secondary: Color = .secondary


    var body: some View {
        Picker("", selection: $selection) {
            ForEach(values, id: \.self) { value in
                Text(display(value)).tag(value)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}