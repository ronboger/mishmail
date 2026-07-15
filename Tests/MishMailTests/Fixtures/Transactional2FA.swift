import Foundation

/// Sanitized regression fixtures for HTML email layout (transactional 2FA).
///
/// Modeled on table-based mail like Emburse 2FA: remote logos/spacers with
/// authored width/height, greeting text, and a verification code. Domains are
/// synthetic (`example-emburse.test`) so fixtures never trigger real network
/// intent under Ask policy. Not a byte-for-byte capture of production mail —
/// use for structure-level regression (complete document vs fragment, image
/// attributes, plain-text alternative).
enum Transactional2FAFixture {
    /// Multipart plain-text alternative — readable without remote images.
    static let plainText = """
        Hello Ron

        Your 2FA verification code is: 119585

        This code expires in 10 minutes.
        """

    /// Complete HTML document (DOCTYPE + html/head/body + author stylesheet).
    /// Images use remote HTTPS URLs and explicit width/height for layout.
    static let completeDocumentHTML = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Your 2FA verification code is: 119585</title>
          <style type="text/css">
            body { margin: 0; padding: 0; background: #f5f5f5; }
            .wrap { width: 600px; margin: 0 auto; background: #ffffff; }
            .code { font-size: 32px; font-weight: bold; letter-spacing: 2px; color: #111; }
            .muted { color: #666; font-size: 13px; }
          </style>
        </head>
        <body>
          <table class="wrap" width="600" cellpadding="0" cellspacing="0" role="presentation">
            <tr>
              <td style="padding: 24px 24px 0 24px;">
                <img src="https://cdn.example-emburse.test/logo.png"
                     width="180" height="48" alt="Example Emburse" border="0">
              </td>
            </tr>
            <tr>
              <td style="font-size:0;line-height:0;height:24px;">
                <img src="https://cdn.example-emburse.test/spacer.gif"
                     width="1" height="24" alt="" border="0">
              </td>
            </tr>
            <tr>
              <td style="padding: 0 24px;">
                <p style="margin:0 0 12px 0;font:15px/1.4 -apple-system,sans-serif;color:#222;">
                  Hello Ron
                </p>
                <p style="margin:0 0 8px 0;font:15px/1.4 -apple-system,sans-serif;color:#222;">
                  Your 2FA verification code is:
                </p>
                <p class="code" style="margin:0 0 16px 0;">119585</p>
                <p class="muted" style="margin:0;">This code expires in 10 minutes.</p>
              </td>
            </tr>
            <tr>
              <td style="padding: 24px;">
                <img src="https://cdn.example-emburse.test/footer.png"
                     width="552" height="80" alt="" border="0">
              </td>
            </tr>
          </table>
        </body>
        </html>
        """

    /// Body fragment only (no DOCTYPE/html shell) — same visual structure.
    static let fragmentHTML = """
        <table width="600" cellpadding="0" cellspacing="0" role="presentation">
          <tr>
            <td>
              <img src="https://cdn.example-emburse.test/logo.png"
                   width="180" height="48" alt="Example Emburse">
            </td>
          </tr>
          <tr>
            <td>
              <img src="https://cdn.example-emburse.test/spacer.gif"
                   width="1" height="24" alt="">
            </td>
          </tr>
          <tr>
            <td>
              <p>Hello Ron</p>
              <p>Your 2FA verification code is:</p>
              <p style="font-size:32px;font-weight:bold;">119585</p>
              <p>This code expires in 10 minutes.</p>
            </td>
          </tr>
        </table>
        """

    /// Hostile dimensions — must be capped by `HTMLBodyLayout.cappedSize`.
    static let hugeImageHTML = """
        <p>Hello</p>
        <img src="https://cdn.example-emburse.test/huge.png"
             width="99999" height="50000" alt="huge">
        """

    /// Quoted reply trail for collapse-gap regression (must stay display:none
    /// and not re-expand measured height via scrollHeight).
    static let withGmailQuoteHTML = """
        <div>New reply text only</div>
        <div class="gmail_quote">
          <blockquote>On Mon, someone wrote:<br>old history that should hide</blockquote>
        </div>
        """
}
