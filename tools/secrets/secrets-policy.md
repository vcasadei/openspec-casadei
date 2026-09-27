# Secrets policy

Written by openspec-casadei (`install --secrets high`). This file is the
project's secrets policy: the `casadei` schema tells the agent to read it in
the proposal, design, and apply steps and to follow it wherever it is stricter
than the schema's own rules. Edit it freely - re-running the installer never
overwrites it.

## Where secrets live

Fill in the table once for the project. The agent asks rather than choosing
when a row still says `TBD`.

| Environment | Store | How code reads it |
|---|---|---|
| Local development | TBD - e.g. 1Password (`op run`), Doppler, Infisical, SOPS-encrypted file | TBD |
| CI (GitHub Actions) | GitHub Environments secrets; cloud access through OIDC | `${{ secrets.NAME }}` scoped to an environment |
| Staging | TBD - e.g. HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, GCP Secret Manager | TBD |
| Production | TBD | TBD |

## Rules

1. **No plaintext secrets on disk.** Local development pulls secrets from the
   store at run time (`op run -- npm start`, `doppler run -- ...`) instead of
   keeping them in a long-lived `.env`. If the project keeps secrets in the
   repo at all, they are encrypted (SOPS with age or a KMS key, or dotenvx),
   and the decryption key is never committed.
2. **Every secret has an owner and a rotation period.** A new secret is named
   in the proposal's Impact and in the design, with its store per
   environment, who can read it, and how often it is rotated.
3. **No long-lived cloud keys in CI.** GitHub Actions reaches AWS, Azure, or GCP
   through OIDC federation, not through an access key stored as a repository
   secret. Production secrets live in a GitHub Environment with required
   reviewers.
4. **Least privilege.** Each service and each pipeline gets its own
   credential, scoped to what it needs. No shared "admin" key.
5. **Production reads secrets at run time** from the store or from the
   platform (Kubernetes secrets fed by the store, a managed identity). They
   are not baked into images, build artifacts, or committed config.
6. **The scanner is not optional.** The gitleaks pre-commit hook is installed
   in every clone (`pre-commit install`), and the Secret scan workflow must
   pass before merge. Nobody commits with `--no-verify` to get past it.

## If a secret leaks

1. **Rotate it first.** Revoke the credential at its source and issue a new
   one. Once pushed, a secret is compromised, even if the commit is removed
   minutes later.
2. Check the provider's access logs for use of the leaked credential.
3. Remove it from the code and, if the team decides to, from history
   (`git filter-repo --replace-text`), then force-push and have every
   collaborator re-clone.
4. Add the rotated secret's fingerprint to `.gitleaksignore` so the history
   scan passes again, with a comment saying when it was rotated.
