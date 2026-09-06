# Issue/comment create correlation markers

PR12's outbound create recovery uses a hidden Markdown HTML comment at the end
of issue and comment source:

```markdown
User-authored body

<!-- fornacast:sync:v1:ac36ea90-98c4-4208-9ae1-3a85326dfc10 -->
```

The UUID is randomly generated and durably stored before the first create request;
every recovery attempt uses that same UUID. It is not a credential. The marker is
visible when inspecting/editing raw Markdown on GitHub, although normal Markdown
rendering hides the HTML comment. It consumes part of the provider body budget;
the combined body and marker must fit the local compatibility limit of 65,536
Unicode codepoints. Oversized content must be reported, never truncated.

Local ingestion removes only the terminal marker matching the persisted expected
UUID. Unrelated HTML comments and markers are preserved. Removing or moving a
marker on GitHub can prevent automatic ambiguous-create recovery; it must not
authorize a blind retry that creates a duplicate.

Markers are recovery hints, not authority. Recovery must verify the repository
and resource kind and finish the relevant paginated scan. Exactly one matching
immutable provider identity can be adopted. Multiple matching identities become
a conflict. An interrupted scan is not evidence of absence. The worker must
retain its external-effect checkpoint until the result is unambiguous.

Implementation status: the source-format codec is tested. Provider worker
integration, rendering/ingestion integration, and ambiguous-create recovery
acceptance remain part of the unfinished PR12 work.
