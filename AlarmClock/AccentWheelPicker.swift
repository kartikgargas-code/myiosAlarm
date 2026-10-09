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
        // reloadComponent() resets the selected row to 0 -> reload FIRST, re-select AFTER.
        picker.reloadComponent(0)
        if let idx = values.firstIndex(of: selection) {
            picker.selectRow(idx, inComponent: 0, animated: false)
        }
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
            let isSelected = parent.values[row] == parent.selection
            label.text = parent.display(parent.values[row])
            label.font = .systemFont(ofSize: isSelected ? 22 : 20, weight: .regular)
            label.textColor = isSelected ? UIColor(parent.accent) : UIColor(parent.secondary)
            return label
        }


        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            parent.selection = parent.values[row]
            // Recolour visible rows in place. Do NOT reloadComponent here.
            for r in 0..<parent.values.count {
                guard let label = pickerView.view(forRow: r, forComponent: component) as? UILabel else { continue }
                let isSelected = parent.values[r] == parent.selection
                label.textColor = isSelected ? UIColor(parent.accent) : UIColor(parent.secondary)
                label.font = .systemFont(ofSize: isSelected ? 22 : 20, weight: .regular)
            }
        }
    }
}