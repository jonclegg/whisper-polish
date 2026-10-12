import SwiftUI

/// Words the keyboard added to its dictionary on its own, to look over and remove.
struct LearnedWordsView: View {
    @State private var words = LearnedWords.listed()

    var body: some View {
        List {
            Section {
                ForEach(words, id: \.self) { word in
                    Text(word)
                }
                .onDelete { offsets in
                    for offset in offsets { LearnedWords.remove(words[offset]) }
                    words.remove(atOffsets: offsets)
                }
            } footer: {
                if !words.isEmpty {
                    Text("Words you kept from the suggestion bar and made-up words you typed more than once. A removed word stops being suggested; it comes back only if you teach it again.")
                }
            }
        }
        .overlay {
            if words.isEmpty {
                ContentUnavailableView(
                    "No learned words",
                    systemImage: "character.book.closed",
                    description: Text("Words the keyboard learns from your typing show up here after it next opens.")
                )
            }
        }
        .toolbar {
            if !words.isEmpty { EditButton() }
        }
        .navigationTitle("Learned words")
        .navigationBarTitleDisplayMode(.inline)
    }
}
