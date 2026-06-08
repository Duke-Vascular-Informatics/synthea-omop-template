# Git and GitHub Authentication (Detailed)

This guide expands Step 2 in `docs/GETTING_STARTED.md`.

## SSH Authentication (Recommended)

```bash
# Generate a key (press Enter for defaults)
ssh-keygen -t ed25519 -C "your.email@org.edu"

# Start ssh-agent and add key
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Copy public key and add it in GitHub
cat ~/.ssh/id_ed25519.pub

# Test connection
ssh -T git@github.com
```

Add the copied key in GitHub:
- GitHub -> Settings -> SSH and GPG keys -> New SSH key

Expected test output includes:
- `Hi <username>! You've successfully authenticated...`

## HTTPS + Token-Backed Authentication

If you use GitHub CLI:

```bash
gh auth login
gh auth status
```

If you do not use GitHub CLI:
- Use HTTPS remotes
- Sign in when prompted by your credential manager or Git client

## Check Current Remote Type

```bash
git remote -v
```

- SSH remote example: `git@github.com:org/repo.git`
- HTTPS remote example: `https://github.com/org/repo.git`

## Switch Remote Type

```bash
# Switch to SSH
git remote set-url origin git@github.com:<org>/<repo>.git

# Switch to HTTPS
git remote set-url origin https://github.com/<org>/<repo>.git
```
