# Git Authentication Design

## Goal

Fornacast must support standard OpenSSH RSA public keys for Git over SSH and
GitHub-style personal API keys for authenticated clone, fetch, and push over
smart HTTP.

## SSH RSA Keys

The SSH-key form accepts standard OpenSSH RSA public keys in this shape:

```text
ssh-rsa <base64-encoded RSA key blob> <optional comment>
```

The `ssh-rsa` prefix describes the RSA key format. It does not enable the
obsolete SHA-1 SSH signature algorithm. The SSH daemon continues to negotiate
modern `rsa-sha2-256` or `rsa-sha2-512` signatures when an RSA key is used.

Key validation decodes the OpenSSH key, stores its SHA-256 fingerprint, and
matches authentication attempts by decoded key material. Existing Ed25519 and
RSA-SHA2-compatible stored keys remain supported.

## Personal API Keys

Each user may create multiple named personal API keys. A key has:

- a name;
- one or both classic repository scopes, `repo:read` and `repo:write`;
- a secure random secret with a recognizable Fornacast prefix;
- an optional expiration time;
- creation, last-used, and revocation metadata.

The raw secret is displayed once after creation. Fornacast stores only a
cryptographic hash and a non-secret prefix suitable for identifying the key in
settings. Users can list and revoke their own keys. Revoked or expired keys
cannot authenticate.

`repo:write` implies permission to read Git data for protocol negotiation.
Token scopes are an additional restriction; they never grant repository access
that the user does not already have through ownership, organization membership,
collaboration, or administration.

## Smart HTTP Authentication

Git clients authenticate with HTTP Basic authentication:

```text
username:personal_api_key
```

Account passwords are not accepted for Git HTTP authentication.

Public clone and fetch remain anonymous. Private clone and fetch require a
valid key with `repo:read` or `repo:write`. Push always requires a valid key
with `repo:write`, including pushes to public repositories. Authentication is
followed by the existing repository authorization check for the acting user.

Authentication failures return `401` with the existing Fornacast Git Basic
challenge. Authenticated users without repository permission receive the
existing repository-access failure without leaking private repository details.

## Smart HTTP Transport

The current upload-pack routes remain the read path. The router and Git HTTP
controller add protocol-v0 receive-pack advertisement and request endpoints:

- `GET /:owner/:repo.git/info/refs?service=git-receive-pack`
- `POST /:owner/:repo.git/git-receive-pack`

The controller reuses `GitTransport.ReceivePack` to advertise refs, parse the
request, apply the pack, and render Git status packets. Successful writes use
the same repository update and audit semantics as SSH pushes. Secrets are never
written to logs or audit metadata.

## Interface

Account settings gain a personal API-key section for creation, one-time secret
display, metadata listing, and revocation. Repository clone instructions expose
the HTTP URL alongside SSH and explain that the Git password prompt expects a
personal API key.

Validation errors are rendered as human-readable field messages. They must not
expose raw Ecto error structures such as keyword lists and metadata tuples.

## Verification

Focused tests cover:

- accepting the exact `ssh-rsa <blob> <comment>` format and storing its
  fingerprint;
- a real SSH client authenticating with that stored RSA key while legacy SHA-1
  signatures remain disabled;
- API-key creation, one-time display, hashing, scopes, expiration, usage
  tracking, and revocation;
- real Git private clone using `username:api_key`;
- real Git push using a write-scoped key;
- public anonymous clone;
- rejection of account passwords, invalid, revoked, or expired keys;
- rejection of pushes with read-only keys;
- rejection when the authenticated user lacks repository authorization; and
- readable SSH-key validation feedback in the settings UI.

Only the affected account, Git transport, and web tests are in scope.
