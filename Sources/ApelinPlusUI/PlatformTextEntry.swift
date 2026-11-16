import SwiftUI

// Text-entry modifiers that only exist on one side of the platform line.
//
// `.textInputAutocapitalization` is iOS-only, and macOS has no soft
// keyboard to apply it to, so writing it inline turns every field into a
// conditional. These wrappers keep the call sites reading like ordinary
// SwiftUI and leave the `#if` in one place.

extension View {
    /// For keys, tokens and identifiers: no capitalisation, no autocorrect.
    @ViewBuilder
    func plainTextEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    /// For a name a person types: capitalise each word, leave autocorrect
    /// alone so a product name is not "fixed".
    @ViewBuilder
    func nameTextEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    /// Decimal and integer fields: a decimal pad where there is one.
    @ViewBuilder
    func numberTextEntry() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
