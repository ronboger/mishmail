import Foundation

/// Starter snippets seeded once on first launch, so typing `/` shows something
/// useful before you've made any of your own. Kept minimal and free of personal
/// calendar links / names — users add their own from Settings or import.
/// Seeding is one-time (a UserDefaults flag), so deleting them stays deleted.
enum SnippetDefaults {
    static let items: [SnippetImport.Item] = [
        .init(name: "intro find time", body: """
        Thanks {bcc_first_name} for the intro (moving you to bcc)!

        It's great to meet you {first_name}, let's chat. What are some times that work for you in the coming weeks?

        Best,
        {my_first_name}
        """, movesToBcc: true),
        .init(name: "cal", body: """
        Hi {first_name},

        Happy to find a time — feel free to send a few options that work for you.

        Best,
        {my_first_name}
        """, movesToBcc: false),
    ]
}
