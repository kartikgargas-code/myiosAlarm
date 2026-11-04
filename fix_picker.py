with open('AlarmClock/SoundPickerView.swift', 'r', encoding='utf-8') as f:
    content = f.read()

idx = content.find('private func isSectionExpanded')
if idx >= 0:
    end_idx = content.find('    private var selectedSoundDisplayName', idx)
    if end_idx >= 0:
        old_text = content[idx:end_idx]
        
        new_text = '''    private func isSectionExpanded(_ id: String) -> Bool {
        // If search is active, show all sections expanded (no search in picker yet)
        // For child folders (inner folders inside "Imported sounds"), always use persisted state
        // so they stay open/closed as the user left them when parent collapses/reopens
        let isChildFolder = id != "importedSounds" && id != "__loose__" && id != "defaultSounds"
        if isChildFolder {
            return soundsUIState.isExpanded(id)
        }
        // For alarm sound picker: open the section containing the currently selected sound
        // This only applies when the set is empty (first load)
        if soundsUIState.expandedIds.isEmpty && !pickerVisibleGroups.isEmpty {
            // Find which group contains the currently selected sound
            if case .imported(let selectedId) = selectedSound,
               let group = pickerVisibleGroups.first(where: { $0.sounds.contains(where: { $0.id == selectedId }) }) {
                // If it's a loose file, open the singleFiles section
                if group.id == "__loose__" {
                    return id == "__loose__"
                }
                // Otherwise open the importedSounds parent section
                return id == "importedSounds" || id == group.id
            }
            // For built-in or default sound, open defaultSounds section
            if case .builtIn = selectedSound {
                return id == "defaultSounds"
            }
            if case .systemDefault = selectedSound {
                return id == "defaultSounds"
            }
            // Default: expand first available section
            let firstGroup = pickerVisibleGroups.first(where: { !$0.sounds.isEmpty })
            if let firstGroup = firstGroup {
                if firstGroup.id == "__loose__" {
                    return id == "__loose__"
                }
                return id == "importedSounds"
            }
        }
        return soundsUIState.isExpanded(id)
    }
    
    private func toggleSection(_ id: String) {
        soundsUIState.toggle(id)
    }
    
    // Seeds the persisted set with the sections the default logic auto-opens.
    // Without this, a child folder opened only by the default (e.g. the folder
    // holding the selected sound) has no entry in the set - the default branch
    // is dead as soon as anything is toggled - so collapsing and reopening the
    // parent re-derives the child from the set and it comes back closed.
    private func seedDefaultExpandedSectionsIfEmpty() {
        guard soundsUIState.expandedIds.isEmpty, !pickerVisibleGroups.isEmpty else { return }
        var seedIds: [String] = []
        if case .imported(let selectedId) = selectedSound,
           let group = pickerVisibleGroups.first(where: { $0.sounds.contains(where: { $0.id == selectedId }) }) {
            if group.id == "__loose__" {
                seedIds.append("__loose__")
            } else {
                seedIds.append("importedSounds")
                seedIds.append(group.id)
            }
        } else if case .builtIn = selectedSound {
            seedIds.append("defaultSounds")
        } else if case .systemDefault = selectedSound {
            seedIds.append("defaultSounds")
        } else if let firstGroup = pickerVisibleGroups.first(where: { !$0.sounds.isEmpty }) {
            seedIds.append(firstGroup.id == "__loose__" ? "__loose__" : "importedSounds")
        }
        guard !seedIds.isEmpty else { return }
        soundsUIState.seedIfEmpty(ids: seedIds)
    }
'''
        
        new_content = content[:idx] + new_text + content[end_idx:]
        with open('AlarmClock/SoundPickerView.swift', 'w', encoding='utf-8') as f:
            f.write(new_content)
        print('Replaced successfully')