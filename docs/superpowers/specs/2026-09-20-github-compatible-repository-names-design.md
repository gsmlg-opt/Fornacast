# GitHub-Compatible Repository Names

## Goal

Fornacast repository slugs must accept GitHub repository names such as
`duskmoon-dev/.github` and use GitHub's documented repository-name character
set and length limit.

## Canonical local rule

A canonical local repository slug:

- contains 1 through 100 ASCII characters;
- contains only lowercase ASCII letters, digits, `.`, `-`, and `_`;
- may begin with `.`, `-`, or `_`;
- may end with `.`, `-`, or `_`;
- is not `.` or `..`;
- does not end with `.git`, because clone URL parsing treats that suffix as
  presentation data.

Fornacast continues to lowercase repository slugs and remove a supplied `.git`
suffix. Invalid character runs continue to normalize to `-`. Hyphens are no
longer stripped from the beginning or end because GitHub permits them.

Repository display names preserve their original casing, such as `Samgita`.
Lookups, uniqueness, and Git paths are case-insensitive through the lowercase
slug. GitHub imports do not require conflict resolution for case-only changes;
actual duplicate destinations and destructive name normalization still do.

## Integration

`ForgeRepos.Repository` remains the authoritative local validator. All normal,
API, import-publication, and metadata-sync changesets already use it. GitHub
import conflict decisions that persist repository slugs must raise their safe
string limit from 63 to 100 characters so they do not reintroduce the old
boundary.

No migration is required: the database column already accommodates the new
maximum, and repository storage paths are opaque hashes rather than user slugs.

## Verification

Regression coverage will prove:

- `.github` is canonical and can be created through the domain API;
- the REST API can create and read a `.github` repository;
- leading and trailing hyphens follow GitHub's documented character rule;
- 100 characters are accepted and 101 are rejected;
- GitHub import discovery selects `.github` without a rename conflict;
- mixed-case names import without a case-only conflict and retain their casing
  at publication, including after an organization destination change;
- mixed-case Git paths resolve the same repository, while case-only duplicate
  names remain conflicts;
- GitHub metadata synchronization can rename a local repository to `.github`;
- persisted import decisions accept the 100-character boundary;
- trailing dots are accepted, while the reserved `.` and `..` values and the
  `.git` suffix normalization remain enforced.

Only focused `forge_repos` and `forge_imports` PostgreSQL tests and the format
check are required for this change.
