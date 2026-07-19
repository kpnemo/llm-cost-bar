# Privacy

LLM Cost Bar has **no backend**. Nothing you do in the app is sent to us —
there is no "us" to send it to.

- **Your API keys** are stored only in the macOS Keychain on your Mac. They are
  never written to config files, the local database, or logs, and never leave
  your machine except as the authentication header on requests to the vendor
  they belong to.
- **Usage data** (daily spend, per-key totals, balances) is fetched directly
  from each vendor's official API — OpenRouter, Anthropic, OpenAI — over HTTPS
  and stored in a local SQLite database under
  `~/Library/Application Support/LLMCostBar/`.
- **No analytics, no telemetry, no crash reporting.** The only network requests
  the app or its daemon ever make are to the vendor APIs you connected.
- **Diagnostics log** (visible in Settings → Diagnostics) records sync attempts
  and error snippets locally so you can debug failures. It never contains key
  material and never leaves your Mac.

Deleting an account in Settings removes its key from the Keychain and its data
from the local database. Deleting the app and
`~/Library/Application Support/LLMCostBar/` removes everything.
