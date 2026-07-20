# SOPS cheatsheet

Quick reference for managing encrypted secrets in this repo. Setup is documented in `CLAUDE.md` under "Secrets — sops-nix". Run all commands from the repo root; `sops` reads `.sops.yaml` to know which recipients to encrypt for.

```sh
# Get sops in scope
nix shell nixpkgs#sops
```

## Day-to-day

```sh
# Edit an existing secret (decrypts, opens $EDITOR, re-encrypts on save)
sops secrets/hosts/001/garage.yaml

# View a secret without editing — print decrypted to stdout
sops -d secrets/hosts/001/garage.yaml

# Pull just one key out (for piping into another command)
sops -d --extract '["garage_env"]' secrets/hosts/001/garage.yaml
```

## Creating a new secret

```sh
# New file — sops creates encrypted from scratch using .sops.yaml rules
sops secrets/hosts/001/<name>.yaml

# Or: encrypt an existing plaintext file in place
sops --encrypt --in-place secrets/hosts/001/<name>.yaml
```

## Recipient management

Use these whenever `.sops.yaml`'s `keys:` or `key_groups:` change.

```sh
# After EDITING .sops.yaml (added/removed a recipient, rotated a host),
# re-encrypt every existing secret to match the new key list.
sops updatekeys secrets/hosts/001/*.yaml
# Asks "y/n" per file showing the diff of recipients being added/removed.
# Use -y to skip the prompt:
sops updatekeys -y secrets/hosts/001/*.yaml

# Rotate the data encryption key on a single file (recipients unchanged).
# Useful if you suspect the DEK leaked.
sops -r -i secrets/hosts/001/garage.yaml
```

## Common workflows

### Adding a new host (e.g. host002)

```sh
# 1. Get host002's pubkey, convert to age
ssh admin@host002 'cat /etc/ssh/ssh_host_ed25519_key.pub' | nix run nixpkgs#ssh-to-age

# 2. Add `&host002 age1...` to .sops.yaml under `keys:` and reference it
#    in the relevant creation_rules entry's key_groups.

# 3. Re-encrypt existing secrets to include host002 as recipient
sops updatekeys secrets/hosts/002/*.yaml
```

### Adding a second laptop / collaborator

```sh
# Have them run `age-keygen -o ~/.config/sops/age/keys.txt` and send you
# their public `age1...` key.

# Add to .sops.yaml as &laptop2 under keys, reference in the creation_rule.
sops updatekeys secrets/hosts/001/*.yaml
```

### Removing a compromised key

```sh
# Edit .sops.yaml — delete the recipient line and remove from key_groups.
sops updatekeys -y secrets/hosts/001/*.yaml
# updatekeys removes recipients no longer listed; the file is now
# unrecoverable with the old key. ALSO rotate the underlying secrets
# (sops can't un-leak data the compromised holder may have already
# decrypted before removal).
```

### Force re-encrypt everything after a `.sops.yaml` overhaul

```sh
# updatekeys is the right tool; fall back to decrypt+re-encrypt only if it misbehaves:
for f in secrets/hosts/*/*.yaml; do
  sops -d "$f" \
    | sops --input-type yaml --output-type yaml -e --filename-override "$f" /dev/stdin \
    > "$f.tmp" && mv "$f.tmp" "$f"
done
```

## Inspection / debugging

```sh
# What recipients can decrypt this file?
sops -d --extract '["sops"]["age"]' secrets/hosts/001/garage.yaml | grep recipient
# (the metadata block at the bottom of the YAML is plain text — can also just `tail` it)

# Verify a file is encrypted (sanity check before commit)
head -c 200 secrets/hosts/001/garage.yaml | grep -q 'ENC\[' && echo OK || echo PLAINTEXT

# Verbose mode for any sops command
sops -v <file>
```

## What you generally don't need

- `sops --rotate` per-file is rarely needed; recipient changes are handled by `updatekeys`, and the DEK rotates implicitly any time you re-save through `sops <file>`.
- Manual key handling (`sops --age=...`, `--add-age`, `--rm-age`) is supported but `.sops.yaml` + `updatekeys` is the cleaner workflow — keep recipients declared in one place rather than passed at the CLI.

## Reinstall hazard

A wipe of host001 regenerates `/etc/ssh/ssh_host_ed25519_key`, so the existing encrypted secrets become undecryptable on the new host. Two paths:

1. **Preserve the host SSH key** across reinstalls (USB / 1Password offline). Restore to `/mnt/etc/ssh/` after disko mounts, before `nixos-install`. No further action needed — same identity, existing secrets just decrypt.
2. **Accept the new identity:** convert the new host's pubkey via `ssh-to-age`, replace the `&host001` line in `.sops.yaml`, then `sops updatekeys -y secrets/hosts/001/*.yaml`, commit, rebuild.
