# Optional local GitHub App acceptance

## Organization Device Flow connection

Connect at `/organizations/:organization/settings/github/connection`. Complete
fresh Device Flow consent for the organization, install the Fornacast App in the
intended GitHub organization, and select/recheck its installation. Confirm the
immutable GitHub organization and installation IDs, effective repository list
and read permissions for contents, issues and pull requests. Personal saved
credentials are not transferred to the organization.

The public Client ID `Iv23lizCVE3E24s7fCA0` and Device Flow are sufficient for
this connection; the App private key and webhook settings below are separate.
Authorization without an installation must show **installation required**;
missing permissions must prevent activation. Reconnect must clear ready status
and require verification again. Check that another current local manager can
manage the connection and that local authorizer removal leaves committed
organization work independent of that user.

Once existing jobs have settled, explicitly activate the organization source and
start **Sync now**. Record the run ID and source snapshot without exposing tokens.
Acceptance requires a terminal successful aggregate run, every discovered
repository succeeded, and actual LFS download/integrity verification. A repository
GET, public Git refs, successful authorization or mocked test is insufficient.
GitHub-side installation and consent changes require the operator's action.

## Separate private-key installation integration

The optional installation-token integration is available at
`/organizations/:organization/settings/github/app/advanced`. The Device Flow
client ID alone does not configure this integration; it requires the four App
settings below. Those settings are not prerequisites for organization Device
Flow or legacy saved-credential synchronization. The accepted saved-PAT Git/LFS
endpoint checks and remaining credential-specific gates are recorded in the
[acceptance ledger](superpowers/plans/2026-09-07-github-org-sync-acceptance.md).

Device Flow does not expand the App's effective repository permissions. Check
GitHub-side installation permissions and selected repository coverage separately
from the optional server settings below. Public repository discovery, metadata,
and Git refs can succeed while LFS download authorization returns HTTP 403.
Connection success alone does not establish successful synchronization; verify
LFS access and a successful terminal synchronization result as well.

## Configure the local process

Use an explicitly designated writable GitHub test organization and test
repositories. Record their immutable GitHub IDs and the corresponding local
organization before admitting mirror writes.

Configure a GitHub App with Metadata read, Contents write, Issues write,
Pull requests write, and Administration write for the enabled capabilities.
Administration is also required by the current Git mirror policy. Install it on
the designated test repositories. Enable the installation, installation
repositories, repository, push, create, delete, issues, issue comment, pull
request, and release webhook events used by the mirror.

Set the App setup URL to the local organization's callback:
`http://localhost:4890/organizations/<local-organization>/settings/github/callback`.
Use the install action in the App settings so the callback retains the current
owner session and generated state. A callback or an old installation webhook
alone does not bind an organization. GitHub must also be able to deliver signed
webhooks to an operator-configured HTTPS URL forwarding
`/api/webhooks/github` to the local API listener at `127.0.0.1:4891`.

Development and release processes accept the same four environment variables:

| Variable | Value |
| --- | --- |
| `FORNACAST_GITHUB_APP_ID` | Positive decimal GitHub App ID |
| `FORNACAST_GITHUB_APP_SLUG` | App slug from its GitHub URL |
| `FORNACAST_GITHUB_APP_PRIVATE_KEY_FILE` | Absolute path to the App's PEM private key |
| `FORNACAST_GITHUB_WEBHOOK_SECRET` | The same webhook secret configured on GitHub |

`FORNACAST_GITHUB_WEBHOOK_MAX_BYTES` is optional and defaults to 1,048,576;
larger limits are rejected. Missing all four values disables the App. Partial
configuration fails explicitly, and startup validates the private key and secret.
Keep secrets in a private local file or secret manager, outside version control.
Do not include their contents in logs or acceptance evidence.

Launch the local service with these variables in its environment. For example,
after stopping only the existing Fornacast process when its active work has
finished, a foreground development process can load a private environment file:

```sh
set -a
source /absolute/private/fornacast-github-app.env
set +a
devenv shell --no-tui -- mix fornacast.run
```

PostgreSQL remains on the devenv Unix socket at port 55432. An existing process
manager may retain its original environment: restarting it is sufficient only
when its launch environment contains the new values. Verify the running process,
API `/health`, and App settings before starting installation/bootstrap.

## Record real endpoint evidence

Use a dedicated checkout directory and retain a small manifest containing test
repository identities, timestamps, expected refs, commit/tree IDs, LFS OIDs,
sizes and SHA-256 digests. Keep credentials out of clone URLs and command logs.

1. Connect the App as a current local organization owner. Confirm the GitHub
   organization identity, installation permissions, selected repository coverage,
   and signed webhook delivery in the App settings.
2. Bootstrap a test repository containing ordinary files, a nested directory,
   a branch/tag, and an LFS object. Wait for durable repository and organization
   state to become active with no pending required resource operations.
3. Clone independently from the real GitHub URL and the Fornacast Git URL.
   Checkout the expected ref on both, run `git fsck --full`, compare refs and
   commit/tree IDs, then run `git lfs pull` and `git lfs fsck`. Check the hydrated
   LFS file's SHA-256 and size against the manifest; a pointer-only checkout is
   insufficient.
4. Make one ordinary Git change and one LFS change on GitHub, then wait for the
   inbound mirror to settle. Repeat independent clone/checkout and integrity
   checks from both endpoints.
5. Make equivalent changes through Fornacast, wait for outbound Git and LFS
   confirmation, and repeat both endpoint checks. Record the durable operation
   IDs and observed remote refs alongside the local refs.
6. Exercise enabled metadata in both directions and the documented conflict,
   pause/resume and recovery cases. Check durable terminal outcomes and remote
   state; a queued job or a `running` label is insufficient evidence.

Update criterion 11 and the other applicable rows in the
[acceptance ledger](superpowers/plans/2026-09-07-github-org-sync-acceptance.md)
only with actual endpoint observations. GitHub wiki repositories and release
asset binaries remain excluded from permanent mirroring; bootstrap/PAT import
has a different release-asset scope.
