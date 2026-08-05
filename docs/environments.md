# Environments and secrets

An environment is a named set of `{{variables}}`, one per server you talk to. Switching the picker
retargets every request in the collection without editing any of them.

Two stores back one feature, and keeping them straight is the whole design:

| | Where | What |
|---|---|---|
| Keys, and non-secret values | `environments/<Name>.env.json`, in your repo | committed, diffed, reviewed |
| Secret values | Keychain, service `app.nib.secret` | never written to disk, never in a diff |

In memory both halves are present, because they have to be to build a request. Everywhere else they
stay apart.

## Resolution

Precedence is `request > environment > folder > collection`, defined once in `VariableScope` and
assembled in `CollectionModel.scope(forRequestWithID:)`.

**The environment beats the collection, and that direction is load-bearing.** The collection holds
defaults — `baseUrl` = production. The active environment is the "which target am I hitting" switch,
so it has to be able to override them. Inverting it means selecting Staging silently fails to
redirect and the app looks like it is working while it hits production. There is a regression test
in `VariableResolverTests` and another through the model in `EnvironmentsTests`; neither is a
candidate for simplification.

A variable resolves only if it is **enabled** and **has a value**. Both exclusions matter:

- Disabled is the user saying "not this one", and behaves as if the key were absent.
- A secret with no stored value is the normal state on a freshly cloned repo. It stays unresolved,
  so `{{TOKEN}}` remains visible in the URL bar and in the warning strip. Substituting an empty
  string instead would send a blank credential and produce a 401 that explains nothing.

Unresolved names are reported **before** the send, not only after — `RequestSession.pendingUnresolved`
scans the URL and the enabled headers. Not the body: it can be a megabyte, and re-scanning it on
every keystroke buys nothing the send would not report anyway.

## What the files look like

```json
{
  "formatVersion" : 1,
  "id" : "01KZ9K6KBASQWVA0CEQA8WC2Y3",
  "name" : "Staging",
  "variables" : [
    { "enabled" : true, "key" : "baseUrl",   "secret" : false, "value" : "https://staging.acme.dev" },
    { "enabled" : true, "key" : "API_TOKEN", "secret" : true,  "value" : null }
  ]
}
```

`"value": null` is written explicitly, never omitted. An absent key would be indistinguishable from
a variable that never existed, and a clone could not then tell you a token is expected.

## Keychain accounts

Service `app.nib.secret`, account `<collectionID>/<environmentName>/<key>`.

Readable on purpose rather than hashed: Keychain Access is the escape hatch when Nib is not running,
and someone who wants to rotate or delete their own token should be able to find it by eye.

Because the account contains the environment *name*, renaming an environment is a Keychain move as
well as a file rename. That works because the values are in memory at the time: `SecretStore.synchronise`
writes them under the new accounts and prunes the old ones. Renames, deletions and unticking
"secret" all go through that one reconcile step, which is why none of them leave an orphan entry.

`synchronise` lists before it writes, and the listing's failure propagates before anything is
deleted. A locked Keychain listing as empty would otherwise make it delete every secret you have.
For the same reason `CollectionModel` refuses to write secrets at all while `secretsFailure` is set,
and says so in the bar above the URL field.

## Two honest limitations of the Keychain path

Both are consequences of shipping self-signed, not bugs to fix in this code.

1. **This is the file-based keychain, not the data-protection keychain.** The modern one requires a
   `keychain-access-groups` entitlement tied to a Team ID; a self-signed build gets
   `errSecMissingEntitlement`. A knock-on effect worth knowing: the file keychain rejects
   `kSecMatchLimitAll` together with `kSecReturnData` — it answers `errSecParam` rather than an empty
   list — so `SecretStore` enumerates accounts and then reads each value individually.
2. **The ACL is bound to the code signature.** An ad-hoc signature changes with every build, so
   upgrading Nib can re-prompt for permission. "Always Allow" holds until the next upgrade.
   Notarizing with a stable Developer ID would end this. See `docs/signing.md`.

## Editing model

The editor stages changes in memory and writes once, on dismiss — including Escape, because losing
ten minutes of typed tokens to the wrong key is not a trade worth making for a tidy Cancel button.
Saving per keystroke would mean a file write and a Keychain write per character, and a rename would
mint a fresh Keychain account for every intermediate spelling of the name.

The in-memory half is immediate, so `{{baseUrl}}` in the URL bar behind the sheet resolves as you
type the value.

Three races had to be closed to make that safe, all with the same shape — the folder watcher firing
while an edit was in flight:

- A reload landing between staging and committing would discard the staged environments.
  `hasStagedEnvironmentChanges` makes a reload take the tree from disk and keep environments from
  memory.
- A reload publishes what is on disk, where every secret is `null`, and only refills the values one
  suspension point later. `carryingSecrets` keeps values already held, so there is no window in
  which every token in the app reads as empty.
- `store.load()` takes long enough for a save to finish underneath it. Applying that snapshot rolls
  the model back to how the files looked a moment ago and then persists it. `reloadIfChangedExternally`
  re-checks the write generation after the read and drops the stale snapshot.

The third one is not specific to environments — it could discard a just-saved request too. All three
presented as the same symptom: a suite that failed in a different combination on each run.
