# Repository rules

## Access and merges

Only `tommasoltrz` has write access to `anguria-studio/Moppo`.
Other users cannot merge unless an administrator gives them write access.
The repository permits squash merges only.
GitHub uses the pull request title as the squash commit title.

- Open a pull request for each change to `main`.
- Use a branch name such as `fix/scan-removal-flows`.
- Use a Conventional Commit title, such as `fix: clear outdated scan results`.
- Wait for the `Pull request rules` and `Tests and writing` checks to pass.
- Merge only after an explicit instruction from `tommasoltrz`.

The branch format is a repository rule.
The Conventional Commits specification defines commit messages, not branch names.
The [project instructions](../AGENTS.md#branches-and-pull-requests) list the permitted types.

## GitHub Free limit

This private organization repository uses GitHub Free.
GitHub requires GitHub Team for branch protection in this configuration.
CI reports failures, but GitHub does not block a merge when a check fails.
GitHub also permits an administrator to push directly to `main`.
Local instructions cannot enforce server rules.

See [GitHub branch protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

## Settings after an upgrade

After an upgrade to GitHub Team, apply these settings to `main`:

- Require a pull request before a merge.
- Require the `Pull request rules` and `Tests and writing` checks.
- Require the branch to include the latest `main` changes before a merge.
- Restrict pushes and merges to `tommasoltrz`.
- Apply the rules to administrators.
- Require resolution of review conversations.
- Require linear history.
- Block force pushes and branch deletion.
- Keep automatic merges disabled.

Do not require a second reviewer while `tommasoltrz` is the sole maintainer.
GitHub does not permit an author to approve their own pull request.

After both CI checks have run, apply the prepared configuration:

```sh
gh api --method PUT repos/anguria-studio/Moppo/branches/main/protection \
  --input .github/main-protection.json
```

The configuration is inactive until GitHub accepts this command.

## CI coverage

The `CI` workflow runs on pull requests and pushes to `main`.
The workflow can also run manually.
The workflow checks branch names and pull request titles on pull requests.
It runs the core tests, app state tests, and Vale writing checks.
The workflow has read access to repository contents.
It does not need signing certificates or other repository secrets.

The app state tests use a separate test bundle with an ad hoc signature.
These tests do not launch Moppo or use personal photos.
The signed app build and live macOS permission dialogs need separate checks.
