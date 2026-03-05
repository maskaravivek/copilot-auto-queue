# Example Epic Issue

This is an example of how to structure an epic issue that works with `epic-queue.sh`.

## Epic Structure

Your epic issue should contain a **checklist** of related issues using GitHub's task list syntax:

```markdown
## EPIC: User Authentication System

Goal: Implement a complete authentication system with OAuth, 2FA, and session management.

Success criteria:
- Users can sign up and log in securely
- OAuth integration with Google and GitHub
- Two-factor authentication available
- Session management with automatic logout
- Password reset functionality

### Work items:
- [ ] #101 — Set up authentication database schema
- [ ] #102 — Implement user registration endpoint
- [ ] #103 — Add login with email/password
- [ ] #104 — Integrate Google OAuth
- [ ] #105 — Integrate GitHub OAuth
- [ ] #106 — Add two-factor authentication
- [ ] #107 — Implement session management
- [ ] #108 — Build password reset flow
- [ ] #109 — Add account verification emails
- [ ] #110 — Create user profile settings page
```

## Key Points

1. **Use task list syntax**: `- [ ] #123 — Description`
   - Unchecked boxes (`- [ ]`) are pending work
   - Checked boxes (`- [x]`) are completed (can auto-sync with `--sync-epics`)

2. **Issue numbers are required**: The `#123` reference is how the script:
   - Assigns issues to the coding agent
   - Matches PRs that reference the issue
   - Tracks completion

3. **Order matters**: The script works through issues top-to-bottom

4. **Descriptive titles help**: The text after `#123 —` is shown in issue assignment messages

## Example Output

When running `epic-queue.sh` with the epic above:

```bash
./epic-queue.sh --epics 100 --repo myorg/myapp --auto-merge --watch
```

**First run:**
```
[info] Assigning next issue: #101 Set up authentication database schema
[info] https://github.com/myorg/myapp/issues/101
```

**After Copilot finishes #101:**
```
[info] PR #201 waiting for Copilot to finish session
[info] Copilot assigned to #101: Set up authentication database schema
[info] Waiting on Copilot issue #101 (next check in 60s)

... (Copilot finishes work) ...

[info] Copilot session finished on PR #201
[info] PR #201 idle 125s (need 120s) — ready to merge
[info] Approving PR #201 ...
[info] Merging PR #201 ...
[info] Assigning next issue: #102 Implement user registration endpoint
[info] https://github.com/myorg/myapp/issues/102
```

## Multiple Epics

You can queue multiple epics in priority order:

```bash
./epic-queue.sh --epics 100,200,300 --repo myorg/myapp --auto-merge --watch
```

The script will:
1. Complete all issues from Epic #100 first
2. Then move to Epic #200
3. Finally work through Epic #300

## Tips

- **Keep issues atomic**: Each issue should be a complete, testable unit of work
- **Avoid dependencies**: Issues should be relatively independent when possible
- **Use labels**: Tag issues with `epic-100` or similar for easy tracking
- **Regular updates**: Review the epic checklist as work progresses
- **Sync completed work**: Use `--sync-epics` to auto-check completed issues
