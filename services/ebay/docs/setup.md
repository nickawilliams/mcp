# ebay — credential setup and token reseed

The ebay service authenticates to eBay with three credentials, all held on
the single 1Password item `op://Infrastructure/ebay-client-mcp` and seeded
into SSM by terraform (see the `.env` op:// refs and
`terraform/modules/ebay/`):

| 1Password field      | What it is                            | Lifecycle |
| -------------------- | ------------------------------------- | --------- |
| `username`           | App ID (client id)                    | permanent |
| `credential`         | Cert ID (client secret)               | permanent |
| `user-refresh-token` | user OAuth refresh token              | ~18 months|
| `runame`             | RuName (OAuth `redirect_uri` value)   | permanent |
| `signin-url`         | portal-generated branded consent URL  | permanent |

The refresh token is the only credential that expires. It does **not**
rotate on use — the running service refreshes short-lived access tokens
from it in memory — so the only recurring operation is re-minting it when
it dies (~18 months, or earlier if access is revoked from the eBay
account). The service logs `update EBAY_USER_REFRESH_TOKEN` when that
happens.

## Reseed (the recurring case)

```sh
make maintenance/ebay-token   # browser consent -> token -> 1Password
make apply                    # 1Password -> TF_VAR -> SSM
make deploy                   # SSM -> host .env -> container env
```

The make target (`scripts/ebay-user-token.sh`) opens the item's
`signin-url` in the browser; sign in to eBay, **Agree and Continue**, then
paste the full landing URL (it carries `?code=...`, single-use, ~5 min)
back into the prompt. The script exchanges the code and writes the new
refresh token (and expiry date) back to the 1Password item. macOS only.

## From scratch (new keyset or new eBay account)

1. **Developer app.** Register at developer.ebay.com and create a
   production keyset. `username`/`credential` on the 1Password item are
   its App ID / Cert ID.
2. **RuName.** Under the keyset's *User Tokens* → *Get a Token from eBay
   via Your Application*, add an eBay Redirect URL. eBay generates the
   RuName (→ `runame` field). The "auth accepted URL" behind it is where
   the browser lands with the code — any HTTPS page works (eBay rejects
   `http://` and localhost); a dummy page is fine, only the address bar
   matters. Blank falls back to eBay's default accept page.
3. **Consent URL.** On the same portal page, copy the full *Your branded
   eBay Production Sign In (OAuth)* URL ("See all") into the `signin-url`
   field. Use this URL, not a hand-built one: the portal assembles it from
   the keyset's actual scope entitlements. Hand-built URLs that request
   unentitled limited-release scopes (VeRO, eDelivery, …) fail with
   `invalid_scope` — as does the upstream package's setup wizard, which
   hardcodes the full scope table. Re-copy the URL after changing the
   portal's scope selection.
4. **Mint the token.** Run the reseed flow above.

The upstream package's interactive wizard (`npx ebay-mcp setup`) can
substitute for step 4 (use its "paste authorization code" path with the
same consent URL, then copy `EBAY_USER_REFRESH_TOKEN` from the `.env` it
writes at the installed package root into 1Password — and delete that
file, it holds the live token). The make target exists because the wizard
cannot run non-interactively, trips `invalid_scope` on its generated URL,
and leaves plaintext secrets behind.

## Notes

- Scopes are baked into the refresh token at consent; tools whose scopes
  weren't granted 403 at runtime until the next reseed widens them.
- The eBay developer portal's *User Tokens* page mints OAuth user tokens
  in-UI but never displays the refresh token — it is only ever returned
  by the code exchange, which is why the script (or wizard) must do it.
- Sandbox is out of scope throughout: the service, the script, and the
  stored credentials are production-only. A sandbox keyset would need its
  own RuName and consent URL against `auth.sandbox.ebay.com`.
