# Security

This is the default security policy for forkwright repositories. A repository that needs
different terms carries its own `SECURITY.md`, which takes precedence over this file.

## Reporting vulnerabilities

**Do not open a public GitHub issue, pull request, or discussion for an undisclosed vulnerability.**

Report privately through the affected repository's own advisory form: open its **Security** tab and
choose **Report a vulnerability**. Reporting against the repository the issue is in keeps the report
attached to the code it concerns and visible to the people who can fix it.

If the repository is private, or its advisory form is unavailable, use the operator's private
security channel instead.

Include:

- The affected repository and commit
- Impact, and what an attacker reaches through it
- Reproduction steps or proof-of-concept detail
- Whether credentials, private data, or build infrastructure are exposed
- A suggested fix, if you have one

## What to expect

- Acknowledgement within 48 hours
- Severity assigned after reproduction or credible impact analysis
- Fix developed privately when disclosure risk warrants it
- Public advisory only once a fix is available, or by explicit agreement

## For contributors

Engineering security standards — secret handling, typed credential wrappers, TLS on
credential-bearing traffic, explicit permissions on credential writes, validation at trust
boundaries — are defined in the `basanos` standards and enforced by `kanon lint`.
