# Contributing to Agent Evolution Kit

Thank you for your interest in contributing. This project benefits from diverse perspectives on multi-agent orchestration, self-evolution, and AI governance.

## How to Contribute

### Reporting Issues

- Use GitHub Issues for bugs, feature requests, and questions
- Include relevant context: what you tried, what happened, what you expected
- For documentation issues, link to the specific file and section

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Ensure all content is in English
5. Run the sanitization check (see below)
6. Submit a PR with a clear description

### Sanitization Check

Before submitting, verify no personal or project-specific references leaked in:

```bash
# Should return 0 results
grep -ri "oracle\|hachiko\|mahsum\|clawd\|openclaw\|cikcik\|soros\|tithonos" \
  --include="*.md" --include="*.sh" --include="*.yaml" --include="*.json" .
```

### What We're Looking For

**Documentation improvements:**
- Clearer explanations of concepts
- Additional examples
- Translations (keep English as primary, add translations in `docs/i18n/`)
- Typo fixes

**New skills:**
- Skills should be framework-agnostic
- Include YAML frontmatter (name, description)
- Follow the structure of existing skills in `skills/`
- Include red flags and rationalizations sections

**New scripts:**
- Must be POSIX-compatible bash (or clearly documented dependencies)
- Include `set -euo pipefail`
- Include usage/help text
- Use `$AEK_HOME` for paths
- Include colored output helpers

**Academic integrations:**
- New paper implementations welcome
- Include paper citation in `docs/academic-references.md`
- Explain what was adapted from the paper vs used as-is

### What We Don't Want

- Framework-specific implementations (keep it generic)
- API keys, tokens, or secrets (even examples — use `[YOUR_API_KEY]` placeholders)
- Large binary files
- Auto-generated documentation without human review

## Code of Conduct

Be respectful, constructive, and focused on making agents better. We follow the standard [Contributor Covenant](https://www.contributor-covenant.org/).

## Questions?

Open a GitHub Issue with the "question" label. We'll do our best to respond promptly.
