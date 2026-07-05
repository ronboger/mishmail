import Foundation

/// Starter snippets seeded once on first launch (Ron's Notion Mail set), so
/// typing `/` shows something useful before you've made any of your own.
/// Seeding is one-time (a UserDefaults flag), so deleting them stays deleted.
enum SnippetDefaults {
    static let items: [SnippetImport.Item] = [
        .init(name: "intro find time", body: """
        Thanks {bcc_first_name} for the intro (moving you to bcc)!

        It's great to meet you {first_name}, let's chat. What are some times that work for you in the coming weeks?

        Best,
        {my_first_name}
        """, movesToBcc: true),
        .init(name: "Follow Up", body: """
        Hi {first_name},
        Thank you for taking the time to meet with us today. Here are the main points we covered today:

        {key_point_1}

        {key_point_2}

        As we discussed, our next steps are:

        {action_item_1}

        {action_item_2}

        {action_item_3}

        If you have any questions or need any additional information in the meantime, please don't hesitate to reach out.
        """, movesToBcc: false),
        .init(name: "Schedule Reply", body: """
        Hi {first_name},

        Great! I'd love to chat. Please find my availability here (preference for Fridays if possible): https://calendar.notion.so/meet/rboger/rb30

        Best,
        {my_first_name}
        """, movesToBcc: false),
        .init(name: "Schedule Outreach", body: """
        Hi {first_name}, I'd love to find a time to chat. I'm sharing my availability below:
        """, movesToBcc: false),
        .init(name: "Zoom Link", body: "Here's my zoom link: {zoom_link}", movesToBcc: false),
    ]
}
