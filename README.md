# DetectiveGadget

DetectiveGadget is an evidence-first Swift debugging CLI for macOS and Linux-oriented repositories. The first MVP collects a Jira issue URL, constructs a minimal JQL query, detects available investigation CLIs, collects reproduction evidence, and persists an investigation context before any code changes are allowed.

## Build

```sh
swift build
swift test
swift run detective-gadget
```

## Configuration

On first run, DetectiveGadget creates `~/.DetectiveGadget/requirement.json`. Keep secrets out of this file. The default base branch is `development`; the Jira issue URL, CLI choice, and evidence are requested interactively.

To retrieve raw Jira data without hard-coding a Jira vendor CLI, set `jira.fetchCommand` to a command template supplied by the developer. The template may use `{jql}`, `{url}`, and `{key}` placeholders. The same JQL is also provided through `DETECTIVE_GADGET_JQL`.

Example configuration fragment:

```json
{
  "jira": {
    "fetchCommand": "your-jira-cli --jql {jql} --json"
  }
}
```

The command must write JSON or text to stdout and return exit status zero. DetectiveGadget does not store credentials or invent a Jira authentication mechanism.

## Evidence policy

The MVP never reports a confirmed root cause from textual similarity alone. A confirmed result requires a reproducible trigger, a causal path, and a verified remediation with regression confidence. Otherwise the result remains a candidate hypothesis and the saved context can be extended with logs.

## Current safety boundary

This version does not modify source files, create branches, push commits, or open pull requests. Those actions remain approval-gated follow-up stages.
