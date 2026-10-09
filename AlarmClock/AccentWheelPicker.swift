import SwiftUI
import UIKit

/// Wheel picker that tints the SELECTED row with the accent colour.
struct AccentWheelPicker: UIViewRepresentable {
    let values: [Int]
    let display: (Int) -> String
    @Binding var selection: Int
    var accent: Color
    var secondary: Color

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        if let idx = values.firstIndex(of: selection) {
            picker.selectRow(idx, inComponent: 0, animated: false)
        }
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        context.coordinator.parent = self
        if let idx = values.firstIndex(of: selection), picker.selectedRow(inComponent: 0) != idx {
            picker.selectRow(idx, inComponent: 0, animated: false)
        }
        picker.reloadComponent(0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPickerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 90, height: proposal.height ?? 110)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: AccentWheelPicker
        init(_ parent: AccentWheelPicker) { self.parent = parent }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
        func pickerView(_ pickerView: UIPickerView,
                        numberOfRowsInComponent component: Int) -> Int { parent.values.count }
        func pickerView(_ pickerView: UIPickerView,
                        rowHeightForComponent component: Int) -> CGFloat { 36 }

        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int,
                        forComponent component: Int, reusing view: UIView?) -> UIView {
            let label = (view as? UILabel) ?? UILabel()
            label.textAlignment = .center
            let isSelected = pickerView.selectedRow(inComponent: 0) == row
            label.text = parent.display(parent.values[row])
            label.font = .systemFont(ofSize: isSelected ? 22 : 20,
                                     weight: isSelected ? .bold : .regular)
            label.textColor = isSelected ? UIColor(parent.accent) : UIColor(parent.secondary)
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            parent.selection = parent.values[row]
            pickerView.reloadComponent(component)   // recolour the newly-selected row
        }
    }
}