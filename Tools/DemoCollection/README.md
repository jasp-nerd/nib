# Demo collection

The fixture `Tools/screenshot.sh` opens so the product screenshot always shows the same thing.

It is a real Nib collection, in the on-disk format described in `docs/on-disk-format.md`, so it
doubles as a worked example of what one looks like: requests as individual JSON files, environments
in their own directory, and a secret recorded as `"value": null`.

`Local` points at `127.0.0.1:8795`, which is the throwaway server the screenshot script starts.
`Staging` points at a host that does not exist, on purpose — selecting it is how you check that
switching environment actually retargets the request.

`API_TOKEN` is marked secret with no stored value, so the screenshot shows the unresolved-variable
warning rather than a suspiciously clean window.
